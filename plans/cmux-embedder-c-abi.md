# cmux embedder C ABI

Design sketch for the C ABI the cmux Chromium fork will export from `//cmux/embedder/`. `Packages/CmuxBrowserEngine`'s `ChromiumBrowserBackend` is the only consumer. The ABI is the long-lived contract between two repos: this one and the fork at `manaflow-ai/cmux-chromium` (to be created).

Design constraints, in priority order:

1. **C, not C++.** Stable, callable from Swift via a `module.modulemap` without bridging types.
2. **No `std::*` or Chromium internals leaking.** Pointer-by-pointer ownership, opaque handles. The Swift side never sees a `WebContents*`.
3. **Callable from MainActor Swift.** Every method runs on the browser process main thread. Threading inside the embedder is invisible to Swift.
4. **Small.** The ABI mirrors only what `CmuxBrowserEngine`'s wrapper actually calls. Less is more — every method is a maintenance debt across upstream Chromium rebases.
5. **Stable across upstream rebases.** No field unions, no exposed structs that aren't versioned, no opaque pointer reinterpretation.

## Header sketch

```c
// cmux_browser.h — exported from CmuxCore.framework.
// Generated and maintained at //cmux/embedder/cmux_browser.h in the
// cmux Chromium fork. Consumed by CmuxBrowserEngine via a modulemap.

#ifndef CMUX_EMBEDDER_CMUX_BROWSER_H_
#define CMUX_EMBEDDER_CMUX_BROWSER_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ABI revision. Bump on any breaking change. CmuxBrowserEngine asserts
// at framework load.
#define CMUX_EMBEDDER_ABI_VERSION 1

// Opaque handles. The Swift side never inspects layout.
typedef struct cmux_session_  cmux_session_t;   // process-wide singleton
typedef struct cmux_profile_  cmux_profile_t;   // ~= WKWebsiteDataStore
typedef struct cmux_view_     cmux_view_t;      // ~= WKWebView
typedef struct cmux_nav_      cmux_nav_t;       // ~= WKNavigation handle

// Errors.
typedef enum cmux_status_ {
    CMUX_OK = 0,
    CMUX_E_ABI_MISMATCH = 1,
    CMUX_E_ALREADY_INITIALIZED = 2,
    CMUX_E_NOT_INITIALIZED = 3,
    CMUX_E_INVALID_ARG = 4,
    CMUX_E_NATIVE = 5,         // see cmux_session_last_error_string()
} cmux_status_t;

// --- Lifecycle ---

// Called once per process. argv must include the helper bundle paths
// resolved by the host (browser process passes them to the helpers).
// Returns CMUX_OK or CMUX_E_ABI_MISMATCH if abi_version doesn't match
// the framework's exported CMUX_EMBEDDER_ABI_VERSION.
cmux_status_t cmux_session_init(uint32_t abi_version,
                                int argc, const char* const* argv,
                                cmux_session_t** out_session);

// Shutdown is best-effort; on macOS we typically just exit().
void cmux_session_shutdown(cmux_session_t* session);

// Pump the browser-process message loop once. Hosts that already run
// a CFRunLoop call this from a CFRunLoopSource. The implementation is
// idempotent and reentrant-safe.
void cmux_session_run_once(cmux_session_t* session);

// Diagnostic. Caller does not free; lifetime is until the next call.
const char* cmux_session_last_error_string(cmux_session_t* session);

// --- Profiles ---

// Creates or fetches a profile. Profiles map to disk under
// {user-data-dir}/{name}; default user-data-dir is "{HOME}/Library/
// Application Support/cmux/CmuxCore". Pass NULL for ephemeral.
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

// --- Views ---

typedef struct cmux_view_config_ {
    cmux_profile_t* profile;          // required
    bool javascript_enabled;          // default true
    bool allows_inline_media;         // default true
    bool media_requires_user_action;  // default false
    const char* user_agent_or_null;
    const char* application_name_or_null;
} cmux_view_config_t;

// On return, *out_view is owned by the caller. *out_ns_view is a
// CFTypeRef of an NSView the caller adds to the AppKit hierarchy.
// The NSView's content is backed by a CALayerHost bound to the GPU
// helper's CAContext. Caller releases the NSView normally; calling
// cmux_view_close releases the engine-side WebContents.
cmux_status_t cmux_view_create(cmux_session_t* session,
                               const cmux_view_config_t* config,
                               cmux_view_t** out_view,
                               void** out_ns_view);

void cmux_view_close(cmux_view_t* view);

// --- Navigation ---

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

// --- JS evaluation ---

typedef void (*cmux_js_callback)(
    void* userdata,
    const char* json_value_or_null,   // JSON-encoded result, or NULL on error
    const char* error_or_null);

void cmux_view_evaluate_js(cmux_view_t* view,
                           const char* source, size_t source_len,
                           void* userdata,
                           cmux_js_callback callback);

// --- Script messages (page → host) ---

typedef void (*cmux_script_message_handler)(
    void* userdata,
    const char* name,
    const char* frame_url_or_null,
    bool is_main_frame,
    const char* json_body);

void cmux_view_set_script_message_handler(
    cmux_view_t* view, void* userdata,
    cmux_script_message_handler handler);

// --- User scripts ---

typedef enum cmux_injection_time_ {
    CMUX_INJECT_AT_DOCUMENT_START = 0,
    CMUX_INJECT_AT_DOCUMENT_END = 1,
} cmux_injection_time_t;

void cmux_view_add_user_script(cmux_view_t* view,
                               const char* source, size_t source_len,
                               cmux_injection_time_t injection_time,
                               bool for_main_frame_only);

void cmux_view_remove_all_user_scripts(cmux_view_t* view);

// --- Navigation delegate (host ← engine) ---

typedef struct cmux_navigation_event_ {
    uint64_t nav_id;
    const char* url;
    bool is_main_frame;
    bool is_provisional;
    int32_t navigation_type;  // matches CmuxNavigationAction.NavigationType
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

// --- Snapshot ---

typedef void (*cmux_snapshot_cb)(
    void* userdata,
    const uint8_t* png_bytes,
    size_t png_len,
    const char* error_or_null);

void cmux_view_take_snapshot(cmux_view_t* view,
                             int32_t width, int32_t height,
                             void* userdata,
                             cmux_snapshot_cb cb);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // CMUX_EMBEDDER_CMUX_BROWSER_H_
```

## Ownership rules

- Sessions, profiles, views are caller-owned via opaque pointers. Caller invokes the corresponding `*_close()` to release.
- `cmux_view_t` owns no AppKit objects; the `NSView` returned from `cmux_view_create` is reference-counted by AppKit normally. Closing the view releases the engine-side WebContents but the NSView stays alive until AppKit drops it.
- Strings handed back via accessors (`cmux_view_url`, `cmux_view_title`, `cmux_session_last_error_string`) are valid until the next message-loop pump. Copy if you need to outlive that.
- Strings passed in are copied by the embedder.
- Callbacks may be invoked on the browser-process main thread only.

## Why JSON instead of binary for JS / script messages

`cmux_view_evaluate_js` and the script message handler both pass JSON strings rather than typed unions. This is a deliberate compromise:

- The wrapper already walks `WKScriptMessage.body`'s `Any?` into `CmuxScriptMessageBody`. JSON-walk on the Swift side mirrors that.
- A typed union would need separate ABI types for null, bool, int, double, string, array, dictionary, data, plus length-prefixing for each. That's a lot of surface for a small win.
- Chromium has well-tested `base::Value` → JSON in both directions; cost of JSON serialize/deserialize is microseconds per call.

If a hot path (e.g. high-frequency mouse events serialized as messages) shows up in profiling, add a binary path then. Don't add it speculatively.

## Versioning

`CMUX_EMBEDDER_ABI_VERSION` is the only required version surface. Bump on any *breaking* change (struct layout, semantic change in an enum value, function signature). New methods may be added at the end of the header without bumping; consumers detect new methods via `dlsym` or weak-link.

The fork keeps a CHANGELOG at `//cmux/embedder/CHANGELOG.md`. CmuxBrowserEngine asserts the loaded framework's version is `>= CMUX_EMBEDDER_MIN_ABI` (the minimum it knows how to talk to) and `<= CMUX_EMBEDDER_MAX_ABI`. The minimum and maximum are pinned in the package's `CmuxBrowserEngine.swift`.

## What's intentionally out

These belong to subsequent ABI revisions, not v1:

- Downloads. Migration order from `wkwebview-surface-audit.md` puts downloads after the data-store work.
- Find-in-page (Chromium has `FindRequest`/`FindReply` Mojo; expose as `cmux_view_find_*`).
- DevTools / inspector.
- Print.
- WebAuthn surface (Chromium handles internally; verify behavior parity is enough).
- Extensions (massive surface; only meaningful in P4).
- WebRTC/getUserMedia permission decisions.
- Push notifications.

## File layout in the fork

```
src/cmux/embedder/
├── BUILD.gn                       # source_set + framework target wiring
├── CHANGELOG.md                   # ABI version history
├── cmux_browser.h                 # this header, source of truth
├── cmux_browser.mm                # Objective-C++ glue, talks to content::
├── cmux_view.cc                   # WebContentsDelegate impl + NSView host
├── cmux_session.cc                # process-startup, helper-app spawn
├── cmux_profile.cc                # BrowserContext wrappers
└── cmux_layer_host.mm             # CAContext / CALayerHost integration
```

The framework target itself lives at `//cmux:cmux_core_framework`; `//cmux/embedder` is its only public surface.
