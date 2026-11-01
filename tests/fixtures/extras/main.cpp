// SPDX-License-Identifier: MIT
#include <argparse/argparse.hpp>
#include <cxxopts.hpp>
#include <nonstd/expected.hpp>
#include <zlib.h>

#include <iostream>
#include <string>

static nonstd::expected<int, std::string> parse_count(const std::string &text) {
  try {
    return std::stoi(text);
  } catch (...) {
    return nonstd::make_unexpected("not a number: " + text);
  }
}

int main(int argc, char **argv) {
  argparse::ArgumentParser program("extras");
  program.add_argument("--count").default_value(std::string("3"));
  program.parse_args(argc, argv);

  cxxopts::Options options("extras", "the cxxopts header is here");
  (void)options;

  auto count = parse_count(program.get<std::string>("--count"));
  if (!count) {
    std::cerr << count.error() << "\n";
    return 1;
  }
  std::cout << "count " << *count << ", zlib " << zlibVersion() << "\n";
  return 0;
}
