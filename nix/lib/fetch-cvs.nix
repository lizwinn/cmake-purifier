# SPDX-License-Identifier: MIT
#
# nixpkgs' fetchcvs with CVSREADONLYFS set, which makes cvs leave no lock
# files in the repository, so that a local repository on a read-only file
# system, such as one in the store, can be exported too. The sandbox build
# (sources.nix) and the lock run (prefetch-vcs.nix) both pass it to the
# shared library's fetchEntry in place of fetchcvs, so the hash the lock
# run records is the hash the sandbox build checks.
{ fetchcvs }:
args:
(fetchcvs args).overrideAttrs (old: {
  env = (old.env or { }) // {
    CVSREADONLYFS = "1";
  };
})
