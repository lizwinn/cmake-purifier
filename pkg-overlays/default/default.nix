# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.cmake-purifier`, of which `.cmake-purifier` is the command. A
# consumer that lists this flake in `projects` holds it as
# `cmake-purifier/default`, which its package sets apply by default.
#
# The command takes the source of the shared library of the
# nix-purifiers, which its own nix-build calls import.
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
    };
}
