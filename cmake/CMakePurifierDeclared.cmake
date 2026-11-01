# SPDX-License-Identifier: MIT
#
# The download a FetchContent declaration names, as one line of text: the
# kind, the URL or repository, and the tag or revision it asks for. The
# lock run's provider records it in the lockfile, and the provider of a
# build from the lockfile compares it with the declaration it sees, so
# that a dependency whose declaration changed, such as a new version,
# stops the configure with a hint to relock.
#
#   _cmake_purifier_declared(<out variable> <declared details>...)

include_guard(GLOBAL)

function(_cmake_purifier_declared out)
  cmake_parse_arguments(PARSE_ARGV 1 d ""
    "GIT_REPOSITORY;GIT_TAG;HG_REPOSITORY;HG_TAG;SVN_REPOSITORY;SVN_REVISION;CVS_REPOSITORY;CVS_MODULE;CVS_TAG"
    "URL")
  if(DEFINED d_URL)
    list(GET d_URL 0 first)
    set(text "url ${first}")
  elseif(DEFINED d_GIT_REPOSITORY)
    set(text "git ${d_GIT_REPOSITORY} ${d_GIT_TAG}")
  elseif(DEFINED d_HG_REPOSITORY)
    set(text "hg ${d_HG_REPOSITORY} ${d_HG_TAG}")
  elseif(DEFINED d_SVN_REPOSITORY)
    set(text "svn ${d_SVN_REPOSITORY} ${d_SVN_REVISION}")
  elseif(DEFINED d_CVS_REPOSITORY)
    set(text "cvs ${d_CVS_REPOSITORY} ${d_CVS_MODULE} ${d_CVS_TAG}")
  else()
    set(text "")
  endif()
  set(${out} "${text}" PARENT_SCOPE)
endfunction()
