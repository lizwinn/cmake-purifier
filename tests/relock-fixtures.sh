#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks both fixtures with the cmake-purifier of this checkout. The lock
# run configures and builds each fixture, so it needs the network and a C
# and C++ compiler, which nixpkgs provides here.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
for fixture in basic extras; do
  nix shell 'nixpkgs#gcc' 'nixpkgs#gnumake' "$root#cmake-purifier" \
    -c cmake-purifier lock -S "$root/tests/fixtures/$fixture"
done
