# SPDX-License-Identifier: MIT
#
# The dependency provider of the lock run. `cmake-purifier lock` names this
# file in CMAKE_PROJECT_TOP_LEVEL_INCLUDES, so CMake includes it at the
# first project() call of the build, before any CMakeLists.txt declares a
# dependency.
#
# The lock run records every download through its proxy and its git
# wrapper, whatever CMake command makes it. This provider adds what those
# two cannot see: which FetchContent dependency each download belongs to.
# FetchContent_MakeAvailable() calls the provider once per dependency, at
# every level of the build. The provider records the name and the
# declared download, and returns without making the dependency available,
# so FetchContent populates it the usual way. When the top-level
# CMakeLists.txt is done, a deferred call writes, for each dependency,
# where FetchContent put it, to the file in CMAKE_PURIFIER_OBSERVED.

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
  cmake_parse_arguments(PARSE_ARGV 2 arg "" "GIT_REPOSITORY;DOWNLOAD_NO_EXTRACT" "URL")
  if(DEFINED arg_URL)
    list(GET arg_URL 0 url)
    if(NOT url MATCHES "^[A-Za-z][A-Za-z0-9+.-]*://" OR url MATCHES "^file://")
      # A file in the build's own source tree is not a download.
      return()
    endif()
    set(type url)
  elseif(DEFINED arg_GIT_REPOSITORY)
    set(url "${arg_GIT_REPOSITORY}")
    set(type git)
  else()
    message(FATAL_ERROR "cmake-purifier: dependency ${name} is neither a URL nor a GIT_REPOSITORY download; the lock records those two kinds only")
  endif()
  set(extract true)
  if(arg_DOWNLOAD_NO_EXTRACT)
    set(extract false)
  endif()
  set_property(GLOBAL APPEND PROPERTY CMAKE_PURIFIER_NAMES "${name}")
  set_property(GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_TYPE" "${type}")
  set_property(GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_URL" "${url}")
  # Every URL of a URL download, which CMake tries in order.
  set_property(GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_URLS" "${arg_URL}")
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
    get_property(urls GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_URLS")
    get_property(extract GLOBAL PROPERTY "CMAKE_PURIFIER_${name}_EXTRACT")
    FetchContent_GetProperties(${name} SOURCE_DIR source_dir POPULATED populated)
    if(NOT populated)
      message(FATAL_ERROR "cmake-purifier: FetchContent did not populate dependency ${name}")
    endif()
    _cmake_purifier_json_string(json_name "${name}")
    _cmake_purifier_json_string(json_url "${url}")
    _cmake_purifier_json_string(json_source_dir "${source_dir}")
    set(json_urls "[]")
    set(url_index 0)
    foreach(each IN LISTS urls)
      _cmake_purifier_json_string(json_each "${each}")
      string(JSON json_urls SET "${json_urls}" ${url_index} "${json_each}")
      math(EXPR url_index "${url_index} + 1")
    endforeach()
    set(entry "{\"name\":${json_name},\"type\":\"${type}\",\"url\":${json_url},\"urls\":${json_urls},\"sourceDir\":${json_source_dir},\"extract\":${extract}}")
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
