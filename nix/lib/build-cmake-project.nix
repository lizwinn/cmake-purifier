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
# - `fetchurl`: replaces the built-in fetcher of URL downloads, for
#   credentials or mirrors (see fetch.nix).
#
# `passthru.sources` is the sources of sources.nix.
{
  lib,
  stdenv,
  cmake,
  callPackage,
}:
{
  src,
  lockFile ? src + "/cmake-purifier.lock.json",
  fetchurl ? null,
  cmakeFlags ? [ ],
  nativeBuildInputs ? [ ],
  preConfigure ? "",
  passthru ? { },
  ...
}@args:
let
  sources = callPackage ./sources.nix { inherit lockFile fetchurl; };
  inherit (sources) lock;
  projectVersion = lock.project.version or "";
in
stdenv.mkDerivation (
  removeAttrs args [
    "lockFile"
    "fetchurl"
  ]
  // {
    pname = args.pname or lock.project.name;
    version = args.version or (if projectVersion == "" then "0" else projectVersion);
    inherit src;
    nativeBuildInputs = [ cmake ] ++ nativeBuildInputs;
    cmakeFlags = lock.cmakeFlags ++ cmakeFlags;
    preConfigure = ''
      bash ${./write-cache.sh} ${sources.tree} "$NIX_BUILD_TOP/cmake-purifier/sources" "$NIX_BUILD_TOP/cmake-purifier/cache.cmake" ${../../cmake/CMakePurifierLocked.cmake}
      cmakeFlagsArray+=(-C "$NIX_BUILD_TOP/cmake-purifier/cache.cmake")
    ''
    + preConfigure;
    passthru = passthru // {
      inherit sources;
    };
  }
)
