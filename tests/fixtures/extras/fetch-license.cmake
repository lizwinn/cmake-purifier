# SPDX-License-Identifier: MIT
#
# Downloads fmt's license to OUT, at build time.
file(DOWNLOAD "https://raw.githubusercontent.com/fmtlib/fmt/11.1.4/LICENSE" "${OUT}" STATUS status)
list(GET status 0 code)
if(code)
  message(FATAL_ERROR "the license download failed: ${status}")
endif()
