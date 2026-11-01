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
