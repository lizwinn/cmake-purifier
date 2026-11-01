#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The interactive test: `cmake-purifier configure` on the fixture, outside
# the sandbox. The program must build and run, its tests must pass, and
# FetchContent must have populated nothing itself: a populated dependency
# leaves a <name>-src or <name>-subbuild directory under _deps.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
build=$(mktemp -d)
trap 'chmod -R u+w "$build"; rm -rf "$build"' EXIT

run() {
  nix shell 'nixpkgs#gcc' 'nixpkgs#gnumake' 'nixpkgs#cmake' "$root#cmake-purifier" -c "$@"
}

run cmake-purifier configure -S "$root/tests/fixtures/basic" -B "$build"
run cmake --build "$build" -j4
[ "$("$build/greet" --name interactive)" = "Hello, interactive!" ]
run ctest --test-dir "$build" --output-on-failure

populated=$(find "$build/_deps" -mindepth 1 -maxdepth 1 \( -name '*-src' -o -name '*-subbuild' \))
if [ -n "$populated" ]; then
  echo "FetchContent populated a dependency itself:" >&2
  ls "$build/_deps" >&2
  exit 1
fi
echo "interactive: passed"
