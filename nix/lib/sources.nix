# SPDX-License-Identifier: MIT
#
# Everything a build from a lockfile reads instead of the network. It is a
# package for callPackage, with the lockfile among its arguments.
# buildCMakeProject's `sources` is this, and `cmake-purifier configure`
# builds it on its own for an interactive build.
#
# `tree` is one directory with three parts:
#
# - `deps/<name>`: the source tree of each FetchContent dependency, as
#   FetchContent would have populated it. `byName` maps each name to it.
# - `git-checkouts.tsv`: a line per git checkout the build makes, with the
#   repository URL, the ref the build asked for, the commit and the store
#   path of the checkout, for git-shim.sh.
# - `http/`: every locked file at its artifact path, which is
#   `<scheme>/<host>/<path>` of its URL, the layout mitm-cache replays.
{
  lib,
  runCommand,
  cmake,
  fetchgit,
  lockFile,
  # Replaces the built-in fetcher of file downloads; see fetch.nix.
  fetchurl ? null,
}:
let
  lock = import ./lock.nix { inherit lockFile; };
  fetch = import ./fetch.nix { inherit lock fetchurl; };

  # Each artifact fetched once, by its path.
  fetched = builtins.mapAttrs (
    path: artifact:
    if artifact ? git then
      fetchgit {
        name = "${lock.storeName (baseNameOf artifact.git.url)}-${
          builtins.substring 0 12 artifact.git.rev
        }";
        inherit (artifact.git) url rev;
        inherit (artifact) hash;
        fetchSubmodules = artifact.git.submodules;
      }
    else
      fetch artifact
  ) lock.artifactsByPath;

  artifactOf =
    what: path:
    lock.artifactsByPath.${path}
      or (throw "cmake-purifier: ${what} names the artifact ${path}, which ${toString lockFile} does not lock");

  source =
    dep:
    let
      artifact = artifactOf "dependency ${dep.name}" dep.artifact;
      download = fetched.${dep.artifact};
    in
    if artifact ? git then
      download
    else if dep.extract then
      runCommand "${lock.storeName dep.name}-source"
        {
          nativeBuildInputs = [ cmake ];
          preferLocalBuild = true;
        }
        ''
          cmake -DARCHIVE=${download} -DOUT=$out -DWORK=$TMPDIR/extract -P ${./extract.cmake}
        ''
    else
      # DOWNLOAD_NO_EXTRACT: the source directory holds the downloaded file
      # under its own name.
      runCommand "${lock.storeName dep.name}-source" { preferLocalBuild = true; } ''
        mkdir $out
        ln -s ${download} $out/${lib.escapeShellArg (baseNameOf artifact.url)}
      '';

  byName = builtins.listToAttrs (
    map (dep: {
      inherit (dep) name;
      value = source dep;
    }) lock.dependencies
  );

  files = builtins.filter (artifact: !(artifact ? git)) lock.artifacts;
in
{
  inherit lock byName;
  # The manifests go to the builder as files, since a build can lock many
  # downloads.
  tree =
    runCommand "cmake-purifier-sources"
      {
        deps = lib.concatStrings (lib.mapAttrsToList (name: path: "${name}\t${path}\n") byName);
        http = lib.concatMapStrings (a: "${a.path}\t${fetched.${a.path}}\n") files;
        checkouts = lib.concatMapStrings (
          c:
          let
            artifact = artifactOf "the checkout of ${c.url} at ${c.ref}" c.artifact;
          in
          "${c.url}\t${c.ref}\t${artifact.git.rev}\t${fetched.${c.artifact}}\n"
        ) lock.gitCheckouts;
        passAsFile = [
          "deps"
          "http"
          "checkouts"
        ];
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        mkdir -p $out/deps $out/http
        while IFS=$'\t' read -r name target; do
          ln -s "$target" "$out/deps/$name"
        done < "$depsPath"
        while IFS=$'\t' read -r rel target; do
          mkdir -p "$out/http/$(dirname "$rel")"
          ln -s "$target" "$out/http/$rel"
        done < "$httpPath"
        cp "$checkoutsPath" $out/git-checkouts.tsv
      '';
}
