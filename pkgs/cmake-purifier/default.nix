# SPDX-License-Identifier: MIT
#
# The `cmake-purifier` command.
#
#   cmake-purifier lock [-S <source dir>] [<cmake configure arguments>...]
#   cmake-purifier configure -B <build dir> [-S <source dir>] [<cmake configure arguments>...]
#
# `lock` configures the project once in a scratch build directory, with
# the network, an empty FetchContent download directory and the lock
# run's dependency provider (cmake/CMakePurifierLock.cmake). Every
# dependency FetchContent populates goes into
# <source dir>/cmake-purifier.lock.json: a URL download by its URL and the
# SHA-256 of the file, a git checkout by its repository, commit and the
# hash fetchgit checks (see nix/lib/lock.nix for the format). The configure arguments go into the lockfile too,
# since they decide which dependencies the build declares; every build of
# the lockfile passes them first.
#
# `configure` runs `cmake` on the locked sources, offline. It builds the
# sources through Nix (with a GC root in <build dir>/cmake-purifier),
# copies them into the build directory, and passes CMake an initial cache
# that points FetchContent at the copies. Arguments after the build
# directory follow the locked ones.
#
# Both commands run the `nix` and `nix-build` of the user's own Nix
# installation.
{
  pkgs,
  writeShellApplication,
  cmake,
  git,
  jq,
  nix-prefetch-git,
  coreutils,
}:
writeShellApplication {
  name = "cmake-purifier";
  runtimeInputs = [
    cmake
    git
    jq
    nix-prefetch-git
    coreutils
  ];
  meta = {
    description = "Lock the FetchContent downloads of a CMake build, and configure it offline from the lock";
    mainProgram = "cmake-purifier";
  };
  text = ''
    lockVersion=${toString (import ../../nix/lib/lock-version.nix)}
    provider=${../../cmake/CMakePurifierLock.cmake}
    lockedProvider=${../../cmake/CMakePurifierLocked.cmake}
    nixlib=${../../nix/lib}
    nixpkgs=${pkgs.path}

    usage() {
      cat >&2 <<'EOF'
    usage: cmake-purifier lock [-S <source dir>] [<cmake configure arguments>...]
           cmake-purifier configure -B <build dir> [-S <source dir>] [<cmake configure arguments>...]
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

    # -S and -B are read here, in the separate and the attached form; every
    # other argument goes to cmake.
    source=.
    build=
    args=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -S) [ $# -ge 2 ] || usage; source=$2; shift 2 ;;
        -S*) source=''${1#-S}; shift ;;
        -B) [ $# -ge 2 ] || usage; build=$2; shift 2 ;;
        -B*) build=''${1#-B}; shift ;;
        *) args+=("$1"); shift ;;
      esac
    done
    source=$(realpath "$source")
    [ -f "$source/CMakeLists.txt" ] || die "$source has no CMakeLists.txt"
    lockfile=$source/cmake-purifier.lock.json

    lock() {
      [ -z "$build" ] || die "lock takes no -B; it configures in a scratch directory"
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      echo "cmake-purifier: configuring $source to find its downloads" >&2
      cmake -S "$source" -B "$work/build" \
        -DCMAKE_PROJECT_TOP_LEVEL_INCLUDES="$provider" \
        -DCMAKE_PURIFIER_OBSERVED="$work/observed.json" \
        -DFETCHCONTENT_BASE_DIR="$work/deps" \
        -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER \
        -DFETCHCONTENT_FULLY_DISCONNECTED=OFF \
        ''${args[@]+"''${args[@]}"} >&2
      [ -f "$work/observed.json" ] || die "the configure run wrote no record of its downloads"

      artifacts='[]'
      dependencies='[]'
      count=$(jq '.dependencies | length' "$work/observed.json")
      for ((i = 0; i < count; i++)); do
        dep=$(jq -c ".dependencies[$i]" "$work/observed.json")
        name=$(jq -r .name <<<"$dep")
        type=$(jq -r .type <<<"$dep")
        url=$(jq -r .url <<<"$dep")
        case "$type" in
          url)
            echo "cmake-purifier: hashing $url" >&2
            hash=$(nix --extra-experimental-features nix-command store prefetch-file --json "$url" | jq -r .hash)
            path="$name/$(basename "''${url%%[?#]*}")"
            artifacts=$(jq -c --arg path "$path" --arg url "$url" --arg hash "$hash" \
              '. + [{path: $path, url: $url, hash: $hash}]' <<<"$artifacts")
            dependencies=$(jq -c --argjson dep "$dep" --arg path "$path" \
              '. + [{name: $dep.name, artifact: $path, extract: $dep.extract}]' <<<"$dependencies")
            ;;
          git)
            rev=$(jq -r .rev <<<"$dep")
            submodules=$(jq -r .submodules <<<"$dep")
            echo "cmake-purifier: hashing $url at $rev" >&2
            flags=(--quiet --url "$url" --rev "$rev")
            [ "$submodules" = true ] && flags+=(--fetch-submodules)
            hash=$(nix-prefetch-git "''${flags[@]}" | jq -r .hash)
            artifacts=$(jq -c --argjson dep "$dep" --arg hash "$hash" \
              '. + [{path: $dep.name, git: {url: $dep.url, rev: $dep.rev, submodules: $dep.submodules}, hash: $hash}]' <<<"$artifacts")
            dependencies=$(jq -c --argjson dep "$dep" \
              '. + [{name: $dep.name, artifact: $dep.name}]' <<<"$dependencies")
            ;;
          *) die "the configure run recorded the unknown dependency type $type" ;;
        esac
      done

      flagsJson=$(jq -c -n '$ARGS.positional' --args -- ''${args[@]+"''${args[@]}"})
      jq -n \
        --argjson version "$lockVersion" \
        --argjson project "$(jq -c .project "$work/observed.json")" \
        --argjson cmakeFlags "$flagsJson" \
        --argjson artifacts "$artifacts" \
        --argjson dependencies "$dependencies" \
        '{
          version: $version,
          project: $project,
          cmakeFlags: $cmakeFlags,
          artifacts: ($artifacts | sort_by(.path)),
          dependencies: ($dependencies | sort_by(.name))
        }' > "$lockfile.tmp"
      mv "$lockfile.tmp" "$lockfile"
      echo "cmake-purifier: wrote $lockfile with $count dependencies" >&2
    }

    configure() {
      [ -n "$build" ] || die "configure needs -B <build dir>"
      [ -f "$lockfile" ] || die "$lockfile does not exist; run cmake-purifier lock first"
      format=$(jq .version "$lockfile")
      [ "$format" = "$lockVersion" ] || die "$lockfile has lock format version $format; this cmake-purifier reads version $lockVersion. Run cmake-purifier lock again."
      mkdir -p "$build/cmake-purifier"
      build=$(realpath "$build")
      tree=$(nix-build --expr \
        "{ lockFile }: ((import $nixpkgs { }).callPackage $nixlib/sources.nix { inherit lockFile; }).tree" \
        --arg lockFile "$lockfile" --out-link "$build/cmake-purifier/sources-root")
      bash "$nixlib/write-cache.sh" "$tree" "$build/cmake-purifier/sources" "$build/cmake-purifier/cache.cmake" "$lockedProvider"
      mapfile -t locked < <(jq -r '.cmakeFlags[]' "$lockfile")
      exec cmake -S "$source" -B "$build" -C "$build/cmake-purifier/cache.cmake" \
        ''${locked[@]+"''${locked[@]}"} ''${args[@]+"''${args[@]}"}
    }

    case "$command" in
      lock) lock ;;
      configure) configure ;;
      *) usage ;;
    esac
  '';
}
