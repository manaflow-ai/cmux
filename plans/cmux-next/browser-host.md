# cmux next: browser host (agent browser use, WebKit and Chromium)

Design note, 2026-10-01. Owner: the cmux-next browser-use lead. Binding inputs: cmux-next-spec `spec/browser-use.md` (draft 2), `decisions.md` D12 and D20, `references/browser-use.md`, `references/browser-repl-inventory.md`; OWNERSHIP-PRINCIPLES.md; browser.md (CEF fork, shim, R2). Base implementation: PR https://github.com/manaflow-ai/cmux/pull/15570 (`cmux browser repl`, owner session feat-browser-repl-parity-8c, called "the REPL session" below). Its driver protocol ([browser-repl/driver-protocol.md](browser-repl/driver-protocol.md), moved from `docs/browser-repl`) is the contract this note builds on; its `tests/browser-parity` is the conformance suite. This note does not change either; changes to them go to the REPL session through the coordinator.

> **Resume note (parked 2026-10-03, browser-use lead):**
> 1. Branch `feat-cmux-next-browser-host-b` (head 1471aaaea0c, rebased on feat-cmux-next): REPL VM, policy gate, request interception, MCP port; review round 3 CLEAN; hosted full run 37074766904 FAILED: lint/test (linux) = one clippy unused_qualifications in server.rs (fixed in a later push), test (linux) also cmux-conversation conformance (another lane's crate), one job 'Formatting issues found' (check if ours). Next: rerun `./scripts/verify-cmux-tui-hosted.sh --full`, then push to feat-cmux-next with a COORDINATION line.
> 2. Branch `feat-cmux-next-wake-post` (head pushed, not landed): POST pages never hibernate (WebKit tracker + CEF shim export). Swift tests green via nx-remote; shim compile UNVERIFIED (nx-remote ssh dropped). Next: `scripts/cmux-next/ensure-cef.sh` + `build-cef-shim.sh` on the build host, gates, then land.
> 3. Landed today: quit-order fix a73630ec329, SIGPIPE no-op handler 3114269a0cd. Open after landing b: seal tabs (decision 8), owner policy path (fail-closed setup, real-Chromium worker/WebSocket tests), WebRTC, native fetch, conformance 11/33.
> 4. Waiting on the CEF fork lane: cmux.14 pin (adopt `cmux_tab_duplicate` behind `browser.duplicateRight`), watchdog/signal-handler change.
> 5. Lawrence decision pending: with any domain policy active, all WebSockets are blocked (Slack, Linear included).

## Decisions (Lawrence, 2026-10-01, via the coordinator)

1. **Daemon-supervised host, app as engine provider (decided).** It must just work: the host starts on demand with no setup, restarts after a crash, the app's provider reconnects by itself, sessions survive an app restart, and the UI shows a clear state when an engine is unavailable (section 1, "Lifecycle and user-visible state").
2. **#15570 port: the coordinator's mover agent** moves the runtime JS, docs, `tests/browser-parity` and the WebKit driver onto feat-cmux-next (paths agreed with the browser-use lead: JS in `cmux-tui/crates/cmux-browser-host/js/`, docs in `plans/cmux-next/browser-repl/`, suite at `tests/browser-parity/`).
3. **Agent-supplied secrets: allowed, masking only (decided).** Passwords are never secrets: agents use the Secure sign-in sheet and get a status (coordinator, Leo's cc-next-browser lane owns import and passwords).
4. See 2.
5. **No host|inapp switch (decided).** cmux-next uses only the Rust host for Chromium and WebKit.

6. **WebKit driver in Swift (decided, no Rust spike).** `CmuxNextBrowserAutomation` behind `DriverCallHandler`, built by the mover agent.
7. **Engines (decided).** Chrome and WebKit are both first class in the host, CLI, MCP and code mode: same API, same conformance goldens. Chrome is the default engine: `browser.repl.open {engine: "auto"}` resolves to in-app Chromium (CEF) on the Mac and headless Chromium on Linux. WebKit is reachable only through the CLI (`--engine webkit`), MCP (`engine: "webkit"`) and the Cmd-Shift-P palette; no menu, right-click or new-tab-page entry.

8. **Secrets read back by agent code (decided: sealed tabs now, engine-level read masking later).** Lawrence's question: an agent can save a value to a global or install a shim before the fill. Sealing therefore works like this:
   - The secret never enters the agent's JS VM: the VM holds a vault handle; the host types the value through trusted engine input.
   - Before a secret fill, the host SEALS and RESETS the tab: arbitrary `frame.evaluate` (page and agent worlds), raw CDP, `addInitScript` and user scripts, service-worker registration by the agent and agent-world injection are disabled for that tab; agent-installed init scripts are removed; the page is reloaded fresh, so no agent global or shim survives in the page or the agent world.
   - The fill happens only through the Secure sign-in sheet (user-confirmed) into that clean page.
   - The tab stays sealed for its lifetime, or until it navigates to a different site and is reloaded fresh; results returned to the agent are masked.
   - Remaining risk: the site's own scripts and browser extensions can still read the field. Engine-level read masking (option 2) is the follow-up that closes this.
   - Tests (written first): an agent that installs a capture shim, a global, an init script or a service worker before the fill gets nothing; a sealed tab refuses evaluate and raw CDP; a sealed tab unseals only after a cross-site navigation plus fresh reload.

## 1. Process model

```
agents (CLI, MCP, mux code mode)            remote mux (via daemon relay, D20)
        │ catalog ops browser.*                     │
        ▼                                           ▼
cmux browser host (Rust, one per machine, supervised by the local daemon)
   listener: $STATE/browser-host.sock (0600, user-only dir); agents present the launch credential
   ├─ sessions: QuickJS-ng VM per session (rquickjs), 15570 runtime JS unchanged, __cmuxNative v1 ABI
   ├─ policy gate (Rust): navigation, fetch, subresource, secret typing, raw CDP grant, origin and actor checks
   ├─ secret vault (Rust): values never enter the VM; output masking on every byte that leaves the host
   ├─ snapshot core (Rust port of snapshot.js; JS stays as reference behind a DEV switch)
   ├─ action log, leases, recordings, eval harness, MCP tool descriptors (exported to the catalog)
   └─ drivers (one Rust trait = driver protocol)
        ├─ CdpDriver<PipeTransport>     headless Chromium, --remote-debugging-pipe (Linux VMs, Mac later)
        ├─ CdpDriver<RelayTransport>    in-app CEF tabs, raw CDP frames over the provider connection
        └─ ProviderDriver               in-app WebKit tabs, driver protocol forwarded to the Swift driver
                     ▲
                     │ provider connection (Unix socket, authenticated, app dials)
Mac app (owns the browser runtime): Swift WebKit driver + CEF shim DevTools relay + lease badge
page agent JS + Playwright injected script: installed per frame in an isolated world by each driver
```

- One host per machine, not per app window or per session: refs, leases and policy are machine facts, and a mux on another machine addresses one endpoint (`browser-host` owner in the catalog).
- The daemon starts the host lazily on the first `browser.*` op or the first provider connect, restarts it with `Backoff` after a crash, and stops it when idle with no provider and no session (one-shot `DemandTimer`, no polling). The host binary is the one `cmux` binary (`cmux browser host`); until #16174 merges it is a separate binary target `cmux-browser-host` of the same crate, and the subcommand wiring is a request to session feat-cmux-next-99.
- Crash isolation: a runaway session (15570 measured 7 GB once) hits the per-VM QuickJS memory limit and interrupt deadline and fails alone; a host crash loses sessions and refs but no tab, page or layout state (owned by the app and the store).
- Cost: one local IPC hop per driver call. 15570 already batches frame reads (`frame.contentFrames`); the host keeps that and adds `batch` frames (several driver calls in one message) where the runtime issues independent calls.

### Lifecycle and user-visible state

- Start: the first `browser.*` op (CLI, MCP, mux) or the first provider connect makes the daemon start the host. No setup step, no flag.
- Crash: the daemon restarts the host with `Backoff`. Sessions are lost (their VM state is in memory); the next `browser.repl.eval` on a lost session answers `session_lost` with the session id, and `browser.repl.open` with the same id creates it again. Tabs, pages and layout are untouched.
- App restart: the provider connection drops; the host keeps sessions and marks their tabs `provider_gone`. Calls on those tabs wait up to their deadline for the provider to come back and re-announce the tab (same `targetId` from the store's tab record), else fail `closed`. When the app comes back it reconnects without user action.
- Engine unavailable (no CEF framework in the bundle, Chromium binary missing on Linux, WebKit provider absent): `browser.repl.open {engine}` and every call fail with `engine_unavailable {engine, reason}` (the reason text comes from `CEFUnavailableReason` on the Mac). The app shows the same reason on the lease badge and the browser pane notice; the CLI and MCP print it.
- Chromium on Linux: an optional Chrome for Testing bundle next to cmux-tui (`cmux browser install-chromium`, sha256-pinned), always baked into Freestyle snapshots; the host finds it before any system Chrome.

### Provider connection (app ↔ host)

Framing: length-prefixed JSON (u32 big-endian length, then UTF-8 JSON), one frame per message, both directions, max 64 MiB (screenshots). Frames:

| Frame | Direction | Meaning |
| --- | --- | --- |
| `hello {version, provider_id, install_id, engines: ["webkit","cef"], tabs: [TabAnnounce]}` | app → host | first frame; `TabAnnounce = {targetId, engine, workspace, profile, url, title, visible}` |
| `hello.ack {agent_bundle, agent_bundle_sha}` | host → app | the page agent bundle (manifest `agent` list, embedded in the host); the app installs it as document-start user scripts in the agent world of every driven tab, so there is one copy |
| `call {id, method, params}` / `result {id, result? , error?}` | host → app / app → host | driver protocol method on a WebKit tab (methods, params and errors exactly as driver-protocol.md) |
| `event {name, payload}` | app → host | driver protocol event (`tab.created`, `dialog.opened`, …) and provider events (`tab.announced`, `tab.gone`) |
| `cdp.attach {targetId}` / `cdp.detach {targetId}` | host → app | start or stop relaying a CEF tab's DevTools session |
| `cdp {targetId, message}` | both | one raw CDP message (string), passed through unparsed by the app |
| `lease {targetId, lease?}` | host → app | show or clear the "driven by" badge; the app never shows a lease it did not receive |
| `user.input {targetId}` | app → host | a person pressed a key or clicked in a leased tab; the host pauses that lease (spec risk "human and agent input") |

Authentication: the daemon mints a per-launch provider secret when it starts the host and hands it to the app over the app's existing trusted daemon connection; the app proves it in `hello` and the host also checks peer credentials (same uid). A provider connection is never accepted from the agent listener. The host refuses a second provider with the same `install_id` (one app per install) and replaces it only after the first disconnects.

CEF relay: the shim gains `cmux_shim_devtools_send(browser_id, message_json)` (`CefBrowserHost::SendDevToolsMessage`, raw JSON with its own `id` and optional `sessionId`) and forwards every `CefDevToolsMessageObserver::OnDevToolsMessage` for attached browsers as a new shim event. Raw messages keep flat sessions, so out-of-process iframes work through `Target.setAutoAttach {flatten: true}`. Every tab under an agent lease turns password fill off before the first agent action (Leo's browser lane rule, 2026-10-01): the provider's lease path calls `TabContentCache.markAgentDriven(key)` for every engine, and for CEF tabs also `cmux_tab_set_password_fill` (CEF fork API 15) when the lease starts, restored when it ends. The setting is per WebContents and popups do not inherit it (CEF fork review): a tab opened by a leased tab (`window.open`, `target=_blank`, popups the runtime adopts) joins the opener's lease, and the app applies the setting synchronously when it adopts the tab, before its first navigation, because a value filled before the call stays until reload. Step c carries a test for the popup case (a leased tab opens a login popup; the popup never fills a saved password). The existing `cmux_shim_devtools_call` path stays for the app's own uses (previews, occlusion snapshots). Header edit changes the shim ABI identity (browser.md "CEF shim ABI identity"); the relay needs no fork change.

### Agent protocol (host listener)

Catalog ops (owner `browser-host`), the runtime command list in spec/browser-use.md "APIs and ops": `browser.session.open/list/reset/close`, `browser.eval {session, code, max_output}`, `browser.snapshot`, `browser.screenshot`, `browser.wait`, `browser.dialog.respond`, `browser.filechooser.respond`, `browser.download.list/path`, `browser.cookies.*`, `browser.storage_state.save/load {scope}`, `browser.policy.set` (user origin only), `browser.secrets.load/list/delete` (user origin only), `browser.record.start/stop`, `browser.trace.export`, `browser.lease.take/release`, `browser.cdp` (grant), `browser.act` (fixed tool mode, opt-in). Framing: the cmux-tui request envelope (`{id, method, params, origin, idempotency_key?}`, `request-settled`), so the generated CLI and MCP clients reuse their transport. Runtime commands are at-most-once by request id; an input call whose result is lost is reported `ambiguous` and never replayed.

### Surfaces: CLI, MCP and mux code mode (binding, Lawrence 2026-10-01)

Browser use is available through three surfaces, all generated from the one operation catalog (owner `browser-host`), all with the same persistent REPL session model:

| Surface | REPL | Discrete ops |
| --- | --- | --- |
| CLI | `cmux browser repl` interactive, and `cmux browser repl --session NAME --eval CODE\|-` one-shot (15570 grammar); `cmux browser repl list`, `reset`, `close`, `guide` | `cmux browser snapshot`, `screenshot`, `tabs`, ... from the catalog |
| MCP | `browser_repl_open {session?, profile?, label?} -> {session}`, `browser_repl_eval {session, code, timeout?, max_output?}`, `browser_repl_close {session}` | `browser_snapshot`, `browser_screenshot`, `browser_tabs`, ... from the catalog (default group per operation-catalog.md) |
| mux code mode | the mux sends code to `browser.repl.eval` on a session it opened; the code runs in the host's QuickJS VM with the 15570 API (`page`, locators, `keyboard`, `mouse`, `tabs`, `snapshot`, ...) so one call scripts a multi-step task | same catalog ops as tools |

Catalog ops behind them: `browser.repl.open {session?, profile?, label?}` (creates or attaches by id; idempotent by `session`), `browser.repl.eval {session, code, timeout_ms?, max_output?}`, `browser.repl.close {session}`, `browser.repl.list`, `browser.repl.reset {session}`. A session keeps its VM state (top-level `const`/`let`, variables, open tabs, refs) between calls until `close`, `reset`, idle expiry, or a host restart. Every surface runs the same sandbox and the same policy, secret and masking rules (section 4), and every call is stamped with `origin` (`cli`, `mcp`, `remote` for a relayed mux) plus `actor` and `on_behalf_of` from the connection (section 3). There is no surface-specific runtime: the CLI, the MCP server (`cmux mcp`) and the mux tool layer are thin generated clients of these ops.

## 2. What runs where

| Piece | Where | Why |
| --- | --- | --- |
| page agent (`page-agent.js`) and Playwright injected script | in every frame, isolated world, installed by each driver | they read the live DOM and accessibility state; Rust cannot run there |
| runtime JS (`runtime-core.js`, `api.js`, `agent-tools.js` minus policy and secrets, `sites/*`, `repl-host.js`) | QuickJS-ng VM in the host | agent code is JS; the Playwright-model runtime is engine-neutral and proven by the suite |
| sessions, ref and frame bookkeeping, timers, fs sandbox, fetch with tab cookies | host (Rust) | one core for every engine; today Swift in `CmuxBrowser/Repl` |
| snapshot stitching, render, diff, print budget | host (Rust port), JS reference behind `CMUX_BROWSER_SNAPSHOT_CORE=js\|rust` (DEV) | page agent already emits raw per-frame nodes; QuickJS is slower than JSC on 50k-node trees |
| domain policy, subresource policy, secret vault, masking, raw CDP grant | host (Rust), below the VM | security blocker (section 4) |
| output cap and spill, action log, leases, recordings, evals | host (Rust) | bounded state the host owns |
| MCP tool descriptors | host exports catalog entries; `cmux mcp` (feat-cmux-next-mcp) serves them | one MCP server per machine, generated from the catalog (D7) |
| CDP driver | host (Rust), transports: relay (CEF in app), pipe (headless) | the same mapping for in-app and headless Chromium |
| WebKit driver (native NSEvent input, content worlds, `_frames:`, delegates, capture, off-screen key window) | Swift in the app | `WKWebView` exists only in the app process and needs AppKit and SPI |
| CEF DevTools relay, lease badge, user-input pause signal | Swift in the app (`CmuxNextBrowserHost`) | the app owns the browser runtime |

`__cmuxNative` keeps version 1 (driver-protocol.md "Native host contract") with two changes made in Rust: `driverCall` goes through the policy gate, and secret-bearing calls take handles (section 4). The VM stays swappable (V8 through `deno_core` if QuickJS-ng misses the perf gate).

### 2a. WebKit driver: Swift or Rust (evaluation)

Lawrence asked whether the WebKit driver can be Rust too: a Rust library linked into the app (objc2, objc2-web-kit), on the main thread, with Swift only hosting the view.

Feasible parts: objc2-web-kit binds `WKWebView`, `WKContentWorld`, `WKUserScript`, `callAsyncJavaScript:arguments:inFrame:inContentWorld:`, `takeSnapshotWithConfiguration:`, `createPDFWithConfiguration:`, and delegate protocols (`define_class!` implements `WKNavigationDelegate`/`WKUIDelegate`). SPI (`_simulateMouseMove:`, `_frames:`, `_setResourceLoadDelegate:`, `_doAfterProcessingAllPendingMouseEvents:`, `_WKContentWorldConfiguration`) is plain `msg_send!` behind `respondsToSelector:` checks, the same as Swift's dynamic calls. Native input (`NSEvent` construction, `sendEvent:` to the web view's window) works through objc2-app-kit. Threading: driver calls arrive off main; `MainThreadMarker` plus a main-queue hop (dispatch2) serializes them, as Swift's `@MainActor` does.

Costs that decide it:
- Delegate ownership: `WebKitTab` (Swift, `CmuxNextBrowser`) already owns the navigation, UI and download delegates for normal browsing. Dialogs, file choosers, popups and downloads must reach the driver, so a Rust driver needs either Swift to forward every delegate callback over FFI or Rust proxy delegates that forward to Swift. Both put a second owner on the same delegate surface.
- AppKit state the driver changes: the off-screen key render window, first responder, occlusion, the native drag session, and the virtual pasteboard swap are AppKit lifecycle code that the Swift app owns (focus.md, OWNERSHIP-PRINCIPLES "client owns the view"). Driving them from Rust crosses that boundary on every call.
- Build: a second Rust static library in the Xcode build (precedent: the CEF shim and diff sidecar), Swift 6.2 Release compile interplay, and an FFI ABI identity like the shim's.
- What moves: only engine-bound glue. Everything engine-neutral is already Rust in the host, so "Rust for both Chrome and WebKit" holds at the host level either way.

Recommendation: Swift WebKit driver now (`CmuxNextBrowserAutomation`, ported from the 1,620-line driver that passes the suite), exposed only through the driver protocol (`DriverCallHandler`). If Lawrence still wants Rust there, a bounded spike first: a Rust objc2 crate in the app that does `frame.evaluate` in a content world, `_simulateMouseMove:` hover and a trusted click on one tab, timed against the Swift path; decide on its numbers and on the delegate forwarding cost.

### CDP mapping (summary; the driver is done when the goldens pass)

| Driver method | CDP |
| --- | --- |
| `frames.list`, `tab.navigated` | `Page.getFrameTree`, `Page.frameAttached/Navigated/Detached`, OOPIF sessions from `Target.setAutoAttach {flatten}` |
| agent world | `Page.addScriptToEvaluateOnNewDocument {worldName: "cmux-agent", runImmediately}` per session, `Page.createIsolatedWorld` for frames that loaded before, context ids from `Runtime.executionContextCreated` (`auxData.frameId`, name) |
| `frame.evaluate` | `Runtime.callFunctionOn {executionContextId, functionDeclaration, arguments, awaitPromise, returnByValue}`; handles resolved in the agent world, moved to the page world with the same DOM-event trick as WebKit |
| `input.mouse/key/insertText` | `Input.dispatchMouseEvent`, `Input.dispatchKeyEvent` (Playwright key table), `Input.insertText`; top-level coordinates reach OOPIFs |
| `input.drag` | `Input.setInterceptDrags` + `Input.dispatchDragEvent` |
| hidden-tab focus | `Emulation.setFocusEmulationEnabled {enabled: true}` while driven |
| `tab.navigate/history/reload`, `loadState` | `Page.navigate`, `Page.navigateToHistoryEntry`, `Page.reload`, `Page.lifecycleEvent` (networkidle from lifecycle) |
| dialogs, file choosers | `Page.javascriptDialogOpening` + `Page.handleJavaScriptDialog`; `Page.setInterceptFileChooserDialog` + `DOM.setFileInputFiles` (host writes files to a per-session temp dir) |
| capture | `Page.captureScreenshot`, `Page.printToPDF` (headless; CEF uses the app's `PrintToPDF`) |
| network, console | `Network.*`, `Runtime.consoleAPICalled`, `Runtime.exceptionThrown` |
| cookies | `Network.getCookies/setCookies/clearBrowserCookies` (page session; CEF per request context) |
| subresource policy | `Fetch.enable` patterns + `Fetch.failRequest`/`continueRequest` decided in Rust |
| `clipboard.*` (virtual) | not in phase 2: capability absent, the runtime throws the reference error text; listed as a gap |

## 3. Ownership and identity

| Entity | Owner | Writers |
| --- | --- | --- |
| browser tab record (placement, URL revision, title, profile, engine) | workspace store | store ops only; the host never writes it, a navigation the agent causes reaches it through the app's `browser.navigated` op |
| page runtime (live URL, loading, history stack, crash) | the Mac app that renders the page | the app; the host reads it through the driver |
| sessions, refs, VM, action log, recordings, policy, secret vault | browser host | host only; non-durable except logs |
| automation lease `{targetId, session, actor, on_behalf_of, origin, label, since}` | browser host | host; the app renders the badge and sends Stop as `browser.lease.release` with origin `user` |
| headless Chromium tabs on a VM | that VM's host | host |

- Every agent request carries `origin` (channel) and the host derives `actor`, `on_behalf_of` and agent class from the connection (launch credential locally; relayed principal remotely). Every driver call in the action log carries them. No request without an actor reaches a driver once the launch credential ships; until then requests are attributed as plain CLI (spec gap, identity-and-permissions.md section 6).
- Agent tabs open in the workspace's agent profile by default (D12). A session may opt in to a signed-in profile only with `profile: "signed-in"` on `browser.session.open`, which needs origin `user` or a mux grant, and shows on the lease badge.
- Remote control (D20): the host listener is local only. The daemon relay forwards `browser.*` runtime commands only for `mux` principals of the host's owner, and the host checks the relayed principal class again (defense in depth). Ordinary agents on other machines get `forbidden`. Enabling the relay family needs the written relay analysis and policy tests from the cmux-next CLAUDE.md.
- Focus: driving never changes view state. `tabs.open` opens background tabs; `tab.bringToFront` is refused unless origin is `user` or the call passes `focus: true` (OWNERSHIP-PRINCIPLES "Clients are projections"). The host never renames tab titles (15570's `session.name` label becomes the lease label shown in the badge).

## 4. Security (blocker before MCP or remote use)

Finding (research/browser-use.md, by reading): in 15570 the domain policy and secret masking are JS in the same context as agent code, and `__cmuxNative.driverCall` is reachable, so agent code skips both. Rules in the host:

1. The VM's `__cmuxNative.driverCall` is a Rust function that checks every call before any driver sees it: navigation targets (`tab.navigate`, `tabs.open`, `tab.history` results, popups through `tab.created`), `fetch` URLs, `file://`, `chrome://`, `about:` other than `about:blank`, TLS-error interstitials, `browser.cdp` (grant), and `frame.evaluate {world: "page"}` (allowed; page JS cannot widen the policy because it runs in the page, not the host).
2. Subresource policy is built in Rust: CDP `Fetch` interception decisions, and WebKit `contentRules` computed by Rust and sent by the host, never taken from VM code.
3. Policy writes: `browser.policy.set` needs origin `user` (or the session's creator mux within its grant) and can `lock`. VM code may only narrow (`session.allowedDomains` intersects the locked policy).
4. Passwords never reach the host or the VM: `auth.request` is a driver method that the app answers with its own sheet and its bundled fill script (#15570 site-tools.md "Secure sign-in"); the host forwards the request and returns only the status (`submitted`, `cancelled`, `unavailable`, `expired`, `origin_changed`, `page_changed`, `locator_invalid`, `submission_failed`). On headless Linux there is no sheet, so `auth.request` answers `unavailable`. Saved passwords and browser data import belong to Leo's cc-next-browser lane; the host has no API that reads them.
5. Other secret values live only in the Rust vault until typed. The VM sees `{__secret: name}` handles. Host-only work (focus checks, select-all, capture masking) runs in a third world, `cmux-host`, that VM code can never target (`frame.evaluate {world: "host"}` from the VM is refused); typing goes through native input after the host checks the focused frame (engine frame URL, never page JS) against the secret's domains. Once typed, only a sealed, freshly reloaded tab holds the value (decision 8). `input.insertText {text: handle}` and `fill` are resolved by the host after it checks the focused frame's origin (driver `frames.list` plus the agent world's focus report) against the secret's domains; TOTP codes are computed in Rust.
6. Masking runs in Rust on every byte leaving the host: print output, results, errors, spill files, action log, recordings, event payloads, MCP responses. Screenshot masking stays a driver step (the page agent covers secret-bearing fields), ordered by the host around capture calls.
7. Page text is untrusted: snapshot and markdown output mark page-sourced text; the host never follows instructions from page content (it has no model loop).
8. Same-uid processes outside cmux are outside this boundary (the control socket default is `automation`, D16); the boundary is the agent session and the MCP client.

Tests (failing first): a VM call to `__cmuxNative.driverCall("tab.navigate", {url: "https://blocked.example"})` under a locked policy fails `forbidden`; `JSON.stringify(globalThis)` and a walk of every reachable object never contains a user secret value; a secret typed into a non-matching frame fails; masking covers a secret split across two print calls and inside an error stack.

## 5. Conformance and performance gates

Backends added to `tests/browser-parity` (through the REPL session): `host-headless` (Rust host + headless Chromium over the pipe, runs in hosted Linux CI and on the Mac), `host-cef` and `host-webkit` (tagged no-activate app with the host). All use `cmux browser repl --eval -` per cell (until the Rust CLI verb exists: `cmux-browser-host eval --session NAME [--engine E] -`) with the engine from `browser.repl.open {engine}` or `CMUX_BROWSER_HOST_ENGINE`, so the suite gains backends, not a fork. Same goldens on every engine; a deliberate engine difference goes into `capabilities.json` with a reason, never a per-engine golden.

Gate for shipping the host in NIGHTLY (the in-app runtime is not ported): `gate.sh` green on `host-webkit` and `host-cef` twice in a row and on `host-headless` in CI; 0 cmux-worse in the differential cases; perf within 15% of 15570's in-app numbers (p50/p95 ms, real app: 50k elements 419/522, 200k elements 2224, 300 iframes 179/686, 10k-row table 392, live GitHub PR files 225) on WebKit, and reported separately for CEF; idle host near 0% CPU and 0 wakeups/s (`bench-idle.sh`).

## 6. Steps (each lands on feat-cmux-next with failing tests first)

| Step | Content | Verification |
| --- | --- | --- |
| a | crate `cmux-tui/crates/cmux-browser-host`: driver protocol types, `Driver` trait, CDP transport trait, pipe transport, `CdpDriver` (tabs, navigate, frames, agent world, evaluate, input, screenshot), provider frame codec, host listener skeleton | hosted `--filter browser_host`; a Chromium integration test in the cmux-tui workflow (Playwright Chromium, as the existing CDP smoke) |
| b | QuickJS-ng sessions with `__cmuxNative` v1, policy gate, secret vault, masking, Rust snapshot core with the JS reference switch | unit tests above; suite `host-headless` on a hosted runner |
| c | app side: `CmuxNextBrowserHost` provider bridge (connection, `hello`, WebKit call forwarding to the ported driver, CEF relay via the shim, lease badge, user-input pause); shim `cmux_shim_devtools_send` + message forwarder | `swift build --build-tests`, module tests with a fake host; tagged no-activate live run |
| d | conformance runner: `host-*` backends, `gate.sh` against both engines, perf bench vs 15570 | numbers per engine in this note |
| e | catalog entries for `browser.*` (owner `browser-host`), CLI verbs generated (request to session feat-cmux-next-99), MCP default group through `cmux mcp` | generated surfaces checked by the catalog tests |

Order change (binding surfaces above): the REPL session ops (`browser.repl.open/eval/close/list/reset`) and their three surfaces move forward. Step b lands them on the host listener together with the VM, and the CLI and MCP clients for them land right after b (CLI through session feat-cmux-next-99, MCP through the `cmux mcp` owner), before c. The discrete ops follow in e.

## 7. Prototype switches (DEV and NIGHTLY)

- `CMUX_BROWSER_SNAPSHOT_CORE=js|rust`: snapshot.js in the VM versus the Rust port; both must print byte-identical goldens.
- `CMUX_BROWSER_HOST_VM=quickjs|v8` (only if QuickJS misses the perf gate).

## 8. Not decided here, or UNVERIFIED

- QuickJS-ng speed on the runtime is unmeasured. CEF hidden-tab focus and hover under `Emulation.setFocusEmulationEnabled` is unverified. The Chromium sandbox on Freestyle VMs is unverified (never default to `--no-sandbox`).
- Virtual clipboard on CDP has no design yet (gap in section 2).
- Downloads on CEF come from the app's download handler, not CDP; the provider forwards them as driver events. Not yet specified frame by frame.
- Agent tabs outside the layout on the Mac stay out of phase 1 (spec open question).
