# cmux NEXT performance lead: issues, numbers, owners

Status: living plan (started 2026-10-23). Owner: the Performance Lead (Lawrence msg 11552:
"fix all cmux performance issues, including chromium performance, fix all dumb things, big
refactor"). Every row moves only with a measured number from a real build on the fleet (never
Lawrence's Mac) and a perf test or bench that is red before and green after. Lawrence
(2026-10-23): no new gates or tests in CI; each agent runs its tests and benches itself on the
fleet and records the numbers here and in the commit message.

Related references (not repeated here): [speed-of-sound-DESIGN.md](speed-of-sound-DESIGN.md)
(floors and idle/memory rows), [instant-new-surfaces.md](instant-new-surfaces.md),
[split-spring-animation/BASELINE.md](split-spring-animation/BASELINE.md),
[home-streaming-perf-DESIGN.md](home-streaming-perf-DESIGN.md), [sequoia-lag.md](sequoia-lag.md),
[sidebar-lag-DESIGN.md](sidebar-lag-DESIGN.md), [browser.md](browser.md),
`scripts/cmux-next/perf-gate.py`, `scripts/cmux-next/perf-budgets.py` with
`perf-budgets-baseline/apple-m4-pro-macos27.json` (fleet, 2026-10-22).

## 1. Targets

Lawrence 2026-10-23: **every action < 10 ms p95 to its committed frame**, motion at full refresh
with 0 drops, measured in a light session and in the STRESS session (60 workspaces; measured
workspace 4 columns x 3 rows, 6 tabs per pane: terminals, Chromium, WebKit, chat; nested
splits; 10 Chromium workspaces; 10 busy terminals; builder `scripts/cmux-next/perf-stress-session.py`).
The table below is superseded where it says more than 10 ms.

| Target | Budget | Proof |
|---|---|---|
| Key to frame (terminal, Home composer, omnibar) | p95 < 8 ms | `bench-typing.py`, `home.typing.*` budget row |
| Split / close / zoom / column motion | every frame at display refresh (120 Hz: 8.33 ms), 0 dropped, with and without a Chromium page in the layout | `pane-perf-terminal.py`, `anim-perf-terminal.py`, `panes.*` budget rows, new `panes.*.chromium` rows |
| New Chromium tab visible | < 100 ms key to first themed frame of the tab; page pixels as soon as the renderer commits | new `cef_tab.*` budget row (`debug.new_tab bench_open`) |
| Tab / workspace / space switch | < 16 ms input to commit, p95 | `workspace_switch.*`, `debug.tab_switch` |

Rule: fix the cause, never a throttle. Work per event is O(what changed on screen).

## 2. Issues, ranked by what Lawrence feels

Numbers are fleet p95 unless noted. "unmeasured" means the first job of the owner is the red row.

| # | Issue | Measured today | Target | Owner | Status |
|---|---|---|---|---|---|
| 1 | **New Chromium tab is slow to show.** The browser tab waits for the daemon's `new-frontend-browser-tab` reply before it is selected (no stand-in, unlike terminals). A pane without a Chromium window makes one with `CefBrowserHost::CreateBrowser` on the main thread (code note: ~0.8 s in a macOS 26 VM); the spare window covers only the first Chromium tab of the process. Any URL other than New Tab builds its `CEFTab` after 2+ awaits. Cold `CefInitialize` 100-160 ms when the 7-day warmup rule skipped it. | unmeasured end to end; daemon reply 31/46 ms p50/p95 | < 100 ms | PL-cef-tab | in progress |
| 2 | **Split / close animation drops frames, worse with Chromium.** Each motion frame live-resizes every moving pane (`applyPresentation` + `layoutSubtreeIfNeeded`), and with a page window up: one `NSPanel.setFrame` per divider catcher, a `browserChildWindowPagesNeedUpdate` post that makes every `CEFHostView` (static ones too) post geometry, the fork re-reads clip/occlusion and moves every page window; child windows do not commit in the parent's CA transaction (tearing). Chromium resizes on the first frame (growing pane) or after landing (shrinking pane). | `panes.close.4x2` frame 33.3 ms, `panes.zoom.4x2` 26.0 ms (no Chromium); with Chromium unmeasured | 8.33 ms, 0 drops | PL-motion-cef (page side), PL-motion-core (layout side) | in progress |
| 3 | **Pane motion per-frame cost grows with pane count.** Red test 241f5bab (`PaneMotionBench`, p95 4 ms of our share at 2/8/30 panes) has no fix: New Column at 30 panes 41 ms p95 in the layout clock. Every frame re-runs clip, divider frames, overlay sync, hover refresh and visibility for every pane, moving or not. | 41 ms p95 (30 panes) | 4 ms our share | PL-motion-core | in progress |
| 4 | **Workspace switch with Chromium pages.** | next/prev input to commit 46.2 ms, to idle 59.7 ms, longest frame 44.3; click 39.5 ms | < 16 ms | PL-switch | in progress |
| 5 | **Home typing.** | `home.typing.key_dispatch` 15.8 ms; single frames to 38 ms on short text | < 8 ms | PL-typing | in progress |
| 6 | **Terminal typing while the sidebar rearranges** (Lawrence 10-23). Bench landed (ab42b3ca, 749d7358), no result yet. Sidebar at 400 workspaces while ticking: 17.4 % CPU, 143 ms/s main thread. | unmeasured key to frame | < 8 ms | a576 (sidebar fixes go through a590) | open, not ours |
| 7 | **Tab switch 100x** (a168). In process apply 0.42 -> 0.31 ms; real window 15-30 ms end to end, the out-of-process content frame unmeasured. | 15-30 ms | < 16 ms p95 | PL-switch | in progress |
| 8 | **Cmd-Tab back** (a503 landed 6f3c937d). Become notices p95 24 ms (budget 8, warns); a PointerHover key change refreshes every hover target (O(all), ~20 ms). | 24 ms | < 8 ms | PL-switch (batch 2) | open |
| 9 | **Idle cost.** Home 3.40 % CPU, main wakes 27-107/s (more when hidden), 358 KB/s disk writes, 3 Chromium renderers (185 MB) for cmux's own pages before any browser tab. | see speed-of-sound sec. 7 | 0 | batch 2 | open |
| 10 | **Chromium shares the main thread.** `external_message_pump`; a pump pass of >= 10 ms counts as a long run, longer than a 120 Hz frame. | `debug.cef pump` long runs: unmeasured per action | 0 long runs during motion and typing | PL-motion-cef | in progress |
| 11 | Cmd-N `cmdN.start` 8-15 ms on the key's turn; Cmd-T `newTab.open` 3.4/11 ms p50/max. | as stated | < 4 ms on the key's turn | batch 2 | open |
| 12 | Space switch, group open/close: no bench row. | unmeasured | < 16 ms | PL-switch | open |
| 13 | Full-screen lag (a195): Aziz 24ce2dc4/5dad2b0c fixed the titlebar window counted as a page; no numbers. | unmeasured | as row 2 | PL-motion-cef verifies | open |
| 14 | Cmd-D spring (a394, a121): after the fix all panes move from frame 1, rest 383 ms; frame cost is rows 2-3. | rest 383 ms | per row 2 | PL-motion-core | open |
| 15 | Memory: hidden Chromium tab 55 MB, WebKit 29 MB, Home 793 MB, CEF framework 347 MB of a 665 MB app (a555, a456 hibernation 30-min default landed). | as stated | speed-of-sound floors | batch 2 | open |
| 16 | GitHub [#6790](https://github.com/manaflow-ai/cmux/issues/6790) scroll hangs (classic: full-window NSHostingView relayout per scroll tick, 254-512 ms) and [#8900](https://github.com/manaflow-ai/cmux/issues/8900) hidden NotificationsPage re-renders (classic, 50-61 % main). NEXT check: no hidden page may re-render (the same class as row 9). | classic numbers | 0 work for hidden views | batch 2 audit | open |
| 17 | [#20856](https://github.com/manaflow-ai/cmux/issues/20856): CEF tab 183 MB, 60 CEF tabs 11.8 GB vs Chrome 7.4 GB; warm tab switch 160 ms, hibernated wake 0.7-1.1 s (Leo since: wake p50 41 ms back). | as stated | row 7 / 15 | batch 2 | open |
| 18 | [#17587](https://github.com/manaflow-ai/cmux/issues/17587) launch: first frame 217-263 ms, live tree 351-936 ms at 24 workspaces. | as stated | first frame < 150 ms | batch 2 | open |
| 19 | [#23087](https://github.com/manaflow-ai/cmux/issues/23087) idle headless cmux-tui owner 5-16 % CPU; [#17287](https://github.com/manaflow-ai/cmux/issues/17287) client busy loop after pty deleted. | as stated | 0 | batch 2 | open |
| 20 | [#21977](https://github.com/manaflow-ai/cmux/issues/21977) zsh integration forks `find` per path part: new tab +100 ms (145-240 ms). | as stated | 0 forks | batch 2 | open |
| 21 | **Ghostty integration** ([ghostty-integration-DESIGN.md](ghostty-integration-DESIGN.md) G1-G8): a resize frame draws the old text at the new size (sync draw of stale cells on main, async reflow frames dropped); each grid step is a full READY snapshot round trip with up to 4 whole-scrollback reflows and the app holding frames for its own; every byte parsed 3 times (host, daemon mirror, app), daemon parse on the echo path; output chunks hop through the main actor; base64 JSON output. | resize stale-text frames and frame hold per step: unmeasured (bench-terminal-resize.py) | every resize frame shows the new size with its text, 0 held frames, < 10 ms | PL-ghostty (app, ghostty-next); daemon half PL-daemon | in progress |

Earlier perf work this plan builds on (do not undo): perf gate and budgets (a436, Aziz's
1884ac30 brought tabs/new_workspaces back), Chromium clip memo (Leo c22a1071, `debug.cef`
tracker counters; `app-eff/cef-tracker-before` is his A/B base), cover snapshot JPEG off main
(4cbad887), hibernation wake 41 ms (Leo 26e6f02f, a456 30-min default 98a126f8), Cmd-Tab
indicators 368 -> 0 (a503), redraw coalescing (cdbab175, 8d667660), lazy PTY (a308 7953211a),
Ctrl-` optimistic (a413 2dee73fe), Cmd-N one frame, Home streaming p95 87 -> 8.6 ms,
palette linear grouping (Aziz 59564e6e), WebKit title coalesce (Aziz ff167aa9).

## 3. Structural causes and the refactor that removes each

1. **Live resize as animation.** Motion sets real frames on every pane every frame, so AppKit
   layout, Ghostty grid math, Chromium resize and child-window moves run 120 times a second.
   Refactor: a structural change computes the rest layout once; the springs move layers
   (position/bounds on the render server, or a frozen snapshot for page windows); content
   resizes once, at landing, behind its last frame. Per frame only panes whose presented rect
   changed are touched.
2. **Chromium pages are child windows outside the CA transaction.** Every geometry change is a
   WindowServer round trip per page and it tears against the pane chrome. Refactor: during any
   motion, a page shows a snapshot layer in its host and its child window is hidden
   (`setOccluded`, already designed in browser.md, never called by motion code); geometry posts
   go only to hosts whose rect or clip changed; divider catcher panels update at landing.
   Longer term: CALayerHost / remote-layer hosting (cef-out-of-process.md option B) so pages
   live in the window's layer tree.
3. **Waiting for the daemon on the key's turn.** Terminals got stand-ins (instant-new-surfaces);
   browser tabs, and parts of Cmd-N, did not. Refactor: one intent + stand-in path for every
   create (terminal, browser, chat, page), reconciled by request id (CLAUDE.md shared optimistic
   rule).
4. **Expensive Chromium objects created on demand on the main thread.** Refactor: a spare
   Chromium window is always ready (refilled at idle after each take), CEF init at idle whenever
   Chromium is the default engine, `CEFTab` made in the key's turn.
5. **Main-thread Chromium pump.** Refactor step 1: no geometry churn (cause 2) so the pump has
   nothing to do during motion; step 2: defer non-urgent pump work while the layout clock runs.
6. **O(all) observers.** Hover targets, sidebar rows, status indicators re-run for every object
   on a change to one. Refactor: one observer per visible thing (speed-of-sound rule), already
   done for pane focus (16 -> 2 chrome updates) and Cmd-Tab (368 -> 0).
7. **SwiftUI leftovers on hot paths** (Home composer, sidebar rows, hidden pages still in the
   graph, the [#8900](https://github.com/manaflow-ai/cmux/issues/8900) class). Refactor: hidden
   views leave the graph; AppKit/immediate rows on typing paths; `perf-profile-split.py` buckets
   prove where time goes before a rewrite.

### Design faults (Lawrence 2026-10-23: "are there other fundamentally wrong things")

| # | Fault | Evidence | Real fix | When |
|---|---|---|---|---|
| F1 | Chromium pages are separate child windows over panes | issues 1, 2, 4, 13 | page layer in the cmux window's layer tree (PL-cef-layer) | now |
| F2 | Chromium's browser process runs in cmux, its pump on cmux's main thread (macOS CEF UI thread = main) | pump passes >= 10 ms; a Chromium CHECK ends all of cmux (cef-out-of-process.md) | browser process in a helper app; pixels through the F1 layer hosting across processes (Lawrence: yes) | after F1 |
| F3 | cmux's own UI pages are React in Chromium renderers | Home starts 3 renderers, 185 MB, ~2 % idle CPU before any browser tab | Lawrence: cmux pages STAY in Chromium ("we want a bunch of stuff in chromium"). Fix is cost, not engine: hidden cmux pages cost 0 CPU and wake 0 times; renderers start on first show | batch 2 |
| F4 | Motion = live resize of real frames every frame | 41 ms/frame at 30 panes | Lawrence: resizing stays live and fluid for Ghostty and Chromium (no snapshot freeze, no landing-only resize): every frame shows content laid out at that frame's size, same CA transaction; per-frame work only for panes that moved (PL-motion-core, PL-ghostty, PL-motion-cef, PL-cef-layer) | now |
| F5 | Work follows what exists, not what changed | idle main wakes 27-107/s, 358 KB/s idle disk writes, 368 indicators per Cmd-Tab (fixed), sidebar 17 % CPU ticking at 400 ws | one observer per visible thing; no timers; writes only on new information | batch 2 |
| F6 | One process per terminal | 392 processes heavy (172 terminal hosts), 8.2 MB per workspace | keep crash isolation another way: a holder keeps PTY fds + byte rings, VT parsing in a small worker pool that restarts from the ring (PL-daemon, terminal-host-model-DESIGN.md) | now |
| F7 | Creates wait for the daemon's echo; stand-ins added per command | terminals instant, browser tabs not | one intent + stand-in path for every create | PL-cef-tab now |
| F8 | Hidden things keep full cost | hidden Chromium tab 55 MB, Home 793 MB vs ~70 MB floor | discard engines past a grace, keep a record and picture | batch 2 |
| F10 | Daemon requests are slow | split 107-112 ms p50, new terminal 114/660 ms p50/p95 loaded | profile each op, fix causes; local request < 2 ms (PL-daemon) | now |
| F11 | Ghostty integration (audit) | 20 idle terminals 7.3 % CPU, 7.8 MB per terminal; possible double VT parsing (daemon + app) | ghostty-integration-DESIGN.md (PL-ghostty) | now |
| F12 | Two web engines for browser tabs (every feature built twice) | WebKitEngine + CEFEngine, per-tab engine | Lawrence 2026-10-23: KEEP BOTH ENGINES. Every perf target applies to both; no removal | closed |
| F13 | Codebase health: god target CmuxNextApp 141,651 lines, 152 singletons, 162 broadcast observers, 290 assumeIsolated, Debug-only perf counters | text search counts | PL-arch (architecture-refactor-DESIGN.md), PL-guardrails (pre-push ratchet, OWNERS.md, perf-hot markers, codebase-health.md) | now |
| F9 | Lag regressions land unseen: timings only warn, fleet minis have no lit display (frame checks skipped) | perf-gate.py header | Lawrence: no CI gate on push or nightly; a scheduled cron perf run (perf budgets + STRESS) opens one regression issue (PL-perf-cron) | now |

User data: Lawrence 2026-10-23: opt-in hang reports from nightly users, private data removed (PL-telemetry, hang-reports-DESIGN.md; privacy policy text needs Lawrence).

Process (Lawrence 2026-10-23): every agent session's landed code is reviewed twice by independent review agents, with fixes landed after each review; at the end one agent tests everything on live Macs on every supported macOS (14, 15, 26, 27). The remaining basic problems run as workflow cmux-next-basic-problems (pages cost, idle wakeups, O(all) per event incl. Cmd-Tab, hidden memory, launch, create on the key, scrolling, shell integration, then a completeness critic and a second round).

## 4. Workstreams (batch 1)

Each workstream is one subagent in its own worktree, lands on feat-cmux-next (rebase, plain
push), and writes its before/after table into this file's section 5.

- **PL-cef-tab**: issue 1. Browser tab stand-in on the key's turn; always-ready spare Chromium
  window; idle CEF init; synchronous `CEFTab`. Red row: `cef_tab.new.visible` (cold pane, warm
  pane, second pane).
- **PL-motion-cef**: issues 2 (page side), 10, 13. Snapshot-and-hide page windows during
  motion, landing-only resize, geometry posts only to changed hosts, catchers at landing. Red
  rows: `panes.split.chromium`, `panes.close.chromium` frame p95 and `debug.cef` geometry posts
  per frame. Reads Leo's c22a1071 and `app-eff/cef-tracker-before` first.
- **PL-motion-core**: issues 2 (layout side), 3, 14. Makes 241f5bab green: per-frame work only
  for panes that moved, layer-driven motion, content resize at landing. Files:
  `ScreenContentView+Motion.swift`, `LayoutRootView*.swift`, `PaneHostView.swift`.
- **PL-switch**: issues 4, 7, 12 (then 8). Workspace/tab/space switch < 16 ms with Chromium
  pages (Lawrence 2026-10-23: switching is slow when Chromium is involved; top priority).
- **PL-cef-layer**: implementing (Lawrence: "do the real fix now") hosting the Chromium page's layer in the cmux window's own layer tree
  (no child page windows), plus the interim fix inside the child-window design. Output:
  `cef-layer-hosting-DESIGN.md`.
- **PL-typing**: issue 5 and the terminal key-to-frame baseline; sidebar-caused lag goes to a576
  / a590.

Batch 2 (after batch 1 lands): issues 8, 9, 11, 15-20.

## 5. Results log

| Date | Workstream | sha range on feat-cmux-next | Row | Before | After |
|---|---|---|---|---|---|
| 2026-10-23 | PL-guardrails | this push | pre-push guardrails (guardrails.py), perf-hot markers, OWNERS.md, codebase-health.md | no rule; hooks on this Mac from 10-19 | 8 rules refuse new debt in added lines; 0.16-0.20 s per typical push (Lawrence's Mac, loaded); no CI change |
| | | | | | |
