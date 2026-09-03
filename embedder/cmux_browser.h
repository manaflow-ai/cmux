// Copyright 2026 manaflow-ai. All rights reserved.
//
// cmux_browser.h — C ABI exported from CmuxCore.framework.
//
// Source of truth for the Swift wrapper at
// Packages/CmuxBrowserEngine/Sources/CmuxBrowserEngine/ChromiumBrowserBackend.swift
// in the manaflow-ai/cmux repo. Consumed via a modulemap.
//
// Design constraints (in priority order):
//
//   1. C, not C++. Stable, callable from Swift via a module.modulemap
//      with no bridging types.
//   2. No std::* or Chromium internals leak. Pointer-by-pointer
//      ownership, opaque handles. The Swift side never sees a
//      content::WebContents*.
//   3. Callable from MainActor Swift. Every method runs on the
//      browser-process main thread. Threading inside the embedder is
//      invisible to Swift.
//   4. Small. The ABI mirrors only what CmuxBrowserEngine's wrapper
//      actually calls. Every method is maintenance debt across
//      upstream Chromium rebases.
//   5. Stable across upstream rebases. No field unions, no exposed
//      structs that aren't versioned, no opaque pointer reinterpret.
//
// All `cmux_*_close()` functions are idempotent. All callbacks run on
// the browser-process main thread. Strings passed in are copied;
// strings handed back via accessors are valid until the next message-
// loop pump.

#ifndef CMUX_EMBEDDER_CMUX_BROWSER_H_
#define CMUX_EMBEDDER_CMUX_BROWSER_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ABI revision. Bump on any breaking change. The Swift package asserts
// at framework load.
#define CMUX_EMBEDDER_ABI_VERSION 1

// ---------- Opaque handles ----------

typedef struct cmux_session_  cmux_session_t;   // process-wide singleton
typedef struct cmux_profile_  cmux_profile_t;   // ~ WKWebsiteDataStore
typedef struct cmux_view_     cmux_view_t;      // ~ WKWebView
typedef struct cmux_nav_      cmux_nav_t;       // ~ WKNavigation handle

// ---------- Status / errors ----------

typedef enum cmux_status_ {
    CMUX_OK = 0,
    CMUX_E_ABI_MISMATCH       = 1,
    CMUX_E_ALREADY_INITIALIZED = 2,
    CMUX_E_NOT_INITIALIZED    = 3,
    CMUX_E_INVALID_ARG        = 4,
    CMUX_E_NATIVE             = 5,  // see cmux_session_last_error_string()
} cmux_status_t;

// ---------- Session lifecycle ----------

// Called once per process. argv must include the helper-bundle paths
// resolved by the host so the browser process can hand them to the
// helper processes. Returns CMUX_OK or CMUX_E_ABI_MISMATCH if
// abi_version doesn't match the framework's CMUX_EMBEDDER_ABI_VERSION.
cmux_status_t cmux_session_init(uint32_t abi_version,
                                int argc,
                                const char* const* argv,
                                cmux_session_t** out_session);

// Shutdown is best-effort; on macOS we typically just exit().
void cmux_session_shutdown(cmux_session_t* session);

// Pump the browser-process message loop once. Hosts that already run
// a CFRunLoop call this from a CFRunLoopSource. Idempotent and
// reentrant-safe.
void cmux_session_run_once(cmux_session_t* session);

// Diagnostic. Caller does not free; lifetime is until the next call.
const char* cmux_session_last_error_string(cmux_session_t* session);

// ---------- Profiles ----------

// Creates or fetches a profile. Profiles map to disk under
//   {user-data-dir}/{name}
// where {user-data-dir} defaults to
//   {HOME}/Library/Application Support/cmux/CmuxCore
// Pass NULL for an ephemeral (in-memory) profile.
cmux_status_t cmux_profile_open(cmux_session_t* session,
                                const char* name_or_null,
                                cmux_profile_t** out_profile);

void cmux_profile_close(cmux_profile_t* profile);

// Cookies. Iteration uses a callback because the cookie set is mutable.
typedef void (*cmux_cookie_visitor)(
    void* userdata,
    const char* name, const char* value,
    const char* domain, const char* path,
    int64_t expires_unix_ms,
    bool secure, bool http_only);

cmux_status_t cmux_profile_get_cookies(cmux_profile_t* profile,
                                       const char* url_or_null,
                                       void* userdata,
                                       cmux_cookie_visitor visitor);

cmux_status_t cmux_profile_set_cookie(cmux_profile_t* profile,
                                      const char* name, const char* value,
                                      const char* domain, const char* path,
                                      int64_t expires_unix_ms,
                                      bool secure, bool http_only);

cmux_status_t cmux_profile_delete_cookie(cmux_profile_t* profile,
                                         const char* name,
                                         const char* domain,
                                         const char* path);

// Clear browsing data for this profile. `data_types_mask` is the OR of
// cmux_data_type_* below. `since_unix_ms` ≥ 0; pass INT64_MIN for "all
// time".
typedef uint32_t cmux_data_type_mask_t;
#define CMUX_DATA_COOKIES        (1u << 0)
#define CMUX_DATA_LOCAL_STORAGE  (1u << 1)
#define CMUX_DATA_INDEXED_DB     (1u << 2)
#define CMUX_DATA_CACHE          (1u << 3)
#define CMUX_DATA_SERVICE_WORKERS (1u << 4)
#define CMUX_DATA_ALL            (~0u)

cmux_status_t cmux_profile_remove_data(cmux_profile_t* profile,
                                       cmux_data_type_mask_t mask,
                                       int64_t since_unix_ms);

// ---------- Views ----------

typedef struct cmux_view_config_ {
    cmux_profile_t* profile;          // required
    bool javascript_enabled;          // default true
    bool allows_inline_media;         // default true
    bool media_requires_user_action;  // default false
    const char* user_agent_or_null;
    const char* application_name_or_null;
} cmux_view_config_t;

// On success, *out_view is owned by the caller. *out_ns_view is a
// CFTypeRef of an NSView the caller adds to the AppKit hierarchy.
// The NSView's content is backed by a CALayerHost bound to the GPU
// helper's CAContext. AppKit refcounts the NSView normally; calling
// cmux_view_close releases the engine-side WebContents.
cmux_status_t cmux_view_create(cmux_session_t* session,
                               const cmux_view_config_t* config,
                               cmux_view_t** out_view,
                               void** out_ns_view);

void cmux_view_close(cmux_view_t* view);

// ---------- Navigation ----------

cmux_nav_t* cmux_view_load_url(cmux_view_t* view, const char* url);
cmux_nav_t* cmux_view_load_html(cmux_view_t* view,
                                const char* html, size_t html_len,
                                const char* base_url_or_null);
cmux_nav_t* cmux_view_reload(cmux_view_t* view);
cmux_nav_t* cmux_view_go_back(cmux_view_t* view);
cmux_nav_t* cmux_view_go_forward(cmux_view_t* view);
void cmux_view_stop(cmux_view_t* view);
bool cmux_view_can_go_back(cmux_view_t* view);
bool cmux_view_can_go_forward(cmux_view_t* view);

// URL/title are valid until the next message-loop pump. Copy if you
// need to outlive that.
const char* cmux_view_url(cmux_view_t* view);
const char* cmux_view_title(cmux_view_t* view);
bool        cmux_view_is_loading(cmux_view_t* view);
double      cmux_view_estimated_progress(cmux_view_t* view);

// Page zoom factor. 1.0 = no zoom.
void   cmux_view_set_page_zoom(cmux_view_t* view, double zoom);
double cmux_view_page_zoom(cmux_view_t* view);

// ---------- JS evaluation ----------

typedef void (*cmux_js_callback)(
    void* userdata,
    const char* json_value_or_null,  // JSON-encoded result, NULL on error
    const char* error_or_null);

void cmux_view_evaluate_js(cmux_view_t* view,
                           const char* source, size_t source_len,
                           void* userdata,
                           cmux_js_callback callback);

// ---------- Script messages (page → host) ----------

typedef void (*cmux_script_message_handler)(
    void* userdata,
    const char* name,
    const char* frame_url_or_null,
    bool is_main_frame,
    const char* json_body);

void cmux_view_set_script_message_handler(
    cmux_view_t* view, void* userdata,
    cmux_script_message_handler handler);

// ---------- User scripts ----------

typedef enum cmux_injection_time_ {
    CMUX_INJECT_AT_DOCUMENT_START = 0,
    CMUX_INJECT_AT_DOCUMENT_END   = 1,
} cmux_injection_time_t;

void cmux_view_add_user_script(cmux_view_t* view,
                               const char* source, size_t source_len,
                               cmux_injection_time_t injection_time,
                               bool for_main_frame_only);

void cmux_view_remove_all_user_scripts(cmux_view_t* view);

// ---------- Navigation delegate (host ← engine) ----------

typedef struct cmux_navigation_event_ {
    uint64_t nav_id;
    const char* url;
    bool is_main_frame;
    bool is_provisional;
    int32_t navigation_type;     // matches CmuxNavigationAction.NavigationType
    int32_t button_number;
    uint32_t modifier_flags;
    bool should_perform_download;
} cmux_navigation_event_t;

typedef int32_t cmux_nav_decision_t;
#define CMUX_NAV_ALLOW    0
#define CMUX_NAV_CANCEL   1
#define CMUX_NAV_DOWNLOAD 2

typedef cmux_nav_decision_t (*cmux_navigation_action_cb)(
    void* userdata, const cmux_navigation_event_t* evt);

typedef void (*cmux_navigation_terminal_cb)(
    void* userdata, uint64_t nav_id,
    const char* url, bool succeeded,
    const char* error_message_or_null);

void cmux_view_set_navigation_action_cb(cmux_view_t* view,
                                        void* userdata,
                                        cmux_navigation_action_cb cb);

void cmux_view_set_navigation_did_finish_cb(cmux_view_t* view,
                                            void* userdata,
                                            cmux_navigation_terminal_cb cb);

// ---------- Snapshot ----------

typedef void (*cmux_snapshot_cb)(
    void* userdata,
    const uint8_t* png_bytes,
    size_t png_len,
    const char* error_or_null);

// Snapshot the current page. Width/height are device-independent
// pixels. Pass 0 for either to use the view's current bounds.
void cmux_view_take_snapshot(cmux_view_t* view,
                             int32_t width, int32_t height,
                             void* userdata,
                             cmux_snapshot_cb cb);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // CMUX_EMBEDDER_CMUX_BROWSER_H_
