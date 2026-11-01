# SPDX-License-Identifier: MIT
#
# The `cmake-purifier` library namespace: the builder `buildCMakeProject`
# (nix/lib/build-cmake-project.nix), on the shared library's functions,
# and `readLock` (nix/lib/lock.nix), which reads a lockfile into the lock
# in memory of the purifier contract.
{ ... }:
{

  overlay = final: prev: {
    cmake-purifier = (prev.cmake-purifier or { }) // {
      buildCMakeProject = import ../../nix/lib/build-cmake-project.nix { inherit (final) purifier; };
      readLock = import ../../nix/lib/lock.nix;
    };
  };

}
