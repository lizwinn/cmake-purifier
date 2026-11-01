# cmake-purifier

A command and a Nix library that build a CMake project in the Nix sandbox
from a lockfile of everything its build downloads. CMake still configures
and builds the project. `cmake-purifier lock` configures, builds and
installs the project once with the network and records every download,
whatever CMake command makes it: `FetchContent`, `ExternalProject_Add()`,
`file(DOWNLOAD)` at configure or build time, and wrappers on top of them
such as CPM.cmake. It writes `cmake-purifier.lock.json`, and Nix builds
the project from it with no Nix files in the project beyond the lockfile.

## Quickstart

Lock the project, from its source directory, in a shell with the
command, CMake and a C and C++ compiler:

```zsh
nix develop github:nix-purifiers/cmake-purifier
cmake-purifier lock
```

The lock run needs the network, and the compilers and libraries the build
needs, because it runs a real configure, build and install in a scratch
directory. A project that needs more than the shell above, such as
OpenSSL for `find_package(OpenSSL)`, locks in its own development shell
with `cmake-purifier.packages.${system}.default` added to its packages.
That shell is a `mkShell` with CMake among its inputs, whose setup hook
adds the libraries to `CMAKE_PREFIX_PATH`, where `find_package()` looks.
Arguments after `lock` go to the configure, and the lockfile keeps them:
every build from the lockfile passes them first, since options such as
`-DBUILD_TESTING=ON` decide what a build downloads and installs.
`CMAKE_BUILD_PARALLEL_LEVEL` sets the number of jobs of the lock run's
build, which is the number of cores by default.

Commit `cmake-purifier.lock.json`. The flake's `overlays.default` adds
one attribute to a package set, the scope `cmake-purifier`. The scope
holds the builder `buildCMakeProject` and the command, and a package takes
the scope by name:

```nix
# package.nix
{ cmake-purifier, zlib }:
cmake-purifier.buildCMakeProject {
  src = ./.;
  # Libraries that find_package() looks for come from nixpkgs as usual.
  buildInputs = [ zlib ];
}
```

```nix
# flake.nix
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
      project = pkgs.callPackage ./package.nix { };
    in
    {
      # The package is named after the top-level project().
      packages.${system}.default = project.packages.my-project;
      checks.${system}.tests = project.tests;
    };
}
```

The result has four attributes, each known at evaluation time:

- `packages.<name>` is the installed project, under the name of the
  top-level `project()`. Its `targets.<name>` and `installed."<path>"`
  name every output from the lockfile, without a build.
- `tests` is the same build with ctest run after it. The lock run does not
  run the tests, so the lockfile holds nothing that the tests download,
  and ctest runs without the replaying proxy: a test sees the sandbox
  without a network, as it expects of a host that does not resolve.
- `release` is a directory with the installed project as one
  reproducible tarball, which `cmake-purifier publish <tag> <installable>`
  uploads to a GitHub release with `gh`.
- `fetches` is the list of downloads, as entries of the shared library
  [purifier](https://github.com/nix-purifiers/purifier), for SBOM,
  license and vulnerability tools.

`buildCMakeProject` takes every argument of `stdenv.mkDerivation`, and
nixpkgs' CMake setup hook runs the build. `nix/lib/build-cmake-project.nix`
documents the arguments of its own: `src`, `lockFile`, `cmakeFlags`
(after the locked ones), and `fetchers`. It takes the packages it builds
with by name, so `cmake-purifier.buildCMakeProject.override` replaces
them, and `pkgs.cmake-purifier.overrideScope` replaces what the scope
shares. A lockfile kept
outside `src`, as `lockFile`, is the one the build reads, so a packaging
flake can lock a project it does not change. Every command takes it as
`--lockfile <path>` or from the environment variable
`CMAKE_PURIFIER_LOCKFILE`, which the packaging flake's development shell
can set to the path it passes as `lockFile`.

`lib.cmake-purifier.readLock { src, lockFile ? … }` reads the lockfile
into the shape that every nix-purifier shares,
`{ purifier, entries, outputs, problems }`, for tools that read the locks
of every ecosystem, such as an SBOM generator.

## Development loop

Prefetch the locked downloads once, then work with CMake's own commands
on the initial cache that the prefetch writes:

```zsh
cmake-purifier prefetch
cmake -B build -C .cmake-purifier/initial-cache.txt
cmake --build build
ctest --test-dir build
```

The initial cache points FetchContent at copies of the locked sources and
git, hg, svn and cvs at the locked checkouts, and sets the configure
arguments of the lock run. A build directory configured with it keeps
those settings, so later runs of `cmake --build build` reconfigure with
them too.

A project that downloads files outside FetchContent, with `file(DOWNLOAD)`
or `ExternalProject_Add()` with a URL, runs the configure and the build
under `cmake-purifier replay --`, which starts mitm-cache as their HTTP
and HTTPS proxy, replaying the locked files:

```zsh
cmake-purifier replay -- cmake -B build -C .cmake-purifier/initial-cache.txt
cmake-purifier replay -- cmake --build build
```

`prefetch` says when a project needs this. CMake makes these downloads
with its own HTTP client, some of them in `cmake -P` scripts that the
build runs, so only a proxy reaches them.

To add or upgrade a dependency, edit its `FetchContent_Declare()` (or its
`ExternalProject_Add()`, or its CPM.cmake call), run `cmake-purifier lock`
and `cmake-purifier prefetch` again, and configure again. A relock takes
about as long as a clean configure and build of the project.

`lock` keeps what the lockfile already resolved. A checkout whose ref
moves, such as a `GIT_TAG` that names a branch, a Subversion checkout at
HEAD, or a CVS checkout without a tag, stays at its locked revision.
`cmake-purifier update` moves such checkouts to where their refs point
now, and relocks with the configure arguments of the lockfile.
`cmake-purifier update <name>...` moves only the named FetchContent
dependencies or repositories.

## Working offline

`cmake-purifier prefetch` builds every download of the lockfile through
Nix and keeps it alive with a garbage-collector root,
`.cmake-purifier/sources-root`, beside the lockfile. After a prefetch, the
configure, the build, ctest and the editor work with the network cut off.
The directory `.cmake-purifier/` ignores itself in git.

`prefetch` realizes what the lockfile lists, and a CMake lockfile lists
only the project's downloads. The compilers, CMake itself and clangd come
from the development shell, which `nix develop` keeps in the store once
it has built.

## Editor

The initial cache sets `CMAKE_EXPORT_COMPILE_COMMANDS`, so the configure
writes `build/compile_commands.json`. clangd and other tools that read it
find every dependency's headers in the prefetched sources, offline. The
development shell of this flake has clangd; a project's own shell takes
`clang-tools` from nixpkgs.

## Troubleshooting

Each of these stops the command, the evaluation or the build with a
message that names the problem and the command that fixes it:

- **A dependency that the lockfile does not hold**, such as a new
  `FetchContent_Declare()`, a new ExternalProject repository or ref, or a
  new git clone: "the build declares the dependency …, which the lockfile
  does not hold. Run `cmake-purifier lock`".
- **A dependency whose declaration changed** without a change to the
  CMake files, such as a version from a `-D` argument: "the dependency …
  now declares the download …, but the lockfile holds …. Run
  `cmake-purifier lock`".
- **A lockfile older than the project.** The lockfile records a hash of
  every `CMakeLists.txt` and `*.cmake` file. When they hash differently,
  `prefetch`, the Nix evaluation (for a `src` that is a path) and the
  sandbox build stop: "… is older than the project … Run
  `cmake-purifier lock`".
- **A lockfile that was edited by hand.** The lockfile records the hash of
  its own content, and an edit, such as a changed hash of a download,
  stops the evaluation: "… was edited: its content no longer matches its
  contentHash".
- **An output that the sandbox build did not install**: "the lockfile
  names the output …, which the install did not write". The lock run
  builds with every program on the `PATH` of the shell, and `nix develop`
  keeps the system `PATH` after the one of the shell. A build that does
  more when it finds a program installs more in the lock run than in the
  sandbox. The build of curl is one such build: it writes its man pages
  when it finds Perl. Add the program to the inputs of the package and of
  the shell, and run `cmake-purifier lock` again.
- **A lockfile that is not valid JSON, or not a cmake-purifier lockfile**:
  the message names the file, and says to restore it from version control
  or run `cmake-purifier lock`.

## Supported language repositories

The lock run records downloads from HTTP and HTTPS servers, through
mitmproxy as the proxy of CMake and everything it runs, and from git,
Mercurial, Subversion and CVS repositories, through wrappers that CMake
finds as its `GIT_EXECUTABLE`, `HG_EXECUTABLE`,
`Subversion_SVN_EXECUTABLE` and `CVS_EXECUTABLE`. A checkout that names a
branch locks the commit the branch pointed at, and the next lock moves it.
A git repository cloned over SSH is locked by the HTTPS URL of the same
host, since the sandbox has no SSH credentials. `docs/development/product.md`
describes the lock run and the builds from the lockfile in full.

These are refused or unsupported:

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
- **A repository that needs a login**, with the default fetchers. The
  sandbox has no credentials. `buildCMakeProject` takes fetchers that
  have them in `fetchers`, such as nixpkgs' fetchgit with a `netrcPhase`
  as `fetchers.fetchgit`; a company mirror goes in `fetchers.fetchurl`.
- **CVS on aarch64-linux.** nixpkgs' cvs does not run on aarch64-linux, so
  a project with a CVS checkout locks and builds on x86_64-linux only.
- **Version-control commands other than the checkout steps, on a locked
  checkout.** A locked checkout holds the files of its revision and no
  history, which keeps its hash reproducible. The shims answer the
  commands of a checkout and of its update steps, `git rev-parse`, and
  `git describe`. Any other command on a locked checkout, such as
  `git log` in a dependency's CMakeLists.txt, fails with a message that
  names it.

## Examples

### cpr

[cpr](https://github.com/libcpr/cpr) is a C++ HTTP library whose build
takes curl, zlib-ng, googletest and mongoose from FetchContent archives,
and libpsl from a FetchContent git checkout that it builds with meson. It
finds OpenSSL with `find_package()`, so its development shell has OpenSSL
besides the tools of its build. A `flake.nix` in a checkout of cpr:

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
      # curl's build writes its man pages when it finds Perl.
      nativeBuildInputs = [ pkgs.perl pkgs.pkg-config pkgs.meson pkgs.ninja pkgs.python3 ];
      buildInputs = [ pkgs.openssl ];
      cpr = pkgs.cmake-purifier.buildCMakeProject {
        inherit nativeBuildInputs buildInputs;
        src = ./.;
        # cpr's test suites each start a server on the same port.
        enableParallelChecking = false;
      };
    in
    {
      packages.${system}.default = cpr.packages.cpr;
      checks.${system}.tests = cpr.tests;
      devShells.${system}.default = pkgs.mkShell {
        inherit buildInputs;
        nativeBuildInputs = nativeBuildInputs ++ [
          pkgs.cmake
          pkgs.clang-tools
          cmake-purifier.packages.${system}.default
        ];
      };
    };
}
```

Lock it with its tests, work on it, and build it with Nix:

```zsh
nix develop
cmake-purifier lock -DCPR_BUILD_TESTS=ON
cmake-purifier prefetch
cmake -B build -C .cmake-purifier/initial-cache.txt
cmake --build build
ctest --test-dir build
nix build
nix flake check
```

cpr's tests need no network: they talk to a server that the tests start
on the machine itself.

## Credits

cmake-purifier follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier), which was
inspired by nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo).
