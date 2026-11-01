// SPDX-License-Identifier: MIT
#define DOCTEST_CONFIG_IMPLEMENT_WITH_MAIN
#include "doctest.h"

#include <fmt/format.h>

TEST_CASE("fmt formats its arguments") {
  CHECK(fmt::format("{}-{}", 1, 2) == "1-2");
}
