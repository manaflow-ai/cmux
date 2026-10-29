# p12-perf-process: the cmux perf lab (chromeperf, Pinpoint and Finch for cmux-next)

Status: final spec after 3 reviews (fixer pass, 2026-10-25). Checkout read: `/Users/lawrence/fun/wt/chrome-parity` at `772cdfc45ac` (origin/feat-cmux-next).

This program gives cmux-next a Chrome-style perf regression process:

- a dedicated bench Mac pool (the "perf lab", the analog of chrome.perf)
- Release-optimized bench builds of every merge batch of the big branch
- a recorded-session corpus (system_health stories plus Web Page Replay)
- change-point alerts
- automatic Pinpoint-style bisect with culprit verification
- A/B try jobs for agents
- an agent perf-sheriff loop with SLOs
- Release-capable feature flags with signed remote overrides and safe mode (F9)

Everything runs on the fleet through the controller job system. Nothing in this program is a CI gate, a CI job, a CI step or a merge check. The program changes no file under `.github/workflows`.

## 0. What changed after review

Three reviews were applied. Each claim below was checked in the checkout or in catapult before it was accepted.

| Review claim | Check | Result |
| --- | --- | --- |
| The Pinpoint values in the compare.py comment are one-sided. The current code is two-sided. | catapult `mann_whitney_u.py` returns `2 * _NormSf(abs(z))` with `mean_rank = n1*n2/2 + 0.5`. A local recompute gives 0.00973 one-sided and 0.01945 two-sided for `[0]*20` vs `[0]*15+[1]*5`. | Accepted. The done check uses the current code's values (MWU 0.0195, KS 0.4973; MWU 0.9892, KS 0.0082). |
| SAME is not a fixed 0.10. | `thresholds.py`: `LowThreshold()` = 0.01. `HighThreshold(mode, magnitude, n)` comes from `_HIGH_THRESHOLDS_PERFORMANCE`, indexed by `int(m*10)-3` and `min(n, len)-1`. Row 1.0 IQR at n=10 is 0.5708. `compare.py` computes 2 verdicts. The "new" verdict uses floors (low `max(0.01, 0.05)`, high `max(HT, 0.10)`) and is returned when `benchmark_arguments` is set. Otherwise it is only logged as `BisectDebug`. | Accepted with a decision (see Rules R5). |
| Attempts grow 10 -> 160, speculation is 1 level. | `job_state.py`: `MIN_ATTEMPTS = 10`, `MAX_ATTEMPTS = 160`, doubling, `_DEFAULT_SPECULATION_LEVELS = 1`, `MAX_BUILDS = 60`. Magnitude = `abs(comparison_magnitude / max(IQR_a, IQR_b, 0.001))`. A mean change in the improvement direction is SAME. | Accepted. |
| find_change_points is E-Divisive, not MWU/KS bisection. | `clustering_change_detector.py`: energy statistic (alpha 2), `PermutationTest` with 199 iterations over a window of at most 20 points, `_MIN_SIGNIFICANCE = 0.95`, `ExtendChangePointRange` at 0.90 of the peak. | Accepted. Task 003 ports it. |
| `CMUX_NEXT_CEF_EXTRA_SWITCHES` is DEBUG-only. | `CEFSwitches.swift:167-168` reads it only under `#if DEBUG` and only for dev bundles. | Accepted (task 221). |
| The bench config always has `CMUX_BLOCKING_CHECKS`. | `reload.sh:1701` adds `-DCMUX_BENCH_HOOKS -DCMUX_BLOCKING_CHECKS`. | Accepted (task 147). |
| A signed remote flag document exists. | `release-notes/next/flags.json` (version 1). `nightly.yml:7277-7281` signs and publishes it as `notes/flags.json`, and the step asserts `version == 1`. `cmux-tui/crates/cmux-tui/src/feature_flags.rs` fetches, verifies and caches it (cohorts, `DisabledFeatures`). The app verifies the same content key through `ContentSignature` in `CmuxNextUpdater/ReleaseNotes/ReleaseNotesStore.swift`. The app does not read `flags.json` today. | Accepted. The design reuses this document and key, keeps `version: 1` (a version bump fails the nightly assertion and needs a workflow edit) and adds new keys. |
| SignpostName has 9 reserved cases, not 5. | The doc comment of `SignpostName.swift:8-11` lists 8 emitted cases. The corrected MQ5 query prints `motionFrame motionRun switchWorkspace switchTab switchPaneFocus createTab createWorkspace cefPump cefCreateBrowser`. | Accepted (tasks 080-083). |
| `SwitchFrameTimer` is in CmuxNextDesign and is debug-driven. | `Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Diagnostics/SwitchFrameTimer.swift`. Only CmuxNextActions, CmuxNextApp, CmuxNextFocusUI and CmuxNextWakeups import CmuxNextSignposts. | Accepted. Switch signposts are emitted from the action commit in CmuxNextApp. |
| The perf cron's first host is cmux20-bench. | `perf-cron.py:52 BENCH_WORKER = "cmux20-bench"`. The plan job sparse-checks out `scripts` (`cmux-next-perf-budgets.yml:209`). | Accepted. A sentinel file stops the cron without a workflow edit (task 026). |
| Wrong paths in 043, 093, 102-105. | Real paths: `Tests/CmuxNextHangReportsTests/HangReportWireFormatTests.swift`, `Sources/CmuxNextUpdater/UpdaterService.swift` (and `+ReleaseNotes`), `CmuxNextLayout/Views/DropOverlay/DropOverlayTunables.swift`, `CmuxNextSidebar/Logic/SidebarTunables.swift`, `CmuxNextBrowser/Hibernation/HibernationTunables.swift`, `CmuxNextApp/HostPressure/HostPressureTunables.swift`, `CmuxNextAgentPane/AgentPaneTunables.swift`, `cmux-tui-core/src/holder_runtime.rs:31` (`CMUX_TUI_TERMINAL_HOST_MODEL`). | Accepted. Corrected in the task table. |
| `handOffIfStale` is a daemon method. | It exists only in `CmuxNextAgentPane/AcpmuxChiefHandoff.swift` (acpmux). | Rejected as written. Task 150 uses the daemon's client hello (`cmux-tui-core/src/server/`, see `client_hello_tests.rs`) and reports a mismatch. It does not invent a handoff reason. |
| A refusing guardrail rule (107) is a CI gate. | guardrails.py is a pre-push and gate tool. A new refusing rule is a new gate. | Accepted. 107 is dropped. `gen-features.py --unmigrated` (MQ6) tracks the same debt. |
| Edits to `cmux-next-perf-budgets.yml` and `cmux-next-perf-bench.yml` are CI step changes. | CLAUDE.md: "Never add CI gates ... CI jobs or steps". | Accepted. No workflow edit. The cron and xbench check a sentinel file in their own scripts. |
| A main-turn histogram with log2 buckets cannot show a 10 % shift. | 2/4/8 ms edges put 3.9 and 4.1 ms in different buckets 2x apart. | Accepted (task 031 uses about 64 exponential buckets). |

Items dropped or merged, with the reason:

- 107 (refusing feature-flag guardrail): dropped. It is a new gate (CLAUDE.md, 2026-10-23 rule). MQ6 reports the same debt.
- 140 and M05 merged into 002. 141 merged into 003. 149 replaces the old 094. 156 replaces the old 031. M02 replaces the old 026 (no workflow edit).
- 201-207 (per-review migration slices) and the old 050-077 are re-cut into 050-069. Each bench file is in exactly one task, and that task does MQ1, MQ2, MQ3 and result-v1 for the file. Parallel implementers then never edit the same file.
- 142, 143 (shard map, pool roles) and the scheduler hooks of 023, 146 and 235 are merged into 011, so `scheduler.py` has one author.
- 144 (build every first-parent commit) merged into 234. 212 merged into 009. 213 merged into 146. 215 merged into 157. 216 merged into 007 (owner field) and 014 (routing). 224 merged into 152. 237 merged into 039. 240 merged into 106. M03 and 148 merged into 221. M04 merged into 235. M08 merged into 150. M09 is 147. M10 merged into 012. M01 is 160, M06 is 161, M07 is 162.
- 228 (WebKit arms) is split: the engine field goes into 001 and 004, the arms go into 034, 035 and 036, and 228 keeps only the catalog and target rows.
- 233 (host hygiene) is split: checks go into 006, setup into 130, the bench env list into 162.
- 222 is kept in a corrected form. It keeps `version: 1`, because `nightly.yml:7279` asserts `version == 1`, and new keys pass that assertion.
- 238 keeps only the docs. The guardrail message edit is dropped, because PL-guardrails owns guardrails.py.

## 1. Chrome reference (cited)

1. **Lab waterfall.** `docs/speed/perf_waterfall.md`: "For each commit to the Chromium repo, a Builder is invoked", with a set of builders per platform. Testers run continuously. Each run covers the commits since the previous run up to the latest built commit, sharded over devices. Each story is bound to a fixed device through generated shard maps (`tools/perf/core/shard_maps`, `generate_perf_sharding.py`). `tools/perf/core/bot_platforms.py` marks `pinpoint_only` platforms, so bisect devices are separate from waterfall devices. It also has `run_reference_build`, which runs a pinned reference build next to tip. Policy: "If you make a change that regresses measured performance, you will be required to fix it or revert". Hardware: `docs/speed/perf_lab_platforms.md`. Disabled stories: `tools/perf/expectations.config`.
2. **Lab and field.** `docs/speed/how_does_chrome_measure_performance.md`: "Chrome collects performance data both in the lab and from end users". Each speed domain (`docs/speed/speed_domains.md`) has lab and field metrics and a triage rotation. Perf trybots (`docs/speed/perf_trybots.md`) measure an unsubmitted CL. Field data comes from UMA histograms (`base/metrics/histogram_macros.h`; each histogram has an owner and an expiry, `tools/metrics/histograms/README.md`). Active variations are attached to every UMA log and crash (`components/variations/variations_crash_keys`).
3. **Anomaly detection.** catapult `dashboard/dashboard/find_change_points.py` calls `clustering_change_detector.ClusterAndFindSplit`. That is an approximation of E-Divisive: an energy statistic with squared distances, `ChangePointEstimator` over every split, `PermutationTest` with `_PERMUTATION_TESTING_ITERATIONS = 199` over at most `_MAX_SUBSAMPLING_LENGTH = 20` points, `_MIN_SIGNIFICANCE = 0.95`, and `ExtendChangePointRange` at `_CHANGE_RANGE_TOLERANCE = 0.90`. Then `_PassesThresholds` filters with the defaults in `dashboard/common/defaults.py`: `MAX_WINDOW_SIZE = 50`, `MIN_SEGMENT_SIZE = 6`, `MIN_ABSOLUTE_CHANGE = 0`, `MIN_RELATIVE_CHANGE = 0.1`, `MIN_STEPPINESS = 0.5`, `MULTIPLE_OF_STD_DEV = 2.5` (mirrored in `AnomalyConfig`, `protobuf/sheriff.proto`). Only series that a sheriff `Subscription` matches raise alerts. Alerts with overlapping ranges form a group.
4. **Pinpoint.** `docs/speed/bisects.md`. Model (`pinpoint/models/README.md`): Job -> Change -> Attempt -> Execution (Build Quest, then Test Quest). `job_state.py`: `MIN_ATTEMPTS = 10`, doubling to `MAX_ATTEMPTS = 160`, `MAX_BUILDS = 60`, `_DEFAULT_SPECULATION_LEVELS = 1` (the README's "two levels" is out of date). Magnitude = `|comparison_magnitude| / max(IQR_a, IQR_b, 0.001)`, default 1.0. A mean shift in the improvement direction is SAME. `compare/compare.py`: p = min(KS, MWU), because "MWU is bad at detecting changes in variance, and K-S is bad with discrete" distributions. Original verdict: DIFFERENT if p <= `LowThreshold()` = 0.01, UNKNOWN if p <= `HighThreshold(mode, magnitude, n)`, else SAME. "New" verdict: thresholds floored at `_MIN_LOW_THRESHOLDS_FUNCTIONAL = 0.05` and `_MIN_HIGH_THRESHOLDS_FUNCTIONAL = 0.10`, returned when `benchmark_arguments` is set, else logged as `BisectDebug`. `mann_whitney_u.py` uses the normal approximation, tie correction and a 0.5 continuity term in `mean_rank`, and is two-sided. The comment examples (MWU 0.0097, 0.4946) are one-sided. The current code returns 0.0195 and 0.9892. `thresholds.py` `_HIGH_THRESHOLDS_PERFORMANCE`: 38 rows (0.3 to 4.0 IQR). Pinpoint also has a functional mode (pass/fail rates), bisects into DEPS rolls, and keeps traces of each attempt (`docs/speed/addressing_performance_regressions.md`).
5. **Features and Finch.** `base/feature_list.h`: `BASE_FEATURE(kX, FEATURE_DISABLED_BY_DEFAULT)`. The override order is command line, then field trial, then default. "If a feature appears on both lists, then it will be disabled". `OVERRIDE_DISABLE_FEATURE` is the Finch kill switch. `base::FeatureParam` tunes numbers under a feature. FeatureList tracks early access (reads before the list is installed). Child processes get the state through shared memory. `testing/variations/README.md`: `fieldtrial_testing_config.json` is "the configuration most likely to launch", and perf bots run with it. Studies have min/max version, channel and platform filters, and the arm comes from a low-entropy source. `components/variations/service/safe_seed_manager`: `kCrashStreakSafeSeedThreshold = 3` (use the last known-good seed), `kCrashStreakNullSeedThreshold = 4` (no seed), fetch-failure streaks 25/50, and a successful fetch resets the streak.
6. **Hang detection.** `base/threading/hang_watcher.h`: `kDefaultHangWatchTime = base::Seconds(10)`. `WatchHangsInScope` arms per-thread deadlines on UI, IO, ThreadPool and compositor threads. A hang calls `DumpWithoutCrashing` (report, never kill). `content/browser/scheduler/responsiveness/calculator.h` measures queueing plus execution (`kQueueAndExecution`).
7. **Harness hygiene.** crossbench: probes, stories, `--repeat`, `--env-validation`, results as `cb.results.json` plus raw per-run data.

## 2. cmux today (checkout 772cdfc45ac)

- **Perf cron.** `scripts/cmux-next/perf-cron.py` (3196 lines) and `.github/workflows/cmux-next-perf-budgets.yml`. A tick every 20 minutes runs ONE of 10 parts (build, stress, motion, switch, perf-gate, launch, sidebar, home-idle, chat-anim, diff-viewer) on an idle measure worker, with `cmux20-bench` first (`perf-cron.py:52`). Parts yield to nightly and dev builds. A tip measurement takes 3 h or more. It measures the DEBUG build (`perf-cron.py:1455`). `--config bench` exists (`reload.sh:1149`, `1699-1702`) and always adds `CMUX_BLOCKING_CHECKS`. Rows keep p95 only. The rule is +10 % over a 5-run median with `CONFIRM_SAMPLES = 3`. State is a GitHub artifact. The only output is one GitHub issue. The cron also starts the frame-pacing workflow once a day, and `perf-cron-arch-report.py` tracks the F13 architecture counts. `cmux-next-perf-bench.yml` runs xbench (cmux against Chrome, Helium, Ardia, Dia and Safari) nightly at 09:17 on cmux20-bench with a 420-minute timeout.
- **Commit volume.** First-parent commits on origin/feat-cmux-next: 274 (10-22), 811 (10-23), 1057 (10-24).
- **Thresholds in 6 places.** `perf-budgets.json` (9 families), `scripts/perf-bench/budgets.json` and `budgets-heavy.json`, `perf-bench/baseline/*.json`, `idle-budget.json`, `browser-idle-cost-budget.json`, and `LAUNCH_BUDGETS` in perf-cron.py with `scripts/ci/launch_budget_gate.py`.
- **Bench sprawl** (corrected counts):
  - Private stat functions (corrected MQ1 over all perf directories): about 70 files.
  - Perf benches that launch their own app instead of `bench_launch.BenchApp` (corrected MQ2): 29 files.
  - Benches with p95 and no p99 (corrected MQ3): 36 files.
  - Swift in-process bench and perf test files under `Tests/`: 19.
  - Daemon benches under `cmux-tui/scripts`, and webview benches, have no shared format.
  - `scripts/measure` has 53 files.
- **Instrumentation.** `CmuxNextSignposts` has 17 SignpostName cases. Only 8 have an emitter (the file's own doc comment). The 9 reserved cases are listed in MQ5. `action.perform` and `action.commit` are always on in Release. The watchdog (`CmuxNextControl/Diagnostics/MainThreadWatchdog.swift`) samples stalls and has gap, `frames120` and `longFrames` counters, but no per-turn histogram. HangReport already has `stallHistogram` and `intervals: [IntervalHistogram]` (`HangReport.swift:105-109`). `BlockingDetector` (`CmuxNextCompat/Threading/BlockingDetector.swift`) runs in Debug and bench builds only.
- **Target coverage gaps.** These have no bench row:
  - Cmd-W
  - main-turn p99
  - Chromium crash survival with timing (`child-crash-e2e.py` checks survival only)
  - hidden-workspace memory slope
  - Release blocking-site count
  - QoS undeclared count (Swift and Rust: about 529 production `thread::spawn`/`thread::Builder::new()` sites in `cmux-tui/crates/*/src`, and 0 QoS calls)
  - runtime QoS inversions
  - daemon hangs
  - incremental build time

  Cold launch exists but is not scheduled.
- **Flags.** There is no Release flag system in the app. There are 230 Tunables: 83 `Tunable<Bool>.toggle`, 81 numeric. `TunableStore` (`CmuxNextDesignTokens/Tunables/TunableStore.swift`) is active in DEV and NIGHTLY only. Labs has 2 rows. Help > Feature Flags exists (`CmuxNextApp/Settings/FeatureFlagsPage.swift`). Sources read 85 `CMUX_NEXT_*` env names in the app and 101 `CMUX_TUI_*` names in the daemon. The signed `flags.json` document exists for the daemon (above). The enterprise managed policy `DisabledFeatures` exists. The only build-level kill is `nightly-next-rollback.yml`.
- **Field data.** Opt-in NIGHTLY hang reports go to the PlanetScale `cmux-prod` table `hang_reports`. Reports already carry MetricKit histograms (hang time, launch first draw and resume, hitch ms/s) and signpost intervals. Sentry gets crashes, hangs over 2 s and lag spikes of 250 ms or more.
- **Corpus.** None. Sessions are synthetic (`perf-stress-session.py`, STRESS = 60 workspaces). The input journal has a characters mode (`CMUX_NEXT_INPUT_JOURNAL_CHARACTERS`, `InputJournal.swift:159`). `schemas/terminal-corpus` holds 5 `.vt` streams.
- **Fleet.** Measurement goes through `cmux-ci run --class exclusive --measurement`. Measure scripts are blob-allowlisted ("the script blob must match the reviewed one", `split-spring.sh:8`). The 120 Hz virtual display is not confirmed on cmux20-bench. No fleet Mac runs macOS 14 or 15.

## 3. Target design: the cmux perf lab

Code lives in `scripts/perf-lab/`. The design doc is `plans/cmux-next/perf-lab-DESIGN.md`. It is a fleet service, never a CI gate and never on a merge path.

### 3.1 Pool, roles and device affinity

`scripts/perf-lab/pool.json` lists 6 lab hosts with the controller label `perf-lab`. Only perf-lab jobs run there, one job per host, and no foreground job preempts them.

| Role | Hosts | Work |
| --- | --- | --- |
| waterfall M6 | 2 M6 minis (from the owned cmux15-24 set) | T0 shards A and B, T1 shards. Alerting class. |
| pinpoint M6 | 2 M6 minis | bisect, culprit verification, A/A, reference runs. They have the same fingerprint as the waterfall hosts. |
| waterfall + pinpoint (other classes) | cmux20-bench; 1 aws-m4pro on macOS 26 | T2 (xbench vs-browsers, soak) on both, T1 on aws-m4pro only (cmux20-bench is the M6 host class; its T1 points would join the M6 series). Bisect for their own class borrows them when idle. |

- Each T0/T1 story is bound to one fixed waterfall host by a generated shard map (`shard_map.json`, bin packing on story seconds), as Chrome does. If the owner host is down, the point is a coverage gap. The story is never moved to another host.
- A bisect may borrow a waterfall host only when it is idle and its next T0 starts in more than 10 minutes.
- Agent try jobs run on any free fleet Mac with the measure label, never on a lab host while T0 or bisect waits. They are same-host ABBA, so device identity does not matter. The receipt names the host class.
- `host-setup.sh` makes every lab host the same: no sleep, Spotlight off on the data volume, no Time Machine, no automatic updates, the bench user logged in at the console with no screen lock, `wpr`, and the vdisplay helper. A sudoers entry for `purge` and `powermetrics` is applied only with `--grant-privileged` (decision D3).
- `host_env.py` runs before every job. It checks: thermal limit 100, 1-minute load < 1.0, free+inactive memory > 8 GB, Low Power off, the console user is the bench user, no other GUI cmux app, no outbound connections from the app or daemon in a 60 s nettop window, and the measured refresh rate. A host that cannot hold 8.33 ms runs at `hz=60`, and its frame-target stories are not judged against 120 Hz targets (task 160). An invalid host refuses with `env-invalid` and stores nothing.
- **Series key:** (story, metric, engine, host class = chip + memory + display Hz, macOS major, build config). The features hash, the full macOS build and the safe-mode state are point metadata, shown as dashboard annotations. They are never part of the key, so a features.json default flip is a step inside the same series and bisects to the flip commit.

### 3.2 Builds

- Configs (task 147):
  - `bench` = Release optimization + `CMUX_BENCH_HOOKS`, no `CMUX_BLOCKING_CHECKS`. It is used for latency, frame, launch, idle and memory stories.
  - `bench-checks` = bench + `CMUX_BLOCKING_CHECKS`. It is used only by the blocking-sites story.
  - Debug results are never compared with bench results.
  - The parity story compares `bench` with the shipped Release build on always-on `action.commit` and must stay within 3 %.
- `scripts/measure/perf-lab-build.sh` runs at the tip ref, because measure entries are blob-allowlisted. It builds `--build-sha` in a separate worktree with submodules at that commit, so a 2-day-old bisect midpoint builds with today's harness. It publishes a content-addressed artifact keyed by (sha, config).
- Builders keep one persistent bench build directory each, and build in SHA order so each build is incremental. They reuse `scripts/ci/dev_release_product_reuse.py`. Batch tips build first, then bisect midpoints, then every other first-parent commit (newest first, when builders are idle) (task 234).
- Capability skew: the lab runs the tip harness against old apps. `debug.capabilities` (task 211) lists the debug methods, emitted signposts and probe env names of a build. A story declares `needs`. A Change that lacks a need is `not-measurable` (never a regression), and a bisect narrows its range to the first measurable commit.

### 3.3 Tiers

- **T0** runs on every built batch: at most 480 s summed over all T0 stories, split over the 2 waterfall M6 shards, with 10 interleaved repeats. T0 stories:
  - terminal key->frame light
  - terminal key->frame STRESS from a restored layout snapshot. Until the snapshot importer (111) lands, STRESS key->frame stays in T1.
  - Home and omnibar key->frame
  - Cmd-T, Cmd-N and Cmd-W key->frame with dropped frames
  - split/close frame
  - workspace switch
  - warm launch x5
  - 60 s idle wakeups with 10 Chromium tabs
  - frame-pacing instant mode
- **T1** runs every 2 h on the waterfall shards (all classes), at most 45 minutes of wall time. T1 stories:
  - all perf-budgets families
  - STRESS motion
  - every-action-sweep shards
  - cold launch
  - hidden-workspace memory slope
  - Chromium crash survival
  - daemon op latency and daemon benches
  - main-turn p99
  - blocking sites (bench-checks build)
  - runtime QoS inversions
  - frame-pacing golden and fling
  - Swift in-process benches (on a builder)
  - power
  - the shipped-Nightly story
  - corpus stories
- **T2** runs nightly: the 8 h corpus soak, launch after reboot, xbench vs-browsers, browser macro benchmarks (Speedometer 3, MotionMark 1.3, JetStream 2, cmux vs Chrome), and A/A.
- **Linux part** (no Mac): diff-viewer and webview benches, static QoS counts (Swift and Rust), arch counts (F13).
- **Builder part:** incremental leaf build with the rebuilt-module list and slow type-check functions, bundle size.

### 3.4 One result format and one statistics module

- Every bench writes `cmux-perf-result/v1` (schema at `schemas/perf/result-v1.schema.json`) through `perf_result.py`, or through `BenchApp.record()` (task 162). A result holds:
  - story, metric, unit, better direction, raw samples
  - the target reference
  - build {sha, config, measure_version}
  - host fingerprint, display Hz, engine, session
  - resolved features with sources, and the safe-mode state
  - attachments
- Statistics come only from `perf_stats.py`: percentiles (one definition, linear interpolation), IQR, Pinpoint's MWU and KS ported line by line, `HighThreshold`, `LowThreshold`, and `compare` (task 002).
- `perf-budgets.py` stays self-contained. The perf cron's report job sparse-checks out only a few files, and an import of `perf_stats` breaks that job. A parity test proves that its `pct` equals `perf_stats.pct`. `perf-budgets.py` and `perf-cron.py` are the only MQ1 allowlist entries.

### 3.5 Store, dashboard, alerts

- `labd.py` runs on cmux-lawrence beside the controller (decision D1), under launchd with `ProcessType=Background`, `nice 10` and a memory limit. It uses stdlib `http.server` bound only to the tailnet address, SQLite (WAL) in Application Support, and a nightly backup to R2 by digest.
- Write endpoints (`/ingest`, `/hooks/job-finished`) accept only callers that `tailscale whois` maps to the controller or a lab host. Read endpoints are open on the tailnet. The operator deploys a pinned, reviewed sha with `deploy.sh --sha`.
- labd reads the big-branch tip with `git ls-remote` every 60 s and on controller job-finish callbacks. It never runs a full fetch loop.
- Dashboard pages:
  - 12 target tiles
  - series sparklines with change points and annotations (features hash, macOS build, reference drift)
  - coverage
  - alert groups
  - Pinpoint jobs with trace links
  - a Field tab (hang rate, MetricKit launch and hitch, action latency, crash-free rate, features arms)
- `anomaly.py` is a port of catapult's detector with catapult's defaults (task 003). A second rule, `target_miss`, applies to the 12 target series: it fires when the newest segment of >= 6 points crosses the fixed target. It is shown as a dashboard tile, not an issue.
- Only series that `subscriptions.json` matches can alert: the 12 target series, the perf-hot series and the per-family summaries. The every-action-sweep per-action series and per-op daemon series feed monitored aggregates.
- Alerts with overlapping ranges form one group. A group gets a GitHub issue (label `perf-regression`) **only after its culprit is verified**. Unverified groups stay on the dashboard. Issues are edited, with one comment per state change. GitHub reads go through `glaeda-gh`.
- A weekly-frozen reference artifact runs on each waterfall host every 6th T0 (`.ref` series). An alert whose `.ref` series moved in the same window becomes `lab-drift`, goes to the lab owner and is not bisected.

### 3.6 Pinpoint

- `pinpoint.py` is a pure core: Job, Change, Attempt, step. `pinpoint_exec.py` is the executor.
- A bisect starts for each new monitored alert group. It is pinned to the alerting host class (a pinpoint host) and runs only the regressed story.
- Attempts: 10 per Change, doubling on UNKNOWN up to 160.
- Magnitude = |alert delta| / max(IQR_a, IQR_b, 0.001).
- Speculation: 1 level. 2 levels only when every Change in the range already has a stored build.
- A commit that does not build is skipped. A Change without a needed capability is not-measurable.
- Bisect starts at batch granularity (batch-tip builds exist), then goes inside the batch.
- A submodule-only culprit (ghostty, ghostty-next, CEF pin) expands into a nested bisect of the dependency's commits (task 236).
- A story that fails on 2 consecutive batches makes a harness-broken alert, and functional mode bisects the pass/fail rate (task 214).
- **Verification:** a try job C^ vs C on the same pinpoint host, 20 ABBA attempts each. It must be DIFFERENT by the strict rule (p <= 0.01) in the regression direction. Otherwise the culprit is `unverified`.
- Traces (signposts, watchdog, daemon spans; no xctrace) are recorded for the first and median attempt of each T0 story, Change and try arm, and stored in R2 by digest (task 157).
- **Try jobs for agents:** `lab.py try --base SHA --head SHA [--stories a,b] [--feature X=on|off]` prints a fixed receipt line per metric. Requests have per-session quotas and are deduplicated (task 235).

### 3.7 Sheriff loop

- Rotating agent sessions run `.claude/workflows/perf-sheriff.js`.
- States: new -> triaged -> bisecting -> culprit -> assigned -> fixed | flag-off | accepted (with a reason and the Performance Lead's session) | invalid | lab-drift.
- SLOs, counted from the time the lab went live: triage <= 1 h, culprit <= 4 h after the alert, fix or flag-off <= 12 h.
- When the culprit is behind a perfPath feature, the first action is a PR that flips the branch default in `schemas/features/` and regenerates the generated files. The PR has a `risk:` label and the line `Takes back #N: <why>` (the take-back hold).
- Otherwise a fixer agent works from the stored traces (157), 2 adversarial reviewers check the fix (REVIEW-STANDARD), and a try job verifies it. A revert uses only `gh-merge-green --revert` per CLAUDE.md.
- The fixer prompt says: never edit budgets, thresholds or expectations to clear an alert.
- `expectations.json` disables a story x host pair, with an issue link and an expiry of at most 7 days.
- A/A runs measure each series' CV and false-alert rate. Each noisy series is a de-noise task (MQ11).
- The regression canary is a bench-hooks-only feature `perfLabCanary`. It adds a 2 ms key-dispatch spin on a scratch ref, never on the big branch. It runs on demand and weekly.

### 3.8 Recorded-session corpus

- Manifests (`schemas/perf/corpus-story-v1`) live in `perf-corpus/`. Blobs are content-addressed in R2.
- A story holds:
  - a layout snapshot built through the action pipeline
  - an input track replayed with recorded timing (event timestamp = send time)
  - PTY tracks played by `pty_replay.py`
  - Chromium pages from a WPR archive (needs task 221: an allowlisted `host-resolver-rules` and `ignore-certificate-errors-spki-list` in bench builds)
  - ACP agent tracks through the acpmux fake-agent harness (needs `CMUX_NEXT_ACPMUX_ROOT` in bench builds, task 221)
- Checkpoint digests must be identical across 2 replays.
- Stories: agent-swarm, dev-loop, browse-heavy, stress-recorded, launch-restore, long-day-soak (T2).
- No user data. The recorder refuses a non-bench bundle id and refuses when `CMUX_NEXT_INPUT_JOURNAL_CHARACTERS` is set. The manifest validator rejects text payloads.
- Player API (task 115, used by stories that measure around a replay, first `blocking_hangs.py`, task 037, and story main-turn, task 032): `play.py` exposes `replay(manifest, *, app, out, window=None)` next to its CLI.
  - After the launch and the layout import, it calls `window(bench)` once with its `BenchApp`, and plays the input track inside the context manager that call returns. The measured window is the input track only.
  - A failed launch raises `bench_launch.LaunchError`, as `BenchApp.launch` does.
  - `out` gets the replay's own result-v1 files and the `host-env-full-<pid>.json` of each launch.

### 3.9 Features, remote overrides, safe mode (base::Feature plus Finch)

- **Registry:** `schemas/features/features.d/<name>.json`, one file per feature so parallel tasks do not conflict. It is generated into the Swift core target `CmuxNextFeatures` and the Rust crate `cmux-features`. Each entry has:
  - name, owner, description
  - defaults {dev, nightly, release}
  - kind: perfPath | killSwitch | labs
  - expires (perfPath: <= 60 days)
  - process: app | daemon | both | chromium (`chromium_feature` maps into CEF `--enable-features`/`--disable-features`, and disable wins)
  - params (typed, with min/max; FeatureParam)
  - stories (the lab stories that bench both arms)
  - `sticky` (a remote off stays off in safe mode)
  - `runtimeMutable` (false for every feature until that feature has a tested live-teardown path)
- **Resolution order, highest first:**
  1. Managed policy `DisabledFeatures` (enterprise)
  2. env `CMUX_DISABLE_FEATURES`/`CMUX_ENABLE_FEATURES` (disable wins)
  3. local Labs/Debug overrides (DEV and NIGHTLY only; `TunableStore` becomes only an override provider for perfPath keys)
  4. remote overrides from the signed flags document, filtered by safe mode
  5. Nightly field-trial arm
  6. channel default
- The snapshot is immutable after the composition root builds it, and a read is one array load. Early reads before install are recorded in DEBUG and bench builds.
- **Remote overrides reuse the existing signed document.** `release-notes/next/flags.json` stays `version: 1`. New top-level and policy keys are added:
  - `Features` {name: "on"|"off"} under `default` and `cohorts`
  - `FeaturesSerial`, `FeaturesExpiresAt`, `FeaturesMinBuild`, `FeaturesMaxBuild`
  - `Studies` (task 152)

  `nightly.yml` already signs and publishes the document with the content-signing key, and its assertion passes. The app fetches `notes/flags.json(.sig)` next to the existing release-notes fetch, verifies it with `ContentSignature`, parses it off-main and applies it at the next launch. The fetch runs even when `updates.checkAutomatically` is off. A separate managed policy key can turn it off. No new timer is added.
- An operator tool, `scripts/features/publish-flags.py`, publishes a kill switch between nightlies with the same key. It needs the content-signing key (decision D2).
- Bench builds also trust a test public key, compiled only under `CMUX_BENCH_HOOKS`. The done check uses that key.
- **Safe mode** (Chrome's rules): at a crash streak of 3, use the last known-good remote document (promoted after the first successful fetch of a run). At 4, use no remote document, but sticky kill switches stay off. Fetch-failure streaks of 25 and 50 act the same way. A successful fetch resets the streak. Crashes are counted by `LaunchRecovery`'s PreviousRun. Under `CMUX_BENCH_HOOKS`, `CMUX_FEATURES_SAFE_MODE=off` disables safe mode for lab runs, and every result records the safe-mode state.
- **Daemon:** the app sends its snapshot at spawn (env) and in every client hello. A mismatch for a `process=both` feature is reported in `features.list`, and the daemon's value is used for that session (no mid-session flip). The daemon keeps its own `flags.json` reader for `DisabledFeatures`.
- **Lab:** T0/T1 measure the branch defaults (the "most likely to launch" config). Each perfPath feature whose default or story code changed in the last 24 h gets one on/off try job a day.
- **Field:** hang reports and Sentry events carry `features_hash` and the non-default features. Nightly studies give perfPath arms by a stable per-install low-entropy value (0..7999), hashed with the study name.

### 3.10 Field and stability

`field.py` reads `hang_reports` read-only (`pscale --org cmux`, branch `main`, a read-only role; the credential comes from the environment). It aggregates per Nightly build and hardware class:

- hangs > 250 ms per 1000 active hours
- MetricKit launch and hitch histograms
- action-latency and main-turn histograms
- the top main-thread blocking sites (Nightly-only cheap mode, task 226)
- every metric split by features arm

`stability.py` reads Sentry read-only: crash-free sessions per release and new top signatures. Each new top signature is one alert group in the same sheriff loop. Field rows are reported on the dashboard. They are not a pass/fail done check, because opt-in Nightly data in 72 h is small.

### 3.11 Capacity

| Work | Cost |
| --- | --- |
| T0 | 2 waterfall M6 hosts, about 4-5 min per shard per batch |
| T1 | about 45 min on each waterfall host every 2 h, about 0.4 host |
| Bisect and verification | 2 pinpoint M6 hosts |
| Try jobs | the general fleet |
| Builds | bench builds of batch tips, about 6 per hour, need about 2 builder hosts all the time with incremental builds. Bisect midpoints come from stored per-commit builds when they exist. |

`capacity.py` reports builder utilization and queue age. When the build queue is over 2, T0 measures every 2nd batch, and the coverage check allows that (60-minute window).

## 4. Rules

- R1. No CI. No file under `.github/workflows` changes. No new CI job, step, schedule or gate. No new refusing guardrail. The perf cron and xbench stop through a sentinel file (`scripts/perf-lab/OWNS_MEASUREMENT`) that their own scripts read.
- R2. No compile or test on a person's Mac. Swift and Rust tests run as `cmux-ci run --class isolated` steps. Lab runs are controller jobs. Linux-only Python tests may run anywhere.
- R3. Never change budgets, thresholds or expectations to clear an alert. Noisy series get de-noised, never widened.
- R4. `targets.json` holds only the 12 fixed program targets. Per-row floors are read by reference (path plus key) from the existing threshold files, never copied. A lint fails on a duplicated number.
- R5. Statistics: bisect and anomaly use catapult's code as ported. The bisect step uses Pinpoint's returned ("new") verdict: DIFFERENT p <= 0.05, SAME p > max(HighThreshold, 0.10), else UNKNOWN. Culprit verification and the try receipt's headline use the strict original rule (DIFFERENT only at p <= 0.01). The receipt also prints both verdicts and both p-values. This decision is recorded in perf-lab-DESIGN.md with the false-positive reason.
- R6. Every story has an owner lane from OWNERS.md and one config (bench or bench-checks or release).
- R7. One file per story (`scripts/perf-lab/stories.d/<id>.json`) and one file per feature (`schemas/features/features.d/<name>.json`), so parallel tasks do not collide.
- R8. Each bench file is migrated by exactly one task, which does MQ1, MQ2, MQ3 and result-v1 for that file. Existing report keys stay unchanged. If a percentile definition changes, the commit gives the old and new values on a fixed vector.
- R9. Tasks that touch an owned area name the owner and tell it (OWNERS.md): PL-blocking, PL-telemetry, PL-switch, PL-motion-core, PL-cef-tab, PL-cef-helper, PL-cef-layer, PL-memory, PL-daemon, PL-holder, PL-arch (signpost catalog, layering), PL-guardrails. If another 72 h program owns the same file, that program takes the task with the same acceptance, and p12 keeps the story and the result-v1 contract.
- R10. Privacy: the corpus has no user data, the field data is counts only, credentials come from the environment and never appear in argv or logs.
- R11. Risk tiers: tasks 092, 093, 094, 097 and 150 change signing, updater or remote control of app behavior. They are `risk:high` and need a `Review (<reviewer>): SHIP at <sha>` receipt. Defaults stay unchanged until the lab shows both arms.
- R12. Bench-only code (`perfLabCanary`, the test public key, the safe-mode override, the bench CEF switch allowlist) is under `CMUX_BENCH_HOOKS`. `check-no-bench-hooks.sh` proves it is absent from Release.

## 5. Critical path for the 72 h

| Hours | Work |
| --- | --- |
| H0-H6 | 026 (sentinel, before any host gets the label), 160 (measure 120 Hz on each host), 001, 002, 004, 162, 147, 200 |
| H6-H12 | 161 (MVP tick on cmux20-bench through `split-spring.sh --config=bench`, so other programs get baselines early), 009, 006, 007, 130 |
| H12-H30 | 008, 010 (hq), 011, 012, 003, 014, 015, 234, the bench-migration queue (050-069) in parallel, signposts 080-083, features 090/091 |
| H30-H48 | 016, 017, 018, 019, 157, 211, the corpus (110-122), target stories (030-043), 092-096, 100-105 |
| H48-H72 | 020, 024 (A/A x3), 025 (canary x3), 027, 146, field (042, 223, 225); then done checks |

## 6. Done checks

`python3 scripts/perf-lab/lab.py done-checks --json` runs every check below and exits 0 only when all pass (except the reported-only items).

1. **Coverage T0.** `lab.py coverage --tier T0 --since 24h` shows >= 90 % of 10-minute merge batches since the lab went live with stored T0 results within 60 minutes of the batch's last merge. If T0 is in every-2nd-batch mode, the check counts measured batches against planned batches.
2. **Coverage T1.** The newest complete T1 is <= 3 h old with 0 missing story families.
3. **Targets mapped.** `lab.py targets --check` prints 12/12. The 12 targets are:
   - key->frame p50 <= 8.3 ms and p99 <= 16.7 ms, light and STRESS, at hz=120
   - 0 main-thread blocking sites (bench-checks)
   - main-turn p99 <= 4 ms
   - 0 dropped frames in motion
   - idle wakeups app+daemon <= 1/s and main <= 0.5/s with 10 Chromium tabs
   - launch cold <= 300 ms and warm <= 150 ms
   - Cmd-T/N/W 0 missed frames
   - 0 hangs > 250 ms (lab corpus and daemon; Nightly field is reported)
   - Chromium crash survival 1.0
   - 0 undeclared QoS threads/queues (Swift and Rust) and 0 runtime inversions
   - incremental leaf build < 30 s
   - hidden-workspace memory slope <= 0.5 MB per workspace

   Each browser target has a chromium row and a webkit row (F12). Each mapped story has >= 1 stored result in the last 24 h.
4. **Release-grade numbers.** `lab.py runs --since 24h --config debug --tier T0,T1` returns 0 rows. The parity series `bench_parity.action_commit_delta_pct` (lean bench vs shipped Release) is <= 3 %.
5. **One result format.** The corrected MQ1 query returns only the allowlist (`perf-budgets.py`, `perf-cron.py`). MQ4 returns 0 stories.
6. **Self-launch removed.** The corrected MQ2 query returns 0 files.
7. **Signposts live.** The corrected MQ5 query prints 0 cases.
8. **No orphan benches.** `lab.py stories --orphans` prints 0 (each perf script is a story or in `retired.json` with a reason).
9. **Noise.** For each waterfall host: >= 3 A/A runs. `lab.py aa --since-live` shows <= 1 false alert per 100 monitored series-days, CV of the median <= 5 % for >= 90 % of monitored latency series, and CV of p99 <= 10 % for >= 80 %.
10. **Pipeline proof.** `lab.py canary --last 3` (3 on-demand runs) shows 3/3: an alert within 7 T0 batches of the injected commit (MIN_SEGMENT_SIZE = 6 needs 6 points after the step), a bisect to the exact injected commit within 3 h of the alert, and a strict DIFFERENT verification.
11. **Pinpoint statistics.** `python3 -m unittest scripts/perf-lab/tests/test_perf_stats.py` asserts the current catapult values: `[0]*20` vs `[0]*15+[1]*5` gives MWU 0.0195 and KS 0.4973; `range(10,30)` vs `list(range(10))+list(range(30,40))` gives MWU 0.9892 and KS 0.0082 (tolerance 0.0005). `HighThreshold('performance', 1.0, 10)` = 0.5708. The table's sha256 matches catapult.
12. **Sheriff SLO.** `lab.py sheriff --slo --since-live` shows 100 % of monitored alert groups triaged within 1 h, a median of <= 4 h from alert to culprit, and 0 groups older than 12 h in new, triaged or culprit.
13. **Kill switch end to end.** In a bench build: the test-key flags document sets the test feature `perfLabKillProbe` off. At the next launch, `cmux settings feature-flags --json` (the existing verb, extended) shows `off source=remote`. A second document with it on shows `on`. Since 2026-10-29 the probe is off by default in every channel (no perf lab switch defaults on), so this proves the remote layer is read and decides both ways, but not that a remote `off` beats a default that is on: see feature-switch-policy.md rule 7 and the lab build-default set proposed there. The safe-mode unit suite passes (3 crashes: last known-good; 4: no remote, sticky kill switches stay off).
14. **Features complete.** `python3 scripts/cmux-next/gen-features.py --check` exits 0. `gen-features.py --unmigrated` (MQ6) prints 0.
15. **Corpus.** `python3 scripts/perf-lab/corpus/play.py --verify --all` shows >= 6 stories, each replayed twice with identical checkpoint digests, run-to-run CV of key->frame p50 <= 5 %, and 0 WPR network misses.
16. **Env audit.** `python3 scripts/features/env_audit.py --check` exits 0 (all app `CMUX_*` and daemon `CMUX_TUI_*` names are classified).
17. **No CI added.** `git diff origin/feat-cmux-next... --stat -- .github/workflows` is empty.
18. Reported only (not pass/fail): `lab.py field --since 7d` (per-Nightly hang rate, launch, hitch, blocking sites, features arms) and `lab.py stability --since 7d` (crash-free rate).

## 7. Machine queues

All queries live in `scripts/perf-lab/queues.py` (task 200). `python3 scripts/perf-lab/queues.py --all --counts` prints them. The commands below are the reference forms. Run them from `/Users/lawrence/fun/wt/chrome-parity`.

- **MQ1: private stat functions (about 70 files).** One bench file goes to one task of the bench-migration queue.
  `rg -l -e 'def (pct|percentile|percentiles|p95|p99|quantile|_pct|_percentile|_percentiles|_quantile|med|median|_median|_med|stats|_stats)\(' -e '\b(p99|p95|p90|pct|med|median) = lambda' -e 'int\(len\([a-z_]+\) \* 0\.9' scripts cmux-tui/scripts webviews/scripts -g '*.py' | rg -v -e 'perf-lab/perf_stats\.py|perf-budgets\.py|perf-cron\.py|ci_health_report|warm_distance|benchmark-dev-fleet|mobile-|team-vm-spike'`
  Non-perf hits (functional `-live.py` tests that define `stats`) go to `queues.py`'s retired list with a reason.
- **MQ2: perf benches that launch their own app (29 files).**
  `cd scripts/cmux-next && for f in *.py; do rg -q 'bench_launch|BenchApp' $f && continue; rg -q -e 'Contents/MacOS|"open", "-n"|launch_app|def launch' $f && echo $f; done | rg -e 'bench|perf|stress|typing|idle|launch|anim|memory|power|churn|hibern|tab_switch|soak|lag|frames|resize|paint|zoom|storm' | rg -v -e '^perf-cron|launch-env-fence'`
- **MQ3: p95 without p99 (36 files).**
  `rg -l p95 scripts/cmux-next/*.py | xargs rg --files-without-match p99 | rg -v -e 'guardrails\.py|perf-cron\.py'`
- **MQ-B: bench-migration queue** = the union of MQ1, MQ2 and MQ3, one file to one task (tasks 050-069 are the first cut). Command: `python3 scripts/perf-lab/queues.py bench-migration --files`.
- **MQ4: story commands that do not write result-v1.** `python3 scripts/perf-lab/lab.py stories --lint --format=paths | xargs rg --files-without-match -e 'perf_result|BenchApp|\.record\('`
- **MQ5: SignpostName cases with no emitter (9 today).**
  `for c in $(rg -o -r '$1' '^\s+case (\w+)$' Packages/macOS/CmuxNext/Sources/CmuxNextSignposts/SignpostName.swift); do n=$(git grep -n -E "(Signposter\.[a-zA-Z]+|signposter|poster)\.[a-zA-Z]+\(\s*\.$c\b|SignpostName\.$c\.staticName" -- Packages/macOS/CmuxNext/Sources ':!Packages/macOS/CmuxNext/Sources/CmuxNextSignposts/SignpostName.swift' | grep -v -E ':[0-9]+:\s*///' | wc -l); [ $n -eq 0 ] && echo $c; done`
- **MQ6: perf-path tunables not yet features** (Bool and numeric). After 090: `python3 scripts/cmux-next/gen-features.py --unmigrated`. Seed keys: `browserResize.layerHosting`, `browserHost.helper`, `motion.pane.holdContent`, `sidebar.*slideHoldsContent`, `hibernation.compressedSnapshots`, `hostPressure.enabled`, `agent.pageHost`, `agent.chromium`, and the env switch `CMUX_TUI_TERMINAL_HOST_MODEL`.
- **MQ7: env switches** (85 `CMUX_NEXT_*`, 183 `CMUX_*` in the app, 101 `CMUX_TUI_*` in the daemon). Each name that changes Release behavior on a perf path becomes a feature or is documented as Debug-only. Command: `python3 scripts/features/env_audit.py --unclassified`.
- **MQ8: fixed targets with no lab story.** `python3 scripts/perf-lab/lab.py targets --uncovered`
- **MQ9: perf-hot paths whose bench is not a story.** `python3 scripts/perf-lab/lab.py hot-paths --uncovered`
- **MQ10: runtime sheriff queue** (one alert group = one sheriff task). `python3 scripts/perf-lab/lab.py alerts --state new,triaged,culprit --json`
- **MQ11: noisy series** (one de-noise task each; fix the bench or the code's variance). `python3 scripts/perf-lab/lab.py aa --cv-over 0.05 --json`
- **MQ12: orphan benches** (each group of up to 4 scripts is one task: make it a story or retire it with a reason). `python3 scripts/perf-lab/lab.py stories --orphans`
- **MQ13: bench-config gaps** (debug methods or env names that scripts use and whose Swift registration is only under `#if DEBUG`). `python3 scripts/perf-lab/queues.py bench-gaps`
- **MQ14: Rust threads without QoS** (one crate is one task). `python3 scripts/perf-lab/stories/qos_static_rust.py --list`
- **MQ15: slow type-check functions** (over 100 ms, one file is one task). From the builder story 039: `python3 scripts/perf-lab/lab.py queue typecheck --latest`
- **MQ16: numeric perf-path tunables that become FeatureParams.** `git grep -n -E 'Tunable<(Double|Int|Duration|CGFloat)>' -- Packages/macOS`, filtered to OWNERS perf-owned paths by `gen-features.py --unmigrated-params`.

## 8. Risks and decisions

Decisions that need Lawrence. Each item names both options in full.

- **D1, labd host.** labd runs on cmux-lawrence, which also runs the controller and the subrouter for all agent traffic. I chose cmux-lawrence with background priority, a memory limit and `git ls-remote` only, because the controller's Tailscale identity and callbacks are there. Reply `keep labd on cmux-lawrence` or `move labd to another tailnet host (name it)`.
- **D2, kill switches between nightlies.** A kill switch between nightlies needs the content-signing key that `nightly.yml` uses, held by an operator for `publish-flags.py`. Without it, a remote kill ships only with the next nightly, and the 12 h SLO uses the branch-default flip. Reply `give the operator the content-signing key for publish-flags.py` or `remote kill only through the nightly flags.json`.
- **D3, sudo on lab hosts.** Cold launch (`purge`) and power (`powermetrics`) need a single-command sudoers entry on the 6 lab hosts. Without it those stories refuse with a reason, and the cold-launch target is covered only by launch-after-reboot in T2. Reply `allow the purge and powermetrics sudoers entries on lab hosts` or `no sudoers change; reboot-based cold launch only`.
- **D4, dedicated hosts.** The lab takes 6 hosts (cmux20-bench, 4 M6 minis, 1 aws-m4pro) out of the shared fleet during a push where other programs also build. The memory note allows clearing paused M6 workers. Reply `dedicate 6 hosts` or `dedicate 4 hosts (2 waterfall M6, 1 pinpoint M6, cmux20-bench) and run T1 every 4 h`.

Risks:

- The controller pool change (010) is in cmuxterm-hq, which has its own review. Until it lands, the lab uses the exclusive measurement class, foreground jobs can preempt it, and the coverage check can fail. Task 161 (MVP) covers the first hours.
- 120 Hz may fail on some hosts. host_env then keys them at hz=60, and the frame targets are judged only from 120 Hz hosts. If no M6 host holds 120 Hz, the frame targets cannot be judged at 120 Hz.
- The move from Debug to the bench config breaks continuity with the cron history. Legacy p95 rows are imported as `legacy_p95_only` and never judged. Each series needs 6 points before anomaly detection works.
- Big-branch commits land on compile only, and some do not build alone. Bisect skips them, which can widen a culprit to a range.
- Build capacity: Release bench builds of 589k Swift lines plus CEF are slow. Per-commit builds (234) are best effort. A bisect inside a batch may wait on builds.
- Remote overrides and safe mode are `risk:high` (updater and signing). They need an independent review receipt. Defaults stay unchanged.
- Field data is opt-in Nightly only. A read-only PlanetScale role and a Sentry token may not exist. Field is therefore reported, not judged.
- Ownership overlap with other programs on the watchdog, hang reports, signposts, CEF files, tunables and daemon threads (R9).
- Corpus privacy: a recorder bug could leak text into R2. The recorder refuses `CMUX_NEXT_INPUT_JOURNAL_CHARACTERS`, and the validator rejects text payloads.
- Noise: if A/A CV stays above 5 % on Apple Silicon, small regressions are missed. MQ11 fixes the variance and never widens thresholds.
- No fleet Mac runs macOS 14 or 15. VM timing is not perf evidence, so the lab cannot catch regressions specific to those versions.
- Shortcut I took: for tasks 080-083, 096 and 150 I did not open every call site. Each task says how to find the real site with `git grep`. An implementer must confirm the site before editing.

## 9. Task table

Size: S <= 150 changed lines, M <= 400, L is a split candidate. Tests run on the fleet per R2. "Lab run" means `cmux-ci run --class exclusive --measurement --label perf-lab --script scripts/measure/perf-lab.sh --ref <tip> --arg=--sha=SHA --arg=--stories=<id>`.

| id | title | size | depends on | queue |
| --- | --- | --- | --- | --- |
| 001 | result-v1 schema and writer | S | - | |
| 002 | perf_stats: catapult MWU, KS, thresholds, compare | M | - | |
| 003 | anomaly.py: catapult E-Divisive port + target_miss | M | 002 | |
| 004 | SQLite store with migrations, series key, annotations | M | 001 | |
| 005 | ingest CLI and perf-cron history import | M | 004 | |
| 006 | host_env validation and fingerprint | M | - | |
| 007 | stories.d, targets.json, catalog, owners, lints | M | 001 | MQ8 |
| 008 | perf-lab.sh measure entry and story runner | M | 006, 007, 009, 162 | |
| 009 | bench builds from the tip harness (--build-sha) | M | 147 | |
| 010 | controller perf-lab pool, roles, priorities (hq) | L | - | |
| 011 | scheduler: batches, tiers, shard map, roles, hooks | L | 004, 007 | |
| 012 | labd service with whois auth and pinned deploy | M | 005, 011 | |
| 013 | dashboard | M | 012 | |
| 014 | alerts, subscriptions, groups, verified-only issues | M | 003, 004, 007 | |
| 015 | Pinpoint job core | L | 002 | |
| 016 | Pinpoint executor | L | 015, 011, 010 | |
| 017 | culprit verification (strict) | S | 016 | |
| 018 | try CLI and receipt | M | 016 | |
| 019 | sheriff states and SLO report | M | 014 | MQ10 |
| 020 | perf-sheriff workflow | L | 019, 018, 157 | MQ10 |
| 021 | perf-lab-DESIGN.md, perf-sheriff.md, doc updates | S | - | |
| 022 | culprit attribution | S | 017 | |
| 023 | expectations with expiry | S | 011 | |
| 024 | A/A noise program | S | 011, 003 | MQ11 |
| 025 | regression canary feature | S | 091, 016 | |
| 026 | sentinel: perf cron and xbench yield to the lab | S | - | |
| 027 | done-checks runner | S | 007, 019, 200 | |
| 030 | Cmd-W rows + full migration of instant-new-surfaces-bench.py | S | 001, 002, 162 | MQ8 |
| 031 | main-turn and input-queueing histograms | M | - | MQ8 |
| 032 | main-turn p99 story | S | 031, 008 | MQ8 |
| 033 | cold launch story | S | 130, 001 | MQ8 |
| 034 | idle with 10 tabs, chromium and webkit | S | 001, 162 | MQ8 |
| 035 | hidden-workspace memory slope, both engines | S | 001, 162 | MQ8 |
| 036 | crash survival timing in child-crash-e2e.py | M | 001, 162, 221 | MQ8 |
| 037 | blocking-site and hang count story (per thread role) | S | 008, 147 | MQ8 |
| 038 | Swift QoS static count | S | 001 | MQ8 |
| 039 | incremental leaf build story with build metrics | S | 001 | MQ8, MQ15 |
| 040 | daemon op latency from spans | S | 008 | |
| 041 | every-action-sweep shards | M | 001, 002 | MQ-B |
| 042 | field import of hang reports | M | 004 | |
| 043 | hang report: active seconds and turn histogram | S | 031 | |
| 050-069 | bench-migration queue (20 tasks, see below) | S/M | 001, 002, 162, 200 | MQ-B |
| 080 | switch.* signposts from the action commit | S | - | MQ5 |
| 081 | motion.frame and motion.run signposts | S | - | MQ5 |
| 082 | create.tab and create.workspace signposts | S | - | MQ5 |
| 083 | cef.pump and cef.create_browser signposts | S | - | MQ5 |
| 090 | feature registry and generator | M | - | MQ6 |
| 091 | CmuxNextFeatures core (FeatureList) | M | 090 | |
| 092 | remote overrides model and store | M | 091 | |
| 093 | fetch and verify notes/flags.json in the updater | M | 092 | |
| 094 | safe mode (Chrome rules) | M | 092 | |
| 095 | cmux-features crate | S | 090 | |
| 096 | Labs page, existing CLI verb, features.list | M | 091 | |
| 097 | publish-flags.py operator tool | S | 092 | |
| 098 | lab feature arms | S | 018, 090 | |
| 100-105 | MQ6 conversions | S/M | 091 (105: 095) | MQ6 |
| 106 | env audit (app and daemon) | M | - | MQ7 |
| 110-122 | corpus | S-L | see rows | |
| 130 | lab host setup | S | - | |
| 131 | weekly report | S | 019 | |
| 146 | reference build series and lab-drift | S | 003, 011, 014 | |
| 147 | bench vs bench-checks configs | S | - | |
| 150 | daemon snapshot in every hello | M | 095, 091 | |
| 151 | feature state in reports and Sentry | S | 091, 042, 043 | |
| 152 | Nightly field trials | M | 092, 151 | |
| 153 | Chromium features in the registry | S | 091, 221 | |
| 155 | FeatureParam | M | 091, 092 | MQ16 |
| 157 | traces with every attempt | S | 008, 016 | |
| 160 | measure 120 Hz on each host | S | - | |
| 161 | MVP tick (hour 12 baselines) | S | 001, 004, 026 | |
| 162 | BenchApp.record and bench env | S | 001 | MQ4 |
| 200 | canonical queue module | M | - | MQ1-3, 5, 6 |
| 208 | xbench vs-browsers as a T2 story | M | 001, 012, 026 | |
| 209 | frame-pacing stories (+golden, browser_resize) | M | 008, 002 | MQ8 |
| 210 | arch counts as a Linux story | S | 001, 026 | |
| 211 | debug.capabilities and not-measurable | M | 015, 007 | |
| 214 | harness-broken alerts and functional bisect | M | 015, 014 | |
| 217 | Swift in-process benches as stories | M | 001, 007 | MQ9 |
| 218 | daemon benches as stories | M | 001, 002 | |
| 219 | webview benches as Linux stories | M | 001 | |
| 220 | orphan bench queue | S | 007 | MQ12 |
| 221 | bench-config gaps (CEF switches, acpmux root, debug methods) | M | - | MQ13 |
| 222 | flags.json Features keys (version 1 kept) | S | 090 | |
| 223 | field MetricKit series | S | 042 | |
| 225 | stability (Sentry) | M | 014 | MQ10 |
| 226 | Nightly blocking-site field counts | M | 042, 151 | |
| 227 | shipped Nightly story | S | 008 | |
| 228 | engine rows in targets and stories | S | 007, 034, 035, 036 | MQ8 |
| 229 | browser macro benchmarks vs Chrome | M | 001, 208 | |
| 230 | runtime QoS inversion count | M | 226, 037 | MQ8 |
| 231 | Rust QoS static count | S | 001 | MQ14 |
| 232 | daemon hang watcher (diagnostics: `server-stats` `include: ["hangs"]` answers `data.hangs = {over_250ms: count since launch, never reset; records: [{sequence, span, duration_ms}]}`, read by 037) | M | 001 | MQ8 |
| 234 | builder capacity and per-commit builds | M | 009 | |
| 235 | try admission and general-fleet try pool | S | 018 | |
| 236 | bisect into dependency rolls | M | 016 | |
| 238 | point agents at try receipts (docs only) | S | 018 | |
| 239 | power and bundle-size series | S | 001, 130 | |

Bench-migration queue first cut (each file in exactly one task; each task: delete private stats and import `perf_stats` by file path, add p99, replace self-launch with `BenchApp`, write result-v1 through `BenchApp.record` or `perf_result`, keep report keys):

| id | files |
| --- | --- |
| 050 | typing-frame-bench.py, automation-typing-bench.py, sidebar-churn-typing.py, bench-typing.py |
| 051 | new-tab-e2e.py, cef-tab-bench.py, open-panel-bench.py, new-tab-daemon-bench.py |
| 052 | tab-switch-matrix.py, tab-switch-stages.py, activation-perf.py, bench_tab_switch.py |
| 053 | palette-open-stages.py (keeps p90), omnibar-click-bench.py, bench-command-pan.py, perceived-speed.py |
| 054 | sidebar-rows-perf-live.py, sidebar-rows-perf-release.py, sidebar-mirror-rebuild-perf.py, sidebar-stress-bench.py |
| 055 | sidebar-doc-bench.py, sidebar-v2-drag-record.py, sidebar_v2_motion_checks.py, sidebar-v2-drag-live.py |
| 056 | bench_cli_storm.py (keep `Client` for input-replay.py), cli-storm-session.py, script-storm-bench.py, bench_daemon_spawn.py |
| 057 | acpmux-overhead-bench.py, agent-engine-bench.py, agent-stream-e2e.py, home-perf.py |
| 058 | bench_hibernation.py, bench_renderer_sharing.py, remote-browser-local-live.py, chromium-host-bench.py |
| 059 | resize-frames-live.py, bench-terminal-resize.py, column-resize-live.py, devtools-resize-live.py |
| 060 | cef-resize-sync-bench.py, drag-lag-live.py, layout-loop-stress-live.py, fullscreen-transition.py |
| 061 | pane-perf-terminal.py, pane-zoom-terminal.py, split-spring-terminal.py, anim-perf-terminal.py (cron row names unchanged) |
| 062 | app-split-bench.py, split-latency-bench.py, app-perf.py, bench_pane_scale.py |
| 063 | browser-idle-cost-live.py, idle-budget.py, fsync-bench.py, burst-bench.py |
| 064 | launch-connect-journey.py, relaunch-e2e.py, downloads-relaunch-live.py, readiness-soak.py |
| 065 | home-typing-still.py, new-workspace-real-typing-e2e.py, cmd-n-paint-e2e.py, zoom-close-check.py |
| 066 | bench-config-parity.py (+ lean bench vs Release parity story), bench-control-publish.py, bench-stalls.py |
| 067 | perf-gate.py (3 p99 forms -> 1; Popen at :204 -> BenchApp) |
| 068 | perf-signposts.py, trace.py (`--self-test` passes) |
| 069 | scripts/perf/browser_engine_bench.py, scripts/measure/perf-10x-drag-daemon.py, scripts/frame-probe-tui.py, cmux-tui/scripts/measure-frames.py |

Files owned by other tasks, not in this queue: `instant-new-surfaces-bench.py` (030), `bench_idle.py` (034), `bench_memory.py` (035), `child-crash-e2e.py` (036), `every-action-sweep.py` (041), `bench-startup.py` (033), `bench_power.py` and `bundle-size.py` (239), `scripts/ci/frame-pacing/*` (209), `cmux-tui/scripts/bench-*.py` (218), `xbench.py` (208). Allowlisted: `perf-budgets.py`, `perf-cron.py`.

The structured result returned with this spec holds the full change, acceptance and test phase for every task.
