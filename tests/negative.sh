#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The mistakes a developer makes with a lockfile, through
# `cmake-purifier configure` outside the sandbox. Each must stop with, or
# warn of, an error that says what went wrong and which command to run.
#
# - A lockfile that is not valid JSON.
# - A lockfile whose hash of a download was edited.
# - A lockfile older than the build definition: the configure warns, and
#   still configures when nothing new is downloaded.
# - A build that declares a dependency the lockfile does not hold, and one
#   whose declaration names a new version.
#
# Each case runs on a copy of the basic fixture in a scratch directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT

run() {
  nix shell 'nixpkgs#gcc' 'nixpkgs#gnumake' 'nixpkgs#cmake' 'nixpkgs#jq' "$root#cmake-purifier" -c "$@"
}

# Copies the basic fixture to $scratch/<name> and prints its path.
fixture() {
  cp -r "$root/tests/fixtures/basic" "$scratch/$1"
  chmod -R u+w "$scratch/$1"
  echo "$scratch/$1"
}

# Runs the configure of <source> and checks that it fails with output that
# matches <pattern>.
fails_with() {
  local source=$1 pattern=$2
  if run cmake-purifier configure -S "$source" -B "$source/build" > "$source.log" 2>&1; then
    echo "negative: the configure of $source succeeded" >&2
    exit 1
  fi
  grep -q -- "$pattern" "$source.log" || {
    echo "negative: the configure of $source failed without '$pattern':" >&2
    cat "$source.log" >&2
    exit 1
  }
}

broken=$(fixture broken)
echo '{ "version": 2,' > "$broken/cmake-purifier.lock.json"
fails_with "$broken" "is not valid JSON; restore it from version control, or run cmake-purifier lock"

tampered=$(fixture tampered)
run jq '(.artifacts[] | select(.url != null) | .hash) |= "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="' \
  "$root/tests/fixtures/basic/cmake-purifier.lock.json" > "$tampered/cmake-purifier.lock.json"
fails_with "$tampered" "hash mismatch"

stale=$(fixture stale)
echo '# an edit that downloads nothing new' >> "$stale/CMakeLists.txt"
run cmake-purifier configure -S "$stale" -B "$stale/build" > "$stale.log" 2>&1
grep -q 'warning: a CMakeLists.txt or \*.cmake file changed since' "$stale.log"

unlocked=$(fixture unlocked)
printf 'FetchContent_Declare(extra URL https://example.invalid/extra.zip)\nFetchContent_MakeAvailable(extra)\n' >> "$unlocked/CMakeLists.txt"
fails_with "$unlocked" "the build declares the dependency extra, which the lockfile"

upgraded=$(fixture upgraded)
sed -i 's|11.1.4/fmt-11.1.4.zip|11.2.0/fmt-11.2.0.zip|' "$upgraded/CMakeLists.txt"
fails_with "$upgraded" "the dependency fmt now declares the download"

echo "negative: passed"
