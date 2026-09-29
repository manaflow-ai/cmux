# cmux next: deletion plan (bonsplit and the legacy app)

Computed 2026-09-29 on `feat-cmux-next` at a68b915c3be. Closure = local SwiftPM `path:` edges from every `Packages/*/*/Package.swift`, plus `packageProductDependencies` and Sources build phases of each native target in `cmux.xcodeproj/project.pbxproj`, plus `ios/cmuxPackage/Package.swift` and `ios/cmux.xcworkspace`. Line counts = text lines of tracked files (`git grep -I -c ''`), tests included. Re-run before each batch; the numbers drift.

Goal (REWRITE.md 1, 9): no bonsplit, and delete every line that the new app and the surviving consumers do not link.

## 1. Dependency closure

### 1.1 What `cmux-next` links today

Xcode target `cmux-next` (`CE7A00000000000000000005`, scheme `cmux`):

| Input | Value |
| --- | --- |
| Sources | `App/main.swift` (4 lines) only |
| Package products | `CmuxNextApp` (`XCLocalSwiftPackageReference "Packages/macOS/CmuxNext"`) |
| Frameworks | `GhosttyKit.xcframework` |
| Resources | `Assets.xcassets` (shared file ref `A5001101`), no `Localizable.xcstrings`, no `InfoPlist.xcstrings` |
| Info.plist / entitlements | `Resources/Info.plist` (shared with legacy); Release `Resources/cmux.entitlements`; Debug none |
| Target dependency | `cmux-cli` (phase "Copy CLI" puts `cmux` into `Contents/Resources/bin`) |
| Script phases | "Reject Bundled Provider Binaries"; `scripts/cmux-next/bundle-cmux-tui.sh` (reads `scripts/cmux-next/cmux-tui.pin`, aarch64 only); `scripts/cmux-next/embed-cef.sh` (reads `cef-manifest.json`, private `manaflow-ai/cef` release); `scripts/cmux-next/bundle-ghostty-resources.sh` (reads `ghostty/zig-out/share`, `Resources/ghostty`, `Resources/terminfo-overlay`, `Resources/shell-integration`, `ghostty/src/shell-integration`) |
| Not embedded (legacy has them) | Sparkle.framework, cmuxTunnel system extension, CmuxDockTilePlugin, `cmux-diff-sidecar`, Nucleo FFI, markdown-viewer assets, plain-text paste worker, extension point, Sentry, PostHog, MarkdownUI |
| Settings | `MACOSX_DEPLOYMENT_TARGET = 26.0` (legacy 14.0), Release bundle id `com.cmuxterm.app` (same as legacy, Keychain kept), `ENABLE_HARDENED_RUNTIME = NO` (signing script adds `--options runtime`) |

SwiftPM closure of `Packages/macOS/CmuxNext` (13 nodes):

| Package | Lines | Why |
| --- | --- | --- |
| Packages/macOS/CmuxNext | 87,474 | the app |
| Packages/Shared/CmuxGhosttyKit | 25 | CmuxNextTerminal |
| Packages/Shared/CMUXAuthCore | 971 | CmuxNextCloud |
| Packages/Shared/CmuxAuthRuntime | 17,432 | CmuxNextCloud |
| vendor/stack-auth-swift-sdk-prerelease | 7,875 | via CmuxAuthRuntime |
| Packages/Shared/CMUXMobileCore | 55,218 | CmuxNextMobile |
| Packages/Shared/CmuxIrxTransport | 21,577 | CmuxNextMobile (+ remote `iroh-ffi`) |
| Packages/Shared/CmuxIrohTransport | 62,472 | via CmuxIrxTransport |
| Packages/iOS/CmuxMobileRPC | test only | CmuxNextMobileTests |
| Packages/iOS/CmuxMobileSSH, CmuxMobileTunnel, CmuxMobileShellModel, CmuxMobileSupport | test only | CmuxNextMobileTests (swift-nio-ssh etc.) |

### 1.2 Other consumers that must keep building

| Consumer | Links (transitive) | Notes |
| --- | --- | --- |
| `cmux-cli` target (`CLI/`, 103,002 lines) | CmuxSurfaceCatalogModel, CMUXAgentLaunch, CmuxAgentJournal, CmuxControlSocket, CmuxTerminalCore, CmuxTerminalImport, CMUXDebugLog, CmuxCore, CmuxSwiftRender, CmuxSwiftRenderUI, CmuxSudoBroker, CmuxSidebarInterpreterService, CmuxSimulator, CmuxSettings, CmuxFoundation, CmuxSentryTelemetry, CMUXMobileCore, CmuxGhosttyKit | Also compiles 19 files from `Sources/` (3,845 lines): `Automation*` (8), `JSONC*` (3), `Remote*Bootstrap*` / `RemoteRelayZshBootstrap` / `RemoteSessionBundledResourceLoader` (5), `SSHPTYAttachStartupCommandBuilder`, `AgentProcessBindingResolution`, `AgentHibernation/AgentHibernationLifecycleState`, `Surfaces/CmuxTuiRemoteRouting`. CLI code imports none of CmuxSwiftRender, CmuxSwiftRenderUI, CmuxSidebarInterpreterClient: dead links. |
| `cmuxCLITests` (scheme `cmux-cli-tests`, host-free) | CMUXAgentLaunch, CmuxAgentJournal, CmuxFoundation, CmuxSettings, CmuxCore | `cmuxCLITests/` 11,114 + `cmuxCLITestSupport/` 2,463 |
| `cmuxTunnelExtension` (`TunnelExtension/`) | vendor/WireGuardKit, CmuxCloudTunnelCore | Embedded only by legacy. cmux-next uses userspace `cmux-tui wg hub` (`CmuxNextCloud/Tunnel/CloudTunnelHub.swift`), so this target becomes optional (decision X2). |
| iOS app (`ios/cmuxPackage`, CmuxMobileShellUI, CmuxMobileTerminal) | 36 nodes: every `Packages/iOS/*`, Shared: CMUXAuthCore, CmuxAuthRuntime, CMUXMobileCore, CmuxAgentChat, CmuxClientConfig, CmuxGhosttyKit, CmuxIrohTransport, CmuxIrxTransport, CmuxSentryTelemetry, CmuxSimulatorStreamKit, CmuxWorkspacePresence, **Packages/macOS/CmuxPhonePush** | CmuxPhonePush is a macOS-path package the iOS app links. Keep. |
| web/ | `web/tests/account-me-orpc.test.ts:14` reads `Packages/Shared/CmuxAPIClient/Sources/CmuxAPIClient/openapi.json` | Keep CmuxAPIClient (or move the JSON). |
| cmux-tui/ | nothing in Packages | one comment in `crates/cmux-tui-core/src/layout.rs:83`; leave |
| test-ios.yml | tests `Packages/Shared/CmuxSyncStore` | Nobody links CmuxSyncStore. Orphan; ask the iOS owner. |
| Release tooling | `Resources/Info.plist`, `cmux*.entitlements`, `Assets.xcassets`, `Resources/ghostty`, `Resources/shell-integration`, `Resources/terminfo-overlay`, `scripts/sign-cmux-bundle.sh`, `scripts/sparkle_*`, `daemon/remote` (SSH daemon assets, until B6) | see section 4 |

### 1.3 Keep set and deletion set

Keep (union of 1.1 and 1.2): CmuxNext; Shared: all except CmuxSyntaxHighlighting, CmuxTerminalPrediction, CmuxSyncStore (orphan, confirm); macOS: CMUXAgentLaunch, CMUXDebugLog, CmuxAgentJournal, CmuxControlSocket, CmuxCore, CmuxFoundation, CmuxSettings, CmuxSimulator, CmuxSudoBroker, CmuxSurfaceCatalogModel, CmuxTerminalCore, CmuxTerminalImport, CmuxCloudTunnelCore, CmuxPhonePush, plus the three dead CLI links until B2 removes them; all `Packages/iOS/*`; vendor/stack-auth-swift-sdk-prerelease, vendor/WireGuardKit.

Outside every closure (41 packages): the 8 bonsplit dependents (B1) and 33 more (B2, B7). No package in the keep set depends on any of them (checked by reverse edges).

## 2. Deletion batches

Order matters: each batch leaves every surviving consumer green. Bonsplit cannot go alone. 301 files import it (141 in `Sources/`, 91 in `cmuxTests`, 5 packages), so the smallest compile-safe unit that removes bonsplit also removes the legacy `cmux` target. B1 is therefore "bonsplit plus everything that cannot compile without it".

### B0. Prerequisites (no deletion, same or earlier PR)

| Change | Why |
| --- | --- |
| Move the 19 CLI-compiled `Sources/` files into `CLI/` (or a CLI-owned package) and repoint the `cmux-cli` Sources phase | B1 deletes `Sources/` |
| Add CLI resources to the cmux-next bundle: `Resources/Localizable.xcstrings` (CLI keys, see B4), `Resources/opencode-plugin.js`, `Resources/feed-tui`, `Resources/markdown-viewer` (CLI `markdown`), `Resources/bin/*` wrappers, `Resources/InfoPlist.xcstrings` | CLI reads them from the enclosing app bundle (`CLI/cmux_open.swift:86`, `CLIExecutableLocator.enclosingAppBundle`); cmux-next bundles none of them today |
| Decide the bench baseline | architecture.md 6 compares against the old app; after B1 the branch cannot build it. Use the installed release `/Applications/cmux.app` or a pinned legacy DMG |

### B1. Bonsplit and the legacy app target

| Path | Lines | Files |
| --- | --- | --- |
| `vendor/bonsplit` (submodule gitlink, pin c5cb292) | 0 in repo (24,804 upstream) | 1 |
| `.gitmodules` `vendor/bonsplit` entry | 3 | |
| `Sources/` minus the 19 CLI files (moved in B0) | 542,532 | 2,419 |
| `cmuxTests/` | 494,631 | 1,138 |
| `cmuxUITests/` | 28,013 | 81 |
| Packages/macOS/CmuxPanes | 2,566 | 29 |
| Packages/macOS/CmuxBrowser | 33,229 | 288 |
| Packages/macOS/CmuxTerminal | 28,950 | 210 |
| Packages/macOS/CmuxWorkspaces | 15,730 | 129 |
| Packages/macOS/CmuxRemoteSession | 21,829 | 173 |
| Packages/macOS/CmuxCloudTui (-> CmuxTerminal) | 2,423 | 23 |
| Packages/macOS/CmuxAppKitSupportUI (-> CmuxWorkspaces) | 7,440 | 86 |
| Packages/macOS/CmuxCloud (-> CmuxCloudTui) | 27,867 | 271 |
| pbxproj: targets `cmux` (A5001050), `cmuxTests`, `cmuxUITests`, `CmuxDockTilePlugin`; package refs bonsplit (A5001260-62), Sparkle, PostHog, MarkdownUI, all B1/B2 local refs; groups | ~16,500 (estimate, of 18,771) | |
| schemes `cmux-legacy`, `cmux-unit`, `cmux-ci`, `cmux-numeric-locale` | 152 | 4 |
| `cmux-Bridging-Header.h` (legacy only) | 2 | 1 |
| **B1 total** | **~1,222,000** | |

References to edit in the same PR:

| Where | Edit |
| --- | --- |
| `cmux.xcworkspace/contents.xcworkspacedata` (101 locations) | drop every deleted package |
| `cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | re-resolve (Sparkle, PostHog, swift-markdown-ui drop out) |
| `Resources/Info.plist:371` | remove "Bonsplit Tab Transfer" UTType declaration |
| `CLI/cmux.swift:10214,10248` (`bonsplit_tab_id` debug print), `:20838` (help "Bonsplit pane") | edit text |
| `.github/workflows/ci-guards.yml:1169-1171`, `seed-swiftpm-manifests.yml:61-67`, `app-host-test-rerun.yml:170-172` | remove `git submodule update ... vendor/bonsplit` |
| `scripts/lint-stored-dispatch-work-items.py:25,51,689-698` | drop `BONSPLIT_SOURCES_ROOT` and `SOURCES_ROOT` (fails when the dir is missing) |
| `scripts/ci/detect_ci_change_areas.py:833-836`, `ui_tests_dispatch.py:65`, `detect_linux_guard_changes.py:100`, `swiftpm-manifest-cache.sh:51`, `owned_spm_scratch.py:16,62-64`, `owned_build_state.py:937`, `package-test-lane.sh` (27 refs, bonsplit phase) | remove bonsplit and legacy paths |
| `.github/swift-warning-budget.tsv` (13 bonsplit rows, plus every `Sources/`/`cmuxTests` row) | delete rows |
| `scripts/localization-allowed-omissions.json`, `scripts/verify-cmd-click-file-previews.sh`, `scripts/remote-tmux-live-fuzz.sh` | drop bonsplit entries / delete legacy-only scripts |
| Legacy CI lanes that fail without the target (must go in B1, rest of infra in B3): `ci-macos.yml` cmux-unit/app-host jobs (50 refs), `ci.yml` (49 refs), `test-e2e.yml`, `app-host-test-rerun.yml`, `seed-derived-data.yml`, `test-macos-suite.yml`, `ci-macos-compat.yml`, `tmux-corpus.yml`, `command-palette-search-benchmarks.yml`, `ci-ui-tests.yml`, `ci-main-full-suite.yml` | delete workflow or job |
| Python tests: `tests/test_ci_select_package_tests.py`, `test_hung_test_watchdog.py`, `test_ci_owned_build_state.py`, `test_ci_change_areas.py`, `test_swift_package_execution.py`, `test_lint_stored_dispatch_work_items.py`, `test_ci_ui_tests_dispatch.py`, `test_ci_swift_warning_budget.sh`, `test_ci_owned_spm_scratch.py`, `test_build_metrics.py`, `test_ci_swiftpm_manifest_cache.sh`, `test_ci_source_lint_guard_structure.py`, `test_ci_run_guards.py` | update fixtures |
| tests_v2 bonsplit-geometry files: `test_split_cmd_d_ctrl_d_geometry_fuzz.py`, `test_nested_split_no_arranged_subview_underflow.py`, `test_split_flash_and_layout.py`, `test_close_surface_selection.py`, `test_terminal_focus_routing.py`, `test_tab_dragging.py`, `test_new_tab_interactive_after_splits.py`, `test_browser_panel_stability.py`, `tests_v2/cmux.py` | keep if the compat suite passes them, else delete (see B7) |
| Docs/skills: `skills/cmux-ghostty/SKILL.md:52`, `skills/cmux-debugging/SKILL.md:21`, `.claude/commands/pull.md:8`, `.claude/commands/sync-branch.md:9-11`, `THIRD_PARTY_LICENSES.md`, `PROJECTS.md`, `docs/remote-tmux-*.md`, `docs/canvas-layout-design.md`, `docs/dock.md`, `docs/custom-sidebars.md`, `docs/cli-contract.md`, `docs/v2-api-migration.md`, `dogfood/fuzz/*` | remove bonsplit and legacy text; `CHANGELOG.md` stays (history) |
| `Resources/Localizable.xcstrings` (58 bonsplit hits) | handled by B4 prune |

Verification: `xcodebuild -scheme cmux` Debug and Release universal (fleet `cmux-ci build`, isolated DerivedData); `xcodebuild -scheme cmux-cli build`; `cmux-cli-tests` on CI; `swift test` in `Packages/macOS/CmuxNext` on the fleet or a Testbox; iOS `test-ios.yml` plus `cmux-ios` scheme build (no iOS input changes, sanity only); `ci-guards.yml`; `python3 scripts/verify-local.py`; fresh clone `git submodule update --init --recursive` succeeds with no bonsplit; `scripts/cmux-next/check-no-godfiles.sh`, `check-concurrency.sh`; tagged `reload-cloud.sh` launch; tests_v2 compat suite (`scripts/cmux-next/cli-compat-tests-v2.py`) not below its current count.

### B2. Legacy-only packages without bonsplit, and dead CLI links

| Path | Lines | Note |
| --- | --- | --- |
| macOS: CmuxSettingsUI 31,977, CmuxRemoteWorkspace 12,229, CmuxCommandPalette 7,259, CmuxCanvasUI 5,130, CmuxSidebar 4,840, CmuxMobileHost 4,522, CmuxRemoteDaemon 3,196, CmuxCloudMachines 2,609, CMUXProjectModel 2,400, CmuxCanvas 2,344, CmuxExtensionKit 2,273, CmuxLiveEval 1,786, CmuxWindowing 1,691, CmuxSudoBrokerUI 1,230, CmuxFilePreviewCore 1,144, CmuxHive 982, CmuxSidebarProviderKit 716, CmuxCloudImagePaste 624, CmuxAgentSessionStore 599, CmuxTestSupport 241, CmuxCloudBannerCore 174, CmuxDiffComments 137 | 88,103 | replaced by CmuxNext modules or dropped (inventory D3, D4) |
| Shared: CmuxTerminalPrediction 2,874, CmuxSyntaxHighlighting 1,162 | 4,036 | only legacy links them |
| `Examples/CmuxExtensionSidebarExamples`, `CustomSidebars`, `TabsVisibleSidebar`, `SampleSidebarExtensionApp`, `StubAgentSidebarExtension` | 7,938 | D4 |
| `Native/CommandPaletteNucleoFFI` | 937 | legacy build phase only |
| CLI dead links: CmuxSidebarInterpreterService 3,662, CmuxSwiftRender 10,301, CmuxSwiftRenderUI 6,210 | 20,173 | remove 3 products from `cmux-cli`; swift-syntax drops out of Package.resolved |
| **B2 total** | **121,187** | |

References: `cmux.xcworkspace`, pbxproj package refs (if B1 left any), `scripts/ci/package-test-lane.sh`, `scripts/test-command-palette-nucleo-ffi.sh`, `scripts/lint-ios-package-conventions.sh` (CmuxTerminalPrediction), `.github/workflows/test-ios.yml` (mentions), docs for custom sidebars, `web/data/cmux.schema.json` keys `customSidebars`/`canvas` (keep keys, add deprecation per inventory 2.4).

Verification: as B1, plus `cmux-cli` Release universal build (proves the dead links were dead) and bundled CLI smoke `scripts/smoke-signed-app-cli.sh` on an unsigned build.

### B3. Legacy CI and test infrastructure

| Path | Lines | Files |
| --- | --- | --- |
| app-host / cmux-unit / UI-test / e2e / derived-data seed tooling: `scripts/ci/app_host_*`, `app-host-*.sh`, `cmux_unit_test_shard.py`, `cmux-unit-test-timings.json`, `compile-app-host-test-product.sh`, `ui_tests_dispatch.py`, `e2e_*`, `seed_derived_data.py`, `warm_distance.py`, `late_placement.py`, `reverse_test_impact.py`, `focused_test_selectors.py`, `dispatch-focused-test.py`, `run-display-ui-regressions.sh`, `workloads/macos-app-host-test-shard.sh`, `scripts/e2e/`, `scripts/run-e2e.sh`, `run-tests-v1.sh`, `test-unit.sh`, `sync_test_wiring.py`, `sync-test-wiring`, `wire-app-sources.py`, `perf-activation-session.py`, `.github/actions/e2e-run-tests/`, the 11 workflows listed in B1, and their `tests/test_*` counterparts | 46,566 | 91 |
| v1 socket tests: `tests/cmux.py`, `test_cli_socket_autodiscovery.py`, `test_multi_workspace_focus.py`, `test_workspace_churn_up_arrow_lag.py` | 3,007 | 4 |
| **B3 total** | **~49,600** | |

Edit, not delete: `ci.yml`, `ci-macos.yml`, `ci-guards.yml`, `scripts/ci/detect_ci_change_areas.py`, `choose_ci_suite.py`, `queue_janitor.py`, `pr_media.py`, `product_input_identity.py`, `workflow_guard_groups.py`, `scripts/check-test-determinism.py`, `scripts/verify-local.py`, `scripts/swift_file_length_budget.py`, `skills/cmux-testing/*` (cmux-unit instructions), `CLAUDE.md`/`AGENTS.md` sync-test-wiring rule. Review separately: `main_regression_attribution.py` / `main_regression_bisect.py` (may be test-agnostic). Replace with: CmuxNext `swift test` lane, `cmux-cli-tests`, tests_v2 compat lane against a tagged cmux-next build.

Verification: `ci-guards.yml` green (workflow lint, guard groups), `python3 -m pytest tests/` for the remaining CI tooling tests, one `ci.yml` run on the PR.

### B4. Resource prune (after B1)

| Path | Lines now | After |
| --- | --- | --- |
| `Resources/Localizable.xcstrings` (7,246 keys x 20 locales) | 573,242 | ~143,000 (keeps ~1,804 keys whose literals appear in CLI and CLI-linked packages; exact list by a key-usage script) |
| `Resources/agent-session-react`, `agent-session-solid`, `cmux.sdef`, `ComputerUseHelper.icon`, `ComputerUseHelperIcon.icns` | ~500 | 0 |
| `Resources/markdown-viewer` | 45,128 | keep while CLI `markdown` uses it (`CLI` references it) |
| **B4 total** | **~431,000** (+45,128 if markdown is dropped) | |

References: `scripts/localization_catalog.py`, `localize_changes.py`, `merge-xcstrings.py`, `localization-catalog.yml`, `ci-guards.yml`, `.github/review-bot-rules/full-internationalization.md`. Verification: CLI `--help` and a localized verb under `AppleLanguages=(ja)` from the bundled CLI; localization catalog lint.

### B5. CLI shrink (gated, needs CLI verb decisions)

| Path | Lines | Gate |
| --- | --- | --- |
| Packages/macOS/CmuxSimulator | 57,822 | iOS `mobile.simulator.*` (cloud-ios.md R3/Q3) and CLI `simulator`/`ios` verbs; keep the stream service part |
| Packages/macOS/CmuxControlSocket | 47,644 | CLI imports it in 6 files; keep only `Wire/` framing |
| Packages/macOS/CmuxTerminalCore | 18,288 | CLI uses one symbol in `cmux_open.swift` |
| Packages/macOS/CmuxSurfaceCatalogModel | 5,494 | `CMUXCLI+VMTransfer.swift`, `cmux.swift` |
| Forwarded verb implementations in `CLI/` | unknown | cli-compat.md: verbs already answered by cmux-next compat |
| **B5 total** | **up to ~129,000** | |

Verification: `cmux-cli` build, `cmux-cli-tests`, `scripts/cmux-next/cli-compat-e2e.py`, tests_v2 compat suite.

### B6. Go remote daemon (gated on D5 parity)

| Path | Lines |
| --- | --- |
| `daemon/` (Go `daemon/remote`) | 30,166 |
| `.github/workflows/remote-daemon.yml` | 130 |
| CLI remote bootstrap files moved in B0 (`Remote*Bootstrap*`, `SSHPTYAttachStartupCommandBuilder`, `RemoteSessionBundledResourceLoader`) | ~1,000 |
| **B6 total** | **~31,300** |

Edits: nightly/release "Build immutable SSH daemon assets", "Attest", "Embed verified SSH daemon manifest", "Verify signed app SSH daemon contract", `scripts/verify_remote_daemon_release.py`, `smoke-signed-app-cli.sh` (SSH manifest check). Gate: cmux-tui `cmux-remote` covers `cmux ssh`, relay, port forward, cloud attach.

### B7. Optional, each needs a user decision

| Path | Lines | Decision |
| --- | --- | --- |
| Reuse candidates (legacy-only today): CmuxGit 17,650, CmuxNotifications 7,578, CmuxUpdater 7,455, CmuxSidebarGit 5,536, CmuxComputerUse 5,084, CmuxFeedback 3,809, CmuxUpdaterUI 1,630 | 48,742 | X1: link into cmux-next (fast path for Sparkle, notifications, git sidebar) or delete and rewrite (goal 9). Delete only after the replacement lands. |
| Packages/Shared/CmuxSyncStore | 2,598 | orphan; iOS owner confirms, then drop from `test-ios.yml:45,449,521` |
| `TunnelExtension/`, `vendor/WireGuardKit`, CmuxCloudTunnelCore, `TunnelExtension/*.entitlements` | 4,022 | X2: cmux-next uses userspace `cmux-tui wg hub`; drop the system extension and its release steps |
| tests_v2 files that call `debug.*` (24 files) | 5,834 | after the contract suite ports the checks it needs (inventory D7) |
| `Native/DiffSidecar`, `webviews/` | 5,868 + 24,286 | CLI `diff` (`CLI/CMUXCLI+DiffSidecar.swift`) needs the sidecar in the bundle; delete only with that verb |
| **B7 total** | **~61,200** (+30,154 with diff) | |

### Totals

| Batch | Deletable lines | Blocked by |
| --- | --- | --- |
| B1 bonsplit + legacy app | ~1,222,000 | B0; blockers marked B1 in section 3 |
| B2 legacy-only packages + dead CLI links | 121,187 | B1 |
| B3 legacy CI/test infra | ~49,600 | B1 (partly in B1) |
| B4 resource prune | ~431,000 (+45,128) | B1, B0 CLI resources |
| B5 CLI shrink | up to ~129,000 | CLI verb decisions, iOS simulator |
| B6 Go remote daemon | ~31,300 | D5 parity |
| B7 optional | ~61,200 (+30,154) | X1, X2, D7 |
| **All** | **~2,045,000** | |

## 3. Blockers

Gate key: **M** = must land before merging `feat-cmux-next` to `main` (main is nightly; `-scheme cmux` already builds cmux-next on this branch, so the merge is the switch for users). **B1** = must land before deleting the legacy target on the branch. **R** = before the first stable release.

| Old app provides | cmux-next today | Gate |
| --- | --- | --- |
| Sparkle updater (CmuxUpdater, Sparkle.framework, `SUFeedURL` in Info.plist) | no Sparkle linked; the first cmux-next build a user installs can never update again | M |
| Update feed floor: legacy deploys macOS 14.0; cmux-next 26.0 | appcast gets `sparkle:minimumSystemVersion` only if the built Info.plist has `LSMinimumSystemVersion` (not in `Resources/Info.plist`; verify Xcode injects it). macOS 14/15 users stop receiving updates; decide a legacy maintenance feed or accept | M |
| x86_64 / universal nightly variants | `cmux-tui.pin` is aarch64 only; CEF artifact slices unverified | M (or drop Intel variants) |
| CEF artifact in CI | `manaflow-ai/cef` release is private; CI and fleet cannot fetch it (REWRITE.md) | M |
| Bundled cmux-tui with cmux-next daemon features | nightly overwrites `Contents/Resources/bin/cmux-tui` with main's published client (`resolve-nightly-cmux-tui-client`) that lacks them | M |
| Localization: 20 locales (`Resources/Localizable.xcstrings`, `InfoPlist.xcstrings`) | 13 catalogs, en + ja only; app bundle has no CLI strings table, so CLI output is English only | M for CLI table and InfoPlist strings; R for 18 more locales |
| CLI resources: agent wrappers `Resources/bin/cmux-claude-wrapper` etc., `cmux-sudo`, `opencode-plugin.js`, `feed-tui`, `markdown-viewer`, `cmux-diff-sidecar`, Ghostty CLI helper | not bundled by the cmux-next target (only `cmux`, `cmux-tui`, Ghostty resources); users' installed hooks and wrapper PATH shims break | M |
| CLI compat | 17/98 tests_v2 pass; terminals lack `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` (hooks, feed.push, agent journal miss); bundled `cmux --help` crashes | M |
| iOS: `mobile.*` for shipped phones incl. `terminal.render_grid`, `mobile.simulator.*` | compat adapter landed (PR 15601); simulator streaming not linked (CmuxSimulator not in closure); render-grid fidelity R1 | M |
| Cloud tunnel system extension | not embedded; nightly and release steps fail on its absence (section 4) | M (change pipeline) |
| Sentry crash reporting, PostHog analytics | not linked; dSYM upload still runs | M for Sentry (decision), R for analytics |
| Features typed-unavailable: Markdown/diff viewers, file preview, VS Code server, browser profiles/history/import, WebAuthn, agent chat/Teams/Computer Use | 65 actions unavailable (REWRITE.md) | R; B1 deletes CmuxBrowser (WebAuthn 1,891 lines) from the tree, recover from history if needed |
| PTY lifecycle | leaked `__terminal-host` processes exhausted ptys (REWRITE.md) | M |
| Bench baseline against old app | needs a legacy build | B1 (use installed release instead) |
| Mobile shim port reference (`Sources/Mobile` 17k, `CmuxMobileHost`) | adapter exists; old code is the wire-shape reference | soft B1 (git history suffices) |
| Dock tile plugin (channel icon persistence) | not embedded | R (or drop) |

## 4. Release pipeline once the legacy target is gone

Today on this branch `nightly.yml:541,1099`, `release.yml:272`, `ci-macos.yml:4078` run `xcodebuild -scheme cmux -configuration Release` and pick up `build-universal/Build/Products/Release/cmux.app`. Release config `PRODUCT_NAME = cmux`, so the path still matches, but the bundle is cmux-next. Step by step:

| Step (nightly.yml / release.yml) | Result with cmux-next | Required change |
| --- | --- | --- |
| Build universal app | builds; Embed CEF needs the private artifact; Bundle cmux-tui finds no x86_64 pin | public or token-readable CEF release (REWRITE D3); x86_64 cmux-tui and CEF, or arm64-only variants |
| Bundle cmux-tui client (nightly `install-cmux-tui-client.sh`) | replaces the pinned daemon with main's client | install the commit in `scripts/cmux-next/cmux-tui.pin`, or merge the daemon branch to main first |
| Inject Ghostty CLI helper, theme picker regression, CLI memory guard | pass (post-build injection) | none |
| Build/attest/embed SSH daemon assets | pass (CLI still uses them) | remove in B6 |
| Strip bundle (`strip-release-bundle.sh`) | pass (paths optional) | none |
| Verify Cloud tunnel engine (nightly ~1227, release 478) | **fails**: "Cloud tunnel system extension is missing" | delete step, tunnel provisioning-profile embed (release 463, nightly "Embed Cloud tunnel extension provisioning profile"), `normalize-system-extension-bundle.sh` call, packet-tunnel entitlement in `cmux.*.entitlements`, sysext checks in `sign-cmux-bundle.sh:87-303` (X2) |
| Verify diff sidecar (nightly 1541, release 380) | **fails**: `cmux-diff-sidecar` absent | build it in the cmux-next target (CLI `diff`) or drop verb and step |
| Architecture check lists `cmux-cua`, Computer Use helper (nightly 1519-1521), "Start Computer Use helper notarization" | helper built outside Xcode; cmux-next does not use it | drop, or keep if Computer Use returns |
| Inject nightly identity / Sparkle keys into Info.plist | writes `SUFeedURL`, `SUPublicEDKey`; nothing reads them | add Sparkle to cmux-next (M) |
| Embed provisioning profile, codesign (`sign-cmux-bundle.sh`) | must sign CEF framework and 5 helper apps with correct entitlements | extend `sign-cmux-bundle.sh` for CEF helpers; verify `verify-bundle-load-commands.sh` |
| Smoke launch | needs the daemon to start under the runner | verify |
| Smoke bundled CLI (version, help, SSH manifest, ping, capabilities, workspace create/list/close) | `--help` crash fails it | fix resource bundle (M) |
| Notarize, DMG, `syspolicy_check` | expected pass after signing fixes | verify |
| dSYM upload to Sentry | uploads, app has no SDK | add Sentry or drop step |
| `sparkle_generate_appcast.sh` | emits `minimumSystemVersion` from the bundle if present; deltas from legacy builds are large but valid | assert `sparkle:minimumSystemVersion=26.0` in the appcast (new check) |
| `update-homebrew.yml` | cask still says the old macOS floor | set `depends_on macos: ">= :tahoe"` in `homebrew-cmux` |
| `bump-version.sh` | edits the first `MARKETING_VERSION`; cmux-next has its own copies (14 total today) | after B1 fewer copies; verify it rewrites all |
| `ci-macos.yml:4078` release-build lane, `perf-activation.yml:189`, `scripts/reload*.sh`, `build-sign-upload.sh`, `reloadp.sh`, `run-tests-v2.sh` | now build cmux-next | reset perf baselines; keep `run-tests-v2.sh` as the compat lane |
| `test-macos-suite.yml:405`, `ci-macos-compat.yml:254` (`-scheme cmux` then legacy UI tests) | wrong app | deleted in B1 |

Decisions for the user: X1 (reuse or rewrite Updater/Notifications/Git), X2 (drop the tunnel system extension), macOS 14/15 update policy, Intel variants, Sentry and PostHog in cmux-next, CLI verbs to drop (simulator, markdown, diff, import), and whether B1 lands on the branch before the merge gate items (it removes the legacy fallback build from the branch; main keeps it until merge).
