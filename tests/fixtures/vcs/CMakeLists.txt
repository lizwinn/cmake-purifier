# SPDX-License-Identifier: MIT
#
# The fixture of checkouts from repositories: a FetchContent dependency
# from Subversion, which FetchContent_MakeAvailable() makes available, an
# ExternalProject_Add() checkout from Mercurial, and a git repository with
# two submodules, checked out twice with a GIT_SUBMODULES list that names
# one of them: by FetchContent, which keeps sub-a, and by
# ExternalProject_Add(), which keeps sub-b. The repositories are the ones
# tests/vcs-repos.nix builds, which the lock run names with the cache
# variables PURIFIER_SVN_URL, PURIFIER_HG_URL and PURIFIER_GIT_URL. The
# fixture `cvs` has the CVS checkout.
cmake_minimum_required(VERSION 3.30)
project(purifier-vcs VERSION 0.1.0 LANGUAGES CXX)

include(FetchContent)
include(ExternalProject)

FetchContent_Declare(svnlib SVN_REPOSITORY "${PURIFIER_SVN_URL}/trunk" SVN_REVISION -r1)
FetchContent_Declare(
  gitfc
  GIT_REPOSITORY "${PURIFIER_GIT_URL}"
  GIT_TAG v1
  GIT_SUBMODULES sub-a
)
FetchContent_MakeAvailable(svnlib gitfc)
if(NOT EXISTS "${gitfc_SOURCE_DIR}/sub-a/a.h" OR EXISTS "${gitfc_SOURCE_DIR}/sub-b/b.h")
  message(FATAL_ERROR "gitfc holds other submodules than its GIT_SUBMODULES list, sub-a")
endif()

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
  gitep
  GIT_REPOSITORY "${PURIFIER_GIT_URL}"
  GIT_TAG v1
  GIT_SUBMODULES sub-b
  CONFIGURE_COMMAND ""
  BUILD_COMMAND
    "${CMAKE_COMMAND}" -DKEEP=<SOURCE_DIR>/sub-b/b.h -DDROP=<SOURCE_DIR>/sub-a/a.h
    -P "${CMAKE_CURRENT_SOURCE_DIR}/check-submodules.cmake"
  INSTALL_COMMAND ""
)
ExternalProject_Get_Property(gitep SOURCE_DIR)
set(gitep_include "${SOURCE_DIR}")

add_executable(vcs main.cpp)
add_dependencies(vcs hglib gitep)
target_include_directories(
  vcs PRIVATE
  "${svnlib_SOURCE_DIR}" "${hg_include}" "${gitfc_SOURCE_DIR}/sub-a" "${gitep_include}/sub-b"
)
install(TARGETS vcs)
