# SPDX-License-Identifier: MIT
#
# The fixture of a CVS checkout: ExternalProject_Add() with the tag v1 of
# the module cvslib, from the repository tests/vcs-repos.nix builds, which
# the lock run names with the cache variable PURIFIER_CVS_ROOT. nixpkgs'
# cvs aborts on aarch64-linux, so only x86_64-linux builds this fixture.
cmake_minimum_required(VERSION 3.30)
project(purifier-cvs VERSION 0.1.0 LANGUAGES CXX)

include(ExternalProject)

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

add_executable(cvs main.cpp)
add_dependencies(cvs cvslib)
target_include_directories(cvs PRIVATE "${SOURCE_DIR}")
install(TARGETS cvs)
