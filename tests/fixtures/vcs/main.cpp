// SPDX-License-Identifier: MIT
#include <a.h>
#include <b.h>
#include <cvs.h>
#include <hg.h>
#include <svn.h>

#include <iostream>

int main() {
  std::cout << svn_text() << " " << hg_text() << " " << cvs_text() << " "
            << sub_a_text() << " " << sub_b_text() << "\n";
  return 0;
}
