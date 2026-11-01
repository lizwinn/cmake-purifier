# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
{
  pkgs,
  # The flake's default package overlay, which adds buildCMakeProject.
  overlay,
  cmake-purifier,
}:
let
  # The fixture builds the way a consumer's package does: through
  # buildCMakeProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;

  basic = withOverlay.buildCMakeProject {
    src = ./fixtures/basic;
    # ctest runs the doctest suite, which includes the header that the
    # lock records as a download FetchContent does not extract.
    doCheck = true;
  };

  # Downloads outside FetchContent_MakeAvailable(): file(DOWNLOAD) at
  # configure and build time, CPM.cmake, and ExternalProject_Add() with a
  # URL and with git.
  extras = withOverlay.buildCMakeProject { src = ./fixtures/extras; };

  # The fixture with one more download, built from the fixture's lockfile,
  # which does not hold it.
  unlocked = withOverlay.buildCMakeProject {
    src = pkgs.runCommand "basic-unlocked" { } ''
      cp -r ${./fixtures/basic} $out
      chmod -R u+w $out
      cat >> $out/CMakeLists.txt <<'EOF'
      FetchContent_Declare(extra URL https://example.invalid/extra.zip)
      FetchContent_MakeAvailable(extra)
      EOF
    '';
    lockFile = ./fixtures/basic/cmake-purifier.lock.json;
  };
in
{
  inherit basic;

  # The installed program runs, with fmt and argparse from the lockfile.
  basic-runs = pkgs.runCommand "basic-runs" { } ''
    out_text=$(${basic}/bin/greet --name purifier)
    [ "$out_text" = "Hello, purifier!" ] || { echo "greet printed: $out_text" >&2; exit 1; }
    touch $out
  '';

  # The package name and version come from the lockfile's project().
  basic-name = pkgs.runCommand "basic-name" { } ''
    [ ${basic.pname} = purifier-basic ] && [ ${basic.version} = 1.2.3 ]
    touch $out
  '';

  # The outputs come from the lockfile at evaluation time: the target
  # greet and the file it installs, with no build needed to know them.
  # fmt installs itself as part of the fixture, so its static library is
  # an output too.
  basic-outputs =
    assert basic.targets.greet.type == "EXECUTABLE";
    assert basic.targets.greet.files == [ "${basic}/bin/greet" ];
    assert basic.targets.fmt.files == [ "${basic}/lib/libfmt.a" ];
    assert builtins.elem "include/fmt/format.h" (builtins.attrNames basic.installed);
    pkgs.runCommand "basic-outputs" { } ''
      [ "$(${builtins.head basic.targets.greet.files} --name outputs)" = "Hello, outputs!" ]
      touch $out
    '';

  inherit extras;

  # Every installed file of extras is an output, the license the build
  # downloaded included.
  extras-outputs =
    assert extras.targets.extras.files == [ "${extras}/bin/extras" ];
    assert
      builtins.attrNames extras.installed == [
        "bin/extras"
        "share/purifier-extras/fmt-LICENSE"
      ];
    pkgs.runCommand "extras-outputs" { } ''
      grep -q 'Victor Zverovich' ${extras.installed."share/purifier-extras/fmt-LICENSE"}
      touch $out
    '';

  # The program runs with argparse and cxxopts from CPM.cmake, zlib from
  # an ExternalProject archive and expected-lite from an ExternalProject
  # checkout, and the license the build downloaded is installed.
  extras-runs = pkgs.runCommand "extras-runs" { } ''
    out_text=$(${extras}/bin/extras --count 5)
    [ "$out_text" = "count 5, zlib 1.3.1" ] || { echo "extras printed: $out_text" >&2; exit 1; }
    grep -q 'Copyright (c) 2012 - present, Victor Zverovich' ${extras}/share/purifier-extras/fmt-LICENSE
    touch $out
  '';

  # A download the lockfile does not hold stops the configure with the
  # hint to relock.
  unlocked-fails =
    pkgs.runCommand "unlocked-fails" { failed = pkgs.testers.testBuildFailure unlocked; }
      ''
        # CMake wraps the message, so the check matches its first line.
        grep -q 'cmake-purifier: the build declares the dependency extra, which the lockfile' $failed/testBuildFailure.log
        touch $out
      '';

  nix-library = import ./nix-library.nix { inherit pkgs; };

  # The command builds, which runs shellcheck on it.
  inherit cmake-purifier;
}
