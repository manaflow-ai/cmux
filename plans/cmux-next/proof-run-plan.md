# Prove or remove: proof run plan (v2.2.3-opt), 2026-10-28

Written 2026-10-28 09:40Z. Rule: [prove-or-remove.md](prove-or-remove.md). Rows: [prove-or-remove-table.md](prove-or-remove-table.md). Status: **PREPARED, NOT SUBMITTED**:
fleet submits time out until hq #4793 (controller write path) is live; the lead says when. No fleet job of this plan has run yet.

## The build and the base

- Build under test: **chrome-parity-v2-2-3-opt**, job `5aad318613a5d03003030a32` (done, aws-m4pro-6), commit `1b856ace18a92cf12556ff69f7fac7cac2de59cc`,
  artifact `sha256:69e27553df799423efa487c528aa3a441405d812671b7373565d5d59d9d9d0ec`. Release -O, whole module, no DEBUG, plus
  `-DCMUX_BENCH_HOOKS` (the debug socket). Its tag starts with `chrome-parity-`, so its 104 dogfood switches are on by default (FeatureList
  step 6); `CMUX_ENABLE_FEATURES` / `CMUX_DISABLE_FEATURES` (step 2) override one launch. 1,262 of the 1,504 task ids on the tip are in it.
- Comparison: each A/B is the **same build, same host**, switch on vs off, interleaved. No second build is needed for a switch row.
  For rows without a switch the only base is nightly-opt (job `d55a43f7dac5d94cdeba1ed4`, `sha256:0b49e1a5a85e303163f4d1071732720de82b45bf42f7c38f4aedea5c3efe6914`,
  feat-cmux-next cc0d757 in the same bench config): a whole-build number that names no single mechanism, so it is not proof of a row.
- Rows whose code is not in v2.2.3-opt are marked **needs v2.2.4/5-opt** below (v2.2.4-opt job 0fd2bb11 is still queued).

## The harness: `--suite=proof-ab` on scratch ref `cp/proof-ab-measure` (ce3d9d351f3, never lands)

- Base: `cp/first5s-measure-f` 175239cbe54 (the fixed first-5s sender; on feat-cmux-next, so `scripts/measure/split-spring.sh` is the reviewed
  blob a2a18b47 the controller accepts). `split-spring.sh --config=<sha256>` fetches the fleet artifact (reload stub), no build.
- `scripts/cmux-next/proof-ab.py` runs one bench suite 2 x N times on that app (N = 5 per arm), in ABBA order (on off off on, off on on
  off, ...): arm **on** launches with `CMUX_ENABLE_FEATURES=<switches>`, arm **off** with `CMUX_DISABLE_FEATURES=<switches>` (both explicit,
  so the dogfood defaults never decide an arm). Every launch path (BenchApp, bench-startup.py, bench_memory.py) applies the arm
  (`proof_ab_env.py`) and reads `features.list` back; a run whose switches did not take the arm is invalid.
- Per metric: pooled p50 / p95 / p99 / max per arm, the per-run p95 list, the **noise band** = spread (max - min) of the off arm's per-run
  p95, the effect = median(on) - median(off) of the per-run p95, and an exact two-sided Mann-Whitney p. **proven** = every valid run's arm
  verified, 5 valid runs per arm, p < 0.05, effect in the better direction and larger than the noise band; **regression** = the same in the
  worse direction; else **not proven**. First-5s runs are valid only when every key's `send_late_ms` is < 1 ms (FIRST5S-SENDER max < 1 ms).
- Simulated end to end on the Linux VM with a stand-in bench (arms, readback, report, verdict); not run on a Mac yet.
- Files: steps `/work/wt/chrome-parity-design/proof-runs/steps.json`; `submit.py` (dry run by default; `--go` submits, one fixed `--key`
  per step, ledger.jsonl, never resubmits a key); `collect.py` (polls each job at most every 3 min, fetches the report, writes one strict
  proof row per step to results.jsonl). Offline re-analysis: `proof-ab.py --summarize <report.json>`.

## Hosts

perf-lead pool: cmux17-perf, cmux18-perf, cmux19-perf, cmux21-perf, cmux22-perf, cmux23-perf, cmux24-perf (7 M6 minis with `gui-session-v1`,
`measure`, macOS 27). cmux15 does not report to the controller now; cmux16 never; cmux20-bench has no GUI session label. Every step is
`--class exclusive --measurement --label measure --pool perf-lead`, 120 Hz virtual display. One A/B never spans two hosts.

**Host time: 91.6 h for 71 A/B steps, about 13.1 h wall time on 7 hosts** if the pool is free. Order: largest net lines at risk first.

## Counts after the decisions

- 313 rows: proven 0, planned 247, unproven 66 (27 before the decisions; +3 host mode, +36 gate rows not in the train or CI or not landed).
- Planned rows whose own proof text says "else remove" / "keep only if": **45** rows, +67,245 net lines (list at the end).
- So the removal list on 11-04 is at least 66 rows (+60,265 lines) and, if no proof lands, every planned row too.
- Of the 247 planned rows: 71 are switch A/Bs that can run on v2.2.3-opt now (below), 105 need v2.2.4/5-opt or a revert build, 71 are not a metric A/B (gate catch, bugfix red/green, or a bench that does not exist yet).

## Benches (grouped), ordered by net lines at risk

| bench | suite and arguments | metrics (lower is better) | min per run | steps | host hours | net lines at risk |
|---|---|---|---|---|---|---|
| memory (footprint, 10 workspaces) | `memory` --workspaces=1,10 --mix=terminal,terminal+browser,terminal+chat --settle=30 | footprint | 7 | 26 | 39.1 | +36,313 |
| key-to-frame STRESS | `typing-frame` --sessions=stress --surfaces=terminal,omnibar --phases=idle,load --rounds=1 --samples=60 | term_idle; term_load; omni_load | 12 | 5 | 10.3 | +13,147 |
| idle CPU/wakeups | `idle-budget` --sessions=light,light-hidden --settle=60 | wakeups; main_wakes; cpu | 6 | 9 | 9.6 | +9,418 |
| frame drops (anim-perf, 120 Hz) | `anim-perf` --rounds=1 | dropped; frame_p95; main_ms | 8 | 12 | 16.8 | +8,786 |
| launch (cold + warm) | `launch` --mode cold --mode warm --runs 1 --profile realistic | first_frame; first_terminal | 3 | 9 | 5.1 | +5,430 |
| key-to-frame light | `typing-frame` --sessions=light --surfaces=terminal,omnibar --phases=idle,load --rounds=1 --samples=60 | term_idle; term_load; omni_load | 6 | 10 | 10.7 | +4,862 |

Memory rows for discard behavior run with Memory Saver aggressive and a 360 s settle, so hidden pages pass the discard timeout; other memory
and idle rows use a generic scenario. **Flag:** the row owner confirms that the scenario reaches the mechanism before its step is submitted;
a scenario that never runs the code gives "not proven", not a removal reason by itself.

## A/B steps on v2.2.3-opt (submit in this order)

| # | row | mechanism | net lines | bench | switches toggled | runs | host min | key | owner | note |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | p07-04 | Memory Saver discards hidden cmux pages | +5,946 | memory (footprint, 10 workspaces) | `memorySaverSetting,memoryDiscardInternalPages,memoryDiscardPageTabs,memoryDiscardConversations,topPageDiscard,memoryDiscardSidebarSections,memoryDiscardRemoteTabs,memoryDiscardAgentPagesOverBudget` | 5 + 5 | 144 | `por-ab-p07-04-v223-1` | PL-memory | Memory Saver aggressive, 360 s settle so hidden pages pass the discard timeout: memory/leaks owner confirms before submit |
| 2 | p09-05 | Field histograms and View Metrics | +5,670 | key-to-frame STRESS | `metricsView` | 5 + 5 | 124 | `por-ab-p09-05-v223-1` | PL-telemetry | row says else remove |
| 3 | p14-07 | Energy Saver | +5,465 | idle CPU/wakeups | `energySaver` | 5 + 5 | 64 | `por-ab-p14-07-v223-1` | memory/leaks (proposed) | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 4 | p07-12 | Daemons follow the app's memory pressure | +4,632 | memory (footprint, 10 workspaces) | `memoryAcpmuxPressure,memorySqliteTrim` | 5 + 5 | 74 | `por-ab-p07-12-v223-1` | PL-memory | partial: only these switches are in v2.2.3-opt; generic scenario: the row owner confirms it reaches the mechanism before submit |
| 5 | p07-10 | Daemon per-terminal memory sized from RAM | +3,837 | memory (footprint, 10 workspaces) | `memoryScrollbackPressure,memoryKittyShare` | 5 + 5 | 74 | `por-ab-p07-10-v223-1` | PL-memory | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 6 | p07-02 | App caches shrink under memory pressure | +3,211 | memory (footprint, 10 workspaces) | `memoryTabCaches,memoryBackdropImages,memoryBrowserCaches,memoryAppCaches,memoryFileHomeCaches,memoryAgentAndControlCaches,memoryHomeLabCaches,memorySmallAppStores` | 5 + 5 | 74 | `por-ab-p07-02-v223-1` | PL-memory | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 7 | p07-13 | Fewer tool processes per agent chat | +3,183 | memory (footprint, 10 workspaces) | `agentToolsInDaemon,mcpCatalogHost` | 5 + 5 | 74 | `por-ab-p07-13-v223-1` | PL-acpmux | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 8 | p07-01 | Memory coordinator: RAM budgets and sliced release | +3,171 | memory (footprint, 10 workspaces) | `memoryHiddenAppRelease` | 5 + 5 | 74 | `por-ab-p07-01-v223-1` | PL-memory | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 9 | p06-15 | Daemon serves the person's requests first | +3,162 | key-to-frame STRESS | `daemonRequestQos` | 5 + 5 | 124 | `por-ab-p06-15-v223-1` | sequence manager (proposed) |  |
| 10 | p08-08 | Saved window picture as first frame | +2,801 | launch (cold + warm) | `savedWindowPicture` | 5 + 5 | 34 | `por-ab-p08-08-v223-1` | restore (proposed) |  |
| 11 | p07-11 | Cold scrollback compression in the daemon | +2,482 | memory (footprint, 10 workspaces) | `coldScrollbackCompression` | 5 + 5 | 74 | `por-ab-p07-11-v223-1` | PL-memory | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 12 | p13-09 | Hidden pages freeze, then discard | +2,473 | memory (footprint, 10 workspaces) | `pageLifecycle` | 5 + 5 | 144 | `por-ab-p13-09-v223-1` | PL-webui | Memory Saver aggressive, 360 s settle so hidden pages pass the discard timeout: memory/leaks owner confirms before submit |
| 13 | p04-10 | Drags and hover handled once per frame | +2,272 | frame drops (anim-perf, 120 Hz) | `pointerFrameDrags,pointerFrameHover` | 5 + 5 | 84 | `por-ab-p04-10-v223-1` | PL-motion-cef |  |
| 14 | p05-04 | Wire stats and per-method latency histograms | +2,149 | key-to-frame light | `ipcMethodLatencyFieldData` | 5 + 5 | 64 | `por-ab-p05-04-v223-1` | daemon hot paths (proposed) | row says else remove |
| 15 | p06-14 | Person-caused changes apply before automation | +2,013 | key-to-frame STRESS | `drainCauseSplit` | 5 + 5 | 124 | `por-ab-p06-14-v223-1` | sequence manager (proposed) |  |
| 16 | p04-07 | MainJobGate: input before other main work | +1,818 | key-to-frame STRESS | `mainJobGate` | 5 + 5 | 124 | `por-ab-p04-07-v223-1` | PL-typing |  |
| 17 | p03-02 | One vsync thread per display (VSyncHub) | +1,533 | frame drops (anim-perf, 120 Hz) | `vsyncHub` | 5 + 5 | 84 | `por-ab-p03-02-v223-1` | motion (proposed) |  |
| 18 | p04-15 | Scroll by moving layers, not relayout | +1,262 | frame drops (anim-perf, 120 Hz) | `tabStripScrollFrames` | 5 + 5 | 84 | `por-ab-p04-15-v223-1` | PL-motion-core |  |
| 19 | p14-08 | Background polls pause while nothing shows them | +1,219 | idle CPU/wakeups | `hiddenPollPause` | 5 + 5 | 64 | `por-ab-p14-08-v223-1` | memory/leaks (proposed) | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 20 | p07-03 | Picture caches purgeable and pressure-sized | +1,131 | memory (footprint, 10 workspaces) | `memoryImageCaches,memoryTerminalLastFrames` | 5 + 5 | 74 | `por-ab-p07-03-v223-1` | PL-memory | partial: only these switches are in v2.2.3-opt; generic scenario: the row owner confirms it reaches the mechanism before submit |
| 21 | p03-06 | Overlays and drag ghosts in an in-window layer | +1,024 | frame drops (anim-perf, 120 Hz) | `overlayTopLayer` | 5 + 5 | 84 | `por-ab-p03-06-v223-1` | PL-motion-cef |  |
| 22 | p07-16 | Fewer renderer processes for pages and tabs | +845 | memory (footprint, 10 workspaces) | `cmuxPageRendererSharing,webKitPageProcessGroups,webKitSameSiteProcesses` | 5 + 5 | 74 | `por-ab-p07-16-v223-1` | PL-memory | partial: only these switches are in v2.2.3-opt; generic scenario: the row owner confirms it reaches the mechanism before submit |
| 23 | p03-11 | Hidden frames in one memory-capped LRU | +784 | memory (footprint, 10 workspaces) | `memoryHiddenFrameLRU` | 5 + 5 | 74 | `por-ab-p03-11-v223-1` | PL-memory | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 24 | p13-16 | New Tab parks hidden in the preload slot | +774 | key-to-frame light | `newTabParksHidden` | 5 + 5 | 64 | `por-ab-p13-16-v223-1` | PL-webui |  |
| 25 | p14-09 | High-energy hidden tab badge with Discard | +771 | idle CPU/wakeups | `highEnergyTabs` | 5 + 5 | 64 | `por-ab-p14-09-v223-1` | memory/leaks (proposed) | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 26 | p07-15 | Helpers, panels and page renderers start on first use | +710 | memory (footprint, 10 workspaces) | `memoryOpenPanelOnFirstUse,memoryOverlayPagesOnFirstUse,pageRendererAtFirstShow` | 5 + 5 | 74 | `por-ab-p07-15-v223-1` | PL-memory | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 27 | p08-04 | Control socket binds off main thread | +686 | launch (cold + warm) | `controlSocketEarlyBind` | 5 + 5 | 34 | `por-ab-p08-04-v223-1` | first-5s (proposed) |  |
| 28 | p07-06 | Off-screen windows count as hidden | +656 | memory (footprint, 10 workspaces) | `occludedWindowDiscard` | 5 + 5 | 144 | `por-ab-p07-06-v223-1` | PL-memory | partial: only these switches are in v2.2.3-opt; Memory Saver aggressive, 360 s settle so hidden pages pass the discard timeout: memory/leaks owner confirms before submit |
| 29 | p03-09 | Chromium pages attached as Cocoa views | +630 | frame drops (anim-perf, 120 Hz) | `cefAttachedPages` | 5 + 5 | 84 | `por-ab-p03-09-v223-1` | PL-cef-layer |  |
| 30 | p07-07 | Discard frozen-growing and crashed-subframe pages | +621 | memory (footprint, 10 workspaces) | `frozenGrowthDiscard` | 5 + 5 | 144 | `por-ab-p07-07-v223-1` | PL-memory | partial: only these switches are in v2.2.3-opt; Memory Saver aggressive, 360 s settle so hidden pages pass the discard timeout: memory/leaks owner confirms before submit |
| 31 | p03-13 | Covered or hidden content stops animating | +584 | idle CPU/wakeups | `windowOcclusionFamily` | 5 + 5 | 64 | `por-ab-p03-13-v223-1` | motion (proposed) | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 32 | p14-13 | Sleep and wake stop keepalives | +570 | idle CPU/wakeups | `sleepWakeKeepalives` | 5 + 5 | 64 | `por-ab-p14-13-v223-1` | memory/leaks (proposed) | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 33 | p07-08 | Hidden workspaces unmount past RAM budget | +537 | memory (footprint, 10 workspaces) | `memoryDiscardParkedWorkspaces,memoryDiscardParkedIdleTimeout` | 5 + 5 | 144 | `por-ab-p07-08-v223-1` | PL-memory | Memory Saver aggressive, 360 s settle so hidden pages pass the discard timeout: memory/leaks owner confirms before submit |
| 34 | p04-13 | Resampled drag visuals | +534 | frame drops (anim-perf, 120 Hz) | `resampledDrags` | 5 + 5 | 84 | `por-ab-p04-13-v223-1` | PL-motion-cef |  |
| 35 | p08-10 | Saved browser page pictures at launch | +533 | launch (cold + warm) | `browserLaunchPictures` | 5 + 5 | 34 | `por-ab-p08-10-v223-1` | restore (proposed) |  |
| 36 | p06-12 | Chromium tab events merged per frame | +527 | key-to-frame light | `cefMergedEvents` | 5 + 5 | 64 | `por-ab-p06-12-v223-1` | PL-motion-cef |  |
| 37 | p06-04 | Render starvation guard | +500 | frame drops (anim-perf, 120 Hz) | `renderStarvationGuard` | 5 + 5 | 84 | `por-ab-p06-04-v223-1` | sequence manager (proposed) |  |
| 38 | p04-09 | CEF pump waits for non-Chromium input | +484 | key-to-frame STRESS | `cefPumpInputPolicy` | 5 + 5 | 124 | `por-ab-p04-09-v223-1` | PL-cef-layer |  |
| 39 | p13-11 | Urgent discard ranks tabs, chats, pages | +483 | memory (footprint, 10 workspaces) | `memoryUrgentDiscardRanking` | 5 + 5 | 144 | `por-ab-p13-11-v223-1` | PL-memory | Memory Saver aggressive, 360 s settle so hidden pages pass the discard timeout: memory/leaks owner confirms before submit |
| 40 | p08-05 | Sentry hang reports paused during launch | +407 | launch (cold + warm) | `sentryHandlersFirst` | 5 + 5 | 34 | `por-ab-p08-05-v223-1` | first-5s (proposed) |  |
| 41 | p04-12 | Remote view pointer events once per frame | +381 | frame drops (anim-perf, 120 Hz) | `pointerFrameRemoteInput` | 5 + 5 | 84 | `por-ab-p04-12-v223-1` | hold-class (proposed) |  |
| 42 | p08-12 | Visible-first Chromium page restore | +372 | launch (cold + warm) | `cefLaunchOrigin` | 5 + 5 | 34 | `por-ab-p08-12-v223-1` | restore (proposed) |  |
| 43 | p13-23 | Page push channel to pages | +364 | key-to-frame light | `pagePushChannel` | 5 + 5 | 64 | `por-ab-p13-23-v223-1` | PL-webui | row says else remove |
| 44 | p01-17 | Terminals on one PTY holder process | +355 | memory (footprint, 10 workspaces) | `terminalHolder` | 5 + 5 | 74 | `por-ab-p01-17-v223-1` | PL-holder | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 45 | p06-13 | cmux page scripts once per frame | +283 | key-to-frame light | `pageScriptFrames` | 5 + 5 | 64 | `por-ab-p06-13-v223-1` | PL-webui |  |
| 46 | p08-09 | Background windows build by occlusion | +279 | launch (cold + warm) | `launchWindowsByOcclusion` | 5 + 5 | 34 | `por-ab-p08-09-v223-1` | first-5s (proposed) |  |
| 47 | p08-11 | Only visible panes build at launch | +271 | launch (cold + warm) | `launchVisiblePanesOnly` | 5 + 5 | 34 | `por-ab-p08-11-v223-1` | first-5s (proposed) |  |
| 48 | p04-11 | Terminal pointer events once per frame | +255 | frame drops (anim-perf, 120 Hz) | `terminalPointerFrames` | 5 + 5 | 84 | `por-ab-p04-11-v223-1` | PL-ghostty |  |
| 49 | p03-15 | Shared glyph masks for chrome labels | +248 | memory (footprint, 10 workspaces) | `sharedGlyphMasks` | 5 + 5 | 74 | `por-ab-p03-15-v223-1` | motion (proposed) | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 50 | p03-03 | Frame rate classes per client | +241 | idle CPU/wakeups | `frameRateClasses` | 5 + 5 | 64 | `por-ab-p03-03-v223-1` | PL-motion-core | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 51 | p13-07 | Ad blocker loads at first browser tab | +241 | memory (footprint, 10 workspaces) | `chromiumAdBlockerAtFirstTab` | 5 + 5 | 74 | `por-ab-p13-07-v223-1` | PL-webui | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 52 | p06-10 | Hidden Chromium tabs follow their visibility node | +237 | idle CPU/wakeups | `chromiumTabVisibility` | 5 + 5 | 64 | `por-ab-p06-10-v223-1` | PL-cef-tab | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 53 | p13-02 | Page process groups by capability | +235 | memory (footprint, 10 workspaces) | `pageProcessGroups` | 5 + 5 | 74 | `por-ab-p13-02-v223-1` | PL-webui | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 54 | p14-05 | Chromium timer slack and aligned wakes | +233 | idle CPU/wakeups | `cefTimerSlack` | 5 + 5 | 64 | `por-ab-p14-05-v223-1` | PL-cef-layer | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 55 | p13-04 | Pages spare Chromium window at warm start | +210 | key-to-frame light | `pagesSpareWindow` | 5 + 5 | 64 | `por-ab-p13-04-v223-1` | PL-webui |  |
| 56 | p03-17 | Resized terminal frame in the size commit | +207 | key-to-frame light | `terminalPreCommitPresent` | 5 + 5 | 64 | `por-ab-p03-17-v223-1` | PL-ghostty |  |
| 57 | p06-11 | Hidden terminal state waits until shown | +174 | key-to-frame light | `terminalHiddenActionHold` | 5 + 5 | 64 | `por-ab-p06-11-v223-1` | PL-ghostty |  |
| 58 | p06-16 | Automation layout bursts snap without spring | +172 | frame drops (anim-perf, 120 Hz) | `automationBurstSnap` | 5 + 5 | 84 | `por-ab-p06-16-v223-1` | PL-motion-core |  |
| 59 | p13-20 | Page tabs share one Chromium window per pane | +169 | memory (footprint, 10 workspaces) | `pageTabsShareChromiumWindow` | 5 + 5 | 74 | `por-ab-p13-20-v223-1` | PL-webui | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 60 | p13-18 | Cold page open shows a stand-in | +143 | key-to-frame light | `pageStandIn` | 5 + 5 | 64 | `por-ab-p13-18-v223-1` | PL-webui |  |
| 61 | p07-09 | Hidden terminals release GPU memory | +139 | memory (footprint, 10 workspaces) | `terminalGPURelease` | 5 + 5 | 74 | `por-ab-p07-09-v223-1` | PL-memory | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 62 | p04-14 | Column strip pan resampled at frame time | +118 | frame drops (anim-perf, 120 Hz) | `stripPanResampling` | 5 + 5 | 84 | `por-ab-p04-14-v223-1` | PL-motion-core |  |
| 63 | p12-16 | Content holds its size during motion | +105 | frame drops (anim-perf, 120 Hz) | `paneHoldsContentInMotion,sidebarSlideHoldsContent` | 5 + 5 | 84 | `por-ab-p12-16-v223-1` | PL-motion-core |  |
| 64 | p14-15 | Hidden WebKit views hidden to WebKit | +98 | idle CPU/wakeups | `webkitHiddenTabs` | 5 + 5 | 64 | `por-ab-p14-15-v223-1` | memory/leaks (proposed) | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 65 | p12-17 | Hibernated tabs keep a compressed picture | +81 | memory (footprint, 10 workspaces) | `compressedSnapshots` | 5 + 5 | 74 | `por-ab-p12-17-v223-1` | PL-memory | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 66 | p08-06 | Crash forwarders run after startup | +78 | launch (cold + warm) | `crashForwardersAfterStartup` | 5 + 5 | 34 | `por-ab-p08-06-v223-1` | first-5s (proposed) | row says else remove |
| 67 | p13-06 | No spare renderer before first browser tab | +62 | memory (footprint, 10 workspaces) | `chromiumSpareAfterFirstTab` | 5 + 5 | 74 | `por-ab-p13-06-v223-1` | PL-webui | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 68 | p13-05 | Renderer-less spare placeholder tab | +43 | memory (footprint, 10 workspaces) | `rendererlessSpareWindow` | 5 + 5 | 74 | `por-ab-p13-05-v223-1` | PL-webui | row says else remove; generic scenario: the row owner confirms it reaches the mechanism before submit |
| 69 | p13-24 | New Tab and chats share a renderer | +38 | memory (footprint, 10 workspaces) | `agentPageRendererSharing` | 5 + 5 | 74 | `por-ab-p13-24-v223-1` | PL-memory | generic scenario: the row owner confirms it reaches the mechanism before submit |
| 70 | p12-19 | Agent tabs render in Chromium | +31 | key-to-frame light | `agentChromium` | 5 + 5 | 64 | `por-ab-p12-19-v223-1` | PL-webui |  |
| 71 | p06-07 | Chromium prefetch waits behind launch fence | +3 | launch (cold + warm) | `cefPrefetchBehindFence` | 5 + 5 | 34 | `por-ab-p06-07-v223-1` | sequence manager (proposed) |  |

Full command of step 1 (every step has the same shape; `submit.py` prints each):

```
cmux-ci \
  run \
  --class \
  exclusive \
  --measurement \
  --label \
  measure \
  --pool \
  perf-lead \
  --script \
  scripts/measure/split-spring.sh \
  --ref \
  ce3d9d351f37a196003c962c75a74e2f03596527 \
  --artifact \
  artifacts/split-spring/report.json \
  --key \
  por-ab-p07-04-v223-1 \
  --timeout \
  10440 \
  --arg=--config=69e27553df799423efa487c528aa3a441405d812671b7373565d5d59d9d9d0ec \
  --arg=--vdisplay=120 \
  --arg=--vdisplay-hold=9240 \
  --arg=--suite=proof-ab \
  --arg=--toggle=memorySaverSetting,memoryDiscardInternalPages,memoryDiscardPageTabs,memoryDiscardConversations,topPageDiscard,memoryDiscardSidebarSections,memoryDiscardRemoteTabs,memoryDiscardAgentPagesOverBudget \
  --arg=--inner=memory \
  --arg=--runs=5 \
  --arg=--row=p07-04 \
  --arg=--run-timeout=1800 \
  --arg=--metric=footprint=^samples\.\*\.total_footprint_mb$ \
  --arg=-- \
  --arg=--workspaces=1,10 \
  --arg=--mix=terminal+browser,terminal+chat,terminal \
  --arg=--settle=360 \
  --arg=--config={"memory":{"saver":"aggressive"}}
```

## Rows that need v2.2.4/5-opt or a revert build

| row | mechanism | net lines | bench kind | why not on v2.2.3-opt | owner |
|---|---|---|---|---|---|
| p06-21 | Classify every main hop (codebase migration) | +9,453 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (32/47 tasks in v2.2.3-opt) | sequence manager (proposed) |
| p09-01 | Release trace ring and black box | +9,348 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (16/17 tasks in v2.2.3-opt) | PL-trace |
| p05-08 | Binary frames with priorities on one connection | +8,935 | k2f-stress | needs v2.2.4/5-opt | daemon hot paths (proposed) |
| p05-07 | Generated wire bindings replace hand-written commands | +8,217 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (18/22 tasks in v2.2.3-opt) | daemon hot paths (proposed) |
| p09-02 | Trace recording control, CLI and Perfetto export | +7,618 | k2f-stress | needs v2.2.4/5-opt | PL-telemetry |
| p05-11 | Terminal views as streams on one connection | +6,328 | k2f-light | needs v2.2.4/5-opt | daemon hot paths (proposed) |
| p05-03 | Request-path watchdog and busy-thread stacks | +4,991 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-daemon |
| p04-01 | Input latency ledger and EventLatency stages | +4,916 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (8/10 tasks in v2.2.3-opt) | PL-input |
| p09-03 | Per-key cross-process flow trace | +4,820 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-trace |
| p02-12 | Daemon and holder threads and processes QoS-set | +4,518 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-daemon |
| p05-14 | Fewer daemon threads: sequenced pool and reactor | +4,504 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-daemon |
| p09-07 | Release HangWatcher in every process | +3,884 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-telemetry |
| p09-04 | Catalog trace points for actions and frames | +3,840 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-arch |
| p03-04 | Pane springs on the render server | +3,683 | frames | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (11/12 tasks in v2.2.3-opt) | PL-motion-core |
| p04-03 | debug.input diagnostics and input audits | +3,410 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (5/6 tasks in v2.2.3-opt) | PL-input |
| p02-16 | Background lanes: launch fence and priority | +3,307 | first-5s | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | sequence manager (proposed) |
| p06-23 | Main-thread attribution meters and ledgers | +3,240 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | sequence manager (proposed) |
| p02-06 | Main thread never waits on system calls | +3,033 | first-5s | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (11/12 tasks in v2.2.3-opt) | sequence manager (proposed) |
| p07-19 | Memory diagnostics: debug.memory, discards and reports | +2,735 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (3/6 tasks in v2.2.3-opt) | PL-memory |
| p05-10 | Readers route only; no head-of-line blocking | +2,725 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (3/6 tasks in v2.2.3-opt) | PL-daemon |
| p02-15 | Priority inversion: waiters boost owners | +2,587 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | sequence manager (proposed) |
| p04-05 | One input tap replaces per-area event monitors | +2,561 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (14/15 tasks in v2.2.3-opt) | PL-input |
| p14-11 | acpmux wakes only on events | +2,431 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-acpmux |
| p06-05 | Idle work and aligned timer wakeups | +2,406 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | sequence manager (proposed) |
| p08-17 | Launch traces, marks and debug.startup | +2,384 | launch | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (6/8 tasks in v2.2.3-opt) | first-5s (proposed) |
| p05-16 | Output path: batching, chunking, no per-viewer copy | +2,315 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-daemon |
| p06-01 | Classed main-thread scheduler, input goes first | +2,215 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | sequence manager (proposed) |
| p08-01 | Startup scheduler and best-effort fence | +2,048 | launch | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (8/9 tasks in v2.2.3-opt) | first-5s (proposed) |
| p08-03 | Launch reads and blocking calls off main | +1,992 | launch | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (16/17 tasks in v2.2.3-opt) | first-5s (proposed) |
| p05-09 | Daemon parses each request once | +1,730 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-daemon |
| p03-05 | Chrome motion without per-frame main work | +1,721 | frames | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (8/10 tasks in v2.2.3-opt) | PL-motion-core |
| p02-08 | Pool and global queues never block (module sweeps) | +1,559 | first-5s | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (2/6 tasks in v2.2.3-opt) | sequence manager (proposed) |
| p02-18 | Child exits reaped by one kqueue thread | +1,528 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-daemon |
| p14-17 | Daemon and Rust idle wake sources removed | +1,523 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (1/2 tasks in v2.2.3-opt) | PL-daemon |
| p01-19 | Binary terminal streams on DaemonConnection | +1,381 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt | PL-daemon |
| p02-10 | Hidden terminals' threads drop to utility | +1,339 | k2f-light | needs v2.2.4/5-opt | sequence manager (proposed) |
| p13-10 | Hidden pages stop timers, polls and pushes | +1,296 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-webui |
| p01-18 | Daemon threads pooled, not per terminal | +1,288 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt | PL-daemon |
| p03-18 | Terminal and remote frames presented off main | +1,237 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (3/5 tasks in v2.2.3-opt) | PL-ghostty |
| p04-21 | O(1) key routing | +1,223 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-typing |
| p12-08 | Main-turn and blocking-site field data | +1,195 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-telemetry |
| p04-19 | Key path threads first in cmux-tui | +1,117 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (2/3 tasks in v2.2.3-opt) | PL-daemon |
| p14-10 | Idle acpmux helpers at background priority | +1,114 | idle | needs v2.2.4/5-opt | PL-acpmux |
| p08-14 | Chromium start off the launch path | +1,107 | launch | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (4/5 tasks in v2.2.3-opt) | PL-cef-tab |
| p05-13 | Focused terminal output first, hidden gets none | +1,079 | k2f-stress | needs v2.2.4/5-opt | PL-ghostty |
| p04-17 | Terminal predictive echo | +1,063 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-ghostty |
| p02-09 | Key echo path at user-interactive QoS | +1,049 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-daemon |
| p04-08 | Observation changes delivered once per frame | +1,020 | frames | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | hold-class (proposed) |
| p14-04 | Main-thread timers share one aligned wake | +997 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (10/11 tasks in v2.2.3-opt) | memory/leaks (proposed) |
| p05-23 | Page relay on one connection, off main | +974 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (1/2 tasks in v2.2.3-opt) | daemon hot paths (proposed) |
| p04-18 | Terminal keys go straight to the attach socket | +940 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-ghostty |
| p08-02 | Services built on first use, not launch | +921 | launch | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | first-5s (proposed) |
| p14-19 | App idle wake sources removed | +677 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (7/8 tasks in v2.2.3-opt) | memory/leaks (proposed) |
| p05-15 | Daemon thread QoS and priority inheritance | +662 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt | PL-daemon |
| p03-22 | Main thread draws only what changed | +639 | frames | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (11/13 tasks in v2.2.3-opt) | motion (proposed) |
| p13-25 | debug.webui census, signposts, bench driver | +581 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; partial (2/3 tasks in v2.2.3-opt) | PL-webui |
| p13-22 | Page calls without DevTools | +566 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-webui |
| p03-07 | Pages resize once per spring | +565 | frames | needs v2.2.4/5-opt | PL-cef-layer |
| p13-19 | Shared JS chunk and split page build | +562 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-webui |
| p06-06 | Startup phases defer work past reveal | +544 | launch | needs v2.2.4/5-opt | sequence manager (proposed) |
| p02-07 | Ghostty config and one-time initializers off main | +522 | launch | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-ghostty |
| p03-24 | CEF pump stays inside the frame deadline | +502 | k2f-light | needs v2.2.4/5-opt | PL-cef-layer |
| p06-03 | Priority-ordered main executor hook | +468 | k2f-stress | needs v2.2.4/5-opt | sequence manager (proposed) |
| p12-14 | Lab feature arms and Nightly field trials | +403 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-perf-lab |
| p03-16 | Terminal cursor blinks on the render server | +392 | idle | needs v2.2.4/5-opt | PL-ghostty |
| p13-14 | Pages built only when needed | +370 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-webui |
| p04-02 | Input latency field data in hang reports | +338 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-telemetry |
| p06-18 | Sidebar rebuild in chunks across frames | +333 | k2f-light | needs v2.2.4/5-opt | a590 |
| p07-17 | Wake admission for unrequested tab wakes | +331 | memory | needs v2.2.4/5-opt | PL-memory |
| p14-18 | Swift sleeps and package polls removed | +329 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | memory/leaks (proposed) |
| p04-20 | Ghostty key never waits on renderer | +313 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-ghostty |
| p03-14 | Responsive scrolling for sidebar and palette | +264 | frames | needs v2.2.4/5-opt | motion (proposed) |
| p03-08 | Chromium resize fence | +260 | frames | needs v2.2.4/5-opt | PL-motion-cef |
| p06-02 | Refresh-scaled budget turn after commit | +254 | k2f-stress | needs v2.2.4/5-opt | sequence manager (proposed) |
| p08-15 | First terminal font and Metal prefetch | +217 | first-5s | needs v2.2.4/5-opt | first-5s (proposed) |
| p03-20 | Window frame animation holds content | +214 | frames | needs v2.2.4/5-opt | PL-motion-core |
| p13-15 | Closed page tabs end their engine page | +161 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-webui |
| p09-11 | Sentry auto-instrumentation trimmed | +115 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-telemetry |
| p04-23 | cmux web pages: passive listeners, rAF moves | +96 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-input |
| p02-11 | Declared QoS on every app queue and thread | +90 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | sequence manager (proposed) |
| p12-04 | Bench migration into lab stories | +27 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-perf-lab |
| p12-05 | Lab target stories | +8 | launch | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-perf-lab |
| p07-20 | Memory benches, soak and verification runs | +2 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-memory |
| p01-20 | Person-first lane on the daemon link | +0 | k2f-stress | needs v2.2.4/5-opt | daemon hot paths (proposed) |
| p01-21 | Hidden terminals free their app surface | +0 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-ghostty |
| p01-24 | One MCP helper per agent chat | +0 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-acpmux |
| p03-19 | Ghostty renderer idle and memory cost | +0 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-ghostty |
| p04-04 | Input benches, glass check and proof phase | +0 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-input |
| p05-01 | IPC benches, soak and proof tables | +0 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-daemon |
| p05-17 | Producer-side attach resize coalescing | +0 | frames | needs v2.2.4/5-opt | daemon hot paths (proposed) |
| p05-18 | Shared-memory terminal output ring | +0 | k2f-stress | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-holder |
| p05-19 | Admit then reply (F10) | +0 | k2f-light | needs v2.2.4/5-opt | PL-daemon |
| p05-20 | Reply before terminal spawn | +0 | first-5s | needs v2.2.4/5-opt | PL-daemon |
| p05-21 | Person before automation across connections | +0 | k2f-stress | needs v2.2.4/5-opt | daemon hot paths (proposed) |
| p05-22 | Side clients as streams (journal, loopback, SSH) | +0 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-daemon |
| p09-13 | Observability audit, matrices, benches and docs | +0 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | fleet (proposed) |
| p11-11 | Child-page geometry: per-window dirty set | +0 | frames | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-motion-cef |
| p14-12 | Hidden agent sessions freeze idle harnesses | +0 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-acpmux |
| p14-14 | Idle network sockets stay silent | +0 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | memory/leaks (proposed) |
| p14-16 | App web pages tick only when needed | +0 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | memory/leaks (proposed) |
| p14-20 | Ghostty cursor blink costs no frame | +0 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-ghostty |
| p14-21 | Hidden terminal output batched to 1/s | +0 | idle | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | PL-daemon |
| p15-18 | Tab and window actions show in turn | +0 | k2f-light | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; needs v2.2.4/5-opt (nothing landed yet) | spam (proposed) |
| p13-17 | Settings, History, Cloud preload next page | -167 | k2f-light | needs v2.2.4/5-opt | PL-webui |
| p13-01 | WebUIHost owns every cmux page | -641 | memory | no switch: needs a revert build (optimized tip minus the mechanism) or the program-level build comparison; v2.2.3-opt | PL-webui |

## Planned rows that are not a metric A/B

| row | mechanism | net lines | kind | what proves it | owner |
|---|---|---|---|---|---|
| p09-09 | Crash reports for every process | +6,144 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-telemetry |
| p01-22 | Sandboxed VT worker processes | +5,206 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-daemon |
| p02-14 | Daemon request path never blocks | +4,690 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | PL-daemon |
| p10-17 | Supervised Rust threads and tasks | +4,610 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p10-16 | No blocking calls on tokio workers | +4,092 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p10-08 | Strict memory safety and SAFETY-TODO queue | +3,842 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p10-04 | Fuzz targets, corpus and stateful fuzzers | +2,517 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p06-20 | Direct event delivery instead of broadcasts | +2,301 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | PL-arch |
| p06-08 | Visibility tree: hidden content does no work | +2,290 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | sequence manager (proposed) |
| p10-05 | Hang watch scopes on critical threads | +1,766 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p12-12 | Remote kill switch and feature safe mode | +1,744 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | landing (proposed) |
| p10-24 | Crash keys and unclean-exit metric | +1,364 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p10-15 | Documented unsafe Rust and forbid(unsafe_code) | +1,330 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p03-21 | Pane chrome without Auto Layout | +1,211 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | motion (proposed) |
| p09-06 | Hang reports schema 3 | +1,129 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-telemetry |
| p10-18 | Rust FFI panics never abort cmux | +929 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p07-05 | Discard protection for audible and live pages | +904 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-memory |
| p05-05 | Ordered replies, events and PTY input | +898 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-daemon |
| p02-17 | Quit waits for and bounds background work | +876 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | sequence manager (proposed) |
| p05-12 | One terminal sizing participant per app | +841 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | daemon hot paths (proposed) |
| p04-16 | Intent prewarm of sleeping browser pages | +821 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | PL-switch |
| p10-09 | One safe continuation and callback API | +821 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p15-15 | Input model, replay and attach walk | +801 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-oracle |
| p10-10 | No unowned references without lifetime reason | +494 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p09-08 | Fatal hang reported at next launch | +487 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-telemetry |
| p09-10 | Stability events and counts | +483 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-telemetry |
| p13-13 | Page crash reloads on show | +472 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-webui |
| p03-10 | Chromium pages in the window's layer tree | +453 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | PL-cef-layer |
| p13-21 | Web updates reload only shown pages | +390 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-webui |
| p10-07 | No unreasoned @unchecked Sendable or @preconcurrency | +365 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p06-09 | Hidden native page tabs leave the window | +358 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | sequence manager (proposed) |
| p10-11 | Outside input never traps in Swift | +332 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p06-17 | Sidebar observes only on-screen rows | +307 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | a590 |
| p07-18 | Task Manager shows memory saved | +293 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-memory |
| p10-03 | Sanitizer, Miri and loom lanes | +285 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p01-09 | Permission prompts in the tab bar | +283 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-cefhost |
| p13-12 | Page renderer hang notice | +226 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-webui |
| p01-13 | Unresponsive prompt follows tab visibility | +198 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-cef-layer |
| p08-07 | Crash-streak safe launch | +157 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | first-5s (proposed) |
| p03-12 | Hidden workspaces detach after a grace | +151 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | PL-switch |
| p10-12 | Invariant API: check and notFatalUntil | +133 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p12-06 | Recorded-session corpus and replay | +123 | restore | bench-restore.py runs through its capture-slot script (cp/restore-bench), not split-spring.sh; the restore agent runs it | PL-perf-lab |
| p12-07 | Switch, motion, create and CEF signposts | +95 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | PL-arch |
| p06-24 | Scheduler benches and test phase | +64 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | sequence manager (proposed) |
| p10-02 | VM matrix fuzz and process-chaos lanes | +8 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p01-23 | Long-lived app children under the daemon | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-holder |
| p02-02 | Pre-push threading rules (pool, priority, raw blocking) | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-guardrails |
| p03-23 | Pre-push sync-layout rule | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-guardrails |
| p04-06 | Guardrail: no new NSEvent monitors | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-guardrails |
| p05-24 | Daemon crash survival and crash-loop breaker | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-daemon |
| p05-25 | IPC reader fuzzing | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p06-19 | Visibility-scoped daemon subscription | +0 | switch-scale | app-level switch-scale-bench.py does not exist yet (cp/switch-scale-bench has the fixture and in-process Swift tests only) | sequence manager (proposed) |
| p06-22 | Scheduler guardrails refuse unclassified main hops | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-guardrails |
| p10-01 | Crash-search lab, signatures and issues | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p10-06 | Swift 6 mode and stability settings everywhere | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p10-13 | No uncatchable Objective-C exceptions | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-stability |
| p10-20 | Fork safety, child reaping, bounded queues | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-holder |
| p10-21 | A failing child or page never ends cmux | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-cefhost |
| p10-22 | Crash D class guards on macOS versions | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-stability |
| p10-23 | Corrupt state recovers instead of crashing | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-daemon |
| p11-04 | CmuxNextApp closed to growth | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-arch |
| p11-06 | Phase W: workbench, focus and windows targets | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-arch |
| p11-07 | Layer edges cut: model targets, splits | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-arch |
| p11-08 | Singletons and globals to injected instances | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-arch |
| p11-10 | Broadcasts and observers to typed Signals | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-arch |
| p11-12 | No assumeIsolated outside seam adapters | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-arch |
| p11-13 | Actions act on their explicit target | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-arch |
| p14-03 | Wakeup guardrails and full-tree audit | +0 | gate | a gate row: proof is a recorded catch in the train (decision 2), not a run | PL-guardrails |
| p15-16 | Fuzz, sanitizer and test-scale lanes | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-oracle |
| p15-19 | Terminal host death mid-escape keeps shell | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | PL-daemon |
| p15-20 | Actions refuse instead of silent success | +0 | red/green | a bugfix row: needs its own repro (red with the switch off, green on) from its owner, not a metric A/B | spam (proposed) |

## Planned rows that say "else remove" (the real removal count)

| row | mechanism | net lines | condition in its proof text |
|---|---|---|---|
| p09-01 | Release trace ring and black box | +9,348 | Tooling: overhead A/B on v2.2.4-opt: perf-lab typing-stress key-to-frame p95 and idle-budget wakeups with recording on vs off, and v2.2.4-opt vs nightly-opt; keep only if overhead is within noise and a bench or report reads the output; the ring is read by every trace and crash row below. |
| p05-08 | Binary frames with priorities on one connection | +8,935 | ipcFrames is on an unmerged branch: land it, then A/B on v2.2.5-opt with perf-lab typing-flood-stress (key-to-frame) and bench-daemon-latency --bulk-interference; remove if not landed by 11-04. |
| p05-07 | Generated wire bindings replace hand-written commands | +8,217 | bench-daemon-latency.py --ops all on v2.2.4-opt vs nightly-opt (decode cost per request); no felt number of its own is likely, so the lead must decide keep-as-base-of-frames or remove. |
| p09-02 | Trace recording control, CLI and Perfetto export | +7,618 | Tooling: on v2.2.4-opt (traceControl is on in dev and in the chrome-parity dogfood tag per switch-table.md) record one perf-lab typing-stress run with `cmux trace record` and export; keep it only if a bench or a perf finding uses the export by 11-04, else remove. |
| p09-05 | Field histograms and View Metrics | +5,670 | Tooling: on v2.2.4-opt (metricsView in the dogfood set) run perf-lab typing-stress and compare `cmux metrics` key.frame p95 to the bench; overhead A/B vs nightly-opt. Field upload (134) not landed; remove the store if nothing reads it by 11-04. |
| p05-03 | Request-path watchdog and busy-thread stacks | +4,991 | Name one daemon split or create stall found by a watchdog stack on nightly-opt; else run bench-daemon-latency.py on v2.2.4-opt and show slow_requests with stacks; remove if no stall was found through it by 11-04. |
| p09-03 | Per-key cross-process flow trace | +4,820 | Tooling: one first-5s-typing.py run on v2.2.4-opt with recording on, trace.py shows the per-hop split; Ghostty hook (048) and Chromium tracing (050, 051, 104) are not landed. Overhead A/B in the ring row; remove if no perf fix cites the split. |
| p09-04 | Catalog trace points for actions and frames | +3,840 | Tooling: overhead A/B on v2.2.4-opt: perf-lab typing-stress key-to-frame p95 and idle-budget wakeups with recording on vs off, and v2.2.4-opt vs nightly-opt; keep only if overhead is within noise and a bench or report reads the output; perf-lab launch, switch and motion stories must read these names. |
| p04-03 | debug.input diagnostics and input audits | +3,410 | Name one key-to-frame fix that came from input-turn-hops.py or input-dirty-views.py output on nightly-opt; if none exists by 11-04, remove the recorders (keep debug.input if the ledger row stays). |
| p08-17 | Launch traces, marks and debug.startup | +2,384 | no own number: it is the measuring tool for the launch rows; keep only the parts the perf-lab launch stories read on v2.2.4-opt, remove the rest (field histograms, nightly trace ring) |
| p05-04 | Wire stats and per-method latency histograms | +2,149 | Bench builds keep the histograms anyway: read them in bench-daemon-latency.py on v2.2.4-opt; the Release field switch ipcMethodLatencyFieldData is remove unless someone reads Release field data by 11-04. |
| p10-05 | Hang watch scopes on critical threads | +1,766 | On v2.2.4-opt: a debug-injected block in a watched scope must give one record whose top frame is the blocked function; perf-lab idle-budget story v2.2.4-opt vs nightly-opt shows no new wakeups. 033 (tokio slow-poll) runs only in lab builds: remove if no lab run uses it. |
| p12-08 | Main-turn and blocking-site field data | +1,195 | lab.py field --since 7d shows main-turn p99 per Nightly for the last nightly; if nobody reads the field series by 11-04, remove the unread parts. |
| p10-18 | Rust FFI panics never abort cmux | +929 | Fleet test every_export_is_guarded in the 4 FFI crates at the tip; the CCmuxAppFFI pin must contain 152 (check-app-ffi-pin.sh). No felt number: keep only if a real FFI abort is named. |
| p15-15 | Input model, replay and attach walk | +801 | Linux VM: oracle-input-walk at the tip (670 lines landed); without a named bug by 11-04, remove the walk and keep the attach-machine move only if PL-input wants it. |
| p13-23 | Page push channel to pages | +364 | only if the pinned fork is at API 43: A/B on v2.2.4-opt (NOT in the chromeParity set): CMUX_ENABLE_FEATURES=pagePushChannel vs off, perf-lab sidebar-churn-typing story; else remove |
| p04-02 | Input latency field data in hang reports | +338 | One hang report from v2.2.4-opt with the default-off field feature on, accepted by schema 3 with non-empty input_latency[]; remove if nobody reads the field rows by 11-04. |
| p10-03 | Sanitizer, Miri and loom lanes | +285 | sanitizer-sweep.sh --sanitize thread,address on one closure test target at the tip (fleet isolated step), fix one finding; else remove. 012 put 73 lines into the app (SanitizerRuntime.swift); check they compile out of Release. |
| p08-06 | Crash forwarders run after startup | +78 | A/B on v2.2.4-opt (switch is NOT in the chromeParity set): CMUX_ENABLE_FEATURES=crashForwardersAfterStartup vs off, perf-lab launch-cold and launch-warm stories; expect a small number, remove if under noise |
| p06-24 | Scheduler benches and test phase | +64 | Tooling: run the landed counters (229) inside switch-scale-bench.py on v2.2.4-opt vs nightly-opt; the unwritten benches (150, 152, 230) and the test phase (160) are planned only; remove the counters if no bench reads them. |
| p13-05 | Renderer-less spare placeholder tab | +43 | only if the pinned fork has the renderer-less placeholder (017 not landed): A/B on v2.2.4-opt (in the chromeParity dogfood set, so on by tag): default vs CMUX_DISABLE_FEATURES=rendererlessSpareWindow, perf-lab idle-tabs at Home (renderer count and RSS); else remove |
| p01-20 | Person-first lane on the daemon link | +0 | A/B daemonPersonInputLane on vs off on an optimized build, perf-lab typing story under STRESS agent output; switch is on an unmerged branch, so remove unless it merges before v2.2.5-opt |
| p01-21 | Hidden terminals free their app surface | +0 | nothing landed: v2.2.5-opt vs nightly-opt, leak-harness.py --resource-bench resource-minimum with 20 hidden terminals; else remove |
| p01-23 | Long-lived app children under the daemon | +0 | nothing landed: red/green perfLabKillProbe app kill on an optimized build after 239 lands; else remove |
| p01-24 | One MCP helper per agent chat | +0 | nothing landed: v2.2.5-opt vs nightly-opt, leak-harness.py --resource-bench with 10 agent chats (helper processes and RSS); else remove |
| p03-19 | Ghostty renderer idle and memory cost | +0 | perf-lab idle-tabs story with 20 terminals, v2.2.4-opt vs nightly-opt. All five tasks have nothing landed: remove if none lands by 11-04. |
| p03-23 | Pre-push sync-layout rule | +0 | No build: replay one of the 067 forced-layout sites against guardrails.py and show it is refused. Nothing landed: remove if not written by 11-04. |
| p04-06 | Guardrail: no new NSEvent monitors | +0 | Not landed: run guardrails.py on a commit that re-adds a monitor (red) and on the tip (green); remove if it does not land by 11-04. |
| p05-17 | Producer-side attach resize coalescing | +0 | Switch is on an unmerged branch: land it, then A/B on v2.2.5-opt with a perf-lab motion story (divider drag over terminals); remove if not landed by 11-04. |
| p05-18 | Shared-memory terminal output ring | +0 | Nothing landed: if landed, perf-lab typing-flood-stress A/B on v2.2.5-opt; otherwise remove the planned code by 11-04. |
| p05-19 | Admit then reply (F10) | +0 | Switch is on an unmerged branch and nothing landed: if landed, A/B admitThenReply on v2.2.5-opt with split-spring.sh newterm; otherwise remove by 11-04. |
| p05-20 | Reply before terminal spawn | +0 | Switch is on an unmerged branch: if landed, A/B terminalAsyncStart on v2.2.5-opt with new-terminal-first-keys.py; otherwise remove by 11-04. |
| p05-21 | Person before automation across connections | +0 | Switch is on an unmerged branch: if landed, A/B daemonPersonFirst on v2.2.5-opt with bench-daemon-latency.py --automation-storm 8 and perf-lab typing-stress; otherwise remove by 11-04. |
| p05-22 | Side clients as streams (journal, loopback, SSH) | +0 | Nothing landed: if landed, split-spring.sh newterm over an SSH machine on v2.2.5-opt vs nightly-opt; otherwise remove by 11-04. |
| p05-24 | Daemon crash survival and crash-loop breaker | +0 | Nothing landed: if landed, kill -9 the daemon during a flood on v2.2.5-opt and time until every stream is READY; otherwise remove by 11-04. |
| p05-25 | IPC reader fuzzing | +0 | Nothing landed: remove unless a fuzz run finds a real reader crash by 11-04. |
| p10-06 | Swift 6 mode and stability settings everywhere | +0 | no build: a scratch commit that adds a target without the settings, and one that edits a closure Package.swift setting by hand; prepush-gate.py --base <tip> --head <scratch> must refuse both. Remove the MessagesLab flips if no data race found in them is named. |
| p10-13 | No uncatchable Objective-C exceptions | +0 | no build: crash_ratchet.py --report objc_raises on the tip vs the #14786 parent must list the site; nothing landed (166-170 empty): remove unless made a refusing local rule with a named bug. |
| p11-06 | Phase W: workbench, focus and windows targets | +0 | Key-to-frame and switch-scale non-regression after the moves (perf-lab typing story, switch-scale-bench.py) v2.2.5-opt vs nightly-opt; these paths are owned by PL-switch, PL-typing, PL-cef-tab, PL-motion-cef. p11 has no landed product lines: remove if nothing lands. |
| p14-03 | Wakeup guardrails and full-tree audit | +0 | No build: replay the removed acpmux 1 s wait poll through guardrails.py and show it is refused. Nothing landed: remove if not written by 11-04. |
| p14-12 | Hidden agent sessions freeze idle harnesses | +0 | idle-budget agent session with 3 hidden agent panes, v2.2.4-opt vs nightly-opt. Nothing landed: remove if not landed by 11-04. |
| p14-14 | Idle network sockets stay silent | +0 | idle-budget signed-in session (network wakes), v2.2.4-opt vs nightly-opt. Nothing landed: remove if not landed by 11-04. |
| p14-16 | App web pages tick only when needed | +0 | idle-budget home session (WebContent wakes), v2.2.4-opt vs nightly-opt. Nothing landed: remove if not landed by 11-04. |
| p14-21 | Hidden terminal output batched to 1/s | +0 | idle-tabs story with 10 hidden terminals streaming output, v2.2.4-opt vs nightly-opt. Nothing landed: remove if not landed by 11-04. |
| p15-16 | Fuzz, sanitizer and test-scale lanes | +0 | Linux VM: the resource-op fuzzer 30 min at the tip; nothing landed. Merge with p10's lanes or remove. |

## How a result is written

`collect.py` writes one row per finished step to `proof-runs/results.jsonl`: row id, job, host, macOS, build (v2.2.3-opt, job, commit,
artifact sha256, config), bench, switches, runs valid per arm, per metric the on/off p50/p95/p99/max, per-run p95, noise band, effect,
Mann-Whitney p and verdict. The prove-or-remove table and the switch table then cite it as the proof cell:
`proven: job <id>, <host>, v2.2.3-opt 1b856ace18a, <bench>, <metric> on p95 <x> vs off <y> (effect <d>, band <b>, p <p>, 5+5 runs)`, or
`not proven: job <id> ... (<why>)`. A "not proven" run is evidence for the 11-04 removal list, not a reason to rerun with new arguments.
