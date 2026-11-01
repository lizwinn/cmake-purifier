#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks the fixtures with the cmake-purifier of this checkout. The lock
# run configures and builds each fixture, so it needs the network and a C
# and C++ compiler, which nixpkgs provides here.
#
# The vcs fixture locks against the repositories of tests/vcs-repos.nix,
# which the flake check `vcs-repos` builds. They are in the read-only
# store, so CVSREADONLYFS tells cvs to leave no lock files in the CVS one,
# and git clones the git one's submodules over the file transport only
# with protocol.file.allow set, as the GIT_CONFIG_* variables do.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
system=$(nix eval --impure --raw --expr builtins.currentSystem)

lock() {
  nix shell 'nixpkgs#gcc' 'nixpkgs#gnumake' "$root#cmake-purifier" -c cmake-purifier lock "$@"
}

lock -S "$root/tests/fixtures/basic"
lock -S "$root/tests/fixtures/extras"

repos=$(nix build --no-link --print-out-paths "$root#checks.$system.vcs-repos")
CVSREADONLYFS=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
  lock -S "$root/tests/fixtures/vcs" \
  -DPURIFIER_SVN_URL="file://$repos/svn" \
  -DPURIFIER_HG_URL="file://$repos/hg" \
  -DPURIFIER_CVS_ROOT="$repos/cvs" \
  -DPURIFIER_GIT_URL="file://$repos/git/super.git"
