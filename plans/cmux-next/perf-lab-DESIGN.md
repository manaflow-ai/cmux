# cmux perf lab: design

Status: building (2026-10-26). Owner: PL-perf-lab ([OWNERS.md](OWNERS.md)). Program spec, task table and done
checks: [chrome-parity/p12-perf-process.md](chrome-parity/p12-perf-process.md). The sheriff process:
[perf-sheriff.md](perf-sheriff.md).

The perf lab is the cmux copy of Chrome's perf waterfall, chromeperf, Pinpoint and Finch. It measures Release-grade
bench builds of each merge batch on dedicated Macs. It finds change points, bisects them to one commit, verifies the
culprit, and gives the culprit to a sheriff. Features with signed remote overrides let a sheriff turn a perf path off
without a revert.

It is a fleet service. It is not a CI gate, a CI job, a CI step or a merge check. It changes no file under
`.github/workflows` (CLAUDE.md, Lawrence 2026-10-23: "not to add gates/tests in CI, but you have to run them
yourself").

## 1. Rules

1. No CI. The perf cron and xbench stop when the sentinel file `scripts/perf-lab/OWNS_MEASUREMENT` exists. Their own
   scripts read it (task 026). No workflow edit.
2. No compile or test on a person's Mac. Lab runs are controller jobs. Swift and Rust tests run as
   `cmux-ci run --class isolated` steps. Linux-only Python tests can run anywhere.
3. Never change a budget, a threshold or an expectation to clear an alert. Make a noisy series less noisy. Never make
   its threshold wider.
4. `targets.json` holds only the 12 fixed program targets. A per-row floor is a reference (path plus key) to the
   threshold file that holds it, never a copy.
5. Every story has one owner lane from [OWNERS.md](OWNERS.md) and one build config.
6. One file per story (`scripts/perf-lab/stories.d/<id>.json`) and one file per feature
   (`schemas/features/features.d/<name>.json`), so parallel tasks do not edit the same file.
7. Bench-only code (`perfLabCanary`, the test public key, the safe-mode override, the bench CEF switch allowlist)
   compiles only under `CMUX_BENCH_HOOKS`.
8. The corpus has no user data. Field data is counts only. Credentials come from the environment, never from argv or
   logs.

## 2. The Chrome model

| cmux part | Chrome part | Source |
| --- | --- | --- |
| Lab pool, shard map, pinpoint-only hosts, reference build | perf waterfall, builders and testers | `docs/speed/perf_waterfall.md`, `tools/perf/core/bot_platforms.py` (`pinpoint_only`, `run_reference_build`), `tools/perf/core/shard_maps`, `generate_perf_sharding.py` |
| Disabled story x host pairs | story expectations | `tools/perf/expectations.config` |
| Store, series, alerts, alert groups | chromeperf | catapult `dashboard/dashboard/models/graph_data.py`, `dashboard/dashboard/models/anomaly.py`, `dashboard/dashboard/sheriff_config/`, `dashboard/dashboard/protobuf/sheriff.proto` |
| Change-point detector | E-Divisive approximation | catapult `dashboard/dashboard/find_change_points.py`, `dashboard/dashboard/common/clustering_change_detector.py`, `dashboard/dashboard/find_step.py`, `dashboard/dashboard/common/defaults.py` |
| Bisect, try jobs, verification | Pinpoint | catapult `dashboard/dashboard/pinpoint/models/job_state.py`, `pinpoint/models/compare/compare.py`, `mann_whitney_u.py`, `kolmogorov_smirnov.py`, `thresholds.py`; `docs/speed/bisects.md`, `docs/speed/perf_trybots.md` |
| Fix or revert | Chrome core principle | `docs/speed/addressing_performance_regressions.md`: "If you make a change that regresses measured performance, you will be required to fix it or revert." |
| Features and params | `base::Feature`, `base::FeatureParam` | `base/feature_list.h`, `base/feature_list.cc`, `base/metrics/field_trial_params.h`, `chrome/browser/flag-metadata.json` |
| Remote overrides and studies | Finch variations | `testing/variations/README.md`, `fieldtrial_testing_config.json`, `components/variations/` |
| Safe mode | variations safe seed | `components/variations/service/safe_seed_manager.h`, `safe_seed_manager.cc` |
| Field data | UMA histograms and crash keys | `base/metrics/histogram_macros.h`, `tools/metrics/histograms/README.md`, `components/variations/variations_crash_keys.cc` |
| Lab and field | how Chrome measures | `docs/speed/how_does_chrome_measure_performance.md`, `docs/speed/speed_domains.md` |
| Harness hygiene | crossbench | crossbench `--env-validation`, `--repeat`, `cb.results.json` |

Chromium paths are relative to `chromium/src`, catapult paths to `catapult-project/catapult`.

## 3. Pool and roles

`scripts/perf-lab/pool.json` (task 130) lists 6 lab hosts with the controller label `perf-lab`. Only perf-lab jobs
run there. Each host runs one job at a time. A foreground job does not preempt a lab job (controller pool, task 010).

| Role | Hosts | Work |
| --- | --- | --- |
| waterfall M6 | 2 M6 minis | T0 shards A and B, T1 shards. These hosts make the alerting series. |
| pinpoint M6 | 2 M6 minis | Bisect, culprit verification, A/A, reference runs. Same host class as the waterfall hosts. |
| waterfall + pinpoint, other classes | cmux20-bench; 1 aws-m4pro on macOS 26 | T2 (xbench, soak) on both, T1 on aws-m4pro. cmux20-bench is an M6 16 GB mini, the M6 host class, and a series key names no host, so it runs no T0 or T1 story. A bisect for their class borrows them when they are idle. |

- A generated shard map (`shard_map.json`, bin packing on story seconds) binds each T0 and T1 story to one waterfall
  host, as Chrome's shard maps do. When the owner host is down, the point is a coverage gap. The lab never moves the
  story to a different host.
- A bisect can borrow a waterfall host only when the host is idle and its next T0 starts in more than 10 minutes.
- Agent try jobs run on any free fleet Mac with the measure label (task 235). They never run on a lab host. They are
  same-host ABBA runs, so the host identity does not change the result. The receipt names the host class.
- `host-setup.sh` makes every lab host the same: no sleep, Spotlight off on the data volume, no Time Machine, no
  automatic updates, the bench user logged in at the console with no screen lock, `wpr` and the virtual display
  helper. Sudoers entries for `purge` and `powermetrics` come only with `--grant-privileged` (decision D3).
- `host_env.py` runs before each job (task 006). It checks: `CPU_Speed_Limit` 100 and thermal and performance
  warning levels 0 (`pmset -g therm`; an unreadable channel fails), 1-minute load below 1.0, free plus inactive memory
  above 8 GiB, Low Power off, the bench user at the console, no other GUI cmux, no outbound connections from the app
  or daemon in a 60 s nettop window, and the measured refresh rate. An invalid host refuses with `env-invalid`
  (exit 3) and stores nothing. A host whose median frame interval is more than 5 % over 8.33 ms runs at `hz=60`. The
  lab does not judge its frame stories against the 120 Hz targets (task 160).

## 4. Builds

| Config | Flags | Stories |
| --- | --- | --- |
| `bench` | Release optimization + `CMUX_BENCH_HOOKS` | latency, frame, launch, idle, memory |
| `bench-checks` | `bench` + `CMUX_BLOCKING_CHECKS` | the blocking-sites story only |
| `release` | the shipped Release build | the parity story and the shipped-Nightly story |
| `debug` | Debug | never measured by the lab |

- `scripts/reload.sh --config bench` adds only `-DCMUX_BENCH_HOOKS`. `--config bench-checks` also adds
  `-DCMUX_BLOCKING_CHECKS` (task 147). The build ledger (`scripts/perf-lab/builds.py`) knows only these two configs,
  and it refuses a bench app whose Swift defines are not those of its config.
- The lab never compares a Debug result with a bench result. Done check 4 requires 0 Debug rows in T0 and T1.
- The parity story compares `bench` with the shipped Release build on the always-on `action.commit` signpost. The
  difference must stay within 3 % (`bench_parity.action_commit_delta_pct`).
- `scripts/measure/perf-lab-build.sh` runs at the tip ref, because the controller allows only reviewed measure
  scripts. It builds `--build-sha` in a separate worktree with submodules at that commit. So a bisect midpoint from 2
  days ago builds with the tip harness. It publishes a content-addressed artifact keyed by (sha, config) (task 009).
  `builds.py` records one ok or failed build per (sha, config). A failure that the commit causes is final, so a
  bisect skips that commit. A full disk, the network or a signal records nothing, and the next attempt builds again.
- Each builder keeps one bench build directory and builds in SHA order, so each build is incremental. Order: batch
  tips first, then bisect midpoints, then every other first-parent commit, newest first, when builders are idle
  (task 234).
- Capability skew: the tip harness runs old apps. `debug.capabilities` (task 211) lists the debug methods, emitted
  signposts and probe env names of a build. A story declares `needs`. A Change that does not have a need is
  `not-measurable`. It is never a regression. The bisect range stops at the first measurable commit.

## 5. Tiers

| Tier | When | Budget | Stories |
| --- | --- | --- | --- |
| T0 | every built merge batch | 480 s summed over all T0 stories, split over the 2 waterfall M6 shards, 10 interleaved repeats | terminal key->frame light and STRESS (STRESS moves to T0 when the snapshot importer, task 111, lands), Home and omnibar key->frame, Cmd-T/N/W key->frame with dropped frames, split and close frame, workspace switch, warm launch x5, 60 s idle wakeups with 10 Chromium tabs, frame-pacing instant mode |
| T1 | every 2 h on the waterfall shards of all classes | 45 minutes of wall time | the perf-budgets families, STRESS motion, every-action-sweep shards, cold launch, hidden-workspace memory slope, Chromium crash survival, daemon op latency and daemon benches, main-turn p99, blocking sites (`bench-checks`), runtime QoS inversions, frame-pacing golden and fling, Swift in-process benches (on a builder), power, shipped Nightly, corpus stories |
| T2 | nightly | - | 8 h corpus soak, launch after reboot, xbench against other browsers, Speedometer 3, MotionMark 1.3, JetStream 2, A/A |
| Linux | each batch, no Mac | - | diff-viewer and webview benches, static QoS counts (Swift and Rust), architecture counts (F13) |
| Builder | each build | - | incremental leaf build with the rebuilt-module list and slow type-check functions, bundle size |

A batch is the commits since the last T0-measured sha, at most one each 10 minutes. When the build queue is longer than
2, T0 measures every 2nd batch. The coverage check counts planned batches in that mode (task 011). `scheduler.py`
gives a batch one of five states: `pending` (it waits for its build), `measured`, `skipped` (every-2nd-batch mode),
`folded` (a newer batch was built first) and `failed` (its tip build failed, or did not come in 1 h or in 3 times the
expected build time). The next measured batch covers a skipped, folded or failed batch. `catalog.py` refuses a T0
story set that sums to more than 480 s.

## 6. Result format and series

- Every bench writes `cmux-perf-result/v1` (`schemas/perf/result-v1.schema.json`) through
  `scripts/perf-lab/perf_result.py`, or through `BenchApp.record()` in `scripts/cmux-next/bench_launch.py`, which calls
  it. One result holds story, metric, unit, better direction, raw samples, target reference, run, build
  {sha, config, measure_version}, host fingerprint and class, display Hz, engine, session, resolved features with their
  sources, safe-mode state and attachments.
- Statistics come only from `scripts/perf-lab/perf_stats.py`. `pct()` is the one percentile definition: linear
  interpolation between the closest ranks. `scripts/cmux-next/perf-budgets.py` keeps its own copy of `pct`, because
  the perf cron's report job checks out only a few files. `tests/test_perf_stats.py` proves the two agree.
- The series key is (story, metric, engine, host class = chip + memory + display Hz, macOS major, build config)
  (`scripts/perf-lab/store.py` `series_key`). The features hash, the full macOS build and the safe-mode state are
  point metadata. They are never part of the key. So a features default flip is a step in the same series, and the
  bisect finds the flip commit.
- Only waterfall runs are series points. Bisect, verify, try, A/A and reference attempts are job data
  (`store.py` `RUN_KINDS`).

## 7. Statistics: catapult's constants

The port is line by line at catapult commit `0e8f52413a40b5c868739293e784428041275f81`
(`scripts/perf-lab/perf_stats.py`, `scripts/perf-lab/pinpoint_thresholds.py`, `scripts/perf-lab/anomaly.py`,
`scripts/perf-lab/anomaly_edivisive.py`, `scripts/perf-lab/pinpoint.py`), with catapult's names.

### 7.1 Values in code

`scripts/perf-lab/tests/test_design_docs.py` reads this table and compares each value with the code. A cell
`path::NAME` is a module-level constant of that file. A cell `path::Call(...)` is a call into that perf-lab module. A
value must equal the code's value exactly, with the same type. Only a value marked `≈` (a computed p-value) is the
code's value rounded to the decimals shown. When you change one side, change the other side in the same commit.
The test is in the perf-lab suite: run `python3 -m unittest discover -s scripts/perf-lab/tests` when you change a
perf-lab file or one of the perf-lab docs.

| Constant | Value | cmux code | Chromium or catapult source |
| --- | --- | --- | --- |
| Strict DIFFERENT threshold | `0.01` | `scripts/perf-lab/pinpoint_thresholds.py::LowThreshold()` | `compare/thresholds.py` `LowThreshold` |
| Floored DIFFERENT threshold | `0.05` | `scripts/perf-lab/perf_stats.py::_MIN_LOW_THRESHOLDS_FUNCTIONAL` | `compare/compare.py` |
| Floored SAME threshold floor | `0.10` | `scripts/perf-lab/perf_stats.py::_MIN_HIGH_THRESHOLDS_FUNCTIONAL` | `compare/compare.py` |
| High threshold, 1.0 IQR, 10 values | `0.5708` | `scripts/perf-lab/perf_stats.py::HighThreshold('performance', 1.0, 10)` | `compare/thresholds.py` `_HIGH_THRESHOLDS_PERFORMANCE` |
| High threshold, 1.0 IQR, 20 values | `0.0859` | `scripts/perf-lab/perf_stats.py::HighThreshold('performance', 1.0, 20)` | same |
| High threshold, 1.0 IQR, 160 values | `0.0032` | `scripts/perf-lab/perf_stats.py::HighThreshold('performance', 1.0, 160)` | same |
| Performance table rows (0.3 to 4.0 IQR) | `38` | `scripts/perf-lab/pinpoint_thresholds.py::len(_HIGH_THRESHOLDS_PERFORMANCE)` | same |
| Functional table rows (0.1 to 1.0 rate) | `10` | `scripts/perf-lab/pinpoint_thresholds.py::len(_HIGH_THRESHOLDS_FUNCTIONAL)` | `compare/thresholds.py` `_HIGH_THRESHOLDS_FUNCTIONAL` |
| sha256 of the threshold tables | `"afe6ac6d7b187c28a1923e8c0eced4a08b692a7fcdb7282d2ac20ad35d7d88af"` | `scripts/perf-lab/pinpoint_thresholds.py::TABLE_SHA256` | `compare/thresholds.py` at the commit above |
| MWU p, `[0]*20` vs `[0]*15+[1]*5` | ≈ `0.0195` | `scripts/perf-lab/perf_stats.py::MannWhitneyU([0] * 20, [0] * 15 + [1] * 5)` | `compare/mann_whitney_u.py` |
| KS p, `[0]*20` vs `[0]*15+[1]*5` | ≈ `0.4973` | `scripts/perf-lab/perf_stats.py::KolmogorovSmirnov([0] * 20, [0] * 15 + [1] * 5)` | `compare/kolmogorov_smirnov.py` |
| MWU p, `range(10,30)` vs `range(10)+range(30,40)` | ≈ `0.9892` | `scripts/perf-lab/perf_stats.py::MannWhitneyU(list(range(10, 30)), list(range(10)) + list(range(30, 40)))` | `compare/mann_whitney_u.py` |
| KS p, `range(10,30)` vs `range(10)+range(30,40)` | ≈ `0.0082` | `scripts/perf-lab/perf_stats.py::KolmogorovSmirnov(list(range(10, 30)), list(range(10)) + list(range(30, 40)))` | `compare/kolmogorov_smirnov.py` |
| Window for change points | `50` | `scripts/perf-lab/anomaly.py::MAX_WINDOW_SIZE` | `common/defaults.py` `MAX_WINDOW_SIZE` |
| Points on each side of a step | `6` | `scripts/perf-lab/anomaly.py::MIN_SEGMENT_SIZE` | `common/defaults.py` `MIN_SEGMENT_SIZE` |
| Absolute change (the lab uses the row floor, read by reference) | `0` | `scripts/perf-lab/anomaly.py::MIN_ABSOLUTE_CHANGE` | `common/defaults.py` `MIN_ABSOLUTE_CHANGE` |
| Relative change | `0.1` | `scripts/perf-lab/anomaly.py::MIN_RELATIVE_CHANGE` | `common/defaults.py` `MIN_RELATIVE_CHANGE` |
| Steppiness | `0.5` | `scripts/perf-lab/anomaly.py::MIN_STEPPINESS` | `common/defaults.py` `MIN_STEPPINESS` |
| Standard deviations | `2.5` | `scripts/perf-lab/anomaly.py::MULTIPLE_OF_STD_DEV` | `common/defaults.py` `MULTIPLE_OF_STD_DEV` |
| Permutation test iterations | `199` | `scripts/perf-lab/anomaly_edivisive.py::_PERMUTATION_TESTING_ITERATIONS` | `common/clustering_change_detector.py` |
| Permutation test points | `20` | `scripts/perf-lab/anomaly_edivisive.py::_MAX_SUBSAMPLING_LENGTH` | same |
| Significance | `0.95` | `scripts/perf-lab/anomaly_edivisive.py::_MIN_SIGNIFICANCE` | same |
| Change range, part of the peak | `0.9` | `scripts/perf-lab/anomaly_edivisive.py::_CHANGE_RANGE_TOLERANCE` | same |
| Attempts per Change, first | `10` | `scripts/perf-lab/pinpoint.py::MIN_ATTEMPTS` | `pinpoint/models/job_state.py` `MIN_ATTEMPTS` |
| Attempts per Change, most (doubling on UNKNOWN) | `160` | `scripts/perf-lab/pinpoint.py::MAX_ATTEMPTS` | `job_state.py` `MAX_ATTEMPTS` |
| Builds per job | `60` | `scripts/perf-lab/pinpoint.py::MAX_BUILDS` | `job_state.py` `MAX_BUILDS` |
| Speculation levels | `1` | `scripts/perf-lab/pinpoint.py::SPECULATION_LEVELS` | `job_state.py` `_DEFAULT_SPECULATION_LEVELS` (the README's "two levels" is out of date) |
| Speculation levels when every Change has a stored build | `2` | `scripts/perf-lab/pinpoint.py::STORED_BUILD_SPECULATION_LEVELS` | - |
| Verify job attempts per arm, in the Pinpoint core | `20` | `scripts/perf-lab/pinpoint.py::VERIFY_ATTEMPTS` | - |
| Verification attempts per arm (ABBA) | `20` | `scripts/perf-lab/verify.py::DEFAULT_ATTEMPTS` | - |
| Fixed targets | `12` | `scripts/perf-lab/catalog.py::TARGET_COUNT` | - |
| T0 seconds, summed over all T0 stories | `480` | `scripts/perf-lab/catalog.py::T0_SECONDS_MAX` | - |
| Batch, at most one each N minutes | `10.0` | `scripts/perf-lab/scheduler.py::BATCH_INTERVAL.total_seconds() / 60` | - |
| T1, every N hours | `2.0` | `scripts/perf-lab/scheduler.py::T1_INTERVAL.total_seconds() / 3600` | - |
| Every-2nd-batch mode, queued builds over | `2` | `scripts/perf-lab/scheduler.py::EVERY_SECOND_QUEUE` | - |
| Bisect borrow, minutes before the next T0 | `10.0` | `scripts/perf-lab/scheduler.py::BORROW_LEAD.total_seconds() / 60` | - |
| Batch-tip build timeout, hours | `1.0` | `scripts/perf-lab/scheduler.py::BUILD_TIMEOUT.total_seconds() / 3600` | - |
| Reference build, every Nth T0 on a waterfall host | `6` | `scripts/perf-lab/scheduler.py::REFERENCE_EVERY` | `bot_platforms.py` `run_reference_build` |
| Host: `CPU_Speed_Limit` not throttled | `100` | `scripts/perf-lab/host_env.py::THERM_CHANNELS[2][3]` | crossbench `--env-validation` |
| Host: highest 1-minute load | `1.0` | `scripts/perf-lab/host_env.py::MAX_LOAD_1MIN` | same |
| Host: lowest free plus inactive memory, GiB | `8.0` | `scripts/perf-lab/host_env.py::MIN_FREE_INACTIVE_BYTES / 2**30` | same |
| Host: nettop window, seconds | `60` | `scripts/perf-lab/host_env.py::NETTOP_WINDOW_S` | - |
| Host: 120 Hz frame, ms | `8.33` | `scripts/perf-lab/host_env.py::round(FRAME_120_MS, 2)` | - |
| Host: frame interval tolerance | `1.05` | `scripts/perf-lab/host_env.py::FRAME_TOLERANCE` | - |
| Host: exit code of `env-invalid` | `3` | `scripts/perf-lab/host_env.py::EXIT_ENV_INVALID` | - |
| Issue label | `"perf-regression"` | `scripts/perf-lab/alerts.py::ISSUE_LABEL` | - |
| Sheriff SLO: alert to `triaged`, hours | `1.0` | `scripts/perf-lab/sheriff.py::TRIAGE_SLO.total_seconds() / 3600` | - |
| Sheriff SLO: alert to `culprit` (median), hours | `4.0` | `scripts/perf-lab/sheriff.py::CULPRIT_SLO.total_seconds() / 3600` | - |
| Sheriff SLO: alert to `fixed` or `flag-off`, hours | `12.0` | `scripts/perf-lab/sheriff.py::FIX_SLO.total_seconds() / 3600` | - |
| Judged batches for `fixed` | `2` | `scripts/perf-lab/sheriff.py::RECOVERY_BATCHES` | `mark_recovered_alerts.py` |
| Sheriff take lease, hours | `2.0` | `scripts/perf-lab/sheriff.py::TAKE_LEASE.total_seconds() / 3600` | - |
| Trace retention, days | `30` | `scripts/perf-lab/trace_quest.py::RETENTION.days` | - |
| labd port (the controller is on 18765) | `18766` | `scripts/perf-lab/labd.py::DEFAULT_PORT` | - |
| Unfinished try jobs per session | `3` | `scripts/perf-lab/try_admission.py::SESSION_QUOTA` | - |
| Result schema id | `"cmux-perf-result/v1"` | `scripts/perf-lab/perf_result.py::SCHEMA_ID` | - |
| Build configs | `("debug", "bench", "bench-checks", "release")` | `scripts/perf-lab/perf_result.py::CONFIGS` | - |
| Engines | `("chromium", "webkit", "none")` | `scripts/perf-lab/perf_result.py::ENGINES` | - |
| Feature sources in a result | `("policy", "env", "local", "remote", "study", "default")` | `scripts/perf-lab/perf_result.py::FEATURE_SOURCES` | - |
| Safe-mode states in a result | `("off", "inactive", "last_known_good", "no_remote", None)` | `scripts/perf-lab/perf_result.py::SAFE_MODES` | `safe_seed_manager.h` (safe seed, null seed) |
| Series key version | `"sk1"` | `scripts/perf-lab/store.py::SERIES_KEY_VERSION` | - |
| Run kinds | `("waterfall", "bisect", "verify", "try", "aa", "reference")` | `scripts/perf-lab/store.py::RUN_KINDS` | - |
| Alert group states | `("new", "triaged", "bisecting", "culprit", "assigned", "fixed", "flag-off", "accepted", "invalid", "lab-drift")` | `scripts/perf-lab/store.py::ALERT_GROUP_STATES` | - |
| Longest perfPath feature life, days | `60` | `scripts/cmux-next/gen-features.py::PERF_PATH_MAX_DAYS` | `chrome/browser/flag-metadata.json` (`expiry_milestone`) |
| Feature registry folder | `"schemas/features/features.d"` | `scripts/cmux-next/gen-features.py::FEATURES_DIR` | - |
| Perf cron's first host (until the sentinel) | `"cmux20-bench"` | `scripts/cmux-next/perf-cron.py::BENCH_WORKER` | - |
| Perf cron's confirm samples (until the sentinel) | `3` | `scripts/cmux-next/perf-cron.py::CONFIRM_SAMPLES` | - |

### 7.2 Two-sided p-values

catapult's `compare.py` has a comment table with MWU 0.0097 and 0.4946 for the two examples above. Those are one-sided
values. The code returns `2 * _NormSf(abs(z))` with `mean_rank = n1*n2/2 + 0.5`, which is two-sided. It gives 0.0195
and 0.9892. The lab uses the code, not the comment. `tests/test_perf_stats.py` asserts the code values and asserts
that the comment values do not come out. The ported comment in `perf_stats.py` says the same.

### 7.3 Decision: floored verdict for bisect steps, strict verdict for verification and receipts

`compare()` returns both of Pinpoint's verdicts (`perf_stats.Comparison`):

- `original` (strict): DIFFERENT when p <= 0.01, UNKNOWN when p <= HighThreshold, else SAME.
- `floored` ("new" in catapult): DIFFERENT when p <= 0.05, SAME when p > max(HighThreshold, 0.10), else UNKNOWN.
  Pinpoint returns it when `benchmark_arguments` is set and only logs it as `BisectDebug` otherwise.

The lab uses them as follows:

| Step | Verdict | Why |
| --- | --- | --- |
| Bisect step (task 015) | floored | Pinpoint returns this verdict for performance bisects. A false DIFFERENT at one step costs only builds and attempts on the wrong half, and verification catches the wrong culprit. The 0.10 SAME floor stops early SAME verdicts at large sample counts, where HighThreshold falls to 0.0032 at 160 values. |
| Culprit verification (task 017) | strict, in the regression direction | An issue opens only for a verified culprit, and a sheriff acts on it. At p <= 0.05, about 1 in 20 null comparisons is DIFFERENT. At p <= 0.01, about 1 in 100. A culprit that is floored DIFFERENT but strict UNKNOWN stays `unverified`. |
| Try receipt headline (task 018) | strict, and the receipt also prints the floored verdict and both p-values | A try job compares many metrics. With 10 metrics and no real change, the chance of at least one false DIFFERENT is 1 - 0.95^10 = 40 % at the floored rule and 1 - 0.99^10 = 9.6 % at the strict rule. |

Magnitude (both uses) = |delta| / max(Iqr(a), Iqr(b), 0.001), with catapult's own C = 1/2 percentile
(`perf_stats.magnitude_from`). It is not `pct()`, so a threshold row matches catapult's row. A mean shift in the
improvement direction is SAME.

### 7.4 Values in the spec, not yet in code

Each task below adds its constant with the catapult or Chromium name. Then move the row to 7.1 in the same commit.
The catapult and Chromium values were checked against their main branches on 2026-10-25.

| Value | Number | Task | Source |
| --- | --- | --- | --- |
| T1 wall time | at most 45 minutes on each waterfall host | 011 | - |
| T0 repeats | 10 interleaved repeats of each T0 story | 007 | - |
| Reference pin | the reference artifact is frozen each week | 146 | `bot_platforms.py` `run_reference_build` |
| Expectations | expire at most 7 days after they are added | 023 | `tools/perf/expectations.config` |
| Main-turn histogram | about 64 exponential buckets | 031 | `base/metrics/histogram_macros.h` |
| Safe seed | crash streak `kCrashStreakSafeSeedThreshold = 3`, fetch-failure streak `kFetchFailureStreakSafeSeedThreshold = 25` | 094 | `components/variations/service/safe_seed_manager.h` (crash), `safe_seed_manager.cc` (fetch failure) |
| Null seed | crash streak `kCrashStreakNullSeedThreshold = 4`, fetch-failure streak `kFetchFailureStreakNullSeedThreshold = 50` | 094 | same |
| Low-entropy value | 0..7999 per install | 152 | `components/metrics/entropy_state.h` `kMaxLowEntropySize = 8000` |
| Parity | `bench` vs shipped Release `action.commit` within 3 % | 066 | - |
| A/A | >= 3 runs per waterfall host; <= 1 false alert per 100 monitored series-days; median CV <= 5 % for >= 90 % of latency series, p99 CV <= 10 % for >= 80 % | 024 | - |

## 8. Alerts

- `anomaly.py` (task 003) ports catapult's detector with catapult's defaults (7.1). A point is the median of one run;
  the p99 series is a separate series. An improvement is stored and does not alert.
- A second rule, `target_miss`, applies to the 12 target series. It fires when the newest segment of at least
  `MIN_SEGMENT_SIZE` (6) points crosses the fixed target. It is a dashboard tile, not an issue.
- `alerts.py detect` runs both rules on the series that an ingest touched. A change point that overlaps an alert that
  the series already has is not alerted again (catapult `find_anomalies.py`). A regression joins the oldest open group
  whose range overlaps its range, and the group range becomes the intersection (catapult `models/alert_group.py`
  `RevisionRange.IsOverlapping`).
- Only series that `subscriptions.json` matches can alert: the 12 target series, the perf-hot series
  (`scripts/cmux-next/perf-hot-benches.json`) and the family summaries. Every-action-sweep and daemon per-op series
  feed monitored aggregates. This is chromeperf's `Subscription` (`dashboard/dashboard/protobuf/sheriff.proto`).
- Alerts with overlapping ranges make one group. A group gets a GitHub issue with the label `perf-regression` only
  after its culprit is verified (task 014). Unverified groups stay on the dashboard. The lab edits the issue body and
  adds one comment for each state change. GitHub reads go through `glaeda-gh`.
- When the `.ref` series of the alert host moves in the same window, the group is `lab-drift`. It goes to the lab
  owner and the lab does not bisect it (task 146).
- A story that fails on 2 consecutive batches on an env-valid host makes a `harness-broken` group. Functional mode
  bisects its pass/fail rate (task 214).

## 9. Pinpoint rules

1. A bisect starts for each new monitored alert group. It runs only the regressed story, pinned to the alerting host
   class, on a pinpoint host.
2. Each Change starts with 10 attempts. UNKNOWN doubles the attempts, up to 160. The bisect step uses the floored
   verdict (7.3).
3. Magnitude = |alert delta| / max(Iqr(a), Iqr(b), 0.001).
4. Speculation is 1 level. It is 2 levels only when every Change in the range already has a stored build.
5. The bisect starts at batch granularity (batch-tip builds exist), then goes into the batch.
6. A commit that does not build is skipped. A Change without a needed capability is `not-measurable`. Both can make
   the culprit a range.
7. A culprit that only moves the ghostty or ghostty-next submodule or the CEF pin expands into a nested bisect of the
   dependency's commits (task 236).
8. Verification (`verify.py`, task 017): a try job of C^ against C on one pinpoint host, 20 ABBA attempts each, with
   the samples of each arm pooled. It must be strict DIFFERENT (p <= 0.01) in the regression direction. The group
   moves from `bisecting` to `culprit` in both cases. `culprit_verified` records the result, and only a verified
   culprit opens an issue. An unverified culprit goes to the sheriff through the group history.
9. The lab records traces (signposts, watchdog, daemon spans; no xctrace) for the first and the median attempt of each
   T0 story, Change and try arm, and stores them in R2 by digest (`trace_quest.py`, task 157). A trace is kept 30
   days, or longer while an alert group or an alert range refers to its run. `lab.py traces links --group N` prints
   the trace links of a group for its issue.
10. Try jobs for agents: `lab.py try --base SHA --head SHA [--stories a,b] [--feature X=on|off]` (task 018). It
    prints one receipt line per metric. The try queue (`try_admission.py`, task 235) puts the job on a free fleet Mac
    with the `measure` label, never on a `perf-lab` host. It refuses a 4th unfinished job of one session, and it joins
    a request with the same base, head, stories and features to the unfinished job. So a wait timeout leaves the job
    running, and the same command waits again. The receipt format and the verdict that each claim needs are in
    [perf try receipts](../../skills/cmux-testing/SKILL.md#perf-try-receipts). That section is the one source; this
    file does not copy it.
11. `pinpoint.py` (task 015) is the pure core: `step()` returns build and run actions and does no I/O. The executor
    (task 016) runs them and saves the job state after each result, so a restarted executor continues the same job.

## 10. Features, remote overrides and safe mode

### 10.1 Registry

- One file per feature: `schemas/features/features.d/<name>.json`, validated by
  `schemas/features/features.schema.json`. `scripts/cmux-next/gen-features.py` generates the Swift target
  `CmuxNextFeatures` (`Features.generated.swift`) and the Rust crate `cmux-features` (`src/generated.rs`). The
  fields are in [schemas/features/README.md](../../schemas/features/README.md).
- Kinds: `perfPath` (a perf path that rolls out behind a default; it expires at most 60 days after the generator run),
  `killSwitch`, `labs`.
- New user-visible behavior goes behind a default-off feature, as Chrome's `FEATURE_DISABLED_BY_DEFAULT`.
- `runtimeMutable` is false until the feature has a tested live-teardown path (`teardownTest`).
- `sticky`: a remote off stays off in safe mode, also when the remote document is dropped.

### 10.2 Resolution order

Highest first (`CmuxNextFeatures/FeatureList.swift`):

1. Managed policy `DisabledFeatures` (enterprise).
2. `CMUX_DISABLE_FEATURES` and `CMUX_ENABLE_FEATURES`. A name on both lists is off, as in Chrome
   (`base/feature_list.h`: "If a feature appears on both lists, then it will be disabled").
3. Local Labs and Debug overrides, DEV and NIGHTLY only. `TunableStore` is only an override provider for perfPath
   keys.
4. Remote overrides from the signed flags document, filtered by safe mode.
5. The Nightly field-trial arm.
6. The channel default.

The composition root builds the snapshot once. It is immutable after that, and a read is one array load. The daemon
gets the app's overrides in its spawn environment and in every client hello. A `process=both` feature that differs is
reported in `features.list`, and the daemon keeps its value for the session (task 150).

Open mismatch: the Swift `Feature.Source.fieldTrial` prints `trial`, but result-v1 `FEATURE_SOURCES` expects
`study`. Fix one side before a bench copies `cmux settings feature-flags --json` sources into a result.

### 10.3 Reuse of the signed `flags.json`

The lab adds no new signed document and no new key.

- `release-notes/next/flags.json` stays `version: 1`. `nightly.yml` signs it with the content-signing key, publishes
  it as `notes/flags.json`, and asserts `version == 1`. A version bump would fail that assertion and need a workflow
  edit, so the lab adds keys instead (task 222).
- New keys under `default` and `cohorts`: `Features` ({name: "on"|"off"}), `FeaturesSerial`, `FeaturesExpiresAt`,
  `FeaturesMinBuild`, `FeaturesMaxBuild`, `Studies` (task 152). The daemon's reader
  (`cmux-tui/crates/cmux-tui/src/feature_flags.rs`) keeps `DisabledFeatures`.
- The app fetches `notes/flags.json` and its `.sig` next to the release-notes fetch, verifies it with
  `ContentSignature`, parses it off the main thread and applies it at the next launch (task 093). The fetch runs also
  when `updates.checkAutomatically` is off. A managed policy key can turn it off. No new timer.
- The store refuses an unknown name, an expired document, a lower serial and a build outside the range, with a reason
  (task 092).
- `scripts/features/publish-flags.py` lets an operator publish a kill switch between nightlies with the same key
  (task 097, decision D2).
- Bench builds also trust a test public key, compiled only under `CMUX_BENCH_HOOKS`.

Tasks 092, 093, 094, 097 and 150 change signing, the updater or remote control of app behavior. They are `risk:high`
and need a `Review (<reviewer>): SHIP at <full head sha>` receipt.

### 10.4 Safe mode

These are Chrome's safe-seed rules (`safe_seed_manager.cc`), task 094:

- A crash streak of 3, or a fetch-failure streak of 25: use the last known-good remote document. A document becomes
  last known-good after the first successful fetch of a run.
- A crash streak of 4, or a fetch-failure streak of 50: use no remote document. Sticky kill switches stay off.
- A successful fetch resets the streak. `LaunchRecovery`'s PreviousRun counts crashes.
- Under `CMUX_BENCH_HOOKS` only, `CMUX_FEATURES_SAFE_MODE=off` turns safe mode off for lab runs. Every result records
  the safe-mode state (`SAFE_MODES` in 7.1).

### 10.5 Features in the lab and the field

- T0 and T1 measure the branch defaults. This is Chrome's `fieldtrial_testing_config.json` rule: perf bots run "the
  configuration most likely to launch".
- Each perfPath feature whose file or story code changed in the last 24 h gets one on/off try job each day (task 098).
- Hang reports and Sentry events carry `features_hash` and the non-default features (task 151), as Chrome attaches
  active variations to UMA logs and crash keys.
- Nightly studies give a perfPath arm from a stable per-install low-entropy value (0..7999), hashed with the study
  name (task 152).

## 11. Recorded-session corpus

- Manifests (`schemas/perf/corpus-story-v1`) live in `perf-corpus/`. Blobs are content-addressed in R2, with a local
  cache. No blob over 256 KB goes into git (task 110).
- A story has a layout snapshot built through the action pipeline, an input track replayed with its recorded timing,
  PTY tracks (`pty_replay.py`), Chromium pages from a Web Page Replay archive and ACP agent tracks from the acpmux
  fake-agent harness. WPR needs the bench CEF switch allowlist, and ACP needs `CMUX_NEXT_ACPMUX_ROOT` in bench builds
  (task 221).
- 2 replays must give the same checkpoint digests.
- Stories: agent-swarm, dev-loop, browse-heavy, stress-recorded, launch-restore, long-day-soak (T2).
- No user data. The recorder refuses a bundle id that is not a bench bundle, and refuses when
  `CMUX_NEXT_INPUT_JOURNAL_CHARACTERS` is set. The manifest validator refuses text payloads.

## 12. Field and stability

- `field.py` reads the PlanetScale `cmux-prod` table `hang_reports` read-only (`pscale --org cmux`, branch `main`,
  a read-only role, credential from the environment). Per Nightly build and hardware class it reports: hangs over
  250 ms per 1000 active hours, MetricKit launch and hitch histograms, action-latency and main-turn histograms, the
  top main-thread blocking sites, and each metric split by features arm.
- `stability.py` reads Sentry read-only: crash-free sessions per release and new top signatures. Each new top
  signature is one alert group in the sheriff loop.
- Field rows are reported on the dashboard. They are not a pass/fail done check, because 72 h of opt-in Nightly data
  is small.

## 13. Store, service and dashboard

- `scripts/perf-lab/store.py`: SQLite with WAL, one connection per thread, forward-only versioned migrations.
- `labd.py` runs on cmux-lawrence next to the controller (decision D1), under launchd (`com.cmux.perf-lab.plist`)
  with `ProcessType=Background` and nice 10. macOS does not enforce the plist memory limit, so labd exits with
  `EX_TEMPFAIL` when its peak RSS passes the limit, and launchd starts it again. It binds only to its tailnet
  address, port 18766. Write endpoints (`/ingest`, `/hooks/job-finished`) accept only callers that
  `tailscale whois` names as the controller or a lab host. The controller on the same host posts to the Unix socket
  `labd.sock`, because each OS user of that host can reach its tailnet address. Read endpoints are open on the
  tailnet. The operator deploys a pinned sha with `deploy.sh --sha` (task 012). Each night labd puts a gzipped copy
  of the store into R2 by its sha256.
- labd runs the scheduler tick every 60 s and after each job-finished callback. The tick reads the tip with
  `git ls-remote` and fetches only that branch into `refs/perf-lab/<branch>`. It never fetches the full
  repository.
- Dashboard: 12 target tiles, series with change points and annotations, coverage, alert groups, Pinpoint jobs with
  trace links, and a Field tab (task 013).

## 14. What landed

| Task | Part | Code |
| --- | --- | --- |
| 001 | result format | `schemas/perf/result-v1.schema.json`, `scripts/perf-lab/perf_result.py` |
| 002 | statistics | `scripts/perf-lab/perf_stats.py`, `scripts/perf-lab/pinpoint_thresholds.py` |
| 003 | change-point detector and `target_miss` | `scripts/perf-lab/anomaly.py`, `scripts/perf-lab/anomaly_edivisive.py` |
| 004 | store | `scripts/perf-lab/store.py` |
| 005 | ingest and the perf-cron history import (legacy points: shown, never judged) | `scripts/perf-lab/ingest.py` |
| 006 | host checks and fingerprint | `scripts/perf-lab/host_env.py` |
| 007 | story catalog, the 12 targets, owners and lints | `scripts/perf-lab/catalog.py`, `scripts/perf-lab/stories.d/`, `scripts/perf-lab/targets.json` |
| 009 | bench builds from the tip harness and the build ledger | `scripts/measure/perf-lab-build.sh`, `scripts/perf-lab/builds.py` |
| 011 | scheduler: batches, tiers, shard map, roles | `scripts/perf-lab/scheduler.py`, `scripts/perf-lab/gen_shard_map.py`, `scripts/perf-lab/shard_map.json` |
| 012 | labd service, whois auth and pinned deploy | `scripts/perf-lab/labd.py`, `scripts/perf-lab/deploy.sh`, `scripts/perf-lab/com.cmux.perf-lab.plist` |
| 013 | dashboard (server-rendered SVG) | `scripts/perf-lab/dashboard.py` |
| 014 | subscriptions, alert groups, issues only for verified culprits | `scripts/perf-lab/alerts.py`, `scripts/perf-lab/subscriptions.json` |
| 015 | Pinpoint job core (pure) | `scripts/perf-lab/pinpoint.py` |
| 017 | culprit verification | `scripts/perf-lab/verify.py` |
| 019 | sheriff states, claims and the SLO report | `scripts/perf-lab/sheriff.py` |
| 022 | culprit attribution to a PR, author and session | `scripts/perf-lab/attribution.py` |
| 090 | feature registry and generator | `schemas/features/`, `scripts/cmux-next/gen-features.py` |
| 091 | app FeatureList | `Packages/macOS/CmuxNext/Sources/CmuxNextFeatures/` |
| 095 | daemon features | `cmux-tui/crates/cmux-features/` |
| 147 | `bench` without `CMUX_BLOCKING_CHECKS`, and `bench-checks` | `scripts/reload.sh` |
| 157 | traces of T0, bisect, verify and try attempts | `scripts/perf-lab/trace_quest.py` |
| 162 | `BenchApp.record` and the bench env | `scripts/cmux-next/bench_launch.py`, `scripts/perf-lab/bench_env.py` |
| 228 | a chromium and a webkit row for each browser target (F12) | `scripts/perf-lab/targets.json`, `scripts/perf-lab/stories.d/` |
| 235 | try admission and the general-fleet try pool | `scripts/perf-lab/try_admission.py` |
| 238 | agents cite lab try receipts | `skills/cmux-testing/SKILL.md`, `plans/cmux-next/AGENT-BRIEF.md`, `REVIEW.md` |

`scripts/perf-lab/lab.py` is the one command line. It finds each command in the `LAB_COMMANDS` dict of a sibling
module, so a task adds a command with its module and does not edit `lab.py`. Today only `catalog.py`, `ingest.py`,
`scheduler.py`, `gen_shard_map.py` and `trace_quest.py` declare it. Run the other modules (for example `sheriff.py`,
`alerts.py`, `builds.py` and `labd.py`) as `python3 -I scripts/perf-lab/<module>.py`.

Every other part in this file is the spec. The pool (`pool.json`, task 130), the controller pool (task 010), the
Pinpoint executor (task 016) and `lab.py try` (task 018) are not on the branch yet. Until task 026 lands and the sentinel
exists, the perf cron (`scripts/cmux-next/perf-cron.py`) still measures and reports.

## 15. Open decisions

Decisions D1 (labd host), D2 (kill switches between nightlies), D3 (sudo on lab hosts) and D4 (dedicated hosts) are
in section 8 of [chrome-parity/p12-perf-process.md](chrome-parity/p12-perf-process.md#8-risks-and-decisions), each
with its two options.
