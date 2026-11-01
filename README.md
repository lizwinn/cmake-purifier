# cmake-purifier

A command and a Nix library that build a CMake project in the Nix sandbox
from a lockfile of its `FetchContent` downloads. CMake still configures
and builds the project. The lockfile records every file and git checkout
the build fetches, and Nix provides them, so the project needs no Nix
files of its own beyond the lockfile.

- **A lockfile.** `cmake-purifier lock` configures the project once with a
  CMake dependency provider that sees every `FetchContent_MakeAvailable()`
  call, at every level of the build. It writes
  `cmake-purifier.lock.json`, with each URL download by its URL and
  SHA-256, and each git dependency by its repository, commit and the hash
  `fetchgit` checks. Git tags and branches are resolved to commits.
- **Sandboxed builds.** `buildCMakeProject`, which the flake's overlay adds
  to a package set, builds and installs the project from its lockfile. The
  package's name and version come from the top-level `project()`.
- **Offline interactive builds.** `cmake-purifier configure -B build` runs
  `cmake` on the locked sources. Everything after it, `cmake --build` and
  `ctest` included, is plain CMake.

## Use

Lock the project, from its source directory:

```zsh
nix run github:nix-purifiers/cmake-purifier -- lock
```

The lock run needs the network and a working compiler, because it runs a
real configure. Arguments after `lock` go to that configure, and the
lockfile keeps them: every build of the lockfile passes them first, since
options such as `-DBUILD_TESTING=ON` decide which dependencies a build
declares.

Commit `cmake-purifier.lock.json`. The flake's `overlays.default` adds
`buildCMakeProject` to a package set:

```nix
# package.nix
{ buildCMakeProject, zlib }:
buildCMakeProject {
  src = ./.;
  # Libraries that find_package() looks for come from nixpkgs as usual.
  buildInputs = [ zlib ];
}
```

```nix
{
  inputs.cmake-purifier.url = "github:nix-purifiers/cmake-purifier";
  inputs.nixpkgs.follows = "cmake-purifier/nixpkgs";

  outputs = { nixpkgs, cmake-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ cmake-purifier.overlays.default ];
      };
    in
    {
      packages.${system}.default = pkgs.callPackage ./package.nix { };
    };
}
```

`buildCMakeProject` takes every argument of `stdenv.mkDerivation`, and
nixpkgs' CMake setup hook runs the build. `nix/lib/build-cmake-project.nix`
documents the arguments of its own: `lockFile`, `cmakeFlags` (after the
locked ones), and `fetchurl` (for credentials or mirrors).

To work on the project offline, configure a build directory from the
lockfile:

```zsh
nix run github:nix-purifiers/cmake-purifier -- configure -B build
cmake --build build
```

`configure` builds the locked sources through Nix, keeps a GC root to
them in `build/cmake-purifier`, and copies them into the build directory,
because some projects write into their dependencies' source trees. It
passes CMake an initial cache that points FetchContent at the copies.

## How a build reads the lockfile

FetchContent takes the source of a dependency from
`FETCHCONTENT_SOURCE_DIR_<NAME>` when that variable is set, and downloads
nothing for it. Both the sandbox build and `configure` set it for every
locked dependency, along with `FETCHCONTENT_FULLY_DISCONNECTED`. A second
dependency provider checks every `FetchContent_MakeAvailable()` call
against the lockfile. A dependency the lockfile does not hold stops the
configure with a hint to run `cmake-purifier lock`.

Both runs set `FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER`, so a dependency
declared with `FIND_PACKAGE_ARGS` comes from its locked source, rather than
from whatever `find_package()` finds on the machine that runs the lock.

## Limits

- Only downloads made through `FetchContent_MakeAvailable()` are locked.
  `ExternalProject_Add()`, `file(DOWNLOAD)` and direct
  `FetchContent_Populate()` calls bypass the dependency provider. A build
  that uses them fails in the sandbox, which has no network.
- A `GIT_SUBMODULES` list locks every submodule of the repository, because
  `fetchgit` fetches all of them or none.
- The lock run uses the commit FetchContent checked out. A dependency
  pinned to a branch locks the branch's head at the time of the lock run.

The purifier idea comes from
[cargo (libnix)](https://github.com/nixcloud/cargo) by nixcloud, by way of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier).
