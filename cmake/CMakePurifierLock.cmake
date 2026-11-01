# SPDX-License-Identifier: MIT
#
# The dependency provider of the lock run. `cmake-purifier lock` names this
# file in CMAKE_PROJECT_TOP_LEVEL_INCLUDES, so CMake includes it at the
# first project() call of the build, before any CMakeLists.txt declares a
# dependency.
#
# FetchContent_MakeAvailable() calls the provider once per dependency, at
# every level of the build, with the details of the dependency's
# FetchContent_Declare(). The provider records them and returns without
# making the dependency available, so FetchContent populates it the usual
# way. When the top-level CMakeLists.txt is done, a deferred call reads
# where FetchContent put each dependency, resolves git tags to commits, and
# writes everything to the file in CMAKE_PURIFIER_OBSERVED for
# `cmake-purifier lock` to hash.

include_guard(GLOBAL)
include(FetchContent)

if(NOT CMAKE_PURIFIER_OBSERVED)
  message(FATAL_ERROR "cmake-purifier: CMAKE_PURIFIER_OBSERVED names no file; run the lock through `cmake-purifier lock`")
endif()

function(_cmake_purifier_provide method name)
  get_property(names GLOBAL PROPERTY CMAKE_PURIFIER_NAMES)
  # FetchContent keeps the first declaration of a name, so the provider
  # records the first call of each name only.
  if(name IN_LIST names)
    return()
  endif()
  cmake_parse_arguments(PARSE_ARGV 2 arg
    ""
    "GIT_REPOSITORY;DOWNLOAD_NO_EXTRACT"
    "URL;GIT_SUBMODULES"
  )
  if(DEFINED arg_URL)
    list(GET arg_URL 0 url)
    if(NOT url MATCHES "^[A-Za-z][A-Za-z0-9+.-]*://" OR url MATCHES "^file://")
      # A file in the build's own source tree is not a download.
      return()
    endif()
    set(type url)
  elseif(DEFINED arg_GIT_REPOSITORY)
    set(url "${arg_GIT_REPOSITORY}")
    if(NOT url MATCHES "^[A-Za-z][A-Za-z0-9+.-]*://" AND NOT url MATCHES "^[^/]+@[^/]+:")
      message(FATAL_ERROR "cmake-purifier: dependency ${name} names the local git repository ${url}; the lock records remote repositories only")
    endif()
    set(type git)
  else()
    message(FATAL_ERROR "cmake-purifier: dependency ${name} is neither a URL nor a GIT_REPOSITORY download; the lock records those two kinds only")
  endif()
  # GIT_SUBMODULES given with no value means no submodules. FetchContent's
  # default, and a list of submodules, both lock all of them.
  set(submodules true)
  if("GIT_SUBMODULES" IN_LIST arg_KEYWORDS_MISSING_VALUES)
    set(submodules false)
  endif()
  set(extract true)
  if(arg_DOWNLOAD_NO_EXTRACT)
    set(extract false)
  endif()
  set_property(GLOBAL APPEND PROPERTY CMAKE_PURIFIER_NAMES "${name}")
  set_property(GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_TYPE" "${type}")
  set_property(GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_URL" "${url}")
  set_property(GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_SUBMODULES" "${submodules}")
  set_property(GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_EXTRACT" "${extract}")
endfunction()

# A JSON string literal of a CMake string.
function(_cmake_purifier_json_string out value)
  string(REPLACE "\\" "\\\\" value "${value}")
  string(REPLACE "\"" "\\\"" value "${value}")
  set(${out} "\"${value}\"" PARENT_SCOPE)
endfunction()

function(_cmake_purifier_write)
  get_property(names GLOBAL PROPERTY CMAKE_PURIFIER_NAMES)
  set(entries "[]")
  set(index 0)
  foreach(name IN LISTS names)
    get_property(type GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_TYPE")
    get_property(url GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_URL")
    get_property(submodules GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_SUBMODULES")
    get_property(extract GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_EXTRACT")
    FetchContent_GetProperties(${name} SOURCE_DIR source_dir POPULATED populated)
    if(NOT populated)
      message(FATAL_ERROR "cmake-purifier: FetchContent did not populate dependency ${name}")
    endif()
    _cmake_purifier_json_string(json_name "${name}")
    _cmake_purifier_json_string(json_url "${url}")
    set(entry "{\"name\":${json_name},\"type\":\"${type}\",\"url\":${json_url}}")
    if(type STREQUAL "git")
      find_package(Git REQUIRED QUIET)
      execute_process(
        COMMAND "${GIT_EXECUTABLE}" rev-parse HEAD
        WORKING_DIRECTORY "${source_dir}"
        OUTPUT_VARIABLE rev
        OUTPUT_STRIP_TRAILING_WHITESPACE
        COMMAND_ERROR_IS_FATAL ANY
      )
      string(JSON entry SET "${entry}" rev "\"${rev}\"")
      string(JSON entry SET "${entry}" submodules "${submodules}")
    else()
      string(JSON entry SET "${entry}" extract "${extract}")
    endif()
    string(JSON entries SET "${entries}" ${index} "${entry}")
    math(EXPR index "${index} + 1")
  endforeach()
  _cmake_purifier_json_string(json_project "${CMAKE_PROJECT_NAME}")
  _cmake_purifier_json_string(json_version "${CMAKE_PROJECT_VERSION}")
  file(WRITE "${CMAKE_PURIFIER_OBSERVED}"
    "{\"project\":{\"name\":${json_project},\"version\":${json_version}},\"dependencies\":${entries}}\n")
endfunction()

cmake_language(
  SET_DEPENDENCY_PROVIDER _cmake_purifier_provide
  SUPPORTED_METHODS FETCHCONTENT_MAKEAVAILABLE_SERIAL
)

# The deferred call runs at the end of the directory that includes this
# file, the top-level source directory, after every add_subdirectory().
cmake_language(DEFER CALL _cmake_purifier_write)
