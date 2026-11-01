# SPDX-License-Identifier: MIT
#
# The dependency provider of a build from the lockfile, in the sandbox and
# under `cmake-purifier configure`. The initial cache that write-cache.sh
# writes names this file in CMAKE_PROJECT_TOP_LEVEL_INCLUDES, lists the
# locked FetchContent names in CMAKE_PURIFIER_LOCKED, sets
# CMAKE_PURIFIER_SOURCE_<NAME> to the locked source of each, and
# CMAKE_PURIFIER_DECLARED_<NAME> to the download each declaration named in
# the lock run (CMakePurifierDeclared.cmake).
#
# The provider checks each dependency the build makes available, and then
# points FetchContent at its locked source by setting
# FETCHCONTENT_SOURCE_DIR_<NAME> in the scope of the
# FetchContent_MakeAvailable() call, where FetchContent reads it next. A
# dependency the lockfile does not hold, or one whose declaration names
# another download than in the lock run, such as a new version, stops the
# configure with a hint to relock, rather than with the error of a
# disconnected FetchContent or with the old version.

include_guard(GLOBAL)
include("${CMAKE_CURRENT_LIST_DIR}/CMakePurifierDeclared.cmake")

function(_cmake_purifier_check method name)
  cmake_parse_arguments(PARSE_ARGV 2 arg "" "" "URL")
  if(DEFINED arg_URL)
    list(GET arg_URL 0 url)
    # The lock run records no file of the build's own source tree, and
    # FetchContent reads one without a download.
    if(NOT url MATCHES "^[A-Za-z][A-Za-z0-9+.-]*://" OR url MATCHES "^file://")
      return()
    endif()
  endif()
  string(TOUPPER "${name}" upper)
  set(found "")
  foreach(locked IN LISTS CMAKE_PURIFIER_LOCKED)
    string(TOUPPER "${locked}" locked_upper)
    if(upper STREQUAL locked_upper)
      set(found "${locked}")
    endif()
  endforeach()
  if(found STREQUAL "")
    message(FATAL_ERROR
      "cmake-purifier: the build declares the dependency ${name}, which the lockfile does not hold. "
      "Run `cmake-purifier lock` to lock it.")
  endif()
  _cmake_purifier_declared(declared ${ARGN})
  set(locked_declared "${CMAKE_PURIFIER_DECLARED_${upper}}")
  if(NOT locked_declared STREQUAL "" AND NOT declared STREQUAL locked_declared)
    message(FATAL_ERROR
      "cmake-purifier: the dependency ${name} now declares the download '${declared}', "
      "but the lockfile holds '${locked_declared}'. Run `cmake-purifier lock` to lock the new one.")
  endif()
  set("FETCHCONTENT_SOURCE_DIR_${upper}" "${CMAKE_PURIFIER_SOURCE_${upper}}" PARENT_SCOPE)
endfunction()

cmake_language(
  SET_DEPENDENCY_PROVIDER _cmake_purifier_check
  SUPPORTED_METHODS FETCHCONTENT_MAKEAVAILABLE_SERIAL
)
