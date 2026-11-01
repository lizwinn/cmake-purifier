# SPDX-License-Identifier: MIT
#
# The repositories of tests/fixtures/vcs: a Subversion, a Mercurial and a
# CVS repository, each with a header, built from nothing so that the
# checks need no server. The fixture names them with cache variables, and
# the lock run records their store paths.
#
# - `svn`: a repository with `trunk/svn.h` at revision 1.
# - `hg`: a repository with `hg.h`, tagged `v1`. Its commits have a fixed
#   user and date, so the commit hashes, and the hash of the checkout, do
#   not change from one build to the next.
# - `cvs`: a repository root with the module `cvslib` and its `cvs.h`,
#   tagged `v1`.
# - `git/super.git`: a git repository tagged `v1`, with the submodules
#   `sub-a` (`a.h`) and `sub-b` (`b.h`), from `git/sub-a.git` and
#   `git/sub-b.git` by relative URL. Its commits have a fixed author and
#   date too.
#
# `vcsFetchers` is fetchers.nix, and `fetchgit` nixpkgs' fetchgit, with
# these repositories as inputs of each fetch. The lockfile names them by
# store path only, which gives a fetch no access to them in the sandbox.
# git clones submodules over the file transport only when
# `protocol.file.allow` permits it, which `gitConfig` sets, for fetchgit
# here and for the lock run in tests/relock-fixtures.sh.
{ pkgs }:
let
  inherit (pkgs) lib;

  header = name: ''
    #pragma once
    inline const char *${name}_text() { return "${name}"; }
  '';

  gitConfig = {
    GIT_CONFIG_COUNT = "1";
    GIT_CONFIG_KEY_0 = "protocol.file.allow";
    GIT_CONFIG_VALUE_0 = "always";
  };

  repos =
    pkgs.runCommand "cmake-purifier-vcs-repos"
      (
        {
          nativeBuildInputs = [
            pkgs.subversion
            pkgs.mercurial
            pkgs.cvs
            pkgs.git
          ];
          GIT_AUTHOR_NAME = "test";
          GIT_AUTHOR_EMAIL = "test@example.invalid";
          GIT_AUTHOR_DATE = "1970-01-01T00:00:00Z";
          GIT_COMMITTER_NAME = "test";
          GIT_COMMITTER_EMAIL = "test@example.invalid";
          GIT_COMMITTER_DATE = "1970-01-01T00:00:00Z";
        }
        // gitConfig
      )
      ''
        mkdir $out work
        export HOME=$TMPDIR

        svnadmin create $out/svn
        mkdir -p work/svn/trunk
        cat > work/svn/trunk/svn.h <<'EOF'
        ${header "svn"}
        EOF
        svn import -q -m init work/svn file://$out/svn

        hg init $out/hg
        cat > $out/hg/hg.h <<'EOF'
        ${header "hg"}
        EOF
        hg -R $out/hg add -q $out/hg/hg.h
        hg -R $out/hg commit -q -m init -u test -d '0 0'
        hg -R $out/hg tag -u test -d '0 0' v1
        rm -f $out/hg/hg.h $out/hg/.hgtags

        export CVSROOT=$out/cvs
        cvs -Q init
        mkdir -p work/cvslib
        cat > work/cvslib/cvs.h <<'EOF'
        ${header "cvs"}
        EOF
        (cd work/cvslib && cvs -Q import -m init cvslib vendor start)
        cvs -Q rtag v1 cvslib

        mkdir $out/git
        for sub in a b; do
          git init -q -b main work/sub-$sub
          cat > work/sub-$sub/$sub.h <<EOF
        ${header "sub_\${sub}"}
        EOF
          git -C work/sub-$sub add $sub.h
          git -C work/sub-$sub commit -q -m init
          git clone -q --bare work/sub-$sub $out/git/sub-$sub.git
        done
        git init -q -b main work/super
        # Relative submodule URLs resolve against origin.
        git -C work/super remote add origin $out/git/super.git
        echo super > work/super/README
        git -C work/super add README
        git -C work/super submodule -q add ../sub-a.git sub-a
        git -C work/super submodule -q add ../sub-b.git sub-b
        git -C work/super commit -q -m init
        git -C work/super tag v1
        git clone -q --bare work/super $out/git/super.git
      '';

  # The text with the repositories' store path, which a lockfile names as
  # plain text, replaced by the repositories themselves, so that the
  # string carries them as an input. A lockfile made with other
  # repositories names another store path, and its fetch then fails on the
  # hash.
  withRepos =
    text:
    let
      found = builtins.match "(.*)/nix/store/[a-z0-9]{32}-cmake-purifier-vcs-repos(.*)" text;
    in
    if found == null then text else "${builtins.elemAt found 0}${repos}${builtins.elemAt found 1}";

  base = pkgs.callPackage ../nix/lib/fetchers.nix { };
in
{
  inherit repos gitConfig;
  fetchgit =
    args:
    (pkgs.fetchgit (args // { url = withRepos args.url; })).overrideAttrs (old: {
      env = (old.env or { }) // gitConfig;
    });
  vcsFetchers.vcs =
    artifact:
    base.vcs (
      artifact
      // lib.optionalAttrs (artifact ? hg) {
        hg = artifact.hg // {
          url = withRepos artifact.hg.url;
        };
      }
      // lib.optionalAttrs (artifact ? svn) {
        svn = artifact.svn // {
          url = withRepos artifact.svn.url;
        };
      }
      // lib.optionalAttrs (artifact ? cvs) {
        cvs = artifact.cvs // {
          cvsRoot = withRepos artifact.cvs.cvsRoot;
        };
      }
    );
}
