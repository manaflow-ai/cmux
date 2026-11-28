# Bench coverage map

Leo, 2026-11-27: "so i guess our other benches hadn't reached that? hm. did we map out all the benches of
everything else too?"

They hadn't. cmux#59531 put a 160 KB settings encode inside every sidebar row's Chief pictures. At 1,100
workspaces it caused 2-6 s main-thread hangs, and no bench saw it. `SidebarLagBench` and
`SidebarScrollBench` build N workspaces, but they have no Chiefs and no large cmux.json, and nothing runs
them on a pull request. This page lists every risky area, the benches that cover it, and the gaps. The
decision and the gap ranking are in cmuxterm-hq RFD 0186 (fast benches for risky areas).

`tests/test_bench_coverage_map.py` keeps this page whole. It fails when:

- a bench registered in `scripts/bench/benches/` is missing from the cmux-bench table, or the table
  lists a bench that is not registered;
- a Swift bench suite in a `Tests/` or `UITests/` folder (a type named `…Bench`, `…BenchTests`,
  `…Benchmark`, `…BenchmarkTests`, `…Bench…UITests` or `…PerformanceTests`) is missing from the Swift
  table, or a listed type has gone;
- a Rust bench in a crate's `benches/` folder is missing, or a `webviews/bench/` bench file matches no
  glob in the web table;
- a risky path is missing from the risky paths table, or a listed path no longer exists.

To add a bench, add its row here in the same pull request.

## Scale

A fixture counts as realistic when it reaches the scale of Lawrence's and Leo's real sessions:

| dimension | scale |
|---|---|
| workspaces in the sidebar | 1,100 (Lawrence, 2026-11-27 hang) |
| sessions (loose sidebar rows) | 10,789 (Leo, cmuxterm-hq#13493) |
| cmux.json / settings fileRoot | 160 KB |
| Chiefs | 5, each with its own pet picture |
| chat transcript | 100k rows; 1 GB on disk |
| concurrent streaming chats | 20 |

"On PR" means a pull request that touches the area's paths runs the bench and fails when it regresses.
A bench that only prints a number, runs behind an env var, runs only in the perf cron, or reports
without failing is "no". The perf cron (`cmux-next-perf-budgets.yml`) is advisory, runs after merge, and
fails nothing.

## Risky paths

These are the areas where one change can freeze the main thread or blow up bytes, frames or memory at
scale. Ranks match the RFD: 1 is the highest risk.

| rank | area | path | benches | fixture at scale | on PR | gap |
|---|---|---|---|---|---|---|
| 1 | Swift↔Rust bridge (sync calls from the main actor) | `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeRules.swift` | none | none | no | No bench counts payload bytes per call or calls per frame. A fileRoot sent per row goes unseen. |
| 1 | Swift↔Rust bridge | `Packages/macOS/CmuxNext/Sources/CmuxNextChiefPetWiring/WelcomeRule.swift` | `ChiefFaceFlushBenchTests` (lane/main-thread-sync-bridge) | 1,104 rows × 5 Chiefs, 160 KB | yes, by path (lead's PR) | The bench is one call site; the bridge as a whole has no bytes or calls budget. |
| 1 | Swift↔Rust bridge | `cmux-tui/crates/cmux-home-rules` | none | none | no | Same as above, from the Rust side. |
| 1 | Swift↔Rust bridge | `cmux-tui/crates/cmux-app-ffi` | none | none | no | No per-call cost bench. |
| 2 | Sidebar row feed and flush | `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar` | `SidebarLagBench`, `SidebarScrollBench`, `SidebarStructuralChangeBenchTests`, `SidebarHoverCardRetargetBenchTests`, `ChiefFaceFlushBenchTests` | covered by lane/main-thread-sync-bridge: Chiefs and a 157 KB settings fixture; structural changes at 10,789 rows | covered by lane/main-thread-sync-bridge (PR CI by path, flush under 250 ms) | Before that PR: no Chiefs, no large cmux.json, no budget, never run on a PR. |
| 2 | Sidebar row mapping | `Packages/macOS/CmuxNext/Sources/CmuxNextBridge/SidebarMapping+Face.swift` | `ChiefFaceFlushBenchTests` | 1,104 rows × 5 Chiefs | covered by lane/main-thread-sync-bridge | none once it lands |
| 2 | Chief pictures | `Packages/macOS/CmuxNext/Sources/CmuxNextChiefPetWiring/ChiefMascotPicks.swift` | `ChiefFaceFlushBenchTests` | 160 KB | covered by lane/main-thread-sync-bridge | none once it lands |
| 3 | Agent pane transport (daemon → pane) | `Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane` | `AgentPaneTransportBench`, `AgentPaneTransportBenchParse`, `AgentPaneBridgeHopBench`, `AgentPageProviderBridgeGapBench`, `ChatTailJSONPathBench`, `AcpmuxPaneInboundScanBench`, `app-stream-bytes` | 300-1,000 frames; app-stream-bytes uses 20 chats | no (env-gated or no threshold) | No budget on a pull request; frames only reach hundreds, not a 100k-row chat. |
| 4 | acpmux daemon (send, watch, list) | `cmux-tui/crates/acpmux` | `v2`, `icount`, `turn_overhead`, `acpmux-watch-bytes`, `agent-turn`, `daemon-latency`, `coord-sim`, `session-benches`, `AcpmuxChatRowsBench` | 20 chats; `AcpmuxChatRowsBench` 100k rows (ratio ≤ 1.2) | partly: cmux-tui-spec checks that v2 emits its rows (no timing); `AcpmuxChatRowsBench` when its target runs | v2 timing runs after merge only. |
| 4 | acpmux core | `cmux-tui/crates/acpmux-core` | `v2`, `icount` | synthetic | no timing on a PR | Same as above. |
| 5 | Chat index and transcripts (Rust) | `cmux-tui/crates/cmux-chat-index` | `chat-size`, `transcript-shifts` | 1 MB-4 GB; 50k rows | no | Manual or cron only. |
| 6 | Agent chat transcript (web) | `webviews/src/agent-session` | `webviews/bench/transcript-*.bench.ts`, `webviews/bench/chat-*.bench.ts`, `webviews/bench/million-event-chat.bench.ts`, `snappy`, `typing`, `pane-resize-drag` | 100k rows and 1M events exist | report only: chat-open-perf-report (no fail) | About 150 web benches never fail a pull request. |
| 6 | Sidebar chat list (web) | `webviews/src/sidebar` | `webviews/bench/sidebar-chats-*.bench.ts`, `webviews/bench/all-chats-list.bench.ts`, `webviews/bench/session-*.bench.ts` | session-scale fixtures | no | Not run on a pull request. |
| 6 | Diff view | `webviews/src/diff-viewer`, `webviews/src/find`, `webviews/src/diff-stream.ts` | `diff-stream`, `diff-find-scale` | 100k-line file, 10k-file stream | no | Find and stream op counts and budgets in `webviews/test/diff-find-scale.test.ts`; the stream bench is the area's `run`. |
| 6 | Model picker search | `webviews/src/agent-session/acpmux/modelSearch.ts`, `webviews/src/agent-session/acpmux/modelQuery.ts`, `webviews/src/agent-session/acpmux/ModelPicker.tsx`, `webviews/src/agent-session/acpmux/QuickModelMenu.tsx`, `webviews/src/agent-session/acpmux/modelPicker*.ts` | `model-picker-search` | 5,000 router models | no | Per keystroke ≤ 2 ms at 5,000 models; the bench fails open on a loaded host. |
| 7 | Main-actor work in the app target | `Packages/macOS/CmuxNext/Sources/CmuxNextApp` | `MainTaskRecordBench`, `ActionBudgetMonitorBench`, `stress`, `typing-native` | stress has a scale preset | no (env-gated, manual) | Lint only: `scripts/cmux-next/check-main-actor-work.py`. |
| 8 | Terminal | `Packages/macOS/CmuxNext/Sources/CmuxNextTerminal` | `TerminalLaunchFrameKeeperBenchTests`, `terminal-throughput-quick` | not at scale | no | Manual only. |
| 8 | Tabs, panes, spaces | `Packages/macOS/CmuxNext/Sources/CmuxNextPages` | `TabSwitchPathBench`, `TabSwitchCycleBench`, `TabSwitchViewSwapBench`, `TabStripSelectionBench`, `TabStripFollowsPaneTickBench`, `SpaceSwitchBench`, `PaneMotionBench`, `PaneContentPolicyBench`, `LayoutDragBench`, `PageHostPoolClaimReadyBenchmark`, `KeyRouterBench` | 30 tabs | partly: ungated suites run when their target runs, without a budget, except `PaneMotionBench` (env-gated) | No fail threshold on a pull request. |
| 9 | Palette and omnibar | `Packages/macOS/CmuxNext/Sources/CmuxNextPalette` | `PaletteBenchmarkTests`, `CmdPRankBench`, `OmniboxPhaseABenchmarkTests`, `OmnibarOpenTabsPerKeyBench`, `omnibar`, `newtab` | 1,000-2,000 items | yes when the target runs (median and p99 budgets) | `CmdPRankBench` is env-gated. |
| 10 | iOS workspace sync and live link | `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive` | `WorkspaceSyncPerformanceTests`, `LinkSmoothnessBenchTests`, `CloseTabRoundTripBench`, `ResumeLiveBenchTests`, `ResumeMatrixBenchTests`, `TerminalLoadBench`, `TranscriptReadFirstR1Bench`, `mobile-flows` | not at 1,100 workspaces | no | No iOS bench gates a pull request. |
| 10 | iOS terminal | `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal` | `TerminalHistoryWindowBench`, `TerminalScrollBenchUITests` | synthetic | no | Same as above. |
| 11 | Cloud relay and sync | `cmux-tui/crates/cmux-relay` | `cloud-turn`, `bytes-path`, `projection-scale`, `projection-way-back` | real relay; N files | no | Manual only. |
| 11 | Cloud wire | `cmux-tui/crates/cmux-cloud-wire` | `bytes-path` | per folder kind | no | Manual only. |
| 12 | Browser chrome | `Packages/macOS/CmuxNext/Sources/CmuxNextBrowser` | `BrowserChromeSwitchBench`, `BrowserChromeMemoryBench`, `xbench`, `web-vitals` | n/a | the switch bench checks one render per switch | No time budget. |
| 13 | New Tab (web) | `webviews/src/agent-session/acpmux/newtab`, `webviews/src/agent-session/acpmux/NewTabPage.tsx`, `webviews/src/agent-session/acpmux/newTabModel.ts`, `webviews/src/agent-session/acpmux/projectRepos.ts`, `webviews/src/agent-session/acpmux/ProjectChooser.tsx`, `webviews/src/agent-session/acpmux/lastPick.ts` | `webviews/bench/project-picker-open.bench.ts`, `webviews/bench/new-tab-scale.bench.tsx`, `webviews/bench/new-tab-omnibar-keystroke.bench.ts` | 1,000-10,000 projects | for-paths --run (needs Chromium; fails open without it) | No budget yet (RFD 0199 area 2). |
| 13 | Session list readers | `webviews/src/agent-session/acpmux/sessionList.ts`, `webviews/src/agent-session/acpmux/sessionIndex.ts`, `webviews/src/agent-session/acpmux/session-list`, `webviews/src/agent-session/acpmux/steerQueue`, `webviews/src/agent-session/acpmux/dotGrid`, `webviews/src/agent-session/acpmux/ChiefDock.tsx`, `webviews/src/agent-session/acpmux/homeListsModel.ts`, `webviews/src/agent-session/acpmux/newtab/recentProject.ts` | `webviews/bench/session-store-change.bench.ts`, `webviews/bench/session-scale-typing.bench.ts`, `webviews/bench/session-change-cpu.bench.ts` | 10,789 sessions | tests by path | `sessionReaders.dsa` bound test not written yet (RFD 0199 area 7). |
| 13 | Model picker search | `webviews/src/agent-session/acpmux/modelSearch.ts`, `webviews/src/agent-session/acpmux/modelQuery.ts`, `webviews/src/agent-session/acpmux/ModelPicker.tsx`, `webviews/src/agent-session/acpmux/QuickModelMenu.tsx` | none | 5,000 models | tests by path | The scratch bench is not in `webviews/bench` yet (RFD 0199 area 8). |
| 13 | Diff view | `webviews/src/diff-viewer`, `webviews/src/find`, `webviews/src/diff-stream.ts` | `webviews/bench/diff-stream.bench.ts` | 2,000 files | for-paths --run, 10 s | Find per keystroke and while streaming has no bench yet (RFD 0199 area 11). |
| 13 | Pane layout | `Packages/macOS/CmuxNext/Sources/CmuxNextLayout` | `LayoutDragBench`, `PaneMotionBench` | 5-200 panes | tests by path | `LayoutIncrementalBoundTests` not written yet (RFD 0199 area 4). |
| 13 | Terminal core (Rust) | `cmux-tui/crates/ghostty-vt`, `cmux-tui/crates/cmux-terminal-find`, `cmux-tui/crates/cmux-terminal-projection` | `terminal-throughput-quick` | 10k-100k rows | tests by path | No Linux `run` bench (libghostty-vt needs zig); history page-hop test not written yet (RFD 0199 area 10). |
| 13 | Settings schema and window | `webviews/src/pages/settings` | `webviews/bench/settings-search-visible-only.bench.ts`, `webviews/bench/settings-cards-visible-only.bench.ts` | 160 KB | tests by path | none |

## cmux-bench registry

`scripts/bench/cmux-bench list`: harness benches that record to the ledger. None runs on a pull request
as a gate. `stress` has a dispatch-only compare workflow (`cmux-next-stress-bench.yml`).

| bench | area | fixture at scale | on PR |
|---|---|---|---|
| `acpmux-watch-bytes` | acpmux daemon | 20 chats | no |
| `agent-class-duress` | acpmux daemon | full load | no |
| `agent-quota` | CI and agents | one PR | no |
| `agent-turn` | acpmux daemon | stand-in model | no |
| `app-stream-bytes` | agent pane transport | 20 chats | no |
| `ask-card-wait` | agent chat | replayed logs | no |
| `autocloud-repo-ready` | cloud | real repo | no |
| `bundle` | app bundle | n/a | no |
| `bytes-path` | cloud | per folder kind | no |
| `chat-size` | chat index | 1 MB-4 GB | no |
| `chief-latency` | Chief | 15 asks | no |
| `ci-vm-idle` | CI | 24 h inventory | no |
| `claude-vs-acpmux` | acpmux daemon | real model | no |
| `cloud-first-byte` | cloud | Cloud Git active | no |
| `cloud-turn` | cloud | real relay | no |
| `coord-sim` | acpmux daemon | several coordinator chats | no |
| `coordinator-cpu` | acpmux daemon, chat renderer | 20 live subagents | no |
| `daemon-latency` | acpmux daemon | commits | no |
| `desktop-link` | iOS link | n/a | no |
| `dev-loop` | dev loop | n/a | no |
| `download-bridge` | dev loop | n/a | no |
| `ext-reload` | extensions | n/a | no |
| `footprint` | app memory | default session | no |
| `graceful-swap` | web bundle swap | open pages | no |
| `idle` | app idle | default session | no |
| `idle-compare` | app idle | default session | no |
| `launch` | launch | default session | no |
| `launch-background` | launch | default session | no |
| `launch-bare` | launch | empty | no |
| `launch-matrix` | launch | per scenario | no |
| `launch-premain` | launch | n/a | no |
| `launch-reboot` | launch | n/a | no |
| `local-chat` | agent chat | one chat | no |
| `mcp-fanout` | agents | N chats | no |
| `mobile-flows` | iOS | per flow | no |
| `newtab` | tabs | idle and loaded | no |
| `omnibar` | omnibar | n/a | no |
| `pane-compile` | agent pane web | n/a | no |
| `pane-resize-drag` | agent chat web | 200-2,000 turns | no |
| `persona-walk` | first run | fresh install | no |
| `post-update` | update | n/a | no |
| `projection-scale` | cloud | N files | no |
| `projection-way-back` | cloud | N files | no |
| `published-idle` | apps | n/a | no |
| `rivals` | launch | n/a | no |
| `screen-share` | screen share | n/a | no |
| `session-benches` | acpmux daemon | long session | no |
| `snappy` | agent chat | one chat | no |
| `stress` | main thread | scale preset | no (dispatch compare) |
| `tailnet-stable-node` | network | n/a | no |
| `terminal-throughput-quick` | terminal | n/a | no |
| `tool-transport` | acpmux daemon | n/a | no |
| `transcript-shifts` | agent chat | 500 and 50k rows | no |
| `tui-idle` | acpmux daemon | idle | no |
| `typing` | composer | 100k rows | no |
| `typing-native` | main thread | L0-L5 loads | no |
| `wallpaper_cost` | wallpaper | n/a | no |
| `web-vitals` | web | n/a | no |
| `workspace-factory` | CI | n/a | no |
| `xbench` | browser | n/a | no |

## Swift bench suites

Suites in `Tests/` and `UITests/`. "Gate" names the env var that must be set for the suite to run.
Without one, the suite runs whenever the pull request route selects its test target. "Budget" says
whether it fails on a number.

| suite | path | gate | budget |
|---|---|---|---|
| `AcpmuxChatRowsBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextDaemonTests/AcpmuxChatRowsBench.swift` | none | 100k-row p95 within 1.2× of 100 rows |
| `AcpmuxPaneInboundScanBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AcpmuxPaneInboundScanBench.swift` | none | no |
| `ActionBudgetMonitorBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextActionsTests/ActionBudgetMonitorBench.swift` | `CMUX_ACTION_BUDGET_BENCH` | no |
| `AgentCLIHybridBenchUITests` | `cmux-next-ios/UITests/AgentCLIHybridBenchUITests.swift` | UI test plan | no |
| `AgentCLIHybridBenchCodexUITests` | `cmux-next-ios/UITests/AgentCLIHybridBenchUITests.swift` | UI test plan | no |
| `AgentCLIHybridBenchHybridOnlyUITests` | `cmux-next-ios/UITests/AgentCLIHybridBenchUITests.swift` | UI test plan | no |
| `AgentCursorTailBenchTests` | `Packages/macOS/CmuxRemote/Tests/CmuxRemoteComputerUseTests/AgentCursorTailBenchTests.swift` | `CMUX_TAIL_BENCH` | no |
| `AgentCursorVisibilityResolveBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/AgentCursorVisibilityResolveBench.swift` | `CMUX_AGENT_CURSOR_VISIBILITY_BENCH` | no |
| `AgentPageProviderBridgeGapBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPageProviderBridgeGapBench.swift` | `CMUX_SWIFT_TEST_SUITE_TIMEOUT_SECONDS=901` | no |
| `AgentPaneBridgeHopBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPaneBridgeHopBench.swift` | `CMUX_PANE_TRANSPORT_BENCH` | no |
| `AgentPaneTransportBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPaneTransportBench.swift` | `CMUX_PANE_TRANSPORT_BENCH` | no |
| `AgentPaneTransportBenchParse` | `Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AgentPaneTransportBenchParse.swift` | `CMUX_PANE_TRANSPORT_BENCH` | no |
| `BrowserChromeMemoryBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/BrowserChromeMemoryBench.swift` | none | no |
| `BrowserChromeSwitchBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/BrowserChromeSwitchBench.swift` | none | one render per switch |
| `ChiefFaceFlushBenchTests` | pending lane/main-thread-sync-bridge (CmuxNextAppTests) | none | one flush under 250 ms at 1,104 rows × 5 Chiefs, 160 KB |
| `ChatTailJSONPathBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/ChatTailJSONPathBench.swift` | `CMUX_CHAT_TAIL_BENCH` | after faster than before |
| `ChiefLiveLayoutPerformanceTests` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileChiefTests/ChiefLiveLayoutPerformanceTests.swift` | `CMUX_CHIEF_LIVE_PERF` | no |
| `CloseTabRoundTripBench` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/CloseTabRoundTripBench.swift` | `CMUX_TRACE_FILE` | yes |
| `CmdPRankBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextPaletteTests/CmdPRankBench.swift` | `CMUX_CMDP_RANK_BENCH` | no |
| `CmuxDialogLatencyBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextDesignTests/CmuxDialogLatencyBench.swift` | `CMUX_DIALOG_BENCH` | no |
| `ExtensionsMenuPerformanceTests` | `Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/ExtensionsMenuPerformanceTests.swift` | a display | yes: open and hover within a frame, calibrated to the host (`FrameBudgetCalibration`) |
| `KeyRouterBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/KeyRouterBench.swift` | `CMUX_BENCH` | no |
| `KeyboardInjectBenchUITests` | `cmux-next-ios/UITests/KeyboardInjectBenchUITests.swift` | UI test plan | no |
| `KeyboardMotionBenchUITests` | `cmux-next-ios/UITests/KeyboardMotionBenchUITests.swift` | `cmux-next-ios-keyboard-motion.yml` (push) | no |
| `LayoutDragBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/LayoutDragBench.swift` | `CMUX_DRAG_BENCH` | no |
| `LinkSmoothnessBenchTests` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/LinkSmoothnessBenchTests.swift` | none | yes |
| `MainTaskRecordBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextControlTests/MainTaskRecordBench.swift` | `CMUX_MAIN_TASK_RECORD_BENCH` | no |
| `MobileBenchFlowsUITests` | `cmux-next-ios/UITests/MobileBenchFlowsUITests.swift` | `mobile-flows` harness | no |
| `OmnibarOpenTabsPerKeyBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/OmnibarOpenTabsPerKeyTests.swift` | `CMUX_OMNIBAR_TABS_BENCH` | no |
| `OmniboxPhaseABenchmarkTests` | `Packages/macOS/CmuxNext/Tests/CmuxNextBrowserTests/OmniboxPhaseABenchmarkTests.swift` | none | p99 under 8-10 ms |
| `OutgoingGradientDrawCostBench` | `Packages/Shared/CmuxMessagesLab/Tests/MessagesLabHomeTests/OutgoingGradientDrawCostBench.swift` | none | no |
| `PageHostPoolClaimReadyBenchmark` | `Packages/macOS/CmuxNext/Tests/CmuxNextPagesTests/PageHostPoolClaimReadyBenchmark.swift` | `CMUX_PAGE_CLAIM_BENCH` | no |
| `PaletteBenchmarkTests` | `Packages/macOS/CmuxNext/Tests/CmuxNextPaletteTests/PaletteBenchmarkTests.swift` | none | median under 2× budget |
| `PaneContentPolicyBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/PaneContentPolicyBench.swift` | `CMUX_PANE_BENCH` | no |
| `PaneMotionBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/PaneMotionBench.swift` | `CMUX_PANE_BENCH` | layout p95 |
| `PeerTurnEndCostBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/PeerTurnEndCostBench.swift` | `CMUX_PEER_TURN_END_BENCH` | no |
| `RemoteDecodeRangeBenchTests` | `Packages/macOS/CmuxNext/Tests/CmuxNextRemoteViewTests/RemoteDecodeRangeBenchTests.swift` | `CMUX_RD_DECODE_BENCH` | no |
| `ResumeLiveBenchTests` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/ReconnectChainTimingTests.swift` | `CMUX_RESUME_LIVE_BENCH` | yes |
| `ResumeMatrixBenchTests` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/ReconnectChainTimingTests.swift` | `CMUX_RESUME_LIVE_BENCH` | no |
| `ResumeStagesBenchTests` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/ReconnectChainTimingTests.swift` | `CMUX_RESUME_LIVE_BENCH` | no |
| `AnimationFrameBenchUITests` | `cmux-next-ios/UITests/AnimationFrameBenchUITests.swift` | UI test plan | no |
| `RotateBenchUITests` | `cmux-next-ios/UITests/RotateBenchUITests.swift` | UI test plan | no |
| `SentryScrubCostBench` | `Packages/Shared/CmuxSentryTelemetry/Tests/CmuxSentryScrubbingTests/SentryScrubCostBench.swift` | `CMUX_SENTRY_SCRUB_BENCH` | no |
| `SidebarHoverCardRetargetBenchTests` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SidebarHoverCardRetargetBenchTests.swift` | `CMUX_HOVER_RETARGET_BENCH` | p95 under 8 ms scaled |
| `SidebarLagBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SidebarLagBench.swift` | none (a harness other tests drive) | covered by lane/main-thread-sync-bridge |
| `SidebarScrollBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SidebarScrollBench.swift` | none (a harness other tests drive) | covered by lane/main-thread-sync-bridge |
| `SidebarStructuralChangeBenchTests` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SidebarStructuralChangeBenchTests.swift` | none | no (prints 100 vs 10,789) |
| `SnappySendBenchUITests` | `cmux-next-ios/UITests/SnappySendBenchUITests.swift` | UI test plan | no |
| `SpaceSwitchBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SpaceSwitchBench.swift` | none | no |
| `TabStripFollowsPaneTickBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/TabStripFollowsPaneTickBench.swift` | `CMUX_KEY_RESIZE_STRIP_BENCH` | no |
| `TabStripSelectionBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/TabStripSelectionBench.swift` | none | no |
| `TabSwitchCycleBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/TabSwitchCycleBench.swift` | none | no |
| `TabSwitchPathBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/TabSwitchPathBench.swift` | none | no |
| `TabSwitchViewSwapBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/TabSwitchViewSwapBench.swift` | `CMUX_TAB_SWITCH_BENCH` | no |
| `TerminalHistoryWindowBench` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileTerminalTests/TerminalHistoryWindowBench.swift` | `CMUX_VIEWPORT_WINDOW_BENCH` | no |
| `TerminalLaunchFrameKeeperBenchTests` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/TerminalLaunchFrameKeeperBenchTests.swift` | `CMUX_KEEP_FRAMES_BENCH` | no |
| `TerminalLoadBench` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/TerminalLoadBench.swift` | `CMUX_TERMINAL_LOAD_BENCH` | no |
| `TerminalScrollBenchUITests` | `cmux-next-ios/UITests/TerminalScrollBenchUITests.swift` | UI test plan | yes |
| `TranscriptReadFirstR1Bench` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/TranscriptReadFirstR1Bench.swift` | none | no |
| `WorkspaceSyncPerformanceTests` | `cmux-next-ios/CmuxMobileKit/Tests/CmuxMobileLiveTests/WorkspaceSyncPerformanceTests.swift` | none | no |

A row whose path cell reads "pending <branch>" is a suite on an open branch: the test lets it be absent until the branch lands, then wants its path.

## Rust benches

| bench | on PR |
|---|---|
| `cmux-tui/crates/acpmux/benches/v2.rs` | cmux-tui-spec checks that it emits its gate rows, without timing; timed after merge in cmux-next-quality-report |
| `cmux-tui/crates/acpmux/benches/icount.rs` | no (baseline file kept beside it) |
| `cmux-tui/crates/acpmux/benches/turn_overhead.rs` | no |
| `cmux-tui/crates/cmux-api-compat/benches/rex_parity.rs` | no |
| `cmux-tui/crates/cmux-api-compat/benches/version_pin.rs` | no |
| `cmux-tui/crates/cmux-launch-record/benches/read.rs` | no |

## Web benches

`webviews/bench/` (Playwright, run with bun). Only the chat-open files run on a pull request, as a report
that fails nothing (`chat-open-perf-report.yml`). The degenerate-lab smoke preset runs on its own paths
and gates nothing. The rest run in the perf cron's web UI suite or by hand.

| glob | area | on PR |
|---|---|---|
| `webviews/bench/chat-*.bench.ts` | agent chat open, switch, scroll, 100k flat | chat-open: report only |
| `webviews/bench/transcript-*.bench.ts` | transcript scroll, resize, replay, turn end | no |
| `webviews/bench/million-event-chat.bench.ts` | 1M-event chat | no |
| `webviews/bench/degenerate-chat-frames.bench.ts` | degenerate chats | smoke on its own paths, no fail |
| `webviews/bench/thread-*.bench.ts` | thread rail and minimap | no |
| `webviews/bench/markdown-*.bench.ts` | markdown | no |
| `webviews/bench/composer-*.bench.ts` | composer | no |
| `webviews/bench/send-*.bench.ts` | send motion and paint | no |
| `webviews/bench/home-composer-tti.bench.ts` | Home composer | no |
| `webviews/bench/shared-renderer-typing.bench.ts` | typing | no |
| `webviews/bench/sidebar-chats-*.bench.ts` | sidebar chat list | no |
| `webviews/bench/all-chats-list.bench.ts` | all chats list | no |
| `webviews/bench/session-*.bench.ts` | session scale | no |
| `webviews/bench/project-picker-open.bench.ts` | project picker | no |
| `webviews/bench/inline-text-hasmarks.bench.ts` | inline text marks | no |
| `webviews/bench/subsession-reply-height.bench.ts` | subsession reply height | no |
| `webviews/bench/terminal-history-offscreen.bench.ts` | terminal history, offscreen turns | no |
| `webviews/bench/renderer-idle-growth.bench.ts` | renderer idle memory growth (RFD 0062) | no |
| `webviews/bench/webkit-push-growth.bench.ts` | WebKit growth per pushed script (RFD 0062) | no |
| `webviews/bench/cloud-*.bench.ts` | cloud feed | no |
| `webviews/bench/cloud-page-first-row.bench.tsx` | cloud page | no |
| `webviews/bench/daemon-gate-relink.bench.tsx` | daemon relink | no |
| `webviews/bench/diff-*.bench.ts*` | diff viewer | no (perf cron) |
| `webviews/bench/diff-stream.bench.ts` | diff stream (`diff-stream`), the Diff view area's `run`; its find op counts, oracle and budgets are the test `webviews/test/diff-find-scale.test.ts` (`diff-find-scale`, run in webviews tests) | via `for-paths --run` |
| `webviews/bench/model-picker-search.bench.ts` | model picker keystroke at 5,000 models (`model-picker-search`) | via `for-paths --run` |
| `webviews/bench/new-tab-*.bench.ts*` | new tab | no |
| `webviews/bench/*-visible-only.bench.ts` | page virtualization | no |
| `webviews/bench/apps-catalog-*.bench.ts` | apps catalog | no |
| `webviews/bench/glass-*.bench.ts` | glass surfaces | no |
| `webviews/bench/agent-*.bench.ts` | agent pane idle, activity | no |
| `webviews/bench/host-line-shift*.bench.ts` | layout shift | no |
| `webviews/bench/scroll-edges-idle.bench.ts` | idle frames | no |
| `webviews/bench/idle-frame-sources.bench.ts` | idle frames | no |
| `webviews/bench/wheel-tick-scaling.bench.ts` | scroll | no |
| `webviews/bench/pane-resize-drag.bench.ts` | pane resize | no |
| `webviews/bench/edit-turns-stream.bench.ts` | streaming | no |
| `webviews/bench/streaming-text-frames.bench.ts` | streaming | no |
| `webviews/bench/live-turn-rows.bench.ts` | streaming | no |
| `webviews/bench/delta-renders.bench.ts` | streaming | no |
| `webviews/bench/tool-call-burst.bench.ts` | streaming | no |
| `webviews/bench/turn-end-fold-timing.bench.ts` | streaming | no |
| `webviews/bench/hidden-stream-heap.bench.ts` | memory | no |
| `webviews/bench/state-growth.bench.ts` | memory | no |
| `webviews/bench/page-row-store.bench.ts` | row store | no |
| `webviews/bench/height-index.bench.ts` | row store | no |
| `webviews/bench/virtual-list-item-keys.bench.ts` | lists | no |
| `webviews/bench/visible-lists.bench.ts` | lists | no |
| `webviews/bench/update-one.bench.ts` | lists | no |
| `webviews/bench/render-counts.bench.ts` | renders | no |
| `webviews/bench/ui-stability.bench.ts` | layout shift | no |
| `webviews/bench/settled-page.bench.ts` | page settle | no |
| `webviews/bench/first-load-after-restart.bench.ts` | restart | no |
| `webviews/bench/replay-under-load.bench.ts` | load | no |
| `webviews/bench/power-user-bursts.bench.ts` | load | no |
| `webviews/bench/coord-sim-load.bench.ts` | load | no |
| `webviews/bench/sim-ladder.bench.ts` | load | no |
| `webviews/bench/orchestrator-16.bench.ts` | 16 agents | no |
| `webviews/bench/link-card-appear.bench.ts` | link cards | no |
| `webviews/bench/intl-formatters.bench.ts` | formatting | no |
| `webviews/bench/preview-size-reports.bench.ts` | previews | no |
| `webviews/bench/motion-tabs.bench.ts` | tabs | no |
| `webviews/bench/scene-lazy-stack-*.bench.ts` | scenes | no |
| `webviews/bench/forum-search.bench.ts` | forum search typing | no |
| `webviews/bench/github-*.bench.ts*` | GitHub page | no |

## Agent tooling benches (leo-workspace)

Agents run these tools on every task, so a slow lookup costs every lane. These benches live in
teamleaderleo/leo-workspace, not this tree, so `tests/test_bench_coverage_map.py` does not check this
section. Budget: a warm query under 300 ms, an update under 2 s after one doc changes, and flat at 10x
docs (the ds&a fan-out brief). Each one's correctness test sits beside it.

| bench | tool | scale | result | budget met | test |
|---|---|---|---|---|---|
| `tools/bench_agent_memory_search.py` | `tools/agent-memory search` | 13k sources | p50 1.7 s → 6 ms (leo-workspace#13282) | yes | `tools/test_agent_memory.py` |
| `tools/bench_agent_memory_fingerprint.py` | `agent-memory` staleness fingerprint | 13k sources | 3.6 s → 0.69 s (leo-workspace#13291) | yes (runs in a throttled child, off the query path) | `tools/test_agent_memory.py` |
| `tools/bench_rfd_update.py` | `tools/rfd find` and `rfd update` | 336 and 3,360 docs | at 3,360 docs: query 1,505 → 430 ms; update 6,605 → 1,916 ms, p95 2,492 ms (leo-workspace#13340) | no: the query at 10x and the update p95 are over budget, tracked in leo-workspace#13352 | `tools/test_rfd.py` |
