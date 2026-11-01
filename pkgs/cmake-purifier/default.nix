# SPDX-License-Identifier: MIT
#
# The `cmake-purifier` command.
#
#   cmake-purifier lock [--no-build] [-S <source dir>] [<cmake configure arguments>...]
#   cmake-purifier configure -B <build dir> [-S <source dir>] [<cmake configure arguments>...]
#   cmake-purifier build -B <build dir> [<cmake --build arguments>...]
#
# `lock` configures and builds the project once in a scratch directory,
# with the network and an empty FetchContent download directory. Three
# recorders see its downloads: mitmproxy as the HTTP and HTTPS proxy of
# CMake and everything it runs (lock/record.py), a git wrapper in
# GIT_EXECUTABLE that logs every git command, and the dependency provider
# cmake/CMakePurifierLock.cmake, which names the FetchContent dependency
# each download belongs to. lock/assemble.py turns the three records into
# <source dir>/cmake-purifier.lock.json (see nix/lib/lock.nix for the
# format). The configure arguments go into the lockfile too, since they
# decide which downloads the build makes; every build of the lockfile
# passes them first. After the build, `lock` installs the project into a
# scratch prefix and records what it installed, so that Nix knows the
# outputs of the build without building it. `--no-build` stops after the
# configure, and then the lockfile misses what the build itself downloads,
# and records no outputs.
#
# `configure` runs `cmake` on the locked downloads, offline. It builds them
# through Nix (with a GC root in <build dir>/cmake-purifier), copies the
# FetchContent dependencies into the build directory, and passes CMake an
# initial cache that points FetchContent at the copies and git at the
# locked checkouts. mitm-cache replays every other locked download as the
# proxy of the configure. Arguments after the build directory follow the
# locked ones. `build` runs `cmake --build` behind the same proxy, for a
# build that downloads files while it builds.
#
# All three commands run the `nix-build` of the user's own Nix
# installation, and `lock` runs its own nix-prefetch-git.
{
  pkgs,
  writeShellApplication,
  runtimeShell,
  cmake,
  git,
  mercurial,
  subversion,
  cvs,
  jq,
  mitmproxy,
  mitm-cache,
  nix-prefetch-git,
  openssl,
  python3,
  python3Packages,
  coreutils,
}:
writeShellApplication {
  name = "cmake-purifier";
  runtimeInputs = [
    cmake
    jq
    mitmproxy
    mitm-cache
    openssl
    python3Packages.ephemeral-port-reserve
    coreutils
  ];
  meta = {
    description = "Lock the downloads of a CMake build, and configure and build it offline from the lock";
    mainProgram = "cmake-purifier";
  };
  text = ''
    lockVersion=${toString (import ../../nix/lib/lock-version.nix)}
    provider=${../../cmake/CMakePurifierLock.cmake}
    lockedProvider=${../../cmake/CMakePurifierLocked.cmake}
    nixlib=${../../nix/lib}
    lockdir=${../../lock}
    nixpkgs=${pkgs.path}
    realGit=${git}/bin/git
    realHg=${mercurial}/bin/hg
    realSvn=${subversion}/bin/svn
    realCvs=${cvs}/bin/cvs
    python=${python3}/bin/python3
    prefetchGit=${nix-prefetch-git}/bin/nix-prefetch-git

    usage() {
      cat >&2 <<'EOF'
    usage: cmake-purifier lock [--no-build] [-S <source dir>] [<cmake configure arguments>...]
           cmake-purifier configure -B <build dir> [-S <source dir>] [<cmake configure arguments>...]
           cmake-purifier build -B <build dir> [<cmake --build arguments>...]
    EOF
      exit 2
    }

    die() {
      echo "cmake-purifier: $*" >&2
      exit 1
    }

    [ $# -ge 1 ] || usage
    command=$1
    shift

    # -S, -B and --no-build are read here, in the separate and the attached
    # form; every other argument goes to cmake.
    source=.
    build=
    noBuild=
    args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -S) [ $# -ge 2 ] || usage; source=$2; shift 2 ;;
        -S*) source=''${1#-S}; shift ;;
        -B) [ $# -ge 2 ] || usage; build=$2; shift 2 ;;
        -B*) build=''${1#-B}; shift ;;
        --no-build) noBuild=1; shift ;;
        *) args+=("$1"); shift ;;
      esac
    done
    source=$(realpath "$source")
    lockfile=$source/cmake-purifier.lock.json

    # Waits until something listens on 127.0.0.1:<port>.
    await_port() {
      for _ in $(seq 100); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
          return 0
        fi
        sleep 0.1
      done
      die "the proxy on port $1 did not start"
    }

    # The environment that sends HTTP and HTTPS through the proxy on
    # 127.0.0.1:<port> and trusts the certificate authority <ca>.
    proxy_env() {
      export http_proxy="http://127.0.0.1:$1" https_proxy="http://127.0.0.1:$1"
      export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy"
      unset ALL_PROXY all_proxy
      export SSL_CERT_FILE="$2" NIX_SSL_CERT_FILE="$2" CURL_CA_BUNDLE="$2"
    }

    lock() {
      [ -z "$build" ] || die "lock takes no -B; it configures in a scratch directory"
      [ -f "$source/CMakeLists.txt" ] || die "$source has no CMakeLists.txt"
      work=$(mktemp -d)
      trap 'kill "''${recorder:-}" 2>/dev/null || true; chmod -R u+w "$work" 2>/dev/null || true; rm -rf "$work"' EXIT

      # mitmproxy forwards to the user's own proxy when one is set.
      mode=regular
      upstreamArgs=()
      svnArgs=()
      upstream=''${https_proxy:-''${HTTPS_PROXY:-}}
      if [ -n "$upstream" ]; then
        hostport=''${upstream#*://}
        hostport=''${hostport%/}
        if [ "''${hostport#*@}" != "$hostport" ]; then
          creds=''${hostport%@*}
          upstreamArgs=(--set "upstream_auth=$creds")
          hostport=''${hostport#*@}
          svnArgs+=(--config-option="servers:global:http-proxy-username=''${creds%%:*}")
          svnArgs+=(--config-option="servers:global:http-proxy-password=''${creds#*:}")
        fi
        mode="upstream:http://$hostport"
        # svn reads no proxy variables, only its own configuration.
        svnArgs+=(--config-option="servers:global:http-proxy-host=''${hostport%:*}")
        svnArgs+=(--config-option="servers:global:http-proxy-port=''${hostport##*:}")
      fi

      # Writes $work/<tool>, a wrapper that logs each command with its
      # working directory to $work/<tool>.jsonl and runs <real> with the
      # user's own network environment and any further arguments given.
      make_logger() {
        local tool=$1 real=$2
        shift 2
        {
          echo "#!${runtimeShell}"
          for var in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy NO_PROXY no_proxy SSL_CERT_FILE NIX_SSL_CERT_FILE CURL_CA_BUNDLE; do
            if [ -n "''${!var+set}" ]; then
              printf 'export %s=%q\n' "$var" "''${!var}"
            else
              printf 'unset %s\n' "$var"
            fi
          done
          # The wrapper expands $PWD and $@ itself, and jq the filter.
          # shellcheck disable=SC2016
          printf '%q -cn --arg cwd "$PWD" %q --args -- "$@" >> %q\n' \
            "$(command -v jq)" '{cwd: $cwd, args: $ARGS.positional}' "$work/$tool.jsonl"
          printf 'exec %q' "$real"
          for extra in "$@"; do
            printf ' %q' "$extra"
          done
          # shellcheck disable=SC2016
          printf ' "$@"\n'
        } > "$work/$tool"
        chmod +x "$work/$tool"
      }
      make_logger git "$realGit"
      make_logger hg "$realHg"
      make_logger svn "$realSvn" ''${svnArgs[@]+"''${svnArgs[@]}"}
      make_logger cvs "$realCvs"
      port=$(ephemeral-port-reserve 127.0.0.1)
      PURIFIER_RECORD="$work/http.jsonl" mitmdump -q --listen-host 127.0.0.1 --listen-port "$port" \
        --mode "$mode" ''${upstreamArgs[@]+"''${upstreamArgs[@]}"} --set confdir="$work/mitmproxy" \
        -s "$lockdir/record.py" &
      recorder=$!
      await_port "$port"

      echo "cmake-purifier: configuring $source to record its downloads" >&2
      # The File API's code model names the targets and where they install.
      mkdir -p "$work/build/.cmake/api/v1/query"
      touch "$work/build/.cmake/api/v1/query/codemodel-v2"
      (
        proxy_env "$port" "$work/mitmproxy/mitmproxy-ca-cert.pem"
        unset CPM_SOURCE_CACHE
        # CMAKE_INSTALL_LIBDIR and CMAKE_BUILD_TYPE are what nixpkgs' CMake
        # setup hook sets, so that the recorded outputs match the outputs
        # of the sandbox build. The build type decides the names of some
        # installed files, such as <package>-targets-release.cmake. A
        # -DCMAKE_BUILD_TYPE among the user's arguments comes later and
        # wins, and the lockfile records it for the sandbox build.
        cmake -S "$source" -B "$work/build" \
          -DCMAKE_INSTALL_LIBDIR=lib \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="$provider" \
          -DCMAKE_PURIFIER_OBSERVED="$work/observed.json" \
          -DFETCHCONTENT_BASE_DIR="$work/deps" \
          -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER \
          -DFETCHCONTENT_FULLY_DISCONNECTED=OFF \
          -DGIT_EXECUTABLE="$work/git" \
          -DHG_EXECUTABLE="$work/hg" \
          -DSubversion_SVN_EXECUTABLE="$work/svn" \
          -DCVS_EXECUTABLE="$work/cvs" \
          ''${args[@]+"''${args[@]}"} >&2
        if [ -z "$noBuild" ]; then
          echo "cmake-purifier: building $source to record what the build downloads" >&2
          cmake --build "$work/build" --parallel >&2
          echo "cmake-purifier: installing $source to record its outputs" >&2
          cmake --install "$work/build" --prefix "$work/prefix" >&2
        fi
      )
      kill "$recorder"
      wait "$recorder" 2>/dev/null || true
      recorder=
      [ -f "$work/observed.json" ] || die "the configure run wrote no record of its dependencies"

      jq -n '$ARGS.positional' --args -- ''${args[@]+"''${args[@]}"} > "$work/flags.json"
      "$python" -I "$lockdir/assemble.py" "$work" "$lockVersion" "$lockfile" "$nixpkgs" \
        "$nixlib" "$realGit" "$realHg" "$realSvn" "$prefetchGit"
    }

    # Builds the locked downloads and writes the initial cache of <build dir>.
    prepare() {
      [ -f "$lockfile" ] || die "$lockfile does not exist; run cmake-purifier lock first"
      format=$(jq .version "$lockfile")
      [ "$format" = "$lockVersion" ] || die "$lockfile has lock format version $format; this cmake-purifier reads version $lockVersion. Run cmake-purifier lock again."
      mkdir -p "$build/cmake-purifier"
      build=$(realpath "$build")
      tree=$(nix-build --expr \
        "{ lockFile }: ((import $nixpkgs { }).callPackage $nixlib/sources.nix { inherit lockFile; }).tree" \
        --arg lockFile "$lockfile" --out-link "$build/cmake-purifier/sources-root")
      bash "$nixlib/write-cache.sh" "$tree" "$build/cmake-purifier/sources" "$build/cmake-purifier/cache.cmake" \
        "$lockedProvider" "$nixlib" "$realGit" "$realHg" "$realSvn" "$realCvs"
    }

    # Runs a command with mitm-cache replaying the locked files of
    # <build dir> as its proxy.
    replay() {
      tree=$(readlink -f "$build/cmake-purifier/sources-root")
      ca=$build/cmake-purifier/ca
      mkdir -p "$ca"
      [ -f "$ca/ca.cer" ] || {
        openssl genrsa -out "$ca/ca.key" 2048 2>/dev/null
        openssl req -x509 -new -nodes -key "$ca/ca.key" -sha256 -days 3650 -out "$ca/ca.cer" -subj "/CN=cmake-purifier" 2>/dev/null
      }
      port=$(ephemeral-port-reserve 127.0.0.1)
      mitm-cache -l "127.0.0.1:$port" -k "$ca/ca.key" -c "$ca/ca.cer" replay "$tree/http" >/dev/null 2>&1 &
      replayer=$!
      trap 'kill "$replayer" 2>/dev/null || true' EXIT
      await_port "$port"
      status=0
      ( proxy_env "$port" "$ca/ca.cer"; "$@" ) || status=$?
      exit "$status"
    }

    configure() {
      [ -n "$build" ] || die "configure needs -B <build dir>"
      [ -f "$source/CMakeLists.txt" ] || die "$source has no CMakeLists.txt"
      prepare
      mapfile -t locked < <(jq -r '.cmakeFlags[]' "$lockfile")
      replay cmake -S "$source" -B "$build" -C "$build/cmake-purifier/cache.cmake" \
        ''${locked[@]+"''${locked[@]}"} ''${args[@]+"''${args[@]}"}
    }

    build() {
      [ -n "$build" ] || die "build needs -B <build dir>"
      [ -d "$build/cmake-purifier" ] || die "$build was not configured with cmake-purifier configure"
      build=$(realpath "$build")
      replay cmake --build "$build" ''${args[@]+"''${args[@]}"}
    }

    case "$command" in
      lock) lock ;;
      configure) configure ;;
      build) build ;;
      *) usage ;;
    esac
  '';
}
