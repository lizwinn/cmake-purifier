# SPDX-License-Identifier: MIT
#
# Writes the initial cache that points FetchContent at the locked sources.
#
#   bash write-cache.sh <sources tree> <copies dir> <cache file> <provider>
#
# <sources tree> is the `tree` of sources.nix: an entry per FetchContent
# name. Some builds write into their dependencies' source directories, and
# the store is read-only, so each source is copied into <copies dir>
# first. A copy is made again only when its store path changes.
#
# The cache file sets FETCHCONTENT_SOURCE_DIR_<NAME> for every dependency,
# where <NAME> is the FetchContent name in upper case, as FetchContent
# spells it. FETCHCONTENT_FULLY_DISCONNECTED stops FetchContent from
# downloading anything else, and FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
# makes every declared dependency come from its source, as in the lock run.
# <provider> is cmake/CMakePurifierLocked.cmake, which the cache names in
# CMAKE_PROJECT_TOP_LEVEL_INCLUDES; it stops a configure that declares a
# dependency the lockfile does not hold. Every entry is FORCE, so
# `cmake -C` with this file also updates an existing build directory.
set -eu

tree=$1
copies=$2
cache=$3
provider=$4

mkdir -p "$copies"
{
  echo '# Written by cmake-purifier from the lockfile; do not edit.'
  echo 'set(FETCHCONTENT_FULLY_DISCONNECTED ON CACHE BOOL "" FORCE)'
  echo 'set(FETCHCONTENT_TRY_FIND_PACKAGE_MODE NEVER CACHE STRING "" FORCE)'
  printf 'set(CMAKE_PROJECT_TOP_LEVEL_INCLUDES "%s" CACHE STRING "" FORCE)\n' "$provider"
} > "$cache.tmp"
locked=

for entry in "$tree"/*; do
  [ -e "$entry" ] || continue
  name=$(basename "$entry")
  store=$(readlink -f "$entry")
  copy="$copies/$name"
  if [ "$(cat "$copy.source" 2>/dev/null || true)" != "$store" ]; then
    if [ -e "$copy" ]; then
      chmod -R u+w "$copy"
      rm -rf "$copy"
    fi
    # $store is the resolved directory, and -R copies the symlinks inside
    # it as symlinks.
    cp -R "$store" "$copy"
    chmod -R u+w "$copy"
    echo "$store" > "$copy.source"
  fi
  upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  printf 'set(FETCHCONTENT_SOURCE_DIR_%s "%s" CACHE PATH "" FORCE)\n' "$upper" "$copy" >> "$cache.tmp"
  locked="$locked${locked:+;}$name"
done
printf 'set(CMAKE_PURIFIER_LOCKED "%s" CACHE INTERNAL "")\n' "$locked" >> "$cache.tmp"

mv "$cache.tmp" "$cache"
