# SPDX-License-Identifier: MIT
#
# Unpacks ARCHIVE into OUT the way FetchContent unpacks a URL download
# (CMake's ExternalProject/extractfile.cmake.in): `cmake -E tar` extracts
# the archive, and when the archive holds a single directory, that
# directory's contents become the source tree.
#
#   cmake -DARCHIVE=<file> -DOUT=<dir> -DWORK=<scratch dir> -P extract.cmake

file(REMOVE_RECURSE "${WORK}")
file(MAKE_DIRECTORY "${WORK}")
execute_process(
  COMMAND "${CMAKE_COMMAND}" -E tar xf "${ARCHIVE}"
  WORKING_DIRECTORY "${WORK}"
  COMMAND_ERROR_IS_FATAL ANY
)
file(GLOB contents "${WORK}/*")
list(REMOVE_ITEM contents "${WORK}/.DS_Store")
list(LENGTH contents count)
if(NOT count EQUAL 1 OR NOT IS_DIRECTORY "${contents}")
  set(contents "${WORK}")
endif()
file(INSTALL "${contents}/" DESTINATION "${OUT}" USE_SOURCE_PERMISSIONS)
