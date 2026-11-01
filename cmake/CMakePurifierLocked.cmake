# SPDX-License-Identifier: MIT
#
# The dependency provider of a build from the lockfile, in the sandbox and
# under `cmake-purifier configure`. The initial cache that write-cache.sh
# writes names this file in CMAKE_PROJECT_TOP_LEVEL_INCLUDES, and lists
# the locked FetchContent names in CMAKE_PURIFIER_LOCKED.
#
# The cache already points FetchContent at the locked sources, so the
# provider only checks each dependency the build makes available. A
# download the lockfile does not hold stops the configure with a hint to
# relock, rather than with the error of a disconnected FetchContent.

include_guard(GLOBAL)

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
  foreach(locked IN LISTS CMAKE_PURIFIER_LOCKED)
    string(TOUPPER "${locked}" locked_upper)
    if(upper STREQUAL locked_upper)
      return()
    endif()
  endforeach()
  message(FATAL_ERROR
    "cmake-purifier: the build declares the dependency ${name}, which the lockfile does not hold. "
    "Run `cmake-purifier lock` to lock it.")
endfunction()

cmake_language(
  SET_DEPENDENCY_PROVIDER _cmake_purifier_check
  SUPPORTED_METHODS FETCHCONTENT_MAKEAVAILABLE_SERIAL
)
