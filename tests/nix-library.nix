# SPDX-License-Identifier: MIT
#
# The Nix library on a hand-written lockfile, with fetchers that download
# nothing: an archive with a single top-level directory and a file that is
# not extracted, both FetchContent dependencies; a file only the proxy
# serves; and a git checkout, which a FetchContent dependency whose name
# has upper and lower case letters uses, and which the git shim serves.
{ pkgs }:
let
  inherit (pkgs) lib;

  rev = "0123456789abcdef0123456789abcdef01234567";
  checkout = "git/https/example.invalid/dep.git/${rev}";

  lockOf = version: {
    inherit version;
    project = {
      name = "p";
      version = "";
    };
    cmakeFlags = [ "-DX=1" ];
    artifacts = [
      {
        path = "https/example.invalid/archive-1.0.tar.gz";
        url = "https://example.invalid/archive-1.0.tar.gz";
        mirrors = [ ];
        hash = lib.fakeHash;
      }
      {
        path = "https/example.invalid/one.h";
        url = "https://example.invalid/one.h";
        mirrors = [ ];
        hash = lib.fakeHash;
      }
      {
        path = "https/example.invalid/data/served.txt";
        url = "https://example.invalid/data/served.txt";
        mirrors = [ ];
        hash = lib.fakeHash;
      }
      {
        path = checkout;
        git = {
          url = "https://example.invalid/dep.git";
          inherit rev;
          submodules = false;
          leaveDotGit = false;
          commitObject = null;
        };
        hash = lib.fakeHash;
      }
    ];
    dependencies = [
      {
        name = "archive";
        artifact = "https/example.invalid/archive-1.0.tar.gz";
        extract = true;
      }
      {
        name = "header";
        artifact = "https/example.invalid/one.h";
        extract = false;
      }
      {
        name = "Git_Dep";
        artifact = checkout;
      }
    ];
    gitCheckouts = [
      {
        url = "https://example.invalid/dep.git";
        ref = "v1.0";
        artifact = checkout;
      }
    ];
    outputs = null;
  };

  # builtins.toFile, so that reading the lockfile needs no build.
  lockFile = builtins.toFile "cmake-purifier.lock.json" (
    builtins.toJSON (lockOf (import ../nix/lib/lock-version.nix))
  );
  otherVersion = builtins.toFile "cmake-purifier.lock.json" (builtins.toJSON (lockOf 0));

  archive = pkgs.runCommand "archive-1.0.tar.gz" { } ''
    mkdir -p tree/archive-1.0/sub
    echo inside > tree/archive-1.0/sub/file
    tar -C tree -czf $out archive-1.0
  '';
  header = pkgs.writeText "one.h" "// one\n";
  served = pkgs.writeText "served.txt" "served\n";
  fetchurl =
    { urls, ... }:
    let
      url = builtins.head urls;
    in
    if lib.hasSuffix ".tar.gz" url then
      archive
    else if lib.hasSuffix ".h" url then
      header
    else
      served;
  fetchgit =
    { rev, fetchSubmodules, ... }:
    assert !fetchSubmodules;
    pkgs.runCommand "git-dep" { } ''
      mkdir $out
      echo ${rev} > $out/REV
    '';

  sources = pkgs.callPackage ../nix/lib/sources.nix { inherit lockFile fetchurl fetchgit; };
in
assert
  !(builtins.tryEval (import ../nix/lib/lock.nix { lockFile = otherVersion; })).success
  || throw "lock.nix read a lockfile of another format version";
assert
  builtins.attrNames sources.byName == [
    "Git_Dep"
    "archive"
    "header"
  ];
pkgs.runCommand "nix-library" { } ''
  tree=${sources.tree}
  bash ${../nix/lib/write-cache.sh} $tree $TMPDIR/copies $TMPDIR/cp/cache.cmake /provider.cmake \
    ${../nix/lib} ${pkgs.git}/bin/git "" "" ""
  cat $TMPDIR/cp/cache.cmake

  # The archive's single top-level directory became the source tree, and
  # the copy is writable.
  [ "$(cat $TMPDIR/copies/archive/sub/file)" = inside ]
  [ -w $TMPDIR/copies/archive/sub/file ]
  # The file that is not extracted keeps its name.
  [ "$(cat $TMPDIR/copies/header/one.h)" = "// one" ]
  [ "$(cat $TMPDIR/copies/Git_Dep/REV)" = ${rev} ]
  # Every file is in the replay tree at its path.
  [ "$(cat $tree/http/https/example.invalid/data/served.txt)" = served ]

  grep -qx "set(FETCHCONTENT_SOURCE_DIR_ARCHIVE \"$TMPDIR/copies/archive\" CACHE PATH \"\" FORCE)" $TMPDIR/cp/cache.cmake
  grep -qx "set(FETCHCONTENT_SOURCE_DIR_GIT_DEP \"$TMPDIR/copies/Git_Dep\" CACHE PATH \"\" FORCE)" $TMPDIR/cp/cache.cmake
  grep -qx 'set(FETCHCONTENT_FULLY_DISCONNECTED ON CACHE BOOL "" FORCE)' $TMPDIR/cp/cache.cmake
  grep -qx 'set(CMAKE_PROJECT_TOP_LEVEL_INCLUDES "/provider.cmake" CACHE STRING "" FORCE)' $TMPDIR/cp/cache.cmake
  grep -qx 'set(CMAKE_PURIFIER_LOCKED "Git_Dep;archive;header" CACHE INTERNAL "")' $TMPDIR/cp/cache.cmake
  grep -qx "set(GIT_EXECUTABLE \"$TMPDIR/cp/git\" CACHE FILEPATH \"\" FORCE)" $TMPDIR/cp/cache.cmake

  # The git shim answers ExternalProject's clone, checkout and update steps
  # from the locked checkout.
  git=$TMPDIR/cp/git
  mkdir $TMPDIR/work
  (cd $TMPDIR/work && $git clone --depth 1 https://example.invalid/dep.git dep-src)
  (cd $TMPDIR/work/dep-src && $git checkout v1.0 --)
  [ "$(cat $TMPDIR/work/dep-src/REV)" = ${rev} ]
  [ -w $TMPDIR/work/dep-src/REV ]
  (cd $TMPDIR/work/dep-src && $git submodule update --recursive --init)
  [ "$(cd $TMPDIR/work/dep-src && $git --git-dir=.git rev-parse 'v1.0^0')" = ${rev} ]
  ! (cd $TMPDIR/work/dep-src && $git --git-dir=.git show-ref v1.0)
  [ "$(cd $TMPDIR/work/dep-src && $git describe --tags)" = v1.0 ]
  # A repository or ref the lockfile does not hold stops with the hint.
  ! (cd $TMPDIR/work && $git clone https://example.invalid/other.git other 2> err)
  grep -q 'which the lockfile does not hold' $TMPDIR/work/err
  ! (cd $TMPDIR/work/dep-src && $git checkout v2.0 2> $TMPDIR/work/err2)
  grep -q 'v2.0 of https://example.invalid/dep.git, which the lockfile does not hold' $TMPDIR/work/err2
  # Commands outside a locked checkout go to the real git.
  $git --version | grep -q '^git version'

  # A second run with the same sources keeps the copies.
  touch $TMPDIR/copies/archive/marker
  bash ${../nix/lib/write-cache.sh} $tree $TMPDIR/copies $TMPDIR/cp/cache.cmake /provider.cmake \
    ${../nix/lib} ${pkgs.git}/bin/git "" "" ""
  [ -e $TMPDIR/copies/archive/marker ]

  touch $out
''
