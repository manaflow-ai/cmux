# cmux next: browser REPL parity with classic

Lawrence (2026-10-23): "we had aside and chatgpt parity in cmux-classic, how much do we bring over to
cmux-next? ideally all of it, but rewritten in rust (for the parts that can be rewritten in rust)".

Owner: the computer and browser use lead. Classic = manaflow-ai/cmux `main` at dea5e18f130 (the Swift
REPL of PRs #15570 and #17256: `Packages/macOS/CmuxBrowser/Sources/CmuxBrowser/Repl/*`, 75 files).
Next = `feat-cmux-next` at 555ee92c747: the Rust host `cmux-tui/crates/cmux-browser-host`
(called `R/` below), its runtime JS (`J/` = `.../cmux-browser-host/js`), and the Swift WebKit driver
`Packages/macOS/CmuxNext/Sources/CmuxNextBrowserAutomation` (`W/`). The design is
[browser-host.md](browser-host.md). Section 2a there explains why the WebKit driver stays Swift.

## Summary

83 rows (each classic `Repl/*.swift` file, the CLI, the runtime JS, the parity tooling, and the
runtime features named separately):

| Status | Rows |
| --- | ---: |
| Ported to Rust | 32 |
| Ported to JS (runtime in QuickJS, page agent) | 1 (the whole runtime bundle) |
| Swift, must stay Swift (WebKit, AppKit, NSEvent, NSWindow) | 11 |
| Partial | 26 (2 more closed by this round, see below) |
| Missing | 13 (1 closed by this round) |

Of the partial and missing rows, 25 can move to Rust fully or partly. Only the WebKit-side parts
(content rule list install, NSEvent key release, the open panel, NSPrintOperation, WKPreferences)
must be Swift.

## Measured parity (Linux Testbox, Playwright Chromium 1200, 2026-10-24)

| Suite | Backend | Before (555ee92c747) | After (b3dd90d11d2, = 2d9dbc14431 after rebase) |
| --- | --- | --- | --- |
| `tests/browser-parity` scenarios | host-headless | 40/44 (2 known: 05-input, 39-policy-rules) | 41/44 (1 known: 39-policy-rules) |
| Differential cases (156 + 2 app-only, private repo) | host-headless through `cmux-browser-host eval` | 9 cmux-worse cases (6 vs Aside, 9 vs ChatGPT), 14 cases miss their expectation | 4 cmux-worse cases (1 vs Aside, 4 vs ChatGPT), 9 miss their expectation |
| `tests/browser-parity` scenarios | host-cef, host-webkit | not run: no fleet step (below) | not run |

The last recorded number (browser-host.md, 2026-10-04) was host-headless 11/37.

Real scenario failures left on host-headless: 32-agent-tools (a secret-masked screenshot:
`Page.captureScreenshot` times out after 30 s), 38-cookie-guards (`cookies.clear` under a domain
policy asks for a `targetId` where the golden says `blocked`, and the cells after it fail).

The JS suites of `gate.sh` on the same Linux box: unit 131/135 pass (2 fail: page-reply-budget
"every page agent export", tab-ownership "a user's tab: only events the agent handles"), sites
80/83 (googleCalendar.create twice, gmail.send reply). The same tests fail with the base page
agent, so they predate this round and are Linux-only or environment failures (not investigated
here).

How the differential cases were run: the cases, runner and scorer moved out of this repo to the
private repository `manaflow-ai/cmux-browser-parity-private` (#16818). Its
`browser-parity/diff/run.mjs check --backend cmux` was run with `PARITY_CMUX_CLI` pointing at a shim
that turns `cmux browser repl [--session S] --eval -` into `cmux-browser-host eval [--session S]
--engine headless -` against one `cmux-browser-host serve`. The shared `fixtures/` and `lib/` of
this repo's `tests/browser-parity` were linked in. `check` compares with the recorded Aside and
ChatGPT results, so it needs no sign-in. Without the `fixtures` link the dialog cases fail with a
404 page (a harness artifact, not a host bug); the first run had that fault and showed 13 cmux-worse cases, so the "before" column above is the run with the fixtures linked, with the two keyboard cases added back from the first run. The shim is not checked in: the cases must stay out
of public repos.

Differential failures left after this round (host-headless):

| Case | cmux-worse vs | What is missing in next |
| --- | --- | --- |
| `browser.history` | ChatGPT | `history.search` driver method: no browsing history on headless |
| `browser.capabilities` | ChatGPT | `page.cdp` is absent but throws a TypeError, not the "absent" error |
| `edge.detached-mid-click` | Aside, ChatGPT | press-target re-check (classic `BrowserReplPressTarget`, `expect`/`dropExpect` on `input.mouse`) |
| `tabs.claim-other-workspace` | ChatGPT | needs the cmux CLI (`new-workspace`); the shim has none, so not judged |
| `edge.ime-only-editor`, `edge.trusted-paste` | none (expectation only) | IME composition commit and a trusted rich paste from the tab clipboard |
| `edge.sessions-same-tab` | none | intentional: next's automation lease refuses a second session on a held tab |
| `edge.web-process-crash`, `edge.context-options` | none | the case needs app hooks (kill the web process) or the shim cannot pass `session.configure` |

## Landed in this round

| Commits | Change | Cases fixed |
| --- | --- | --- |
| e5b65eb0504 (red), 36d11ea98ff | The CDP driver sends the macOS editing commands on every platform, plus Meta+B/I/U (classic FormattingShortcut) | keyboard.shortcuts, edge.contenteditable-bold; scenario 05-input on Linux |
| 51c62a87d98 (red), 4f42fdb07ca | fs errors use Node's wording (`EACCES: permission denied, open 'p' (reason)`) | loc.set-input-files, filechooser.event |
| cdc30a8c323 (red), 2d9dbc14431 | A `window.open` popup with an opener gets a page agent for its real document (the global reused from about:blank kept the old agent) | edge.window-open |

Verification: on the Linux Testbox, the whole crate's tests (lib 338, real-Chromium 51), clippy
`-D warnings` and fmt passed at b3dd90d11d2, the pre-rebase head. The rebase onto 6abc8c09d04 brought other lanes' crate changes (host_runtime_tests.rs, cdp_driver_fake.rs and 5 more files); the landed head 2d9dbc14431 was not tested again on its own. On the macOS fleet (step 5908aec3e23),
`editing_commands_follow_mac_shortcuts` passed. The step is red only on a clippy error in
`cmux-tui-core` (`surface/tests/input.rs:166`, `fork_count_tests.rs:410`), a file this round does not
touch. Fleet step eb33a883388 (`fs_errors_read_like_node` on macOS) was still queued when this landed.

## Inventory

`R/` Rust host, `J/` runtime JS, `W/` Swift WebKit driver. Impact = how often an agent driving a
browser hits the gap. Size: S < 200 lines, M, L.

| Classic piece | Classic file | Next home | Status | Can move to Rust | Impact | Size |
|---|---|---|---|---|---|---|
| Navigation waits | BrowserAutomationNavigationCoordinator+BrowserRepl | W/LoadWaits.swift | Swift | no: WKNavigationDelegate | | |
| Agent user script | BrowserReplAgentUserScript | W/AgentWorld.swift; R/cdp/driver.rs | Swift (WebKit), Rust (CDP) | no: WKUserScript | | |
| Boundary (checks below the VM) | BrowserReplBoundary | R/gate.rs | Rust | | | |
| Bounded window | BrowserReplBoundedWindow | R/headless_routes.rs | partial: headless only | yes | low | S |
| Caller locality | BrowserReplCallerLocality | R/locality.rs, R/server.rs | partial: no PID-to-workspace trace | yes | low | S |
| Capture limits | BrowserReplCaptureLimits | none | missing | yes | medium | S |
| Capture mask | BrowserReplCaptureMask | R/gate/guards.rs | Rust | | | |
| Content rule lists (domain policy on WebKit) | BrowserReplContentRuleLists | none: `set_request_filter` is false for non-CEF tabs, so a policy session refuses WebKit tabs | missing | partly: compile in Rust, install in Swift | high | M |
| Cookie clear scope | BrowserReplCookieClearScope | R/cdp/cookies.rs, R/cookie_backups.rs, W/WebKitDriver+Cookies.swift | Rust | | | |
| Cookie match | BrowserReplCookieMatch | R/cdp/driver.rs | Rust | | | |
| Document authority | BrowserReplDocumentAuthority | R/provider_engine.rs, R/lease.rs, R/policy.rs | partial: no workspace-scoped verdict | yes | low | M |
| Document provenance | BrowserReplDocumentProvenance | none (CDP never loads a blocked document) | missing | partly | low | S |
| Domain policy | BrowserReplDomainPolicy | R/policy.rs, R/policy/*, R/policy_proxy.rs, R/headless_policy.rs | Rust (headless, CEF) | | | |
| Download ledger | BrowserReplDownloadLedger | R/cdp/downloads.rs, R/provider_downloads.rs | Rust | | | |
| Download source, session downloads | BrowserReplDownloadSource, BrowserReplSessionDownloads | R/cdp/downloads.rs | partial: no per-redirect policy check | yes | low | S |
| Drag pasteboard redirect | BrowserReplDragPasteboardRedirect | W/WebKitDrag.swift; R/cdp/drag.rs | Swift (replaced by synthetic drag) | no | | |
| Driver protocol | BrowserReplDriver | R/protocol.rs, R/driver.rs, W/DriverProtocol.swift | Rust | | | |
| Egress masking | BrowserReplEgress | R/gate.rs, R/secrets.rs | Rust | | | |
| Evaluation body | BrowserReplEvaluationBody | R/cdp/evaluate.rs, W/WebKitDriver+Frames.swift | Rust | | | |
| Fetcher | BrowserReplFetcher | R/gate/fetch.rs, R/gate/redirects.rs, R/cdp/fetch.rs | partial: no `net.fetch` on WebKit tabs | yes | medium | M |
| File sandbox, fs | BrowserReplFileSandbox, BrowserReplFileSystem | R/fs_sandbox.rs | partial: Node error wording now done; no openat walk (check-then-act race), no atomic copy staging | yes | medium | M |
| Frame | BrowserReplFrame | W/FrameTree.swift; R/cdp/state.rs | Swift (WebKit), Rust (CDP) | no | | |
| Frame binding | BrowserReplFrameBinding | W/WebKitDriver+FrameOwners.swift | Swift | no | | |
| Frame gate, focus containment | BrowserReplFrameGate | R/gate.rs, R/cdp/requests.rs | partial: no blocked-frame inertness on WebKit | partly | medium | M |
| Clipboard shortcut | BrowserReplFrameGate+ClipboardShortcut | R/cdp/clipboard.rs, W/WebKitClipboard.swift | Rust | | | |
| Editing shortcut | BrowserReplFrameGate+EditingShortcut | R/cdp/input.rs `editing_commands` | Rust (every platform since 36d11ea98ff) | | | |
| Formatting shortcut (Meta+B/I/U) | BrowserReplFrameGate+FormattingShortcut | R/cdp/input.rs `editing_commands` | Rust since 36d11ea98ff (CDP); missing on WebKit | WebKit: no | low | S |
| Frame registry | BrowserReplFrameRegistry | W/FrameRegistry.swift | Swift | no | | |
| HTTP credentials | BrowserReplHTTPCredentials | none | missing | yes for CDP (`Fetch.authRequired`) | medium | S |
| Held keys | BrowserReplHeldKeys | R/cdp/input.rs, R/cdp/state.rs | partial: WebKit releases nothing at session end | partly | medium | S |
| JS thread | BrowserReplJSThread | R/vm.rs | Rust | | | |
| Key stroke | BrowserReplKeyStroke | W/KeyStroke.swift; R/cdp/keys.rs | Swift (WebKit), Rust (CDP) | no | | |
| Latest value runner | BrowserReplLatestValueRunner | none | missing (needed with WebKit rule lists) | no | low | S |
| Method spec | BrowserReplMethodSpec | R/gate.rs, R/provider_engine.rs | partial: no default-deny table per method | yes | low | M |
| Mouse event plan | BrowserReplMouseEventPlan | W/MouseEventPlan.swift; R/cdp/input.rs | Swift (WebKit), Rust (CDP) | no | | |
| Network gate | BrowserReplNetworkGate | R/cdp/network.rs | partial: no per-document filter; WebKit sends no request events | partly | high | M |
| PDF | BrowserReplPDFPrinter | R/cdp/pdf.rs, W/WebKitDriver+Capture.swift | partial: WebKit prints one tall page | no | low | S |
| Page clipboard guard | BrowserReplPageClipboard | R/cdp/clipboard.rs, J/page-clipboard.js | partial: not on WebKit | no | medium | S |
| Page telemetry | BrowserReplPageTelemetry | R/cdp/state.rs, W/PageConsole.swift | Rust | | | |
| Page URL (credential-free) | BrowserReplPageURL | none | missing | yes | low | S |
| Pending prompt, `auth.request` | BrowserReplPendingPrompt | J/sites/browser-auth.js calls it; no handler | missing | partly: state in Rust, sheet in Swift | medium | M |
| Permission requests | BrowserReplPermissionRequest | R/headless_configure.rs | partial: app tabs leave prompts to the person | partly | low | S |
| Pinned file loads | BrowserReplPinnedFileLoads | none (`file:` forbidden by design) | missing | yes | low | M |
| Pointer owner | BrowserReplPointerOwner | R/lease.rs | Rust (replaced by the lease) | | | |
| Policy board | BrowserReplPolicyBoard | R/cdp/requests.rs, R/policy_proxy.rs | Rust | | | |
| Popups | BrowserReplPopupOpening | R/headless_source.rs, R/cdp/driver.rs; page agent fix 2d9dbc14431 | Rust | | | |
| Press target | BrowserReplPressTarget | none | missing | partly | medium | M |
| Proxy stores | BrowserReplProxyStores | R/headless_configure.rs, R/headless_policy.rs | Rust (headless) | | | |
| Public suffix list | BrowserReplPublicSuffixList | R/policy.rs `site_of` (short hard-coded list) | partial | yes | medium | S |
| Resource ledger | BrowserReplResourceLedger | R/host.rs, R/gate.rs, R/gate/fetch.rs | partial: no disk quota | yes | low | M |
| Routed requests | BrowserReplRoutedRequests | R/headless_routes.rs | partial: not on provider tabs | yes | medium | S |
| Runtime bundle | BrowserReplRuntimeBundle | R/host.rs, build.rs, J/manifest.json | Rust | | | |
| Script heap | BrowserReplScriptHeap | R/vm.rs | Rust | | | |
| Script probe | BrowserReplScriptProbe | W/WebKitPrivateCalls.swift, W/CallDeadline.swift | Swift | no | | |
| Secret scanner | BrowserReplSecretScanner | R/secrets.rs `Masker` | partial: no Base64, double-percent, numeric entity forms | yes | medium | M |
| Secret store | BrowserReplSecretStore | R/secrets.rs, R/gate.rs | partial: user secrets refused (no sealed tab) | yes | high | L |
| Secret target | BrowserReplSecretTarget | R/gate.rs | Rust | | | |
| Session | BrowserReplSession | R/host.rs, R/vm.rs | Rust | | | |
| Session registry | BrowserReplSessionRegistry | R/host.rs, R/host/idle.rs | partial: no workspace key | yes | low | S |
| Session world | BrowserReplSessionWorld | one shared agent world | partial | partly | low | S |
| Subframe load hold | BrowserReplSubframeLoadHold | R/cdp/requests.rs | partial: not on WebKit | no | low | S |
| Tab clipboard | BrowserReplTabClipboard | R/cdp/clipboard.rs, W/WebKitClipboard.swift | Rust | | | |
| Tab ownership | BrowserReplTabOwnership | R/provider_engine.rs, R/tab_source.rs | Rust | | | |
| Tab waker | BrowserReplTabWaker | W/WebKitDriver.swift, AppBrowserHostTabs.swift | Swift | no | | |
| Text commit (IME) | BrowserReplTextCommit | W/WebKitNativeInput.swift | partial | no | low | S |
| Time limit | BrowserReplTimeLimit | R/cdp/evaluate.rs, W/CallDeadline.swift | Rust | | | |
| Timers | BrowserReplTimerScheduler | R/vm.rs | Rust | | | |
| Typed secrets | BrowserReplTypedSecrets | R/gate.rs, R/secrets.rs | Rust | | | |
| Unfinished loads | BrowserReplUnfinishedLoads | R/cdp/network.rs | Rust | | | |
| Upload staging, file chooser | BrowserReplUploadStaging | R/cdp/choosers.rs, W/WebKitSetFiles.swift | partial: no chooser events on WebKit | partly | medium | S |
| Watchdog | BrowserReplWatchdog | R/vm.rs interrupt handler | Rust | | | |
| Workspace binding | BrowserReplWorkspaceBinding | app chooses the profile | partial | yes | low | S |
| Data store id | WKWebsiteDataStore+BrowserReplID | R/headless_configure.rs | Rust | | | |
| CLI | CLI/CMUXCLI+BrowserRepl.swift | R/host.rs ops, cmux-tui `cli/mcp/browser_tools.rs` | Rust | | | |
| Runtime JS | Resources/browser-repl/* | J/ (same files) | JS | | | |
| Stale-cell refusal | async-owner.js | J/repl-host.js only mutes a cancelled cell | partial | yes | medium | S |
| User agent policy | session.configure userAgent | R/headless_configure.rs, R/cdp/overrides.rs | partial: not on app tabs | partly | low | S |
| Network egress (private ranges) | none in classic | R/egress_* | Rust (new in next) | | | |
| Offscreen render | session and driver | CmuxNextBrowserHost AgentRenderWindows.swift | Swift | no | | |
| JS dialogs | session and driver | R/cdp/state.rs, W/DialogBroker.swift | Rust | | | |
| Differential cases and runner | tests/browser-parity/diff | manaflow-ai/cmux-browser-parity-private | moved out (private) | no: Node harness | low | M |
| Scorer | diff/report.mjs | private repo | moved out | no | low | S |
| Capability map | capabilities.json | private repo | moved out | no | low | S |

## Next ports, by agent impact

1. Domain policy on WebKit tabs: compile the policy into WebKit content-rule JSON in a new
   `R/policy/webkit_rules.rs`, send it as a provider frame, install it in Swift. Today a policy
   session cannot use a WebKit tab at all.
2. Secret store for user secrets (the sealed tab of browser-host.md decision 8) and the one-pass
   scanner with classic's encoded forms (`R/secrets.rs`).
3. WebKit driver methods the host still lacks: `net.fetch` with tab cookies (Rust over
   `cookies.get`), request routing on provider tabs (Rust, as `R/headless_routes.rs`), held-key
   release at session end (tracking in Rust).
4. Network events for WebKit tabs and a per-document filter in `R/cdp/network.rs`.
5. Press-target re-check (`expect` on `input.mouse`): JS runtime plus a check in `R/cdp/input.rs`
   (closes `edge.detached-mid-click`).
6. HTTP credentials on CDP (`Fetch.authRequired`, new `R/cdp/auth.rs`) and an `auth.request`
   handler.

## Not measured: host-cef and host-webkit

These backends need a tagged no-activate cmux-next app on a Mac connected to the host. The fleet
controller's step allowlist (hq `build-fleet/cmd/controller/ci_step.go`) has no step that builds a
tagged app and runs `tests/browser-parity/run.mjs check --backend host-cef|host-webkit`. Measuring
them needs a `scripts/measure/browser-parity-hosts.sh` here (the `agent-engine.sh` shape: tagged
`reload.sh`, then the runner with `PARITY_HOST_CLI`) and its allowlist entry in hq. This round did
not bypass the scheduler over SSH.
