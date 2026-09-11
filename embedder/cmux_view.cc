// Copyright 2026 manaflow-ai. All rights reserved.
//
// cmux_view.cc -- stub implementations of the view accessors,
// navigation, JS, user-script, and snapshot portions of the cmux
// embedder C ABI. Lands at src/cmux/embedder/cmux_view.cc in the
// fork. NSView creation and CALayerHost wiring live in the .mm
// translation units (cmux_browser.mm / cmux_layer_host.mm); this
// file holds everything pure-C++ so it compiles without the AppKit
// SDK headers leaking into //content.

#include "cmux/embedder/cmux_browser.h"

extern "C" {

void cmux_internal_set_last_error(const char* msg);

// ---------- Navigation ----------

cmux_nav_t* cmux_view_load_url(cmux_view_t* /*view*/,
                               const char* /*url*/) {
  cmux_internal_set_last_error("cmux_view_load_url: stub");
  return nullptr;
}

cmux_nav_t* cmux_view_load_html(cmux_view_t* /*view*/,
                                const char* /*html*/,
                                size_t /*html_len*/,
                                const char* /*base_url_or_null*/) {
  cmux_internal_set_last_error("cmux_view_load_html: stub");
  return nullptr;
}

cmux_nav_t* cmux_view_reload(cmux_view_t* /*view*/) {
  cmux_internal_set_last_error("cmux_view_reload: stub");
  return nullptr;
}

cmux_nav_t* cmux_view_go_back(cmux_view_t* /*view*/) {
  cmux_internal_set_last_error("cmux_view_go_back: stub");
  return nullptr;
}

cmux_nav_t* cmux_view_go_forward(cmux_view_t* /*view*/) {
  cmux_internal_set_last_error("cmux_view_go_forward: stub");
  return nullptr;
}

void cmux_view_stop(cmux_view_t* /*view*/) {
  // No-op in the stub.
}

bool cmux_view_can_go_back(cmux_view_t* /*view*/) {
  return false;
}

bool cmux_view_can_go_forward(cmux_view_t* /*view*/) {
  return false;
}

// ---------- View accessors ----------

const char* cmux_view_url(cmux_view_t* /*view*/) {
  return "";
}

const char* cmux_view_title(cmux_view_t* /*view*/) {
  return "";
}

bool cmux_view_is_loading(cmux_view_t* /*view*/) {
  return false;
}

double cmux_view_estimated_progress(cmux_view_t* /*view*/) {
  return 0.0;
}

void cmux_view_set_page_zoom(cmux_view_t* /*view*/, double /*zoom*/) {
  // No-op in the stub.
}

double cmux_view_page_zoom(cmux_view_t* /*view*/) {
  return 1.0;
}

// ---------- JS evaluation ----------

void cmux_view_evaluate_js(cmux_view_t* /*view*/,
                           const char* /*source*/,
                           size_t /*source_len*/,
                           void* userdata,
                           cmux_js_callback callback) {
  if (callback != nullptr) {
    callback(userdata, nullptr, "cmux_view_evaluate_js: stub");
  }
}

// ---------- Script messages ----------

void cmux_view_set_script_message_handler(
    cmux_view_t* /*view*/,
    void* /*userdata*/,
    cmux_script_message_handler /*handler*/) {
  // No-op: the engine never receives postMessage calls in the stub.
}

// ---------- User scripts ----------

void cmux_view_add_user_script(cmux_view_t* /*view*/,
                               const char* /*source*/,
                               size_t /*source_len*/,
                               cmux_injection_time_t /*injection_time*/,
                               bool /*for_main_frame_only*/) {
  // No-op.
}

void cmux_view_remove_all_user_scripts(cmux_view_t* /*view*/) {
  // No-op.
}

// ---------- Navigation callbacks ----------

void cmux_view_set_navigation_action_cb(
    cmux_view_t* /*view*/,
    void* /*userdata*/,
    cmux_navigation_action_cb /*cb*/) {
  // No-op.
}

void cmux_view_set_navigation_did_finish_cb(
    cmux_view_t* /*view*/,
    void* /*userdata*/,
    cmux_navigation_terminal_cb /*cb*/) {
  // No-op.
}

// ---------- Snapshot ----------

void cmux_view_take_snapshot(cmux_view_t* /*view*/,
                             int32_t /*width*/,
                             int32_t /*height*/,
                             void* userdata,
                             cmux_snapshot_cb cb) {
  if (cb != nullptr) {
    cb(userdata, nullptr, 0, "cmux_view_take_snapshot: stub");
  }
}

}  // extern "C"
