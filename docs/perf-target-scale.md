# Target-scale resource regression benchmark

`scripts/perf-target-scale.py` is the reproducible benchmark for issue
[#9812](https://github.com/manaflow-ai/cmux/issues/9812).  It is deliberately
separate from the activation-timing benchmark: this fixture measures the
resources owned by the cmux app process after terminal surfaces settle.

## Fixture contract

Each requested size is run in a fresh, isolated tagged app instance.  The
benchmark creates exactly 1, 10, 100, or 200 terminal surfaces.  At most five
surfaces are selected (one selected tab in each of five panes); every remaining
surface is a hidden tab.  Every surface receives the same bounded scrollback
seed, then its PTY is left at an idle shell prompt.  The seed uses shell
builtins only; no coding agent, compiler, build, or long-lived child workload is
started.

After the seed settles, the collector records a first settled sample, reveals
and hides every hidden surface for 20 cycles, settles again, and records the
post-cycle sample.  CPU is sampled with `ps` for at least 30 seconds after the
second settle.  The app PID is resolved from the tag-specific debug socket, so
an unrelated cmux instance cannot be charged to the run.

Run locally (after building a tagged app) with:

```bash
python3 scripts/perf-target-scale.py \
  --tag perf-9812 \
  --app-path "$HOME/Library/Developer/Xcode/DerivedData/cmux-perf-9812/Build/Products/Debug/cmux DEV perf-9812.app" \
  --output perf-results/target-scale.json \
  --junit perf-results/target-scale.junit.xml
```

The hosted workflow is manual-only while variance is characterized:
`.github/workflows/perf-target-scale.yml`.  It builds the tagged app on the
selected hosted Mac, runs all four fixture sizes, and uploads the JSON and
JUnit artifacts.  The same command works on a developer Mac; it never selects
the untagged default socket.

## Collected metrics

The JSON artifact has schema version `1` and includes the benchmark/app
version, commit, hardware model, OS, fixture size, visible/hidden counts, and
effective scrollback bytes.  Each size records:

* app `phys_footprint` and the reported peak;
* Dirty Graphics, IOSurface, and IOAccelerator separately, plus a conservative
  retained-GPU total;
* mean/p95/max CPU as a percentage of one core, whole-machine-normalized CPU,
  sample count, duration, and logical-core count;
* total threads and stable role buckets (`main`, `display_link`, `renderer`,
  `pty_io`, `dispatch`, `io`, and `other`);
* first-settled and post-cycle snapshots; and
* descendant process count/RSS as `child_workload`.

Descendant RSS is reporting-only.  It is explicitly marked
`excluded_from_app_budgets` and is never added to app footprint or GPU totals.
If a required process diagnostic cannot be collected, the run fails rather
than emitting a guessed value.  Missing optional graphics categories are kept
as `null` and surfaced in `collector_warnings`.

## Initial guardrails

The checked-in defaults are intentionally generous and are represented in the
artifact so a hosted-runner calibration can be reviewed as data:

| Resource | Initial target |
| --- | --- |
| App footprint | `500 MiB + 3 MiB × hidden + 50 MiB × visible` |
| Retained GPU | `150 MiB + 50 MiB × visible` |
| Idle CPU | `10%` of one core at the 200-surface fixture |
| Hidden GPU slope | at most `0.25 MiB` per hidden terminal |
| Hidden CPU slope | at most `0.05` percentage points per hidden terminal |
| Reveal/hide soak | post-cycle footprint and GPU at most `1.10×` first settled |
| Threads | documented model: `32 + 4 × visible + 0.25 × hidden`; display-link role at most `2 + visible` |

Dirty Graphics can contain IOSurface and IOAccelerator on some macOS releases.
For the retained-GPU gate, the collector uses the larger of Dirty Graphics and
`IOSurface + IOAccelerator`, while retaining all three raw categories in the
artifact to avoid double-counting.

The slope checks are growth checks: a negative slope is not treated as a
regression.  A single-size run still checks absolute limits and soak, but does
not claim a slope.  The documented Ghostty thread model is intentionally
visible in the artifact; calibration should tighten it only after hosted-runner
variance is measured.

## Advisory-to-required transition

The default mode is advisory.  A budget failure is written to `evaluation` and
the artifact status becomes `advisory_failures`, but the command exits zero so
the first hosted runs can characterize variance.  Use `--enforce` for a gating
run; any budget failure then exits non-zero.  The workflow exposes this as its
`enforce` dispatch input.  Before making it required, compare several clean
runs on the same hosted hardware, record the chosen constants in the artifact,
and retain the invariants rather than tuning away a hidden-terminal slope.

The pure evaluator has deterministic fault injections for the acceptance
contract:

```bash
python3 scripts/perf-target-scale.py --self-test
```

The self-test requires a deliberate hidden-renderer leak to fail the GPU slope,
a hidden wakeup to fail the CPU slope, a retained allocation to fail the soak
bound, and a display-link leak to fail the thread model.  These tests run on
Linux/CI and do not pretend to be a measurement of a real app.
