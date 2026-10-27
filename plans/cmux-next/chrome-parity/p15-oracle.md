# p15-oracle: Correctness oracle (final spec, after 3 reviews)

Status: final for the 72-hour push. Checkout read at `772cdfc45ac` (`origin/feat-cmux-next`).
Owner: p15-oracle. This file replaces the draft design and records how each review item was applied.

The oracle is cmux's version of Bun's language-independent test suite and of Chrome's Web Platform Tests.
A behavior corpus of JSON cases drives cmux through the daemon resource API, the control socket, the CLI,
MCP, the TUI and the UI-workflow corpus. At each step the runner records canonical model-state snapshots.
A refactor must give the same snapshots before and after it. The default check is **base SHA against head SHA**.
A **refactor switch** (old arm against new arm in one build) is used only where a program wants a runtime fallback.
Every pure-Swift package also gets a Linux build, so its tests and the oracle replay tools run on the 360-core VM.

---

## 1. Chrome reference

All paths are in chromium/src unless a URL is given.

1. **One conformance suite, many products.** WPT lives in `third_party/blink/web_tests/external/wpt` and runs through
   `third_party/blink/tools/run_wpt_tests.py` against `chrome`, `headless_shell`, Android Chrome and WebView
   (`docs/testing/run_web_platform_tests.md`), with per-product metadata. We copy this: a case states the
   capabilities it `requires`; the product (`daemon`, `app`, `cli`, `headless`, `tui`, `mcp`) is a run parameter.
2. **Baselines and expectations** (`docs/testing/web_tests.md`, `docs/testing/web_test_expectations.md`).
   - `-expected.txt` baselines; platform baselines under `web_tests/platform/<p>`.
   - `TestExpectations`, `NeverFixTests`, `SlowTests`, `ASANExpectations`, `LeakExpectations`. Line format
     `[ bug ] [ modifiers ] test [ results ]`. Result keywords: `Pass Failure Crash Timeout Skip Slow`.
     Several results on one line mean flaky; there is no `Flaky` keyword.
   - Policy: "If a test can be rebaselined, it should always be rebaselined instead of adding lines to
     TestExpectations", even when the baseline codifies an error, because this keeps coverage for the rest
     of the test. A revert is "strongly preferred" when a rebaseline is not possible.
   - `lint_test_expectations.py`, `blink_tool.py rebaseline-cl`, `blink_tool.py optimize-baselines`.
3. **Baseline fallback** (`docs/testing/web_test_baseline_fallback.md`). Two passes: first the virtual name
   along the platform path, then the base name. Order for a virtual/flag test:
   `platform/<p>/virtual/<v>` -> `virtual/<v>` -> `platform/<p>/<base>` -> `<base>`.
4. **The same tests under a flag.** `web_tests/VirtualTestSuites` (`virtual/<prefix>/` with extra `args`),
   `run_web_tests.py --flag-specific=NAME` with `FlagSpecificConfig` and `FlagExpectations/NAME`.
   Our switch arms are virtual suites; a switch's `expected_differences` is its FlagExpectations.
5. **Features.** `base/feature_list.h`: the FeatureList is built once before the first read and then frozen
   (a read before init is a DCHECK). It exists in every channel, and the browser passes the state to each
   child process as `--enable-features/--disable-features`. `base/test/scoped_feature_list.h` flips features
   in a test scope. `testing/variations/fieldtrial_testing_config.json` applies the planned launch config of
   all studies at once to browser_tests, interactive_ui_tests and WPT. Flags expire:
   `chrome/browser/flag-metadata.json`, `tools/flags/generate_expired_list.py`.
6. **UI journeys.** Kombucha (`chrome/test/interaction/README.md`, `ui/base/interaction/interactive_test.h`):
   Action, WaitFor and Check verbs on ElementIdentifiers, `StateObserver` + `WaitForState` instead of
   sleeps, `DumpElements` on failure. `docs/threading_and_tasks_testing.md`: `RunUntilIdle` "can lead to
   flaky tests"; the favored pattern is `RunLoop::Run` + `QuitClosure` for one named event.
7. **Process per test, sharding, retries.** `base/test/launcher/test_launcher.cc`:
   `WrapperTestLauncherDelegate::GetBatchSize()` is 1 for browser tests ("each test is run inside its own
   process"), shards (`--test-launcher-total-shards`, `--test-launcher-shard-index`), jobs, retry limit
   (retries run serially, one test per process; forced to 0 for local filtered runs), `--gtest_shuffle`.
   The CQ blames a CL only after "(with patch)", "(retry shards with patch)" with the same config and
   "(without patch)" at tip of tree; a failure that also fails without the patch is not the CL's.
8. **Child-crash and leak checks.** `content/public/test/browser_test_base.h`: `NoRendererCrashesAssertion`
   fails a test on any renderer crash unless `ScopedAllowRendererCrashes` covers it.
   `content/public/test/browser_test_utils.h` (`RenderProcessHostWatcher`, `CrashTab`), `chrome://crash`,
   `chrome://gpucrash`, `chrome://hang`. LeakSanitizer and `LeakExpectations`.
9. **Time and ids.** `base/test/task_environment.h` `TimeSource::MOCK_TIME`,
   `base/time/time_override.h` `ScopedTimeClockOverrides`, headless deterministic mode (virtual time).
   Time is controlled at the source, "without any test-specific seams in the product code".
10. **Fuzzing.** `testing/libfuzzer/README.md` ("prefer FuzzTest for all new fuzz targets", coverage-guided,
    typed inputs), `mojo/docs/mojolpm.md` (libprotobuf-mutator over Mojo interfaces, in-process), ClusterFuzz.
    Mojo's shared validation data (`mojo/public/interfaces/bindings/tests/data/validation`) is read by the
    C++, JS and Java bindings.
11. **Sanitizers and coverage.** `build/config/sanitizers/sanitizers.gni` (`is_asan`, `is_lsan`, `is_tsan`),
    the ASan/TSan/MSan bots running the same suites. `docs/testing/code_coverage_in_gerrit.md`: absolute and
    incremental line coverage per CL.
12. **Release-optimized test builders.** CQ runs browser_tests on `linux-rel` with `dcheck_always_on`.
13. **Accessibility baselines.** `content/browser/accessibility/dump_accessibility_tree_browsertest.cc` with
    `content/test/data/accessibility/**/*-expected-mac.txt`.
14. **One command path.** Accelerators, menus and toolbar buttons all dispatch the same `IDC_*` through
    `chrome::ExecuteCommand` and `CommandUpdater` (`chrome/browser/ui/browser_commands.h`).
15. **Migrations.** `components/test/data/history/history.N.sql` with `HistoryBackendDBTest MigrationVersionN`,
    `sql/test/test_helpers.h`; crash-safe session files in `components/sessions/core/command_storage_backend.cc`.
16. **Portable base.** `base/` keeps OS code in `*_mac.mm`, `*_posix.cc`, `*_linux.cc` behind one interface,
    not as scattered `#if` in shared files. `content_shell` and `headless_shell` are small test hosts.
17. **Hermetic tests.** browser_tests use `net::EmbeddedTestServer` (`net/test/embedded_test_server/`) and a
    fresh user-data-dir per test; no external network.

---

## 2. cmux today (verified at 772cdfc45ac unless marked "design count")

1. **Swift tests.** CmuxNext: 98 targets, 589,534 Swift lines, 8,404 `@Test` in 47 test dirs (design count).
   Commit `36f2381bf1a` (2026-10-10, "Delete all now") deleted the in-process suites and the model-based
   input fuzzer (`Tests/CmuxNextAppTests/InputModel`); `input-spec.md` still names it.
2. **Rust.** cmux-tui: 10,284 `#[test]`, 98 integration test files. `spec/resource-operations-v2.json`:
   310 ops = 201 mutation, 90 read, 13 connection_control, 6 stream_open (verified with jq). 201 ops have
   `idempotency: required`, 109 `forbidden`. `spec/inventory.json` has 50 `tui_actions`.
   `bindings/conformance/runner.py` drives 7 SDKs. Existing differential corpora: focus reducer corpus
   (`cmux-layout-reducer-ffi/tests/focus/corpus.json`), 7 `.vt` cases in `schemas/terminal-corpus`,
   44 browser-parity goldens, MessagesLab, cmux-browser-host differential cases.
   `cmux-tui/spec/api-compat-fixtures.json` is an empty `cases` array (18 bytes); the real classic-API
   vectors are in `cmux-tui/crates/cmux-api-compat/tests/api_compat.rs` (636 lines).
3. **Formal specs.** `plans/cmux-next/formal/`: 6 `.tla` (LayoutRows, TabLayout, closefocus,
   OwnershipConvergence, FeedHandoff, hovercard), many `.cfg`, `tlc.sh`. The VM has no `java` today.
4. **GUI drivers.** `every-action-sweep.py` (2,690 lines) over `action-surfaces.json` (1,201 actions;
   cli offered 688; mcp offered 606; palette 1,151; main_menu 214; context menus 573; 196 default
   shortcuts). `every-action-gaps.json`: 216 excluded, 84 gaps, so 901 runnable. 986 actions have 2 or
   more entrypoints. Scripts: **64** `*-e2e.py` + 2 `*-e2e.sh` (the draft said 78), **106** `*-live(-check).py`
   (the draft omitted them), 23 media tours, `ui-workflow-corpus.md` (12 journeys, not implemented).
5. **State sources.**
   - App: `snapshot.get` (Release, `ControlTopology`), 153 `debug.*` methods. Verified present: `debug.focus`,
     `debug.desync`, `debug.journal`, `debug.replay`, `debug.window_snapshot`, `debug.tunables`,
     `debug.blocking`, `debug.hangs`, `debug.action_budget`, `debug.wakeups`, `debug.layout_counters`,
     `debug.key`, `debug.crash.app`, `debug.crash.exception`. No Chromium crash method exists.
   - The debug gate is `ControlRouter.debugMethodsAllowed` (`CmuxNextControl/Routing/ControlRouter.swift:45`):
     `#if DEBUG || CMUX_BENCH_HOOKS`, applied to `debug.`-prefixed names only. There is no "nightly" gate.
   - Barrier signals that exist: `ControlSequenceBarrier` and `ControlSnapshot.reflects`
     (`CmuxNextControl/Concurrency/ControlSnapshot.swift:29-48,140`), `MotionClock`
     (`CmuxNextDesign/Motion/MotionClock.swift`), `CommitBoundary` (`CmuxNextSignposts/CommitBoundary.swift`).
     `CompatWriteBarrier` exists only in two plan docs; `LayoutClock` does not exist.
   - Daemon: `session.snapshot` and `settings.snapshot` are public read ops. `public_session_snapshot_with_journal_head`
     (`resource_api.rs:534`) returns the snapshot and the journal head as one consistent cut. The journal's
     pure `restore_preview` (`journal_checkpoint.rs:264`) is `#[cfg(test)]` only.
6. **Switches.** No mechanism. `browserResize.layerHosting` lives in TunableStore; `TunableStore.activate(file:)`
   (`TunableStore.swift:98`) loads in `Task.detached` and applies later on main, so early-launch reads see the
   default. `CEFLayerHosting.init(isEnabled: { BrowserResizeTunables.layerHosting.value })` (line 112) reads per
   call, so one process can run both arms. The daemon holder switch is `CMUX_TUI_TERMINAL_HOST_MODEL=holder`
   read directly at `holder_runtime.rs:31` (not `CMUX_TUI_HOLDER_EXE`, which is a path override).
   `DaemonDiagnosticKnobs.names` forwards only `CMUX_NEXT_TRACE_FLOWS` and `CMUX_NEXT_TUI_DEBUG_SPANS`:
   any other CMUX var set on the app never reaches an app-launched daemon.
7. **Nondeterminism.** Swift Sources: 248 `UUID()`, 264 `Date()`, 132 `ContinuousClock()` (design count).
   cmux-tui non-test: 176 `SystemTime::now()`, 152 `Uuid::new_v4|rand::random|thread_rng|getrandom`;
   590 `HashMap` mentions in cmux-tui-core (verified). No clock or id seam in the core.
8. **Daemon build.** `[profile.release]` = `lto = "fat"`, `codegen-units = 1` (`cmux-tui/Cargo.toml:340`):
   one serial LTO link. 54 files read `CMUX_TUI_TEST_*` knobs (debug only). No `cmux-tui/fuzz/`.
   No sanitizer run exists anywhere in the repo.
9. **Linux.** 15 Shared/iOS packages build and test on Linux in CI (~1,280 tests). 0 of 98 CmuxNext targets do.
   Tainting roots: CmuxNextCompat (AppKit, QuartzCore, Darwin, XPC, SystemConfiguration, MachO),
   CmuxNextSignposts (os, MetricKit), CmuxNextWakeups (AppKit, QuartzCore, kqueue, Security).
   CmuxNextSettings depends on CmuxNextDesign and CmuxNextIcons. CmuxNextBridge is tainted through Layout,
   Sidebar, Tabs, Icons; `TerminalAttachMachine.swift` and `+Types.swift` import only Foundation and CmuxNextDaemon.
   `InputReplay.swift` imports CmuxNextBridge, CmuxNextDaemon, CmuxNextFocus; `InputJournal` has
   `static let shared` (line 14). FFI imports in Sources: CCmuxRdFFI 6 files, CCmuxLayoutReducerFFI 5,
   CCmuxMotionFFI 3, CCmuxPaletteRankerFFI 1 (no direct `import CCmuxAppFFI`).
   `scripts/cmux-next/build-app-ffi.sh` exists and requires `xcodebuild` and `lipo`.
10. **VM (this host).** Ubuntu 24.04, 360 cores, 1.4 TB RAM, ~475 GB free. Present: cargo, jq, bun,
    unshare, systemd-run, python `jsonschema`. Missing: swift, java, cargo-nextest, cargo-mutants,
    cargo-fuzz, nightly rust. The VM also runs agents; plan for shared load.
11. **Webviews.** `webviews/` 1,014 and `web/` 568 `*.test.ts(x)` files.
12. **Bench config.** `scripts/reload.sh --config bench` = Release optimization + `BENCH_HOOKS=1`
    (`debug.*` compiled in), the CQ `linux-rel` + `dcheck_always_on` analog.

---

## 3. Target design

### A. Snapshot (schemas/oracle/snapshot-v1.schema.json)

A snapshot is a JSON object of semantic facets, never pixels. Facets:

| Facet | Source |
| --- | --- |
| topology | `snapshot.get` |
| daemon | `session.snapshot` + `settings.snapshot` + journal head (one cut), plus `oracle-state` extras under the `oracle` cargo feature |
| focus | `InputObservationBuilder` per window |
| layout | LayoutModel values per screen (ratios 3 dp, zoom, dock, canvas) |
| sidebar | sidebar store public values |
| tabs | engine-neutral BrowserTab protocol per pane |
| overlays | overlay stack, palette query + top-10 ids, dialog spec id, hover-card target, find bar |
| settings | sha256 of canonical effective config + non-default keys |
| intents | pending intents + **monotonic** rollback and refusal counters (deltas computed by the runner) |
| windows | count, order, key/main, fullscreen, frame as screen fraction (2 dp) |
| history, notifications, agents | closed-tab log; unread and needs-you counts; session/turn/approval + draft hash |
| terminals | attach state, size, title, cwd, sha256 of the last 24 lines (daemon vt-state, off main) |
| webviews | per-page store summary through a pane-protocol `oracle.state` (route, selection, panels, draft hash) |
| ax | AX tree of focusable and actionable elements (role, label key, enabled, focused) |
| crashes | child-process exits since case start by kind (renderer, gpu, browser, utility, daemon, holder) |
| liveObjects | counts of workspace models, CEF browsers, page views, terminals, holders, subscriptions, tasks |
| invariants | `debug.desync` violation ids |
| switches | the arms read back from the frozen switch values and the per-site hit counters |

App methods are `debug.oracle.snapshot`, `debug.oracle.settle`, `debug.oracle.wait_for`, `debug.oracle.turns`,
`debug.oracle.recorder` and `debug.oracle.switch_hits`, registered inside `#if DEBUG || CMUX_BENCH_HOOKS` next to
the existing `debug.*` block. The router's `debugMethodsAllowed` gate then refuses them in Release by name.
Facet providers are registered once in AppServices (composition root), are built only on request, and add no
observer when nobody asks. Private text is never recorded: only hashes.

**v0 facets** (task 006) use only methods that exist at the push base (`snapshot.get`, `debug.focus`,
`debug.desync`, `debug.window_snapshot`, `debug.tunables`, `session.snapshot`, `settings.snapshot`).
Then the oracle can capture any SHA of the push, including SHAs from before the new facets land.
For newer facets on an old base, `--overlay` applies the additive oracle commits onto the base worktree
(task 202); if the overlay fails, the facet is `not-comparable`, never `pass`.

### B. Settle and waits

- Default run mode is `ui.animations.enabled=false` (CLAUDE.md requires that code works with no animation).
  A `motion-on` virtual suite runs the same cases with animation on; settled snapshots must equal the
  motion-off baselines (task 233).
- Each step can carry `waitFor: {pointer, equals|predicate, maxMs}` served by `debug.oracle.wait_for`, which
  resolves from facet change signals (Kombucha `WaitForState`). No sleeps.
- `debug.oracle.settle {sequence, settleMaxMs}` is the checkpoint barrier only. It waits on
  `ControlSnapshot.reflects(ControlSequenceBarrier)`, `waitIntentsIdle()`, `MotionClock` idle and one
  `CommitBoundary` (continuation-based waiters, task 029).
- A settle or waitFor timeout is the **Timeout** result: an unexpected failure unless Expectations lists it.
  Rebaseline refuses Timeout checkpoints.

### C. Canonicalization (scripts/cmux-next/oracle/normalize.py, stdlib only, safe under `python3 -I`)

Ids relabeled by kind in first-seen order of a sorted-key traversal; volatile keys dropped only when the schema
marks them `x-oracle-volatile` with a reason; `$ROOT`, `$HOME`, `$WEB` rewrites; floats 1e-3, frames 0.01;
`x-oracle-order: set` arrays sorted; sha256 of canonical JSON. Under the daemon `oracle` feature with
`CMUX_TUI_ORACLE_SEED`, time is virtual and ids are seeded (task 185), so time-valued keys stay in snapshots as
offsets from the fixture epoch. A new rule needs a reason naming the source of nondeterminism.
`normalize.py` also holds the stdlib schema validator (one implementation; fleet minis have no jsonschema).

### D. Corpus (tests/oracle/corpus/<suite>/<case>.json, schemas/oracle/case-v1.schema.json)

Case = the ui-workflow-corpus manifest plus `requires` (capabilities: `resource_api`, `actions`, `keys`, `gui`,
`chromium`, `restart`, `mcp`, `tui`), `switches`, `platforms`, `allow_crashes`, and steps with `op`
(`resource.call`, `action.run`, `key`, `cli`, `mcp`, `tui.key`, `settle`, `snapshot`, `kill`, `restart`,
`advance_clock`), `target`, `args`, `expect`, `waitFor`, `checkpoint` (`before|turn|settled`).
Offline fixtures may only use loopback URLs.

Suites and sources:

| Suite | Class | Source | Size |
| --- | --- | --- | --- |
| daemon-ops | differential | generated from resource-operations-v2.json | 201 ops x (success + typed error) + 201 idempotent retries |
| reads | differential | 90 read ops vs the daemon facet | 90 |
| streams | differential | 6 stream_open + 13 connection_control | 19 |
| api-compat | differential | vectors extracted from cmux-api-compat tests | all vectors |
| cli | differential | `cli: offered` actions + resource verbs | 688+ |
| mcp | differential | `mcp: offered` actions + v2/browser/keybinding tools | 606+ |
| actions | differential | every-action-sweep setup, real entrypoint | 901 -> >= 965 |
| entrypoints | differential | actions with 2+ entrypoints, one case per entrypoint | 986 actions |
| tui | differential | 50 tui_actions + menu actions of inventory.json | all |
| walks, crash, fuzz | differential | seeded walks, SIGKILL walks, libFuzzer crashes, ddmin | 10k-100k seeds |
| upgrades | golden | state roots written by the last 5 cmux-tui tags | 5 tags x stores |
| terminal | golden | VT corpus (7 -> >= 200) | >= 200 |
| config | differential | Swift vs Rust effective config | >= 2,000 files |
| pane-protocol | golden | shared vectors run by Rust, TS, Swift | all vectors |
| journeys | golden | 12 ui-workflow journeys + 4 Chromium failure + holder crash | 17 |
| tours | golden | 23 media tours | 23 |
| e2e, live | golden | 66 e2e + 106 live scripts, converted or excluded with a reason | 172 |
| tla | golden | TLC simulate traces of 4 specs (+ FeedHandoff, hovercard action maps) | >= 800 |
| ax | golden | AX tree for the 12 journeys at 3 widths | 36 |
| journals | differential | input journals replayed on the Linux reducers | all |

**Two classes.** Differential suites are checked only as base == head (or arm == arm, or product == product).
They have no reviewed baseline and no Expectations budget; the base run is the oracle. Golden suites keep
reviewed baselines and the 2 % budget. This stops agents from rebaselining wrong behavior to meet a budget.

### E. Baselines and expectations

- `tests/oracle/baselines/<suite>/<case>.expected.jsonl`, platform and product fallback dirs.
- Fallback order (Blink two-pass): `platform/<p>/arm/<case>` -> `arm/<case>` -> `platform/<p>/<case>` -> `<case>`.
  `optimize` uses the same order.
- `tests/oracle/Expectations.d/<suite>.txt`, `NeverFix.d/<suite>.txt`, `SanitizerExpectations.d/` (one file per
  suite, so parallel agents do not conflict). Syntax:
  `[ task-id|#issue ] [ linux mac windows | old new | daemon app cli headless tui mcp | debug bench asan tsan ] suite/case[/step][#/json/pointer] [ Pass Failure Crash Timeout Skip Slow ]`.
  Several results mean flaky. `Slow` gives 5x `settleMaxMs`. A pointer suffix scopes the line to one value; the
  rest of the snapshot stays strict. Policy: rebaseline when correct; a known-wrong value gets a pointer-scoped
  line with a task id, never a whole-case Failure unless the case cannot run.
- `oracle.py check` lints: bug id on every line, no duplicates, no stale lines, golden budget <= 2 %.

### F. Differential modes (scripts/cmux-next/oracle/oracle.py)

1. `diff --base A --head B` (**default**). Daemon: `linux_run.sh` builds both SHAs with `--profile oracle
   --features oracle` in /tmp worktrees (submodule `ghostty-next` initialized per worktree). App: `fleet.py`
   builds both tags with `cmux-ci build cmux --ref` in **bench config**, and runs both on the **same host**,
   back to back. `diff.py` refuses a host or OS mismatch.
2. `diff --switch NAME` (virtual suite). Only for refactors that want a runtime fallback (holder F6, CEF helper F2,
   F1 layer hosting, F7 intents, F8 discard). App switches are a frozen `RefactorSwitches` value parsed once at
   launch from `--cmux-switches=` or `CMUX_NEXT_SWITCHES`, present in Release, injected through AppServices,
   with per-site hit counters; the daemon gets `CMUX_TUI_SWITCHES` from that value. Daemon switches are an
   immutable `Switches` value from `CMUX_TUI_SWITCHES`. A run with 0 hits on the requested arm is
   `arm-not-exercised`. Registry: `plans/cmux-next/refactor-switches/<name>.json` (owner, plan, `read:
   launch|live`, default, `planned`, created, expires <= created + 14 days, minimum suites, expected_differences).
3. `--arm launch-config`: every switch at its `planned` arm, `--suite all`, against all-default.
   `bisect-switches CASE` names the smallest switch set that causes a divergence.
4. Port parity (Swift vs Rust reducers), engine parity (WebKit vs Chromium without `engine`), product parity
   (headless vs app, mcp vs cli, entrypoint vs entrypoint), platform parity (Linux vs macOS daemon; Windows stretch).
5. `confirm`: reruns divergent shards on head with the same config and seed, then the cases alone on base.
   Only "head fails twice, base passes" is routed to an owner. Head-pass goes to MQ-flakes; base-fail goes to
   a base-red queue.
6. `select` maps changed paths to suites (`tests/oracle/suite-map.json`); `bisect` runs one divergent case over
   the commits of a batch with `git bisect run`.

**Invariants** at every checkpoint (`scripts/cmux-next/oracle/invariants.py`):

| Id | Rule |
| --- | --- |
| I1 | each mutation gives exactly one receipt or one typed error |
| I2 | ids stay stable unless the step created or closed them |
| I3 | optimistic prefix: turn projection == settled projection, or settled == before + refusal |
| I4 | app topology == daemon tree at the same sequence |
| I5 | 0 `debug.desync` violations |
| I6 | no orphan processes or sockets at teardown |
| I7 | a hidden-workspace change does no view work (`debug.layout_counters`) |
| I8 | a client model folded from `session.events` == daemon facet at the same sequence |
| I9 | journal `restore_preview` == live daemon facet on the restorable sections |
| I10 | retry with the same idempotency key: equal result, no new journal record, no state change |
| I11 | 0 new main-thread blocking violations (`debug.blocking`) |
| I12 | no hang > 250 ms (`debug.hangs`) |
| I13 | action reached its commit in < 10 ms (`debug.action_budget`) |
| I14 | idle wakeups within budget after settle (`debug.wakeups`) |
| I15 | daemon fd, thread and child counts at teardown == after setup |
| I16 | daemon panic log empty, no lock-rank panic |
| I17 | 0 unexpected child exits unless `allow_crashes` covers the kind |
| I18 | live-object counts return to the fixture baseline after teardown |

I11-I14 failures go to the perf owner queue, not to the case baseline. A run that arms the turn recorder (task 032)
reads the armed facets inside each action's turn, so I11-I14 are not checked in that run (task 217 skips them for
every case that arms `debug.oracle.recorder`); the perf invariants come from runs with the recorder disarmed.

**Mutation strength.** Primary: `cargo mutants` over cmux-tui-core store and router files with the daemon suites
as the test command (task 191), and incremental coverage of a change (task 190). Smoke: 20 seeded mutants as
patch files (10 app, 10 daemon) applied in the job worktree (task 026); nothing is added to Sources or crates.

### G. Runners (no CI; every run is agent-started)

- VM: one queue (`runnerd.py`) with request joining, `systemd-run --scope -p CPUQuota=24000% -p MemoryMax=600G`,
  `nice -n 10`, per-SHA target cache with LRU under 150 GB. Defaults `--jobs 200`, cargo `-j 240`.
  Each daemon case: hermetic env (`hermetic_env.py`), state root `/tmp/o/<run6>/<case6>` (sun_path <= 100 bytes),
  `unshare -rn`, `CMUX_TUI_OFFLINE=1`.
- Fleet: `fleet.py` submits `cmux-ci run --class isolated --script scripts/measure/oracle.sh --ref SHA` per shard,
  `--config=bench` by default, waits and never resubmits after a wait timeout. Full app corpus once per
  integration batch (about every 3 h) plus `select` runs per agent change.
- Retries: 0 for filtered runs; 3 for `--suite all` and diff runs, as a whole-shard retry with the same config,
  then the case alone with a fresh app. A pass on retry is Flaky: it does not fail the run, goes to MQ-flakes,
  and is left out of the comparison.
- App driver: reset check before each case (relaunch and `LeakedState` on mismatch), `--batch-limit K`,
  `--shuffle --seed N`.
- Outputs outside the checkout: receipt.json, checkpoints.jsonl, divergence.json (ui-workflow-corpus
  review-finding shape), events.jsonl, index.md.

### H. Linux build

- `Packages/macOS/CmuxNext/linux-tier.json` lists waves; with `CMUX_SWIFTPM_TARGET_LINUX=1` the manifest keeps
  the tier targets and the path dependencies they need (a generated field), maps `CCmuxAppFFI` to
  `CCmuxAppFFILinux` (module map for the 4 module names) and adds swift-crypto and CZlib.
  Builds use a scratch copy with `Package.linux.resolved`; the checkout's `Package.resolved` is never written.
  `.xcstrings` are compiled to `.lproj/*.strings` for Linux by a stdlib script.
  - wave 0: Compat, Signposts, Wakeups, ProcessEnvironment, CCmuxAppFFILinux
  - wave 1: Actions, Daemon, Focus, TerminalGeometry, CopyMode, TerminalFind, HostPressure, DesignTokens,
    ErrorJournal, HangReports, Files, BrowserImport, ImportSuggestions, ChromiumRuntime, Devices, VSCodeServer,
    RemoteFetch, BrowserCore
  - wave 2: Bridge (after task 227), WorkspaceNaming, Cloud, CodeRouter, Remote, Mobile, Settings, Control,
    Hibernation, WorkspaceRepair
  - wave 3: UI-free leftovers (KeepAwake, PhoneAccess, Stash, HostedChief, AgentIntegrations, ChiefViews,
    RemoteLocalhost, RemoteLocalhostService, ServerHelper, CLIInstall, AgentCursorVisibility, AppCore,
    SidebarActions, AgentUpdates, CrashReporting without sentry-cocoa)
  - new: CmuxNextOracle, CmuxNextInputModel, OracleReplay, OracleInputWalk, OracleConfigDump, CmuxNextHeadless
- OS code behind `CmuxNextCompat/Platform` seams (Libc re-export, Mutex, Logger shim with `privacy:`,
  OSSignposter no-op, PlatformEvents kqueue/epoll+eventfd+timerfd, FolderChanges FSEvents/inotify,
  PeerCredentials, ProcessInfoSource). AppKit/QuartzCore helpers move down a layer into
  `CmuxNextCompatAppKit`, `CmuxNextWakeupsDisplay`, `CmuxNextActionsAppKit`, `CmuxNextControlDiagnostics`.
  Geometry-only files use `import Foundation` (corelibs defines CGFloat/CGPoint/CGRect), not `#if canImport`.
- All pure `git mv` moves and their Package.swift edits land in **one coordinated commit** (task 119) in
  hours 0-3 after the owners agree. If an owner does not agree, that target leaves the tier for the push.
- The 119 commit (cp/p15-oracle-119) moved only Compat (121), BrowserCore's imports (140, file part) and the
  Compat tests (143, Compat part). The other moves are not pure: the code that stays names the files that
  would move (moving them is a cycle). So each of these tasks lands its seam first and then its moves, in its own
  commit, and these targets stay out of the tier until it lands. Every target that depends on one of them waits
  too (most of waves 1-3 depend on Wakeups).
  - 125 Wakeups: a display-link seam in Wakeups that MainWorkScheduler's and FrameClient's users depend on.
  - 128 Actions: after 127, a menu seam for ActionRegistry, its +Choices and +ConfiguredRows, and
    ContextMenuCatalog (they name ShortcutRecorder, ActionMenuTarget, makeMenuItem and makeContextMenu).
  - 133 Settings: the protocols that replace SettingsApplier, ShortcutBinding and SettingsDiagnosticToasts.
  - 136 Control: the watchdog protocol that ControlRouter, ControlService, QuitDeadline, HangLog and the
    ActionBudget files use in place of MainThreadWatchdog.
  - 143: the Actions, Control and Settings test moves follow 128, 136 and 133.
- `swift-tier.sh --errors-queue` is the Jarred-style compiler queue.

### I. Lifecycle of a refactor under the oracle

1. If no runtime fallback is wanted: land it; run `select` + `diff --base --head` on the VM and fleet; `confirm`.
2. If a fallback is wanted: register a switch file, land the new path at default old, run `diff --switch` on
   both platforms, fix or justify each divergence, flip the default, run `launch-config`, delete the old path
   and the switch before `expires`. `switches --expired` creates the deletion queue.

---

## 4. Rules

1. No CI: no `.github/workflows` change in any p15 commit; no row in `tests/test-execution.toml`; no CI gate.
   Each run is started by an agent on the VM or the fleet (Lawrence 2026-10-23).
2. No compile or test on the person's Mac. Swift and Rust builds run on the VM or through `cmux-ci`.
3. Oracle app methods are `debug.oracle.*` inside `#if DEBUG || CMUX_BENCH_HOOKS`. None is in Release.
   `RefactorSwitches` parsing is the only oracle-related code in Release, because a switch must behave the same
   in every channel.
4. No new singleton or static state. Facet providers, recorder, switch values, hit counters, `OracleEnv`,
   `IdSource` and key stores are values injected at the composition root (AppServices, the daemon owner start,
   HeadlessServices).
5. No sleeps, polls or timers to wait: typed receipts, `waitFor`, `settle` built on existing continuations.
6. Every normalization rule and every `[ linux ]`, `Skip` or excluded script has a written reason and a task id.
7. Facets read model values, never view frames or view trees, and never read the disk or a SQLite DB on main.
   No private text in artifacts: hashes only.
8. Pure moves are `git mv` plus import and manifest edits, and the macOS behavior of moved code does not change.
   The Darwin branch of every seam is the code that exists today.
9. One implementation: the sweep and the oracle share setup; build-app-ffi.sh gets a `--linux` mode; the Python
   cmux SDK is the one daemon client; `normalize.py` is the one validator.
10. A divergence reaches an owner only after `confirm`. A flaky case is never compared.
11. Agents never use maclease. `cmux-ci` wait timeouts lead to another wait, never a resubmit.
12. Touching an owned area (OWNERS.md) needs the owner told in the commit; the Linux move commit names them all.
13. Each code task that fixes a found bug still adds a regression case and records red on base, green on head.

---

## 5. Done checks

1. **Linux tier.** `bash scripts/cmux-next/linux/swift-tier.sh --all --receipt /tmp/oracle/linux-tier.json`
   exits 0; the receipt shows >= 30 CmuxNext source targets built (today 0), >= 15 test targets, >= 1,500
   `@Test` executed (WorkspaceNaming counted). A test fails only under a `[ linux ]` Expectations line, and no
   target has more than 5 % of its tests marked `[ linux ]`. Fallback if task 119 is refused: waves 0-1 and
   >= 1,000 tests, stated in the receipt.
2. **Shared packages.** `swift-shared.sh --receipt /tmp/oracle/linux-shared.json` builds >= 26 Shared/iOS packages
   (today 15) and executes >= 2,900 tests, at most 5 % of any package `[ linux ]`; each package's count is listed.
3. **Linux speed.** Clean tier build < 600 s; `swift-tier.sh --measure-incremental CmuxNextTerminalGeometry` < 30 s.
4. **Corpus coverage.** `python3 -I scripts/cmux-next/oracle/oracle.py check --coverage` exits 0 with 0 schema and
   0 lint errors and shows: 201/201 mutation ops, 90/90 reads, 19/19 stream and connection ops, 201/201 keyed
   retries, >= 965 action cases (gaps 84 -> <= 20), 986/986 multi-entrypoint actions, 606/606 mcp actions,
   50/50 tui actions, 17/17 journeys, 23/23 tours, 66/66 e2e and 106/106 live (converted or excluded with a
   reason), 4/4 TLA specs with >= 200 traces each, >= 200 terminal cases, all api-compat vectors.
5. **Daemon determinism and speed.** `oracle.py run --product daemon --suite daemon-ops,streams,cli,walks,terminal
   --repeat 2 --jobs 200` on the VM: < 600 s for all op cases and >= 10,000 walks per arm; 0 checkpoint hashes
   differ between repeats outside Expectations; raw daemon facet bytes equal across 2 processes with the same
   `CMUX_TUI_ORACLE_SEED` for the converted stores.
6. **App batch.** `fleet.py --suite actions,entrypoints,journeys,tours,e2e,live --repeat 2 --hosts 8` on
   isolated hosts finishes in < 60 min wall per batch; <= 1 % nondeterministic checkpoints, each with a
   task-id Expectations line; a shuffled run (2 seeds) and a `--batch-limit 1` run give the same verdicts.
7. **Mutation strength.** `oracle.py selftest --mutants` catches >= 19/20 patch mutants (>= 9/10 per product).
   `mutants.sh` reports a kill rate >= 80 % on `resource_router.rs`, `resource_mutation*`, `layout.rs` and
   `journal_reducers.rs`; every surviving mutant is a queue line.
8. **Switch hygiene.** `oracle.py switches --check` exits 0 (owner, plan, `planned`, expiry <= 14 days, both-arm
   run with hits > 0 on each arm in the last 24 h, 0 unexplained divergences); `switches --expired` prints
   0 lines; the launch-config run against default has 0 unexplained divergences.
9. **Expectations budget.** Golden-suite Expectations + NeverFix lines <= 2 % of golden cases;
   `oracle.py check --stale` reports 0; every line names a task id or an issue.
10. **Invariants.** At the feat-cmux-next tip, on both arms of every switch, the green corpus gives 0 violations of
    I1-I10 and I15-I18; I11-I14 violations are each a perf-owner queue line.
11. **Base vs head.** `oracle.py diff --product daemon --base origin/feat-cmux-next~20 --head HEAD` completes in
    < 15 min including 2 oracle-profile builds (overlay or v0 facets recorded in the receipt).
12. **Confirmation.** Every routed divergence in `/tmp/oracle/route.jsonl` has 3 verdicts (head, head retry, base).
13. **Sanitizers and fuzzing.** One ASan and one TSan receipt for the daemon suites and the Swift tier; each
    fuzz target ran >= 1 h with `-fork`; every crash and unique sanitizer stack is a queue line or a fixed case.
14. **No CI added.** `git diff --stat origin/feat-cmux-next -- .github/workflows | wc -l` is 0 for every p15 commit.
15. **Release clean.** In a tagged Release build, `system.capabilities` and `action.list` contain no `oracle`
    method and every `debug.oracle.*` call returns not-allowed. The recorder hook is a nil optional set once
    at the composition root, with no allocation or lock when nil (diff check).
16. **Linux replay.** `oracle-replay --journals tests/oracle/corpus/journals` and `oracle-input-walk` (1,000,000
    steps, 200 workers) run on the VM with 0 divergences on the green set.

---

## 6. Machine queues

| Queue | Command | One task per |
| --- | --- | --- |
| MQ-daemon-ops | `jq -r '.operations\|to_entries[]\|select(.value.class=="mutation")\|.key' cmux-tui/spec/resource-operations-v2.json \| cut -d. -f1 \| sort \| uniq -c` | family group (tasks 061-070) |
| MQ-actions | `jq -r --slurpfile g scripts/cmux-next/every-action-gaps.json '.actions[].id as $i \| select(($g[0].excluded\|has($i))\|not) \| $i' plans/cmux-next/action-surfaces.json \| sed -E 's/^([a-z]+)[A-Z.].*/\1/' \| sort \| uniq -c \| sort -rn` | family block of 50-120 ids (072-081) |
| MQ-action-gaps | `jq -r '.gaps\|keys[]' scripts/cmux-next/every-action-gaps.json \| sed -E 's/^([a-zA-Z]+)[.].*/\1/' \| sort \| uniq -c` | fixture family (082-087) |
| MQ-linux-errors | per target T of `jq -r '.waves[][]' linux-tier.json`: `scripts/cmux-next/linux/swift-tier.sh build --target $T -j 240 2>&1 \| grep -E '^/.+\.swift:[0-9]+:[0-9]+: error:' \| sed -E 's/:[0-9]+:[0-9]+: error:.*//' \| sort \| uniq -c`, or `swift-tier.sh --errors-queue` (a bare `swift build` in the Linux mode first needs `compile-xcstrings.py`, or every catalog target shows zero errors) | file cluster <= 400 lines in one target |
| MQ-linux-imports | `python3 scripts/cmux-next/linux/tier-imports.py` with the regex `^\s*(@[A-Za-z_]+ )*(public \|package \|internal )?import (struct \|class \|enum \|func \|typealias \|protocol \|var \|let )?(AppKit\|SwiftUI\|WebKit\|QuartzCore\|Carbon\|os\|OSLog\|Darwin\|CoreGraphics\|CoreFoundation\|CryptoKit\|Security\|MachO\|XPC\|MetricKit\|SystemConfiguration\|Compression\|CommonCrypto\|Network\|IOKit\|UniformTypeIdentifiers\|CoreServices\|LocalAuthentication\|CFNetwork\|SQLite3\|ImageIO\|CmuxNextDesign\|CmuxNextIcons)(\.[A-Za-z]+)*\s*$` plus symbol tokens `URLSession`, `FSEvent`, `sysctl`, `os_unfair_lock`, `OSAllocatedUnfairLock`, `DistributedNotificationCenter` | target |
| MQ-linux-test-imports | `git grep -lE 'import (AppKit\|QuartzCore\|Carbon\|WebKit\|SwiftUI\|CmuxNextDesign\|CmuxNextIcons\|CmuxNextSidebar\|CmuxNextLayout\|CmuxNextTabs\|CmuxNextBridge)' -- Packages/macOS/CmuxNext/Tests/{CmuxNextActionsTests,CmuxNextControlTests,CmuxNextSettingsTests,CmuxNextCompatTests,CmuxNextSignpostsTests,CmuxNextDaemonTests,CmuxNextFilesTests}` | batch into *AppKitTests (task 143) |
| MQ-settings-design | `git grep -l 'import CmuxNext\(Design\|Icons\)' -- Packages/macOS/CmuxNext/Sources/CmuxNextSettings Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests`, grouped by the Design type used | type family (task 231) |
| MQ-shared-packages | `for p in Packages/Shared/* Packages/iOS/* Packages/macOS/CmuxPhonePush; do grep -qs "$(basename $p)" .github/workflows/swift-packages-linux.yml .github/workflows/cmux-next-terminal.yml \|\| echo "$p $(git grep -lE 'import (AppKit\|UIKit\|SwiftUI\|WebKit\|QuartzCore\|CoreText\|CoreImage\|AVFoundation\|DeviceCheck\|Sparkle\|WebRTC\|VideoToolbox)' -- $p/Sources \| wc -l)"; done`; keep UI-file count <= 2; exclude CmuxHomeRender, CmuxAppAttest, CmuxUpdater by name | package (144-150) |
| MQ-e2e | `ls scripts/cmux-next/*-e2e.py scripts/cmux-next/*-e2e.sh` (66) | batch of 11 (092-097) |
| MQ-live | `ls scripts/cmux-next \| grep -E -- '-live(-check)?\.py$'` (106) | batch of 13 (task 225, 8 units) |
| MQ-tours | `ls scripts/cmux-next/media/tours/*.json` (23) | task 091 |
| MQ-tla | `ls plans/cmux-next/formal/*.tla` (6) | spec action map (task 100) |
| MQ-facets | `jq -r '.properties.facets.properties\|keys[]' schemas/oracle/snapshot-v1.schema.json` minus `git grep -ohE 'name: "[a-zA-Z]+"' -- Packages/macOS/CmuxNext/Sources/CmuxNextApp/Oracle` | missing facet |
| MQ-flakes | `oracle.py run --suite all --repeat 3 --flaky-out /tmp/oracle/flaky.jsonl`, `rust-tests.sh`, `webviews-tests.sh` | unique (case or test, pointer) |
| MQ-daemon-clock | `git grep -n 'SystemTime::now()' -- 'cmux-tui/crates/**/*.rs' ':!**/tests/**'` (176) + `git grep -nE 'Uuid::new_v4\|rand::random\|thread_rng\|getrandom' -- 'cmux-tui/crates/**/*.rs' ':!**/tests/**'` (152), intersected with MQ-flakes pointers first | crate |
| MQ-divergences | `oracle.py diff ... --out /tmp/oracle/divergences.jsonl && oracle.py confirm && oracle.py route` | confirmed divergence -> owning program |
| MQ-switch-expiry | `oracle.py switches --expired` | expired switch -> old-path deletion |
| MQ-mutants | `scripts/cmux-next/oracle/mutants.sh --json` survivors | surviving mutant -> corpus-gap |
| MQ-coverage-gaps | `oracle.py coverage --base A --head B` uncovered hunks | changed hunk without coverage |
| MQ-races | sanitizer reports deduplicated by stack pair / top frame | unique stack |
| MQ-headless-handlers | `git grep -L -E 'import (AppKit\|SwiftUI\|WebKit\|QuartzCore)' -- Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers` (114 of 191) | domain batch <= 400 lines |
| MQ-nondeterminism-static | `git grep -nE '\bUUID\(\)\|\bDate\(\)' -- Packages/macOS/CmuxNext/Sources` intersected with MQ-flakes pointers | site |

---

## 7. Risks and decisions made

Decisions (made, not asked; Lawrence's standing rule is "decide yourself"):

- New Linux-ready Shared packages are agent-run on the VM only; they do not join `swift-packages-linux.yml`
  (rule: no new CI tests).
- Refactor switches are a frozen value read in every channel, Chrome FeatureList style, with a 14-day expiry and
  no UI. This lets a high-risk refactor (holder, CEF helper) ship with a kill switch through a launch argument.
  TunableStore stays for tuning numbers only.
- Base vs head is the default gate. No program is required to add a switch.
- Fault hooks in production code are dropped (draft tasks 022 and 045); mutants are patch files and cargo-mutants.
- The daemon facet uses the existing public `session.snapshot`; `oracle-state` adds only what that lacks.

Risks:

1. **Owner refusal of the Linux move commit (task 119).** It moves files that perf programs edit in the same 72 h
   (Wakeups FrameScheduler/MainWorkScheduler/FrameStall, Compat Blocking detector, Actions menus, Control
   watchdog). If refused, those targets leave the tier for the push and done check 1 uses its fallback.
2. **Settings off Design** (90 of 289 Settings files import CmuxNextDesign, plus CmuxNextIcons) is a queue,
   not one task. It blocks Control (372 tests), Hibernation, the config-parity Swift dump on Linux and headless.
3. **REVIEW-STANDARD "feature flags used to hide a bug".** Mitigated by the 14-day expiry, the expiry queue, the
   hit counters, the warning in task 172, and switches only where a fallback is wanted.
4. **2026-10-10 ruling.** The Linux tier runs existing in-process tests; `oracle-input-walk`, `OracleReplay` and
   `OracleConfigDump` are executables, not test targets.
5. **swift-corelibs-foundation differences** (JSON key order, Date formatting, URL, ProcessInfo). Bounded by the
   5 %-per-target `[ linux ]` rule; a target over it leaves the tier.
6. **Fleet capacity.** Isolated class, same-host pairing, `select` per change and one full batch per 3 h. Still
   competes with perf benches on the minis.
7. **VM load.** The VM runs agents too. runnerd quotas and request joining keep agent shells responsive.
8. **Normalization hiding regressions.** Every rule needs a reason; virtual clock instead of dropping time where
   converted; cargo-mutants and patch mutants measure what the oracle still catches.
9. **Release exposure.** `RefactorSwitches` parsing is in Release by design; everything else is `debug.oracle.*`.
10. **Sanitizer toolchain.** `-Zsanitizer` needs nightly and `-Zbuild-std`; libghostty-vt (zig) may need its own
    sanitizer build. If it does not link, the sanitizer lane runs on crates without ghostty first.
11. **Chromium hang.** `chrome://hang` is not reported while CEF's DevTools controller is attached
    (page-hang-live.py); that case carries an Expectations line until the fork patch lands.
12. **sun_path** <= 108 bytes on Linux: state roots stay `/tmp/o/<6>/<6>`.

Possible laziness of mine (flagged):

- I did not read hq `build-fleet/swift-linux-builder`; task 001 must read it and reuse its Swift pin.
- I did not check that `session.snapshot` carries terminal cols, rows, title and cwd; task 021 adds only what is missing.
- Test totals (1,500 tier, 2,900 shared) are grep counts, not receipts.
- I did not read every e2e and live script; some will be excluded (passkeys, webauthn, real cloud).
- The 80 % cargo-mutants kill-rate target is a guess until the first run.
- The api-compat vectors are inside a Rust test file; task 211 extracts them first, and the count is unknown.

72-hour order (critical path): hours 0-6 tasks 001, 230, 002-005, 228, 229, 119, 007, 010-019, 006, 200, 201,
020, 232, 021, 023, 024 and push-base baselines; hours 6-24 app capture (180, 027, 029-050, 008, 026, 189, 215,
216, 188) and daemon generators; hours 12-60 generators, suites, invariants, Linux queues, fuzz and sanitizers
in parallel; hours 48-72 headless stretch (160-163), launch-config, final receipts.

Dropped or merged draft items: 022 and 045 (replaced by 026 and 191); 025 merged into 191; 028 merged into 200;
051 merged into 015 and 018; 203 merged into 185 and 021; 218 merged into 187.

---

## 8. Task table

| Id | Title | Size | Hours | Depends | Queue |
| --- | --- | --- | --- | --- | --- |
| 001 | Swift 6.2 toolchain on the VM (hq pin) | S | 0-2 | - | |
| 230 | VM tool extras: Java/TLC, nightly, nextest, mutants, fuzz | S | 0-2 | 001 | |
| 002 | Linux mode of the CmuxNext Package.swift + linux-tier.json | L | 0-6 | 001, 003 | |
| 003 | build-app-ffi.sh `--linux` + CCmuxAppFFILinux module map | M | 0-4 | 001 | |
| 228 | .xcstrings compiled for Linux | M | 2-8 | 002 | MQ-linux-errors |
| 229 | Package.linux.resolved isolation | S | 2-6 | 002 | |
| 004 | swift-tier.sh / swift-shared.sh + errors queue | M | 2-8 | 002, 229 | |
| 005 | tier-imports.py static scanner (full regex + symbols) | S | 0-4 | - | MQ-linux-imports |
| 119 | One coordinated Linux move commit | L | 0-3 | 002 | MQ-linux-imports |
| 007 | runnerd.py: VM queue with quotas and caches | M | 2-8 | 024 | |
| 010 | oracle-DESIGN.md, OWNERS row, plan links | M | 0-6 | - | |
| 011 | Snapshot schema v1 | M | 0-4 | - | |
| 012 | Case schema v1 (requires, waitFor, allow_crashes) | M | 0-4 | - | |
| 013 | normalize.py + stdlib validator | L | 2-8 | 011, 012 | |
| 014 | diff.py first divergence + host check | M | 4-10 | 013 | |
| 015 | Expectations.d with Chrome keywords + linter | M | 4-10 | - | |
| 016 | Baseline store, two-pass fallback, classes | M | 4-10 | 013 | |
| 017 | oracle.py CLI: shards, retries, shuffle | L | 4-12 | 013-016 | |
| 018 | Switch registry dir with expiry and planned arm | M | 4-10 | - | |
| 019 | selftest.py | M | 8-14 | 017 | |
| 006 | v0 facets from push-base methods + push-base baselines | M | 4-10 | 013, 017 | |
| 200 | Hermetic per-case env + CMUX_TUI_OFFLINE | M | 4-10 | 023 | |
| 201 | Cargo `oracle` profile and feature | S | 0-4 | - | |
| 020 | cmux-tui Switches value | M | 2-8 | 201 | |
| 232 | Holder env into Switches + seed registry | S | 6-10 | 020, 018 | |
| 021 | Daemon facet on session.snapshot + oracle-state extras | M | 4-10 | 020, 201 | |
| 023 | driver_daemon.py | L | 6-14 | 017, 021 | |
| 024 | linux_run.sh two SHAs with submodules | M | 8-14 | 023, 201 | |
| 180 | Frozen RefactorSwitches value in the app | M | 6-16 | 018, 020 | |
| 027 | Per-site switch hit counters | M | 10-20 | 180 | |
| 030 | CmuxNextOracle + debug.oracle.snapshot | L | 6-14 | - | |
| 029 | Awaitable applied-sequence and intent-idle waiters | M | 8-16 | 030 | |
| 031 | debug.oracle.settle + debug.oracle.wait_for | M | 10-18 | 029 | |
| 032 | OracleRecorder turn checkpoints | M | 10-18 | 030 | |
| 033-044 | App facets (topology ... terminals) | S/M | 10-24 | 030 | MQ-facets |
| 215 | Webview page facet | M | 12-24 | 030 | MQ-facets |
| 216 | AX tree facet + ax suite | M | 12-24 | 030 | MQ-facets |
| 188 | crashes + liveObjects facets, I17/I18 | M | 12-24 | 030, 021, 110 | |
| 046 | Shared sweep setup (phase 1, no move) + plan-only dump | M | 6-12 | - | |
| 047 | driver_app.py (bench config) | L | 12-20 | 031, 046 | |
| 189 | App reset check, batch limit, shuffle | M | 16-24 | 047 | |
| 048 | driver_cli.py (VM and fleet modes) | S | 10-16 | 023 | |
| 049 | Apply and verify arms | M | 14-22 | 018, 047, 180 | |
| 050 | fleet.py + scripts/measure/oracle.sh | M | 14-22 | 047 | |
| 008 | Same-host A/B pairing | S | 18-24 | 050 | |
| 026 | 20 seeded mutants as patch files | M | 18-30 | 050, 024 | |
| 060 | gen_daemon_ops.py | L | 12-20 | 023, 200 | MQ-daemon-ops |
| 061-070 | Daemon-op families | M | 18-48 | 060 | MQ-daemon-ops |
| 237 | Driver user connection (install-key hello) | M | 20-36 | 023, 200, 070 | MQ-daemon-ops |
| 238 | Driver loopback pairing step | S | 20-36 | 023, 200, 070 | MQ-daemon-ops |
| 239 | Chromium daemon-op cases on the app product | M | 20-40 | 047, 061, 067 | MQ-daemon-ops |
| 240 | Driver: errorDetails, mock agent, chief connections | M | 20-36 | 023, 237, 069 | MQ-daemon-ops |
| 241 | Typed refusals the chief family found | S | 20-28 | 069 | |
| 242 | normalize.py snapshot-v1 keywords | S | 18-28 | 013, 011 | |
| 245 | The holder exits at shutdown end_terminals | S | 20-28 | 065 | |
| 246 | Facet: a terminal's view scroll offset | S | 20-28 | 065 | |
| 247 | Driver: a call that ends the daemon, expect.result references | S | 20-36 | 023 | MQ-daemon-ops |
| 248 | Case daemon with installed first-party apps | S | 20-30 | 023, 200, 064 | MQ-daemon-ops |
| 270 | Action cases: sidebar, item and group targets | M | 20-36 | 047, 071, 075 | MQ-actions |
| 271 | Facet: a workspace group's color, icon and archived mark | S | 20-28 | 036, 075 | |
| 272 | Facet: the top band's items | S | 20-28 | 036, 075 | |
| 273 | Pin Chat with no target refuses | S | 20-28 | 075, 270 | |
| 274 | Gap fixtures: a chat in the sweep's acpmux, the Priority view per sample | M | 20-36 | 046, 086 | MQ-action-gaps |
| 290 | Open Conversation refuses an unknown id | S | 20-28 | 076 | |
| 291 | Select Conversation 1-9 is a focus action | S | 20-28 | 076 | |
| 292 | No picker or ask for a socket run without an argument | S | 20-28 | 076 | |
| 293 | TOGGLES matches whole words | S | 18-24 | 071, 076 | |
| 300 | NEIGHBOR_STEPS start from the far pane | S | 20-28 | 071, 080 | MQ-actions |
| 301 | Right sidebar in the reset snapshot and the windows facet | M | 20-36 | 189, 080 | |
| 330 | Action cases: generated setup runs with focus | M | 20-36 | 071, 072, 077 | MQ-actions |
| 331 | Facet: screen and screen group metadata | S | 20-28 | 035, 077 | |
| 332 | Screen creates answer with the screen | S | 20-28 | 077 | |
| 333 | No silent no-op for column and workspace moves | S | 20-28 | 077 | |
| 334 | Reopen Saved Screen Group refuses an unknown id | S | 18-24 | 077 | |
| 350 | Live: pointer step and menu rows | M | 20-36 | 047, 012, 225 | MQ-live |
| 351 | Live: app restart step | M | 20-36 | 047, 189, 225 | MQ-live |
| 352 | Live: https, basic auth and PDF in the web fixture | S | 18-28 | 222, 225 | MQ-live |
| 353 | Live: stand-ins or retirements for scripts outside reach | S | 18-28 | 225 | |
| 354 | Live: the app's Chief over mock_chief.py | M | 20-36 | 047, 200, 240, 225 | MQ-live |
| 355 | Live: per-case launch environment and config | M | 20-36 | 047, 200, 225 | MQ-live |
| 356 | Live: facets for the scripts' debug.* reads | L | 24-48 | 030, 225 | MQ-live |
| 357 | Live: chrome:// and cmux:// pages are local | S | 18-24 | 012, 225 | MQ-live |
| 360 | Loopback TLS page | S | 18-28 | 222, 225, 072, 352 | MQ-action-gaps |
| 361 | Oracle test extension in the hermetic profile | M | 20-36 | 047, 072 | MQ-action-gaps |
| 248 | Loopback permission-asking page | S | 18-24 | 222, 225, 072 | MQ-action-gaps |
| 249 | Loopback Web Store stand-in | S | 18-28 | 222, 225, 072 | MQ-action-gaps |
| 206 | I10 idempotent retry steps | S | 20-28 | 060, 110 | |
| 204 | Streams suite + I8 | L | 18-36 | 023, 110 | |
| 205 | restore_preview + I9 | M | 18-30 | 021, 201 | |
| 211 | api-compat vectors as cases | S | 18-30 | 023 | |
| 071 | gen_actions.py | M | 20-28 | 046, 047 | MQ-actions |
| 072-081 | Action families | M/L | 24-60 | 071 | MQ-actions |
| 082-087 | Gap fixtures per family | S/M | 20-48 | 046 | MQ-action-gaps |
| 209 | MCP suite | M | 20-36 | 048 | |
| 210 | Entrypoint-parity suite | M | 28-48 | 071, 209 | |
| 222 | Hermetic web fixture server | S | 10-18 | 012 | |
| 088-090 | Journeys P0/P1/P2 | M/L | 20-48 | 047, 222 | |
| 223 | Chromium failure journeys | M | 24-40 | 047, 222 | |
| 224 | Holder crash journey | S | 24-36 | 065, 232 | |
| 091 | Tours to cases | L | 24-48 | 047 | MQ-tours |
| 092-097 | e2e batches (66 scripts) | L | 24-60 | 047 | MQ-e2e |
| 225 | live batches (106 scripts) | L | 24-66 | 047 | MQ-live |
| 098 | Walks + ddmin | L | 16-28 | 023 | |
| 099 | Walks at scale on arms | M | 30-60 | 098, 111 | |
| 207 | Crash-consistency walks | M | 28-48 | 098, 201 | |
| 208 | Store upgrade and rollback corpus | L | 24-48 | 023, 024 | |
| 100 | TLA traces to cases | L | 20-44 | 060, 230 | MQ-tla |
| 101 | Terminal VT corpus to >= 200 | M | 18-36 | 023 | |
| 234 | TUI frontend suite | M | 24-48 | 023 | |
| 212 | Config parity Swift vs Rust | M | 30-60 | 134 | |
| 213 | Pane-protocol vectors x 3 runners | M | 18-40 | - | |
| 102 | InputModel part 1 (attach machine out of Bridge) | L | 20-36 | 002, 119 | |
| 103 | InputModel part 2 (replay, attach oracle) | L | 30-48 | 102 | |
| 104 | oracle-replay executable | M | 40-56 | 103, 004 | |
| 105 | oracle-input-walk executable | L | 40-60 | 103 | |
| 110 | invariants.py I1-I7 | L | 12-24 | 017 | |
| 217 | I11-I15 side channels | M | 20-32 | 110 | |
| 236 | I16 panic and lock rank | S | 16-24 | 201, 110 | |
| 111 | diff --switch | M | 20-30 | 049, 014 | |
| 112 | diff --base/--head | M | 18-30 | 024, 050 | |
| 202 | Overlay for old bases | M | 24-36 | 006, 112 | |
| 183 | launch-config arm + switch bisect | M | 30-48 | 111, 180 | |
| 184 | confirm before route | M | 24-36 | 112, 118 | |
| 009 | select + bisect on the batch | M | 24-40 | 017, 112 | |
| 113 | Engine parity | S | 30-44 | 111 | |
| 114 | Platform parity (daemon) | S | 36-54 | 112 | |
| 235 | Windows daemon parity (stretch) | S | 60-72 | 114 | |
| 115 | selftest --mutants | M | 30-44 | 026, 110 | |
| 191 | cargo-mutants with the oracle | M | 30-60 | 060, 098, 230 | MQ-mutants |
| 190 | Incremental coverage | M | 30-54 | 024, 004 | MQ-coverage-gaps |
| 116 | report.py | M | 14-24 | 017 | |
| 117 | Flake detection | M | 16-28 | 017 | MQ-flakes |
| 118 | route.py | S | 20-30 | 111 | MQ-divergences |
| 185 | Daemon virtual clock + seeded ids + sorted output | L | 12-36 | 020, 021 | MQ-daemon-clock |
| 220 | Parser fuzzers + fuzz workspace | M | 12-30 | 230 | |
| 186 | Resource-op sequence fuzzer | L | 24-48 | 220, 021, 110 | |
| 187 | Sanitizer lanes (ASan/TSan) | L | 20-48 | 024, 004, 230 | MQ-races |
| 219 | Miri on pure crates | S | 12-24 | 230 | |
| 221 | Rust tests at 300 jobs, x3 | S | 6-12 | 230 | MQ-flakes |
| 214 | Webviews and web bun tests on the VM | S | 6-12 | - | MQ-flakes |
| 233 | Motion-off default + motion-on arm | S | 24-36 | 047, 111 | |
| 120-142 | Linux tier source tasks | S-L | 3-60 | per row | MQ-linux-errors / imports |
| 226 | Wave 3 UI-free targets | M | 40-66 | 002, 227 | MQ-linux-errors |
| 227 | Bridge off UI edges | L | 8-40 | 002, 119 | MQ-linux-errors |
| 231 | Settings Design types to DesignTokens | L | 8-48 | 131 | MQ-settings-design |
| 143 | AppKit test files to *AppKitTests | M | 8-30 | 128 | MQ-linux-test-imports |
| 144-150 | Shared packages on Linux | S-L | 8-48 | 004 | MQ-shared-packages |
| 151 | Linux tier report | S | 20-72 | 004 | |
| 160-163 | Headless (stretch) | L/M/S | 48-72 | per row | MQ-headless-handlers |
| 170 | Skill reference oracle.md | S | 24-36 | 017 | |
| 171 | Expiry sweep | S | 12-20 | 018 | MQ-switch-expiry |
| 172 | Pre-push warning for unregistered switch | S | 12-24 | 018 | |

---

## 9. Task details

Ids are `p15-oracle-NNN`. "VM" = the 360-core Linux host. "Fleet" = `cmux-ci` on owned minis.

### Foundation and Linux mode

**001 Swift 6.2 toolchain on the VM.** Files: `scripts/cmux-next/linux/setup-swift.sh`, `scripts/cmux-next/linux/README.md`.
Change: first read hq `build-fleet/swift-linux-builder` for its Swift pin and recipe and reuse it; if it differs from
the `swift:6.2-noble` tag in `.github/workflows/swift-packages-linux.yml`, use the workflow tag and print the
difference. Install swiftly + that Swift, `libsqlite3-dev zlib1g-dev libcurl4-openssl-dev libxml2-dev`. Idempotent.
Acceptance: version read from a repo or hq file, not a literal; checks before download; no `.github` change.
Test: run twice (second run no change); `swift build --package-path Packages/Shared/CMUXAuthCore` passes.

**230 VM tool extras.** File: `scripts/cmux-next/linux/setup-tools.sh`. Change: OpenJDK 17 (for `plans/cmux-next/formal/tlc.sh`),
cargo-nextest, cargo-mutants, cargo-fuzz, a dated nightly with rust-src, zig matching `ghostty-next/build.zig.zon`,
`shasum` shim if missing; check `git submodule status ghostty-next`. Acceptance: idempotent; every version read from a
repo file. Test: run twice; `plans/cmux-next/formal/tlc.sh hovercard` passes.

**002 Linux mode of Package.swift.** Files: `Packages/macOS/CmuxNext/linux-tier.json`, `Packages/macOS/CmuxNext/Package.swift`.
Change: waves 0-3 + new targets + test targets; a generated `pathDependencies` field. With `CMUX_SWIFTPM_TARGET_LINUX=1`:
keep tier targets and products, keep only the path packages the tier needs (drops CmuxGhosttyKit, CmuxScreenKit,
CmuxUpdater, CmuxAppAttest, CmuxSentryTelemetry, CmuxHomeRender, sentry-cocoa, Sparkle), map CCmuxAppFFI to
CCmuxAppFFILinux, add swift-crypto and CZlib. Acceptance: without the env var `swift package dump-package` and
ci-target-graph.json are unchanged; `Package.resolved` unchanged; with it, only tier targets appear.
Test: VM resolve in the 229 scratch copy; fleet `cmux-ci compile-check --ref SHA --package macOS/CmuxNext` green.

**003 Linux FFI staticlib.** Files: `scripts/cmux-next/build-app-ffi.sh`, `Packages/macOS/CmuxNext/Sources/CCmuxAppFFILinux/module.modulemap`,
`Packages/macOS/CmuxNext/Sources/CCmuxAppFFILinux/shim.c`. Change: add `--linux` to the existing script: build in a git
worktree at the exact crate sha from the CCmuxAppFFI binaryTarget URL, skip xcodebuild and lipo, write the same per-module
header folders to `.build-linux/ffi`. Module map exposes CCmuxLayoutReducerFFI, CCmuxRdFFI, CCmuxMotionFFI,
CCmuxPaletteRankerFFI. Acceptance: no second build script; headers come from the crates; the macOS path is unchanged.
Test: VM: the `.a` has the symbols called by Sources (`git grep -ohE 'cmux_[a-z_]+\(' Packages/macOS/CmuxNext/Sources | sort -u` vs `nm`).

**228 .xcstrings for Linux.** Files: `scripts/cmux-next/linux/compile-xcstrings.py`, Package.swift (Linux branch only).
Change: compile each tier `.xcstrings` (Actions 11, Settings/Control/RemoteFetch 1 each) into `<lang>.lproj/*.strings`
under `.build-linux`; Linux mode uses `.copy` of the generated lproj. Acceptance: macOS manifest unchanged; stdlib only.
Test: VM: Actions builds; one test resolves an ActionCatalog title to English.

**229 Package.linux.resolved isolation.** Files: `scripts/cmux-next/linux/swift-tier.sh`, `Packages/macOS/CmuxNext/Package.linux.resolved`.
Change: build in a scratch copy (`rsync --link-dest` under /tmp) with `--scratch-path` and
`--only-use-versions-from-resolved-file`. Acceptance: `git status --porcelain Packages/macOS/CmuxNext/Package.resolved` empty after a run.
Test: VM two runs, checkout unchanged.

**004 swift-tier.sh and swift-shared.sh.** Files: `scripts/cmux-next/linux/swift-tier.sh`, `swift-shared.sh`, `errors_queue.py`.
Change: `swift build -j 240 --build-tests`, `swift test --parallel --num-workers 200` per tier test target, receipt (sha,
toolchain, targets built/failed, tests executed/passed/failed, wall times), `--errors-queue OUT`, `--measure-incremental T`,
`--sanitize thread|address`. Shared runner covers 26+ packages. Acceptance: not referenced from `.github`; non-zero exit on
any failure without a `[ linux ]` line. Test: VM run at base gives 0 targets built and a populated queue.

**005 tier-imports.py.** File: `scripts/cmux-next/linux/tier-imports.py`. Change: the MQ-linux-imports regex (with `import
struct X.Y` and `os.log` forms, CoreFoundation, CmuxNextDesign, CmuxNextIcons) and a symbol-blocker column (URLSession,
FSEvent, sysctl, os_unfair_lock, OSAllocatedUnfairLock, DistributedNotificationCenter); transitive blockers from
ci-target-graph.json. Acceptance: order-independent output; the 17 `import os.log`-style files are caught. Test: run at base and tip.

**119 One coordinated Linux move commit.** Files: Package.swift, `plans/cmux-next/architecture-layers.json`, `plans/cmux-next/OWNERS.md`,
the moved files of tasks 121, 140 (file part) and 143 (Compat part); 125, 128, 133, 136 and the rest of 143 are not
pure moves and land later in their own commits (section H). Change: after owners agree, one agent
does every pure `git mv` and its target edits in one commit in hours 0-3. Acceptance: renames, imports and manifest/layer
edits only; owners named in the commit. Test: fleet compile-check of the app and package tests at that commit.

**007 runnerd.py.** Files: `scripts/cmux-next/oracle/runnerd.py`, `linux_run.sh`. Change: flock + spool queue, joins identical
(sha, suite, arm, profile) keys, `systemd-run --scope -p CPUQuota=24000% -p MemoryMax=600G`, `nice -n 10`, per-SHA target dir LRU
under 150 GB, receipt reuse. Acceptance: no oracle job runs outside the queue. Test: 20 submits of one pair cause 2 builds.

### Oracle core

**010 Design doc and links.** Files: `plans/cmux-next/oracle-DESIGN.md`, `OWNERS.md`, `ui-workflow-corpus.md`, `input-spec.md`.
Change: this spec's design with citations; OWNERS row for all owned paths; input-spec points to oracle-input-walk.
Acceptance: each number has its rg/jq command next to it. Test: `python3 scripts/verify-local.py` docs lint.

**011 Snapshot schema v1.** Files: `schemas/oracle/snapshot-v1.schema.json`, `schemas/oracle/README.md`, `schemas/oracle/fixtures/snapshot-example.json`.
Change: all facets of section 3A with `x-oracle-order`, `x-oracle-volatile` (+reason), `x-oracle-id-kind`, precision, source method.
Acceptance: every field names its source method. Test: `python3 -I scripts/cmux-next/oracle/normalize.py --validate` on the example.

**012 Case schema v1.** Files: `schemas/oracle/case-v1.schema.json`, two example fixtures, `schemas/oracle/fixtures/case-v1-mutations.json`,
`scripts/cmux-next/oracle/case_checks.py`. Change: manifest fields + `requires`,
`switches`, `platforms`, `allow_crashes`, step ops of 3D, `waitFor`, `checkpoint`. Rejects unknown fields, duplicate step ids,
a mutating step without target or receipt, any non-loopback URL. The checks JSON Schema cannot state (`x-oracle-unique`,
`x-oracle-step-ref`, `x-oracle-crash-scope`) run in the stdlib `case_checks.py`. Acceptance: duplicate-id error names the step
(`duplicate step id "split-right": /steps/1/id repeats /steps/0/id`). Test: `python3 -I scripts/cmux-next/oracle/case_checks.py --selftest`
(the mutation table on both layers); `oracle.py check` on fixtures once 017 lands.

**013 normalize.py.** Change: section 3C, `--explain`, stdlib validator. The validator covers case-v1 too: its JSON Schema subset
reports each refusal with the def's `x-oracle-error` text when there is one, then calls `case_checks.check_case` (012) for
`x-oracle-unique`, `x-oracle-step-ref` and `x-oracle-crash-scope`. Acceptance: stable under key-order and id permutation; no
rule drops a field without `x-oracle-volatile`; every entry of `schemas/oracle/fixtures/case-v1-mutations.json` gives its layer's
result with jsonschema absent. Test: selftest 30 property cases, plus that table (the duplicate-id entry's error names the id).

**014 diff.py.** Change: first (step, checkpoint, pointer, a, b) per case + divergent count; divergence.json; applies
expected_differences; refuses host/OS mismatch (`host-mismatch`). Acceptance: first divergence only; explained differences labeled.
Test: selftest synthetic runs.

**015 Expectations.** Files: `scripts/cmux-next/oracle/expectations.py`, `tests/oracle/Expectations.d/`, `tests/oracle/NeverFix.d/`, `tests/oracle/README.md`.
Change: syntax of 3E with product and build modifiers, pointer suffix, most specific match wins. Lint: bug id, duplicates, stale,
golden budget 2 %. Acceptance: several results = flaky; Skip never runs; Failure reports unexpected pass; Crash is a result.
Test: selftest 20 parser cases, including a split-directory set equal to a combined file.

**016 Baselines.** Files: `scripts/cmux-next/oracle/baselines.py`, `tests/oracle/baselines/.gitkeep`. Change: two-pass fallback of 3E,
`rebaseline --run DIR [--only-changed] [--platform]`, `optimize`; differential suites never get reviewed baselines.
Acceptance: never writes Timeout or uncertain checkpoints. Test: selftest case where the generic arm baseline beats a platform base baseline.

**017 oracle.py CLI.** Subcommands gen, check (--coverage, --stale; normalize.py's validator plus `case_checks.py` on every case), run (--product, --suite, --switch, --arm, --shard i/n, --jobs,
--repeat, --retry-limit, --shuffle --seed, --batch-limit, --out), diff, confirm, select, bisect, rebaseline, report, minimize,
switches, route, coverage, selftest. Retry policy of 3G. Acceptance: shards cover each case once; Flaky never passes the comparison.
Test: VM dry run over 4 shards.

**018 Switch registry.** Files: `plans/cmux-next/refactor-switches/` (one JSON per switch), `schemas/oracle/refactor-switches.schema.json`,
`scripts/cmux-next/oracle/switches.py`. Fields of 3F.2. `--check` refuses expiry > 14 days, missing `planned`, an unknown app key
(not in the RefactorSwitches catalog), an unparsed daemon switch, a `live` switch read through a per-call closure.
Test: `switches.py --check` on the seed files.

**019 selftest.py.** Stdlib unittest run as a script; not in test-execution.toml. Test: `python3 -I scripts/cmux-next/oracle/selftest.py`.

**006 v0 facets and push-base baselines.** Files: `scripts/cmux-next/oracle/facets_v0.py`, `driver_app.py`, `driver_daemon.py`.
Change: facets from methods present at the push base; capture push-base daemon-ops, actions and journeys before the first refactor lands.
Acceptance: every v0 field names a method `git grep` finds at the push base. Test: capture push base twice; equal hashes.

**200 Hermetic env.** Files: `scripts/cmux-next/oracle/hermetic_env.py`, `driver_daemon.py`, `driver_app.py`, `gen_daemon_ops.py`,
`cmux-tui/crates/cmux-tui/src/owner_start/background_checks.rs`. Change: per-case HOME, XDG_*, CMUX_TUI_CONFIG/STATE_DIR/SOCKET,
TZ=UTC, LANG=C.UTF-8, SHELL=/bin/sh with fixed PS1, `CMUX_TUI_NO_LOGIN_SHELL=1`, hooks disabled, update check off,
`GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, empty `core.hooksPath`, `commit.gpgsign=false`, local bare origin,
`env -i` base, `unshare -rn` on Linux. Daemon: `CMUX_TUI_OFFLINE=1` returns early in `spawn()` (no flags or registry fetch).
Acceptance: both drivers build env only here; generator refuses non-local remotes; daemon diff is the early return only.
Test: 300 cases under unshare; logs show `feature-flags: off (offline)`; git family green twice.

**201 Cargo oracle profile and feature.** Files: `cmux-tui/Cargo.toml`, `crates/cmux-tui-core/Cargo.toml`, `crates/cmux-tui/Cargo.toml`, `linux_run.sh`.
Change: `[profile.oracle] inherits="release"`, `lto="off"`, `codegen-units=256`, `debug-assertions=true`, `overflow-checks=true`,
`debug="line-tables-only"`; `oracle` feature (off by default). Acceptance: release profile and default features unchanged;
oracle items behind `cfg(any(debug_assertions, feature="oracle"))`. Test: cold build < 6 min, leaf incremental < 60 s.

**020 cmux-tui Switches value.** Files: `cmux-tui/crates/cmux-tui-core/src/switches.rs`, `lib.rs`, `crates/cmux-tui/src/cli/version.rs`.
Change: parse `CMUX_TUI_SWITCHES` once at owner start; pass by argument; reject unknown names; report in `--version --json` and identify.
Acceptance: `git grep -n 'static.*Switches' cmux-tui/crates` is empty. Test: unit tests + integration test reading arms from identify.

**232 Holder env into Switches, seed registry.** Files: `holder_runtime.rs`, `switches.rs`, `plans/cmux-next/refactor-switches/*.json`.
Change: read the holder model through Switches with `CMUX_TUI_TERMINAL_HOST_MODEL` as alias until expiry; seed F6 holder, F1
layerHosting, F2 CEF helper, F7 intents, F8 discard with owners from perf-lead.md. Acceptance: the env name appears in core only in
switches.rs. Test: `holder_terminals.rs` passes with the alias.

**021 Daemon facet.** Files: `cmux-tui/crates/cmux-tui-core/src/oracle_state.rs`, `server/commands.rs`, `cmux-tui/spec/commands.md`, `scripts/cmux-next/oracle/driver_daemon.py`.
Change: the daemon facet is `session.snapshot` + `settings.snapshot` + journal head from `public_session_snapshot_with_journal_head`.
`oracle-state` (oracle feature or debug only) adds only fields those lack (switches, terminal attach counts, live-object counts,
panic log path) and emits maps as sorted keys. Acceptance: no second snapshot builder; not in the release command table; no
`HashMap` in output types. Test: output after a fixed op script equals a checked-in expected JSON.

**023 driver_daemon.py.** Isolated cmux-tui per case through hermetic_env, Python SDK (`cmux-tui/bindings/python/cmux`) as the only
client, resource.call/kill/restart/advance_clock steps, I6 teardown proof. Acceptance: socket paths <= 100 bytes. Test: 300 parallel
no-op cases, `pgrep -f cmux-tui` empty after.

**024 linux_run.sh.** Worktrees under `/tmp/oracle-wt`, `git -C <wt> submodule update --init ghostty-next` with a shared
`--reference`, never `CMUX_GHOSTTY_SRC` across SHAs, `cargo build --profile oracle --features oracle -p cmux-tui`, gitlinks recorded.
Acceptance: only its own /tmp dirs; cleans up. Test: tip vs tip, 0 divergences, < 15 min.

### App capture

**180 Frozen RefactorSwitches.** Files: `CmuxNextCompat/RefactorSwitches.swift`, `CmuxNextApp/CmuxNextApp+LaunchEnvironment.swift`,
`CmuxNextDaemon/Launch/DaemonDiagnosticKnobs.swift`, `CmuxNextDaemon/Launch/DaemonLauncher.swift`, `CmuxNextBrowser/CEF/CEFLayerHosting.swift`.
Change: parse `--cmux-switches=` or `CMUX_NEXT_SWITCHES` synchronously before AppServices; inject; DEBUG read before parse traps;
DaemonLauncher sets `CMUX_TUI_SWITCHES`; knobs forward `CMUX_NEXT_ORACLE_SEED`; in oracle mode refuse a running daemon whose
identify switches differ; move layerHosting off the per-call TunableStore closure. Acceptance: no static holds the value; parse is not
DevTools-gated; unknown name is a DEBUG launch error and one log line in Release. Test: fleet bench build, both arms read back at
the first control request.

**027 Switch hit counters.** Files: `CmuxNextApp/Oracle/SwitchHits.swift`, `AppServices+Oracle.swift`, `switches.py`. Change: each
guarded site counts the arm it ran; `debug.oracle.switch_hits`. Acceptance: value injected from AppServices; 0 hits on the requested
arm is `arm-not-exercised`. Test: layerHosting hits only on the requested arm.

**030 CmuxNextOracle + debug.oracle.snapshot.** Files: `Sources/CmuxNextOracle/OracleFacetProvider.swift`, `OracleFacets.swift`,
`CmuxNextApp/Control/AppControl+Oracle.swift`, `CmuxNextApp/AppServices+Oracle.swift`, Package.swift, architecture-layers.json.
Change: core target (Foundation + Compat), protocol + immutable facet list built in AppServices; registration inside
`#if DEBUG || CMUX_BENCH_HOOKS` next to registerInputMethods; main-actor facets take one hop. Acceptance: no `static shared`; Release
router answers not-allowed. Test: DEV build lists facets; Release refuses.

**029 Waiters.** Files: `Sources/CmuxNextDaemon/` (applied-sequence source), intent store, `AppControl+OracleSettle.swift`.
Change: continuation-based `waitApplied(atLeast:)` and `waitIntentsIdle()` resumed from existing state changes. Acceptance: no
Task.sleep, asyncAfter or Timer in the diff. Test: 1,000 settles p99 below settleMaxMs.

**031 settle and wait_for.** Files: `AppControl+OracleSettle.swift`, `CmuxNextControl/Routing/ControlRouter+Barrier.swift`.
Change: settle on `ControlSnapshot.reflects(ControlSequenceBarrier)`, waitIntentsIdle, MotionClock idle, one CommitBoundary;
`wait_for {pointer, predicate, maxMs}` from facet change signals; timeout returns pending list and the runner records Timeout.
Acceptance: names only existing symbols plus 029's waiters. Test: forced pending intent appears in `pending`.

**032 OracleRecorder.** Files: `CmuxNextActions/ActionRunObserver.swift` (new), `CmuxNextApp/Oracle/OracleRecorder.swift`, `AppControl+Oracle.swift`.
Change: optional observer called at the end of the perform turn; ring of 256 checkpoints holding the armed facet values (the
runner normalizes turn and settled alike for I3: a hash of raw values would differ on commit counters); `debug.oracle.turns`, `debug.oracle.recorder`.
Acceptance (structural): immutable optional set once at the root; no allocation or lock when nil; `// perf-hot: <1us action.perform`.
Test: same-host A/B on the action.perform perf-hot bench with a confidence interval.

**033-044 Facets.** One file each under `CmuxNextApp/Oracle/`: 033 topology + invariants (reuse encoders, `InputInvariantMonitor.check()`),
034 focus (`InputObservationBuilder`), 035 layout (model values only), 036 sidebar (no edits under `CmuxNextSidebar/`; send a590 the
field list), 037 tabs (BrowserCore protocol), 038 overlays, 039 settings (applied snapshot, no file read), 040 intents (**monotonic**
rollback and refusal totals; the runner computes deltas), 041 windows (fractions), 042 history + notifications (no SQLite on main),
043 agents (hashes only), 044 terminals (async daemon vt-state off main). Each test phase: the matching journey or case on the fleet.

**215 Webview facet.** Files: `OracleWebviewsFacet.swift`, `webviews/src/protocol/oracle-state.ts`. DevTools-gated pane-protocol call;
per-page store summary with hashes only. Test: agent-pane and palette journeys show it. Run `bun run check` in webviews.

**216 AX facet.** Files: `OracleAccessibilityFacet.swift`, `tests/oracle/corpus/ax/`. Labels by localization key. Test: 12 journeys x 3 widths.

**188 crashes + liveObjects, I17/I18.** Files: `OracleCrashesFacet.swift`, `OracleLiveObjectsFacet.swift`, `oracle_state.rs`, `invariants.py`,
`case-v1.schema.json`. From `CEFChildProcessMonitor`, `CEFRuntime+Crashes`, `CrashRecoveryService` and holder exit records.
Acceptance: no new observer when the oracle is off. Test: renderer crash without allow_crashes fails I17; a leaked tab fails I18.

**046 Shared sweep setup, phase 1.** Files: `scripts/cmux-next/oracle/action_fixtures/__init__.py`, `scripts/cmux-next/every-action-sweep.py`.
Change: the oracle imports the sweep's setup and teardown where they are; add `--plan-only` to the sweep (dumps the per-action plan);
the sweep loads extra per-family fixtures from `oracle/action_fixtures/<family>.py`. Acceptance: `--plan-only` output identical before
and after for all actions (no GUI). Test: VM plan-only diff empty.

**047 driver_app.py.** Launch via `bench_launch.launch_app`, `--config=bench` by default, animations off, steps action.run, debug.key,
cli, mcp, waitFor, settle, snapshot, turns; teardown via TagTeardown. Acceptance: no new launch code; never touches `/Applications/cmux.app`.
Test: 20 action cases twice, equal hashes.

**189 Reset check, batch limit, shuffle.** Files: `driver_app.py`, `oracle.py`. Acceptance: `LeakedState` names the leaking case; order
recorded. Test: actions with 2 shuffle seeds and K=1 give batched verdicts.

**048 driver_cli.py.** VM: the cargo-built `cmux` at the run SHA; fleet: `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh`. Never `/tmp/cmux-cli`.
Test: 50 daemon CLI cases on the VM.

**049 Apply and verify arms.** Files: `switches.py`, `driver_app.py`, `driver_daemon.py`. Launch arg for app, `CMUX_TUI_SWITCHES` for daemon,
readback from `debug.oracle.snapshot.switches` and identify, plus hit counters. Mismatch: `arm-not-applied`. Test: unknown key aborts.

**050 fleet.py + oracle.sh.** `cmux-ci run --class isolated --script scripts/measure/oracle.sh --ref SHA --shard i/N`; never resubmit
after wait timeout; ask hq to allowlist oracle.sh (split-spring workaround until then). Test: 6 shards merge into one receipt.

**008 Same-host pairing.** Files: `fleet.py`, `oracle.sh`, `diff.py`. Both arms or both tags on one host, case by case. Test: forced cross-host pair refused.

**026 Seeded patch mutants.** Files: `tests/oracle/mutants/app/*.patch`, `tests/oracle/mutants/daemon/*.patch`, `oracle.sh`, `linux_run.sh`, `selftest.py`.
The 10 app and 10 daemon faults of the draft as patches applied in the job worktree. Acceptance: `git grep -n OracleFaults -- Packages` empty;
`git apply --check` of every patch at tip. Test: >= 9/10 caught per product.

### Suites and generators

**060 gen_daemon_ops.py** (+`tests/oracle/corpus/daemon-ops/`): one success case per mutation op on the standard fixture, typed-error case,
coverage.json; regeneration stable. **061-070** family tuning as in the draft (browser 17, sidebar 22, session 11 + graceful restart, workspace 26,
terminal 9 on both holder arms, layout 25, tab 21, git/project/stash 18 on generated repo, chief/agents 24 with mock, misc 28). Each: success + error
case, both arms where listed, green twice on the VM.

The 17 success cases a family tuning cannot run on the plain case connection are excluded with a gap that names one
of these three follow-ups; gen_daemon_ops.py refuses a gap that names no WORK.tsv task or only the family task and its
dependencies (done before the family task, so they close nothing).

**237 Driver user connection.** Files: `driver_daemon.py`, `hermetic_env.py`, `case-v1.schema.json`, `gen_daemon_ops.py`,
`misc/_tuning.json`, `workspace/_tuning.json`. The case daemon gets a per-case DEV install key on `--owner-install-key-fd` (`cmuxik1 <install_id>
<hex key>`, never argv or env; `local_owner/install_key.rs`). A step with `connection: user` runs on a second connection that
sends `client-hello {role: main, install_id}` and answers the nonce with the install-key proof (step 2,
`server/client_hello.rs` prove), so it derives origin user; the default connection stays agent. The success cases of
credential.rotate, history.backups.purge, history.trail.record, history.visit.import (a History.sqlite visit log under
`$CASE_ROOT` first), history.visit.record, history.visit.title and history.restore (record a visit, remove it, restore the
removal's restore_id) lose their gaps, and so does workspace.agent_folder.set's (064, a user-only operation). Acceptance:
the 8 cases pass; a wrong proof leaves the connection agent (selftest). Test: VM, the 8 cases green twice; `gen_daemon_ops.py --check`.

**238 Driver loopback pairing.** Files: `driver_daemon.py`, `hermetic_env.py`, `case-v1.schema.json`, `misc/_tuning.json`.
The case daemon's WebSocket listener binds 127.0.0.1:0 (still offline); a `pairing.open` step connects as an unpaired peer
(`server/websocket_listener.rs` begin_pairing) and waits until the facet lists the pairing request; the
pairing_request.resolve success case rejects it by a `$step:` reference. Test: VM, the case green twice, no pairing left.

**239 Chromium daemon-op cases on the app product.** Files: `driver_app.py`, `browser/_tuning.json`, `tab/_tuning.json`.
Depends on 067 (the tab tuning). driver_app.py runs a
`requires: chromium` case's resource.call steps on the app's own daemon, whose browser host is the cmux-browser provider,
in place of handing them to driver_daemon.py (a daemon with no provider answers engine_unavailable). The 10 chromium
success cases lose their gaps: the 9 engine ops (browser.activate/back/forward/reload/navigate,
browser.input.key/text/mouse/wheel) and tab.create_browser (a daemon-rendered browser tab in the fixture pane); mouse and
wheel also need a presented frame token from a stream step (204). Test: fleet, the 10 cases green twice.

**240 Driver: errorDetails, mock agent, chief connections.** Files: `driver_daemon.py`, `mock_chief.py`,
`chief/_tuning.json`. (1) A resource.call step's `expect.errorDetails` is checked with
`case_checks.error_details_mismatch` against the typed error's `details` (the SDK `ResourceError.details`); a
mismatch fails the step with the pointer. No driver on the branch checks it before this task. (2) A case with
`fixture.agent: mock` runs `mock_chief.MockAgent(<case run dir>)`: `start()` before the daemon (its environment
joins the case env: `CMUX_TUI_CHIEF_TOOLS_SOCKET`), `ready(command)` once the daemon answers (the mock
conversation, a v1 `conversation-create`), `close()` at teardown, inside the I6 proof. (3) A step with
`connection: agent` runs on a second connection bound to the mock conversation's agent participant
(`conversation-agent-token`, `conversation-bind`), so conversation.draft's success case loses its gap. (4) With
237's `connection: user` (the verified-app actor), agent.message.unsend's success takes back the fixture message,
and agent.message.release's success approves a held delivery made by a `cmux agent message send` that the
fixture terminal runs into another workspace (a terminal actor, cross_workspace hold). Acceptance: the 48 chief
cases green twice with no Skip line left for the chief family; a wrong errorDetails value fails its case
(negative control). Test: VM, the chief family twice; `gen_daemon_ops.py --check`.

**241 Typed refusals the chief family found.** agent.report of an unknown terminal answers operation.failed with
`operation: resource.runtime` and the reason `unknown terminal <id>` (an anyhow context, agent_reports.rs), while
agent.message.send answers `resource.not_found {scope: terminal, id}` for the same id. room.create with an empty
name answers validation.invalid with only a prose reason, and room.delete of the default room operation.failed
`resource.runtime` with a prose reason. Change: agent.report answers resource.not_found {scope: terminal, id} (the
catalog gains the code); room.create's refusal names `field: name`; room.delete's names `operation: room.delete`
and a reason token (`default_room`). chief/_tuning.json then asserts those keys. Test: the cmux-tui-core tests of
the three handlers; VM, the three error cases.

**242 normalize.py snapshot-v1 keywords.** `normalize.py --lint-schema --schema schemas/oracle/snapshot-v1.schema.json`
refuses x-oracle-decimal, x-oracle-open-keys, x-oracle-id-unpatterned and the list form of x-oracle-id-kind, which
snapshot-v1 uses, so every daemon case fails at canonicalization. Change: implement them (the schema's $comment
says what each means). Test: `normalize.py --lint-schema` clean on snapshot-v1; `normalize.py --selftest`.

**243 Driver builds fixture.repo.** Files: `driver_daemon.py`, `hermetic_env.py`, `oracle.py`, `gen_daemon_ops.py`,
`git/_tuning.json`. Before the first step of a case with `fixture.repo`, driver_daemon.py runs `make_repo.build_for_case`
for `tests/oracle/fixtures/git/<repo>.json` under the case root, with HOME the case's own folder (git_ops/worktree.rs writes
`~/.cmux/worktrees`), and expands `$CASE_ROOT` in step params. The daemon product then offers `git_repo` (oracle.py
PRODUCTS) and REPO_GAP goes away, so the 8 git operations are covered. Test: VM, the 18 git family cases green twice;
`gen_daemon_ops.py --check`.

**244 A case folder the project store takes.** Files: `hermetic_env.py`, `make_repo.py`, `git/_tuning.json`. Every case
root is under /tmp and state/projects.rs refuses every path under /tmp, /var/folders and the home folder, so project.add's
success cannot run. Give a case with a generated repository a checkout outside those roots (a per-run folder the
hermetic environment owns and removes), and project.add's success loses its gap. Test: VM, project.add green twice; no
folder left after the run.

The browser, browserProfile and devtools action cases (072) open their fixture page from 222's loopback server
(openBrowser and `cmux browser navigate` refuse data: URLs), which driver_app.py starts for a case with `fixture.web`
(225's fixer; 072 had planned it as a follow-up). Their success paths that need a fixture no planned task made name
these four follow-ups.

**360 Loopback TLS page.** Files: `webfixture.py`, `tests/oracle/fixtures/web/`, `browser/_tuning.json`. An https
listener on 127.0.0.1 with a per-run self-signed certificate the engines do not trust (352's https origin, which the
live cases share), so a load shows the engine's certificate warning (Chromium's `net/test/embedded_test_server`
`CERT_EXPIRED` server). The success cases of browser.certificateWarning.goBack, browser.pageInfo.certificate (a real
chain) and browser.pageInfo.reenableCertificateWarnings (after a person-path proceed) lose their gap_success. Test:
fleet, the three cases green twice on both engines.

**361 Oracle test extension.** Files: `driver_app.py`, `tests/oracle/fixtures/extensions/oracle/`, `browser/_tuning.json`.
loadUnpacked is person-only, so before launch the driver installs an unpacked MV3 extension named oracle (an action, a
command, an options page) into the tag's hermetic Chromium profile the way the profile's extension store reads it
(BrowserExtensionStore), as Chromium's browser tests load one with `--load-extension`. The success cases of the ten
browser.extension.* actions lose their gap_success. Test: fleet, the ten cases green twice on chromium.

**248 Loopback permission-asking page.** Files: `tests/oracle/fixtures/web/`, `browser/_tuning.json`. A page on 222's
origin that asks for the notifications permission on load, so a prompt is pending; browser.prompt.allow and
browser.prompt.block run their success path on it. Test: fleet, both cases green twice on both engines.

**249 Loopback Web Store stand-in.** Files: `BrowserExtensionInfo.swift`, `driver_app.py`, `tests/oracle/fixtures/web/`,
`browser/_tuning.json`. browser.extensions.webStore opens the remote Chrome Web Store, which no oracle case may load. A
DEBUG and bench-hooks launch value replaces `URL.browserExtensionWebStore` for the run (injected at launch, never read
in a Release build); driver_app.py sets it to `$WEB/webstore.html`. The action loses its gap. Test: fleet, the case
green twice; a Release build still opens chromewebstore.google.com.

**245 The holder exits at shutdown end_terminals.** Files: `cmux-holder/src/holder.rs`, `holder_runtime.rs`,
`mux/terminal_reap.rs`, `terminal/_tuning.json`. On the holder arm (CMUX_TUI_TERMINAL_HOST_MODEL=holder),
`shutdown-daemon end_terminals` ends every terminal but leaves the holder running until its idle exit (IDLE_EXIT, 30 s):
the holder model has no frame that ends the holder, so driver_daemon.py's I6 teardown (10 s) reports it left behind on
every holder-arm case. Change: when the daemon ends its last holder terminal for shutdown, it tells the holder to exit
(or the holder exits when its owner leaves and it holds no terminal), and the daemon waits for that exit before it
answers. terminal/_tuning.json then drops its `expectations` entry (the 18 `[ new ] ... [ Failure ]` lines). Test: the
cmux-holder and holder_runtime tests of the exit; VM, the 18 terminal cases green twice on the holder arm with the stock
driver.

**246 Facet: a terminal's view scroll offset.** Files: `oracle_state.rs`, `snapshot-v1.schema.json`, `terminal/_tuning.json`.
terminal.viewport.scroll moves only the compatibility view's anchor (Surface::view_scroll_delta), which no read and no
facet field returns: terminal.copy and terminal.screen.read read the terminal's own viewport. Change: the daemon facet
reports each terminal's view scrollbar {offset, total, len} (Surface::view_scrollbar), and the scroll success case
settles on offset = total - len - 5 after the call; its gap goes away. Test: VM, the scroll success case green twice on
both holder arms, and red when the handler scrolls 0 rows or the other way (negative control).

**247 Driver: a call that ends the daemon, expect.result references.** Files: `driver_daemon.py`,
`driver_daemon_test.py`, `case_values.py`, `case_checks.py`, `case-v1.schema.json`, `case-v1-mutations.json`. Found by
063 (session.shutdown and the graceful restart). (1) case-v1 step `ends: daemon` (a mutating resource.call only):
after an ok reply the runner waits for the daemon's exit in that step, records it as the step's exit and checks it
against allow_crashes (I17), and fails the step unless the exit is a normal termination (exit 0;
`base/process/kill.h` TERMINATION_STATUS_NORMAL_TERMINATION). A later restart finds no running daemon, so it starts
one and never sends shutdown-daemon to a daemon that is exiting; case_checks.py counts the step as one that ends a
daemon. (2) `expect.result` resolves its `$step:` references before the comparison (case-v1 stepRef: the runner
substitutes it), so `"$step:<id>#"` holds a reply equal to an earlier one, compared with JSON types (a bool never
equals a number). (3) `expect.resultExcept`: JSON pointers, `*` for every item or member, removed from both values
first (case_values.without_pointers), for what a new daemon generation changes. Implemented with 063's fixer, which
needs all three: without (1) session-shutdown-ok races the exiting daemon at the restart (a Crash). Test:
driver_daemon_test.py (ExpectTests, without_pointers; live: a call that ends the daemon owns its exit, three runs,
and one outside allow_crashes is a Crash at the call); case_checks.py --selftest (ends and resultExcept vectors);
VM, the 22 session cases green twice.

**248 Case daemon with installed first-party apps.** Files: `hermetic_env.py`, `driver_daemon.py`,
`workspace/_tuning.json`. The case daemon finds first-party packages in the app bundle, else in `apps/first-party` beside
its binary (first_party_dir.rs resolve), and the oracle build has neither, so no app is installed and
workspace.ensure_app's success cannot run. Stage each `first-party-apps/<name>` package (its manifest, `dist/`, `assets/`
and `catalog/`, as sync-app-runtime.sh copies them) under the case root and start the daemon with
`CMUX_APPS_FIRST_PARTY_DIR` naming that folder (the oracle profile has debug assertions, so a standalone daemon takes it);
the default set then installs cmux/notes and workspace.ensure_app's success loses its gap. Test: VM, the two
workspace.ensure_app cases green twice; no staged folder left after the run.

The sidebar and workspaceGroup action cases (075, `tests/oracle/corpus/actions/sidebar/_tuning.json`) make a group of
the shown workspace before each group action, since no case can name a group, section or item. Two follow-ups close
what the cases cannot check yet.

**270 Action cases: sidebar, item and group targets.** Files: `case-v1.schema.json`, `driver_app.py`,
`driver_app_test.py`, `gen_actions.py`, `tests/oracle/corpus/actions/sidebar/_tuning.json`. case-v1 `target` has no
`workspaceGroup`, `sidebarSection` or `sidebarItem` kind, so action.run cannot name `sidebar-section:sec_top`,
`sidebar-item:itm_home` or a group (ActionTargetKind's CLI prefixes), and gen_actions.py takes no tuned target. Add
the three kinds (a fixed id, or a `$step:` value such as make-group's created group), map them in
`driver_app.action_target` to `workspace-group:`, `sidebar-section:` and `sidebar-item:`, and add `target` to the
generator's tuning keys. The 13 section and 3 item cases that now expect the noSuchSection or noSuchItem
refusal, and the 5 toggles blocked below, run their success path on `sec_top` and `itm_home`
(sidebar.chat.togglePin also needs a history chat, 274), and workspaceGroup.collapseOthers folds a second group.
workspaceGroup.moveToWindow (blocked `live-value`) takes its window from a newWindow setup step's created window as a
`$step:` value. build_case adds a restore that runs a
TOGGLES action again, also after an action step that expects an error, so a refused toggle would fail at restore-1.
Until 270, sidebar.section.toggleTitle, toggleSpaceScope, toggleCollapsed, sidebar.item.toggleLabel and toggleArchive
are blocked `live-value`: their tuning's `params.target` holds `<fixture sidebar-section:sec_top>` or `<fixture
sidebar-item:itm_home>`. 270 moves that value to the action step's target, which unblocks them as success cases, and
gen_actions.py writes no restore after an action step that expects an error (nothing changed to put back). Test:
gen_actions.py --selftest (an error case has no restore step); driver_app_test.py (the kinds reach action.run's
target); fleet, those cases green twice.

**271 Facet: a workspace group's color, icon and archived mark.** Files: `SidebarSnapshot.swift`,
`snapshot-v1.schema.json`, `OracleSidebarFacetTests.swift`, `tests/oracle/corpus/actions/sidebar/_tuning.json`. The
sidebar facet's group row has no color, icon or archived field, so workspaceGroup.setColor, clearColor, the nine
color.* actions, setIcon, clearIcon and toggleArchive change nothing a case can wait on. Add `color` (the GroupTint
wire token or null), `icon` (null, or `set`: an icon is user text) and `archived` to the row from SidebarModel's
public values, as 036 reads the rest; the 14 cases gain a waitFor on the group row. Test: OracleSidebarFacetTests;
fleet, the 14 cases green twice.

**272 Facet: the top band's items.** Files: `SidebarSnapshot.swift`, `snapshot-v1.schema.json`,
`OracleSidebarFacetTests.swift`, `tests/oracle/corpus/actions/sidebar/_tuning.json`. SidebarDocListing.arrange draws
each section before (and after) the machine lists as a block of items with no `.item` node, so the facet writes one
row for sec_top and none for Home or an added item: sidebar.home.add, sidebar.home.remove and sidebar.item.add change
no row, and their cases have no waitFor. Add one `item` row per item of those sections (its ref kind, label from the
item or its app, as the row draws it), under the section row; the three cases gain a `changed` waitFor on
`/sidebar/rows`. Test: OracleSidebarFacetTests (Home under sec_top, gone after its remove); fleet, the three cases
green twice.

**273 Pin Chat with no target refuses.** Files: `SidebarChatHistoryFeed.swift`, `SidebarChatPinBindingTests.swift`,
`tests/oracle/corpus/actions/sidebar/_tuning.json`. SidebarChatHistoryFeed.bind returns with no sidebar-item target
(or no history), so `sidebar.chat.togglePin` answers ok for nothing done, which ActionRegistry+Unavailable's "no
handler is a silent no-op" forbids; the section and item actions refuse with noSuchItem. Throw an ActionFailure with
the noSuchItem string, as SidebarSectionResolve.item does (Chrome: ExecuteCommandWithDisposition returns false for a
command it did not run, chrome/browser/ui/browser_command_controller.cc). The case's tuning (divergence
chat-pin-silent-no-target) turns to `error: control.unavailable`; it is a toggle, so it needs 270's rule of no restore
after an error step. Test: SidebarChatPinBindingTests (no target: the run is refused, no pin changes); fleet, the
case green twice.

**274 Gap fixtures: a chat in the sweep's acpmux, the Priority view per sample.** Files: `every-action-sweep.py`,
`oracle/action_fixtures/__init__.py`, `oracle/action_fixtures/session_states.py`, `session_states_test.py`,
`tests/oracle/gap-closures/session.json`. 086 leaves sidebar.priority.markRead, snooze and togglePin open (session.json
`reasoned`, `follow_up`), and 270's sidebar.chat.togglePin case has no history chat. Both need a chat in the app's own
acpmux: a Priority row is a lane of AgentLaneStore.shared or .chief (AgentPriorityChats, filled by AgentTurnStateFeed's
`_acpmux/watch`), a history chat an entry of that daemon's chat index (SidebarChatHistoryFeed). The sweep launches
with `ACPMUX_AGENT_LAUNCH=deny`, so session/new refuses, and the mock agent's seeded chats live in the page's
in-memory daemon (`webviews/src/agent-session/acpmux/mock.ts`), which no app store reads. Launch the sweep's acpmux
with the perf corpus's replay agent as the only harness it may start (`agent_replay.py install` and `launch_env`:
`ACPMUX_AGENT_LAUNCH=only:replay`, its own `CMUX_NEXT_ACPMUX_ROOT` and `XDG_CONFIG_HOME`), and have an ArgumentFixture
for (sidebar.priority.*, `chat`) make one chat there per launch (session/new on `replay` in the sweep's scratch
folder, one replayed turn so the row is not idle) and name it `agent-chat:<session id>` once the Priority entries
list it; 270's history chat is that chat after its tab closes. The Priority row actions are unavailable while
`sidebar.priorityView.enabled` is off, its default, and each restore's restore_settings turns it off again; a family
has no per-sample settings step (PREPARE runs actions, an ArgumentFixture runs once per row). Add a family `SETTINGS`
table, {action id: {setting path: value}}, that the sweep sets through `settings.set` in ready() before describe and
that restore_settings takes back like any other change (load_families refuses an id two tables set). Chrome
reference: chrome/browser/ui/browser_commands_unittest.cc and chrome/test/base/testing_profile.cc make the profile
state a command needs inside the test (prefs through the test's PrefService) and drop it after. Test:
session_states_test.py (the fixture names the made chat, SETTINGS is set before each sample and back after it, the
plan runs the 3 ids); every-action-sweep.py --plan-only; fleet, `every-action-sweep.py --only` the 3 ids and
sidebar.chat.togglePin green twice.

The workspace, home and space action cases (076, `tests/oracle/corpus/actions/workspace/_tuning.json`) found four
divergences. Each case records today's answer and its note names the task below; the task changes the case's tuning
in the commit that fixes the behavior, so the fix does not read as a regression. No `Expectations.d/actions.txt`
line can list them yet: no actions case file is checked in until a live action-list.json lands (071), and
`expectations.py lint` reports a line for a missing case as `stale` (an error). Once one is checked in before its
task lands, the line is `<task> [ mac app ] actions/<case>/action [ Failure ]` (the action step's expect is not a
snapshot value, so no pointer scopes it).

**290 Open Conversation refuses an unknown id.** Files: `AppActions+HomeConversations.swift`,
`HomeOpenConversationRefusalTests.swift`, `workspace/_tuning.json`. home.openConversation passes any id to
`HomeDockView.open` or `TopHomePageView.open` and the run answers ok, though nothing opens. When the id names no
conversation of the Home list (HomeSidebarModel's rows and pinned), refuse with `registry.refuseNotFound` (the
socket answers `not_found`, ActionRegistry+Unavailable), as Chrome's tabs API rejects an unknown tab id
(chrome/browser/extensions/api/tabs/tabs_api.cc, `ExtensionTabUtil::GetTabById` failing with kTabNotFoundError).
The case's tuning turns to `error: control.not_found`. Test: HomeOpenConversationRefusalTests (an unknown id is
not_found and opens nothing; a listed id opens it); fleet, the case green twice.

**291 Select Conversation 1-9 is a focus action.** Files: `ActionCatalog+Focus.swift`,
`AppActions+HomeConversations.swift`, `HomeSelectConversationByNumberTests.swift`, `workspace/_tuning.json`.
home.nextConversation and home.previousConversation are in `ActionCatalog.focusActionIDs` and show Home from any
origin; their sibling home.selectConversationByNumber is not, so a socket run is refused with homeNeedsFocus where
the next and previous steps run. Add it to the focus set. With no conversation to pick (an empty list) the handler
returns without a word today; refuse with RefusalStrings.homeNotReady instead (no handler is a silent no-op). The
case's tuning expects that refusal for the fresh session (homeNotReady, not homeNeedsFocus) and gains an invariant
that Home shows. Chrome: Select Tab 1-8 runs from any caller of the command (chrome/browser/ui/browser_commands.cc
SelectNumberedTab). Test: HomeSelectConversationByNumberTests (a socket run shows Home and picks the nth; an empty
list refuses); fleet, the case green twice.

**292 No picker or ask for a socket run without an argument.** Files: `WorkspaceStructureHandlers.swift`,
`RoomHandlers.swift`, `ArgumentlessSocketRunRefusalTests.swift`, `workspace/_tuning.json`. workspace.setIcon and
space.setIcon open the icon picker when the run has no icon, whatever the origin, and space.rename asks for a name
in the palette (ActionRegistry.ask does not read the origin): a script's run puts a popover or the palette in front
of the person. When `ActionRunScope.viewChangeAllowed()` is false (a socket run without focus), throw
`ActionFailure.invalidTarget` with the argument-required string (RoomStrings.iconArgumentRequired, a new localized
name-required string for rename) instead; a person's run keeps the picker and the ask. Chrome's extension APIs
never show UI for a missing argument: the schema validation rejects the call
(extensions/renderer/bindings/api_signature.cc). The cases keep their argument (correct today); their `untested`
picker and ask lines drop "once p15-oracle-292 lands". Test: ArgumentlessSocketRunRefusalTests (socket origin, no argument:
refused, no picker or ask; palette origin: the picker or ask opens); fleet, the three cases green twice.

**293 TOGGLES matches whole words.** Files: `every-action-sweep.py`, `workspace/_tuning.json`. TOGGLES
(`pin`, `mute` anywhere in the id) takes space.color.pink for a pin toggle, so gen_actions.py adds a restore that
sets pink again. Match `pin` and `mute` as id words (the end of the id or a capital letter after them:
`togglePin`, `pinTab`, `muteConversation`), and check each id the change drops from the toggles against the catalog
so no real toggle loses its restore. The space.color.pink note loses its divergence. Test: every-action-sweep.py
`--plan-only` over a live catalog, the toggles before and after differ by the color actions only; gen_actions.py
`--check` after regeneration; fleet, the case green twice.

The terminal, find, focus, focusRing and pane action cases (080, `tests/oracle/corpus/actions/focus/_tuning.json`)
found two problems a tuning cannot fix. focusRight and focusDown carry a `known failure (p15-oracle-300)` note, and
focusRightSidebar is blocked (the tuning key `blocked`, kind `tuning` in coverage.json) until 301 lands.

**300 NEIGHBOR_STEPS start from the far pane.** Files: `gen_actions.py`, `focus/_tuning.json`. NEIGHBOR_STEPS
assume a split run through action.run focuses the new pane, but a socket run's split leaves focus in the launch's
pane (FocusEvent::changes_view refuses its Expect, `cmux-tui/crates/cmux-focus-core/src/event.rs`). So neighbor-2 of
focusRight (focusLeft) and of focusDown (focusUp) runs from a pane with no neighbor that way, PaneHandlers.bindFocus
refuses it (control.unavailable), and both cases fail in neighbor-2 on every run. Change NEIGHBOR_STEPS to left =
(splitRight, focusRight), right = (splitRight,), up = (splitDown, focusDown), down = (splitDown,): the moves are in
ActionCatalog.focusActionIDs, so a socket run of them moves focus. Fix the comment above NEIGHBOR_STEPS and the
selftest assertion in test_the_sweeps_setup_is_the_cases_setup (focus-right: splitRight, then the key
cmd+opt+right). In the focus tuning, remove the known-failure notes of focusRight and focusDown, and the
setup-start steps of focusLeft and focusUp (the neighbor steps now end in the far pane). Chrome:
chrome/browser/ui/browser_focus_uitest.cc focuses a known view before each focus-traversal check. Test:
gen_actions.py --selftest; `--check` after regeneration; fleet, focusLeft, focusRight, focusUp and focusDown green
twice.

**301 Right sidebar in the reset snapshot and the windows facet.** Files: `OracleWindowsFacet.swift`,
`OracleWindowsFacetTests.swift`, `snapshot-v1.schema.json`, `app_reset.py`, `app_reset_test.py`,
`focus/_tuning.json`. focusRightSidebar shows the right sidebar (RightSidebarHandlers: showRightSidebar, never a
hide), no restore step closes it, and the reset snapshot (app_reset.projection) has no key for it, so every later
case of the launch runs with a narrower content area (divergence right-sidebar-outlives-case). A relaunch does not
help: RightSidebarModel keeps its visibility and mode in defaults (rightSidebar.visible, rightSidebar.mode). Add
each window's right sidebar (`visible`, `mode`) to the windows facet from RightSidebarModel, and to the reset
snapshot. AppReset.reset puts it back with toggleRightSidebar (visibility) and the mode's
switchRightSidebarTo* action (mode), as it puts back the other keys. Chrome: base/test/test_suite.cc resets the
state a test may change between tests and CheckForLeakedGlobals fails the test that leaves it changed. Then the
focusRightSidebar tuning loses `blocked` and its divergence, and gains a waitFor on the facet's `visible`. Test:
OracleWindowsFacetTests (visible and mode follow the model); app_reset_test.py (an open sidebar in another mode is
put back to the fixture's); fleet, focusRightSidebar green twice and the cases after it in the same launch
unchanged.

The tab action cases (078, `tests/oracle/corpus/actions/tabs/_tuning.json`) state for every create what its turn must
already show (I3). Creates whose handler waits for the daemon before anything shows carry a `divergence` note naming
one of these follow-ups; invariants.py is not yet part of a run, so the cases stay green on their outcome and waitFor
checks until it is.

**320 I3 pairs a stand-in with the object that replaced it.** Files: `OracleIntentsFacet.swift`,
`snapshot-v1.schema.json`, `invariants.py`, `OracleIntentsFacetTests.swift`. An optimistic create shows a stand-in in
its turn (NewTerminalTabCommand.intendNow: a `pending_tab_` id, a provisional surface, no title or size; a page or
workspace stand-in the same way) and the daemon's tab takes its place at settle (ProvisionalTab.created, echoed). I3
compares raw ids, so it reports every optimistic create. The intents facet lists, per create intent of the window's
store, the stand-in id and the id that replaced it (the intent log's createdSurface, mapped to the tab); invariants.py
relabels the turn's stand-in ids by that list and leaves out, for those tabs only, the fields the daemon fills
(surface, title, columns, rows, git_branch). Chrome makes the WebContents with its final id in the same call
(TabStripModel::AddWebContents, chrome/browser/ui/tabs/tab_strip_model.cc), so it has no such pairing; cmux keeps the
stand-in because the daemon owns the id. Test: invariants.py --selftest (a stand-in replaced passes, a stand-in that
vanished or a field the stand-in claimed that changed fails); OracleIntentsFacetTests; fleet, newSurface, newTab and
newColumn green on I3.

**321 A positioned new tab is in its slot in its turn.** Files: `NewTabSlot.swift`, `NewTerminalTabCommand.swift`,
`Intent.swift`, `NewTabPositionSlotTests.swift`. NewTabSlot makes the tab at the end and moves it into its slot
(TabMoves.move) once the pane lists it; NewTabSuccession places it in the strip only, so the store's order, which the
topology and every client read, has it last in the turn. Give the create intent the index (the stand-in is inserted
there) and send it with new-tab, as Chrome inserts at the index in one call (TabStripModel::InsertWebContentsAt). Test:
NewTabPositionSlotTests (the stand-in is at its index in the turn); fleet, newTab.atStart, afterCurrent and toRight
green on I3.

**322 Tab group writes are store intents.** Files: `TabGroupHandlers.swift`, `TabGroupHandlers+Moves.swift`,
`Intent.swift`, `TabGroupIntentTests.swift`. TabGroupHandlers.run passes no intent except for collapse, so create,
addTab, removeTab, newTab, rename, setColor and color.*, ungroup, close and moveLeft/Right change nothing until the
daemon's echo. Add an intent per write, applied to the pane's tab groups in the turn and rolled back on a refusal
(the strip's resync stays the fallback), as Chrome's TabStripModel::AddToNewGroup, AddToExistingGroup,
RemoveFromGroup, MoveGroupTo and TabGroup::SetVisualData change the model at once. Test: TabGroupIntentTests (each
write shows in the turn; a refusal restores it); fleet, the tab group cases green on I3.

**323 Windows, workspaces and reopens show in their turn.** Files: `WindowManager+Creation.swift`,
`WindowManager+Incognito.swift`, `WorkspaceHandlers.swift`, `PaneController+Intents.swift`,
`DaemonClosedHistory.swift`, `TabGroupHandlers.swift`, `OptimisticCreateTests.swift`. newWindow and
newIncognitoWindow open their window after createWorkspace returns, newBrowserWorkspace creates in createAndShow's
unstructured Task, newTab.submit's `!` command skips the terminal stand-in (newTerminalTab's `typing`),
reopenClosedBrowserPanel, reopenClosedWorkspace and tabGroup.reopenSaved await the daemon. Open the window with a
workspace stand-in (as Cmd-N's startWorkspace does), give the typed terminal its stand-in and send the text after the
daemon's tab replaces it, and show a reopened item from the closed record in the turn. Chrome: chrome::NewEmptyWindow,
chrome::NewIncognitoWindow (chrome/browser/ui/browser_commands.cc), TabRestoreService::RestoreMostRecentEntry
(components/sessions/core/tab_restore_service_helper.cc). Test: OptimisticCreateTests; fleet, those cases green on
I3.

**324 Tab and group moves into new containers show in their turn.** Files: `TabMoves.swift`, `TabGroupMoves.swift`,
`TabGroupHandlers+Moves.swift`, `TabHandlers+More.swift`, `TabMoveIntentTests.swift`. TabMoves.toNewSplit,
toNewColumn, toNewDockColumn and toNewWorkspace and the group moves await the daemon (only TabMoves.toWorkspace is an
intent); TabGroupHandlers.moveToNewWorkspace runs in an untracked Task, so action.run answers before the move. Make
each a store intent with a provisional pane, column or workspace, as the splits are, and track the group move.
Chrome: TabStripModel::DetachWebContentsAtForInsertion then InsertDetachedTabAt, chrome::MoveTabsToNewWindow. Test:
TabMoveIntentTests; fleet, the move cases green on I3.

**325 Facets: tab and group icons, tab tint, saved tab groups.** Files: `ControlTopology+JSON.swift`,
`ControlTopologyMapper.swift`, `snapshot-v1.schema.json`, CmuxNextControlTests. The topology's tab and tab group have
no icon, a tab's own tint is in no facet and no facet lists the daemon's saved tab groups, so tab.setIcon,
tab.clearIcon, tab.setTint, tabGroup.setIcon, clearIcon, save and unsave are checked on their ok answer only. Add
`icon` (null, or `set`: an icon is user text) to both, the tab's own `tint`, and the saved groups (id, open group,
name); the cases gain a waitFor. Test: CmuxNextControlTests on the JSON; fleet, the seven cases green twice.

**326 A tab-group target and the groups a run made.** Files: `PublicIDTargetResolver.swift`,
`ControlRouter+ActionRun.swift`, `case-v1.schema.json`, `driver_app.py`, `driver_app_test.py`, the tabs tuning.
action.run's `created` lists no tab group or saved group, and case-v1 has no tab-group target kind (270 adds the
sidebar's), so tabGroup.addTab and tabGroup.reopenSaved are blocked `live-value` and the group actions act only on the
selected tab's group. List created tab groups and saved groups in `created`, add the `tabGroup` target kind
(`tab-group:`), and move the two cases' placeholders to `$step:` values. Test: driver_app_test.py; fleet, the two cases
green twice.

The layout action cases (077, `tests/oracle/corpus/actions/layout/_tuning.json`: screen, screenGroup, column,
layout, split, resize, swap and move) check structure on the layout facet (tree, ratios, column widths, docks, the
active screen, the focused and zoomed pane), tab moves on the topology facet's panes (they list terminal tabs; the
tabs facet lists only browser and page tabs, so a pane of terminals is not in it), workspace order on the sidebar rows
and the two layout settings on settings.nonDefaultKeys. A socket run without focus may not move focus
(FocusCoordinator.send refuses every changesView event), so a split or create in a case's setup leaves the launch's
pane focused; the cases pick a pane with focusPaneByNumber, a focus action. Three cases fail at a generated setup
step until 330, and the other four tasks are what the cases found. As for 076, the cases cannot be listed in
`Expectations.d/actions.txt` until a live action-list.json checks the case files in; each case's note names its task.

**330 Action cases: generated setup runs with focus.** Files: `gen_actions.py`, `layout/_tuning.json`. The sweep
runs its context, neighbor and PREPARE steps through `SweepDriver.run`, which is action.run with `focus: true`;
gen_actions.py `run_step` sends them without it. Without focus the neighbor split does not focus the new pane, so
swapPaneRight's neighbor-2 focusLeft and swapPaneDown's focusUp run from the leftmost or top pane and are refused
(refuseQuietly, control.unavailable), and column.moveRight's prepare-2 column.focusLeft the same. Give the generated
setup steps `args.focus: true` (case-v1's action.run `focus`, which 072 adds with driver_app.py) and nothing else:
the action under test keeps the caller's own permission. The cases' focus-pane-N steps keep working with either
setup, since they pick the pane by number. Test: gen_actions.py --selftest (a generated setup step has focus, the
action step does not); fleet, the three cases green twice.

**331 Facet: screen and screen group metadata.** Files: `ControlTopology+JSON.swift`, `ControlTopologyMapper.swift`,
`snapshot-v1.schema.json`, `OracleTopologyFacetTests.swift`, `layout/_tuning.json`. The topology facet's screen has
id, handle, name, zoomed pane and panes; its color, icon, pin and group are in no facet, and no facet lists a
workspace's screen groups. Add `color` (the wire token or null), `icon` (null, or `set`: an icon is user text),
`pinned` and `group` to the screen, and `screen_groups` (id, name, color, icon as for screens, collapsed, saved) to
the workspace, from the store's ScreenModel and ScreenGroupSnapshot, as the mapper reads the rest. The 14 screen
look cases and the 21 screen group cases without a waitFor gain one. Test: OracleTopologyFacetTests (a colored,
pinned, grouped screen and a collapsed saved group read back); fleet, those cases green twice.

**332 Screen creates answer with the screen.** Files: `ScreenCommands.swift`, `ScreenGroupCommands.swift`,
`ScreenCreateTrackingTests.swift`, `layout/_tuning.json`. `ScreenCommands.create` and `moveToNewWorkspace` start their
daemon request in an untracked `Task`, so action.run (and `cmux screen new`) answers before the screen exists and
`created` does not name it. Hand the work to the registry (`ctx.registry.track`, or the handler returns an
ActionEffect), so the run's scope waits for the reply and lists the screen, as Chrome's `chrome.tabs.create` answers
with the tab it made (chrome/browser/extensions/api/tabs/tabs_api.cc, TabsCreateFunction). screen.focus's case then
targets `$step:second-screen#/created/0` for its success path, and the setup steps' layout waits become plain
checks. Test: ScreenCreateTrackingTests (a socket screen.new answers with the new screen's id); fleet, screen.new,
screen.focus and screen.moveToWorkspace green twice.

**333 No silent no-op for column and workspace moves.** Files: `ColumnHandlers.swift`, `AppActions+Workspaces.swift`,
`AppActions+PersonalOrder.swift`, `SilentNoOpRefusalTests.swift`, `layout/_tuning.json`. On a screen that is still one
split tree, the column width presets, the width cycle and Center Column find no column for the implicit one
(`LayoutModel.setColumnWidth` returns without a word) and the run answers ok for nothing done; Move Workspace Up or
Down at the top or bottom returns the same way. Refuse with `refuseQuietly` and a localized reason (a key stays
quiet; the CLI and the palette get the reason), or, for the presets, apply the width to the lone column as newColumn
makes a strip. Chrome's Move Tab Left at the first tab is a no-op for the key but chrome.tabs.move with an index out
of range is an error (chrome/browser/extensions/api/tabs/tabs_api.cc). Test: SilentNoOpRefusalTests; fleet, the
column and moveWorkspace cases green twice, plus a refusal case for each.

**334 Reopen Saved Screen Group refuses an unknown id.** Files: `ScreenGroupHandlers.swift`,
`ScreenGroupReopenSavedTests.swift`, `layout/_tuning.json`. A saved id that names no saved group reaches the caller as
`daemon_error` (the daemon's refusal wrapped as failed work). Check the id against the store's saved groups first and
refuse with `refuseNotFound` (`not_found`), as 290 does for Home conversations. The case's tuning turns to
`error: control.not_found`. Test: ScreenGroupReopenSavedTests; fleet, the case green twice.

**206 I10 idempotent retry.** For each of the 201 `idempotency: required` ops, the generator adds a same-key retry step. Test: holds on all ops.

**204 Streams suite + I8.** Files: `gen_streams.py`, `invariants.py`, `tests/oracle/corpus/streams/`. Event log facet via
`cmux-tui/bindings/python/cmux/aio.py`; fold equals daemon facet; one case per connection_control op. Test: 19/19, I8 on 10,000 walks.

**205 restore_preview + I9.** Files: `journal_checkpoint.rs`, `oracle_state.rs`, `invariants.py`. Expose `restore_preview` under the
oracle feature as `oracle-restore-preview`, reading the journal reader path; one section-map table with reasons. Test: I9 on all ops and walks.

**211 api-compat cases.** Files: `cmux-tui/spec/api-compat-fixtures.json`, `scripts/cmux-next/oracle/gen_api_compat.py`, `tests/oracle/corpus/api-compat/`.
Change: extract the vectors in `cmux-api-compat/tests/api_compat.rs` into the (now empty) fixtures file, and have the Rust test read the
file, then generate one case per vector. Acceptance: Rust test and oracle read the same file. Test: green twice.

**071 gen_actions.py, 072-081 action families, 082-087 gap fixtures.** As in the draft, with these changes: real entrypoint per case;
gap fixtures live in `oracle/action_fixtures/<family>.py`; the gap tasks emit `tests/oracle/gap-closures/<family>.json` and task 087
applies all closures to `every-action-gaps.json` in one edit. Target: <= 20 gaps.

**209 MCP suite.** Files: `driver_mcp.py`, `gen_mcp.py`, `tests/oracle/corpus/mcp/`. `cmux mcp` over stdio, 606 offered actions + tools;
MCP vs CLI parity. **210 Entrypoint parity.** Files: `gen_entrypoints.py`, `tests/oracle/corpus/entrypoints/`. 986 actions, one case per
entrypoint, settled snapshots equal.

**222 Web fixture server.** Files: `webfixture.py`, `tests/oracle/fixtures/web/`. Loopback, per-case port, load/slow/404/500/beforeunload/
popup/download/chrome://crash link/long DOM; origin normalized to `$WEB`.

**088-090 Journeys.** As in the draft. 089 now covers tabs-and-browser, command-palette, agent-pane and a renderer-crash differential part only.

**223 Chromium failure journeys.** `chromium-renderer-crash` (chrome://crash), `chromium-gpu-crash` (chrome://gpucrash),
`chromium-renderer-hang` (chrome://hang, Expectations line until the CEF DevTools fix), `chromium-helper-kill` (SIGKILL the F2 host,
`[ old ] Skip`). Each asserts app pid unchanged, non-browser facets equal, error state with retry; `allow_crashes` declared.

**224 Holder crash journey.** Kill a VT worker (and `CMUX_TUI_TEST_HOST_ABORT_ONCE`) mid-output on both holder arms; vt-state hash,
size, title, cwd equal after restart; old arm expects the documented host-loss record.

**091 Tours** (23, waits become waitFor/settle). **092-097 e2e** (66 scripts in 6 batches of 11; each converted case fails on its cited
bug's parent). **225 live** (106 scripts, `scripts/cmux-next/oracle/live-map.json`, 8 batches of 13).

**Follow-ups of 225.** Every live script that 225 excludes names one of these tasks (or the suite's task that covers
it) in `gen_live.py` EXCLUSIONS, and `gen_live.py --check` refuses an exclusion without a WORK.tsv task (rule 6).
Each task moves its scripts from EXCLUSIONS to CONVERSIONS, regenerates `live-map.json`, and runs each new case
twice on the fleet (`driver_app.py run-case --repeat 2`).

**350 Pointer step.** Files: `case-v1.schema.json`, `driver_app.py`, `gen_live.py`. A `pointer` step (move, click,
right-click, double-click, drag with its points in a window's or a facet row's coordinates) sent through
`debug.mouse`, as Kombucha's MoveMouseTo, ClickMouse and DragMouseTo verbs (ui/views/interaction/
interactive_views_test.h); an open context menu's rows in the overlays facet. Converts agent-pane-menu,
cef-native-ui, chromium-popups, clickthrough, devtools-resize, group-editor, hovercard-delay, omnibar-pointer,
sidebar-v2-drag, terminal-cmd-click, titlebar-double-click and the pointer halves of other cases.

**351 App restart step.** Files: `driver_app.py`, `gen_live.py`. case-v1 already has `restart` with `process: app`;
driver_app.py quits the app (TagTeardown keeps the state root), relaunches it on the same root and records the exit
status for I17, as Chrome's PRE_ browser tests restart on the same user-data dir (content/public/test/test_launcher.cc).
Converts browser-post-replay, browser-restore, downloads-relaunch, quit-hidden-chromium, update-card-close,
updated-card-close and the relaunch halves of reopen-closed-history and sidebar-group-menu.

**352 Web fixture: https, basic auth, PDF.** Files: `webfixture.py`, `tests/oracle/fixtures/web/`. A second loopback
origin over TLS with a certificate made per run (net::EmbeddedTestServer's TYPE_HTTPS with CERT_EXPIRED and
CERT_MISMATCHED_NAME), an `/auth-basic` route (default_handlers.cc HandleAuthBasic) and an inline PDF route.
Converts browser-challenges and pdf, and the certificate interstitial check of error-pages.

**353 Scripts outside reach.** Files: `gen_live.py`, `live-map.json`. The network, host and evidence scripts (real
services such as the Chrome Web Store, the staging Cloud API and Google Chrome over CDP; macOS services; captures)
each get a loopback stand-in case where one can hold its check, or a written retirement agreed with the script's
owner (OWNERS.md) that keeps it a manual live check outside the oracle.

**354 Chief over mock_chief.py.** Files: `driver_app.py`, `mock_chief.py`, `gen_live.py`. `fixture.agent: chief`
starts the app's Chief owner, Home and the ACP agent pane over mock_chief.py and the fake ACP agent (scripted
replies, no model, no login), as 240 does for the daemon. Converts the chief-*, home-* and html-file-menu scripts
that need a brain but not a real model.

**355 Per-case launch.** Files: `case-v1.schema.json`, `hermetic_env.py`, `driver_app.py`, `gen_live.py`.
`fixture.launch` names a launch variant from a closed list (the recording build env for external opens, extra CEF
switches, a browser-import home, a tunables file, a seeded state root, a copied bundle); hermetic_env.py builds it and
the bench launch applies it, as Chrome's browser tests set their command line in SetUpCommandLine. Converts the
launch scripts.

**356 Facets for debug.* reads.** Files: `snapshot-v1.schema.json`, the CmuxNextOracle and App/Oracle providers.
Each read the no-facet scripts make through a debug.* method (downloads, permission prompts, omnibar suggestion rows,
hover cards, toolbar and pane chrome buttons, OSC 7501 program status, the agent cursor, window layers) becomes a
model value of a facet, with no view frames (rule 7). Converts the no-facet scripts.

**357 Local schemes.** Files: `case-v1.schema.json`, `case-v1-mutations.json`, `gen_live.py`. noRemoteUrl takes
`chrome://` internal pages and `cmux://` pages as local, as it already takes Chromium's debug URLs. Converts
chrome-internal-pages and page-swap-visible.

**098 Walks + ddmin, 099 at scale (100,000 seeds per daemon switch, both arms).** **207 Crash walks** (`crash_walks.py`): SIGKILL at
random steps, restart on the same root, state equals last acknowledged sequence. **208 Upgrades** (`gen_upgrades.py`,
`tests/oracle/fixtures/state-roots/` generated tarballs): last 5 tags, open with head; head-written root opened by the previous tag refuses
with the store_schemas error and files unchanged.

**100 TLA traces** (`gen_tla.py`, `plans/cmux-next/formal/oracle-actionmap.json`): TLC simulate on LayoutRows, TabLayout, closefocus,
OwnershipConvergence; >= 200 traces each. **101 VT corpus** (`schemas/terminal-corpus/generate.py`): >= 200 cases on both holder arms.
**234 TUI suite** (`driver_tui.py`): PTY-driven TUI, all inventory actions.

**212 Config parity.** Files: `gen_config.py`, `OracleConfigDump/main.swift`, `cmux-tui/crates/cmux-config/examples/oracle_effective.rs`.
>= 2,000 files from settings-schema examples, retired keys and seeded JSONC mutations; plus keybinding vectors. Executables only.

**213 Pane-protocol vectors.** Files: `tests/oracle/corpus/pane-protocol/`, `gen_pane_protocol.py`, `webviews/scripts/pane-protocol-conformance.ts`,
`cmux-tui/crates/cmux-pane-protocol/examples/conformance.rs`, Swift runner in the Linux tier or fleet. Same files read by all three.

**102 InputModel part 1.** First `git mv` `TerminalAttachMachine.swift` and `+Types.swift` from Bridge into CmuxNextInputModel (they import
only Foundation and CmuxNextDaemon); then move InputObservation, InputInvariants, InputJournalEntry values. `InputJournal` (singleton +
AppKit) stays in the App. Pure move with access edits. **103 part 2.** Move InputReplay and AttachOracle; replay takes entries as values.
debug.replay output identical. **104 oracle-replay** (500 journals < 60 s). **105 oracle-input-walk** (executable; 1,000,000 steps).

### Invariants, modes, quality

**110 invariants.py I1-I7.** **217 I11-I15** from `debug.blocking`, `debug.hangs`, `debug.action_budget`, `debug.wakeups`, daemon fd/thread/child
counts; failures to the perf owner queue. **236 I16** panic log and lock rank (oracle profile).

**111 diff --switch**, **112 diff --base/--head**, **202 overlay** (`overlay.py`: additive oracle file set applied with `git apply --3way`;
else v0 facets; missing facets `not-comparable`), **183 launch-config + bisect-switches**, **184 confirm** (`confirm.py`), **009 select + bisect**
(`select_suites.py`, `bisect_case.py`: not `select.py`/`bisect.py`, which shadow stdlib modules; `tests/oracle/suite-map.json`), **113 engine parity**, **114 platform parity**, **235 Windows parity (stretch)**.

**115 selftest --mutants** over the 026 patches; fails below 19/20. **191 cargo-mutants** (`mutants.sh`, `cmux-tui/.cargo/mutants.toml`):
test command `oracle.py run --product daemon --suite daemon-ops,walks --jobs 200`; JSON survivors queue. **190 coverage** (`coverage.py`):
`-C instrument-coverage` daemon and `--enable-code-coverage` Swift tier; absolute and incremental per file; a report, not a gate.

**116 report.py**, **117 flake detection** (pairs with value samples; fix at source or a reasoned rule), **118 route.py** (confirmed only; OWNERS
most-specific row).

**185 Daemon virtual clock + seeded ids + stable order.** Files: `cmux-tui/crates/cmux-tui-core/src/oracle_env.rs`, `switches.rs`,
`conversation_store.rs`, `state/workspace_checklist_store.rs`, `git_ops/checkpoint/store.rs`. `OracleEnv { wall, ids }` carried by the Switches
value; virtual epoch and `oracle-advance-clock {ms}` with `CMUX_TUI_ORACLE_SEED` under the oracle feature; seeded ChaCha ids; tie-break by id
in time-sorted lists. Acceptance: passed by argument; production path unchanged. Test: same seed gives byte-equal raw facet across 2 processes.

**220 Parser fuzzers** (`cmux-tui/fuzz/` own workspace; targets control_request, resource_params, journal_record, pane_frame, api_compat;
`scripts/cmux-next/linux/fuzz.sh`). **186 Resource-op sequence fuzzer** (`fuzz_targets/resource_ops.rs`, `fuzz_to_case.py`): `arbitrary` over typed
ops, real dispatch, invariants as crash conditions, `-fork=300`; crashes become walk cases. Acceptance: `cmux-tui/Cargo.lock` unchanged.

**187 Sanitizers.** Files: `linux_run.sh`, `swift-tier.sh`, `expectations.py`, `tests/oracle/SanitizerExpectations.d/`. ASan+LSan and TSan for
cmux-tui (nightly, `-Zbuild-std`, separate target dir) over daemon suites and 10,000 walks; `swift test --sanitize` on the tier; reports become
Crash results with a stack key. **219 Miri** (`scripts/cmux-next/linux/miri.sh`) on cmux-layout-reducer-ffi, cmux-palette-ranker,
cmux-layout-reducer and pure cmux-rd-ffi parts; each `cfg_attr(miri, ignore)` has a reason. **221 Rust tests** (`rust-tests.sh`): nextest
`-j 300 --retries 0` three times, flake list. **214 Webview tests** (`webviews-tests.sh`): bun test sharded, 3 repeats, flake list.

**233 Motion arm.** Files: `oracle/action_fixtures/__init__.py`, `plans/cmux-next/refactor-switches/motion-on.json`. Motion-off default, motion-on
virtual suite; arm read back from the settings facet.

### Linux tier source tasks (MQ-linux-errors and MQ-linux-imports)

Unchanged from the draft unless noted. Each: Darwin path unchanged; fleet compile-check; VM target builds and its tests pass.

- **120** Compat Platform: Libc, Logger shim, Mutex. **121** Compat AppKit/QuartzCore files to CmuxNextCompatAppKit (in the 119 commit).
- **122** Compat Threading on Linux (MachO/XPC parts as `canImport` whole files). **123** Compat misc (MacName, OpenFileLimit, ChildSignalDefaults, ObservationStream).
- **124** Signposts no-op OSSignposter, MetricKit mirror `canImport`. **125** Wakeups display files to CmuxNextWakeupsDisplay (display-link seam first, then the moves in its own commit, section H; tell Performance Lead and PL-typing).
- **126** PlatformEvents, FolderChanges (inotify), UnixSocketPeer (SO_PEERCRED), ProcessUsage (/proc); no polling added.
- **127** Actions `KeyModifiers` value type; action-surfaces export byte-identical. **128** Actions menus/recorder to CmuxNextActionsAppKit (menu seam first, then the moves in its own commit, section H).
- **129** Daemon transport (MSG_NOSIGNAL, Logger, PlatformEvents). **130** Daemon crypto, `InstallKeyStoring` (0600 file on Linux, injected), CZlib inflate.
- **131 (revised)** DesignTokens: replace `import CoreGraphics` with `import Foundation` in geometry-only files (rg queue); remaining CG API in one
  `CmuxNextCompat/Platform` file. Acceptance: 0 `canImport(CoreGraphics)` in DesignTokens.
- **132** Leaf targets (Focus, TerminalGeometry, CopyMode, TerminalFind, ProcessEnvironment, HostPressure with /proc/meminfo + PSI, WorkspaceRepair).
- **133** Settings AppKit files out behind protocols (the protocols first, then the file moves in its own commit, section H). **134** Settings off Design and Icons: Settings->Design and Settings->Icons
  edges gone in ci-target-graph.json. **231** MQ-settings-design queue (Motion and Theme value families to DesignTokens; tell the motion-gate owner).
- **135** Control socket server (PeerCredentials, /proc ancestry, inotify); authorization unchanged; high-risk note in the PR.
- **136** Control diagnostics (watchdogs, stack sampler) to CmuxNextControlDiagnostics (the watchdog protocol first, then the moves in its own commit, section H).
- **137** ErrorJournal, HangReports, VSCodeServer. **138** Files (FileKind seam), RemoteFetch (FoundationNetworking for URLSession), ChromiumRuntime.
- **139** BrowserImport, ImportSuggestions (Crypto, system sqlite, CZlib; Keychain cookie decrypt macOS-only).
- **140** BrowserCore (3 AppKit files to CmuxNextBrowser; tell PL-engine). **141** Cloud, CodeRouter, Remote, Devices (`SecretStore`, `UserPresence` injected).
- **142** Mobile, Hibernation. **143** AppKit/UI-importing test files to *AppKitTests (count of `@Test` on macOS equal before and after; CmuxNextCompatAppKitTests landed in 119, the Actions, Control and Settings moves follow 128, 136 and 133).
- **227** Bridge off UI edges (ResizeCoordinator to a UI target; Layout/Sidebar/Tabs/Icons uses replaced); unblocks WorkspaceNaming (51 tests).
- **226** Wave 3 UI-free targets; tier-imports.py lists each as in-tier or names its blocking edge.

### Shared packages on Linux (MQ-shared-packages)

**144** CmuxHomeCore (222) + CmuxAPIClient. **145** CmuxIrohTransport (~663). **146** CmuxIrxTransport (~246). **147** CmuxMobileRPC, CmuxMobileSSH,
CmuxMobileTunnel (223 + 79 + 17). **148** CmuxAuthRuntime (~314; Keychain seam). **149** CmuxVNC, CmuxPhonePush (41 + 13). **150** CmuxAgentBrands,
CmuxAgentCursor (split UI files). Each: macOS/iOS manifests unchanged without the env var; VM `swift-shared.sh` passes. HomeRender, AppAttest and
Updater are excluded (QuartzCore/CoreText, DeviceCheck, Sparkle). **151** tier-report.py: numbers from receipts only.

### Headless (stretch) and hygiene

**160** CmuxNextHeadless (HeadlessServices composition root; serves snapshot.get, action.run, debug.oracle.snapshot; Linux and macOS).
**161** driver_headless.py + product parity. **162** headless-handlers.py queue (114 of 191). **163** first batch of zero-dependency handlers,
proved by `diff --base --head` on actions with 0 divergences.
**170** `skills/cmux-testing/references/oracle.md` + one SKILL.md row. **171** `switches --expired` one line per switch.
**172** guardrails.py warning (never refuses) for an unregistered switch name.
