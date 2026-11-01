# SPDX-License-Identifier: MIT
#
# Reads a cmake-purifier lock file (written by `cmake-purifier lock`).
#
# The file holds three lists.
#
# `artifacts` is every download of the build. An artifact is either a
# file, `{ path, url, mirrors, hash }` with the SRI hash of the file and a
# list of further URLs that serve the same bytes, or a git
# checkout, `{ path, git = { url, rev, submodules, leaveDotGit,
# commitObject }, hash }` with the SRI NAR hash of the checkout as fetchgit
# makes it, where cmake-purifier writes `leaveDotGit = false` and
# `commitObject = null`, since the git shim needs no `.git`, or a checkout from another
# version-control system: `hg = { url, rev, subrepos }`,
# `svn = { url, rev, ignoreExternals, ignoreKeywords }`, or
# `cvs = { cvsRoot, module, tag, date }` with one of `tag` and `date` null,
# each with the hash of the nixpkgs fetcher's output. These are the
# download entries of the shared nix-purifiers library. A file's `path` is
# `<scheme>/<host>/<path>` of its URL, where mitm-cache replays it; a
# checkout's `path` starts with its tool and ends with its revision.
#
# `dependencies` is every FetchContent_MakeAvailable() dependency, by its
# FetchContent `name`. Its `artifact` is the path of its download. A
# dependency on a file also says whether FetchContent `extract`s it.
#
# `gitCheckouts` is every git checkout the build makes, by repository
# `url` and the `ref` the build checks out, with the path of its
# `artifact`. `hgCheckouts`, `svnCheckouts` and `cvsCheckouts` are the
# checkouts of the other tools, by `repo` and `ref` as vcs-shim.sh reads
# them, with the path of their `artifact`.
#
# `outputs` is what the install writes: `files`, every installed file by
# its path relative to the install prefix, and `targets`, each installed
# target by name with its CMake `type` and the installed `files` of its
# artifacts. It is null when the lock run did not build.
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
