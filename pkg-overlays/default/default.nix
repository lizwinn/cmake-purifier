# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.cmake-purifier` (`.cmake-purifier`, the command), and the builder
# `pkgs.buildCMakeProject` (nix/lib/build-cmake-project.nix) beside them,
# where nixpkgs keeps its own builders, so a package written for
# callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `cmake-purifier/default`, which its package sets
# apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "cmake-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildCMakeProject = final.callPackage ../../nix/lib/build-cmake-project.nix { };
    };
}
