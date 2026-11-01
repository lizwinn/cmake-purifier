# SPDX-License-Identifier: MIT
#
# Fails unless KEEP, a file of the listed submodule, exists, and DROP, a
# file of a submodule the list leaves out, does not.
if(NOT EXISTS "${KEEP}" OR EXISTS "${DROP}")
  message(FATAL_ERROR "the checkout holds other submodules than its GIT_SUBMODULES list: ${KEEP} must exist and ${DROP} must not")
endif()
