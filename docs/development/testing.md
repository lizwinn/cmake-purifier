# Testing

The tests come in two layers.

1. **Flake checks** (`tests/default.nix`) run in the sandbox under
   `nix flake check`:
   - `basic` builds `tests/fixtures/basic` with `buildCMakeProject` and
     runs its ctest suite. The fixture downloads one of each kind the lock
     records: an archive (fmt), a git checkout declared in a subdirectory
     (argparse, in `lib/`), and a single header that FetchContent does not
     extract (doctest).
   - `basic-runs` runs the installed program, and `basic-name` checks that
     the package name and version come from the fixture's `project()`.
   - `unlocked-fails` adds a dependency the fixture's lockfile does not
     hold, and checks that the configure stops with the hint to relock.
   - `nix-library` runs `tests/nix-library.nix`, which applies the library
     to a hand-written lockfile with fetchers that download nothing, and
     checks the initial cache that `nix/lib/write-cache.sh` writes.
   - `cmake-purifier` builds the command, which runs shellcheck on it.
   - `treefmt` checks the formatting of the Nix files.
2. **The interactive test** (`tests/interactive.sh`) runs outside the
   sandbox. It configures the fixture in a scratch build directory with
   `cmake-purifier configure`, builds it, runs the program and its tests,
   and checks that FetchContent downloaded nothing into the build
   directory.

The fixture's lockfile is test data. `tests/relock-fixtures.sh` renews it,
and it needs the network.
