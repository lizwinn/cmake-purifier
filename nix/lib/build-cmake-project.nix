# SPDX-License-Identifier: MIT
#
# buildCMakeProject: builds and installs a CMake project in the sandbox
# from its cmake-purifier lockfile. The package overlay adds it to a
# package set, so a package written for callPackage takes it by name.
#
#   buildCMakeProject { src = ./.; }
#
# The derivation is stdenv.mkDerivation with nixpkgs' cmake setup hook,
# so every mkDerivation argument works as usual: `buildInputs` for the
# libraries find_package() looks for, `doCheck` to run ctest, and so on.
# The arguments of the builder itself:
#
# - `src`: the project. Its lockfile is `cmake-purifier.lock.json` at the
#   root, unless `lockFile` names another.
# - `pname` and `version`: by default the name and version of the
#   top-level project(), which the lockfile records.
# - `cmakeFlags`: flags after the ones the lock run used, which come first
#   so that the build fetches nothing the lock run did not.
# - `fetchers`: fetchers that replace the ones the shared library's
#   fetchEntry uses, by name: `fetchurl`, `fetchgit`, `fetchhg`,
#   `fetchsvn` and `fetchcvs`. Each takes the arguments of the nixpkgs
#   fetcher of its name. They are the place for credentials and mirrors,
#   such as a fetchgit with a `netrcPhase` for a repository that needs a
#   login.
#
# Every download goes to the locked copy. FetchContent dependencies come
# from the initial cache that write-cache.sh writes, checkouts from the
# shims it installs, and every other download from mitm-cache, which
# its setup hook starts as the build's HTTP and HTTPS proxy, replaying the
# locked files.
#
# The lockfile names the outputs of the build, so the derivation's
# passthru knows them without building it:
#
# - `installed."<path>"` is each file the install writes, as a path in the
#   derivation's output, by its path relative to the install prefix.
# - `targets.<name>` is each installed target, with its CMake `type` and
#   the installed `files` of its artifacts, as paths in the output.
#
# After the install, the build checks that every file the lockfile names
# is in the output. `passthru.sources` is the sources of sources.nix.
{
  lib,
  stdenv,
  cmake,
  git,
  mercurial,
  subversion,
  cvs,
  mitm-cache,
  callPackage,
  # The shared library's functions (lib.purifier of the purifier flake),
  # which the package overlay passes.
  purifier,
}:
{
  src,
  lockFile ? src + "/cmake-purifier.lock.json",
  fetchers ? { },
  cmakeFlags ? [ ],
  nativeBuildInputs ? [ ],
  preConfigure ? "",
  postInstall ? "",
  passthru ? { },
  ...
}@args:
let
  sources = callPackage ./sources.nix { inherit lockFile fetchers purifier; };
  inherit (sources) lock;
  # A tool the build checks out with, for the commands its shim passes on;
  # empty when the lockfile has no checkouts of it.
  realTool =
    tool: package: name:
    if (lock."${tool}Checkouts" or [ ]) != [ ] then "${package}/bin/${name}" else "";
  projectVersion = lock.project.version or "";
  outputs =
    if lock.outputs == null then
      {
        files = [ ];
        targets = { };
      }
    else
      lock.outputs;
in
stdenv.mkDerivation (
  finalAttrs:
  removeAttrs args [
    "lockFile"
    "fetchers"
  ]
  // {
    pname = args.pname or lock.project.name;
    version = args.version or (if projectVersion == "" then "0" else projectVersion);
    inherit src;
    nativeBuildInputs = [
      cmake
      mitm-cache
    ]
    ++ nativeBuildInputs;
    mitmCache = "${sources.tree}/http";
    cmakeFlags = lock.cmakeFlags ++ cmakeFlags;
    preConfigure = ''
      ${lib.optionalString ((lock.definitionHash or "") != "") ''
        if [ "$(bash ${./definition-hash.sh} .)" != ${lib.escapeShellArg lock.definitionHash} ]; then
          echo "cmake-purifier: warning: a CMakeLists.txt or *.cmake file changed since the lockfile was written. If the build now downloads something new, it fails; run \`cmake-purifier lock\` to lock it." >&2
        fi
      ''}
      bash ${./write-cache.sh} ${sources.tree} "$NIX_BUILD_TOP/cmake-purifier/sources" "$NIX_BUILD_TOP/cmake-purifier/cache.cmake" \
        ${../../cmake}/CMakePurifierLocked.cmake ${./.} ${git}/bin/git \
        "${realTool "hg" mercurial "hg"}" "${
          realTool "svn" subversion "svn"
        }" "${realTool "cvs" cvs "cvs"}"
      cmakeFlagsArray+=(-C "$NIX_BUILD_TOP/cmake-purifier/cache.cmake")
    ''
    + preConfigure;
    lockedOutputs = lib.concatMapStrings (f: "${f}\n") outputs.files;
    passAsFile = [ "lockedOutputs" ];
    postInstall = postInstall + ''
      missing=0
      while IFS= read -r file; do
        if [ ! -e "$out/$file" ] && [ ! -L "$out/$file" ]; then
          echo "cmake-purifier: the lockfile names the output $file, which the install did not write. Run \`cmake-purifier lock\` again." >&2
          missing=1
        fi
      done < "$lockedOutputsPath"
      [ "$missing" = 0 ]
    '';
    passthru = passthru // {
      inherit sources;
      installed = lib.genAttrs outputs.files (file: "${finalAttrs.finalPackage}/${file}");
      targets = builtins.mapAttrs (
        _: target:
        target
        // {
          files = map (file: "${finalAttrs.finalPackage}/${file}") target.files;
        }
      ) outputs.targets;
    };
  }
)
