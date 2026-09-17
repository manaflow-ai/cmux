// Copyright 2026 manaflow-ai. All rights reserved.
//
// cmux_framework_main.cc -- placeholder TU for the cmux_core_framework
// target. mac_framework_bundle in chromium's GN templates requires at
// least one source file directly on the target; the actual framework
// content comes via :embedder. This file exists only to satisfy the
// "non-empty sources" constraint until the framework's own glue moves
// here (entry-point ABI version reporter, etc.).
//
// Lands at src/cmux/embedder/cmux_framework_main.cc in the fork.

#include "cmux/embedder/cmux_browser.h"

extern "C" {

// Diagnostic: a real consumer can dlsym this and assert at framework
// load to confirm the binary was compiled against the ABI version
// they expect.
unsigned int cmux_framework_abi_version(void) {
  return CMUX_EMBEDDER_ABI_VERSION;
}

}  // extern "C"
