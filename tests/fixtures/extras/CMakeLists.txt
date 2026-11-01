# SPDX-License-Identifier: MIT
#
# The fixture of the downloads outside FetchContent_MakeAvailable():
#
# - file(DOWNLOAD) at configure time: CPM.cmake, fetched the way its
#   get_cpm.cmake fetches it.
# - CPM.cmake packages: argparse, which CPM makes available through
#   FetchContent_MakeAvailable(), and cxxopts, which it fetches with
#   FetchContent_Populate() because the package is DOWNLOAD_ONLY.
# - ExternalProject_Add() with a URL archive, built while the project
#   builds: zlib.
# - ExternalProject_Add() with a git repository: expected-lite's headers.
# - file(DOWNLOAD) at build time, in a `cmake -P` script that a custom
#   command runs: fmt's license.
cmake_minimum_required(VERSION 3.30)
project(purifier-extras VERSION 0.1.0 LANGUAGES C CXX)

set(CPM_DOWNLOAD_VERSION 0.40.8)
set(CPM_DOWNLOAD_LOCATION "${CMAKE_BINARY_DIR}/cmake/CPM_${CPM_DOWNLOAD_VERSION}.cmake")
file(
  DOWNLOAD
  "https://github.com/cpm-cmake/CPM.cmake/releases/download/v${CPM_DOWNLOAD_VERSION}/CPM.cmake"
  "${CPM_DOWNLOAD_LOCATION}"
  EXPECTED_HASH SHA256=78ba32abdf798bc616bab7c73aac32a17bbd7b06ad9e26a6add69de8f3ae4791
)
include("${CPM_DOWNLOAD_LOCATION}")

CPMAddPackage(NAME argparse GITHUB_REPOSITORY p-ranav/argparse GIT_TAG v3.2)
CPMAddPackage(NAME cxxopts GITHUB_REPOSITORY jarro2783/cxxopts VERSION 3.2.1 DOWNLOAD_ONLY YES)

include(ExternalProject)

set(zlib_prefix "${CMAKE_BINARY_DIR}/zlib-install")
file(MAKE_DIRECTORY "${zlib_prefix}/include")
ExternalProject_Add(
  zlib_ep
  URL https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
  URL_HASH SHA256=9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23
  INSTALL_DIR "${zlib_prefix}"
  CMAKE_ARGS
    -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
    -DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}
  BUILD_BYPRODUCTS "${zlib_prefix}/lib/libz.a"
)
add_library(zlib_static STATIC IMPORTED)
set_target_properties(
  zlib_static PROPERTIES
  IMPORTED_LOCATION "${zlib_prefix}/lib/libz.a"
  INTERFACE_INCLUDE_DIRECTORIES "${zlib_prefix}/include"
)
add_dependencies(zlib_static zlib_ep)

ExternalProject_Add(
  expected_ep
  GIT_REPOSITORY https://github.com/martinmoene/expected-lite.git
  GIT_TAG v0.8.0
  GIT_SHALLOW TRUE
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND ""
)
ExternalProject_Get_Property(expected_ep SOURCE_DIR)
set(expected_include "${SOURCE_DIR}/include")

add_custom_command(
  OUTPUT "${CMAKE_BINARY_DIR}/fmt-LICENSE"
  COMMAND "${CMAKE_COMMAND}" -DOUT=${CMAKE_BINARY_DIR}/fmt-LICENSE -P "${CMAKE_SOURCE_DIR}/fetch-license.cmake"
)
add_custom_target(license ALL DEPENDS "${CMAKE_BINARY_DIR}/fmt-LICENSE")
install(FILES "${CMAKE_BINARY_DIR}/fmt-LICENSE" DESTINATION share/purifier-extras)

add_executable(extras main.cpp)
add_dependencies(extras expected_ep)
target_include_directories(extras PRIVATE "${expected_include}" "${cxxopts_SOURCE_DIR}/include")
target_link_libraries(extras PRIVATE argparse zlib_static)
install(TARGETS extras)
