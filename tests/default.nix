# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked downloads.
{
  pkgs,
  # The shared library's functions.
  purifier,
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

  # Checkouts from Subversion, Mercurial, git with submodules and CVS, of
  # repositories the checks build themselves. CVS has a fixture of its
  # own, which only x86_64-linux builds.
  vcsRepos = import ./vcs-repos.nix { inherit pkgs; };
  vcs = withOverlay.buildCMakeProject {
    src = ./fixtures/vcs;
    inherit (vcsRepos) fetchers;
  };
  cvs = withOverlay.buildCMakeProject {
    src = ./fixtures/cvs;
    inherit (vcsRepos) fetchers;
  };

  # The fixture with fmt at another version, built from the lockfile of
  # the old one.
  upgraded = withOverlay.buildCMakeProject {
    src = pkgs.runCommand "basic-upgraded" { } ''
      cp -r ${./fixtures/basic} $out
      chmod -R u+w $out
      substituteInPlace $out/CMakeLists.txt --replace-fail 11.1.4/fmt-11.1.4.zip 11.2.0/fmt-11.2.0.zip
    '';
    lockFile = ./fixtures/basic/cmake-purifier.lock.json;
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

  # The repositories of the vcs fixture, which tests/relock-fixtures.sh
  # builds to lock the fixture against.
  vcs-repos = vcsRepos.repos;

  inherit vcs;

  # The program runs with a header from each repository: the Subversion one
  # through FetchContent, the Mercurial and CVS ones through
  # ExternalProject_Add(), and one from each submodule that a
  # GIT_SUBMODULES list keeps. The fixture itself fails to configure or to
  # build when a checkout holds a submodule its list leaves out.
  vcs-runs = pkgs.runCommand "vcs-runs" { } ''
    out_text=$(${builtins.head vcs.targets.vcs.files})
    [ "$out_text" = "svn hg sub_a sub_b" ] || { echo "vcs printed: $out_text" >&2; exit 1; }
    touch $out
  '';

  # The URL rules of the lock run (lock/urls.py), the mapping of SSH URLs
  # to HTTPS ones included.
  lock-urls = pkgs.runCommand "lock-urls" { } ''
    ${pkgs.python3}/bin/python3 -I ${../lock/test_urls.py} ${../lock}
    touch $out
  '';

  # The reading of the lock run's records (lock/records.py), on sample
  # records of each kind.
  lock-records = pkgs.runCommand "lock-records" { } ''
    ${pkgs.python3}/bin/python3 -I ${../lock/test_records.py} ${../lock}
    touch $out
  '';

  # The copy of each fixture that a build gets hashes to the definition
  # hash its lockfile recorded, so a build warns only when the definition
  # changed; after an edit to a CMakeLists.txt, it hashes differently.
  definition-hash = pkgs.runCommand "definition-hash" { } ''
    for fixture in basic extras vcs cvs; do
      case $fixture in
        cvs) src=${./fixtures/cvs} ;;
        basic) src=${./fixtures/basic} ;;
        extras) src=${./fixtures/extras} ;;
        vcs) src=${./fixtures/vcs} ;;
      esac
      locked=$(${pkgs.jq}/bin/jq -r .definitionHash $src/cmake-purifier.lock.json)
      [ "$(bash ${../nix/lib/definition-hash.sh} $src)" = "$locked" ] ||
        { echo "$fixture hashes differently from its lockfile" >&2; exit 1; }
    done
    cp -r ${./fixtures/basic} edited
    chmod -R u+w edited
    echo '# an edit' >> edited/lib/CMakeLists.txt
    [ "$(bash ${../nix/lib/definition-hash.sh} edited)" != "$(${pkgs.jq}/bin/jq -r .definitionHash edited/cmake-purifier.lock.json)" ]
    touch $out
  '';

  # A dependency whose declaration changed since the lock run, such as a
  # new version, stops the configure with the hint to relock.
  declaration-changed-fails =
    pkgs.runCommand "declaration-changed-fails" { failed = pkgs.testers.testBuildFailure upgraded; }
      ''
        grep -q "cmake-purifier: the dependency fmt now declares the download" $failed/testBuildFailure.log
        grep -q 'warning: a CMakeLists.txt or \*.cmake file changed' $failed/testBuildFailure.log
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

  nix-library = import ./nix-library.nix { inherit pkgs purifier; };

  # The command builds, which runs shellcheck on it.
  inherit cmake-purifier;
}
// (
  if vcsRepos.cvsWorks then
    {
      inherit cvs;
      # The program runs with the header of the CVS checkout.
      cvs-runs = pkgs.runCommand "cvs-runs" { } ''
        [ "$(${builtins.head cvs.targets.cvs.files})" = cvs ]
        touch $out
      '';
    }
  else
    {
      # nixpkgs' cvs aborts on this system, in the 2006 gnulib vasnprintf
      # it bundles, so the CVS fixture builds on x86_64-linux only.
      cvs = pkgs.runCommand "cvs-skipped" { } ''
        echo "cmake-purifier: the CVS fixture is skipped on ${pkgs.stdenv.hostPlatform.system}, where nixpkgs' cvs aborts" >&2
        touch $out
      '';
    }
)
