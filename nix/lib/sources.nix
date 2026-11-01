# SPDX-License-Identifier: MIT
#
# The source tree of every dependency in a lockfile, as FetchContent would
# have populated it. It is a package for callPackage, with the lockfile
# among its arguments. buildCMakeProject's `sources` is this, and
# `cmake-purifier configure` builds it on its own for an interactive build.
#
# `byName` maps each FetchContent name to its source tree. `tree` is one
# directory with an entry per name, linking to that tree.
{
  lib,
  runCommand,
  linkFarm,
  cmake,
  fetchgit,
  lockFile,
  # Replaces the built-in fetcher of URL downloads; see fetch.nix.
  fetchurl ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock fetchurl; };

  fileSource =
    dep: artifact:
    let
      file = fetch artifact;
    in
    if dep.extract then
      runCommand "${lock.storeName dep.name}-source"
        {
          nativeBuildInputs = [ cmake ];
          preferLocalBuild = true;
        }
        ''
          cmake -DARCHIVE=${file} -DOUT=$out -DWORK=$TMPDIR/extract -P ${./extract.cmake}
        ''
    else
      # DOWNLOAD_NO_EXTRACT: the source directory holds the downloaded file
      # under its own name.
      runCommand "${lock.storeName dep.name}-source" { preferLocalBuild = true; } ''
        mkdir $out
        ln -s ${file} $out/${lib.escapeShellArg (baseNameOf artifact.url)}
      '';

  gitSource =
    dep: artifact:
    fetchgit {
      name = "${lock.storeName dep.name}-source";
      inherit (artifact.git) url rev;
      inherit (artifact) hash;
      fetchSubmodules = artifact.git.submodules;
    };

  source =
    dep:
    let
      artifact =
        lock.artifactsByPath.${dep.artifact}
          or (throw "cmake-purifier: dependency ${dep.name} names the artifact ${dep.artifact}, which ${toString lockFile} does not lock");
    in
    if artifact ? git then gitSource dep artifact else fileSource dep artifact;

  byName = builtins.listToAttrs (
    map (dep: {
      inherit (dep) name;
      value = source dep;
    }) lock.dependencies
  );
in
{
  inherit lock byName;
  tree = linkFarm "cmake-purifier-sources" byName;
}
