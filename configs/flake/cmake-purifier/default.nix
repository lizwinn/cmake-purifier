# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The scope `pkgs.cmake-purifier` is the `default` entry of this
    # flake's package overlay registry (pkg-overlays/): the package set
    # applies it by default, and the flake exports it as `pkgOverlays` and
    # as the plain `overlays.default`. The scope also holds the builder, a
    # function, so the `packages` output below is the derivations of the
    # scope, and the automatic export of the scope is off.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/cmake-purifier -- lock` locks the build in
  # the current directory. `nix develop github:nix-purifiers/cmake-purifier`
  # gives a shell with the command, CMake, Ninja, make, the C and C++
  # compilers of stdenv, and clangd, which is enough to lock, prefetch,
  # build and edit a project whose other dependencies come from
  # FetchContent.
  perSystem =
    { config, pkgs, ... }:
    {
      packages = lib.filterAttrs (_: lib.isDerivation) pkgs.cmake-purifier // {
        default = config.packages.cmake-purifier;
      };
      devShells.default = pkgs.mkShell {
        packages = [
          config.packages.cmake-purifier
          pkgs.cmake
          pkgs.ninja
          pkgs.gnumake
          pkgs.clang-tools
        ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              inherit (self.lib) purifier;
              inherit ((pkgs.extend self.overlays.default).cmake-purifier) buildCMakeProject;
              inherit (self.lib.cmake-purifier) readLock;
              inherit (self.packages.${system}) cmake-purifier;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
