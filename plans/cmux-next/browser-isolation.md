# cmux next: browser crash isolation and recovery

Written 2026-09-30 by the crash-isolation agent. User request: a crashed browser tab must not crash the rest of the app, and reload must recover it. Goal: no single failure in a page, a Chromium process, an extension, the daemon connection or a UI component takes the app down, and every failure has a working recovery.

## Decisions for Lawrence

1. **Out-of-process CEF browser process: not now.** The spike (below) shows the pixel path works (a `CALayerHost` of a helper's `CAContext` renders in our window, clipped by our rounded corners, with no extra frame), but Chrome style keeps every Views window (extension popups, permission bubbles, DevTools, file pickers, drag sources) and the page's text input and accessibility in the browser process. Moving that process out needs Chromium's remote_cocoa "app shim" split in the fork, weeks of fork work, and it regresses IME, VoiceOver and focus until each is bridged. Recommendation: keep CEF in process, harden it (done here), and revisit when the fork has a remote_cocoa host mode. Say if you want the fork project started.
2. **SIGPIPE is ignored process-wide** at launch (`CmuxNextApp.main`), as Chromium does. Children get the default back (Foundation `Process` and Chromium reset it; the one `forkpty` site resets it). Say if you prefer per-socket protection only (it is also in place).
3. **SIGTERM counts as a normal quit** for restart detection: `kill <pid>` does not show "cmux restarted after a problem". SIGKILL, jetsam and crashes do.
4. **Safe restart rule**: a restart that ends again within 60 s starts the next time without loading browser pages (they show the URL and "Reload to open"). There is no launcher that restarts the app by itself, so there is no loop.

## Failure matrix: what happens now

| Failure | Detection | What the user sees | Recovery | Verified |
| --- | --- | --- | --- | --- |
| Renderer crash (SIGSEGV, CHECK) | CEF `OnRenderProcessTerminated` (status crashed) | Sad tab in the pane: "This page crashed", "Other tabs are not affected", error code, Reload | Reload (button, Cmd-R, palette, CLI, context menu) loads the shown URL; Chromium turns that into a reload of the current entry, so history is kept | see Verification |
| Renderer killed (`kill -9`, Activity Monitor, Exit page) | status killed | "This page was stopped" | same | see Verification |
| Renderer out of memory | status OOM | "This page ran out of memory" | same | unit test only |
| Renderer launch failure | status launch failed | "This page couldn't start" | same | unit test only |
| Background tab crash | same | nothing until shown; the tab reloads when shown (Chromium behavior) | automatic | see Verification |
| Renderer hang (15 s without input handling) | CEF `OnRenderProcessUnresponsive` / `Responsive` (hang monitor, no polling) | "Page unresponsive" glass card over the page: Wait / Exit page. Chromium's modal Views dialog never shows | Wait restarts the hang timer; Exit page ends the renderer (sad tab, then Reload) | see Verification |
| GPU process crash | helper monitor (kqueue) | Chromium restarts the GPU process and recreates compositor frames; pages repaint | automatic (Chromium) | see Verification |
| Utility / network service crash | helper monitor | in-flight loads fail; Chromium restarts the service | automatic (Chromium); failed loads show the load error page with Try Again | see Verification |
| Extension process crash | helper monitor (renderer with `--extension-process`); fork `extensionsChanged` with `terminated` | see "Extensions" below | see below | see Verification |
| WebKit content process ends | `webViewWebContentProcessDidTerminate` | same sad tab ("This page crashed"; WebKit gives no reason) | Reload | unit path only |
| Daemon disconnects or restarts | existing `DaemonStartup` / resync | existing connecting view; terminals survive in the daemon | existing reconnect | existing tests |
| Socket peer closes during a write | EPIPE (`MSG_NOSIGNAL`, `SO_NOSIGPIPE`, SIGPIPE ignored) | nothing; typed `peerClosed` | connection-level retry | `SocketWriterTests` |
| Malformed daemon event, render delta, control line, certificate | decoders | refused, logged | continue | fuzz tests |
| App crash (any cause) | run marker + fatal signal handler | relaunch restores windows, workspaces, panes, tabs; browser tabs reload; "cmux restarted after a problem" notice with Show Crash Log | manual relaunch | see Verification |
| App crash again within 60 s of a restart | run marker | same, but browser pages are not loaded until the user reloads one; the notice says so | Reload per tab | unit test; see Verification |

## In-process CEF: the remaining risk

Chromium's browser process runs inside the cmux app (CEF external message pump, Chrome style). A bug there (the extensions agent's dangling popup-anchor pointer, fixed in fork `806827fbf` and not yet in the pinned release) ends the whole app. Renderers, GPU, utility and extension processes are already separate, so everything except browser-process code is isolated by Chromium itself. What this change does for the in-process part:

- Every fork call the shim makes is guarded by a browser-id lookup (`BrowserById`, fork `FindTab`); a stale id returns 0, never a CHECK.
- The shim never lets Chromium show its hung-page dialog (a nested run loop on our main thread) or its Aw, Snap! page; both are host UI.
- Quit already uses the fork's window-destroyed signal before `CefShutdown` (`CEFShutdownSequence`), with a timeout that skips `CefShutdown` instead of crashing.
- CEF shim callbacks no longer trap when called off the main thread.
- If the process still dies, relaunch is exact (daemon-owned state) and a second quick crash starts without Chromium pages.

Fork crash paths found but not changed here (sent to the extensions agent): `cmux_ext_action_context_menu` keeps a function-static `views::MenuRunner*` and deletes it at the start of the next call. A second call while the first menu still runs (it runs nested) deletes a running `MenuRunner`, and the runner is not tied to the Browser's lifetime. Fix: one runner per `WindowRegistry::Window`, and return early while one is running.

## Out-of-process spike

Question: can Chromium's browser process run in a helper that cmux owns, with pages shown in the app through remote layers, so that a browser-process crash restarts only the helper?

How Chromium itself is split on macOS:
- Pixels: the GPU process renders each compositor frame into a `CAContext`; the browser process shows it with a `CALayerHost` (`ui::DisplayCALayerTree`). The browser process is not in the pixel path.
- PWA app shims: the NSWindows of an app shim process are driven by the browser process through remote_cocoa (`NativeWidgetNSWindowBridge`, `RenderWidgetHostNSViewBridge` over mojo); page content arrives as `CALayerHost`s; accessibility crosses as remote AX elements. CEF's `libcef/browser/views/native_widget_mac.mm` already goes through remote_cocoa bridges in process.

Spike (`/tmp/crashiso-spike/layerhost/spike.m`, kept out of the repo):
- `spike server` creates a `CAContext` on the WindowServer connection and draws layers into it; `spike host <id>` puts a `CALayerHost` with that id in a normal window whose content layer has `cornerRadius 24, masksToBounds`.
- Result: the helper's layers render in the host window, and the host's rounded clip clips them (screenshot: the bottom corners of the remote content are rounded). A `CALayerHost` is an ordinary layer in our tree, so overlays, column-strip scroll, the rounded clip and Liquid Glass above it all work, unlike today's child NSWindow.
- Frame latency: a remote context commits to the render server directly; WindowServer composites it in the same frame as local layers. No extra hop was added in the pixel path (Chromium's own GPU-to-browser path is the same mechanism).
- Input hop (host process to helper, one pipe round trip, 20,000 samples, machine busy with builds): p50 4-9 us, p99 0.16-0.44 ms, max 3.5-9 ms (scheduling noise). A key or mouse event would pay one of these before Chromium sees it, well under one frame at p99.
- Memory: one more process with the Chromium framework mapped. The app today gains about 40 MB footprint when CEF starts (browser.md, "Chromium warm start"); in the split design the app would not map CEF at all and the helper would carry that plus a process baseline (see Verification for measured helper footprints).

Why it is not feasible now (Chrome style is required for real extensions; CEF's offscreen mode needs Alloy style and has no extension tab model, so it is rejected):

| Area | Cost of moving the browser process out |
| --- | --- |
| Extension popups, permission bubbles, extension context menus, JS dialogs Chromium draws, DevTools windows | NSWindows owned by the helper. They cannot be child windows of our windows (AppKit child windows are per process), clicking them activates the helper, and our window loses key status (traffic lights dim, cmux shortcuts stop). Needs remote_cocoa hosting of every Views widget in our process. |
| Text input (IME, dead keys, emoji picker, dictation) | `NSTextInputClient` must be the page view in the key window's process. Needs `RenderWidgetHostNSViewBridge` in our process (remote_cocoa). |
| Accessibility (VoiceOver, AX window managers) | The page AX tree lives in the helper; it needs remote AX tokens (Chromium does this for app shims). |
| Drag and drop, file pickers, printing, full screen | Helper-owned sessions and panels; each needs a bridge. |
| Focus model and key routing (plans/cmux-next/focus.md) | Today `OnPreKeyEvent` runs our key router synchronously on the main thread; cross-process it becomes async, so shortcut precedence needs a new protocol. |
| Fork work | A CEF mode that runs the browser process as its own executable and hosts remote_cocoa bridges in the embedder (like `chrome/app_shim`). The embedder still links the Chromium framework for the bridge code, but browser-process logic no longer runs in it. Estimate: several weeks in the fork plus a shim rewrite. |

Staged plan if Lawrence wants it later:
1. Fork: build CEF's browser process as a helper executable with a mojo channel to the embedder; show one page through `CALayerHost` (no extensions, no IME). Measure again with real pages.
2. Fork: host `RenderWidgetHostNSViewBridge` in the embedder (input, IME, cursor, AX tokens).
3. Fork: host `NativeWidgetNSWindowBridge` in the embedder for Views widgets (extension popups, bubbles, DevTools).
4. App: helper supervisor (restart on crash, reattach tabs from daemon records, sad tab for pages that were open).

## Crash safety rules (gate)

`scripts/cmux-next/check-crash-safety.sh` (add to the merge gate next to the other three checks): no `try!`; no force unwrap or `as!` in CmuxNextDaemon, CmuxNextControl and CmuxNextMobile (they decode external data) without a reviewed `// crash-allow: <reason>`; every file that makes or accepts a socket uses `SO_NOSIGPIPE` or `MSG_NOSIGNAL`; the app entry point ignores SIGPIPE.

Fuzz coverage: `EventFuzzTests` (every captured daemon event, mutated, applied to a store), `ControlParserFuzzTests` (control JSON framing and v1 text lines), `RenderGridHostileTests` (render deltas), `HostileInputTests` (certificates).

## Crash visibility

- `debug.crashes`: launch recovery state (`clean`, `restarted`, `restartedSafely`), the previous run (pid, launch time, signal, whether it lived past 60 s), paths of macOS's `.ips` and our report, the restart notice on screen, and the recent Chromium failures (process type, sub type, pid, reason, code, tab id, source `engine` or `process`).
- Reports: `~/Library/Logs/cmux-next/<bundle>-chromium-<type>-<time>.json` and `<bundle>-app-<time>.json`. No URL, title, terminal text or typed text. Newest 100 kept.

## Allocator zone race ("No zone found")

Symptom (coordinator report, `/tmp/dvhit-work/crash1.log`): `[FATAL:allocator_shim_apple.cc(61)] Check failed: false. Oops! No zone found`, a CoreFoundation free on the main thread (CoreEmoji, from AppKit) routed through Chromium's `try_free_default`.

Root cause: the framework is built with PartitionAlloc as malloc. Its constructor `InitializeDefaultMallocZoneWithPartitionAlloc` (runs at `dlopen`) makes its zone the default by registering it, unregistering the system default zone and registering the system zone again. Between the last two calls no registered zone owns system allocations; a `free()` on another thread then fails the owner lookup and CHECKs. Chromium's own comment in `allocator_shim_override_apple_default_zone.h` names this race. Chrome avoids it by calling `EarlyMallocZoneRegistration()` first thing in its main executable while it has one thread (a delegating default zone that PartitionAlloc later replaces without ever removing the system zone). cmux-next maps the framework lazily on a background thread (`CEFRuntime.loadLibrary`) while the main thread runs AppKit, so it hit the race.

Fix: `CmuxNextMallocZone` (C target, a port of `early_zone_registration_apple.cc`) runs first in `CmuxNextApp.main`. Evidence: `scripts/cmux-next/malloc-zone-race/run.sh` (four threads malloc/free while the main thread dlopens the pinned framework): without the early zone 23/30 and 14/20 runs crashed with the same CHECK and stack; with it 0/30 and 0/20. Helpers are not affected: they load the framework at the start of their main.

This is also an argument for out-of-process CEF: every static initializer and allocator decision of a 600 MB framework runs inside our process. The early zone removes this race, but the class (framework code with process-wide side effects) stays until the browser process moves out.

## Verification

Tagged build `crashiso` (local, CEF cmux.4-ext, screen unlocked, window on the secondary display, no-activate), 2026-09-30. Screenshots in `/tmp/crashiso-spike/` (not committed).

| Check | Result |
| --- | --- |
| `chrome://crash` in a visible tab | PASS: sad tab "This page crashed", "Error code: SIGSEGV" (`sadtab.png`); app alive; `debug.crashes` has an engine record (tab id) and a process record (pid, SIGSEGV); JSON report written |
| `kill -9` of a visible tab's renderer | PASS: "This page was stopped", SIGKILL (`killed.png`); Reload through the registry action `browserReload` (the Cmd-R, palette and menu path) loads the page again with Back enabled (`reloaded.png`) |
| Reload after `chrome://crash` | FAIL on the first build: Reload loaded `chrome://crash` again and the tab stayed loading over Chromium's own Aw, Snap! (`afterreload.png`). Fixed (reload the committed entry, test red -> green); re-run PASS: the page comes back, not loading (`reloadfix.png`) |
| Background tab renderer killed, then shown (`surface.focus`) | PASS: the tab reloads when shown (`bgshow.png`) |
| GPU process `kill -SEGV` | PASS: Chromium starts a new GPU process, the page repaints, no sad tab (`gpu.png`); process record `gpu-process crashed` |
| Network service `kill -9` | PASS: Chromium restarts it; the next navigation loads; record `utility network.mojom.NetworkService killed` |
| Terminals and windows during all of the above | PASS: `debug.surfaces` live terminal 1, blank panes 0; one invariant violation was counted over the session (transient, not investigated) |
| Renderer hang (`chrome://hang`, and a page that loops on click) | FAIL, cause found (2026-10-12, fleet build of PR #20061 on a capture slot, `scripts/cmux-next/page-hang-live.py`). The first run (2026-09-30) was UNVERIFIED because no in-app input reached the RenderWidgetHost: a no-activate page window is never key, so AppKit dropped posted clicks, keys went to an unfocused view, and DevTools `Input.*` refuses Chromium's own pages. `debug.mouse {"target": "page"}` now hands the click to `RenderWidgetHostViewCocoa`, and the page hangs (visible, `document.visibilityState` "visible"), but Chromium never reports it, because every cmux Chromium tab has a DevTools client attached. CEF's `CefDevToolsController` attaches to the tab's frame agent host on the first protocol message (the media bridge sends `Page.enable` on every tab), so `DevToolsAgentHost::IsDebuggerAttached` is true and `WebContentsImpl::ShouldIgnoreUnresponsiveRenderer` drops every hang. The callbacks and the inline card (`PageUnresponsiveView`, no dialog) are wired and unit-tested. Fix: a fork patch so CEF's own controller does not count as a debugger (needs a CEF release and pin bump) |
| App crash (`debug.crash.app segv`) | PASS: the process ends, the marker has signal 11, the daemon and terminal host keep running; relaunch reports `restarted` with the previous pid and signal, restores the window and tabs and writes the app report |
| Second quick crash | PASS: the next launch is `restartedSafely`; Chromium does not warm start; a tab opened in that run loads normally (Example Domain) |
| Restart notice | FAIL on the first build (hook set after the first window opened), then clipped (one line of height) and without Show Crash Log. Fixed; re-run: the notice shows above the Chromium page at the bottom of the window (`notice-panel.png`); the final layout fix is in the last build |
| macOS crash report for an app crash | FAIL on the first build: the handler re-raised inside itself, so the end was a plain signal and no `.ips`. Fixed; re-run PASS: `debug.crash.app trap` produced `cmux DEV-...-042823.ips`, and the next launch links it as `system_report` |
| SIGTERM (`kill <pid>`) | PASS: marker records 15, the next launch is `clean`, no notice |
| App start with `CMUX_NEXT_CEF_LOAD_EXTENSIONS` (an MV2 and an MV3 probe) and `disable-features=ExtensionManifestV2Unsupported,ExtensionManifestV2Disabled` | On the first build (CEF cmux.4-ext), the app crashed when the first Chromium tab opened, 3 of 3: SIGSEGV in Chromium code on CrBrowserMain, null + 0x10. Without these variables there was no crash. Re-run on CEF cmux.23 (2026-10-12, fleet build of `82ddac28`, capture slot, `CMUX_NEXT_CEF_EXTRA_SWITCHES` for the features): PASS 3 of 3. `browser.extensions` lists both probes. The restored and new Chromium tabs open (Example Domain), and the app keeps running. The crash is gone on the current pin, so there is nothing to fix or symbolize. Extension crash UI stays unit-tested only |
| Isolation spike numbers | pipe round trip p50 3.5-9 us, p99 0.16-0.44 ms (machine busy with builds); CALayerHost demo renders and is clipped by the host's rounded corners |
