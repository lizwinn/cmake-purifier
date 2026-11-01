# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The `cmake-purifier` command: `lock` and `configure`.
  cmake-purifier = callPackage ./cmake-purifier { };
}
