# Testing

The tests come in three layers.

1. **Flake checks** (`tests/default.nix`) run in the sandbox under
   `nix flake check`:
   - `basic` builds `tests/fixtures/basic` with `buildCMakeProject` and
     runs its ctest suite. The fixture has a FetchContent dependency of
     each kind: an archive (fmt), a git checkout declared in a
     subdirectory (argparse, in `lib/`), and a single header that
     FetchContent does not extract (doctest).
   - `extras` builds `tests/fixtures/extras`, whose downloads happen
     outside `FetchContent_MakeAvailable()`: `file(DOWNLOAD)` at configure
     time (CPM.cmake) and at build time (fmt's license, in a `cmake -P`
     script), CPM.cmake packages through `FetchContent_MakeAvailable()`
     (argparse) and `FetchContent_Populate()` (cxxopts, `DOWNLOAD_ONLY`),
     and `ExternalProject_Add()` with an archive that it builds (zlib) and
     with a git checkout (expected-lite).
   - `vcs` builds `tests/fixtures/vcs`, with a FetchContent dependency
     from Subversion, `ExternalProject_Add()` checkouts from Mercurial and
     CVS, and a git repository with two submodules, checked out by
     FetchContent and by `ExternalProject_Add()` with a `GIT_SUBMODULES`
     list each; the fixture fails when a checkout holds a submodule its
     list leaves out. `vcs-repos` builds its repositories
     (`tests/vcs-repos.nix`), so no check needs a server; the fixture's
     fetchers get the repositories as inputs through `vcsFetchers` and
     `fetchgit`.
   - `lock-urls` checks the URL rules of the lock run (`lock/urls.py`),
     the mapping of SSH URLs to HTTPS ones included.
   - `basic-runs`, `extras-runs` and `vcs-runs` run the installed
     programs, and
     `basic-name` checks that the package name and version come from the
     fixture's `project()`.
   - `basic-outputs` and `extras-outputs` check, at evaluation time, the
     `targets` and `installed` the lockfiles name, and use them. Every
     sandbox build also checks that it installed each file its lockfile
     names.
   - `unlocked-fails` adds a dependency the basic lockfile does not hold,
     and checks that the configure stops with the hint to relock.
   - `nix-library` runs `tests/nix-library.nix`, which applies the library
     to a hand-written lockfile with fetchers that download nothing. It
     checks the source tree, the initial cache that
     `nix/lib/write-cache.sh` writes, and the answers of the git shim.
   - `cmake-purifier` builds the command, which runs shellcheck on it.
   - `treefmt` checks the formatting of the Nix files.
2. **The interactive test** (`tests/interactive.sh`) runs outside the
   sandbox. It configures and builds the fixtures with
   `cmake-purifier configure` and `cmake-purifier build`, runs their
   programs and the basic tests, and checks that FetchContent populated
   none of the basic dependencies itself. Run it with the hosts of the
   fixtures' downloads unreachable, to show that the builds download
   nothing, and after the flake checks, which fetch the vcs fixture's
   checkouts.
3. **The relock** (`tests/relock-fixtures.sh`) runs the lock run on the
   fixtures, with the network, and on the vcs fixture against the
   repositories of `vcs-repos`. CI runs it and fails when a lockfile
   changes, so the lock run must reproduce the committed lockfiles.

CI (`.github/workflows/check.yml`) runs all three layers on x86_64-linux,
evaluates the checks of aarch64-linux there, and builds the flake checks
on an aarch64-linux runner.
