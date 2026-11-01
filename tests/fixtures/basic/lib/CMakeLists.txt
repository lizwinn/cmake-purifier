# SPDX-License-Identifier: MIT
#
# A dependency declared below the top-level directory, which the lock run's
# provider sees like any other.
FetchContent_Declare(
  argparse
  GIT_REPOSITORY https://github.com/p-ranav/argparse.git
  GIT_TAG v3.2
  GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(argparse)

add_library(greeting INTERFACE)
target_link_libraries(greeting INTERFACE argparse::argparse)
