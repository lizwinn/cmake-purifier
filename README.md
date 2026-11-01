# cmake-purifier

A command and a Nix library that build a CMake project in the Nix sandbox
from a lockfile of everything its build downloads. CMake still configures
and builds the project. The lockfile records each file and git checkout
the build fetches, and the outputs the build installs, so Nix can build
the project, and knows its outputs, with no Nix files in the project
beyond the lockfile.

- **A lockfile.** `cmake-purifier lock` configures, builds and installs
  the project once with the network, and records every download, whatever
  CMake command makes it: `FetchContent`, `ExternalProject_Add()`,
  `file(DOWNLOAD)` at configure or build time, and wrappers on top of them
  such as CPM.cmake, from HTTP and HTTPS servers and from git, Mercurial,
  Subversion and CVS repositories. It writes `cmake-purifier.lock.json`.
- **Sandboxed builds.** `buildCMakeProject`, which the flake's overlay adds
  to a package set, builds and installs the project from its lockfile.
  Its `targets.<name>` and `installed."<path>"` name every output at
  evaluation time.
- **Offline interactive builds.** `cmake-purifier configure` and
  `cmake-purifier build` configure and build a build directory from the
  same lockfile, with nothing downloaded.

## Use

Lock the project, from its source directory:

```zsh
nix run github:nix-purifiers/cmake-purifier -- lock
```

The lock run needs the network and the compilers and libraries the build
needs, because it runs a real configure, build and install, in a scratch
directory. Arguments after `lock` go to the configure, and the lockfile
keeps them: every build of the lockfile passes them first, since options
such as `-DBUILD_TESTING=ON` decide what a build downloads and installs.

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
      app = pkgs.callPackage ./package.nix { };
    in
    {
      packages.${system}.default = app;
      # One app per installed executable, known from the lockfile alone.
      apps.${system}.greet = {
        type = "app";
        program = builtins.head app.targets.greet.files;
      };
    };
}
```

`buildCMakeProject` takes every argument of `stdenv.mkDerivation`, and
nixpkgs' CMake setup hook runs the build. `nix/lib/build-cmake-project.nix`
documents the arguments of its own: `lockFile`, `cmakeFlags` (after the
locked ones), and `fetchurl` (for credentials or mirrors).

To work on the project offline, configure and build a build directory
from the lockfile:

```zsh
nix run github:nix-purifiers/cmake-purifier -- configure -B build
nix run github:nix-purifiers/cmake-purifier -- build -B build
```

`configure` builds the locked downloads through Nix and keeps a GC root to
them in `build/cmake-purifier`. `build` runs `cmake --build`. A plain
`cmake --build build` works too, unless the build itself downloads files,
as `ExternalProject_Add()` with a URL does.

## How it works

### The lock run

`cmake-purifier lock` runs the configure, the build and an install into a
scratch prefix with three recorders:

- **mitmproxy**, as the HTTP and HTTPS proxy of CMake and everything it
  runs, with its certificate authority in `SSL_CERT_FILE`. It records every
  response by URL and SHA-256. When the user's environment names a proxy
  of its own, mitmproxy forwards to it.
- **Wrappers of git, hg, svn and cvs**, in `GIT_EXECUTABLE`,
  `HG_EXECUTABLE`, `Subversion_SVN_EXECUTABLE` and `CVS_EXECUTABLE`. Each
  logs every command CMake's modules run with its tool and passes it on,
  with the user's own proxy settings; svn gets them as `--config-option`
  arguments, since it reads no proxy variables. The logs show which
  repository each checkout came from and which ref it asked for.
- **A dependency provider**, injected through
  `CMAKE_PROJECT_TOP_LEVEL_INCLUDES`, which records each
  `FetchContent_MakeAvailable()` dependency by name and where FetchContent
  put it.

The lockfile then holds every file the build fetched over HTTP or HTTPS,
under the URL the build asked for, and every checkout at the revision the
build checked out. A git checkout is hashed with `nix-prefetch-git`, the
hash `fetchgit` checks. A Mercurial, Subversion or CVS checkout is hashed
by building the nixpkgs fetcher of the sandbox build (`fetchhg`,
`fetchsvn`, `fetchcvs`) with a wrong hash and reading the right one from
the error, so the hash is the one that build checks, keyword expansion
and time zone included. A CVS checkout without a tag or a date locks the
time of the lock run as its date. A redirect
counts as the file it leads to, and its target is left out, since such
targets are often signed URLs that expire. The install's manifest gives
the installed files, and CMake's File API gives the target each one
belongs to.

The lock run configures with `CMAKE_BUILD_TYPE=Release` and
`CMAKE_INSTALL_LIBDIR=lib`, as nixpkgs' CMake setup hook does, so that the
recorded outputs are the outputs of the sandbox build. A
`-DCMAKE_BUILD_TYPE` among the arguments of `lock` replaces the first, and
the lockfile keeps it for the sandbox build too. `--no-build` stops the
lock run after the configure, for a project whose build cannot run on the
machine that locks; the lockfile then records no outputs, and misses
anything the build itself downloads.

### A build from the lockfile

The sandbox build and `cmake-purifier configure` give every download its
locked copy:

- FetchContent dependencies come from `FETCHCONTENT_SOURCE_DIR_<NAME>`,
  which an initial cache sets for each, with
  `FETCHCONTENT_FULLY_DISCONNECTED`. The sources are copied into the build
  directory, because some projects write into their dependencies' source
  trees.
- Git, Mercurial, Subversion and CVS checkouts go to shims, which the
  initial cache names in `GIT_EXECUTABLE`, `HG_EXECUTABLE`,
  `Subversion_SVN_EXECUTABLE` and `CVS_EXECUTABLE`. They answer the
  checkout and update steps of `ExternalProject_Add()` and of FetchContent
  from the locked checkout of the repository and ref.
- Every other download goes to mitm-cache, as the HTTP and HTTPS proxy,
  which replays the locked files. In the sandbox its setup hook starts it,
  and `cmake-purifier configure` and `build` start it around their CMake
  run.

A second dependency provider checks every `FetchContent_MakeAvailable()`
call, and the shims check every checkout. A dependency the
lockfile does not hold stops the build with a hint to run
`cmake-purifier lock`. After the install, the sandbox build checks that
every output the lockfile names is in the package.

Both kinds of build set `FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER`, as the
lock run does, so a dependency declared with `FIND_PACKAGE_ARGS` comes from
its locked source rather than from whatever `find_package()` finds on the
machine that runs the lock.

## Limits

Each of these follows from what a build from a lockfile can know.

- **A download by a program that ignores the proxy variables or
  `SSL_CERT_FILE`.** The recording and the replay both work as the proxy
  of everything the build runs. A program that opens its own connections,
  or trusts only a certificate store of its own, reaches neither. CMake,
  curl, git and most HTTP libraries honour both variables.
- **Requests other than GET.** A POST or another request with effects on
  the server has no response that is a fixed file, so the lockfile cannot
  hold it.
- **Two URLs that differ only in their query.** mitm-cache replays a URL
  from the path of its file, which carries no query, so the lock run
  refuses such a pair with an error that names both URLs.
- **Repositories reached over SSH, or a CVS server that needs a login.**
  The sandbox has no credentials, so the fetchers cannot fetch from them
  there. Such a dependency can name its repository with an anonymous HTTPS
  or pserver URL instead.
- **Version-control commands other than the checkout steps, on a locked
  checkout.** A locked checkout holds the files of its revision and no
  history, since the fetchers store only the files, which keeps their
  hashes reproducible. The shims answer the commands of a checkout and of
  its update steps, `git rev-parse`, and `git describe` (with the ref the
  build asked for). Any other command on a locked checkout, such as
  `git log` in a dependency's CMakeLists.txt, fails with a message that
  names it.
- **A dependency pinned to a branch** locks the commit the branch pointed
  at during the lock run, since a branch has no other commit to give.
- **A `GIT_SUBMODULES` list** locks every submodule of the repository,
  since `fetchgit` fetches all of them or none.

cmake-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier), which was
inspired by nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo).
