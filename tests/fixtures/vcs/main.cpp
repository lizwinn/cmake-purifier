// SPDX-License-Identifier: MIT
#include <cvs.h>
#include <hg.h>
#include <svn.h>

#include <iostream>

int main() {
  std::cout << svn_text() << " " << hg_text() << " " << cvs_text() << "\n";
  return 0;
}
