# cmux next: browser host (agent browser use, WebKit and Chromium)

Design note, 2026-10-01. Owner: the cmux-next browser-use lead. Binding inputs: cmux-next-spec `spec/browser-use.md` (draft 2), `decisions.md` D12 and D20, `references/browser-use.md`, `references/browser-repl-inventory.md`; OWNERSHIP-PRINCIPLES.md; browser.md (CEF fork, shim, R2). Base implementation: PR https://github.com/manaflow-ai/cmux/pull/15570 (`cmux browser repl`, owner session feat-browser-repl-parity-8c, called "the REPL session" below). Its `docs/browser-repl/driver-protocol.md` is the contract this note builds on; its `tests/browser-parity` is the conformance suite. This note does not change either; changes to them go to the REPL session through the coordinator.

## Decisions for Lawrence

1. **Who starts the host, and how the app reaches it.** Recommended: the local daemon (cmux-tui) supervises one `cmux browser host` per machine, and the Mac app dials the host as an *engine provider* over a dedicated authenticated connection. The WebKit driver calls and the CEF CDP relay run on that connection. Nothing is added to the app control socket, so other same-uid automation clients cannot call the WebKit driver or inject CDP and skip host policy. Sessions survive an app restart (the provider reconnects and re-announces its tabs). Alternative: the app spawns the host as a child with an inherited socketpair (simpler, but sessions die with the app and Linux needs a second launcher). The spec text "relay CDP through the app's authenticated control socket" becomes "through the app's provider connection to the host" under the recommendation.
2. **Who ports the Swift WebKit driver onto `CmuxNextBrowser`.** Recommended: the REPL session ports `WebKitBrowserReplDriver` and `CmuxBrowser/Repl` (it owns that code) into a new `CmuxNextBrowserAutomation` module that implements the driver protocol against `BrowserTab`; the browser-use lead owns the provider bridge (`CmuxNextBrowserHost` module: connection, framing, lease badge, CEF relay) and the Rust host. Alternative: the browser-use lead ports the driver too, with the REPL session reviewing.
3. **Agent-supplied secrets.** `secrets.set(name, value)` from agent code puts the value into the JS VM, because the agent already has it. Recommended: allowed, but marked `agent_known` (masking only, never shown as "protected"); secrets the user supplies (`cmux browser secrets load`, Keychain) never enter the VM and are typed by the host from a handle. Alternative: refuse `secrets.set` from agent code entirely. Passwords are not secrets in this sense (coordinator, 2026-10-01, Leo's cc-next-browser lane owns import and passwords): agents never see a password; they use the Secure sign-in sheet (#15570 `docs/browser-repl/site-tools.md`, `sites.browserAuth.request`) and get only a status.
4. **Conformance suite home.** The suite must run against the Rust host before #15570 lands on feat-cmux-next. Recommended: the REPL session re-targets #15570 (runtime, docs, suite) onto feat-cmux-next first, without the legacy Swift; the host consumes `Resources/browser-repl` from there. Until then the host's runner points at a read-only checkout of the suite (`--suite <path>`); nothing is copied.
5. **Default for `cmux browser repl` once the host exists.** Recommended: DEV and NIGHTLY switch `CMUX_BROWSER_REPL_BACKEND=host|inapp` (default `host` in DEV, `inapp` in NIGHTLY until the conformance and perf gates below pass on both engines), then delete the in-app JSContext runtime.

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

### Provider connection (app ↔ host)

Framing: length-prefixed JSON (u32 big-endian length, then UTF-8 JSON), one frame per message, both directions, max 64 MiB (screenshots). Frames:

| Frame | Direction | Meaning |
| --- | --- | --- |
| `hello {version, provider_id, install_id, engines: ["webkit","cef"], tabs: [TabAnnounce]}` | app → host | first frame; `TabAnnounce = {targetId, engine, workspace, profile, url, title, visible}` |
| `call {id, method, params}` / `result {id, result? , error?}` | host → app / app → host | driver protocol method on a WebKit tab (methods, params and errors exactly as driver-protocol.md) |
| `event {name, payload}` | app → host | driver protocol event (`tab.created`, `dialog.opened`, …) and provider events (`tab.announced`, `tab.gone`) |
| `cdp.attach {targetId}` / `cdp.detach {targetId}` | host → app | start or stop relaying a CEF tab's DevTools session |
| `cdp {targetId, message}` | both | one raw CDP message (string), passed through unparsed by the app |
| `lease {targetId, lease?}` | host → app | show or clear the "driven by" badge; the app never shows a lease it did not receive |
| `user.input {targetId}` | app → host | a person pressed a key or clicked in a leased tab; the host pauses that lease (spec risk "human and agent input") |

Authentication: the daemon mints a per-launch provider secret when it starts the host and hands it to the app over the app's existing trusted daemon connection; the app proves it in `hello` and the host also checks peer credentials (same uid). A provider connection is never accepted from the agent listener. The host refuses a second provider with the same `install_id` (one app per install) and replaces it only after the first disconnects.

CEF relay: the shim gains `cmux_shim_devtools_send(browser_id, message_json)` (`CefBrowserHost::SendDevToolsMessage`, raw JSON with its own `id` and optional `sessionId`) and forwards every `CefDevToolsMessageObserver::OnDevToolsMessage` for attached browsers as a new shim event. Raw messages keep flat sessions, so out-of-process iframes work through `Target.setAutoAttach {flatten: true}`. The existing `cmux_shim_devtools_call` path stays for the app's own uses (previews, occlusion snapshots). Header edit changes the shim ABI identity (browser.md "CEF shim ABI identity"); the relay needs no fork change.

### Agent protocol (host listener)

Catalog ops (owner `browser-host`), the runtime command list in spec/browser-use.md "APIs and ops": `browser.session.open/list/reset/close`, `browser.eval {session, code, max_output}`, `browser.snapshot`, `browser.screenshot`, `browser.wait`, `browser.dialog.respond`, `browser.filechooser.respond`, `browser.download.list/path`, `browser.cookies.*`, `browser.storage_state.save/load {scope}`, `browser.policy.set` (user origin only), `browser.secrets.load/list/delete` (user origin only), `browser.record.start/stop`, `browser.trace.export`, `browser.lease.take/release`, `browser.cdp` (grant), `browser.act` (fixed tool mode, opt-in). Framing: the cmux-tui request envelope (`{id, method, params, origin, idempotency_key?}`, `request-settled`), so the generated CLI and MCP clients reuse their transport. Runtime commands are at-most-once by request id; an input call whose result is lost is reported `ambiguous` and never replayed.

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
5. Other secret values live only in the Rust vault. The VM sees `{__secret: name}` handles. `input.insertText {text: handle}` and `fill` are resolved by the host after it checks the focused frame's origin (driver `frames.list` plus the agent world's focus report) against the secret's domains; TOTP codes are computed in Rust.
6. Masking runs in Rust on every byte leaving the host: print output, results, errors, spill files, action log, recordings, event payloads, MCP responses. Screenshot masking stays a driver step (the page agent covers secret-bearing fields), ordered by the host around capture calls.
7. Page text is untrusted: snapshot and markdown output mark page-sourced text; the host never follows instructions from page content (it has no model loop).
8. Same-uid processes outside cmux are outside this boundary (the control socket default is `automation`, D16); the boundary is the agent session and the MCP client.

Tests (failing first): a VM call to `__cmuxNative.driverCall("tab.navigate", {url: "https://blocked.example"})` under a locked policy fails `forbidden`; `JSON.stringify(globalThis)` and a walk of every reachable object never contains a user secret value; a secret typed into a non-matching frame fails; masking covers a secret split across two print calls and inside an error stack.

## 5. Conformance and performance gates

Backends added to `tests/browser-parity` (through the REPL session): `host-headless` (Rust host + headless Chromium over the pipe, runs in hosted Linux CI and on the Mac), `host-cef` and `host-webkit` (tagged no-activate app with the host). All use the existing `cmux` backend path (`cmux browser repl --eval -` per cell) with `CMUX_BROWSER_REPL_BACKEND=host`, so the suite gains a backend switch, not a fork. Same goldens on every engine; a deliberate engine difference goes into `capabilities.json` with a reason, never a per-engine golden.

Gate for flipping the NIGHTLY default (decision 5): `gate.sh` green on `host-webkit` and `host-cef` twice in a row and on `host-headless` in CI; 0 cmux-worse in the differential cases; perf within 15% of 15570's in-app numbers (p50/p95 ms, real app: 50k elements 419/522, 200k elements 2224, 300 iframes 179/686, 10k-row table 392, live GitHub PR files 225) on WebKit, and reported separately for CEF; idle host near 0% CPU and 0 wakeups/s (`bench-idle.sh`).

## 6. Steps (each lands on feat-cmux-next with failing tests first)

| Step | Content | Verification |
| --- | --- | --- |
| a | crate `cmux-tui/crates/cmux-browser-host`: driver protocol types, `Driver` trait, CDP transport trait, pipe transport, `CdpDriver` (tabs, navigate, frames, agent world, evaluate, input, screenshot), provider frame codec, host listener skeleton | hosted `--filter browser_host`; a Chromium integration test in the cmux-tui workflow (Playwright Chromium, as the existing CDP smoke) |
| b | QuickJS-ng sessions with `__cmuxNative` v1, policy gate, secret vault, masking, Rust snapshot core with the JS reference switch | unit tests above; suite `host-headless` on a hosted runner |
| c | app side: `CmuxNextBrowserHost` provider bridge (connection, `hello`, WebKit call forwarding to the ported driver, CEF relay via the shim, lease badge, user-input pause); shim `cmux_shim_devtools_send` + message forwarder | `swift build --build-tests`, module tests with a fake host; tagged no-activate live run |
| d | conformance runner: `host-*` backends, `gate.sh` against both engines, perf bench vs 15570 | numbers per engine in this note |
| e | catalog entries for `browser.*` (owner `browser-host`), CLI verbs generated (request to session feat-cmux-next-99), MCP default group through `cmux mcp` | generated surfaces checked by the catalog tests |

## 7. Prototype switches (DEV and NIGHTLY)

- `CMUX_BROWSER_REPL_BACKEND=host|inapp`: the host versus 15570's in-app JSContext runtime, same CLI.
- `CMUX_BROWSER_SNAPSHOT_CORE=js|rust`: snapshot.js in the VM versus the Rust port; both must print byte-identical goldens.
- `CMUX_BROWSER_HOST_VM=quickjs|v8` (only if QuickJS misses the perf gate).

## 8. Not decided here, or UNVERIFIED

- QuickJS-ng speed on the runtime is unmeasured. CEF hidden-tab focus and hover under `Emulation.setFocusEmulationEnabled` is unverified. The Chromium sandbox on Freestyle VMs is unverified (never default to `--no-sandbox`).
- Virtual clipboard on CDP has no design yet (gap in section 2).
- Downloads on CEF come from the app's download handler, not CDP; the provider forwards them as driver events. Not yet specified frame by frame.
- Agent tabs outside the layout on the Mac stay out of phase 1 (spec open question).
