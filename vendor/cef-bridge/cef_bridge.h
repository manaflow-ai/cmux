// CEF bridge API for cmux.
//
// Wraps the CEF (Chromium Embedded Framework) C++ API behind a plain C
// interface so Swift can call it through the bridging header. Follows the
// same pattern as ghostty.h.
//
// CEF is loaded on-demand at runtime; all functions are no-ops until
// cef_bridge_initialize() succeeds.
#ifndef CEF_BRIDGE_H
#define CEF_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// -------------------------------------------------------------------
// Return codes
// -------------------------------------------------------------------

#define CEF_BRIDGE_OK             0
#define CEF_BRIDGE_ERR_NOT_INIT  -1
#define CEF_BRIDGE_ERR_INVALID   -2
#define CEF_BRIDGE_ERR_FAILED    -3

// -------------------------------------------------------------------
// Opaque handles
// -------------------------------------------------------------------

typedef void* cef_bridge_browser_t;
typedef void* cef_bridge_profile_t;
typedef void* cef_bridge_extension_t;

// -------------------------------------------------------------------
// Callback types
// -------------------------------------------------------------------

/// Called when an async JavaScript evaluation completes.
/// `request_id` is the caller-supplied correlation ID.
/// `json_result` is the JSON-encoded return value (NULL on error).
/// `error_message` is set when evaluation failed (NULL on success).
typedef void (*cef_bridge_js_callback)(
    int32_t request_id,
    const char* json_result,
    const char* error_message,
    void* user_data
);

/// Called during CEF framework download to report progress.
typedef void (*cef_bridge_download_progress_callback)(
    int64_t bytes_received,
    int64_t total_bytes,
    void* user_data
);

/// Navigation event callback.
typedef void (*cef_bridge_navigation_callback)(
    cef_bridge_browser_t browser,
    const char* url,
    bool is_main_frame,
    void* user_data
);

/// Title change callback.
typedef void (*cef_bridge_title_callback)(
    cef_bridge_browser_t browser,
    const char* title,
    void* user_data
);

/// URL change callback.
typedef void (*cef_bridge_url_callback)(
    cef_bridge_browser_t browser,
    const char* url,
    void* user_data
);

/// Loading state change callback.
typedef void (*cef_bridge_loading_state_callback)(
    cef_bridge_browser_t browser,
    bool is_loading,
    bool can_go_back,
    bool can_go_forward,
    void* user_data
);

/// Favicon URL change callback.
typedef void (*cef_bridge_favicon_callback)(
    cef_bridge_browser_t browser,
    const char** icon_urls,
    int icon_url_count,
    void* user_data
);

/// Fullscreen change callback.
typedef void (*cef_bridge_fullscreen_callback)(
    cef_bridge_browser_t browser,
    bool fullscreen,
    void* user_data
);

/// Popup request callback. Return true to allow, false to block.
typedef bool (*cef_bridge_popup_callback)(
    cef_bridge_browser_t browser,
    const char* target_url,
    void* user_data
);

/// Download request callback.
typedef void (*cef_bridge_download_callback)(
    cef_bridge_browser_t browser,
    const char* url,
    const char* suggested_filename,
    int64_t content_length,
    void* user_data
);

/// JavaScript dialog callback (alert, confirm, prompt).
typedef bool (*cef_bridge_jsdialog_callback)(
    cef_bridge_browser_t browser,
    int dialog_type,       // 0=alert, 1=confirm, 2=prompt
    const char* message,
    const char* default_value,
    void* user_data
);

/// Console message callback.
typedef void (*cef_bridge_console_callback)(
    cef_bridge_browser_t browser,
    int level,             // 0=debug, 1=info, 2=warning, 3=error
    const char* message,
    const char* source,
    int line,
    void* user_data
);

// -------------------------------------------------------------------
// Client callbacks struct (passed at browser creation)
// -------------------------------------------------------------------

typedef struct {
    cef_bridge_navigation_callback     on_navigation;
    cef_bridge_title_callback          on_title_change;
    cef_bridge_url_callback            on_url_change;
    cef_bridge_loading_state_callback  on_loading_state_change;
    cef_bridge_favicon_callback        on_favicon_change;
    cef_bridge_fullscreen_callback     on_fullscreen_change;
    cef_bridge_popup_callback          on_popup_request;
    cef_bridge_download_callback       on_download;
    cef_bridge_jsdialog_callback       on_jsdialog;
    cef_bridge_console_callback        on_console_message;
    cef_bridge_js_callback             on_js_result;
    void*                              user_data;
} cef_bridge_client_callbacks;

// -------------------------------------------------------------------
// Lifecycle
// -------------------------------------------------------------------

/// Check whether the CEF framework is present at the given path.
bool cef_bridge_framework_available(const char* framework_path);

/// Initialize CEF. Call once from the main thread after the framework
/// is available. `framework_path` is the directory containing
/// "Chromium Embedded Framework.framework".
/// `helper_path` is the path to the helper app bundle.
/// `cache_root` is the root directory for CEF cache data.
/// Returns CEF_BRIDGE_OK on success.
int cef_bridge_initialize(
    const char* framework_path,
    const char* helper_path,
    const char* cache_root
);

/// Pump the CEF message loop. Call this periodically from the main
/// thread (e.g. on a timer) when using external_message_pump mode.
void cef_bridge_do_message_loop_work(void);

/// Shut down CEF. Call once before app termination.
void cef_bridge_shutdown(void);

/// Returns true if CEF has been initialized.
bool cef_bridge_is_initialized(void);

// -------------------------------------------------------------------
// Profile management
// -------------------------------------------------------------------

/// Create an isolated browser profile with its own cookies, cache,
/// and storage. `cache_path` must be a unique directory per profile.
cef_bridge_profile_t cef_bridge_profile_create(const char* cache_path);

/// Destroy a profile and release its resources.
void cef_bridge_profile_destroy(cef_bridge_profile_t profile);

/// Clear all browsing data for a profile.
int cef_bridge_profile_clear_data(cef_bridge_profile_t profile);

// -------------------------------------------------------------------
// Browser view
// -------------------------------------------------------------------

/// Create a new browser view. The browser renders inside `parent_view`
/// (an NSView*). Pass NULL to create a hidden browser with no view.
/// `width` and `height` set the initial browser size.
/// The browser starts loading `initial_url` if non-NULL.
cef_bridge_browser_t cef_bridge_browser_create(
    cef_bridge_profile_t profile,
    const char* initial_url,
    void* parent_view,
    int width,
    int height,
    const cef_bridge_client_callbacks* callbacks
);

/// Destroy a browser and its associated view.
void cef_bridge_browser_destroy(cef_bridge_browser_t browser);

/// Get the underlying NSView* for embedding in the view hierarchy.
/// The caller must cast this to NSView* in Swift/ObjC.
void* cef_bridge_browser_get_nsview(cef_bridge_browser_t browser);

// -------------------------------------------------------------------
// Navigation
// -------------------------------------------------------------------

int cef_bridge_browser_load_url(cef_bridge_browser_t browser, const char* url);
int cef_bridge_browser_go_back(cef_bridge_browser_t browser);
int cef_bridge_browser_go_forward(cef_bridge_browser_t browser);
int cef_bridge_browser_reload(cef_bridge_browser_t browser);
int cef_bridge_browser_stop(cef_bridge_browser_t browser);

/// Get the current URL. Caller must free the returned string with
/// cef_bridge_free_string().
char* cef_bridge_browser_get_url(cef_bridge_browser_t browser);

/// Get the current page title. Caller must free the returned string.
char* cef_bridge_browser_get_title(cef_bridge_browser_t browser);

bool cef_bridge_browser_can_go_back(cef_bridge_browser_t browser);
bool cef_bridge_browser_can_go_forward(cef_bridge_browser_t browser);
bool cef_bridge_browser_is_loading(cef_bridge_browser_t browser);

// -------------------------------------------------------------------
// Page control
// -------------------------------------------------------------------

/// Set zoom level. 0.0 is default (100%). Positive values zoom in,
/// negative values zoom out.
int cef_bridge_browser_set_zoom(cef_bridge_browser_t browser, double level);
double cef_bridge_browser_get_zoom(cef_bridge_browser_t browser);

/// Set custom user agent string.
int cef_bridge_browser_set_user_agent(
    cef_bridge_browser_t browser,
    const char* user_agent
);

// -------------------------------------------------------------------
// JavaScript
// -------------------------------------------------------------------

/// Execute JavaScript in the main frame. Fire-and-forget (no result).
int cef_bridge_browser_execute_js(
    cef_bridge_browser_t browser,
    const char* script
);

/// Evaluate JavaScript and get the result via callback. The callback
/// is invoked on the main thread with the JSON-encoded result.
int cef_bridge_browser_evaluate_js(
    cef_bridge_browser_t browser,
    const char* script,
    int32_t request_id,
    cef_bridge_js_callback callback,
    void* user_data
);

/// Add a user script that runs at document start on every navigation.
int cef_bridge_browser_add_init_script(
    cef_bridge_browser_t browser,
    const char* script
);

// -------------------------------------------------------------------
// DevTools
// -------------------------------------------------------------------

/// Show/hide the Chromium DevTools for a browser.
int cef_bridge_browser_show_devtools(cef_bridge_browser_t browser);
int cef_bridge_browser_close_devtools(cef_bridge_browser_t browser);

// -------------------------------------------------------------------
// Visibility (portal support)
// -------------------------------------------------------------------

/// Notify CEF that the browser view has been hidden or shown.
/// Use these when reparenting views in the portal system.
void cef_bridge_browser_set_hidden(cef_bridge_browser_t browser, bool hidden);

/// Notify CEF that the browser view has been resized.
void cef_bridge_browser_notify_resized(cef_bridge_browser_t browser);

// -------------------------------------------------------------------
// Find in page
// -------------------------------------------------------------------

int cef_bridge_browser_find(
    cef_bridge_browser_t browser,
    const char* search_text,
    bool forward,
    bool case_sensitive
);

int cef_bridge_browser_stop_finding(cef_bridge_browser_t browser);

// -------------------------------------------------------------------
// Extensions
// -------------------------------------------------------------------

/// Load a Chrome extension from an unpacked directory.
/// `extension_path` is the directory containing manifest.json.
/// Returns an extension handle on success, NULL on failure.
cef_bridge_extension_t cef_bridge_extension_load(
    cef_bridge_profile_t profile,
    const char* extension_path
);

/// Unload a previously loaded extension.
int cef_bridge_extension_unload(cef_bridge_extension_t extension);

/// Get the extension identifier string. Caller must free with
/// cef_bridge_free_string().
char* cef_bridge_extension_get_id(cef_bridge_extension_t extension);

// -------------------------------------------------------------------
// Utility
// -------------------------------------------------------------------

/// Free a string allocated by the bridge.
void cef_bridge_free_string(char* str);

/// Get the CEF version string. Caller must free with
/// cef_bridge_free_string().
char* cef_bridge_get_version(void);

#ifdef __cplusplus
}
#endif

#endif // CEF_BRIDGE_H
