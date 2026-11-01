// SPDX-License-Identifier: MIT
#include <argparse/argparse.hpp>
#include <fmt/format.h>

#include <string>

int main(int argc, char **argv) {
  argparse::ArgumentParser program("greet", "1.2.3");
  program.add_argument("--name").default_value(std::string("world"));
  program.parse_args(argc, argv);
  fmt::print("Hello, {}!\n", program.get<std::string>("--name"));
  return 0;
}
