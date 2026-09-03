// Copyright 2026 manaflow-ai. All rights reserved.
//
// cmux_browser.mm -- stub implementation of the view-creation portion
// of the cmux embedder C ABI. This translation unit is Obj-C++ because
// a real cmux_view_create wires up an NSView that hosts a CALayerHost
// bound to the GPU helper's CAContext. In the stub it returns
// CMUX_E_NATIVE and never produces an NSView, but the file still has
// to compile/link so the framework has something to consume at the
// platform layer.
//
// Lands at src/cmux/embedder/cmux_browser.mm in the fork.

#import <AppKit/AppKit.h>

#include "cmux/embedder/cmux_browser.h"

extern "C" {

void cmux_internal_set_last_error(const char* msg);

cmux_status_t cmux_view_create(cmux_session_t* /*session*/,
                               const cmux_view_config_t* /*config*/,
                               cmux_view_t** /*out_view*/,
                               void** out_ns_view) {
  // Sentinel: the stub does not produce a backing NSView.
  if (out_ns_view != nullptr) {
    *out_ns_view = nullptr;
  }
  cmux_internal_set_last_error("cmux_view_create: stub");
  return CMUX_E_NATIVE;
}

void cmux_view_close(cmux_view_t* /*view*/) {
  // No-op in the stub.
}

}  // extern "C"
