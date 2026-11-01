# SPDX-License-Identifier: MIT
#
# Reads a cmake-purifier lock file (written by `cmake-purifier lock`).
#
# The file holds two lists. `artifacts` is every download of the build.
# An artifact is either a file, `{ path, url, hash }` with the SRI hash of
# the file, or a git checkout, `{ path, git = { url, rev, submodules },
# hash }` with the SRI NAR hash of the checkout as fetchgit makes it.
# `path` is an opaque relative name: `<name>/<file name>` for a file and
# `<name>` for a checkout, where <name> is the FetchContent name.
#
# `dependencies` is every FetchContent dependency, by its FetchContent
# `name`. Its `artifact` is the path of its download. A dependency on a
# file also says whether FetchContent `extract`s it.
#
# The two kinds of artifact are the download entries of the shared
# nix-purifiers library, where `git.submodules` is required.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a file name. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_".
  storeName =
    fileName:
    let
      # builtins.split alternates the text between matches with a list per
      # match.
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (
          builtins.split "[^A-Za-z0-9+._?=-]" fileName
        )
      );
      undotted = builtins.head (builtins.match "\\.*(.*)" replaced);
      nonEmpty = if undotted == "" then "file" else undotted;
    in
    builtins.substring 0 200 nonEmpty;
in
assert
  lock.version == supportedVersion
  || throw "cmake-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `cmake-purifier lock` with the cmake-purifier version that provides this library.";
lock
// {
  inherit storeName;

  # The fetch name of an artifact: the last component of its path, made a
  # valid store name.
  artifactName = artifact: storeName (baseNameOf artifact.path);

  artifactsByPath = builtins.listToAttrs (
    map (a: {
      name = a.path;
      value = a;
    }) lock.artifacts
  );
}
