// Copyright 2026 manaflow-ai. All rights reserved.
//
// cmux_session.cc -- stub implementation of the session lifecycle
// portion of the cmux embedder C ABI.
//
// Lands at src/cmux/embedder/cmux_session.cc in the fork. The stubs
// here let the framework link and load cleanly: cmux_session_init
// accepts a matching abi_version and returns a sentinel session
// handle; everything else either no-ops or reports
// CMUX_E_NATIVE via cmux_session_last_error_string. Real
// integration with //content's BrowserMainRunner replaces these
// bodies; the goal of the stub is to give the framework a valid
// link target before the content layer is wired.

#include "cmux/embedder/cmux_browser.h"

#include <cstring>

namespace {

// Stub session handle. A real implementation owns a
// content::BrowserMainRunner here. The struct shape is opaque to
// callers; only its address is meaningful.
struct CmuxSessionImpl {
  const char* last_error;
  bool initialized;
};

// Single process-wide instance. cmux_session_init enforces this:
// re-init while still initialized returns CMUX_E_ALREADY_INITIALIZED.
CmuxSessionImpl g_session = {nullptr, false};

constexpr const char* kNotImplemented =
    "cmux embedder is a stub build; real content layer is not wired";

}  // namespace

extern "C" {

cmux_status_t cmux_session_init(uint32_t abi_version,
                                int /*argc*/,
                                const char* const* /*argv*/,
                                cmux_session_t** out_session) {
  if (abi_version != CMUX_EMBEDDER_ABI_VERSION) {
    g_session.last_error = "ABI version mismatch";
    return CMUX_E_ABI_MISMATCH;
  }
  if (out_session == nullptr) {
    g_session.last_error = "out_session must not be NULL";
    return CMUX_E_INVALID_ARG;
  }
  if (g_session.initialized) {
    g_session.last_error = "session already initialized";
    return CMUX_E_ALREADY_INITIALIZED;
  }
  g_session.initialized = true;
  g_session.last_error = nullptr;
  *out_session = reinterpret_cast<cmux_session_t*>(&g_session);
  return CMUX_OK;
}

void cmux_session_shutdown(cmux_session_t* session) {
  if (session == nullptr) {
    return;
  }
  g_session.initialized = false;
  g_session.last_error = nullptr;
}

void cmux_session_run_once(cmux_session_t* /*session*/) {
  // No-op in the stub. The real implementation pumps the browser
  // process MessageLoop once.
}

const char* cmux_session_last_error_string(cmux_session_t* session) {
  if (session == nullptr) {
    return "session handle is NULL";
  }
  return g_session.last_error == nullptr ? "" : g_session.last_error;
}

// Helper used by the other stub TUs.
void cmux_internal_set_last_error(const char* msg) {
  g_session.last_error = msg == nullptr ? kNotImplemented : msg;
}

}  // extern "C"
