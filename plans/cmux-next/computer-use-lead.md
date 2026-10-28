# Computer use and browser use lead: gaps, Rust-first plan, onboarding, dogfood

Plan, 2026-10-23. Owner: the "Computer & browser use lead" agent (a618). Ask (Lawrence,
2026-10-23): "we need to make computer use and browser use very good, both on macOS and linux
(cmux cloud). there's a lot of stuff we can build on top of, but we want as much in rust as
possible. browser-use probably has a lot of things hardcoded to specific sites to make it
useful, and we need to dogfood and test a lot more stuff for cua-driver such that we have a
better onboarding flow etc".

Related: [computer-use.md](computer-use.md) (CUA host, activity store), [automation-bench.md](automation-bench.md)
(one scoreboard), [automation-lease.md](automation-lease.md), [chief-browser-use-DESIGN.md](chief-browser-use-DESIGN.md)
(`cmux browser right`), [browser-host.md](browser-host.md) (Rust browser host), [cloud-browser-DESIGN.md](cloud-browser-DESIGN.md),
[onboarding.md](onboarding.md). This note ranks the work; it does not replace those designs.

## 1. What exists today (audit, 2026-10-23, feat-cmux-next 21fbece36ce)

### Browser use: two stacks on macOS, a third-party one on Linux

| Surface | Code | Language | Snapshot | Input |
| --- | --- | --- | --- | --- |
| `cmux browser <tab_…\|page\|right> <verb>` (what Chiefs and agents use today) | CLI `cmux-tui/crates/cmux-tui/src/cli/app/page.rs`, `right.rs`; app `Packages/macOS/CmuxNext/Sources/CmuxNextControl/Browser/*` (about 2,900 lines) | Rust CLI, Swift service, injected JS | `BrowserPageScripts.snapshot`: a 30-line tag walker, writes `data-cmux-ref` into the page DOM, no frames, no shadow roots | script events (`el.click()`, synthetic pointer events, `value=` setter); native input only for the raw `mouse/wheel/key/insert_text` verbs |
| Browser REPL / host (`browser_repl_*` MCP, `cmux-browser-host`) | `cmux-tui/crates/cmux-browser-host` (about 37k lines incl. tests), `js/page-agent.js`, `snapshot.js`, vendored Playwright injected script, `js/sites/*` | Rust (CDP driver, QuickJS VM, policy, vault, lease) + JS | Playwright aria snapshot per frame, OOPIF auto-attach, open and closed shadow roots, diffs | CDP `Input.*`, file choosers, dialogs (DialogBroker), downloads |
| Cloud VMs (Linux) | `web/services/vms/images/devbox/Dockerfile` | third-party `agent-browser@0.39.1` + Google Chrome | not ours | not ours |

Engines: in-app Chromium (CEF, the default `browser.defaultEngine = chromium`) with raw CDP relayed
over the provider socket (`CEFAgentRelay`, `ProviderDevToolsRelay`), WKWebView through
`CmuxNextBrowserAutomation`, headless Chromium with `--remote-debugging-pipe` for the host on Linux.

### Computer use: two drivers on macOS, one shared Xvfb on Linux

| Part | Code | Language |
| --- | --- | --- |
| Legacy driver (default `computerUse.driver = legacy`) | `manaflow-ai/cmux-cua` `libs/cmux-cua/rust`, pinned v0.8.12 `e8a8dbfd` in `scripts/build-cmux-cua.sh`; "cmux Computer Use.app" `com.cmuxterm.cua` | Rust |
| Helper v2 (`driver = upstream`) | upstream `trycua/cua` `cua-driver-rs-v0.34.0` as `libcua_driver_sdk.dylib`, Swift helper `Packages/macOS/CmuxComputerUseHelper` (dlopen, admission) | Rust engine, Swift host |
| Agent wiring | acpmux `src/agent_tools.rs:469-509` gives every agent a `cmux-cua` MCP server; `cua_v2.rs` is a pass-through bridge | Rust |
| App | `CmuxNextComputerUse/ComputerUseHelperDaemon.swift`, `ComputerUseHelperV2*.swift`, onboarding `CmuxNextOnboarding/Steps/ComputerUseStepView.swift`, Agent Activity pane | Swift |
| Linux VM | `images/cmux-vm/inputs.lock.json` pins cmux-cua **0.8.7**; one Xvfb `:99` + `cmux-cua serve` systemd units, dev snapshots only (`web/scripts/cmux-vm-image/agent-tools.ts`); acpmux hands out `CMUX_CUA_DISPLAY=:N` per workspace but nothing starts those displays | TS image script, Rust driver |

Rust share today: the CLI, the browser host, both CUA engines and acpmux are Rust. The per-tab page
service (the path agents actually use), the CUA helper host and all onboarding are Swift; the page
logic itself is injected JS strings inside Swift.

## 2. Measured on the live NIGHTLY (1.0.0-nightly.3997257646201, macOS 27.0)

Dogfood run (section 5), 2026-10-23, own agent tab beside this chat, 25 tasks:
**18 of 25 passed (72 percent)**. Rows: `artifacts/dogfood/before-nightly-3997257646201.jsonl`
(local, not committed). Failures:

| Task | What broke | Cause |
| --- | --- | --- |
| fresh-tab-wait | `wait --load-state complete` on a tab `cmux open` made in the background timed out after 40 s with `last_error: "closed"`, while `eval` on the same tab worked | `AppBrowserPage.run` created the Chromium browser for `.evaluate` but not `.evaluateAsync` (every page wait and the human-click walk) |
| internet-hover | hover never opened the caption | hover sent script `mouseover` only; CSS `:hover` needs the engine's pointer |
| hn-vote-arrow-named | HN vote arrows are `link` with no name | the name rule ignores a child's `title`/`alt`/`aria-label` |
| internet-iframe-snapshot | text inside a same-origin iframe is missing | the snapshot does not enter frames or shadow roots |
| internet-new-window | a `target=_blank` popup became a tab stuck at `about:blank`, and the next two calls answered `not_run` after 2 s | a background Chromium tab never loads until something creates its browser; the app's main actor was busy for about 4 s while the popup tab was made |
| todomvc-add | `navigate` answered `not_run` | same stall as above (the task after the popup) |
| github-issues-tab | the selector was wrong (GitHub's markup changed) | task bug, fixed in tasks.json |

Other findings in the same session:

- `cmux browser open URL` and `cmux pane … split` from an agent terminal answer
  `socket.unreachable` (they go to a cmux-tui daemon session socket that is not running) while
  `cmux open URL` works. An agent following `cmux browser --help` fails at step 1.
- Snapshot refs in `--json` are a map keyed `e1, e10, e100, …`; order lives only in the text form.

## 3. Ranked gaps

| # | Gap | Evidence | Fix | Where (Rust first) |
| --- | --- | --- | --- | --- |
| 1 | Page waits fail on background Chromium tabs | section 2 | create the browser for every page script (landed, section 7) | Swift gate now; moves with gap 3 |
| 2 | Cloud VMs do not run cmux's browser or a current CUA | Dockerfile:246 `agent-browser`; cmux-cua 0.8.7 vs 0.8.12; `cmux-rd` missing; `cmux-remote-browser-host` macOS only | ship `cmux-browser-host` (headless Chromium, already Rust, Linux targets in browser-host.md 6d) and the same cmux-cua pin in the VM image; one pin file for both OSes | Rust |
| 3 | Two browser stacks; the one agents use is the weak one | section 1 table | route `browser.page.*` for Chromium tabs through the Rust host's CDP driver and snapshot (the REPL's page-agent) over the existing CEF DevTools relay; WebKit keeps the Swift driver behind the host's driver protocol. Then the CLI verbs, the REPL and Linux share one implementation | Rust (`cmux-browser-host`) |
| 4 | Agent input is script events, not trusted input | `BrowserPageScripts.click` uses `el.click()`; hover was script-only | click, hover, type, press through CDP `Input.*` (Chromium) and the WebKit native path, with hit-test before click (browser-use `default_action_watchdog.py:574-942`), fallback to script events | Rust once gap 3 lands; Swift native path now |
| 5 | Snapshot quality | names, frames, shadow DOM, states, select options missing | improved walker now (helper agent, section 7); then the host's aria snapshot + Rust distiller pass (Playwright `ariaSnapshotDistiller.ts`) and browser-use's paint-order occlusion filter and `*` new-element markers | JS now, Rust distiller next |
| 6 | No dialogs, downloads or cross-origin iframes on the CLI path | AUDIT.md:91-93 | Playwright MCP's "modal state" (a pending dialog or file chooser blocks other actions until handled); `Browser.setDownloadBehavior` + a `downloads` verb; OOPIF via flat `Target.setAutoAttach` keyed by `(sessionId, backendNodeId)` | Rust (host already has all three) |
| 7 | Background tabs do not load until touched; a popup stalls the app about 4 s | section 2 | an agent-opened or page-opened tab creates its browser at once (agents drive hidden tabs); `tabs` reports the pending URL; profile the 4 s stall | Swift (CEF lifecycle) |
| 8 | `cmux browser open` / `pane split` unreachable from agent terminals | section 2 | the CLI routes topology verbs to the app when no daemon session runs, as `cmux open` does | Rust CLI |
| 9 | CUA v2 helper is a pass-through, dev-signed only; onboarding sees only the legacy helper | `HelperSocketServer.swift:165-170`, `ComputerUseHelperV2.swift:36-37`, `ComputerUseSetup.swift:297-302` | pick one engine (decision D1), give it `permissions_status`, activity and lease, sign it Developer ID in nightly | Rust engine, thin Swift host |
| 10 | No action-scoped network settle | load states are `interactive`/`complete` only | Playwright `waitForCompletion` (`tools/backend/utils.ts:20-56`): after an action, wait for the requests it started (load 10 s, fetch/xhr 5 s, 500 ms settle) | Rust |
| 11 | Linux per-workspace displays not started; one shared `:99` | `agent-tools.ts:132-135` | session host starts `Xvfb :N` per workspace on demand; the X11 backend opens one connection per display | Rust |
| 12 | No pass rates anywhere | automation-bench.md b2-b5 open | this note's dogfood suite on every change, then the model-driven Online-Mind2Web subset | Python runner now, Rust host bench later |
| 13 | Lease: Swift (90 s, no pause on user input) and Rust (state machine) differ | `BrowserPageService+Lease.swift:19`, `lease.rs` | one lease: the Rust reducer in `cmux-cua-core`/browser host, the app reads it | Rust |
| 14 | Cookie banners, consent walls, captchas | none in code | see section 4: a small rule set, not site hacks; captchas go to the person | Rust rules data + JS |

## 4. What browser-use, Stagehand and Playwright MCP do, and what we port

Sources read at browser-use `3df5806`, Stagehand `8023f34`, Playwright (MCP backend moved into
`microsoft/playwright` `packages/playwright-core/src/tools/backend/`), anthropic-quickstarts
`930ad10`, trycua/cua `c9321b9`.

Site-specific code in browser-use is small; its strength is general technique:

- Hardcoded sites: search URL templates for DuckDuckGo, Google (`&udm=14`) and Bing
  (`tools/service.py:471-473`); DuckDuckGo default "because less captchas" (`tools/views.py:52`);
  it loads uBlock Origin, "I still don't care about cookies" and ClearURLs extensions
  (`browser/profile.py:1034-1044`) instead of writing banner code; a captcha keyword list
  (`agent/service.py:2196`); pagination words in five languages (`dom/service.py:1185`); class/id
  "search" counts as clickable (`clickable_elements.py:77-103`); jQuery/Bootstrap date-picker class
  names (`default_action_watchdog.py:1656-1667`); print buttons.
- General techniques: a merged DOM + DOMSnapshot + AX snapshot per frame; clickable heuristics
  (form tags, onclick/tabindex, ARIA and AX roles, `getEventListeners`); paint-order occlusion
  filter; containment pruning (a child 99 percent inside a link or button folds into it); stable
  indexes keyed by `(session, backendNodeId)` with `*` on new elements; select options inline;
  scroll-into-view, hit-test, real mouse events; new-tab detection by tab diff; auto-accept dialogs;
  `DOM.setFileInputFiles`; download tracking; direct value set for date/range inputs.
- Stagehand: hybrid AX + DOM snapshot with `frameOrdinal-backendNodeId` ids, deep locators across
  iframes and shadow roots, self-heal (fresh snapshot, ask again, retry), an action cache (server
  side; we design our own key: instruction + URL pattern + AX neighbourhood -> xpath + action).
- Playwright MCP: aria snapshot with refs only on visible, pointer-receiving elements; a distiller
  pass; modal state for dialogs and file choosers; `waitForCompletion` network settle; vision tools
  `browser_mouse_*_xy` as a fallback.
- Desktop: Anthropic's demo scales screenshots to XGA/WXGA and maps coordinates back, types in
  50-character chunks, zooms by cropping the full-resolution frame; cua-driver indexes AX elements
  that have an action or a writable value, sets `AXManualAccessibility` so Chromium/Electron expose
  their tree, posts background input with `SLEventPostToPid`, and on Linux uses XSendEvent/XTest
  and sets AT-SPI `ScreenReaderEnabled`.

Port order into Rust (`cmux-browser-host`, which already has the CDP driver and frame registry):

1. Flat auto-attach sessions keyed by `(sessionId, backendNodeId)` for OOPIFs, popups, downloads (host has most of it; make the CLI path use it, gap 3).
2. Merged snapshot per frame (DOM, DOMSnapshot, AX) feeding the aria snapshot.
3. Clickable heuristics, visibility through frames, containment pruning (pure tree passes, Rust).
4. Stable indexes with new-element markers.
5. Paint-order occlusion filter.
6. Action-scoped network settle (gap 10).
7. Click pipeline: scroll, hit-test, CDP mouse, new-tab and download detection.
8. Modal state for dialogs and file choosers.
9. Distiller pass in Rust over the injected Playwright aria tree.
10. Input special cases: date/range direct set, native select options, `setFileInputFiles`.
11. Self-heal and a local action cache.
12. Vision fallback with coordinate scaling; cua-driver for desktop.

Cookie banners and consent walls (decision D3): no per-site code. A data file of consent-manager
selectors (OneTrust, Cookiebot, Didomi, Quantcast, TrustArc, Sourcepoint, Usercentrics, the
IAB TCF `__tcfapi` reject call) read by the Rust host, applied only when the agent asks
(`dismiss-consent` verb) or the task policy allows it, always choosing "reject all / necessary
only". We do not bundle third-party extensions (licence, update channel and the person's own
browsing). Captchas, sign-ins, passkeys and payments go to the person (`escalate_auth`, the
`passkey` verb); agents never solve or type them.

## 5. Dogfood suite and pass rates

`tests/automation-bench/dogfood/` (landed): `tasks.json` holds 25 tasks on real public sites
(HN, Wikipedia, DuckDuckGo, GitHub, httpbin, the-internet.herokuapp.com, TodoMVC, MDN), each with
a programmatic end-state check; `browser_dogfood.py --tab tab_…` drives only `cmux browser` verbs
and writes automation-bench rows (`driver: cmux-browser-cli`, `live: true`). Run it in an agent tab
beside the agent's own chat, never on the person's shown tab.

| Run | macOS | Linux cloud VM |
| --- | --- | --- |
| before: NIGHTLY 1.0.0-nightly.3997257646201, 2026-10-23 | 18/25 (72%) | not runnable: no `cmux browser` on VMs (gap 2) |
| after (this lead's fixes) | section 7 | section 7 |

Next suites (same row shape, same scoreboard):

- Desktop (cua): 20 tasks on fixture apps plus TextEdit, Calculator, Finder, System Settings
  (read-only panes), Safari, an Electron app; checks by AX value, file contents and frontmost-app
  unchanged (focus kept). macOS on a fleet mini with the helper granted; Linux on a cloud VM with
  Xvfb (gedit, xterm, Chromium, LibreOffice).
- Task level: the Online-Mind2Web snapshot subset driven by a model through `cmux browser`
  and the REPL, scored by predicates, never self-judged.

## 6. Onboarding redesign (computer use)

Goal: a person turns computer use on once, sees exactly what is missing, and every agent failure
says what to do.

1. One readiness model, `ComputerUseReadiness`, owned by the CUA host (Rust) and answered over its
   socket as `readiness {helper: running|missing|version_mismatch, signature: developer_id|dev|adhoc,
   accessibility: granted|denied|unknown, screen_recording: granted|denied|unknown,
   automation_apps: […], display: macos|xvfb:N|wayland_foreground_only|none, self_test: pass|fail(step)}`.
   Both drivers answer it (gap 9); the app, the CLI (`cmux cua doctor`) and agents read the same
   answer. Linux answers with no TCC rows and the display row.
2. First run (palette "Set Up Computer Use", Settings card, inline card in the agent pane): one
   checklist with a row per readiness item, each with its one action (Open Privacy pane, drag the
   helper into the list, Restart helper). Rows turn green from the helper's own answer, pushed on
   change (no polling).
3. Self-test, after the grants: the helper opens its own small fixture window, reads its AX tree,
   takes a screenshot of it, clicks a button and types into a field, and checks the result; the
   checklist shows each step's time. It never touches the person's windows.
4. Agent errors carry the readiness row that failed and the one action:
   `computer_use_unavailable {missing: "screen_recording", fix: "cmux cua setup"}` instead of a raw
   TCC error or a 55 s stall; the agent tells the person in one line and goes on with other work.
5. Tagged dev builds: the dev helper id `com.cmuxterm.cua.dev` gets its own grant; the checklist
   says which identity it is checking.

## 7. Build log (each step: failing test first, fleet tests, plain push to feat-cmux-next)

| Step | Gap | State |
| --- | --- | --- |
| s1 page waits on background Chromium tabs | 1 | red test + fix; fleet run pending |
| s2 hover moves the engine pointer | 4 | red test + fix; fleet run pending |
| s3 snapshot names, frames, shadow roots, states, select options | 5 | helper agent, in progress |
| s4 dogfood suite | 12 | landed with this note |
| s5 `cmux browser open` from agent terminals | 8 | next |
| s6 background tabs load at once; popup stall | 7 | next |
| s7 cmux-browser-host + current cmux-cua in the cloud VM image | 2 | next |
| s8 CLI page verbs on the Rust host for Chromium tabs | 3, 4, 6, 10 | design in browser-host.md, then build |
| s9 readiness model + self-test | 9, onboarding | after D1 |

## 8. Decisions (defaults picked; Lawrence can override)

- D1 One desktop engine: upstream `trycua/cua` `cua-driver-rs` (already Rust, macOS and Linux
  backends, used by helper v2), with cmux's activity store, lease and policy as a Rust layer on top;
  the cmux-cua fork stays the default until v2 answers readiness, activity and lease, then flips.
- D2 One browser core: `cmux-browser-host` (Rust) owns snapshot, input, waits, dialogs, downloads
  and frames for Chromium on both OSes; the Swift page service becomes a thin router. WebKit keeps
  its Swift driver behind the host's driver protocol.
- D3 Consent banners by a reviewed rule file, reject-only, on request; no bundled extensions.
- D4 Live-site tasks are scored apart and compared only within a day; fixture tasks gate merges.
