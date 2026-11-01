# SPDX-License-Identifier: MIT
#
# The Nix library on a hand-written lockfile, with fetchers that download
# nothing: one archive with a single top-level directory, one file that
# is not extracted, and one git checkout whose name has upper and lower
# case letters.
{ pkgs }:
let
  inherit (pkgs) lib;

  lockOf = version: {
    inherit version;
    project = {
      name = "p";
      version = "";
    };
    cmakeFlags = [ "-DX=1" ];
    artifacts = [
      {
        path = "archive/archive-1.0.tar.gz";
        url = "https://example.invalid/archive-1.0.tar.gz";
        hash = lib.fakeHash;
      }
      {
        path = "header/one.h";
        url = "https://example.invalid/one.h";
        hash = lib.fakeHash;
      }
      {
        path = "Git_Dep";
        git = {
          url = "https://example.invalid/dep.git";
          rev = "0123456789abcdef0123456789abcdef01234567";
          submodules = false;
        };
        hash = lib.fakeHash;
      }
    ];
    dependencies = [
      {
        name = "archive";
        artifact = "archive/archive-1.0.tar.gz";
        extract = true;
      }
      {
        name = "header";
        artifact = "header/one.h";
        extract = false;
      }
      {
        name = "Git_Dep";
        artifact = "Git_Dep";
      }
    ];
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
  fetchurl = { url, ... }: if lib.hasSuffix ".tar.gz" url then archive else header;
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
  bash ${../nix/lib/write-cache.sh} ${sources.tree} $TMPDIR/copies $TMPDIR/cache.cmake /provider.cmake
  cat $TMPDIR/cache.cmake

  # The archive's single top-level directory became the source tree, and
  # the copy is writable.
  [ "$(cat $TMPDIR/copies/archive/sub/file)" = inside ]
  [ -w $TMPDIR/copies/archive/sub/file ]
  # The file that is not extracted keeps its name.
  [ "$(cat $TMPDIR/copies/header/one.h)" = "// one" ]
  [ "$(cat $TMPDIR/copies/Git_Dep/REV)" = 0123456789abcdef0123456789abcdef01234567 ]

  grep -qx "set(FETCHCONTENT_SOURCE_DIR_ARCHIVE \"$TMPDIR/copies/archive\" CACHE PATH \"\" FORCE)" $TMPDIR/cache.cmake
  grep -qx "set(FETCHCONTENT_SOURCE_DIR_GIT_DEP \"$TMPDIR/copies/Git_Dep\" CACHE PATH \"\" FORCE)" $TMPDIR/cache.cmake
  grep -qx 'set(FETCHCONTENT_FULLY_DISCONNECTED ON CACHE BOOL "" FORCE)' $TMPDIR/cache.cmake
  grep -qx 'set(CMAKE_PROJECT_TOP_LEVEL_INCLUDES "/provider.cmake" CACHE STRING "" FORCE)' $TMPDIR/cache.cmake
  grep -qx 'set(CMAKE_PURIFIER_LOCKED "Git_Dep;archive;header" CACHE INTERNAL "")' $TMPDIR/cache.cmake

  # A second run with the same sources keeps the copies.
  touch $TMPDIR/copies/archive/marker
  bash ${../nix/lib/write-cache.sh} ${sources.tree} $TMPDIR/copies $TMPDIR/cache.cmake /provider.cmake
  [ -e $TMPDIR/copies/archive/marker ]

  touch $out
''
