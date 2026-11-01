#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The interactive test: `cmake-purifier configure` and `cmake-purifier
# build` on the fixtures, outside the sandbox. The programs must build and
# run, the basic fixture's tests must pass, and clangd must work on the
# basic fixture's offline build directory. Run it with the hosts
# of the fixtures' downloads unreachable, to show that nothing outside the
# lockfile is downloaded; on a machine with the network, the check below
# still shows that FetchContent populated none of basic's dependencies
# itself, since a populated dependency leaves a <name>-src or
# <name>-subbuild directory under _deps.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT

run() {
  nix shell 'nixpkgs#gcc' 'nixpkgs#gnumake' 'nixpkgs#cmake' "$root#cmake-purifier" -c "$@"
}

basic=$scratch/basic
run cmake-purifier configure -S "$root/tests/fixtures/basic" -B "$basic" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
# The editor: clangd reads the build directory's compile_commands.json and
# finds the headers of fmt and argparse in the locked sources, offline.
nix shell 'nixpkgs#clang-tools' -c clangd --check="$root/tests/fixtures/basic/main.cpp" \
  --compile-commands-dir="$basic" > "$scratch/clangd.log" 2>&1 || {
  echo "clangd failed on the offline build directory:" >&2
  cat "$scratch/clangd.log" >&2
  exit 1
}
run cmake-purifier build -B "$basic" -j4
[ "$("$basic/greet" --name interactive)" = "Hello, interactive!" ]
run ctest --test-dir "$basic" --output-on-failure
populated=$(find "$basic/_deps" -mindepth 1 -maxdepth 1 \( -name '*-src' -o -name '*-subbuild' \))
if [ -n "$populated" ]; then
  echo "FetchContent populated a dependency itself:" >&2
  echo "$populated" >&2
  exit 1
fi

extras=$scratch/extras
run cmake-purifier configure -S "$root/tests/fixtures/extras" -B "$extras"
run cmake-purifier build -B "$extras" -j4
[ "$("$extras/extras" --count 7)" = "count 7, zlib 1.3.1" ]
grep -q 'Victor Zverovich' "$extras/fmt-LICENSE"

# The vcs fixture checks out from repositories in the store. Its fetches
# name them by plain store path, which gives a fetch no access to them, so
# the flake check `vcs` must have fetched them before this test runs; a
# fetch whose output is already in the store does not run again.
vcs=$scratch/vcs
run cmake-purifier configure -S "$root/tests/fixtures/vcs" -B "$vcs"
run cmake-purifier build -B "$vcs" -j4
[ "$("$vcs/vcs")" = "svn hg cvs sub_a sub_b" ]

echo "interactive: passed"
