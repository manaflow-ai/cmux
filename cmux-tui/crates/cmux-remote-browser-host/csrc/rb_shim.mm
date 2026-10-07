// The CEF shim of the remote browser host (macOS). plans/cmux-next/
// remote-tab-r2.md: it owns every CEF type and exposes csrc/rb_shim.h. The
// CEF fork's remote presentation ABI (cmux_rp_*, include/cef_cmux.h, API 19)
// is bound by dlsym from the loaded framework, as the cmux app binds cmux_*.
// The embedder-test harness of the fork (tests/cmux_embedder, remote-*
// cases) runs the same calls and is the reference for this file.

#import <Cocoa/Cocoa.h>

#include <dlfcn.h>

#include <cstring>

#include <map>
#include <string>
#include <vector>

#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_library_loader.h"

#include "rb_shim.h"

@interface RbShimApplication : NSApplication <CefAppProtocol> {
 @private
  BOOL handlingSendEvent_;
}
@end

@implementation RbShimApplication
- (BOOL)isHandlingSendEvent {
  return handlingSendEvent_;
}
- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  handlingSendEvent_ = handlingSendEvent;
}
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}
@end

namespace {

rb_shim_callbacks_t g_cb = {};
bool g_external_begin_frames = false;
// rb_shim_quit closes every browser first: CefShutdown needs them closed.
bool g_quitting = false;

// --- the fork's cmux_rp_* exports (include/cef_cmux.h, API 19) -------------

using rp_frame_fn = void (*)(void*, int, const rb_frame_t*);
struct Rp {
  int (*api_version)() = nullptr;
  int (*is_active)() = nullptr;
  int (*set_screen)(int, int, double) = nullptr;
  int (*capture_start)(int, int, int, rp_frame_fn, void*) = nullptr;
  int (*capture_stop)(int) = nullptr;
  int (*capture_refresh)(int) = nullptr;
  void (*frame_release)(int64_t) = nullptr;
  int (*send_key)(int, int, const char*, const char*, const char*,
                  const char*, int, const char* const*, const char* const*,
                  int) = nullptr;
  int (*send_wheel)(int, double, double, double, double, int, int, int,
                    int) = nullptr;
  int (*send_pinch)(int, int, double, double, double) = nullptr;
  int (*begin_frame)(int, int64_t, void (*)(void*, int, int), void*) = nullptr;
  void (*set_needs_begin_frames_handler)(void (*)(void*, int, int),
                                         void*) = nullptr;
  void (*set_popup_menu_handler)(void (*)(void*, int, int64_t, int, int, int,
                                          int, const char*, int, int, int,
                                          double),
                                 void*) = nullptr;
  int (*popup_menu_result)(int64_t, const int*, int) = nullptr;
  // RP7 popup surfaces.
  void (*set_surface_handler)(void (*)(void*, int, int, int, int, int, int,
                                       int, int),
                              void*) = nullptr;
  int (*surface_capture_start)(int, int, int, rp_frame_fn, void*) = nullptr;
  int (*surface_send_mouse)(int, int, double, double, int, int,
                            int) = nullptr;
  int (*surface_close)(int) = nullptr;
  int (*set_active)(int, int) = nullptr;
} g_rp;

bool BindRp(const std::string& framework_binary) {
  void* image = dlopen(framework_binary.c_str(), RTLD_NOLOAD | RTLD_LAZY);
  if (!image) {
    return false;
  }
#define BIND(field, name) \
  g_rp.field = reinterpret_cast<decltype(g_rp.field)>(dlsym(image, name))
  BIND(api_version, "cmux_cef_api_version");
  BIND(is_active, "cmux_rp_is_active");
  BIND(set_screen, "cmux_rp_set_screen");
  BIND(capture_start, "cmux_rp_capture_start");
  BIND(capture_stop, "cmux_rp_capture_stop");
  BIND(capture_refresh, "cmux_rp_capture_refresh");
  BIND(frame_release, "cmux_rp_frame_release");
  BIND(send_key, "cmux_rp_send_key");
  BIND(send_wheel, "cmux_rp_send_wheel");
  BIND(send_pinch, "cmux_rp_send_pinch");
  BIND(begin_frame, "cmux_rp_begin_frame");
  BIND(set_needs_begin_frames_handler,
       "cmux_rp_set_needs_begin_frames_handler");
  BIND(set_popup_menu_handler, "cmux_rp_set_popup_menu_handler");
  BIND(popup_menu_result, "cmux_rp_popup_menu_result");
  BIND(set_surface_handler, "cmux_rp_set_surface_handler");
  BIND(surface_capture_start, "cmux_rp_surface_capture_start");
  BIND(surface_send_mouse, "cmux_rp_surface_send_mouse");
  BIND(surface_close, "cmux_rp_surface_close");
  BIND(set_active, "cmux_rp_set_active");
#undef BIND
  return g_rp.api_version && g_rp.api_version() >= 19 && g_rp.is_active &&
         g_rp.capture_start && g_rp.frame_release && g_rp.send_key;
}

// --- browsers ----------------------------------------------------------------

std::map<int, CefRefPtr<CefBrowser>>& Browsers() {
  static std::map<int, CefRefPtr<CefBrowser>> browsers;
  return browsers;
}

CefRefPtr<CefBrowser> BrowserFor(int browser_id) {
  auto it = Browsers().find(browser_id);
  return it == Browsers().end() ? nullptr : it->second;
}

std::map<int, CefRefPtr<CefWindow>>& Windows() {
  static std::map<int, CefRefPtr<CefWindow>> windows;
  return windows;
}

// Context menu callbacks by token (the popup menu tokens are the fork's).
std::map<int64_t, CefRefPtr<CefRunContextMenuCallback>>& MenuCallbacks() {
  static std::map<int64_t, CefRefPtr<CefRunContextMenuCallback>> callbacks;
  return callbacks;
}
int64_t g_next_menu_token = 0;

// JS dialog callbacks by token, with the browser that asked.
struct PendingDialog {
  int browser_id;
  CefRefPtr<CefJSDialogCallback> callback;
};
std::map<int64_t, PendingDialog>& DialogCallbacks() {
  static std::map<int64_t, PendingDialog> callbacks;
  return callbacks;
}
int64_t g_next_dialog_token = 0;

void ShowDialog(CefRefPtr<CefBrowser> browser,
                const char* kind,
                const std::string& origin,
                const std::string& message,
                const char* default_text,
                bool is_reload,
                CefRefPtr<CefJSDialogCallback> callback) {
  const int64_t token = ++g_next_dialog_token;
  DialogCallbacks()[token] = {browser->GetIdentifier(), callback};
  g_cb.on_dialog(g_cb.context, browser->GetIdentifier(), token, kind,
                 origin.c_str(), message.c_str(), default_text,
                 is_reload ? 1 : 0);
}

CefRefPtr<CefListValue> MenuItems(CefRefPtr<CefMenuModel> model) {
  CefRefPtr<CefListValue> list = CefListValue::Create();
  for (size_t i = 0; i < model->GetCount(); ++i) {
    CefRefPtr<CefDictionaryValue> item = CefDictionaryValue::Create();
    item->SetInt("id", model->GetCommandIdAt(i));
    item->SetString("label", model->GetLabelAt(i));
    item->SetBool("enabled", model->IsEnabledAt(i));
    item->SetBool("checked", model->IsCheckedAt(i));
    CefRefPtr<CefListValue> children = CefListValue::Create();
    switch (model->GetTypeAt(i)) {
      case MENUITEMTYPE_SEPARATOR:
        item->SetString("type", "separator");
        break;
      case MENUITEMTYPE_CHECK:
        item->SetString("type", "check");
        break;
      case MENUITEMTYPE_RADIO:
        item->SetString("type", "radio");
        break;
      case MENUITEMTYPE_SUBMENU:
        item->SetString("type", "submenu");
        if (CefRefPtr<CefMenuModel> sub = model->GetSubMenuAt(i)) {
          children = MenuItems(sub);
        }
        break;
      default:
        item->SetString("type", "command");
        break;
    }
    item->SetList("items", children);
    list->SetDictionary(list->GetSize(), item);
  }
  return list;
}

class Client : public CefClient,
               public CefContextMenuHandler,
               public CefDisplayHandler,
               public CefJSDialogHandler,
               public CefKeyboardHandler,
               public CefLifeSpanHandler {
 public:
  explicit Client(int request) : request_(request) {}

  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override {
    return this;
  }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }

  bool RunContextMenu(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame>,
                      CefRefPtr<CefContextMenuParams> params,
                      CefRefPtr<CefMenuModel> model,
                      CefRefPtr<CefRunContextMenuCallback> callback) override {
    if (!g_cb.on_context_menu) {
      return false;
    }
    const int64_t token = ++g_next_menu_token;
    MenuCallbacks()[token] = callback;
    CefRefPtr<CefValue> items = CefValue::Create();
    items->SetList(MenuItems(model));
    const std::string json =
        CefWriteJSON(items, JSON_WRITER_DEFAULT).ToString();
    g_cb.on_context_menu(g_cb.context, browser->GetIdentifier(), token,
                         params->GetXCoord(), params->GetYCoord(),
                         json.c_str());
    return true;
  }

  // JS dialogs show as native sheets on the viewer (rb.dialog.show); the
  // callback waits for rb_shim_dialog_result.
  bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                  const CefString& origin_url,
                  JSDialogType dialog_type,
                  const CefString& message_text,
                  const CefString& default_prompt_text,
                  CefRefPtr<CefJSDialogCallback> callback,
                  bool& suppress_message) override {
    if (!g_cb.on_dialog) {
      return false;
    }
    suppress_message = false;
    const char* kind = dialog_type == JSDIALOGTYPE_CONFIRM  ? "confirm"
                       : dialog_type == JSDIALOGTYPE_PROMPT ? "prompt"
                                                            : "alert";
    const std::string default_text = default_prompt_text.ToString();
    ShowDialog(browser, kind, origin_url.ToString(), message_text.ToString(),
               dialog_type == JSDIALOGTYPE_PROMPT ? default_text.c_str()
                                                  : nullptr,
               false, callback);
    return true;
  }

  bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                            const CefString& message_text,
                            bool is_reload,
                            CefRefPtr<CefJSDialogCallback> callback) override {
    if (!g_cb.on_dialog) {
      return false;
    }
    CefRefPtr<CefFrame> main = browser->GetMainFrame();
    const std::string origin = main ? main->GetURL().ToString() : "";
    ShowDialog(browser, "beforeunload", origin, message_text.ToString(),
               nullptr, is_reload, callback);
    return true;
  }

  // Navigation (or close) drops the page's dialogs: forget their callbacks
  // and let the host cancel them on the viewers (rb.dialog.cancel).
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override {
    const int id = browser->GetIdentifier();
    bool dropped = false;
    for (auto it = DialogCallbacks().begin(); it != DialogCallbacks().end();) {
      if (it->second.browser_id == id) {
        it = DialogCallbacks().erase(it);
        dropped = true;
      } else {
        ++it;
      }
    }
    if (dropped && g_cb.on_dialog_reset) {
      g_cb.on_dialog_reset(g_cb.context, id);
    }
  }

  void OnTitleChange(CefRefPtr<CefBrowser> browser,
                     const CefString& title) override {
    if (g_cb.on_title) {
      g_cb.on_title(g_cb.context, browser->GetIdentifier(),
                    title.ToString().c_str());
    }
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    if (frame->IsMain() && g_cb.on_url) {
      g_cb.on_url(g_cb.context, browser->GetIdentifier(),
                  url.ToString().c_str());
    }
  }

  bool OnKeyEvent(CefRefPtr<CefBrowser> browser,
                  const CefKeyEvent& event,
                  CefEventHandle) override {
    // In remote presentation (RP4) only keys the page did not handle get
    // here; the viewer runs its own action for them.
    if (event.type == KEYEVENT_RAWKEYDOWN && g_cb.on_key_unhandled) {
      g_cb.on_key_unhandled(g_cb.context, browser->GetIdentifier(), "",
                            static_cast<int>(event.modifiers));
    }
    return false;
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    Browsers()[browser->GetIdentifier()] = browser;
    if (g_cb.on_tab_created) {
      g_cb.on_tab_created(g_cb.context, request_, browser->GetIdentifier());
    }
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    const int id = browser->GetIdentifier();
    Browsers().erase(id);
    Windows().erase(id);
    if (g_cb.on_tab_closed) {
      g_cb.on_tab_closed(g_cb.context, id);
    }
    if (g_quitting && Browsers().empty()) {
      CefQuitMessageLoop();
    }
  }

 private:
  const int request_;
  IMPLEMENT_REFCOUNTING(Client);
};

class BrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

 private:
  IMPLEMENT_REFCOUNTING(BrowserViewDelegate);
};

class WindowDelegate : public CefWindowDelegate {
 public:
  WindowDelegate(CefRefPtr<CefBrowserView> view, int width, int height)
      : view_(view), width_(width), height_(height) {}
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window->AddChildView(view_);
    window->Show();  // headless with --cmux-remote-presentation (RP1)
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { view_ = nullptr; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override {
    return CefRect(0, 0, width_, height_);
  }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  bool CanClose(CefRefPtr<CefWindow>) override {
    CefRefPtr<CefBrowser> browser = view_ ? view_->GetBrowser() : nullptr;
    return browser ? browser->GetHost()->TryCloseBrowser() : true;
  }
  cef_runtime_style_t GetWindowRuntimeStyle() override {
    return CEF_RUNTIME_STYLE_CHROME;
  }

 private:
  CefRefPtr<CefBrowserView> view_;
  const int width_;
  const int height_;
  IMPLEMENT_REFCOUNTING(WindowDelegate);
};

void OnFrame(void*, int browser_id, const rb_frame_t* frame) {
  if (g_cb.on_frame) {
    g_cb.on_frame(g_cb.context, browser_id, frame);
  } else {
    g_rp.frame_release(frame->lease);
  }
}

void OnNeedsBeginFrames(void*, int browser_id, int needs) {
  if (g_cb.on_needs_begin_frames) {
    g_cb.on_needs_begin_frames(g_cb.context, browser_id, needs);
  }
}

void OnPopupMenu(void*, int browser_id, int64_t token, int x, int y, int w,
                 int h, const char* items, int selected, int multiple, int,
                 double) {
  if (g_cb.on_popup_menu) {
    g_cb.on_popup_menu(g_cb.context, browser_id, token, x, y, w, h, items,
                       selected, multiple);
  }
}

void OnSurface(void*, int browser_id, int surface_id, int kind, int visible,
               int x, int y, int w, int h) {
  if (g_cb.on_surface) {
    g_cb.on_surface(g_cb.context, browser_id, surface_id, kind, visible, x, y,
                    w, h);
  }
}

// The fork's frame callback gives the surface id in place of the browser id.
void OnSurfaceFrame(void*, int surface_id, const rb_frame_t* frame) {
  if (g_cb.on_surface_frame) {
    g_cb.on_surface_frame(g_cb.context, surface_id, frame);
  } else {
    g_rp.frame_release(frame->lease);
  }
}

class App : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) {
      return;
    }
    command_line->AppendSwitch("cmux-remote-presentation");
    if (g_external_begin_frames) {
      command_line->AppendSwitch("cmux-remote-begin-frames");
    }
    command_line->AppendSwitch("no-first-run");
    command_line->AppendSwitch("disable-field-trial-config");
  }
  void OnContextInitialized() override {
    if (g_rp.set_needs_begin_frames_handler) {
      g_rp.set_needs_begin_frames_handler(&OnNeedsBeginFrames, nullptr);
    }
    if (g_rp.set_popup_menu_handler) {
      g_rp.set_popup_menu_handler(&OnPopupMenu, nullptr);
    }
    if (g_rp.set_surface_handler) {
      g_rp.set_surface_handler(&OnSurface, nullptr);
    }
    if (g_cb.on_ready) {
      g_cb.on_ready(g_cb.context);
    }
  }

 private:
  IMPLEMENT_REFCOUNTING(App);
};

}  // namespace

extern "C" {

int rb_shim_run(int argc,
                char** argv,
                const char* cache_dir,
                int external_begin_frames,
                const rb_shim_callbacks_t* callbacks) {
  bool helper = false;
  for (int i = 1; i < argc; ++i) {
    if (std::strncmp(argv[i], "--type=", 7) == 0) {
      helper = true;
    }
  }
  CefScopedLibraryLoader loader;
  if (helper ? !loader.LoadInHelper() : !loader.LoadInMain()) {
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  if (helper) {
    return CefExecuteProcess(main_args, nullptr, nullptr);
  }
  if (!callbacks || !cache_dir) {
    return 2;
  }
  g_cb = *callbacks;
  g_external_begin_frames = external_begin_frames != 0;
  @autoreleasepool {
    [RbShimApplication sharedApplication];
    // A background app: no Dock icon, no menu bar (the server's console
    // belongs to whoever sits there).
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
    NSString* framework = [[[NSBundle mainBundle] privateFrameworksPath]
        stringByAppendingPathComponent:
            @"Chromium Embedded Framework.framework/"
            @"Chromium Embedded Framework"];
    if (!BindRp(framework.UTF8String)) {
      return 3;  // Not a remote presentation framework (API < 19).
    }
    CefSettings settings;
    settings.no_sandbox = true;
    CefString(&settings.root_cache_path) = cache_dir;
    CefString(&settings.cache_path) = std::string(cache_dir) + "/profile";
    settings.log_severity = LOGSEVERITY_WARNING;
    CefRefPtr<App> app(new App());
    if (!CefInitialize(main_args, settings, app, nullptr)) {
      return 4;
    }
    CefRunMessageLoop();
    Browsers().clear();
    Windows().clear();
    CefShutdown();
  }
  return 0;
}

void rb_shim_quit(void) {
  g_quitting = true;
  if (Browsers().empty()) {
    CefQuitMessageLoop();
    return;
  }
  // Copy: closing erases from the map in OnBeforeClose.
  std::vector<CefRefPtr<CefBrowser>> open;
  for (const auto& [id, browser] : Browsers()) {
    open.push_back(browser);
  }
  for (const auto& browser : open) {
    if (g_rp.capture_stop) {
      g_rp.capture_stop(browser->GetIdentifier());
    }
    browser->GetHost()->CloseBrowser(true);
  }
}

void rb_shim_post(void (*fn)(void*), void* ctx) {
  CefPostTask(TID_UI, base::BindOnce([](void (*fn)(void*), void* ctx) { fn(ctx); },
                                     fn, ctx));
}

void rb_shim_post_delayed(void (*fn)(void*), void* ctx, int64_t delay_ms) {
  CefPostDelayedTask(
      TID_UI,
      base::BindOnce([](void (*fn)(void*), void* ctx) { fn(ctx); }, fn, ctx),
      delay_ms);
}

int rb_shim_set_screen(int width_dip, int height_dip, double scale) {
  return g_rp.set_screen ? g_rp.set_screen(width_dip, height_dip, scale) : 0;
}

int rb_shim_open_tab(int request,
                     const char* url,
                     int width_dip,
                     int height_dip) {
  if (!url || width_dip <= 0 || height_dip <= 0) {
    return 0;
  }
  CefBrowserSettings settings;
  settings.background_color = 0xFFFFFFFF;
  auto view = CefBrowserView::CreateBrowserView(
      new Client(request), url, settings, nullptr, nullptr,
      new BrowserViewDelegate());
  CefRefPtr<CefWindow> window = CefWindow::CreateTopLevelWindow(
      new WindowDelegate(view, width_dip, height_dip));
  return window ? 1 : 0;
}

void rb_shim_close_tab(int browser_id) {
  if (CefRefPtr<CefBrowser> browser = BrowserFor(browser_id)) {
    if (g_rp.capture_stop) {
      g_rp.capture_stop(browser_id);
    }
    browser->GetHost()->CloseBrowser(true);
  }
}

int rb_shim_capture(int browser_id, int on, int min_period_us) {
  if (on) {
    return g_rp.capture_start(browser_id, min_period_us, /*prefer_gpu=*/1,
                              &OnFrame, nullptr);
  }
  return g_rp.capture_stop ? g_rp.capture_stop(browser_id) : 0;
}

int rb_shim_capture_refresh(int browser_id) {
  return g_rp.capture_refresh ? g_rp.capture_refresh(browser_id) : 0;
}

void rb_shim_frame_release(int64_t lease) {
  g_rp.frame_release(lease);
}

int rb_shim_begin_frame(int browser_id, int64_t interval_us) {
  return g_rp.begin_frame
             ? g_rp.begin_frame(browser_id, interval_us, nullptr, nullptr)
             : 0;
}

int rb_shim_send_key(int browser_id,
                     int down,
                     const char* code,
                     const char* key,
                     const char* text,
                     const char* unmodified_text,
                     int modifiers,
                     const char* const* command_names,
                     const char* const* command_values,
                     int command_count) {
  return g_rp.send_key(browser_id, down, code, key, text, unmodified_text,
                       modifiers, command_names, command_values,
                       command_count);
}

int rb_shim_send_mouse(int browser_id,
                       int kind,
                       double x,
                       double y,
                       int button,
                       int click_count,
                       int modifiers) {
  CefRefPtr<CefBrowser> browser = BrowserFor(browser_id);
  if (!browser) {
    return 0;
  }
  CefMouseEvent event;
  event.x = static_cast<int>(x);
  event.y = static_cast<int>(y);
  // CMUX_RP_MOD_* to CEF flags.
  uint32_t flags = 0;
  if (modifiers & 1) flags |= EVENTFLAG_SHIFT_DOWN;
  if (modifiers & 2) flags |= EVENTFLAG_CONTROL_DOWN;
  if (modifiers & 4) flags |= EVENTFLAG_ALT_DOWN;
  if (modifiers & 8) flags |= EVENTFLAG_COMMAND_DOWN;
  event.modifiers = flags;
  auto host = browser->GetHost();
  const cef_mouse_button_type_t type =
      button == 2 ? MBT_RIGHT : button == 1 ? MBT_MIDDLE : MBT_LEFT;
  switch (kind) {
    case 0:
      host->SendMouseMoveEvent(event, false);
      return 1;
    case 1:
      host->SendMouseClickEvent(event, type, false, click_count);
      return 1;
    case 2:
      host->SendMouseClickEvent(event, type, true, click_count);
      return 1;
    default:
      return 0;
  }
}

int rb_shim_send_wheel(int browser_id,
                       double x,
                       double y,
                       double dx,
                       double dy,
                       int precise,
                       int phase,
                       int momentum_phase,
                       int modifiers) {
  return g_rp.send_wheel ? g_rp.send_wheel(browser_id, x, y, dx, dy, precise,
                                           phase, momentum_phase, modifiers)
                         : 0;
}

int rb_shim_send_pinch(int browser_id,
                       int phase,
                       double scale,
                       double x,
                       double y) {
  return g_rp.send_pinch ? g_rp.send_pinch(browser_id, phase, scale, x, y)
                         : 0;
}

int rb_shim_ime_set_composition(int browser_id,
                                const char* text_utf8,
                                int selection_start,
                                int selection_end,
                                int replace_start,
                                int replace_end) {
  CefRefPtr<CefBrowser> browser = BrowserFor(browser_id);
  if (!browser || !text_utf8) {
    return 0;
  }
  const CefString text(text_utf8);
  CefCompositionUnderline line;
  line.range = CefRange(0, static_cast<uint32_t>(text.length()));
  line.color = 0xFF000000;
  line.background_color = 0;
  line.thick = 0;
  line.style = CEF_CUS_SOLID;
  const CefRange replace = replace_start < 0
                               ? CefRange::InvalidRange()
                               : CefRange(replace_start, replace_end);
  browser->GetHost()->ImeSetComposition(
      text, {line}, replace, CefRange(selection_start, selection_end));
  return 1;
}

int rb_shim_ime_commit(int browser_id,
                       const char* text_utf8,
                       int replace_start,
                       int replace_end) {
  CefRefPtr<CefBrowser> browser = BrowserFor(browser_id);
  if (!browser || !text_utf8) {
    return 0;
  }
  const CefRange replace = replace_start < 0
                               ? CefRange::InvalidRange()
                               : CefRange(replace_start, replace_end);
  browser->GetHost()->ImeCommitText(text_utf8, replace, 0);
  return 1;
}

int rb_shim_ime_finish(int browser_id, int keep_selection) {
  CefRefPtr<CefBrowser> browser = BrowserFor(browser_id);
  if (!browser) {
    return 0;
  }
  browser->GetHost()->ImeFinishComposingText(keep_selection != 0);
  return 1;
}

int rb_shim_ime_cancel(int browser_id) {
  CefRefPtr<CefBrowser> browser = BrowserFor(browser_id);
  if (!browser) {
    return 0;
  }
  browser->GetHost()->ImeCancelComposition();
  return 1;
}

int rb_shim_dialog_result(int64_t token, int accept, const char* text_utf8) {
  auto it = DialogCallbacks().find(token);
  if (it == DialogCallbacks().end()) {
    return 0;
  }
  CefRefPtr<CefJSDialogCallback> callback = it->second.callback;
  DialogCallbacks().erase(it);
  callback->Continue(accept != 0, CefString(text_utf8 ? text_utf8 : ""));
  return 1;
}

int rb_shim_context_menu_result(int64_t token, int command_id) {
  auto it = MenuCallbacks().find(token);
  if (it == MenuCallbacks().end()) {
    return 0;
  }
  CefRefPtr<CefRunContextMenuCallback> callback = it->second;
  MenuCallbacks().erase(it);
  if (command_id < 0) {
    callback->Cancel();
  } else {
    callback->Continue(command_id, EVENTFLAG_NONE);
  }
  return 1;
}

int rb_shim_set_active(int browser_id, int active) {
  return g_rp.set_active ? g_rp.set_active(browser_id, active) : 0;
}

int rb_shim_surface_capture(int surface_id) {
  return g_rp.surface_capture_start
             ? g_rp.surface_capture_start(surface_id, /*min_period_us=*/0,
                                          /*prefer_gpu=*/1, &OnSurfaceFrame,
                                          nullptr)
             : 0;
}

int rb_shim_surface_send_mouse(int surface_id,
                               int kind,
                               double x,
                               double y,
                               int button,
                               int click_count,
                               int modifiers) {
  return g_rp.surface_send_mouse
             ? g_rp.surface_send_mouse(surface_id, kind, x, y, button,
                                       click_count, modifiers)
             : 0;
}

int rb_shim_surface_close(int surface_id) {
  return g_rp.surface_close ? g_rp.surface_close(surface_id) : 0;
}

int rb_shim_popup_menu_result(int64_t token, const int* indices, int count) {
  return g_rp.popup_menu_result ? g_rp.popup_menu_result(token, indices, count)
                                : 0;
}

}  // extern "C"
