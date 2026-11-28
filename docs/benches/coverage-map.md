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
| 2 | Sidebar row feed and flush | `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar` | `SidebarLagBench`, `SidebarScrollBench`, `SidebarStructuralChangeBenchTests`, `SidebarHoverCardRetargetBenchTests`, `ChiefFaceFlushBenchTests`, `SidebarChiefLagTests` | Chiefs and a ~160 KB settings fixture at 1,104 rows (`SidebarChiefFixture`, cmux#61230); structural changes at 10,789 rows | yes: `cmux-next-sidebar-bench.yml` by path (cmux#61230), a frame over 250 ms or p95 over 33 ms fails | Before that PR: no Chiefs, no large cmux.json, no budget, never run on a PR. |
| 2 | Sidebar row mapping | `Packages/macOS/CmuxNext/Sources/CmuxNextBridge/SidebarMapping+Face.swift` | `ChiefFaceFlushBenchTests`, `SidebarChiefLagTests` | 1,104 rows × 5 Chiefs | yes: `cmux-next-sidebar-bench.yml` by path (cmux#61230) | none |
| 2 | Chief pictures | `Packages/macOS/CmuxNext/Sources/CmuxNextChiefPetWiring/ChiefMascotPicks.swift` | `ChiefFaceFlushBenchTests`, `SidebarChiefLagTests` | 160 KB | yes: `cmux-next-sidebar-bench.yml` by path (cmux#61230) | none |
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
| 8 | Terminal scrollback reads (daemon `read-scrollback`, find, projection parity) | `cmux-tui/crates/ghostty-vt` | `styled_history_page_bench`, `screen_row_text_bench` (`#[ignore]` tests in `styled_history_tests.rs`, `screen_row_text_tests.rs`) | 10k, 100k and 1M rows × 200 cols, 8,192-row page | partly: oracle and lookup-count tests run with the crate's tests (`a_long_history_page_looks_up_each_page_not_each_row`, under 1,024 lookups a page); timing is by hand | No time budget on a pull request. |
| 8 | Tabs, panes, spaces | `Packages/macOS/CmuxNext/Sources/CmuxNextPages` | `TabSwitchPathBench`, `TabSwitchCycleBench`, `TabSwitchViewSwapBench`, `TabStripSelectionBench`, `TabStripFollowsPaneTickBench`, `SpaceSwitchBench`, `PaneMotionBench`, `PaneContentPolicyBench`, `LayoutDragBench`, `PageHostPoolClaimReadyBenchmark`, `KeyRouterBench` | 30 tabs | partly: ungated suites run when their target runs, without a budget, except `PaneMotionBench` (env-gated) | No fail threshold on a pull request. |
| 9 | Palette and omnibar | `Packages/macOS/CmuxNext/Sources/CmuxNextPalette` | `PaletteBenchmarkTests`, `CmdPRankBench`, `OmniboxPhaseABenchmarkTests`, `OmnibarOpenTabsPerKeyBench`, `omnibar`, `newtab` | 1,000-2,000 items | yes when the target runs (median and p99 budgets) | `CmdPRankBench` is env-gated. |
| 10 | iOS workspace sync and live link | `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive` | `WorkspaceSyncPerformanceTests`, `LinkSmoothnessBenchTests`, `CloseTabRoundTripBench`, `ResumeLiveBenchTests`, `ResumeMatrixBenchTests`, `TerminalLoadBench`, `TranscriptReadFirstR1Bench`, `mobile-flows` | not at 1,100 workspaces | tests by path | Budget is counts the kit tests assert (whole catch-up list, 1 round trip per tab close, 0 whole-tree reads on an unchanged redial); no iOS bench gates a pull request. |
| 10 | iOS terminal | `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileTerminal` | `TerminalHistoryWindowBench`, `TerminalScrollBenchUITests`, `phone-speed` | synthetic; 100 and 10,000 lines | `phone-speed-icount` (Callgrind Ir within 10% of its baseline) | The Swift view layer has no counted budget yet; `phone-speed` counts the projection it renders through. |
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
| 8 | Tab strip and tab names | `Packages/macOS/CmuxNext/Sources/CmuxNextTabs`, `Packages/macOS/CmuxNext/Sources/CmuxNextApp/TabTitleResolver.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentChatTabTitle.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/SubagentTabTitles.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextActions/ActionRegistry+TabStripMenu.swift` | `TabStripSelectionBench`, `TabStripFollowsPaneTickBench`, `TabSwitchPathBench` | 2, 10 and 30 tabs | tests by path | Budgets are counts the work tests assert through `TabStripRowPasses` (0 row walks per switch or close echo, 0 cell writes per still resize); the Swift tests need a Mac. |
| 13 | Update flow | `Packages/macOS/CmuxNext/Sources/CmuxNextUpdater`, `Packages/macOS/CmuxNext/Sources/CmuxNextApp/UpdaterService*.swift`, `Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/DebugUpdater.swift`, `cmux-tui/crates/cmux-app-ffi/src/updater`, `cmux-tui/crates/cmux-app-ffi/src/updater.rs`, `cmux-tui/crates/cmux-update-prewarm-core`, `scripts/cmux-next/update-harness` | `post-update` | n/a (counts) | tests by path | Budgets are counts the update tests assert (0 pauses, 1 download, 0 cards, 1 click); `post-update` is manual. |
| 13 | Launch first frame | `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Launch`, `Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Model/SidebarFirstFrame.swift`, `cmux-tui/crates/cmux-launch-shell` | `launch`, `launch-bare`, `TerminalLaunchFrameKeeperBenchTests` | saved window images | tests by path | 0 opaque cover frames is asserted by `cmux-launch-shell` plan tests on Linux; the Swift reveal tests need a Mac. |
| 13 | Composer hat line (web) | `webviews/src/agent-session/acpmux/subagents` | none | 14 subagents, 6 commands | tests by path | 0 accent words and 0 chips is a real-Chromium test; no bench. |
| 13 | Screen sharing | `cmux-tui/crates/cmux-rd-host`, `cmux-tui/crates/cmux-rd-core`, `cmux-tui/crates/cmux-encode`, `Packages/macOS/CmuxNext/Sources/CmuxNextRemoteView`, `Packages/macOS/CmuxNext/Sources/CmuxNextMacScreen`, `cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileScreenSharing` | `screen-share`, `RemoteDecodeRangeBenchTests` | key to presented frame 100 ms p95 | tests by path | `screen-share` is manual; the per-frame stage ledger (screen_share_fast.present_p95_ms) is read by NOW on the wired Mac pair, not run on a PR. |
| 13 | Remote connect and reconnect | `Packages/macOS/CmuxNext/Sources/CmuxNextMobileHost`, `Packages/macOS/CmuxNext/Sources/CmuxNextRemote` | `remote-connect-phone-production`, `connection-reconnect-chat` | session answers; usable after relaunch | tests by path | Both benches are scheduled probes; a PR here cannot run them. |
| 11 | Cloud start | `cmux-tui/crates/cmux-cloud-start-core`, `cmux-tui/crates/cmux-cloud-environment`, `Packages/macOS/CmuxNext/Sources/CmuxNextCloudStart`, `Packages/macOS/CmuxNext/Sources/CmuxNextCloudPlace` | `cloud-journey-first-text-production`, `cloud-start-matrix-production` | real production start, every folder x team x bypass combination | no | Probes only; no offline bench of start steps a PR runs. |
| 11 | Cloud chat and client | `cmux-tui/crates/cmux-cloud-client`, `Packages/macOS/CmuxNext/Sources/CmuxNextCloud`, `Packages/macOS/CmuxNext/Sources/CmuxNextCloudUI`, `Packages/Shared/CmuxAPIClient` | `cloud-chat-replies-production`, `cloud-chat-attach-production` | real production chat | no | Probes only; no PR-run bench of attach. |
| 11 | Cloud machines | `cmux-tui/crates/cmux-cloud-machine` | `machine-ready-after-create`, `machine-resume`, `cloud-last-seen-cold-start` | real production machine | no | Probes only; cold-start probe needs a Nightly carrying cmux#49806. |
| 11 | Cloud sign-in | `Packages/macOS/CmuxNext/Sources/CmuxNextCloudCredentials`, `Packages/Shared/CmuxAuthRuntime` | `cloud-chat-pro-no-relogin` | real signed-in Nightly | no | Probe only. |
| 11 | Cloud carrier | `cmux-tui/crates/cmux-remote` | `cloud-carrier-ssh-failover`, `cloud-carrier-chaos-staging` | relay killed mid-turn | no | Probes only; chaos probe runs on staging. |
| 11 | Cloud vault | `cmux-tui/crates/cmux-vault-e2e`, `cmux-tui/crates/cmux-vault-egress` | `cloud-machine-no-plaintext-secrets-production`, `cloud-vault-adversarial-production`, `cloud-vault-no-bypass-production` | live production machine, every census attack class | no | Probes only; pass/fail, no timing. |
| 11 | Session transfer | `Packages/macOS/CmuxNext/Sources/CmuxNextSessionTransfer`, `cmux-tui/crates/cmux-session-cloud` | `cloud-session-move-to-cloud-production`, `cloud-session-move-to-local-production`, `session-move-gcp`, `super-highway-moves` | real moves between local, Cloud and GCP | no | Probes only; the offload round trip metric (offload_roundtrip_p95_ms) has no row here. |
| 11 | Connectivity | `Packages/Shared/CmuxConnectivityTelemetry`, `web/services/connectivity` | none | none | no | NOW's connections.within_target_share is the only measure; no bench. |
| 11 | Weft | `cmux-tui/crates/cmux-weft` | none | none | no | NOW's weft.first_byte_s is the only measure; no bench. |
| 13 | Home accessibility | `Packages/macOS/CmuxNext/Sources/CmuxNextHome` | `a11y-baseline` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | acpmux under duress | `cmux-tui/crates/cmux-duress` | `agent-class-duress` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Agent integrations settings | `Packages/macOS/CmuxNext/Sources/CmuxNextAgentIntegrations` | `agent-hooks-in-cmux`, `agent-mcp-in-cmux`, `agent-settings-in-cmux`, `agent-skills-in-cmux` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Onboarding and first run | `Packages/macOS/CmuxNext/Sources/CmuxNextOnboarding`, `Packages/macOS/CmuxNext/Sources/CmuxNextKeys`, `webviews/src/pages/onboarding` | `first-run-one-screen-nightly`, `next-first-run-setup-nightly`, `onboarding-new-person-production`, `agent-shortcut-found-nightly` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Agent lanes orchestrator | `Packages/macOS/CmuxNext/Sources/CmuxNextAgentLanes` | `webviews/bench/orchestrator-16.bench.ts` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Computer Use | `Packages/macOS/CmuxNext/Sources/CmuxNextComputerUse` | `cloud-desktop-agent-production` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Comment round-trip | `webviews/src/comments`, `Packages/macOS/CmuxNext/Sources/CmuxNextTerminalComments` | `cloud-chat-replies-production` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Hang reports | `Packages/macOS/CmuxNext/Sources/CmuxNextHangReports` | none | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | iOS app release | `cmux-next-ios/AppStoreReview`, `cmux-next-ios/CmuxMobileKit` | `ios-app-store-live-production`, `ios-release-bar` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Launch first frame | `Packages/macOS/CmuxNext/Sources/CmuxNextLaunchImages` | `launch`, `launch-bare` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Notification banners | `Packages/macOS/CmuxNext/Sources/CmuxNextNotifications` | `notify-banner-click-nightly` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Screenshot into chat | `Packages/macOS/CmuxNext/Sources/CmuxNextScreenshots` | `screenshot-into-chat-nightly` | none | no | Measured by a scheduled probe or a goal metric NOW reads; no bench a PR runs. |
| 13 | Customization and themes | `cmux-tui/crates/cmux-extension-sdk`, `cmux-tui/crates/cmux-customize`, `cmux-tui/crates/cmux-theme-pack`, `cmux-tui/crates/cmux-agent-customize`, `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Themes` | `customize-composer-nightly`, `feature-flow-looks`, `theme-live-reload-nightly` | 200 saves | tests by path | Measured only by scheduled probes; no PR-runnable bench. |
| 13 | Hibernation and tab discard | `Packages/macOS/CmuxNext/Sources/CmuxNextHibernation`, `cmux-tui/crates/cmux-tab-discard` | `footprint` | 1,000 items or tabs | tests by path | `footprint` is a default session; no 1,000-tab memory bench (NOW infinite_* rows). |
| 13 | Split layout reducer | `cmux-tui/crates/cmux-layout-reducer` | `LayoutDragBench`, `PaneMotionBench` | 5-200 panes | tests by path | No split-scale bench in this tree (cmux#38441). |
| 13 | Composer send and local start | `cmux-tui/crates/cmux-composer-send` | `local-composer-matrix-nightly`, `local-start-matrix-nightly` | n/a (matrix cells) | tests by path | Scheduled probes only. |
| 13 | Classic import | `cmux-tui/crates/cmux-classic-import` | `next-zero-classic-footprint-nightly` | n/a | tests by path | Scheduled probe only. |
| 13 | Daemon recovery | `Packages/macOS/CmuxNext/Sources/CmuxNextDaemonRecovery` | `connection-reconnect-chat` | n/a | tests by path | No bench for relaunch to a drawn chat (restart_to_chat_idle_median_ms). |
| 13 | App bundle size | `scripts/thin-app-bundle.sh`, `scripts/strip-release-bundle.sh` | `bundle` | n/a | tests by path | none |
| 13 | What's new | `scripts/whats-new`, `webviews/src/pages/changelog` | none | n/a | tests by path | Media completeness is a NOW metric over published nightlies; no bench. |

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
| `localization-discovery` | localization tooling | excluded dependency trees (#63387) | no |
| `mcp-fanout` | agents | N chats | no |
| `mobile-flows` | iOS | per flow | no |
| `newtab` | tabs | idle and loaded | no |
| `omnibar` | omnibar | n/a | no |
| `pane-compile` | agent pane web | n/a | no |
| `pane-resize-drag` | agent chat web | 200-2,000 turns | no |
| `phone-speed` | iOS terminal | echo, stream and rotate at 100 and 10,000 rows of scrollback (Callgrind Ir, #63285) | yes (`phone-speed-icount`, when its inputs change) |
| `persona-walk` | first run | fresh install | no |
| `phone-speed` | iOS | 100 and 10,000 terminal lines | yes (`phone-speed-icount`) |
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
| `windowserver` | WindowServer and GPU | idle, typing, spinner, glass/blur, many panes | no |
| `transcript-shifts` | agent chat | 500 and 50k rows | no |
| `tui-idle` | acpmux daemon | idle | no |
| `typing` | composer | 100k rows | no |
| `typing-native` | main thread | L0-L5 loads | no |
| `wallpaper_cost` | wallpaper | n/a | no |
| `web-vitals` | web | n/a | no |
| `windowserver` | WindowServer and GPU | retained workspaces, paired apps | no |
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
| `AnimationFrameBenchUITests` | `cmux-next-ios/UITests/AnimationFrameBenchUITests.swift` | none (UI test target) | no |
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
| `MachineWorkspaceResourceLookupBenchTests` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/MachineWorkspaceResourceLookupBenchTests.swift` | none | a lookup at 11,000 workspaces at most 4x one at 110 (#61663) |
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
| `RotateBenchUITests` | `cmux-next-ios/UITests/RotateBenchUITests.swift` | UI test plan | no |
| `SentryScrubCostBench` | `Packages/Shared/CmuxSentryTelemetry/Tests/CmuxSentryScrubbingTests/SentryScrubCostBench.swift` | `CMUX_SENTRY_SCRUB_BENCH` | no |
| `SidebarHoverCardRetargetBenchTests` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SidebarHoverCardRetargetBenchTests.swift` | `CMUX_HOVER_RETARGET_BENCH` | p95 under 8 ms scaled |
| `SidebarLagBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SidebarLagBench.swift` | none (a harness other tests drive) | yes, through `SidebarChiefLagTests` (cmux#61230) |
| `SidebarScrollBench` | `Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/SidebarScrollBench.swift` | none (a harness other tests drive) | yes, through `SidebarChiefLagTests` (cmux#61230) |
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
| `webviews/bench/inline-text-hasmarks.bench.ts` | inline text model | no |
| `webviews/bench/subsession-reply-height.bench.ts` | sub-session card height | no |
| `webviews/bench/terminal-history-offscreen.bench.ts` | terminal history viewer | no |
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

## Scheduled probes used as benches

Some areas are measured only end to end, by an hourly or nightly probe in manaflow-ai/cmuxterm-hq
(`tools/fleet-reconcilers/`) that NOW reads, not by a bench in this tree. An [[area]] in relevance-map.toml names
the probe as its bench so `tools/area-view` (leo-workspace) shows the area as covered, and the gap column says
what a PR here still cannot run.

| bench | area | measures | budget | gap |
|---|---|---|---|---|
| `cloud-desktop-agent-production` | Computer Use | the cmux-cua driver's click on a production Cloud desktop (Linux, Xvfb, Chrome): `computer_use.click_ok_share` | at least 0.95 at p50 of the newest 20 rows | no scheduled macOS click run (AX, ScreenCaptureKit), and no offline click-landing bench a PR runs |
| `ios-push-e2e-production` | iOS push | turn end on a NEXT Nightly Mac to the banner on the paired phone, and the tap opening that chat | p95 at most 5,000 ms; ceiling 800 ms | the probe needs a Sandbox-enabled APNs key or a TestFlight phone (goal ios-push-e2e preconditions) |
| `remote-connect-phone-production` | Remote connect and reconnect | the iPhone app's machine list opening a session on one of the person's Macs that answers, on the newest Nightly and iPhone app | passes every 6 hours | needs a real phone; no PR-time run |
| `connection-reconnect-chat` | Remote connect and reconnect | local and connected sessions staying usable after the Nightly is quit with sessions kept and relaunched | passes on each scheduled run | no PR-time run |
| `cloud-journey-first-text-production` | Cloud start | create to first text of a real-model reply on production (`create_to_first_text_ms`) | p50 at most 3,000 ms and p95 at most 8,823 ms over the newest 20 runs; 20 of 20 real replies | no PR-run bench of the start steps |
| `cloud-start-matrix-production` | Cloud start | the newest NEXT Nightly starting one chat per folder x team x bypass combination, every 6 hours | every combination passes on the newest run | the GUI and local matrices are separate probes |
| `cloud-chat-replies-production` | Cloud chat and client | a production Cloud chat replying (availability, select to first text, waiting reasons) | availability at least 0.999; rate at least 0.95 | none a PR can run |
| `cloud-chat-attach-production` | Cloud chat and client | click to transcript painted when attaching a production Cloud chat | p95 at most 707 ms over the newest 20 runs | none a PR can run |
| `machine-ready-after-create` | Cloud machines | a new Cloud machine ready after create | p95 at most 10,000 ms over the newest 20 runs | none a PR can run |
| `machine-resume` | Cloud machines | a personal Cloud machine resuming | availability at least 0.99 over the newest 20 runs | none a PR can run |
| `cloud-last-seen-cold-start` | Cloud machines | the last-seen machines list on a cold start | p95 at most 1,000 ms | older Nightlies record a skip |
| `cloud-chat-pro-no-relogin` | Cloud sign-in | a signed-in Pro account opening Cloud chat with no re-login | at least 0.95 pass, lower bound at least 0.85 | none a PR can run |
| `cloud-carrier-ssh-failover` | Cloud carrier | relay killed mid-turn; the chat continues over ssh | 0 lost or repeated output | needs a Nightly |
| `cloud-carrier-chaos-staging` | Cloud carrier | carrier chaos run on staging | newest run passes | staging only |
| `cloud-machine-no-plaintext-secrets-production` | Cloud vault | an agent with sudo on a live machine trying every census row for plaintext secrets | newest run passes | none a PR can run |
| `cloud-vault-adversarial-production` | Cloud vault | every attack class in the vault census against production | newest run passes | none a PR can run |
| `cloud-vault-no-bypass-production` | Cloud vault | each way around the vault with a machine's own credential, every 6 hours | newest run passes | none a PR can run |
| `cloud-session-move-to-cloud-production` | Session transfer | move start to the far side's first output, local to Cloud | p95 at most 10,000 ms over the newest 20 runs | none a PR can run |
| `cloud-session-move-to-local-production` | Session transfer | the same, Cloud to local | p95 at most 10,000 ms over the newest 20 runs | none a PR can run |
| `session-move-gcp` | Session transfer | a session move to a GCP machine | newest run passes | none a PR can run |
| `super-highway-moves` | Session transfer | the super-highway session moves | newest run passes | none a PR can run |
| `a11y-baseline` | Home accessibility | the newest Nightly's Home, sidebar and composer and the iOS home, light and dark: unlabeled controls and Reduce Motion | 0 unlabeled controls; Reduce Motion honored | needs a throwaway macOS runner reading the accessibility tree from outside the app; no PR run |
| `agent-hooks-in-cmux` | Agent integrations settings | Claude Code and Codex hooks listed by event; disable and enable round-trip | probe passes on its newest run | no PR run |
| `agent-mcp-in-cmux` | Agent integrations settings | MCP servers from ~/.claude.json, .mcp.json and ~/.codex/config.toml listed; add and remove round-trip | probe passes on its newest run | no PR run |
| `agent-settings-in-cmux` | Agent integrations settings | model, permission mode, sandbox and env (masked) edits round-trip | probe passes on its newest run | no PR run |
| `agent-skills-in-cmux` | Agent integrations settings | skills listed from user, project and plugin folders; SKILL.md opens for edit | probe passes on its newest run | no PR run |
| `first-run-one-screen-nightly` | Onboarding and first run | a fresh nightly install on a clean Mac to a first agent reply: decisions before the composer | at most 1 decision | runs on each nightly, not on a PR |
| `next-first-run-setup-nightly` | Onboarding and first run | a fresh install opens first-run setup (sign-in, agents, CLI, classic import offer) instead of an empty Home | probe ok on the newest nightly | runs on each nightly, not on a PR |
| `onboarding-new-person-production` | Onboarding and first run | new person: install, sign in, first Cloud chat reply, Remote desktop open; every step timed | every step ok, no dead end | no PR run |
| `agent-shortcut-found-nightly` | Onboarding and first run | the first run offers the start-an-agent shortcut in one click and it is listed where shortcuts are shown | probe ok on the newest nightly | runs on each nightly, not on a PR |
| `ios-app-store-live-production` | iOS app release | App Store Connect state of com.cmux.app and the App Review readiness gate at the submitted head | READY_FOR_SALE; gate YES | no PR run |
| `ios-release-bar` | iOS app release | review gate YES on the INTERNAL lane, goals/ios-release-bar.json items merged, simulator read-back | passes | no PR run |
| `notify-banner-click-nightly` | Notification banners | with the newest Nightly in the background, a finished turn, failed turn and wait each show one macOS banner whose click opens that chat's tab | ok | runs on each nightly, not on a PR |
| `screenshot-into-chat-nightly` | Screenshot into chat | scripted walk sending a screenshot into a chat from another app on a nightly | ok | runs on each nightly, not on a PR |
| `customize-composer-nightly` | Customization and themes | the customized composer on the newest NEXT Nightly | newest run passes, not stale | no PR-runnable run |
| `feature-flow-looks` | Customization and themes | Settings > Appearance shows a tile for each of the ten look packs | newest run passes, not stale | no PR-runnable run |
| `theme-live-reload-nightly` | Customization and themes | 200 theme-file saves, each on screen (frame captures) | every save within 1,000 ms, no miss | macOS runner only |
| `local-composer-matrix-nightly` | Composer send and local start | every composer combination sent through the UI | newest run passes, not stale | no PR-runnable run |
| `local-start-matrix-nightly` | Composer send and local start | each start-picker row (no folder, GitHub URL, Codex workspace, ...) | worst cell at least 95% of the last 20 decided runs | no PR-runnable run |
| `next-zero-classic-footprint-nightly` | Classic import | every Classic surface listed after fresh NEXT flows and a Classic import | newest run passes, not stale | no PR-runnable run |

## Agent tooling benches (leo-workspace)

Agents run these tools on every task, so a slow lookup costs every lane. These benches live in
teamleaderleo/leo-workspace, not this tree, so `tests/test_bench_coverage_map.py` does not check this
section. Budget: a warm query under 300 ms, an update under 2 s after one doc changes, and flat at 10x
docs (the ds&a fan-out brief). Each one's correctness test sits beside it.

| bench | tool | scale | result | budget met | test |
|---|---|---|---|---|---|
| `tools/bench_agent_memory_search.py` | `tools/agent-memory search` | 13k sources | p50 1.7 s → 6 ms (leo-workspace#13282) | yes | `tools/test_agent_memory.py` |
| `tools/bench_agent_memory_fingerprint.py` | `agent-memory` staleness fingerprint | 13k sources | 3.6 s → 0.69 s (leo-workspace#13291) | yes (runs in a throttled child, off the query path) | `tools/test_agent_memory.py` |
| `tools/bench_rfd_update.py` | `tools/rfd find` and `rfd update` | 336 and 3,360 docs | at 3,360 docs: query 1,505 → 430 ms (leo-workspace#13340); update p95 2,492 → 1,731 ms (leo-workspace#14288); query p50 639 ms, p95 895 ms on a loaded lane VM (load 13-32) | update: yes (1,731 ms p95, leo-workspace#14288); query: no (639 ms p50 against 300 ms, tracked in leo-workspace#13352) | `tools/test_rfd.py` |
