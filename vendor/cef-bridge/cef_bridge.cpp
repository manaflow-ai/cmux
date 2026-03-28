// CEF bridge implementation for cmux.
//
// This wraps CEF C++ API calls behind the plain C interface in cef_bridge.h.
// When CEF_BRIDGE_HAS_CEF is defined (CEF headers/libs available), the real
// implementation is compiled. Otherwise, stubs are used.

#include "cef_bridge.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>
#include <map>
#include <atomic>

#ifdef CEF_BRIDGE_HAS_CEF

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_display_handler.h"
#include "include/cef_request_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_library_loader.h"

#ifdef __APPLE__
#include <objc/objc.h>
#include <objc/runtime.h>
#include <objc/message.h>
#endif

// -------------------------------------------------------------------
// Internal types
// -------------------------------------------------------------------

struct BridgeBrowser;

// CefClient that routes callbacks to the C bridge callbacks struct.
class BridgeClient : public CefClient,
                     public CefLifeSpanHandler,
                     public CefLoadHandler,
                     public CefDisplayHandler,
                     public CefKeyboardHandler,
                     public CefContextMenuHandler,
                     public CefFocusHandler {
public:
    explicit BridgeClient(const cef_bridge_client_callbacks* cbs)
        : callbacks_(*cbs) {}

    // CefClient
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }

    // CefDisplayHandler
    void OnTitleChange(CefRefPtr<CefBrowser> browser,
                       const CefString& title) override {
        if (callbacks_.on_title_change) {
            std::string t = title.ToString();
            callbacks_.on_title_change(owner_, t.c_str(), callbacks_.user_data);
        }
    }

    void OnAddressChange(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         const CefString& url) override {
        if (frame->IsMain() && callbacks_.on_url_change) {
            std::string u = url.ToString();
            callbacks_.on_url_change(owner_, u.c_str(), callbacks_.user_data);
        }
    }

    void OnFullscreenModeChange(CefRefPtr<CefBrowser> browser,
                                bool fullscreen) override {
        if (callbacks_.on_fullscreen_change) {
            callbacks_.on_fullscreen_change(owner_, fullscreen, callbacks_.user_data);
        }
    }

    bool OnConsoleMessage(CefRefPtr<CefBrowser> browser,
                          cef_log_severity_t level,
                          const CefString& message,
                          const CefString& source,
                          int line) override {
        if (callbacks_.on_console_message) {
            std::string m = message.ToString();
            std::string s = source.ToString();
            int lvl = 1; // info
            if (level <= LOGSEVERITY_DEBUG) lvl = 0;
            else if (level == LOGSEVERITY_WARNING) lvl = 2;
            else if (level >= LOGSEVERITY_ERROR) lvl = 3;
            callbacks_.on_console_message(owner_, lvl, m.c_str(), s.c_str(), line,
                                          callbacks_.user_data);
        }
        return false;
    }

    // CefLoadHandler
    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser,
                              bool isLoading,
                              bool canGoBack,
                              bool canGoForward) override {
        if (callbacks_.on_loading_state_change) {
            callbacks_.on_loading_state_change(owner_, isLoading, canGoBack,
                                               canGoForward, callbacks_.user_data);
        }
    }

    void OnLoadStart(CefRefPtr<CefBrowser> browser,
                     CefRefPtr<CefFrame> frame,
                     TransitionType transition_type) override {
        if (frame->IsMain() && callbacks_.on_navigation) {
            std::string url = frame->GetURL().ToString();
            callbacks_.on_navigation(owner_, url.c_str(), true, callbacks_.user_data);
        }
    }

    // CefLifeSpanHandler
    bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       int popup_id,
                       const CefString& target_url,
                       const CefString& target_frame_name,
                       WindowOpenDisposition target_disposition,
                       bool user_gesture,
                       const CefPopupFeatures& popupFeatures,
                       CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client,
                       CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info,
                       bool* no_javascript_access) override {
        if (callbacks_.on_popup_request) {
            std::string url = target_url.ToString();
            bool allow = callbacks_.on_popup_request(owner_, url.c_str(),
                                                      callbacks_.user_data);
            return !allow; // return true to cancel
        }
        return true; // block popups by default
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        cef_browser_ = browser;
        fprintf(stderr, "[CEF bridge] OnAfterCreated windowHandle=%p\n",
                browser->GetHost()->GetWindowHandle());
        fflush(stderr);
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        cef_browser_ = nullptr;
    }

    // CefKeyboardHandler
    bool OnPreKeyEvent(CefRefPtr<CefBrowser> browser,
                       const CefKeyEvent& event,
                       CefEventHandle os_event,
                       bool* is_keyboard_shortcut) override {
        // Let Cmd+key shortcuts go to the app menu
        if (event.modifiers & EVENTFLAG_COMMAND_DOWN) {
            *is_keyboard_shortcut = true;
        }
        return false;
    }

    // CefContextMenuHandler - disable default context menu for now
    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefContextMenuParams> params,
                             CefRefPtr<CefMenuModel> model) override {
        // Clear the default menu
        model->Clear();
    }

    void SetOwner(cef_bridge_browser_t owner) { owner_ = owner; }
    CefRefPtr<CefBrowser> GetBrowser() { return cef_browser_; }

private:
    cef_bridge_client_callbacks callbacks_;
    cef_bridge_browser_t owner_ = nullptr;
    CefRefPtr<CefBrowser> cef_browser_;

    IMPLEMENT_REFCOUNTING(BridgeClient);
};

// Simple CefApp for browser process
class BridgeApp : public CefApp,
                  public CefBrowserProcessHandler {
public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
        return this;
    }

    void OnBeforeCommandLineProcessing(
        const CefString& process_type,
        CefRefPtr<CefCommandLine> command_line) override {
        command_line->AppendSwitch("use-mock-keychain");
        command_line->AppendSwitch("disable-gpu");
        command_line->AppendSwitch("disable-gpu-compositing");
        command_line->AppendSwitch("single-process");
        // Hide Chrome's tab strip (we use cmux's sidebar for tab management)
        command_line->AppendSwitch("hide-tabstrip");
    }

private:
    IMPLEMENT_REFCOUNTING(BridgeApp);
};

struct BridgeBrowser {
    CefRefPtr<BridgeClient> client;
    std::vector<std::string> init_scripts;
};

struct BridgeProfile {
    CefRefPtr<CefRequestContext> context;
};

// -------------------------------------------------------------------
// Global state
// -------------------------------------------------------------------

static bool g_initialized = false;
static std::string g_framework_path;
static std::map<int, BridgeBrowser*> g_browsers;
static std::mutex g_mutex;

// -------------------------------------------------------------------
// Helpers
// -------------------------------------------------------------------

static char* bridge_strdup(const char* s) {
    if (!s) return nullptr;
    size_t len = strlen(s) + 1;
    char* copy = static_cast<char*>(malloc(len));
    if (copy) memcpy(copy, s, len);
    return copy;
}

// -------------------------------------------------------------------
// Lifecycle
// -------------------------------------------------------------------

bool cef_bridge_framework_available(const char* framework_path) {
    if (!framework_path) return false;
    std::string path = std::string(framework_path) +
        "/Chromium Embedded Framework.framework";
    // Simple check: see if the framework directory exists
    FILE* f = fopen((path + "/Chromium Embedded Framework").c_str(), "r");
    if (f) { fclose(f); return true; }
    return false;
}

int cef_bridge_initialize(
    const char* framework_path,
    const char* helper_path,
    const char* cache_root
) {
    if (g_initialized) return CEF_BRIDGE_OK;
    if (!framework_path || !helper_path || !cache_root)
        return CEF_BRIDGE_ERR_INVALID;

    g_framework_path = framework_path;

    // Load the CEF framework library
    std::string fwk_path = std::string(framework_path) +
        "/Chromium Embedded Framework.framework/Chromium Embedded Framework";

    // Library loader must stay alive for the lifetime of CEF.
    static CefScopedLibraryLoader library_loader;
    if (!library_loader.LoadInMain()) {
        fprintf(stderr, "[CEF bridge] LoadInMain failed\n");
        fflush(stderr);
        return CEF_BRIDGE_ERR_FAILED;
    }

    CefMainArgs main_args(0, nullptr);

    CefSettings settings;
    settings.no_sandbox = true;
    settings.external_message_pump = true;
    settings.multi_threaded_message_loop = false;
    // Don't persist session cookies to avoid keychain access prompts.
    // Chromium encrypts cookies via macOS Keychain ("Chromium Safe Storage")
    // which triggers a password prompt for unsigned/dev-signed apps.
    settings.persist_session_cookies = false;

    CefString(&settings.framework_dir_path) =
        std::string(framework_path) + "/Chromium Embedded Framework.framework";
    CefString(&settings.browser_subprocess_path) = helper_path;
    CefString(&settings.cache_path) = cache_root;
    settings.log_severity = LOGSEVERITY_VERBOSE;
    CefString(&settings.log_file) = std::string(cache_root) + "/cef_verbose.log";

    CefRefPtr<BridgeApp> app(new BridgeApp());

    fprintf(stderr, "[CEF bridge] Calling CefInitialize...\n");
    fflush(stderr);

    if (!CefInitialize(main_args, settings, app.get(), nullptr)) {
        fprintf(stderr, "[CEF bridge] CefInitialize FAILED\n");
        fflush(stderr);
        return CEF_BRIDGE_ERR_FAILED;
    }

    fprintf(stderr, "[CEF bridge] CefInitialize OK\n");
    fflush(stderr);

    g_initialized = true;

    // Pump the message loop a few times to let CEF complete internal
    // initialization (GPU process launch, network service, etc.)
    // before the first CreateBrowser call.
    for (int i = 0; i < 10; i++) {
        CefDoMessageLoopWork();
    }

    return CEF_BRIDGE_OK;
}

void cef_bridge_do_message_loop_work(void) {
    if (!g_initialized) return;
    CefDoMessageLoopWork();
}

void cef_bridge_shutdown(void) {
    if (!g_initialized) return;
    CefShutdown();
    g_initialized = false;
}

bool cef_bridge_is_initialized(void) {
    return g_initialized;
}

// -------------------------------------------------------------------
// Profile management
// -------------------------------------------------------------------

cef_bridge_profile_t cef_bridge_profile_create(const char* cache_path) {
    if (!g_initialized || !cache_path) return nullptr;

    CefRequestContextSettings ctx_settings;
    CefString(&ctx_settings.cache_path) = cache_path;

    CefRefPtr<CefRequestContext> context =
        CefRequestContext::CreateContext(ctx_settings, nullptr);
    if (!context) return nullptr;

    auto* profile = new BridgeProfile();
    profile->context = context;
    return profile;
}

void cef_bridge_profile_destroy(cef_bridge_profile_t profile) {
    if (!profile) return;
    delete static_cast<BridgeProfile*>(profile);
}

int cef_bridge_profile_clear_data(cef_bridge_profile_t profile) {
    if (!g_initialized || !profile) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* p = static_cast<BridgeProfile*>(profile);
    p->context->ClearCertificateExceptions(nullptr);
    return CEF_BRIDGE_OK;
}

// -------------------------------------------------------------------
// Browser view
// -------------------------------------------------------------------

cef_bridge_browser_t cef_bridge_browser_create(
    cef_bridge_profile_t profile,
    const char* initial_url,
    void* parent_view,
    int width,
    int height,
    const cef_bridge_client_callbacks* callbacks
) {
    if (!g_initialized || !callbacks) return nullptr;

    auto* bb = new BridgeBrowser();
    bb->client = new BridgeClient(callbacks);
    bb->client->SetOwner(bb);

    CefWindowInfo window_info;
    if (parent_view) {
        window_info.parent_view = parent_view;
        window_info.bounds = {0, 0, width, height};
        window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    }

    CefBrowserSettings browser_settings;
    // Don't override size - the CefStructBase constructor sets it correctly
    // from cef_browser_settings_t, not from CefBrowserSettings (which may
    // be larger due to C++ padding).

    CefRefPtr<CefRequestContext> request_context;
    if (profile) {
        request_context = static_cast<BridgeProfile*>(profile)->context;
    }

    std::string url = initial_url ? initial_url : "about:blank";

    fprintf(stderr, "[CEF bridge] Calling CreateBrowser size=%dx%d url=%s\n",
            width, height, url.c_str());
    fprintf(stderr, "[CEF bridge] CefCurrentlyOn(TID_UI)=%d\n",
            CefCurrentlyOn(TID_UI));
    fprintf(stderr, "[CEF bridge] windowInfo.size=%zu expected=%zu\n",
            window_info.size, sizeof(cef_window_info_t));
    fprintf(stderr, "[CEF bridge] browserSettings.size=%zu expected=%zu\n",
            browser_settings.size, sizeof(cef_browser_settings_t));
    fprintf(stderr, "[CEF bridge] client=%p\n", bb->client.get());
    fflush(stderr);

    // Try creating the browser. Both async and sync are tried.
    bool ok = CefBrowserHost::CreateBrowser(
        window_info, bb->client, url, browser_settings, nullptr,
        request_context);

    fprintf(stderr, "[CEF bridge] CreateBrowser returned %d\n", ok);
    fflush(stderr);

    if (!ok) {
        // Sync fallback
        CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
            window_info, bb->client, url, browser_settings, nullptr,
            request_context);
        fprintf(stderr, "[CEF bridge] CreateBrowserSync returned %p\n",
                browser.get());
        fflush(stderr);
        if (!browser) {
            delete bb;
            return nullptr;
        }
    }

    return bb;
}

void cef_bridge_browser_destroy(cef_bridge_browser_t browser) {
    if (!browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (b) {
        b->GetHost()->CloseBrowser(true);
    }
    // Note: BridgeBrowser is freed after OnBeforeClose fires
    // For now, just delete it
    delete bb;
}

void* cef_bridge_browser_get_nsview(cef_bridge_browser_t browser) {
    if (!browser) return nullptr;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return nullptr;
    return b->GetHost()->GetWindowHandle();
}

// -------------------------------------------------------------------
// Navigation
// -------------------------------------------------------------------

int cef_bridge_browser_load_url(cef_bridge_browser_t browser, const char* url) {
    if (!g_initialized || !browser || !url) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->GetMainFrame()->LoadURL(url);
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_go_back(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->GoBack();
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_go_forward(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->GoForward();
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_reload(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->Reload();
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_stop(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->StopLoad();
    return CEF_BRIDGE_OK;
}

char* cef_bridge_browser_get_url(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return nullptr;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return nullptr;
    return bridge_strdup(b->GetMainFrame()->GetURL().ToString().c_str());
}

char* cef_bridge_browser_get_title(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return nullptr;
    // CEF doesn't have a direct GetTitle on Browser.
    // Title is tracked via OnTitleChange callback.
    return nullptr;
}

bool cef_bridge_browser_can_go_back(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return false;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    return b ? b->CanGoBack() : false;
}

bool cef_bridge_browser_can_go_forward(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return false;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    return b ? b->CanGoForward() : false;
}

bool cef_bridge_browser_is_loading(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return false;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    return b ? b->IsLoading() : false;
}

// -------------------------------------------------------------------
// Page control
// -------------------------------------------------------------------

int cef_bridge_browser_set_zoom(cef_bridge_browser_t browser, double level) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->GetHost()->SetZoomLevel(level);
    return CEF_BRIDGE_OK;
}

double cef_bridge_browser_get_zoom(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return 0.0;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    return b ? b->GetHost()->GetZoomLevel() : 0.0;
}

int cef_bridge_browser_set_user_agent(
    cef_bridge_browser_t browser,
    const char* user_agent
) {
    // User agent is set at CefSettings level, not per-browser.
    // This would require re-initialization, so it's a no-op for now.
    return CEF_BRIDGE_ERR_NOT_INIT;
}

// -------------------------------------------------------------------
// JavaScript
// -------------------------------------------------------------------

int cef_bridge_browser_execute_js(
    cef_bridge_browser_t browser,
    const char* script
) {
    if (!g_initialized || !browser || !script) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->GetMainFrame()->ExecuteJavaScript(script, "", 0);
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_evaluate_js(
    cef_bridge_browser_t browser,
    const char* script,
    int32_t request_id,
    cef_bridge_js_callback callback,
    void* user_data
) {
    if (!g_initialized || !browser || !script || !callback)
        return CEF_BRIDGE_ERR_NOT_INIT;

    // CEF doesn't support synchronous JS evaluation from the browser process.
    // For now, execute the script and report no result.
    // A full implementation would use CefProcessMessage IPC.
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;

    b->GetMainFrame()->ExecuteJavaScript(script, "", 0);
    callback(request_id, nullptr, "JS eval return values not yet supported",
             user_data);
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_add_init_script(
    cef_bridge_browser_t browser,
    const char* script
) {
    if (!g_initialized || !browser || !script) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    bb->init_scripts.push_back(script);
    return CEF_BRIDGE_OK;
}

// -------------------------------------------------------------------
// DevTools
// -------------------------------------------------------------------

int cef_bridge_browser_show_devtools(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;

    CefWindowInfo devtools_info;
    devtools_info.size = sizeof(CefWindowInfo);
    CefBrowserSettings devtools_settings;
    b->GetHost()->ShowDevTools(devtools_info, nullptr, devtools_settings,
                                CefPoint());
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_close_devtools(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->GetHost()->CloseDevTools();
    return CEF_BRIDGE_OK;
}

// -------------------------------------------------------------------
// Visibility (portal support)
// -------------------------------------------------------------------

void cef_bridge_browser_set_hidden(cef_bridge_browser_t browser, bool hidden) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (b) b->GetHost()->WasHidden(hidden);
}

void cef_bridge_browser_notify_resized(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (b) b->GetHost()->WasResized();
}

// -------------------------------------------------------------------
// Find in page
// -------------------------------------------------------------------

int cef_bridge_browser_find(
    cef_bridge_browser_t browser,
    const char* search_text,
    bool forward,
    bool case_sensitive
) {
    if (!g_initialized || !browser || !search_text) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->GetHost()->Find(search_text, forward, !case_sensitive, false);
    return CEF_BRIDGE_OK;
}

int cef_bridge_browser_stop_finding(cef_bridge_browser_t browser) {
    if (!g_initialized || !browser) return CEF_BRIDGE_ERR_NOT_INIT;
    auto* bb = static_cast<BridgeBrowser*>(browser);
    CefRefPtr<CefBrowser> b = bb->client->GetBrowser();
    if (!b) return CEF_BRIDGE_ERR_FAILED;
    b->GetHost()->StopFinding(true);
    return CEF_BRIDGE_OK;
}

// -------------------------------------------------------------------
// Extensions (Phase 4 - stubs for now)
// -------------------------------------------------------------------

cef_bridge_extension_t cef_bridge_extension_load(
    cef_bridge_profile_t profile,
    const char* extension_path
) {
    // TODO(phase4)
    return nullptr;
}

int cef_bridge_extension_unload(cef_bridge_extension_t extension) {
    return CEF_BRIDGE_ERR_NOT_INIT;
}

char* cef_bridge_extension_get_id(cef_bridge_extension_t extension) {
    return nullptr;
}

// -------------------------------------------------------------------
// Utility
// -------------------------------------------------------------------

void cef_bridge_free_string(char* str) {
    free(str);
}

char* cef_bridge_get_version(void) {
    if (!g_initialized) return bridge_strdup("146.0.6 (not initialized)");
    return bridge_strdup("146.0.6+chromium-146.0.7680.154");
}

#else // !CEF_BRIDGE_HAS_CEF

// -------------------------------------------------------------------
// Stub implementations when CEF is not available
// -------------------------------------------------------------------

static char* bridge_strdup(const char* s) {
    if (!s) return nullptr;
    size_t len = strlen(s) + 1;
    char* copy = static_cast<char*>(malloc(len));
    if (copy) memcpy(copy, s, len);
    return copy;
}

bool cef_bridge_framework_available(const char* p) { return false; }
int cef_bridge_initialize(const char* a, const char* b, const char* c) { return CEF_BRIDGE_ERR_NOT_INIT; }
void cef_bridge_do_message_loop_work(void) {}
void cef_bridge_shutdown(void) {}
bool cef_bridge_is_initialized(void) { return false; }

cef_bridge_profile_t cef_bridge_profile_create(const char* p) { return nullptr; }
void cef_bridge_profile_destroy(cef_bridge_profile_t p) {}
int cef_bridge_profile_clear_data(cef_bridge_profile_t p) { return CEF_BRIDGE_ERR_NOT_INIT; }

cef_bridge_browser_t cef_bridge_browser_create(cef_bridge_profile_t p, const char* u, void* v, int w, int h, const cef_bridge_client_callbacks* c) { return nullptr; }
void cef_bridge_browser_destroy(cef_bridge_browser_t b) {}
void* cef_bridge_browser_get_nsview(cef_bridge_browser_t b) { return nullptr; }

int cef_bridge_browser_load_url(cef_bridge_browser_t b, const char* u) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_go_back(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_go_forward(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_reload(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_stop(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
char* cef_bridge_browser_get_url(cef_bridge_browser_t b) { return nullptr; }
char* cef_bridge_browser_get_title(cef_bridge_browser_t b) { return nullptr; }
bool cef_bridge_browser_can_go_back(cef_bridge_browser_t b) { return false; }
bool cef_bridge_browser_can_go_forward(cef_bridge_browser_t b) { return false; }
bool cef_bridge_browser_is_loading(cef_bridge_browser_t b) { return false; }

int cef_bridge_browser_set_zoom(cef_bridge_browser_t b, double l) { return CEF_BRIDGE_ERR_NOT_INIT; }
double cef_bridge_browser_get_zoom(cef_bridge_browser_t b) { return 0.0; }
int cef_bridge_browser_set_user_agent(cef_bridge_browser_t b, const char* u) { return CEF_BRIDGE_ERR_NOT_INIT; }

int cef_bridge_browser_execute_js(cef_bridge_browser_t b, const char* s) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_evaluate_js(cef_bridge_browser_t b, const char* s, int32_t r, cef_bridge_js_callback c, void* u) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_add_init_script(cef_bridge_browser_t b, const char* s) { return CEF_BRIDGE_ERR_NOT_INIT; }

int cef_bridge_browser_show_devtools(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_close_devtools(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }

void cef_bridge_browser_set_hidden(cef_bridge_browser_t b, bool h) {}
void cef_bridge_browser_notify_resized(cef_bridge_browser_t b) {}

int cef_bridge_browser_find(cef_bridge_browser_t b, const char* t, bool f, bool c) { return CEF_BRIDGE_ERR_NOT_INIT; }
int cef_bridge_browser_stop_finding(cef_bridge_browser_t b) { return CEF_BRIDGE_ERR_NOT_INIT; }

cef_bridge_extension_t cef_bridge_extension_load(cef_bridge_profile_t p, const char* e) { return nullptr; }
int cef_bridge_extension_unload(cef_bridge_extension_t e) { return CEF_BRIDGE_ERR_NOT_INIT; }
char* cef_bridge_extension_get_id(cef_bridge_extension_t e) { return nullptr; }

void cef_bridge_free_string(char* s) { free(s); }
char* cef_bridge_get_version(void) { return bridge_strdup("0.0.0-stub"); }

#endif // CEF_BRIDGE_HAS_CEF
