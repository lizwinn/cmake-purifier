# SPDX-License-Identifier: MIT
#
# The fetchers of Mercurial, Subversion and CVS artifacts, shared by the
# sandbox build (sources.nix) and the lock run (prefetch-vcs.nix), so that
# the hash the lock run records is the hash the sandbox build checks.
#
# `vcs` fetches an artifact by its kind: `hg = { url, rev, subrepos }`
# with nixpkgs' fetchhg, `svn = { url, rev, ignoreExternals,
# ignoreKeywords }` with fetchsvn, and
# `cvs = { cvsRoot, module, tag, date }` with fetchcvs, where one of `tag`
# and `date` is null. A CVS export sets CVSREADONLYFS, which makes cvs
# leave no lock files in the repository, so a local repository on a
# read-only file system works too.
{
  lib,
  fetchhg,
  fetchsvn,
  fetchcvs,
}:
{
  vcs =
    artifact:
    if artifact ? hg then
      fetchhg {
        inherit (artifact.hg) url rev;
        inherit (artifact) hash;
        fetchSubrepos = artifact.hg.subrepos;
      }
    else if artifact ? svn then
      fetchsvn {
        inherit (artifact.svn)
          url
          rev
          ignoreExternals
          ignoreKeywords
          ;
        inherit (artifact) hash;
      }
    else if artifact ? cvs then
      (fetchcvs (
        {
          inherit (artifact.cvs) cvsRoot module;
          inherit (artifact) hash;
        }
        // lib.optionalAttrs (artifact.cvs.tag != null) { inherit (artifact.cvs) tag; }
        // lib.optionalAttrs (artifact.cvs.date != null) { inherit (artifact.cvs) date; }
      )).overrideAttrs
        (old: {
          env = (old.env or { }) // {
            CVSREADONLYFS = "1";
          };
        })
    else
      throw "cmake-purifier: the artifact ${artifact.path} is no Mercurial, Subversion or CVS checkout";
}
