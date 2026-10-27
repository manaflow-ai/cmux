# Chromium's browser process in a helper app

Status: design and prototype (PL-cef-helper, 2026-10-23). Lawrence approved the move (2026-10-23), after layer
hosting. Fault F2 in [perf-lead.md](perf-lead.md). Builds on [cef-layer-hosting-DESIGN.md](cef-layer-hosting-DESIGN.md)
(PL-cef-layer; fork API 26/27) and replaces the study in [cef-out-of-process.md](cef-out-of-process.md) (option B) and
the "not now" in [browser-isolation.md](browser-isolation.md). Paths: `S/` = `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/CEF/`,
`A/` = `Packages/macOS/CmuxNext/Sources/CmuxNextApp/`, `shim/` = `Packages/macOS/CmuxNext/CEFShim/src/`,
`fork:` = `~/fun/cef-cmux-worktrees/layer-host` (branch `cmux/8037-cmux34-hosted-switch`).

## 1. Goal

1. A Chromium CHECK, NOTREACHED, out-of-memory abort or memory fault in the browser process ends only that process.
   cmux, its windows, terminals and agent panes keep running. Pages come back with a reload of the saved session.
2. Chromium's message pump never runs on cmux's main thread, so it never delays an input event or a frame of cmux.

## 2. Today (in process)

| Part | Where | Cost or risk |
|---|---|---|
| Browser process = the cmux app. `cmux_shim_initialize` calls `CefInitialize` with `external_message_pump` on cmux's main thread | `shim/shim_process.mm:426-473`, `S/CEFRuntime.swift:355-431` | every static initializer, allocator change and CHECK of a 600 MB framework runs in cmux (the "No zone found" race needed `CmuxNextMallocZone`, browser-isolation.md) |
| Pump: `OnScheduleMessagePumpWork` arms one main-run-loop timer; each fire runs `CefDoMessageLoopWork` on cmux's main thread | `S/CEFMessagePump.swift`, `S/CEFPumpSchedule.swift` | pump passes of 10 ms and more (perf-lead F2); the fork's time slice (`cmux-pump-time-slice-us=2000`, `S/CEFSwitches.swift:51-56`) cuts a pass, it does not remove the work from the main thread |
| `CmuxApplication` is Chromium's `NSApp` (`CefAppProtocol`) | `A/CmuxApplication.swift:35-107` | Chromium's `sendEvent` scoping runs in cmux's event dispatch |
| Pages: a child `NSWindow` per page (fork `CmuxParentViewTracker`), or with fork API 26 the page's `DisplayCALayerTree` in a tracker-owned `CAContext` that cmux shows with a `CALayerHost` | `fork:libcef/browser/chrome/views/chrome_child_window_mac.mm:961-1006`, `S/CEFLayerHosting.swift`, `S/CEFHostedPageView.swift` | the context is made on `CGSMainConnectionID()` and the app gets only its id: this part already works across processes |
| Shim ABI: 132 C exports, one event callback, 4 synchronous callbacks (key with an `NSEvent*`, focus request, window request, DevTools key), `NSView*` arguments (`create_window`, `devtools_set_placement`, `popup_window_attach`) | `S/Shim/cmux_cef_shim.h` | pointers and synchronous answers cannot cross a process |
| Chromium's own UI (bubbles, `<select>`, autofill, JS dialogs, HTTP auth, file pickers, print preview, extension popups, DevTools windows, WebAuthn sheets) | Views widgets of the browser process | they are `NSWindow`s of the browser process |
| Chromium's own main-thread blocking at launch and quit (blocking probe, PL-threading item 1 slice c, step 6ebef007, cmux20-bench, macOS 27.0, Debug at 91f2976c551; launch, settle and quit, no actions): `ChromeWebAppShortcutCopierMain` 23.2 ms (5120 `stat`/`access`/`fcntl` calls, longest 11.4 ms), `CefShutdown` 22.7 ms at quit (`waitpid`, `usleep`, longest 10.1 ms) | Chromium's browser-process code on cmux's main thread | host-process work: it leaves cmux's main thread with the browser process (no in-process change, lead 2026-10-25); the host must not add a synchronous wait on it at quit |
| Chromium's child-process waits in the pump (the same probe, step 6ebef007): 32 `waitpid` calls, 19.3 ms of the 20.1 ms the probe gave the pump closure in `CEFRuntime.initialize` (`cmux_shim_do_work` -> `CefDoMessageLoopWork`), inside Chromium's own code (no symbols: the child is not named) | `CefDoMessageLoopWork` on cmux's main thread, today | one more measured reason for the host move: the pump's work, waits included, leaves cmux's main thread with the browser process |

## 3. Design

### 3.1 Processes

```
cmux (app)                          <App> Chromium Host.app (new)              Chromium helpers (as today)
  UI, layout, key router,             Chromium browser process                 Renderer, GPU, Utility, Plugin, Alerts
  tab model, omnibar, prompts,        CefInitialize + CefRunMessageLoop         children of the host
  CALayerHost per page        <-wire-> on ITS main thread                       sandboxed (helper_main.mm)
  supervisor (restart, restore)       page windows: input-less, no pixels
```

- The host is a small app in `Contents/Frameworks/<Product> Chromium Host.app` with `LSUIElement`, its own bundle id
  (`<app id>.chromium-host`) and `NSPrincipalClass ChromiumHostApplication` (the `CefAppProtocol` app). It loads the
  app's CEF framework from `Contents/Frameworks` with `cef_load_library` while it has one thread, so no zone race.
  It uses the same five helper apps as today (`browser_subprocess_path`). Prototype: `shim/browser_host_main.mm`,
  bundled by `scripts/cmux-next/embed-cef.sh` (Debug only).
- cmux no longer maps the framework. The shim becomes a client library of the wire (Swift, no CEF).
- One host for every profile, as Chrome has one browser process. A host crash then reloads every Chromium page. One
  host per profile would contain a crash to that profile for about 60-90 MB more per profile (decision below).
- Signing: hardened runtime, no JIT entitlement (the browser process does not JIT; Renderer and GPU keep `allow-jit`,
  `scripts/cmux-next/sign-cef.sh`). Sandbox: none for the browser process, as Chrome and today. Release signing
  (`scripts/sign-cmux-bundle.sh`) signs the host with `sign-cef.sh`.
- Keychain: Chromium's "Chromium Safe Storage" item encrypts cookies and passwords. Its ACL names the cmux app today.
  The host is another code identity, so release builds must give the host the same keychain access group or migrate
  the item once (open item). Dev builds use the mock keychain (`CEFSwitches.useMockKeychain`).

### 3.2 Lifecycle

- Start: on the first Chromium tab, as `CEFRuntime.start` today, cmux spawns the host (`posix_spawn`, wire on fd 3,
  `POSIX_SPAWN_CLOEXEC_DEFAULT`; prototype `S/ChromiumHost/ChromiumHostLauncher.swift`). `CefInitialize` runs in the
  host, off cmux's launch path. The host sends `ready` (fork API, pid).
- Quit: cmux sends `quit`; the host closes its browsers, `CefShutdown`s and exits. cmux does not wait for it longer than
  its quit deadline. If cmux dies, the host reads EOF on the wire and quits (prototype: `ReadWire` -> `CloseHost`).
- Crash: a thread blocked in `waitid(WEXITED | WNOWAIT)` reports the exit with its signal (SIGTRAP is a CHECK). The supervisor
  (prototype: `ChromiumHostSession`) clears every page's context (no stale pixels), restarts the host and reloads each
  page from the saved session: today's `cmux_shim_tab_navigation_state` / `tab_restore_navigation` (fork v7) per tab,
  which `BrowserHistory` already saves on every commit (`S/CEFTab+RestoredHistory.swift`). The app's safe-restart rule
  applies (`ChromiumHostRestartPolicy`): a host that ends again within 60 s stays ended; pages show "Reload".
- The exit is read with `waitid(WNOWAIT)`: the host's pid stays a zombie until the supervisor reaps it, so a SIGKILL
  that cmux sends to a broken host (a bad frame, a flood, a full send buffer) can never reach a reused pid.

### 3.3 The wire

Two channels per host:

1. **Input and geometry: two stream socket pairs (one per direction), fixed 64-byte frames** (`shim/chromium_host_wire.h`,
   `S/ChromiumHost/ChromiumHostFrame.swift`, one golden frame tested on both sides). cmux writes non-blocking from the
   main thread (one `write` on an `O_NONBLOCK` descriptor, a few us) and reads on a thread of its own, blocking on the
   other pair (macOS ignores `MSG_DONTWAIT` on Unix sockets, and file status flags are shared by every descriptor of
   a socket, so one socket cannot be both); the host reads on a thread of its own and posts each frame to its UI thread.
   Bounded both ways (256 KB send buffer, 4,096 frames backlog); an overflow ends the host, never blocks cmux.
2. **Control: XPC over an anonymous listener endpoint** sent on channel 1 at start (production, not in the
   prototype). It carries what needs Mach ports or replies: CA fence ports for resize sync, file and folder access,
   request/response calls (navigation entries, extension actions, prefs, site settings: today's 9 string-returning
   and about 30 data-returning shim calls become async replies, the pattern `CMUX_SHIM_REPLY` already uses).

What crosses, and how:

| Item | Today | Helper design | Fork patch |
|---|---|---|---|
| Pixels | context id (API 26) | the same id from the host; cmux hosts it (`CEFHostedPageView.layerHost`). Nothing crosses per frame: the WindowServer composes the GPU process's context inside the host's context inside cmux's tree | no |
| Geometry, resize | fork tracker observes cmux's `NSView` chain and reads `-cmuxClipPath`, `-cmuxOcclusionRects` synchronously | cmux sends the page rect per changed frame (64 B); clip and occlusion are cmux's own layers (the hosted page is in cmux's tree), so the host needs no clip | yes: hosted page window off screen and never ordered in (no WindowServer surface, no `setFrame` per frame in a visible window); today the host's page window still follows the pane |
| Resize sync (API 27) | `CATransactionCoordinator` holds cmux's commit in one process | cmux creates a CA fence port per resize transaction and sends it over XPC; the host's commit of the new size joins it (`-[CAContext setFencePort:]`, the remote_cocoa pattern) | yes: fence-port variant of `cmux_browser_set_resize_sync` |
| Mouse, wheel, hover | WindowServer routes to the page window | cmux's page view (`ChromiumHostPageView`) gets the events and forwards them (`SendMouse*Event`) | no (prototype works on stock windowed CEF) |
| Keys | `OnPreKeyEvent` calls cmux's `KeyRouter` synchronously with an `NSEvent*` (`S/CEFRuntime+Events.swift:29-41,152`) | cmux's `KeyRouter` already runs first in `CmuxApplication.sendEvent` (`A/CmuxApplication.swift:107`); keys it does not take go to the host (`SendKeyEvent`), the page's unhandled keys come back as today's `KEY_UNHANDLED` event, async | no for keys; text input below |
| IME, dead keys, emoji, dictation | `RenderWidgetHostViewCocoa` in the page window is the `NSTextInputClient` | cmux's page view implements `NSTextInputClient`; marked text and commits go to the host (`ImeSetComposition`, `ImeCommitText`); the host pushes the composition range and caret rects after each change, so `firstRectForCharacterRange` answers locally | yes: windowed `Ime*` are `DCHECK(false)` (`fork:libcef/browser/browser_platform_delegate.cc:411-432`). PL-cef-layer: the fork's remote-presentation path (API 19, `cmux_rp_*`) already has Chrome-style IME; the host can reuse it instead of patching the windowed path |
| Page screenshots for agents | `Page.captureScreenshot` over DevTools, answered on cmux's main thread | the host runs the capture (fork API `cmux_browser_capture`, planned by PL-cef-layer for cmux.34: `CopyFromSurface` readback, encode on Chromium's thread pool, callback off main) and sends the PNG over the control channel; cmux's main thread never waits | planned (PL-cef-layer) |
| Focus, key and active state | page window is key; fork "active while the parent is key" | cmux's view is first responder and sends focus; the host's windows are never key | yes: `cmux_browser_set_embedder_active(id, bool)` replaces the key-window observers |
| Cursor | Chromium's view sets it in its own window | `CefDisplayHandler::OnCursorChange` -> wire -> cmux sets the cursor over its view | no |
| Accessibility | page window's AX tree; `CmuxApplication` maps the window (`A/CmuxApplication.swift:153`) | the host gives the page's remote AX token (`NSAccessibilityRemoteUIElement`, the app-shim mechanism); cmux's page view returns a remote element child with it | yes: export the token |
| Context menus | `CONTEXT_MENU` JSON + token, cmux's `NSMenu` (`shim/shim_client.mm:365-409`) | unchanged, over the wire | no |
| `<select>`, autofill and password dropdowns, permission bubbles, extension action menu | Chromium Views widgets or its `NSMenu` in the browser process | the cmux path context menus use: Chromium asks, cmux draws, cmux answers by token. Permission prompts: `CefPermissionHandler::OnShowPermissionPrompt` (CEF API, no patch) | yes for `<select>`, autofill and passwords |
| JS dialogs, HTTP auth, file pickers | Chromium's own | `CefJSDialogHandler`, `CefRequestHandler::GetAuthCredentials`, `CefDialogHandler::OnFileDialog`: cmux shows its own sheet or `NSOpenPanel` and answers | no |
| Extension popups, popup windows (API 13), side panel, DevTools (docked and undocked), print preview | Views widgets with a WebContents | each is a page window like a tab: layer hosted by context id in a cmux view or panel, input forwarded | yes: layer hosting for any widget id (today per browser id) |
| Drag and drop in | `CEFFileDragRelay` (DevTools `Input.dispatchDragEvent`) | unchanged over the control channel, or `DragTargetDrag*` | `DragTarget*` are `DCHECK(false)` in windowed mode (`browser_platform_delegate.cc:434-453`) |
| Drag out | Chromium's drag session in its window | the host sends the drag data; cmux starts the `NSDraggingSession` and reports the end | yes: `StartDragging` to the embedder (OSR-only today) |
| Downloads | `DOWNLOAD_*` events + `download_continue` tokens | unchanged | no |
| Passkeys, WebAuthn | Chromium's tab-modal dialog + `ASAuthorizationController` in the browser process (cmux app entitlement) | the platform authenticator request goes to cmux, which runs `ASAuthorizationController` with its own entitlement and window and answers; Chromium's own dialogs follow the bubble row | yes: an embedder delegate for `device/fido/mac` iCloud Keychain |
| Printing | Chromium print preview | `PrintToPDF` in the host, `NSPrintOperation` of the PDF in cmux | no |
| Find, zoom, navigation, DevTools protocol calls | shim calls | the same calls as async frames or XPC requests | no |
| Window requests, focus requests (synchronous callbacks) | `window_request_fn` inside a navigation, `focus_request_fn` | the host decides with a policy cmux pushes (for example "a new window becomes a tab of the opener's window", "page X may take focus") and reports the result | no |

### 3.4 What stays in cmux

Tab model, tab strip, omnibar, toolbar, history database, bookmarks, Downloads UI, context menus, every prompt, link
hints (their script goes over the DevTools protocol channel), browser automation (CDP over the control channel, or the
daemon talks CDP to the host through `--remote-debugging-pipe`), crash reports (`debug.crashes`).

### 3.5 Cost

| | In process (today) | Helper |
|---|---|---|
| cmux main thread per Chromium task | every pump pass (`CefDoMessageLoopWork`), 10 ms+ passes measured | none |
| cmux main thread per input event | the event + Chromium's synchronous pre-key callback | one 64-byte non-blocking write (measured below) |
| Input event to Chromium's UI thread | same thread, waits for the run loop | one socket hop + `CefPostTask` (measured below) |
| Per frame | nothing crosses | nothing crosses (contexts compose in the WindowServer) |
| Per moved page per motion frame | tracker `setFrame` of the page window (WindowServer round trip) | one geometry frame; the host's off-screen window (fork patch) |
| Memory | browser process inside cmux (~40 MB footprint when CEF starts, browser.md) | the same in the host, plus a process baseline (measured below); cmux maps no framework |
| A browser-process CHECK | ends cmux | ends the host; pages reload |
| Idle main-thread wakes, app hidden | 27-107 per s (perf-lead F5); cmux-4f's lead: most of them are CEF pump passes for Chromium UI-thread tasks of each renderer (`bench_idle.py --scenarios app-hidden`, result pending) | the pump wakes the host's main thread, not cmux's |

### 3.6 Risks

- `CALayerHost`, `CAContext` and remote AX tokens are SPI (as today; Chromium uses them in every Chrome).
- Two code identities: keychain ACLs, TCC (camera, microphone, screen recording: the host asks, with its own name),
  passkey entitlements. Each needs a release check.
- An accessory app that shows a window can become active; every host window must stay non-activating and off screen.

### 3.7 Why page focus must not make a page window key (fork API 30, issue #24913)

Today `CEFTab.grantFocus` calls `CefBrowserHost::SetFocus(true)`, and the fork makes the page's child window key
(`makeKeyAndOrderFront:`). Every key-window change runs AppKit's key-state walk over both windows' view trees and,
for a text-input first responder, activates the input method synchronously. The fuzzer found three 10 s main-thread
stalls in that one call (DEV watchdog traps):

- macOS 14.8.7 and 15.7.7 (seed 21, Hang B/C): `-[NSWindow makeKeyWindow]` > `_windowChangedKeyState` (about 20
  view levels; the window holds every parked workspace's view tree, hidden) and KVO in `-[NSApplication _setKeyWindow:]`.
- macOS 26.6.2 (seed 21, build of 0aeef9f4827, 2026-10-25): `SidebarNavigation.step` > `FocusEffectApplier.focusPage`
  > `CEFTab.grantFocus` > `cmux_shim_set_focus` > CEF > `-[NSWindow makeKeyAndOrderFront:]` > `becomeKeyWindow` >
  `NSAutoFillHeuristicController _windowDidBecomeKey:` > `-[NSTextInputContext activate]` > `IMKInputSession activate`
  > `invocationAwaitXPCReply` (a nested run loop that waits for the input method server; the VM's server had stopped
  answering 10 min before). A real Mac whose input method server hangs gets the same wait.

cmux now makes at most one key change per focus request (1da8789d016: no reclaim into the cmux window first, none
when the cmux window is key, no select from building a tab menu). The one change that remains is the grant itself.
With `cmux_browser_set_embedder_active(id, bool)` (fork API 30) page focus becomes cmux's own first responder plus
an active flag: no page window is ever key, so neither the key-state walk nor the input method activation of a key
change runs for a page focus. That needs the pin past API 24 (this design's host work needs 27). DevTools focus
emulation in process is not a substitute: the page view then has no text input client, so IME breaks.

## 4. Prototype (behind `browserHost.helperPrototype`, default off; the host app is in Debug builds only)

- Host: `shim/browser_host_main.mm` (built by `scripts/cmux-next/build-cef-shim.sh` as `cmux-chromium-host`, bundled by
  `embed-cef.sh` as `<Product> Chromium Host.app`, Debug only, signed by `sign-cef.sh`). One Chrome-style page per host.
  Its parent view sits in a transparent, click-through, floating window of the host at the pane's screen rect; its
  `-cmuxOcclusionRects` covers the page, so the fork's tracker never lets the page window take the mouse. It calls
  `cmux_browser_set_layer_hosting` (API 26) and sends the context id. It refuses forks below API 26.
  The host window must stay ordered in and visible: the fork's tracker hides the page when its parent window is not
  visible, and observes the parent's occlusion state (a covered window throttles the renderer), so the prototype puts
  it at the floating level, click-through, with no pixels. The page window is an `addChildWindow` child of the host's
  window, never of cmux's. It is never key (the host is not the active app), so keys reach the page only through
  forwarding (PL-cef-layer, 2026-10-23).
- cmux: `S/ChromiumHost/` (`ChromiumHostFrame`, `ChromiumHostConnection`, `ChromiumHostLauncher`, `ChromiumHostSession`,
  `ChromiumHostPageView`, `ChromiumHostRestartPolicy`, `ChromiumHostConfiguration`, `ChromiumHostPrototype`), and
  `debug.chromium_host` / `debug.chromium_host.measure` (wired in `A/AppDelegate.swift`, DEBUG).
- Forwarded: mouse (move, down, up, exit, buttons, click count), wheel (pixel deltas), keys (down, up, flags changed,
  character and unmodified character), focus, Edit menu (copy, cut, paste, select all, undo, redo). Not forwarded: IME,
  cursor, accessibility, drag and drop, Chromium's bubbles and popups (section 3.3 rows with a fork patch).
- Tests: `ChromiumHostFrameTests` (golden frame, also `scripts/cmux-next/test-chromium-host-wire-cpp.sh`),
  `ChromiumHostProcessTests` (a real child process: round trip, SIGKILL reported with its signal, the pid not reused
  before reap, a host that stops reading ends the connection without blocking the sender; this test found that macOS
  ignores `MSG_DONTWAIT` on Unix sockets), `ChromiumHostSessionTests` (a host that ends restarts
  with the last committed URL and shows no stale context; a second quick end stays ended; a host closed on purpose
  does not restart).
- Bench: `scripts/cmux-next/chromium-host-bench.py` (same probe page in process and in the host; key and click to the
  page's next animation frame, frame pacing, wire round trips, the host's input hop, SIGKILL check).

### Prototype numbers

Tests: the three suites passed on aws-m4pro-2/4/5/6/7 (macOS 27.0.1), 5 runs in all. The bench numbers (Debug build,
macOS 27 measure hosts cmux-austin-mini-0, cmuxs-Mac-mini-3, cmux20-bench; the CEF cmux.33 pin, API 27) are pending
in the measure queue and go into perf-lead.md section 5 when they arrive.

## 5. Remaining work and estimate

| # | Work | Who | Estimate |
|---|---|---|---|
| 1 | Fork: hosted page window off screen, never ordered in (the tracker skips `setFrame`/`addChildWindow` while hosted and drives the Views bounds directly; PL-cef-layer owns it, after hosting is on by default and the child-window path is gone); layer hosting for any widget (popups, extension popups, DevTools, side panel) | PL-cef-layer (fork) | 1 week |
| 2 | Fork: windowed IME (`Ime*`) + composition bounds callback; embedder active state; drag source to the embedder; `<select>` / autofill / password dropdowns through embedder callbacks; remote AX token; WebAuthn platform authenticator delegate | PL-cef-layer (fork) | 3-4 weeks |
| 3 | Shim split: the shim's 132 calls behind the wire (host side in C++ over the existing shim sources; cmux side in Swift); synchronous callbacks replaced by pushed policy and async events | PL-cef-helper | 2-3 weeks |
| 4 | XPC control channel, CA fence ports for resize sync, geometry per motion frame | PL-cef-helper + PL-motion-cef | 1 week |
| 5 | Supervisor for every tab: one host, restart, restore every tab's navigation state, sad-tab UI for pages that do not come back, `debug.crashes` records | PL-cef-helper | 1 week |
| 6 | cmux UI for what Chromium drew: JS dialogs, HTTP auth, file pickers, print, `<select>`, autofill | PL-cef-helper | 1-2 weeks |
| 7 | Text input and accessibility parity (IME on every input source, VoiceOver), macOS 14/15/26/27 | PL-cef-helper | 1-2 weeks |
| 8 | Release signing, keychain item, TCC prompts, passkey entitlement for a second identity | PL-cef-helper + release | 1 week |
| 9 | Bench light and STRESS against in process, then default on | PL-cef-helper | 1 week |

Total: about 12-16 weeks of agent work, of which 4-5 weeks are fork work that can run in parallel with 3-6.

## 6. Responsiveness requirements (session cmux-1c and the lead, 2026-10-24)

Source: `/Users/lawrence/fun/wt/cef-helper-requirements.md`. "Covered" names the place in this design; "missing" says how
it gets covered and in which slice (section 7).

| # | Requirement | Status |
|---|---|---|
| 1 | Pixels never through a main thread (CALayerHost on the GPU process's context); scroll and animation stay in the renderer and GPU process | covered: 3.3 "Pixels"; the prototype does it today (the host's context in a CALayerHost, `ChromiumHostPageView`) |
| 2 | One dedicated high-QoS input channel, coalescing per frame, scroll phase and momentum, chords decided in cmux first, key order kept | partly. Covered: a dedicated stream (not the control channel), one FIFO stream so order is kept, `KeyRouter` runs first in `CmuxApplication.sendEvent`. Missing, slice 2: a preallocated shared-memory ring with a Mach-port wake instead of the socket; cmux coalesces moves (latest wins) and wheel deltas (summed per phase) once per display frame; phase and momentum in the frame (`v[4]`, `v[5]` are free) with a fork call that forwards them (CEF's `SendMouseWheelEvent` has no phase); the host dispatches input on Chromium's user-input task queue (`BrowserTaskType::kUserInput`, a fork call) instead of `CefPostTask` to the default queue |
| 3 | Resize fence: size + sequence id, the host presents at that size and returns a CA fence, cmux commits in the same transaction, never waits more than one frame, else shows the last frame on the page background | partly: 3.3 "Resize sync" (fence port over XPC). Missing, slice 5: the sequence id (the frame's `seq`), a one-frame deadline instead of `browserResize.syncDeadline`, and the page background color sent with each context so cmux fills the gap as `CEFTab+ResizeBackdrop` does in process |
| 4 | Native UI (select, context menus, autofill, permission prompts, file dialogs, DevTools) from helper data, or anchored to cmux's window | covered: 3.3 rows (cmux draws from data; DevTools and popups are layer hosted in a cmux view or panel). A child window of another process is not possible on macOS, so "anchored child windows" become hosted contexts. Slice 4 |
| 5 | IME: cmux's `NSTextInputClient` proxies; the helper pushes the caret rect ahead | covered: 3.3 "IME" (rp-mode IME path, composition bounds pushed after each change). Slice 2 |
| 6 | Accessibility across processes | covered: 3.3 "Accessibility" (remote AX token, fork patch). Slice 4 |
| 7 | Privacy prompts name cmux | covered by how the host starts: cmux spawns it with `posix_spawn` and does not disclaim responsibility, so TCC attributes camera, microphone and location to cmux and reads cmux's usage strings, as for Chrome's helpers. Never start the host through LaunchServices or launchd. Missing: a check on macOS 14, 15, 26 and 27 (slice 5) |
| 8 | Crash: a crash page in each tab, terminals live on, restart and restore | partly: 3.2 (supervisor, restore from the saved navigation state, 60 s rule). Missing, slice 3: the crash page while the host restarts (the prototype shows an empty pane until the new context), every tab of every window |
| 9a | 50 ms main-thread stall every 100 ms: the page still scrolls at 120 Hz with 0 drops | missing, slice 1: `chromium-host-bench.py --stall` (the app's `debug.stall`) with the page's frame intervals and the display's |
| 9b | Key to page paint p95 no worse than today + 1 ms | partly: the bench measures key to the page's next frame in both modes plus the host hop (`hop_us`), Debug build; slice 2 measures it in the bench configuration |
| 9c | Live resize, no stretched frame | missing, slice 5 (with the fence) |
| 9d | IME and dead keys | missing, slice 2 (needs requirement 5) |
| 9e | Kill the helper while typing in a terminal: the terminal does not stall | partly: the bench's kill row checks cmux answers and the host restarts; slice 1 adds a terminal typing probe across the kill |
| 10 | Launch off the critical path; first Chromium tab < 100 ms; a spare page in the helper | missing, slice 3: the host starts after the first frame (as `ChromiumWarmup` does in process today) and keeps a spare page (`CEFSpareWindow`'s rule, PL-cef-tab) |
| 11 | No second copy of shared Chromium state; the renderer-sharing policy unchanged | covered: one browser process, in the host; cmux maps no framework (3.1). The policy is browser-process code and moves with it. Only the prototype runs two browser processes (in-process tabs and the host side by side) |
| 12 | Agent CDP and the shared cmux-page renderer keep working | partly: 3.4 (the host serves CDP; the daemon reaches it through `--remote-debugging-pipe` proxied by cmux with today's auth). Missing, slice 3: the proxy and the shared cmux-page renderer, which is browser-process state and moves with the host |
| 13 | Signing, sandbox, notarization, Sparkle, keychain | partly: 3.1. Missing, slice 5: the prototype turns off Chromium's code-sign clone for the host (it copies the main bundle, which here is only the small host app); an update must therefore end and restart the host before the bundle is replaced, or the clone must copy the outer app. Keychain: the host must use the fork API 25 keychain service of the app (an access group, decision 2) |

## 7. Slices from here (compressed, lead 2026-10-24: default on in DEV/NIGHTLY in about 3 weeks)

After slice 1, three agents work at the same time in their own worktrees (PL-cef-helper plus two helper agents),
and PL-cef-layer builds the fork list (sent 2026-10-24: user-input queue, wheel phase, windowed IME through the rp
path, embedder active state, off-screen hosted window, any-widget hosting, resize fence, native UI from data, AX
token, drag source, WebAuthn delegate, capture) as one CEF release.

| Slice | Who | What | Done when |
|---|---|---|---|
| 0 | PL-cef-helper | Design + prototype behind `browserHost.helperPrototype` (landed 6ed76900e56, cc7bc02aef0) | done 2026-10-24 |
| 1 | PL-cef-helper | Numbers: pump-share baseline (cmux20-bench, cmuxs-Mac-mini-3), prototype latency and pacing, stall test 9a, typing across a kill 9e | about 2026-10-26 (measure queue) |
| 2 | PL-cef-helper | Input ring, coalescing per frame, wheel phase, user-input queue, IME, cursor; proof 9b, 9d; then the resize fence and 9c | about 2026-11-07 (needs fork items 1-3) |
| 3 | helper agent A | The shim behind the wire (132 calls: host side over the shim sources, cmux side in Swift), supervisor for every tab, crash page, CDP proxy, launch and spare page | about 2026-11-07 |
| 4 | helper agent B | Native UI from data, AX token, drag and drop, DevTools and popups hosted | about 2026-11-10 (needs fork items 7, 9-11) |
| 5 | PL-cef-helper | Signing, notarization, Sparkle, keychain, TCC on 14/15/26/27, STRESS benches; default on in DEV and NIGHTLY | about 2026-11-14 |
| 6 | PL-cef-helper | Default on in Release after parity | after 2 NIGHTLY weeks with no host regression, about 2026-11-28 |

Slice 5 exit criteria include the update path: Sparkle (or the app's own update step) ends the host and starts it
again before it replaces the bundle, or the host keeps Chromium's code-sign clone with a clone of the outer app; an
update while a Chromium page is open is tested.

What limits the dates: the fork release (one packaged CEF with items 1-3, 6, 7, 9-11 by about 2026-11-07; a cold fork
build is about 1.6 h, packaging and the pin about a day); the fleet measure queue for the proof tests (steps waited
4 h and more on 2026-10-24); the size of the shim move (132 calls); reviews of each landing.

## 8. Decisions for Lawrence

1. One host for every profile (a crash reloads every Chromium page; least memory), or one host per profile (a crash
   stays in one profile; about 60-90 MB more per extra profile).
2. Release keychain: share an access group between cmux and the host (needs a provisioning change), or migrate
   "Chromium Safe Storage" to the host once at first start.
