# cmux next: browser (WebKit + CEF)

Research and design note for goal 8 of `REWRITE.md`. Written 2026-09-28. Paths are absolute or rooted at the named repo. `cmux2:` = `~/fun/cmux2`, `fork:` = `~/fun/cef-cmux` (branch `cmux/8037`), `dist:` = `~/fun/cef-cmux-dist`, `cmux:` = this worktree.

## Decisions that need Lawrence

1. **Browser granularity.** A Chromium `Browser` shows only its active tab. cmux panes show several web tabs at the same time (splits, columns). This note proposes one Chromium `Browser` per cmux pane, not per cmux window. Extensions then see one Chrome window per pane that holds CEF tabs.
2. **CEF presentation is a child `NSWindow`, not an `NSView`.** The fork keeps a frameless child window over our placeholder view (fork:`libcef/browser/chrome/views/chrome_child_window_mac.mm:186-198`). This breaks Liquid Glass over web content, overlays drawn in the main window, niri horizontal scroll, and clipping. Mitigations are below. This is the biggest risk of the CEF path. Chrome style plus offscreen rendering is not possible, because CEF OSR requires Alloy style, and Alloy has no extension tab model.
3. **Where the fork lives.** fork has only `origin = chromiumembedded/cef`. cmux2 has no remote. Nothing is pushed anywhere. The CLAUDE.md in-org rule requires a new `manaflow-ai/cef` repo (release assets are hosted there too). Choose public or private.
4. **Where browser automation lives** (the socket `browser.*` commands). Recommended: the daemon runs CEF tabs over CDP (it already has `cmux-tui-cdp` and a provider registry), and the frontend runs WebKit tabs. Alternative: the Swift frontend runs both engines.
5. **Local CDP endpoint.** The daemon provider model expects a loopback DevTools port with no authentication (cmux:`cmux-tui/docs/browser-panes.md`). Any local process can then drive every CEF tab, cookies included. Choose among a bearer token (the daemon supports it, but agent-browser direct-page mode rejects it), `--remote-debugging-pipe`, or an in-process CDP proxy.
6. **Architectures and codecs.** The fork builds arm64 only (fork:`scripts/build-cmux-cef.sh:46`). cmux ships a universal build. Choose between "CEF on Apple silicon only" and a second x86_64 fork build. `proprietary_codecs` is off, so H.264/AAC video fails in CEF tabs. Turning it on has licensing cost. Widevine is not available in CEF, so DRM sites must use WebKit.
7. **Official build.** The dist is a non-official build (`is_official_build=false`, no LTO/PGO, fork:`scripts/build-cmux-cef.sh:34`). The binary is 584 MiB unstripped and 367 MiB after `strip -x`. An official build is smaller and faster but takes about a day to build. Recommended for release channels only.
8. **Bundle vs on-demand download.** Put CEF in the app bundle (the DMG gets about 130 MB bigger), or ship it as a separately notarized runtime that is downloaded on the first CEF tab. Recommended: in the bundle first.
9. **Chromium fork competition.** `cmux:cmux-browser/` imports a full Chromium fork (`~/fun/cmux-browser`) that already has real `Browser`/`TabStripModel` integration (cmux2:`docs/extensions-macos.md`, Approach 5). REWRITE.md chose CEF. State that CEF replaces cmux-browser, or keep both paths on purpose.

Items that I did out of laziness, or that are not verified: I did not build or run CEF. I did not test lazy `CefInitialize` after `NSApp.run` has started (see "Lazy loading"). Also, the existing `cmux2:dist/cmux2.app` contains **stock** CEF (320 MiB framework with no `cmux_*` exports, dated 2026-09-27), not the fork. The extension results in cmux2's docs came from other builds that are not on disk now.

## 1. How cmux2 embeds CEF

### Crates and FFI

| Piece | Role | Citation |
| --- | --- | --- |
| `crates/core` | Tab strip model, pinning, layout, session file. No CEF. | cmux2:`README.md`, `crates/core/src/tabs.rs` |
| `crates/engine` | CEF glue: process setup, per-tab browsers, popups-as-tabs (keeps `window.opener`), Chrome accelerator routing, extension discovery, fork API binding | cmux2:`crates/engine/src/lib.rs:1-11` |
| `crates/ffi` | `staticlib` `cmux_ffi`. Its C ABI is in `include/cmux_engine.h`. | cmux2:`crates/ffi/Cargo.toml`, `crates/ffi/include/cmux_engine.h` |
| `crates/helper` | CEF subprocess binary. Enters the sandbox first, then loads the library and runs `execute_process`. | cmux2:`crates/helper/src/main.rs` |
| `apple/` | SwiftPM app. `CCmuxEngine` system module shims the header, links `-lcmux_ffi -lc++` | cmux2:`apple/Package.swift`, `apple/Sources/CCmuxEngine/shim.h` |

The Rust side uses the `cef` crate `=154.2.0` (cmux2:`Cargo.toml`). The crate loads the framework at runtime through `library_loader::LibraryLoader` (cmux2:`crates/engine/src/lib.rs:103-121`), so the framework is not linked.

`cmux_engine.h` surface: process (`cmux_load_library`, `cmux_run_subprocess`, `cmux_initialize(data_dir, subprocess_path, load_extensions, cmux_host)`, `cmux_run`, `cmux_quit`, `cmux_shutdown`, `cmux_close_all`), an engine-owned tab strip (`cmux_tab_*`, `cmux_new_web_tab`, `cmux_new_terminal_tab`, `cmux_restore_session`), web control (`cmux_attach(id, NSView*, w, h)`, navigate/back/forward/reload/stop/focus/zoom/find/devtools), and extensions (`cmux_uses_chrome_tabs`, `cmux_extension_actions_json`, `cmux_run_extension_action`, `cmux_show_extension_action_menu`, `cmux_open_chrome_page`, stock-CEF popups `cmux_open_popup`). The host callbacks are `event`, `parent_for_new_tab`, and `unhandled_key` (cmux2:`crates/ffi/include/cmux_engine.h:46-53`).

Important: the engine **owns the tab strip and the session file**, and also holds terminal tabs (cmux2:`crates/engine/src/lib.rs:222-305`). This conflicts with REWRITE goal 2 (the daemon owns layout).

### Bundle layout, helpers, signing

`scripts/build-mac.sh` builds `cmux-ffi` and `cmux-helper` with cargo, then builds Swift, then assembles:

```
cmux2.app/Contents/MacOS/cmux2
cmux2.app/Contents/Frameworks/Chromium Embedded Framework.framework   (ditto from CEF_PATH)
cmux2.app/Contents/Frameworks/cmux2 Helper.app
cmux2.app/Contents/Frameworks/cmux2 Helper (GPU|Renderer|Plugin|Alerts).app
```

All five helpers are the same `cmux-helper` binary with different names and bundle ids `dev.cmux.browser2.helper[.gpu|.renderer|.plugin|.alerts]`, and they have `LSUIElement` (cmux2:`scripts/build-mac.sh:66-74`). `NSPrincipalClass` is the CEF-aware `NSApplication` subclass (`:50`). Signing is ad hoc, helpers first, then the app, with no entitlements and no hardened runtime (`:73-75`). Framework layout in dist: 584 MiB binary, `Libraries/` 22 MiB (`libcef_sandbox.dylib`, SwiftShader, Vulkan), `Resources/` 86 MiB (paks, locales).

### Sandbox

The helper calls `enter_helper_sandbox()` (Chromium `Sandbox::initialize` via `libcef_sandbox`) before it loads CEF (cmux2:`crates/engine/src/lib.rs:123-131`, `crates/helper/src/main.rs`). `no_sandbox` is 0 on macOS and 1 elsewhere (`lib.rs:152`). The browser process is not sandboxed. Verified in cmux2:`docs/extensions-macos.md` (the "CEF sandbox" row). A single `root_cache_path` = `cache_path` = `<data_dir>/Profile` (`lib.rs:146-154`).

### Message loop

`main.swift` calls `cmux_load_library(false)`, creates `CmuxApplication.shared`, calls `cmux_initialize`, then `cmux_run()` (`CefRunMessageLoop`, which runs `[NSApp run]`), then `cmux_shutdown()` (cmux2:`apple/Sources/CmuxMac/main.swift`). `CmuxApplication` adopts `CefAppProtocol` (`isHandlingSendEvent`/`setHandlingSendEvent`, set around `sendEvent`). It overrides `terminate:` so that Cmd-Q closes every browser first and quits the CEF loop after `CMUX_EVENT_ALL_CLOSED` (cmux2:`apple/Sources/CmuxMac/CmuxApplication.swift`, protocols declared in `CCmuxEngine/shim.h`). CEF therefore owns the run loop from process start. cmux next cannot keep this if CEF must be lazy.

### Keyboard routing

- CEF on macOS already offers keys that the page did not handle to the main menu. cmux2 sets `unhandled_key = nil` because a second offer ran every menu shortcut twice (cmux2:`apple/Sources/CmuxMac/Engine.swift:134-137`). The Rust `on_key_event` still forwards `RAWKEYDOWN` when a host hook exists (cmux2:`crates/engine/src/client.rs:374-390`).
- Chrome accelerators that act on a tab strip (`IDC_NEW_TAB`, `IDC_CLOSE_TAB`, `IDC_SELECT_*`, `IDC_FOCUS_LOCATION`, new window) are captured in `CefCommandHandler::on_chrome_command` and re-emitted as `CMUX_EVENT_COMMAND` for the shell (`client.rs:394-440`).
- Terminal views route key equivalents to the main menu first (cmux2:`apple/Sources/CmuxMac/TerminalView.swift:223-229`).
- With the fork, focus goes to the embedded child window. `CefBrowserHost::SetFocus` activates that widget (fork commit `a7bcbc0`). The child window "never becomes main", and it counts as active while the parent is key (fork commit `377a33a`, `chrome_child_window_mac.mm:118-140`).

### Browser process switches

`on_before_command_line_processing` adds `--cmux-tabbed-windows` and `--disable-field-trial-config` when the fork API is present, `--use-mock-keychain` under `CMUX_MOCK_KEYCHAIN`, and `--load-extension` for dev (cmux2:`crates/engine/src/client.rs:75-110`).

### Fork API detection and the added C API

The engine resolves the fork symbols with `dlopen(RTLD_NOLOAD)` + `dlsym` and checks `cmux_cef_api_version() == 1`. Stock CEF falls back to Alloy (cmux2:`crates/engine/src/fork.rs:43-92`). The symbols are plain C exports, so the CEF API hash is unchanged. The build script copies the header into dist (fork:`scripts/build-cmux-cef.sh`, last lines). `nm -gU` on the dist framework shows all 11 exports.

fork:`include/cef_cmux.h` (`CMUX_CEF_API_VERSION 1`). Browsers are addressed by `CefBrowser::GetIdentifier()`. UI thread only.

| Function | Purpose |
| --- | --- |
| `int cmux_cef_api_version(void)` | version gate |
| `void cmux_cef_free(char*)` | frees returned strings |
| `void cmux_tab_set_observer(cmux_tab_observer_t, void* ctx)` | events `CMUX_TAB_INSERTED/ACTIVATED/MOVED/REMOVED`, `CMUX_EXTENSION_ACTIONS_CHANGED`, `CMUX_EXTENSION_POPUP_CLOSED`, with `(window_id, browser_id, a)` |
| `int cmux_tab_add(int window_browser_id, const char* url, int index, int activate)` | adds a tab to that window's `Browser`. `OnAfterCreated` runs before it returns. |
| `int cmux_tab_activate(int browser_id)` | makes the tab the shown tab |
| `int cmux_tab_move(int browser_id, int index)` | reorders within its window |
| `int cmux_tab_window_id(int browser_id)` | window id of a tab |
| `char* cmux_ext_actions(int browser_id, int icon_px)` | JSON `[{id,name,title,badge,badge_color,badge_text_color,enabled,pinned,has_popup,icon_png}]`, base64 PNG without badge |
| `int cmux_ext_action_run(int browser_id, const char* ext, int x, int width)` | Chromium `ExecuteUserAction`: popup anchored at the top of the browser area in `[x, x+width)`, `onClicked`, `activeTab` grant |
| `void cmux_ext_action_hide_popup(int browser_id, const char* ext)` | hides the popup |
| `void cmux_ext_action_context_menu(int browser_id, const char* ext, int sx, int sy)` | Chromium's action menu (pin, options, remove, site access) |

cmux2's `fork::Api` does not bind `cmux_tab_window_id` or `cmux_ext_action_hide_popup` (cmux2:`crates/engine/src/fork.rs:24-33`).

Missing for cmux next: detach or attach a tab across windows (moving a CEF tab between panes), close through the tab strip, and a tab snapshot. Chromium has `TabStripModel::DetachWebContentsAtForInsertion`, so a fork `cmux_tab_move_to_window` is a small patch.

## 2. What the fork patches

Base: upstream CEF branch `8037` at `564dd6c` (CEF 154.0.28, Chromium 154.0.8037.58). 10 cmux commits `0e93c8e..4065bbf`, 28 files, +1785/-13 (`git diff --stat 564dd6c HEAD`).

| Change | Files | Why |
| --- | --- | --- |
| MV2 re-enabled | `patch/patches/cmux_extensions_manifestv2.patch` (ungoogled-chromium `800d0bb5`, BSD-3) | Chromium 154 rejects MV2. This makes full uBlock Origin work. |
| Chrome style with a macOS `parent_view` | `browser_host_create.cc` (drops the `IS_MAC` Alloy force, CEF issue #3294), `chrome_child_window.cc`, new `chrome_child_window_mac.{h,mm}` (`CmuxParentViewTracker`) | a frameless child `NSWindow` tracks the parent view frame, hidden state, window moves, fullscreen, and key state |
| One tabbed `Browser` per window (`--cmux-tabbed-windows`) | `chrome_browser_delegate.cc` (later tabs drop `browser_view`/`window_info`; hide title bar, tab strip, toolbar, location bar, bookmark bar), `chrome_browser_host_impl.cc` (keep `TYPE_NORMAL`), `cef_switches.*`, `cmux/cmux_window_registry.*` | extensions see one window with N tabs. `chrome.tabs`/`windows` work. |
| `cmux_tabbed_layout_hidden_toolbar.patch` | Chromium layout | tabbed layout CHECKed for Chrome's toolbar |
| `cmux_tab_strip_notify_uninserted.patch` | Chromium tab strip | tabs added by extensions notified before insertion and CHECKed |
| Native action API | `cmux/cmux_api.cc`, `cmux/cmux_extension_action_delegate.*`, `include/cef_cmux.h` | AppKit toolbar drives `ExtensionActionViewModel` |
| Embedded window activity | `chrome_child_window_mac.mm`, `views/ns_window.*`, `browser_view_impl.cc` | `Browser` is active while our window is key (`chrome.action.openPopup`) |
| Popup anchor | `cmux_window_registry.cc` (commit `4065bbf`) | popup anchor excluded from RootView fill layout |
| Build | `scripts/build-cmux-cef.sh`, `BUILD.gn` | `automate-git.py`, arm64 Release, minimal distrib, disk watchdog |

fork:`CMUX.md` is stale: it still says the patches are "design below, not written". cmux2:`docs/extensions-macos.md` has the current state.

Results with the fork (cmux2:`docs/extensions-macos.md`, "Update" section): `tabs.query` 1/1/1 (stock 0/0/0). `chrome.tabs.create` works. Full uBO 1.75 MV2 works. Web Store install works. The Bitwarden popup has the correct size. OneTab `onClicked` is partly verified. 1Password is blocked (native messaging host registered only for Chrome). The helper sandbox is on. Known gap: the address field stays empty for tabs that Chromium adds.

Tracker gaps that matter for cmux (fork:`chrome_child_window_mac.mm:60-110, 176-200`): it observes `NSViewFrameDidChangeNotification` on ancestors only, not `NSViewBoundsDidChangeNotification` on an enclosing `NSClipView`, so a niri scroll does not move the page. It sets the child frame to the full parent bounds with no clip to the visible rect, so a half-scrolled column draws over the sidebar. It orders the child window above the parent's entire content.

## 3. Integration plan

### Engine abstraction

The daemon owns browser tabs as canonical tabs (`TabPublicId`) with `kind = browser`, `engine = webkit | cef`, `profile_id`, `url`, and `title`. The frontend owns only the live engine object. The engine is fixed at tab creation. "Reopen in other engine" creates a new tab with the same URL.

```swift
@MainActor protocol BrowserEngine: AnyObject {
    var kind: BrowserEngineKind { get }                    // .webkit, .cef
    var capabilities: BrowserCapabilities { get }          // OptionSet: .cdp, .extensions, .trustedInput, .networkIntercept, .crossOriginFrames, ...
    func makeTab(_ id: TabPublicId, url: URL?, profile: BrowserProfileID, host: BrowserTabHostView) async throws -> any BrowserTab
}

@MainActor protocol BrowserTab: AnyObject, Observable {
    var id: TabPublicId { get }
    var state: BrowserTabState { get }                     // url, title, favicon, loading, canGoBack/Forward, zoom
    var presentation: BrowserPresentation { get }          // .inView (WKWebView) or .childWindow (CEF)
    func load(_ url: URL); func goBack(); func goForward(); func reload(); func stop()
    func setFocused(_ focused: Bool)
    func setOccluded(_ occluded: Bool) async               // CEF: freeze to snapshot + hide child window
    func snapshot() async throws -> CGImage                // WK takeSnapshot, CEF Page.captureScreenshot
    func evaluate(_ script: String, in frame: BrowserFrameRef?) async throws -> JSONValue
    func find(_ text: String, forward: Bool); func setZoom(_ step: Int)
    func showDevTools()
    func close() async
}
```

`WebKitEngine` wraps `WKWebView` directly in the host view. `CEFEngine` wraps the Rust library (see below). The frontend never branches on engine kind except through `capabilities` and `presentation`.

Child-window rules for `.childWindow` tabs (Decision 2):
- The command palette, popovers, and menus are separate `NSPanel`s at a level above the child windows. Then no in-window overlay is needed.
- App overlays (2026-09-29, `WindowOverlayLayer`): the layout's visual overlays (focus ring, inactive dim, drop highlight) live in one `OverlayPlane` placed in layout-root coordinates. While a window has a visible page window, the plane moves into a click-through overlay child panel kept directly above every page window (child order is `childWindows` order and `order(_:relativeTo:)` has no effect on child windows, so the layer re-adds windows when the fork re-adds a page); app child panels stay above it. Without page windows the plane stays in the root: no extra window. Overlays that take the mouse (divider hit areas, the screen switcher) stay in the parent and reach pages as occlusion holes (`BrowserWindowOcclusionProviding`). Occlusion holes alone were rejected: a hole shows the placeholder, not the page, under a translucent drop zone, and would need per-frame updates while it animates. `debug.layers` reports child order, plane placement and sync, and page window vs host frame.
- Accessibility window managers (Rectangle, 2026-09-30): AppKit reported the page child window as the app's AX focused and main window (the key window, or with none the frontmost ordered window), so Rectangle moved and resized the page itself, off its pane; the fork re-places pages only on parent notifications. `CmuxApplication.accessibilityFocusedWindow/MainWindow` now report the cmux window that owns a page (panels stay themselves), and `WindowOverlayLayer` re-places a page window that an outside client moved directly. `ChildPageGeometry` is the invariant (page window == pane screen rect); DEBUG `debug.window.ax_set_frame` reproduces Rectangle through AX on the tagged app's own window (`target: "page"` for the page window).
- Window moves from any source (drag, Accessibility clients such as Rectangle, display or Space changes, fullscreen, deminiaturize) re-apply page geometry: the page window is an `addChildWindow` child (fork), the fork observes the parent's move/resize/screen/backing notifications, and the app additionally asks every page of the window to re-apply on those notifications and once more after the layout pass they schedule (`BrowserChildWindowPages.needsUpdate`).
- Sidebar Liquid Glass must not sit over a CEF pane. Keep panes inset from glass, or accept the plain background next to CEF.
- Column scroll, tab open/close animations, tab drag, and hover previews: call `setOccluded(true)`, which shows a `Page.captureScreenshot` image in the placeholder view and hides the child window. Restore after the settle signal. Fork patch: observe clip-view bounds changes and clip or hide when the placeholder is only partly visible. Do not ship the no-clip behavior.

Chromium `Browser` per pane (Decision 1): the first CEF tab in a pane creates the tabbed browser in that pane's placeholder view. Later CEF tabs in the pane use `cmux_tab_add`. The pane's selected tab maps to `cmux_tab_activate`. When a WebKit or terminal tab is selected, the placeholder is hidden and the tracker hides the child window. Cross-pane moves need the new fork call. Without it, a move recreates the tab and loses page state.

### Rust crate or Swift against the CEF C API

Recommended: **a new slim Rust crate `cmux-cef` in the cmux repo, built into a static lib**, derived from cmux2's `crates/engine`. Do not reuse `cmux-ffi` as it is.

- Keep from cmux2: process setup and switches (`client.rs:75-110`), sandbox entry, `LibraryLoader`, the fork binding (`fork.rs`), handlers (display, load, life span with popup-as-tab and `do_close` returning 1 on macOS, keyboard, command), the extension action JSON, and the `chrome://` page opening.
- Delete from it: `cmux-core` (tab strip, session, omnibox), terminal tabs, the layout enum, the stock-CEF Alloy fallback and `chrome_window.rs`, and popups-as-browsers for stock CEF. Tabs are keyed by the daemon `TabPublicId`, and the frontend owns order and selection.
- New surface: `cmux_cef_initialize(config, host)` with `external_message_pump`, `cmux_cef_do_work()`, `cmux_cef_create_window(pane_view)`, `cmux_cef_tab_add/activate/move/close`, `cmux_cef_devtools_call(browser, method, params_json, cb)` (`CefBrowserHost::ExecuteDevToolsMethod` + observer), `cmux_cef_target_id(browser)` (via `Target.getTargetInfo`), and a profile to request-context mapping.
- Why Rust rather than Swift over `include/capi`: the C API is hand-refcounted structs of function pointers (`cef_base_ref_counted_t`) with one callback struct per handler. Swift would need about 30 `@convention(c)` trampolines and manual layout, and it duplicates `cef-rs`, which already generates safe wrappers, pins the API hash, and implements the loader and the sandbox. cmux already runs cargo inside the Xcode build (`cmux:cmux.xcodeproj/project.pbxproj:13077`, `run-diff-sidecar-cargo.sh`). The helper stays a Rust binary (`crates/helper` is 16 lines).
- Cost: the `cef` crate version must match the fork's CEF branch. Upgrading CEF means bumping `cef` and rebasing the fork together.

### Lazy loading

Goal: a cmux session with no CEF tab does not load the 584 MiB framework, does not spawn helpers, and does not open the Chromium profile.

1. Do not link the framework. `LibraryLoader` loads it on first use. The only link-time cost is the static Rust lib, which is small without `cmux-core`.
2. The cmux `NSApplication` subclass always implements `CrAppControlProtocol`/`CefAppProtocol` (pure ObjC, no CEF symbols), because it must be `NSApp` before CEF starts. This is cmux2's `CmuxApplication` without `terminate:` changes until CEF is live.
3. On the first CEF tab: load the library, then `CefInitialize` with `external_message_pump = 1`. Implement `OnScheduleMessagePumpWork(delay)` with one `CFRunLoopTimer` on the main run loop in common modes, reset on each request (this is the cefclient `MainMessageLoopExternalPumpMac` pattern), and call `CefDoMessageLoopWork`. This fits the cmux "no `asyncAfter`" rule, because the timer is owned and cancellable. Show a placeholder until `on_context_initialized`.
4. `CefInitialize` runs once per process and cannot run again after `CefShutdown`. After the last CEF tab closes, keep CEF alive and idle. Quit path: if CEF is live, `terminate:` closes all CEF browsers, waits for all-closed, calls `CefShutdown`, then replies `NSTerminateNow`. Otherwise it quits normally.
5. **UNVERIFIED, highest technical risk:** Chrome-style `CefInitialize` after `[NSApp run]` has started and after cmux has installed its own menus. cefclient calls `CefInitialize` before `[NSApp run]` even with the external pump. Chrome style also installs its own `NSApp` delegate hooks and main-menu items. Spike this first in cmux2: move `cmux_initialize` behind a button, with the external pump. If it fails, the fallback is to initialize CEF at launch when the daemon reports any CEF tab or a setting enables CEF. The cost then moves to "users who opt in".

### Per-profile data dirs

The daemon owns the profile identity (`BrowserProfileID` UUID, name). Each engine derives its storage from it:

- WebKit: `WKWebsiteDataStore(forIdentifier: profileUUID)` (macOS 14+). The history file lives under the cmux app support profile dir.
- CEF: `root_cache_path = ~/Library/Application Support/<bundle id>/Chromium`. Each profile gets a `CefRequestContext` with `cache_path = <root>/Profiles/<uuid>`. Each cmux profile is a separate Chromium `Profile`, with its own extensions and Chrome windows. The default profile uses its own subdir too, not the root (Chrome 136+ blocks remote debugging on the default user data dir).
- Tagged DEV builds already have distinct bundle ids and therefore distinct dirs. DEV and tagged builds always pass `--use-mock-keychain`, because every new ad-hoc signature re-prompts for "Chromium Safe Storage" (cmux2:`client.rs:88-95`). Release uses the real keychain item.
- Engines do not share cookies. A later "copy cookies to other engine" action can use `WKHTTPCookieStore` and CDP `Network.getAllCookies`/`setCookies`.

### Socket browser automation

Today: 138 `v2Browser*` handlers on `TerminalController` (cmux:`Sources/TerminalController.swift:3172-3232, 9934-10000`). Most run JS strings built by `CmuxBrowser/Control/BrowserControlService+Scripts.swift` through WKWebView. These return `not_supported` on WebKit: `geolocation.set`, `offline.set`, `trace.*`, `network.route/unroute/requests`, `input_mouse/keyboard/touch`, and cross-origin frames (cmux:`Sources/TerminalController.swift:11334-11389, 9815`).

The daemon already has what CEF needs: `RegisterBrowserProvider {provider_id, endpoint, authentication, bearer_token, targets}`, allowed only from trusted Unix clients (cmux:`cmux-tui/crates/cmux-tui-core/src/server.rs:11461-11492`). A connection-scoped, non-durable registry maps `TabPublicId` to a CDP `target_id` (cmux:`cmux-tui/crates/cmux-tui-core/src/browser_provider.rs`). The `browser.*` daemon commands (`navigate`, `back`, `input.*`, `viewer.resize`, `target.adopt`) and TUI screencast mirroring are CDP clients through `cmux-tui-cdp` (cmux:`cmux-tui/docs/browser-panes.md`).

Proposed mapping (Decision 4):

| Command family | WebKit tab | CEF tab |
| --- | --- | --- |
| navigate/back/forward/reload/stop, url/title | frontend `BrowserTab` | CDP `Page.*` (daemon) |
| eval, find.*, get.*, is.*, snapshot, wait, highlight | same JS scripts via `evaluateJavaScript` (keep `BrowserControlService` scripts) | the same JS scripts via `Runtime.evaluate`, so the output is byte-identical across engines |
| click/dblclick/hover/type/fill/press/keydown/keyup/scroll | synthetic DOM events in JS (untrusted) | `Input.dispatchMouseEvent`/`dispatchKeyEvent`/`insertText` (trusted events), coordinates from `get.box` |
| input_mouse/keyboard/touch | not_supported | CDP `Input.*` |
| screenshot | `takeSnapshot` | `Page.captureScreenshot` |
| cookies, storage | `WKHTTPCookieStore`, JS storage | `Network.*Cookies`, `DOMStorage`/JS |
| network.route/requests, offline, geolocation, viewport, trace | not_supported (viewport keeps the current WK emulation) | `Fetch.enable`/`requestPaused`, `Network.emulateNetworkConditions`, `Emulation.setGeolocationOverride`, `Emulation.setDeviceMetricsOverride`, `Tracing.*` |
| frame.select | same-origin only | `Page.getFrameTree` + execution contexts, cross-origin works |
| dialog.accept/dismiss | `WKUIDelegate` pending dialog | `Page.javascriptDialogOpening` / `handleJavaScriptDialog` |
| downloads | frontend `WKDownload` | `Browser.setDownloadBehavior` + `downloadProgress` |
| devtools.toggle | `WKWebView` inspector | `CefBrowserHost::ShowDevTools` |
| tab.new/list/switch/close | daemon tree | daemon tree plus `cmux_tab_*` |

Path: CLI → daemon. The daemon resolves the tab. For CEF with a provider lease, the daemon runs CDP itself. For WebKit, the daemon forwards to the owning frontend client, which advertises a `browser.webkit.executor` capability. The capability error text is generated from `BrowserCapabilities`, not hard-coded "WKWebView". Inside the frontend, CEF also has in-process CDP (`ExecuteDevToolsMethod`) for tab previews and occlusion snapshots, so the app does not depend on the port.

Provider registration: after `CefInitialize`, the frontend opens a loopback DevTools endpoint (Decision 5), reads `DevToolsActivePort`, and registers `{provider_id, endpoint, targets: {tab_id: target_id}}` over its trusted Unix connection. It re-registers when tabs change. The daemon already handles provider disconnect and target replacement.

## 4. Distribution

Sizes measured on 2026-09-28:

| Artifact | Size |
| --- | --- |
| dist framework (non-official, arm64, `symbol_level=0`) | 691 MiB total, 584 MiB binary |
| binary after `strip -x` | 367 MiB, about 93 MiB with `xz -6` |
| minimal distrib `.tar.bz2` from the build tree | 198 MiB (`~/fun/cef-cmux-build/chromium/src/cef/binary_distrib/`) |
| stock CEF 154 framework in `cmux2.app` | 320 MiB |
| Chromium build tree (no history) | 46 GiB. Script budget 150 GB, requires 350 GiB free (fork:`scripts/build-cmux-cef.sh:19-28`) |

Hosting and pinning (same model as GhosttyKit, cmux:`scripts/download-prebuilt-ghosttykit.sh:52`, `scripts/ghosttykit-checksums.txt`):

- A new repo `manaflow-ai/cef` holds branch `cmux/8037` (push fork history there). GitHub release tag `cef-<forksha12>-chromium-154.0.8037.58-macos-arm64`. Asset `cef-cmux-minimal.tar.xz`: stripped framework, `include/` (with `cef_cmux.h`), `cmake/`, `libcef_dll/`, and `archive.json` (the layout `build-cmux-cef.sh` already writes). Also upload the unstripped binary or dSYM as a separate asset for Sentry symbolication. The GitHub asset limit is 2 GiB, so the size fits.
- cmux repo: `scripts/cef-version.txt` (fork SHA + Chromium version) and `scripts/cef-checksums.txt` (`<forksha> <sha256>`). `scripts/ensure-cef.sh` downloads into `~/Library/Caches/cmux/cef/<forksha>/`, verifies sha256, refuses on mismatch, and exports `CEF_PATH`. Local override: `CMUX_CEF_PATH=~/fun/cef-cmux-dist` for fork development, which skips the checksum and prints a warning.
- cmux-ci fleet Macs and hosted CI then need only network access. Keep the cache across jobs, because a cold fetch is about 100-200 MB. Jobs that do not need CEF (unit tests, most CI) build with `CMUX_CEF=0`: the CEF engine is compiled out or reports unavailable, and nothing is fetched. Nightly, release, and tagged reloads use `CMUX_CEF=1`.
- Building the fork is not a CI job (hours, about 150 GB). Build on one designated fleet Mac with the disk, run `build-cmux-cef.sh build`, then a small `publish-cef.sh` that tars, hashes, and creates the release. Then open a cmux PR that bumps both pin files.

Signing and notarization:

- Helper names must be `<CFBundleName> Helper (X).app`. cmux has several bundle names (`cmux`, `cmux NIGHTLY`, `cmux DEV <tag>`), so helper names are generated per variant at build time. Set `browser_subprocess_path` explicitly to the base helper. **To verify:** CEF derives the `(GPU)`/`(Renderer)` variant paths from the base helper name.
- Sign from the inside out, without `--deep`: `Libraries/*.dylib`, the framework, each helper (hardened runtime, `--timestamp`), then the app. Helper entitlements follow Chromium: Renderer and GPU need `com.apple.security.cs.allow-jit` (`~/fun/cef-cmux-build/chromium/src/chrome/app/helper-{renderer,gpu}-entitlements.plist`). Base, Plugin, and Alerts need none. The main app already has `allow-jit`, `allow-unsigned-executable-memory`, and `disable-library-validation` (cmux:`cmux.release.entitlements`), and camera, microphone, and location usage entitlements that Chrome also needs.
- Notarization: one more 600 MiB Mach-O makes the upload and scan slower. The release flow in cmux:`.github/workflows/release.yml:561-592` needs no structural change. Sparkle deltas stay small when the framework does not change between releases. A fork bump means a full framework delta.
- Keychain: release builds create a "cmux Safe Storage" item on the first CEF launch. A signing identity change re-prompts.
- On-demand runtime (Decision 8, later): a separately signed and notarized `cmux Chromium.bundle` in Application Support, loaded with `framework_dir_path`/`main_bundle_path` and an explicit `browser_subprocess_path`. This keeps the DMG size flat. The cost is a second notarized artifact and version skew between the app and the runtime.

## 5. Existing cmux browser code: delete vs keep

Scale: `Sources/*Browser*.swift` = 146 files, 47,291 lines. `Packages/macOS/CmuxBrowser` = about 30.5k lines (11.6k import AppKit/WebKit/Bonsplit, 12.2k are pure). Also `BrowserPanel.swift` 11.5k, `BrowserPanelView.swift` 8k, `BrowserWindowPortal.swift` 4.3k, and browser code inside `TerminalController.swift`, `Workspace.swift`, and `ContentView.swift`.

Delete (do not port):

- All of `Sources/Panels/Browser*`, `Sources/Browser*` (portal, render state, drop targets), `BrowserWindowPortal.swift` (the WKWebView reparenting hack for bonsplit), `BrowserPopupWindowController.swift`, `BrowserPrewarmedWebViewPool.swift`, `BrowserDiscardRestoreHeal.swift`, `BrowserPanel+AutomationRecovery.swift`, `BrowserPanel+MobileBrowserStreaming.swift` (the daemon CDP screencast replaces it for CEF), `Workspace+DockBrowserLookup.swift`, `TerminalController+WindowDockBrowserRouting.swift`, and the `DockSplitStore` browser paths. All of these are lifecycle and layout owners that the daemon plus `BrowserTab` replace.
- The 138 `v2Browser*` handlers in `TerminalController`. Re-implement them once over the table in section 3.
- `CmuxBrowser/WebView/` (6.4k, including `CmuxWebView.swift` 2.7k), `BrowserHiddenWebViewDiscardManager`, `BrowserOffscreenRenderHost`, `BrowserViewportHostView`, and the scripted-download and context-menu-capture extensions. Write a new, small `WebKitEngine` against the protocol.
- `Panel/`, `Focus/`, `Omnibar/PageFocus/`, `AppSession/` UI parts, `RecentlyClosed/` (the daemon journal owns closed tabs), `Screenshot/` frame verifiers, and the `Bonsplit` dependency in `Package.swift`.
- cmux2's AppKit shell (`apple/Sources/CmuxMac/*`) is also a demo. Take only `CmuxApplication` (CefAppProtocol) and the extension action button logic from `BrowserToolbar.swift:91-165`.

Keep (pure, tested, engine-neutral; move into a new small `CmuxBrowserCore` package without AppKit):

- `Control/BrowserControlService*.swift` (JS locator, snapshot, storage, and keyboard scripts), `BrowserKeyboardEvent`, `BrowserKeyboardNativeKey` (canonical key names that map to both native events and CDP `Input.dispatchKeyEvent`), `BrowserAutomationDocumentReadiness`, `BrowserAutomationNavigationURL`, `BrowserAutomationWatchdog`. Keep their tests.
- `Omnibar/BrowserURLResolver.swift` and `History/BrowserHistorySuggestionEngine.swift`, `BrowserHistoryEntry`, `BrowserHistoryFileRepository`. Use one resolver for both engines, and drop cmux2's `cmux_core::resolve_omnibox_input`.
- `Import/Detection/BrowserInstalledBrowserDetector` and the `Import/Values`/`Outcome` types, for importing into WebKit profiles.
- `Download/BrowserDownloadFilenameResolver` and `BrowserDownloadURLNormalizer` (WebKit only; Chromium does its own downloads).
- WebKit-only, keep only if WebKit keeps the feature: `WebAuthn/BrowserWebAuthnSupport.swift` (1.9k, the passkey bridge that uses the `web-browser.public-key-credential` entitlement; CEF passkey support with that entitlement is untested), `Proxy/BrowserSystemProxyMirror` (WebKit has no loopback proxy bypass), `ClientCertificates/*` (Chrome style shows Chromium's own selector).
- `DiffViewer/*` and `DesignMode/*` are cmux features hosted in WKWebView, not browser engine code. They are out of scope for this note. They stay WebKit-hosted surfaces and do not need the engine protocol.
- `Profiles/Repository/BrowserProfileRepository` is tied to `WKWebsiteDataStore` and `UserDefaults`. Rewrite it: the daemon stores profile identity, and each engine maps it to storage.

## Order of work

1. Push the fork and cmux2 to `manaflow-ai` (Decision 3). Publish the current dist as the first pinned artifact.
2. Spike in cmux2: lazy `CefInitialize` with the external pump after `NSApp.run` starts. Also check one browser per view with two views side by side, and clip-view scrolling.
3. Fork patches: clip-view tracking and visible-rect clipping, cross-window tab move, and a `CMUX.md` refresh. Bump `CMUX_CEF_API_VERSION` to 2.
4. `cmux-cef` crate, `ensure-cef.sh`, the helper app assembly, and signing in the Xcode build.
5. `BrowserEngine` protocol, `WebKitEngine`, `CEFEngine`, and the daemon `engine` and `profile_id` fields on browser tabs.
6. Automation: daemon CDP executor for CEF, WebKit executor capability in the frontend, and the ported JS scripts.

## Spike results (2026-09-28)

Code: branch `spike/lazy-cef` in worktree `~/fun/cmux2-spike`, commit `5f3e534` (not pushed). `apple/Sources/CmuxMac/Spike.swift` (the `--spike` mode of cmux2), `crates/ffi/src/spike.rs` + `crates/ffi/include/cmux_spike.h` (small C ABI over the `cef` crate), `scripts/spike-drive.sh`. Evidence: `docs/spike-2026-09-28/` (screenshots `NN-*.png`, logs `logs/runN-spike.log`). Build: `CEF_PATH=~/fun/cef-cmux-dist scripts/build-mac.sh release`. The dist is the fork: `include/cef_cmux.h` is present and `nm` shows all 11 `cmux_*` exports. The spike detected the fork API at run time (`fork_api=true`) and used `--cmux-tabbed-windows`.

### 1. Lazy init: works, with the external message pump

Sequence that works (run1, run2, run3, run5, run8):

1. `main` creates `CmuxApplication.shared` (the `CefAppProtocol` subclass), sets the delegate, and calls `NSApp.run()`. The CEF framework is not linked and not loaded (`framework mapped before init: false`).
2. Later (timer or button, on the main thread, while `NSApp.isRunning == true`): `LibraryLoader::load` (49-71 ms), then start one `CFRunLoopTimer` on the main run loop in common modes, then `CefInitialize` with `external_message_pump = 1`.
3. `on_schedule_message_pump_work(delay)` can arrive on any thread. It moves to the main thread with `CFRunLoopPerformBlock` + `CFRunLoopWakeUp`, then sets the timer's next fire date (`delay <= 0` means now, capped at 1/30 s). The timer calls `CefDoMessageLoopWork`, then re-arms at 1/30 s. The re-entrancy guard is from cefclient `MainMessageLoopExternalPumpMac`.
4. `on_context_initialized` runs **synchronously inside `CefInitialize`**, 0.40-0.51 s after the start. Browsers can be created from that callback. `CefInitialize` returns after 0.41-0.59 s. The first browser exists after about 0.56 s. The page `load_end` comes about 1.0 s after the start.

Other results:
- Helpers start normally from the bundle, and the helper sandbox is not changed. The renderer, GPU and utility helpers appear after the first browser.
- The fork API must be found by path with `dlopen(RTLD_NOLOAD)`, as in `fork.rs`. `dlsym(RTLD_DEFAULT)` fails because the `cef` crate loader opens the framework `RTLD_LOCAL`.
- No focus steal was seen. The app was launched with `open -g`, and the window uses `orderFront` only. `lsappinfo front` never showed cmux2. In one screenshot (16) the spike window has colored traffic lights. The cause is not known and could be a user click.
- **Rejected:** `external_message_pump = 0` with no `CefRunMessageLoop` (run6). This crashes at once: `FATAL message_pump_apple.mm:360 DCHECK failed: nesting_level_ != 0` from `MessagePumpCFRunLoopBase::EnterExitObserver` (see `logs/run6-cef-fatal.txt`). The dist has DCHECKs enabled.
- **Rejected:** a nested `CefRunMessageLoop` called from a timer callback (run7). It runs, but that callback never returns until quit.
- **Quit path, new risk:** `close_browser` on all browsers, then `CefShutdown` right after the last `on_before_close` (51 ms) causes a crash. The crash is `CHECK` in `tabs_api::TabDragServiceImpl::~TabDragServiceImpl` from `Browser::~Browser` during `ProfileManager` teardown (`DiagnosticReports/cmux2-2026-09-28-223653.ips`). The tabbed Chromium `Browser` lives longer than its CEF browsers, because `do_close` returns 1. When the pump runs 2 s more before `CefShutdown`, the call returns in 47 ms and there is no crash (run9). After that the process exited with no crash report. I did not find out why. A product fix needs a fork signal such as "window destroyed" before `CefShutdown`, not a timer. This probably applies to eager init too. I did not check whether cmux2 `main` has the same crash.
- Not tested: pumping during menu tracking or a modal loop, keyboard focus into the page, DevTools, extensions, and **main-menu/`NSApp` delegate changes by Chrome style**. The spike app has no main menu, so the browser.md risk "Chrome style installs its own menu items after cmux menus exist" is still open.

### 2. Child-window placement: follows ancestor frame moves, never clips

Setup: a 150 pt "sidebar", then a clipping viewport (`clipsToBounds`) with a wider strip that holds 560 pt columns. Scrolling animates `strip.frameOrigin.x` at 60 Hz over 1.5 s or 6 s. At each tick the spike compares the host rect with the child `NSWindow.frame` and with the WindowServer bounds (`CGWindowListCopyWindowInfo`).

| Case | Follows host | Clipped to viewport | Evidence |
| --- | --- | --- | --- |
| Frame-origin scroll, no mitigation | Yes. AppKit child frame within 1 pt at every tick. WindowServer bounds 1-4 pt behind at slow speed, up to 23 pt at 200 pt/s (about one tick behind the parent). | **No.** The page covers the sidebar by 280 pt and leaves the parent window's edges (left edge at x=300, right edge by 30 pt at rest). | `02`, `11`, `01` |
| `NSScrollView` clip-view scroll, no mitigation | **No.** The page stays in place, 300 pt off, because the tracker does not observe `boundsDidChange`. | No | `21` |
| Clip-view scroll + host posts `NSViewFrameDidChangeNotification` for each host view on `boundsDidChange` | Yes (within 1 pt) | No | `23` |
| **hide**: `host.isHidden = true` when the host's visible rect differs from its bounds (the tracker KVO-observes `hidden`) | n/a | Yes, 0 pt overflow | `04`, `15` |
| **mask**: `CAShapeLayer` mask on the child `BridgedContentView.layer` set to the visible rect at each tick, plus `child.isOpaque = false`, `backgroundColor = .clear` | Yes | **Yes, exact clip** at the viewport edge, during animation and at rest | `16`, `17`, `18` (`13` shows the opaque child background before the `isOpaque` fix) |
| **snapshot**: CDP `Page.captureScreenshot` in process (`send_dev_tools_message` + observer), 2 captures in 84-283 ms (2x pixels), `NSImageView` over each host, hosts hidden while scrolling | n/a (the image scrolls with the column) | Yes while scrolling | `12` mid-animation. At rest the live window comes back unclipped (`08`), so combine this with hide or mask. |

Conclusions for Decision 2:
- A frame move of an ancestor view is enough for the page to follow. niri-style scroll must move frames, or post frame-change notifications for host views. A clip-view bounds scroll alone does not work with the fork as it is.
- Clipping is never automatic. **mask** is the best host-side result: the page stays live and is clipped exactly. But it changes CEF's `NSWindow` from outside (opacity and a layer mask on Chromium's content view). Mouse hit-testing in the masked-out part of the child window is **not tested** (it is probably still captured, because the window shape does not change). The correct place for this is a fork patch in `CmuxParentViewTracker`: observe `boundsDidChange` on each enclosing `NSClipView`, apply the visible-rect mask, and set `ignoresMouseEvents` or a shaped hit test.
- **hide** is simple and safe, but a column loses its content as soon as 1 pt of it is off-screen. **snapshot** is good for animations, and the capture latency (84-283 ms) must happen before the scroll starts.

### 3. Two browsers side by side: works

With `--cmux-tabbed-windows`, each `browser_host_create_browser` call with its own parent view created its own Chromium `Browser` (browser ids 1 and 2), with one child window for each host view. Both render and track independently (`01`, `10`). This supports Decision 1 (one `Browser` per pane).

### Items I did out of laziness, or did not verify

- The cmux-cua MCP daemon refused every call ("Computer Use onboarding is still in progress"). I took the screenshots with `screencapture -x -o -l <window>` for the spike window only. Window capture includes the child windows, so the overflow is visible. I did not touch the user's windows or change focus.
- The `hide` and `mask` rows in the logs show `max|child-host|=600pt`. This is a bug in the spike's child-to-host matching when one child is hidden, not a real offset. Use the screenshots for those rows.
- I did not record video, so the frame-level lag between the parent content and the child window is estimated from WindowServer bounds only. Each case ran once.
- The child windows show rounded bottom corners (visible in every screenshot). This is cosmetic, and the fork should remove it.

## Fork clip patches

Fork branch `cmux/8037-clip` in `~/fun/cef-cmux` (pushed to `manaflow` only), head `909710c`. Dist: `~/fun/cef-cmux-dist-clip` (`archive.json` names `909710c`). `~/fun/cef-cmux-dist` is not changed. Re-test code: `~/fun/cmux2-spike` branch `spike/lazy-cef-clip`, commit `3ceaee7` (not pushed). Evidence: `docs/spike-2026-09-28-clip/` (screenshots `NN-*.png`, logs `logs/f1..f3-*.log`).

Commits on top of `cmux/8037`:

1. `9750b78` Tracking. The tracker observes `NSViewBoundsDidChangeNotification` on the parent view and every ancestor (clip-view scrolling), and frame changes as before. A zero-size probe subview of the parent view receives `viewDidMoveToWindow`, `viewDidMoveToSuperview`, `viewDidHide` and `viewDidUnhide` for any ancestor change (this replaces the per-ancestor `hidden` KVO). The embedder can post `CmuxParentViewGeometryDidChange` (object = parent view) for moves that AppKit does not report.
2. `3e0e4b3` Clip and mouse. A `CAShapeLayer` mask on the page window's content view clips the page to the visible part of the parent view (intersection with `NSClipView`, content view, frame view, and `clipsToBounds` or `masksToBounds` ancestors). The page window keeps its full size, so the page does not relayout. The window is borderless, not opaque. In masked parts the page window sets `ignoresMouseEvents`, so the WindowServer sends clicks, hover, scrolling and drags to the parent window. The state follows the pointer (geometry updates, page mouse events through a new `CefNSWindow` event filter, a tracking area on the parent view) and never changes while a button is down. A press that still reaches the page at a masked point is sent again to the parent window with its gesture.
3. `bd9de19` Lifetime. `cmux_browser_window_count()` and the observer event `CMUX_BROWSER_WINDOW_DESTROYED` (6, `a` = remaining count). The fork counts every Chromium `Browser` that held a CEF browser until `~Browser` destroys its `TabStripModel`, and sends the event from a posted task after the destructor returns. `CMUX_CEF_API_VERSION` is now 2 (additive).
4. `d7b6e4b` Z-order. The parent view can implement `-cmuxOcclusionRects` (NSArray of NSValue NSRect, parent view coordinates). The mask gets holes there (even-odd) and the mouse goes to the parent window. Native UI in the parent view hierarchy then shows above the page. The page window stays above all parent views everywhere else. Child windows that the embedder adds to the parent window after the page (popovers, panels) are already above the page. A translucent overlay cannot blur the live page, because the page is not below it in the parent window (that needs a snapshot).
5. `909710c` Square corners (does not work, see below), and route again on page mouse moves at visible points.
6. `fe1054a` `CMUX.md` rewritten for the fork as built.

Build: incremental `nice -n 19 scripts/build-cmux-cef.sh build`, 819 s (patches 1-4), then 254 s (patch 5). No errors.

Re-test results (final dist, one run each case):

| Case | Result | Evidence |
| --- | --- | --- |
| Frame-origin scroll, no host mitigation | **Pass.** The page follows (AppKit child frame within 1 pt, WindowServer 4-10 pt behind at speed, as before) and is clipped exactly at the viewport edge. It does not cover the sidebar, during the animation and at rest. | `02`, `03` |
| `NSScrollView` clip-view scroll, no mitigation | **Pass.** The page follows the bounds scroll within 1 pt and is clipped. Before, it stayed 300 pt off. | `21`, `22` |
| Vertical clip (host 200 pt below the viewport bottom) | **Pass.** Top part shows, bottom part is clipped at the viewport edge. The mask is in the correct coordinate direction. | `04` |
| Synthetic press at a masked point (over the sidebar) | **Pass.** The sidebar view gets mouseDown and mouseUp. The page gets nothing. | `logs/f1-frame-spike.log` (`HIT[masked-over-sidebar]`) |
| Synthetic press at a visible page point | **Pass.** The page gets `mousedown`. The sidebar gets nothing. | `HIT[visible-pageA]` |
| Occlusion rect on host 0 | **Pass.** The yellow parent view shows above the page in the hole. A press there does not reach the page and goes to the parent window. | `09`, `HIT[occluded]` |
| Quit with the signal: close all, wait for all `OnBeforeClose`, wait for count 0, `CefShutdown` | **Pass**, tabbed and non-tabbed. Count reaches 0 about 140-150 ms after the last `OnBeforeClose`; `CefShutdown` returns in 350-400 ms; no crash report. | `f1`, `f3` logs |
| Quit without waiting (`shutdown 0`, old path) | Still fails: the process dies in `CefShutdown`. This time the report is a DCHECK in `CefDoMessageLoopWork` from the spike's pump timer that is still armed, not the `TabDragServiceImpl` CHECK. | `logs/f2-shutdown-0-crash.ips` |
| Rounded page corners | **Not fixed.** The corners stay rounded in tabbed and non-tabbed mode. The window is borderless and reports corner radius 0, so the rounding comes from Chromium's content drawing (not found). Cosmetic. | `02`, `31` |

Items I did not verify, or did out of laziness:

- The mouse routing was tested with synthetic `NSEvent`s sent to the page window only. That tests the event filter and the forward to the parent window, but not WindowServer routing through `ignoresMouseEvents`, because a real test would move the user's pointer. `NSWindow.windowNumber(at:)` returned another app's window above the spike window, so it gave no evidence. The `ignoresMouseEvents` state was correct in the logs (true where the real pointer was outside the visible rect).
- A press forwarded to the parent in the race case (pointer moved and pressed before the first move event) goes through `-[NSWindow sendEvent:]`. A parent control that runs its own tracking loop gets the following drag and up events with page-window coordinates. This case is rare, but a native control can misbehave in it.
- The tracking area uses `NSTrackingInVisibleRect`. If an embedder relies on ancestors with `clipsToBounds = NO` on macOS 14+, AppKit's visible rect can be smaller than the fork's visible rect, and the page can stay mouse-blind in the difference until the next geometry update.
- The probe is a subview of the embedder's host view. An embedder that removes all subviews of the host view removes the probe too (tracking then continues only through notifications).
- `CMUX_CEF_API_VERSION` went from 1 to 2. cmux2 `crates/engine/src/fork.rs` on main rejects any version other than 1, so cmux2 main disables the fork API with the new dist. The spike branch changes the check to `< 1`; cmux2 main needs the same one-line change.
- Commit `909710c` keeps a private-API override (`-_getCachedWindowCornerRadius`) that had no visible effect. I kept it because the dist was built from it; it can be removed in the next fork change.
- The spike's GhosttyKit symlink target (ghostty `e168fd3`) was pruned from the cache. I built the spike with ghostty `72ff13a` (a descendant) and restored the symlink after.
- Each case ran once. No video.

## Chromium top band: fixed (2026-09-29)

Symptom (PR #15776): every CEF tab in cmux-next showed a dark band about 31 pt high at the top of the page, the page was shifted down by that height, and its bottom was cut off.

Cause, measured on tagged build `cefbnd` with `enable-ui-devtools` (Views tree) and lldb (`_subtreeDescription` of the page `NSWindow`):
- Chromium's Views layout was correct: `TopContainerView` height 0, `ContentsWebView` at y=1, 628 pt high in the 629 pt window.
- The AppKit layer was wrong: the `BridgedContentView` of the page window sat at y=-31 in its frame view, with an `NSTitlebarContainerView` (32 pt, backdrop) above it. That titlebar container is the band; its bottom line is the separator.
- The -31 is set at `-[NSWindow setContentView:]` inside `NativeWidgetNSWindowBridge::CreateContentView`. `CefNativeWidgetMac::CreateNSWindow` created the page window titled; AppKit's `constrainFrameRect:toScreen:` moved the titled window below the menu bar at its initial bounds (0,0 on the main screen), and Views placed the content view that far below the window top. The tracker's later switch to `NSWindowStyleMaskBorderless` kept the offset, and `CefNSWindow +frameViewClassForStyleMask:` returned the theme frame (`CefThemeFrame`) for every style mask, so the titlebar container and rounded corners stayed too.
- Why the spike never showed the band is not determined (same fork code); its hosts may never hit the constraint.

Fix: fork branch `cmux/8037-band` (pushed to `manaflow` only) on top of `cmux/8037-clip`:
1. `5364b925a` Only titled windows get the theme frame; a borderless window gets Chromium's `NativeWidgetMacNSWindowBorderlessFrame`. This also makes the page corners square, and removes the `_getCachedWindowCornerRadius` override from `909710c` that had no effect.
2. `3a68cdd61` `CefNativeWidgetMac` creates the page window borderless from the start when its Window delegate is the embedded child-window delegate (`chrome_child_window::IsEmbeddedWindowDelegate`, a registry of live `ChildWindowDelegate`s). Borderless windows are never moved by `constrainFrameRect`.

Incremental builds: 178 s and 132 s (`nice -n 19`). Dist: `~/fun/cef-cmux-dist-band`. Release: https://github.com/manaflow-ai/cef/releases/tag/cef-154.0.28-cmux.3-band (same packaging as `cmux.2-clip`), pinned in `scripts/cmux-next/cef-manifest.json`.

Verification:
- cmux-next tagged build with the published (stripped) artifact: a page with `position: fixed` bars at `top: 0` and `bottom: 0` shows both bars at the pane edges, in one pane and in two side-by-side panes (Chromium windows 880x629 and 440x629). Page window hierarchy: frame view and content view both at (0,0).
- Spike (`~/fun/cmux2-spike`, rebuilt with the new dist): two browsers, page corners now square, clip at the viewport edge unchanged. Evidence: `docs/spike-2026-09-29-band/` (not committed).
- Only the first patch (5364b925a) alone made it worse (the frame view itself moved to y=-31), which is how the constraint cause was found.

## First Chromium tab: main-thread cost (2026-09-29)

PR #15776 saw `pane split-right` miss the 2 s action deadline right after the first Chromium tab. Measured on `cefbnd` (old code): one 2592 ms main-thread stall (`debug.hangs`), sampled in `dlopen` of the Chromium framework (`cmux_shim_load` from `CEFRuntime.boot`, called synchronously from `makeTab`), and one pane action timed out.

Change: `CEFRuntime.start` is async. The shim and framework `dlopen` (`CEFRuntime.loadLibrary`, plain `dlopen`/`dlsym`) runs on a detached task; concurrent first tabs share it. Only the NSApp check, the pump and `CefInitialize` run on the main thread. `CEFEngine.makeTab` awaits the start, so the App keeps its existing "nil until ready" path and shows the tab at once. `CEFEngine.preload()` maps the framework early without starting CEF (not called by the App yet). Quit during the load marks CEF shut down, so it never initializes after quit starts.

New check `scripts/cmux-next/check-first-chromium.py <tag>`: opens the first Chromium tab of a fresh launch while 2 clients send 20 pane actions over about 1.5 s, and fails on a deadline miss or a stall over 50 ms. Results with the change (5 fresh launches): 0 deadline misses, max action latency 9-193 ms, and two remaining stalls per launch of 81-161 ms. The check still fails on those two.

The two remaining stalls are Chromium work that must run on the main thread: inside `CefInitialize` (`ScopedNativeScreen`/display enumeration, Perfetto tracing setup, profile keyed services) and the first `Browser` window (`CefNativeWidgetMac::CreateNSWindow`, `BrowserView::InitBrowser`, GPU channel setup). Removing them needs Chromium changes (for example, initializing CEF at app idle when a Chromium tab is likely) and is a decision for Lawrence, see the PR.

## Chromium warm start (2026-09-29)

Owner: `CmuxNextApp/ChromiumWarmup.swift` (architecture.md 5a, the one allowed exception).

- Launch + 3 s: `CEFEngine.preload()` maps the shim and framework on a background thread and primes ImageIO's plugin list there (the first Chromium window otherwise built it on the main thread, 70 ms measured). No Chromium code runs.
- `CefInitialize` runs early only when a Chromium tab is likely: a Chromium tab exists in any window (`MachineRegistry.hasChromiumTab`, so a restored tab in a background workspace counts), the "+" engine menu opens (`contextMenu(for: .newTabButton)`), or the palette selects or hovers `openBrowser.chromium` / `browser.openInChromium`. It waits for an idle moment: no key or mouse input to this app for 750 ms (a local event monitor installed only while waiting) and no menu tracking; it gives up after 60 s and stays lazy. Otherwise CEF stays lazy.
- `debug.cef` reports state (`idle`, `loading`, `loaded`, `ready`), `preloaded`, `likely`, `trigger` (`tab` or the warm reason), load and initialize times, and the app footprint.

Measured on tagged build `cefwrm` (Debug, pinned `cmux.3-band`), 3 fresh launches each:

| State | App footprint | App RSS | Helpers (footprint) |
| --- | --- | --- | --- |
| Launch, before preload (t=1.5 s) | 66-82 MB | 110-113 MiB | none |
| After preload (t=9.5 s) | 82-96 MB | 130-131 MiB | none |
| Warm init, no tab shown | 124-137 MB | 265-276 MiB | 83-86 MB (GPU, network, storage) |
| One Chromium tab open (cold) | 146-158 MB | 345-351 MiB | ~620 MiB RSS (adds renderer) |

So preload costs about +10-15 MB footprint (+20 MiB RSS, mostly file-backed), and a warm init costs about +40 MB in the app plus about 85 MB in three helpers.

`check-first-chromium.py` results:
- `--mode cold` (no Chromium tab likely): PASS 3/3, 0 deadline misses, two stalls each (97-112 ms `CefInitialize`, 76-87 ms window).
- `--mode warm` (restored Chromium tab in a background workspace): `CefInitialize` ran at idle 0.9-1 s after launch (75-100 ms), before any input. PASS 3/3 with one stall each (73-87 ms, the new Chromium window).

Finding: creating a Chromium window costs 70-90 ms on the main thread every time, not only the first time (a second pane's window measured 70 and 85 ms). The 5a exception therefore covers one stall per pane that gets its first Chromium tab. Removing it would need a spare pre-created Chromium window per profile (a hidden `Browser` with a blank tab that the next pane adopts), which costs a renderer process; not done.

TODO (decided 2026-09-29: not now, revisit after dogfood): spare Chromium window. Measured cost to remove: every pane that gets its first Chromium tab blocks the main thread 70-90 ms creating its Chromium window (first window per process 76-148 ms cold, 73-87 ms after a warm start; a second pane 70 and 85 ms). The fix is one hidden pre-created `Browser` per profile with a blank tab, created at idle and adopted by the next pane (navigate its tab, reparent the host view), then replaced at idle. Expected cost: one extra renderer process per profile while Chromium is running (not measured). Until then the 5a exception allows this stall once per new pane.

Not verified live: the "+" menu and palette triggers (Computer Use is not set up, and the palette does not open in a `CMUX_NEXT_NO_ACTIVATE` launch). The restored-tab trigger is verified.

## Chromium is the default engine (2026-09-29)

User decision: "we should default to chrome browser from now on." Owner: `CmuxNextApp/BrowserEngineResolver.swift` (pure), used by every path that creates a browser tab through `BrowserTabService.resolve`/`open`.

- `browser.defaultEngine` in cmux.json: `"chromium"` (default) or `"webkit"` (`CmuxNextSettings/BrowserDefaultEngine.swift`; a bad value keeps Chromium and reports a diagnostic). Palette actions `browser.defaultEngine.chromium` / `.webkit` ("Use Chromium/WebKit for New Browser Tabs", `cmux settings use-chromium-by-default`) apply at once and write the file.
- Resolution: an explicit engine wins (the `openBrowser` `engine` argument, New WebKit/Chromium Tab, compat `engine` param); an explicit Chromium request is refused with the reason when CEF cannot start. Else an inherited engine: Duplicate Tab, Reopen Closed Tab (the closed record now keeps its engine) and page requests (Cmd-click links, `target=_blank`, `window.open`) use the source tab's engine, because `window.opener` and cookies live in one engine. Else the default. Entry points that take the default: New Browser Tab (shortcut, palette, "+" menu), the strip's new-tab paths, Split Browser Right/Down, New Browser Workspace, Cmd-click on a URL in a terminal, `cmux browser open`/`open_split` and compat `surface.create --type browser`.
- Restored tabs keep their recorded engine. A Chromium record opens in WebKit at once (not a blank pane) when CEF is missing or fails to start; the record still says Chromium, so a build with CEF restores it as Chromium.
- Fallback, never silent: `ChromiumFallbackLog` records each Chromium-to-WebKit fallback with a typed `CEFUnavailableReason` (`notBundled`: fleet/CI builds without the artifact; `startFailed(message)`; `shutDown`). The first fallback page shown in the process gets one dismissible pill at the bottom of the page ("Chromium isn't in this build, so this tab uses WebKit."); later fallbacks are only counted. `debug.cef` reports `default_engine`, `unavailable {code, detail}` and `fallback {count, reason, source, notified}`.
- Page requests are now handled at all: before this change the App set no page delegate, so WebKit blocked every popup and Cmd-click link and CEF's adopted popups had no host. `BrowserPageRequests` opens them in the opener's pane (a popup page the engine already created is adopted into the new daemon tab) and closes the tab on `window.close()`.
- Warm start (architecture.md 5a): while Chromium is the default, any app-rendered browser tab in any window (either engine), the palette's default browser rows and switching the default to Chromium also count as "Chromium likely", so `CefInitialize` runs at idle before the next New Browser Tab. A session with no browser tab still never loads Chromium beyond the launch preload; the first New Browser Tab in such a session starts cold (two 5a stalls). Warming unconditionally at launch was rejected: it costs every user about +40 MB app footprint and about 85 MB in three helpers (table above) whether or not they browse.

## Chromium diagnostics

Debug builds of development bundles (`com.cmuxterm.app.debug.*`) read `CMUX_NEXT_CEF_EXTRA_SWITCHES`, a colon-separated list of Chromium switches (leading dashes optional), for example `enable-ui-devtools=9311` (Views tree over the DevTools protocol, `ws://127.0.0.1:9311/0`) or `show-browser-frame-regions`. Release builds ignore it (`#if DEBUG` in `CEFSwitches.current`).

## CEF shim ABI identity (2026-09-30)

The shim's ABI identity is the SHA-256 of its public header, `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/Shim/cmux_cef_shim.h`. There is no version number to bump. Before this, two parallel changes each raised `CMUX_CEF_SHIM_ABI` from 2 to 3 and then from 3 to 4 with different `cmux_shim_initialize` signatures; each rebase merged cleanly and kept one number, so a shim built from either header passed the check.

- Shim side: `scripts/cmux-next/build-cef-shim.sh` runs `shasum -a 256` on the header and compiles it in as `CMUX_CEF_SHIM_ABI_ID`; `cmux_shim_abi_id()` returns it. A compile without the define fails (`#error`).
- Swift side: the header is a SwiftPM resource of `CmuxNextBrowser` (resources must be inside the target, so the header lives there, not in `CEFShim/`). `CEFShimABI.bundledIdentity()` hashes the bundled copy with CryptoKit on the library-load thread (`CEFRuntime.loadLibrary`). `CEFShimLibrary.open` refuses a shim whose identity differs, or when either side has none (`LoadError.abiMismatch`).
- Any edit to the header changes the identity on both sides at build time; a merge of two edits gives a third identity. `CEFShimABITests` checks that the bundled copy is the source header and that the Swift hash equals the `shasum` derivation.
- Logs: `CEF ready ... shim_abi=<first 12 hex digits>`; `build-cef-shim.sh` prints the same prefix.
- The Swift function-pointer mirror in `CEFShimLibrary.swift` is still written by hand. The identity proves that the shim and the app were built from the same header; it does not prove that the mirror matches the header.

## Chromium DevTools in the pane (2026-09-29)

Bugs on `nxdog8`: opening DevTools changed the tab's URL, and DevTools never showed inside the pane.

Cause: CEF disables Chrome's own docking for CEF-managed Browsers (`chrome_browser_browser.patch`, `DevToolsWindow::Create`: `can_dock = false`), so every DevTools is a separate DevTools Browser made by `ChromeBrowserDelegate::CreateDevToolsBrowser`. When Chrome opened it (the page context menu's Inspect, `IDC_DEV_TOOLS_*`), CEF gave it the opener's client and window info: the shim's page client reported its `OnAfterCreated` as a new tab of the pane window (`adoptChromiumTab`) and its address and title as page events, and its window was a child of the page's own parent view. `ShowDevTools` with an empty window info and no client opened a separate client-less window.

Design (no fork change):
- Every DevTools path reaches `OnBeforeDevToolsPopup` of the page's client (shim `PrepareDevToolsPopup`). It emits `CMUX_SHIM_DEVTOOLS_WILL_OPEN`; `CEFTab.devToolsWillOpen` answers synchronously with `cmux_shim_devtools_set_placement`: a child of a new `CEFHostView` in the tab's content view (docked), or its own window. The DevTools browser gets a `DevToolsClient` that reports only `DEVTOOLS_OPENED/CLOSED` and key downs, so it never becomes a tab and never writes a URL or title (test `devToolsNeverWritesIntoTheTabRecord`).
- Docked layout: `CEFDevToolsLayout` (pure) splits `CEFTabContentView` into page, 1 pt divider and DevTools, bottom or right, with minimums (DevTools 120 pt, page 80 pt). The divider drags to resize; the page and DevTools windows punch an occlusion hole for its 7 pt grab area. Its right-click menu docks bottom or right, undocks into a window, or closes. The last dock side and sizes are remembered (user defaults). Bottom to right keeps the same DevTools; moving into or out of a window reopens it (a Chromium child window cannot become top-level).
- The DevTools window is a fork child window over its own parent view, so it clips, moves and hides with the pane like the page. This needs two fork fixes (fork API 4, release `cmux.5`): `f1d9ec948`/`62972542f` (a DevTools Browser with `parent_view` recursed `Activate -> SetFocus -> Activate` until the stack overflowed) and `360693901` (`OnPopupBrowserViewCreated` made a DevTools popup with `parent_view` a default top-level window on macOS). `CEFDevToolsSupport` docks only when `cmux_cef_api_version() >= 4`; older forks (`cmux.3-band`, `cmux.4-ext`) open DevTools in its own window. Debug builds of development bundles can force docking with `CMUX_NEXT_CEF_EMBEDDED_DEVTOOLS=1` (a local dist with the fixes at an older API).
- In its own window, Chrome style ignores `CefWindowInfo.bounds` and uses Chrome's saved DevTools window placement (first time: 640x640 at 100,100 of the main screen).
- Shortcuts (Chrome): Cmd-Opt-I toggles (`toggleBrowserDeveloperTools`), Cmd-Opt-J opens the Console (`showBrowserJavaScriptConsole`, was Cmd-Opt-C), Cmd-Opt-C picks an element (`inspectBrowserElement`, new; Chrome's `IDC_DEV_TOOLS_INSPECT`). Inside DevTools its pre-key hook runs only these three; content chords go to the DevTools frontend.
- Focus: `FocusState.Target.devTools` / `Resolved.devTools(pane, tab)`. Opening docked DevTools focuses it; a click in it (its child window becomes key) is `Responder.devTools`; closing it returns to the page; another pane and back returns to the page. Context is `browserFocused`, tier 2 content actions do not run in it, tiers 0 and 1 do (Ctrl-Tab switches tabs from DevTools too).

The dock-side items in DevTools' own three-dot menu route to the cmux dock layout (fork API 12, 2026-09-30): see "Extension UI and page background, fork API 11 and 12".

## Chrome extensions UI (2026-09-30)

Owner: `CmuxNextBrowser/UI/ExtensionActionToolbar.swift`, `ExtensionsMenu.swift`, `BrowserToolbarLayout.swift`; App wiring `CmuxNextApp/Handlers/ExtensionHandlers.swift`, `ExtensionMenuRouter.swift`.

- Toolbar: pinned action buttons (Chromium's icon at the button size, which already carries the badge) and an Extensions (puzzle) button that is always there on a Chromium tab. WebKit tabs show no Extensions button.
- Collapse as the pane narrows (`BrowserToolbarLayout`): pinned buttons move into the Extensions menu (last pinned first) while the omnibar would drop below its preferred width (tab max width); then the omnibar shrinks to its minimum (half of that); then Forward hides. Back, Reload, the omnibar and the Extensions button always stay. All chrome minimums are below the window's stay-put priority, so the chrome never widens a pane (`NarrowPaneChromeTests`).
- Popups anchor to the action's button, or to the Extensions button when the action has no button. Shortcuts, palette and CLI use the same anchor. A pane resize, tab switch or leaving the window closes the open popup.
- Extensions menu rows as in Chrome (click runs, pin toggle, "more" menu); footer Manage Extensions, Chrome Web Store, Load Unpacked. Menus opened for the CLI or debug socket run from a run-loop block (`presentExtensionsMenu`), never inside a main-queue job, so control calls keep working while a menu is open.
- Actions: `browser.extensions.menu|manage|webStore|loadUnpacked`, `browser.extension.run|options|pin|unpin|enable|disable|remove|command` (CLI `cmux extension ...`); no default shortcuts (Chrome has none). Debug verbs: `debug.extensions.toolbar|click|menu|popup`. Accessibility ids: `browser.extensions.button`, `browser.extension.action.<id>`, `browser.extensions.menu.row|pin|more.<id>`.

Fork line: `manaflow-ai/cef` `cmux/8037-ext` is the only integration branch (band + extension API + round + DevTools). One agent publishes releases and bumps `cef-manifest.json`; others send commits based on it. cmux.4-ext (API 3), cmux.5 (API 4), then API 5 (DevTools dock-side menu, `CMUX_DEVTOOLS_DOCK_SIDE`).

Verified on tagged build `extui` (dist cmux.5): widths 200/320/480/800/1400 pt (`debug.extensions.toolbar` fits, screenshots), popup anchored to its button and to the Extensions button, menu and per-extension menu, options page as a tab, `chrome.commands` via CLI, `chrome.contextMenus` item in the page menu, service worker, content script, badge, crash repro (popup then Chromium window close; quit with a popup open).

Open:
- Chrome Web Store install, permission prompts and side panels: done in fork API 12, see "Extension UI and page background, fork API 11 and 12".
- Popup latency: 16-45 ms from click to popup navigation in cmux; the rest is the extension renderer starting (1.0-1.2 s at load 200-400, up to 26 s at load 667 while Chromium builds ran). Not measured on an idle machine.

### External message pump (2026-09-30)

The pump is demand-driven (`CEFPumpSchedule`, `CEFMessagePump`). `OnScheduleMessagePumpWork(0)` runs `CefDoMessageLoopWork` on the next run loop pass. A delay arms the one timer for exactly that delay and replaces an earlier delayed request, but never postpones pending immediate work. Nothing runs after `stop()`. A timer fire inside a pass (a nested run loop) is deferred until the outer pass returns, and the timer is disarmed while a pass runs.

The pinned fork's `MessagePumpExternal` (libcef/browser/browser_message_loop.cc) has two gaps, so pure request-driven pumping loses work. It drops the next delayed-task time that `DoWork` returns, so a delayed task posted during a pass is not reported. It also stops after a 10 ms slice with work left, and Chromium's `WorkDeduplicator` then does not ask again. The pump therefore runs again at once after a pass that used the whole slice. After each pass it arms a finite chain of one-shot follow-ups (1/30, 2/30, 4/30, 8/30, 16/30 and 1 s), and then sleeps until CEF asks. A fork change that reports the next run time from `MessagePumpExternal::Run` makes the pump purely demand-driven (`SafetyNet.none`). That change shipped in cef-154.0.28-cmux.7 (fork API 7): with `cmux_cef_api_version() >= 7` the pump uses `SafetyNet.none` and wakes only when CEF asks (`CEFPumpSchedule.safetyNet(forkAPIVersion:)`).

Measured on tagged builds with one static Chromium tab, 60 s windows: the old pump made 28.8-31.4 wakeups/s at 0.58-1.33% app CPU. The new pump makes 0.0-0.9 wakeups/s after Chromium settles, and up to 2.7/s in the first minutes, at 0.02-0.27% app CPU. With CEF started and no browser, it makes 0.27 wakeups/s at 0.07% CPU. `debug.cef` `pump` reports the counters.

## Chrome extensions: end-to-end verification (2026-09-30)

"Every extension on the Chrome Web Store" cannot be tested: the store has more than 100,000. The coverage is two suites, run on a tagged Debug build with `scripts/cmux-next/ext-e2e.py api|store --tag <tag>`; `ext-e2e.py report` writes `plans/cmux-next/extensions-matrix.md`.

Latest results (tag `exte2e`: feat-cmux-next `b9ea95408bb` plus the suite, dist `cef-cmux-dist-ext6` = cmux.5 plus `02df91622`):
- API: 139 checks. 133 pass, 1 fail (side panel page never loads), 1 pending (permission prompt), 2 unverified (`action.openPopup` needs an active window), 2 unsupported on purpose (table below).
- Real extensions: 121 listed. 94 pass every check, 6 fail, 14 not checked (the harness timed out on this overloaded machine: popups that closed or answered too slowly, 3 launches where Chromium did not start in 90 s), 7 unavailable from the store. 45 extensions ran a second time after a timeout; the matrix uses the later run.

- **API matrix** (`scripts/cmux-next/ext-conformance/`): one MV3 and one MV2 test extension call 42 `chrome.*` namespaces (139 checks) and report to a local collector. The runner installs them, starts their API phase through CDP, then drives the UI through the debug socket: toolbar badge and title (`browser.extensions`), pin (`debug.extensions.menu`), popup by button click and `onClicked` with no popup (`debug.extensions.click`), popup user-gesture buttons (CDP input), the extension command (`debug.key`), the page menu item (`debug.cef.devtools` right click, `debug.menu`), DevTools panels. It also checks that `chrome.tabs` and the cmux tab list name the same pages.
- **Real extensions** (`scripts/cmux-next/ext-store/extensions.json`): 121 extensions (top Web Store extensions by users plus popular developer tools). Each is installed from the CRX the Web Store serves, unpacked with its public key (same id), and checked for load state, worker and manifest errors (`chrome.developerPrivate`), popup render (CDP screenshot) and one main-use check. No real account is signed in; a password manager passes when its popup renders its login or onboarding screen.

Harness rules and findings:
- Chromium loads `--load-extension` extensions into every profile, including CEF's root profile (`Chromium/Default`), which has no cmux windows. The runner picks targets by the `browserContextId` of the cmux tab. Production installs only reach `Profile-<uuid>`.
- The store's install button does not work in our Chromium ("Switch to Chrome to install extensions and themes"). The store suite therefore does not test the store UI; see the open decision in "Chrome extensions UI".
- This machine ran at load average 200-330 during the runs. Extension service workers run in background-priority renderer processes, so single API calls took 13 ms to 17 s. Timeouts are 30 s per check; latency numbers from these runs are not product numbers.
- Seven listed extensions are no longer served by the Web Store for Chrome 154, 130 or 120 (delisted MV2 or discontinued); they are recorded as unavailable. uBlock Origin (MV2) comes from its signed GitHub CRX (fork MV2 patch).

Fixes from this work:
- `chrome.downloads.download` always ended `USER_CANCELED`: CEF cancelled every download with no CEF browser. Fork commit `02df91622` (cef `cmux/8037-ext`) leaves extension downloads to Chrome's delegate. Verified with dist `cef-cmux-dist-ext6`; it ships in the next release after cmux.5.
- Ghost tabs (cmux kept tabs that Chromium had closed during adoption) and a crash when a page menu arrived for a tab view outside a window: found by this suite, fixed by the extensions UI owner (`fe71129542f`, `19b93582cec`).

### Extension APIs cmux does not support (on purpose, or not yet)

| API or feature | Behavior in cmux | Reason |
| --- | --- | --- |
| `chrome.identity.getAuthToken` | Rejects: "The user is not signed in." | Needs a Google account signed in to Chromium, which needs Google's restricted sign-in keys (options below). `launchWebAuthFlow` and `getRedirectURL` work. |
| `storage.sync` | Works, local only | No Google sync. |
| `storage.managed` | Returns `{}` | No enterprise policy. |
| `chrome.action.openPopup()` | Needs an active cmux window (Chrome rule) | Not verified: the test launches never activate. |
| Extension calls at startup before any Chromium tab | `tabs.create` and similar fail with "No current window" | Chromium has no window until cmux shows a Chromium tab (Chrome with zero windows behaves the same). |

### Gaps that remain

- `action.openPopup` and anything that needs the Chromium window to be active: unverified.
- Session Buddy opens its page with `chrome.windows.create`; the page does not become a cmux tab (the "no Chrome windows" work converts such windows to tabs, fork API 6).
- OneTab: a toolbar click opens nothing (its `action.onClicked` path returns early; `action.onClicked` itself passes in the API suite). Not diagnosed.
- New tab overrides: Momentum's shows on a new cmux tab; Infinity New Tab's still fails the suite's check (its New Tab target reports `chrome://newtab/`; not diagnosed).
- DuckDuckGo Privacy Essentials: blank popup. SelectorsHub: no DevTools panel. uBlock Origin (MV2, GitHub CRX): loads with no errors but did not block the test ad within 5 reloads (filter lists may still download on first run). Not diagnosed.
- The 14 "not checked" extensions need a run on a machine that is not overloaded.

### Decisions for Lawrence (extensions)

Decided 2026-09-30 and done (next section): Google Chrome's native messaging folders, `chrome://newtab` for new Chromium tabs, the omnibox keyword mode. Open: `identity.getAuthToken` (options in the next section).

## CEF artifacts in R2 (2026-09-30)

The pinned CEF tarballs are also in the private R2 bucket `cmux-cef` on the cmux Cloudflare account (the account that holds `cmux-binaries` and `cmux-ci-cache`). The bucket has no public access: its r2.dev URL is off and it has no custom domain. Its only lifecycle rule is Cloudflare's default "abort incomplete multipart uploads after 7 days"; no rule deletes objects. Keys are content-addressed, `cef/<sha256>/<asset name>`, and the manifest names them (`r2_bucket`, `r2_key`, `debug_r2_key`).

`scripts/cmux-next/ensure-cef.sh` tries, in order: the local cache, R2 through the S3 API with the read-only key, then the GitHub release (gh login, `GH_TOKEN`/`GITHUB_TOKEN`, public URL). Every source is checked against the manifest `sha256`; a mismatch or an R2 error falls through to the next source. The key comes from `CMUX_CEF_R2_ACCOUNT_ID`, `CMUX_CEF_R2_ACCESS_KEY_ID`, `CMUX_CEF_R2_SECRET_ACCESS_KEY` in the environment, else from `~/.secrets/cmux-cef.env` (`CMUX_CEF_R2_ENV_FILE` overrides the path). The script reads only those names from the file and never sources it. `CMUX_CEF_NO_R2=1` skips R2.

`scripts/cmux-next/publish-cef-r2.sh <tag> [--manifest scripts/cmux-next/cef-manifest.json]` mirrors a fork release: it fetches the `.tar.xz` assets with gh (checked against `SHA256SUMS`), uploads write-once, downloads each object again and checks its sha256, and can write the R2 fields into the manifest. It needs `CMUX_CEF_R2_WRITE_ACCESS_KEY_ID` and `CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY`; only the fork owner holds those.

### R2 API tokens

`~/.secrets/cmux-cef.env` (mode 600) holds, by name:

| Name | Scope |
| --- | --- |
| `CMUX_CEF_R2_ACCOUNT_ID` | account ID (not secret) |
| `CMUX_CEF_R2_ACCESS_KEY_ID`, `CMUX_CEF_R2_SECRET_ACCESS_KEY` | token `cmux-cef-read`: Object Read only, bucket `cmux-cef` only |
| `CMUX_CEF_R2_WRITE_ACCESS_KEY_ID`, `CMUX_CEF_R2_WRITE_SECRET_ACCESS_KEY` | token `cmux-cef-write`: Object Read and Write, bucket `cmux-cef` only |

No token on this Mac may create API tokens (2026-09-30: wrangler and cf OAuth have no R2 or token scopes; the account tokens in `~/.secrets` have R2 bucket rights but no "Account API Tokens" right). Create both tokens in the dashboard: R2, Manage API tokens, Create Account API token, permission "Object Read only" (then "Object Read & Write"), "Apply to specific buckets only" = `cmux-cef`, TTL forever. Put the Access Key ID and Secret Access Key into the file above.

### Steps for the coordinator (shared infrastructure, not done by the agent)

1. GitHub Actions, repository secrets on manaflow-ai/cmux: `CMUX_CEF_R2_ACCOUNT_ID`, `CMUX_CEF_R2_ACCESS_KEY_ID`, `CMUX_CEF_R2_SECRET_ACCESS_KEY` (the read-only values). Then add them next to `GH_TOKEN: ${{ secrets.CMUX_CEF_READ_TOKEN }}` in the "Build nightly app (Release)" step of `.github/workflows/nightly.yml` and the "Build universal app (Release)" step of `.github/workflows/release.yml`. `CMUX_CEF_READ_TOKEN` can stay as the fallback or be removed.
2. `ci-macos.yml` admission ("Decide whether admission embeds the Chromium engine") runs `ensure-cef.sh` with no token on purpose. To embed Chromium there, also pass the three R2 secrets to that step and to the compile step. Decide first: same-repo PR jobs would then receive a key that reads the private Chromium build (fork PRs get no secrets).
3. Fleet (cmux-ci controller builds): the worker passes its own environment to the recipe (build-fleet `cmd/worker/main.go` `buildEnv`, which blocks only controller/cache tokens), but sets `HOME` to the job directory, so `~/.secrets/cmux-cef.env` and `~/Library/Caches/cmux/cef` are not seen. Add to the `EnvironmentVariables` of each worker LaunchDaemon plist (the dev-build worker and `ai.manaflow.cmux-lent-worker`, installed by `build-fleet/mini-ops/lend-worker.sh`): the three read-only names, and `CMUX_CEF_CACHE_DIR=<persistent worker cache>/cef` so jobs reuse one verified copy (about 130 MB download, 700 MB extracted). Restart the workers. The recipe runs as `cmux`, so any submitted source can read the read-only key; it grants only object reads in `cmux-cef`.
4. Team Macs: copy only the three read-only lines into `~/.secrets/cmux-cef.env`, mode 600. Keep the write key on the fork owner's Mac only.

## Chromium never opens a window of its own (2026-09-30)

User decision: "we should NEVER open new chrome window with chrome UI"; every request that would open one becomes a cmux tab. Bug: the Chrome Web Store link on chrome://extensions opened a full Chromium window (tab strip, toolbar, "Sign in to Chromium") on the main display; reproduced on `nochw` with cmux.5. Cause: a renderer popup whose `OnBeforePopup` the client handles gets a Browser of its own (`ChromeBrowserDelegate::AddWebContents` -> `AddNewContents` with default `BrowserWindowCreateParams`, TYPE_NORMAL), and about 45 Chromium call sites create Browsers directly (`CreateBrowserWindow`, `GetOrCreateBrowser`, `ScopedTabbedBrowserDisplayer`, `chrome.windows.create`, `NewEmptyWindow`, session and tab restore, app launch).

Three layers, one decision (`CEFWindowPolicy.decide`, pure, `CEFWindowPolicyTests`):
- Fork API 8 (`cmux_window_guard.*`, `cmux_embedder_owns_windows.patch`, fork commit `954613d08`): `chrome::Navigate` sends NEW_WINDOW, NEW_POPUP and window-less navigations to the window `cmux_set_window_request_handler` returns, as a foreground tab; incognito opens nothing; `GetOrCreateBrowser` never creates a Browser; renderer popups join an embedder window as tabs (window.opener stays). A Browser Chromium still creates by itself (no embedder params, not DevTools or picture-in-picture) never shows (BrowserView Show/ShowInactive/Activate/Maximize/Restore), its tabs move to an embedder window and it closes (`CMUX_FOREIGN_BROWSER_BLOCKED`, `cmux_foreign_browser_count`).
- Shim (any fork): popups get no window info; `OnChromeCommand` blocks commands that open a window (New Window, New Incognito Window, Task Manager, feedback, guest profile, Move Tab to New Window, app windows) and reports them; the page context menu drops "Open Link in New Window / Incognito Window / as profile / in app / in split view"; AFTER_CREATED carries the opener's disposition and window features (`GetOpenerIdentifier`).
- App (any fork): the runtime answers window requests (source tab's pane, else the last shown pane, same profile only; none: a new cmux tab through `CEFEngine.openURLWithoutWindow`; incognito: a notice on the tab, which is now an occlusion rect so it shows over Chromium pages). With API 8, tabs Chromium creates outside a pane window wait for the fork to insert them (`unplaced`, adopted on CMUX_TAB_INSERTED); older forks keep moving them into the last shown pane. `ChromiumWindowGuard` is the last resort: a visible titled top-level Chromium window (not a child, not floating, not undocked DevTools) is hidden (Browser windows) or closed (dialogs) when it becomes key, main or visible, and counted.
- Diagnostics: `debug.cef` `windows` (`chromium_windows` must be empty, `guard_blocked`, `fork_foreign_browsers`, `requests`, `blocked_commands`). Live check: `scripts/cmux-next/check-no-chrome-windows.py <tag>`.

Popups (2026-09-30, user decision "Floating panel for sized popups"): a `.popup` (window.open with window features, OAuth and payment sign-in) opens in a floating cmux panel over the opener's window (`CmuxNextApp/Popups`). The popup gets a popup host of its own: when the panel first shows it, the host creates its Chromium window with an about:blank placeholder, moves the popup in (`cmux_tab_move_to_window` keeps the WebContents, so `window.opener` and `postMessage` work) and closes the placeholder. Popup hosts are never window-request candidates. A position the page did not give is not used (the fork's request always carries x and y; the renderer's OnBeforePopup features decide). A page opened by a page uses Chromium's white default at once (`PageBackground.startsWithTheme`). `debug.popups` lists open panels. Still open: `chrome.windows.create({type:'popup'})` reaches the panel, but the extension's window id dies when the fork evicts the foreign popup Browser; fork API 11 (keep the popup Browser, `cmux_popup_window_attach`) shipped in cef-154.0.28-cmux.10; the app does not enable or attach it yet.

## Incognito windows (2026-09-30)

User decision: "open incognito window. not workspace. cannot mix incognito window with non incognito ones." Owners: `CmuxNextBrowser/Core/OffTheRecordProfiles.swift`, `CmuxNextApp/Windows/WindowManager+Incognito.swift`, `WindowRegistry` (window kinds).

- One incognito session serves every incognito window: a random browser profile id that every engine treats as off the record. Chromium: the shim creates the request context with an empty cache path (key `cmux-otr:<uuid>`), which Chrome style turns into a unique in-memory profile (`OTRProfileID::CreateUniqueForCEF`, parent: the root `Default` profile), released when the session ends. WebKit: a non-persistent data store. Site permissions and omnibar history stay in memory.
- The daemon never sees an incognito tab's URL, title or favicon: it gets an about:blank placeholder record; the app keeps the start URL in memory and the strip shows the live page.
- Window requests resolve the store of the source tab, so tabs and popups of an incognito page stay in its window; a request from a store cmux cannot name is refused, never opened as a normal tab. Chromium's incognito requests (Open Link in Incognito Window, New Incognito Window) open a cmux incognito window.
- The Chromium profile of a CEF unique off-the-record context is `kOtherOffTheRecordProfile`, not `IsIncognitoProfile`, so the fork's window guard treats it like a normal profile (it refuses only true incognito requests).

Extensions in incognito: not supported, and "Allow in Incognito" is not offered. Chrome runs an extension in an incognito window only through the incognito profile's original profile (`ExtensionsBrowserClient::GetContextRedirectedToOriginal`, `util::IsIncognitoEnabled`). CEF makes every unique off-the-record context a child of the root `Default` profile (`ChromeBrowserContext::ProfileCreated`, `GetPrimaryUserProfile()`), while cmux installs extensions into `Profile-<uuid>`. The per-extension setting would therefore have no extensions to enable. It needs a fork change: create the off-the-record context as a child of a given profile (for example a `cmux_request_context_create_off_the_record(parent_cache_path)` that calls `GetOffTheRecordProfile(OTRProfileID::CreateUniqueForCEF())` on that profile), then the existing Chrome setting (`extensions::util::SetIsIncognitoEnabled`) can be exposed per extension in the Extensions menu.

## WebKit Web Inspector attached in the pane (2026-09-30)

Bug: the attached WebKit inspector flickered in and out on every frame. Cause: `BrowserChromeView` pinned the `WKWebView` to its content container with Auto Layout, and WebKit's attached inspector (WebInspectorUIProxyMac) adds its view to the web view's superview, sets the web view's frame to the area left, and applies that again on every web view frame change. Each layout pass reset the web view to full size and WebKit shrank it back: 2 frame changes per idle layout pass (`WebKitInspectorLayoutTests`, with a stand-in for WebKit's attach path).

Fix: `WebKitTab.contentView` is a tab-owned `WebKitPageContainer`. The chrome pins the container; the web view inside uses autoresizing only, and nothing sets its frame after it is added. WebKit's attach path is the one owner while attached: its own dock buttons (bottom, right, separate window) and its own resize edge. A container resize reaches the web view once through autoresizing; WebKit then re-places both views. `debug.webkit_inspector` (DEBUG) counts frame changes of the web view and its siblings since `{"action":"start"}`.

Decision for Lawrence: the WebKit inspector does not use the cmux DevTools dock model (divider, divider menu) that Chromium tabs use. WebKit re-places the web view on every web view frame change, so a second owner cannot be stable without private WebKit hooks. The WebKit inspector keeps Safari's own dock controls.

## Extension UI and page background, fork API 11 and 12 (2026-09-30)

Release `cef-154.0.28-cmux.10` (fork `cmux/8037-ext` at `1589e83b7`, `CMUX_CEF_API_VERSION 12`), pinned in `scripts/cmux-next/cef-manifest.json`. Every item was checked live on tagged build `brw2` in a no-activate launch; `debug.focus` stayed inactive with no key window after each step.

- **Page background.** Chromium 154's `ContentsWebView::UpdateBackgroundColor` makes the page widget transparent when CEF hides the view's background (CEF does, so that its own color wins). Documents without a background and the page before its first paint then showed the Chrome window's #292929, and neither `CefSettings.background_color` nor DevTools' `Emulation.setDefaultBackgroundColorOverride` changed it. The fork now paints the embedder color on the view layer and the widget. Coordinator decision (2026-09-30, after cmux.10 landed): white default wins for both engines. The theme color shows only before a tab's first real page; `CEFTab` then switches the tab once to white with `cmux_browser_set_background_color` (popups and target=_blank tabs at adoption), and a theme change repaints only tabs still on the theme color (`18c41c84207`).
- **New Tab page.** A new Chromium tab opens `chrome://newtab/` (`BrowserNewTabPage`, `BrowserEngineChoice.newTabURL`); WebKit tabs keep `about:blank`. Chrome's order holds: an extension override (Momentum) wins; without one the fork loads `cmux_set_new_tab_page_url` (`about:blank`, painted in the theme color), never Google's page. The shim reports `chrome://newtab/` as the address and an empty title, so the omnibar stays empty and focused and the tab reads "New Tab". Chrome's footer on extension New Tab pages (extension name, customize button) is Chromium's and still shows.
- **Web Store install.** The store's own "Add to Chrome" button works: `chrome.webstorePrivate` is compiled in and exposed to the store origin, and our UA and client hints are Chrome's (brand "Chromium"). What the store checks: the "Switch to Chrome" banner comes from a server flag (`IJ_values[24]`) that is true only when the page request carries Google Chrome's private `x-browser-copyright` and `x-browser-year` headers; the client code also wants `chrome.management` and `webstorePrivate.beginInstallWithManifest3`. The flag controls only the banner; the button runs `beginInstallWithManifest3` without it. cmux sends no Google headers and no "Google Chrome" brand. The install confirmation is a cmux sheet (next item); after install the tab shows a notice instead of Chrome's toolbar bubble. The CRX installer of the store suite stays as a fallback.
- **Install and permission prompts.** Every `ExtensionInstallPrompt` (store install, `chrome.permissions.request`, re-enable, repair) goes to `cmux_set_install_prompt_handler`; `ExtensionPromptSheet` shows a native sheet on the asking tab's window (icon, title, what the extension can do, two buttons) and replies once. `debug.extensions.prompt` lists and answers prompts for tests.
- **Omnibox keyword mode.** `OmnibarState.keyword`: the keyword and a space (or Tab after the exact keyword) start a session; the field holds the text after the keyword, the chip shows the extension name, every change goes to `onInputChanged` and the extension's rows (after a default row) show in the card. Enter or a row click sends `onInputEntered` (current tab, or new tab with Cmd/Option), Backspace at the start restores the keyword text, Escape and blur send `onInputCancelled`. Tests: `OmnibarKeywordTests`.
- **Native messaging.** Host manifests are searched in this order: cmux's Chromium user data folder `NativeMessagingHosts`, `/Library/Application Support/Chromium/NativeMessagingHosts`, then `~/Library/Application Support/Google/Chrome/NativeMessagingHosts` and `/Library/Google/Chrome/NativeMessagingHosts` (`CEFNativeMessaging`, fork `cmux_add_native_messaging_dir`). User-level folders are skipped when policy forbids user-level hosts. Each host still lists the extension ids it allows. Not checked with the real 1Password or Bitwarden desktop apps (not installed here).
- **Side panel.** `chrome.sidePanel` shows Chromium's own side panel inside the page's Chromium window, so it docks in the pane beside the page (action click with `openPanelOnActionClick`, `sidePanel.open` with a tab or window). Its header (name, pin, close) is Chromium's. It took the app active in a no-activate launch; the fork now never lets an embedded page window activate the app by itself (`CefNSWindow -activationIndependence`), clicks still activate it. The conformance check `sidePanel.page_loaded` still fails in the suite although the page loads by hand; not diagnosed.
- **DevTools dock menu.** The three-dot menu's dock items report through `CMUX_DEVTOOLS_DOCK_SIDE`; the frontend gets `cmux_dock=true` and always lays out undocked, so it never draws an empty page area. The separate-window choice uses a cmux panel (`CEFDevToolsWindow`) that takes the same `CEFHostView`: bottom, right, left and window all keep the same DevTools (checked: a value set in the frontend survived bottom, window and back to right). DevTools opens in the pane first and moves to the window after it exists (Chromium creates it synchronously only there).
- **Popup windows (API 11, requested by the popup panel work).** `chrome.windows.create({type: "popup"})` can stay hidden with its window id and size until cmux attaches it (`cmux_set_popup_windows_enabled`, `CMUX_POPUP_WINDOW_CREATED`, `cmux_popup_window_bounds`, `cmux_popup_window_attach`). The shim exposes the calls; cmux does not enable it yet, so the window guard still moves such tabs into the pane window. The attach path is not verified.

`chrome.identity.getAuthToken` (research, no credentials registered): Chromium mints the token through the private Gaia `issuetoken` endpoint for the primary signed-in account (`identity_get_auth_token_function.cc`), which needs Google's OAuth client ID and secret; since 2021-03-15 Google blocks sign-in for third-party Chromium builds, and there is no public way to get keys that work. Edge, Vivaldi, Opera and Arc fail too. Options: (a) keep it unsupported (no cost); (b) Brave's fallback, an implicit OAuth web flow with the extension's `oauth2.client_id` (small fork change, MPL code as a model) that fails for extension OAuth clients made after 2023-10-02 ("Custom URI scheme is not supported on Chrome apps") and that Google can break at any time; (c) Google sign-in: not available without a Google contact.

Suite results on the final build (`brw2`, release `cmux.10`): API 141 checks, 135 pass, 3 fail (`windows.create_mapped` and `windows.create_popup_mapped`: the harness did not see the moved tab in the cmux snapshot within 3 s; `sidePanel.page_loaded`, above), 2 unverified (`action.openPopup` needs an active window), 1 unsupported (`identity.getAuthToken`). Store subset (7 extensions): the store's own install flow was checked by hand (Dark Reader); in the suite the first popup of each app launch did not open (Dark Reader, Infinity, uBlock Origin) while later popups did, and the same Dark Reader popup opens by hand; not diagnosed. `check-no-chrome-windows.py`: pass.

