# Product

cmake-purifier is one of the nix-purifiers: a plugin and a Nix library per
build tool, which record the files the tool wants to download in a
lockfile, so that Nix can build the project in its sandbox without
generated Nix files in the project.

For CMake, the plugin is a pair of dependency providers
(`cmake/CMakePurifierLock.cmake` for the lock run,
`cmake/CMakePurifierLocked.cmake` for builds from the lockfile), and the
command `cmake-purifier` that runs them. CMake 3.24 added dependency
providers and `CMAKE_PROJECT_TOP_LEVEL_INCLUDES`, which inject them
without edits to the project, so the purifier needs CMake 3.24 or newer.

## Layout

- `cmake/`: the two dependency providers.
- `nix/lib/`: the Nix library. `lock.nix` reads the lockfile,
  `fetch.nix` fetches file downloads, `sources.nix` turns each dependency
  into its source tree, `write-cache.sh` writes the initial cache, and
  `build-cmake-project.nix` is `buildCMakeProject`.
- `pkgs/cmake-purifier/`: the command.
- `configs/`, `lib-overlays/`, `pkg-overlays/`: the caisson flake layout.
- `tests/`: the checks, the fixture and the scripts around them.

## Lockfile

`nix/lib/lock.nix` documents the format. Its download entries are those
of the shared nix-purifiers library: a file is `{ path, url, hash }`, and a
git checkout is `{ path, git = { url, rev, submodules }, hash }`. An
archive is a file entry, which `sources.nix` unpacks with CMake's own
extraction rule: the archive's single top-level directory is stripped
when there is exactly one.
