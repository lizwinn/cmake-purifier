# SPDX-License-Identifier: MIT
#
# The fixture of Subversion, Mercurial and CVS checkouts: a FetchContent
# dependency from Subversion, which FetchContent_MakeAvailable() makes
# available, and ExternalProject_Add() checkouts from Mercurial and CVS.
# The repositories are the ones tests/vcs-repos.nix builds, which the lock
# run names with the cache variables PURIFIER_SVN_URL, PURIFIER_HG_URL and
# PURIFIER_CVS_ROOT.
cmake_minimum_required(VERSION 3.30)
project(purifier-vcs VERSION 0.1.0 LANGUAGES CXX)

include(FetchContent)
include(ExternalProject)

FetchContent_Declare(svnlib SVN_REPOSITORY "${PURIFIER_SVN_URL}/trunk" SVN_REVISION -r1)
FetchContent_MakeAvailable(svnlib)

ExternalProject_Add(
  hglib
  HG_REPOSITORY "${PURIFIER_HG_URL}"
  HG_TAG v1
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND ""
)
ExternalProject_Get_Property(hglib SOURCE_DIR)
set(hg_include "${SOURCE_DIR}")

ExternalProject_Add(
  cvslib
  CVS_REPOSITORY "${PURIFIER_CVS_ROOT}"
  CVS_MODULE cvslib
  CVS_TAG -rv1
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND ""
)
ExternalProject_Get_Property(cvslib SOURCE_DIR)
set(cvs_include "${SOURCE_DIR}")

add_executable(vcs main.cpp)
add_dependencies(vcs hglib cvslib)
target_include_directories(vcs PRIVATE "${svnlib_SOURCE_DIR}" "${hg_include}" "${cvs_include}")
install(TARGETS vcs)
