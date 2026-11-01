# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.cmake-purifier`, of which `.cmake-purifier` is the command, and
# the builder `pkgs.buildCMakeProject` (nix/lib/build-cmake-project.nix)
# beside them, where nixpkgs keeps its own builders, so a package written
# for callPackage takes it by name. A consumer that lists this flake in
# `projects` holds it as `cmake-purifier/default`, which its package sets
# apply by default.
#
# Both use the shared library of the nix-purifiers: the builder its
# functions, and the command its source, which the command's own
# nix-build calls import.
{
  closure-lib,
  closure-inputs,
  ...
}:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "cmake-purifier";
in
{
  overlay =
    final: prev:
    let
      base = packages final prev;
    in
    base
    // {
      cmake-purifier = base.cmake-purifier // {
        cmake-purifier = base.cmake-purifier.cmake-purifier.override {
          purifier = closure-inputs.purifier;
        };
      };
      buildCMakeProject = final.callPackage ../../nix/lib/build-cmake-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
