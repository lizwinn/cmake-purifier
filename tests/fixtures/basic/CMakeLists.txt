# SPDX-License-Identifier: MIT
#
# The fixture of the flake checks. It downloads one of each kind the lock
# records: an archive (fmt), a git checkout declared one directory down
# (argparse, in lib/), and a single file that FetchContent does not
# extract (doctest's header).
cmake_minimum_required(VERSION 3.24)
project(purifier-basic VERSION 1.2.3 LANGUAGES CXX)

include(FetchContent)

FetchContent_Declare(
  fmt
  URL https://github.com/fmtlib/fmt/releases/download/11.1.4/fmt-11.1.4.zip
)
FetchContent_Declare(
  doctest
  URL https://github.com/doctest/doctest/releases/download/v2.4.11/doctest.h
  DOWNLOAD_NO_EXTRACT TRUE
)
FetchContent_MakeAvailable(fmt doctest)

add_subdirectory(lib)

add_executable(greet main.cpp)
target_link_libraries(greet PRIVATE fmt::fmt greeting)
install(TARGETS greet)

enable_testing()
add_executable(greet-test test.cpp)
target_include_directories(greet-test PRIVATE "${doctest_SOURCE_DIR}")
target_link_libraries(greet-test PRIVATE fmt::fmt)
add_test(NAME greet-test COMMAND greet-test)
