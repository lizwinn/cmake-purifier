# Product

cmake-purifier is one of the nix-purifiers: a plugin and a Nix library per
build tool, which record the files the tool wants to download in a
lockfile, so that Nix can build the project in its sandbox without
generated Nix files in the project.

CMake has no single download channel, so the lock run records downloads
at the channels every CMake download goes through: HTTP and HTTPS,
through a recording proxy, and the version-control tools, through
`GIT_EXECUTABLE`, `HG_EXECUTABLE`, `Subversion_SVN_EXECUTABLE` and
`CVS_EXECUTABLE`. A
dependency provider adds which FetchContent dependency each download
belongs to. CMake 3.24 added dependency providers and
`CMAKE_PROJECT_TOP_LEVEL_INCLUDES`, which inject one without edits to the
project, so the purifier needs CMake 3.24 or newer. The README describes
the lock run, the builds from the lockfile, and the limits.

## Layout

- `cmake/`: the dependency providers of the lock run
  (`CMakePurifierLock.cmake`) and of builds from the lockfile
  (`CMakePurifierLocked.cmake`).
- `lock/`: the lock run's recorder addon for mitmproxy (`record.py`) and
  the script that writes the lockfile from the records (`assemble.py`).
- `nix/lib/`: the Nix library. `lock.nix` reads the lockfile and
  documents its format, `fetch.nix` fetches file downloads, `sources.nix`
  makes the tree a build from the lockfile reads, `write-cache.sh` writes
  its initial cache, `git-shim.sh` and `vcs-shim.sh` serve its
  checkouts, `fetchers.nix` holds the Mercurial, Subversion and CVS
  fetchers of the sandbox build, `prefetch-vcs.nix` runs them for the
  lock run's hashes, and `build-cmake-project.nix` is
  `buildCMakeProject`.
- `pkgs/cmake-purifier/`: the command.
- `configs/`, `lib-overlays/`, `pkg-overlays/`: the caisson flake layout.
- `tests/`: the checks, the fixtures and the scripts around them.

## Lockfile

`nix/lib/lock.nix` documents the format. Its download entries are those
of the shared nix-purifiers library: a file is
`{ path, url, mirrors, hash }`, and a git checkout is
`{ path, git = { url, rev, submodules }, hash }`. A file's path is the
path mitm-cache replays it from. An archive is a file entry, which
`sources.nix` unpacks with CMake's own extraction rule: the archive's
single top-level directory is stripped when there is exactly one.
