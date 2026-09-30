# cx-ci-failfast

Measurement window: 2026-09-25 through 2026-09-30 UTC. The baseline is the
read-only Actions and owned-mini sample from `cx-ci-regime.report.md`, hq #1078,
and `/Users/leoli/Projects/.tmp-ci-regime/mini/*.jsonl`.

## Baseline and attribution

The baseline contains 176 sampled failed or cancelled runs and 794 jobs that
continued after the first decisive failure or cancellation. They consumed
272,613 seconds, or **75.7 runner-hours per seven days (648 runner-minutes per
day)**: 43.0 hours after failed runs and 32.7 hours after cancelled runs.

The cancelled-run sample does not point to a glaeda-only process-tree failure.
In a representative superseded run, a glaeda compile continued for about five
minutes after the newer SHA was created and the run's cancellation guard had
fired. Other samples contained an 11.3-minute Blacksmith compile and a
12.6-minute glaeda compile after cancellation. The broader superseded sample
was 602.9 runner-minutes: 431.9 on Blacksmith and 169.9 on owned minis. The
runner hook's cleanup path has no separate cancellation bug; Runner.Worker is
responsible for killing the process tree. The cause is therefore the Actions
workflow graph and cancellation propagation, with occasional slow signal
handling, rather than a fleet-wide glaeda hook defect. No glaeda deployment was
made.

The existing `always()` rollups were another source of post-cancel work. The
change updates the CI, guard, macOS, and web rollups to `!cancelled()`: they
still report a failed dependency, but do not allocate a runner after a run has
been cancelled. Cleanup steps remain `always()` where they release resources.

The process-level fix is cooperative and applies to both self-hosted and
hosted runners: `run_with_timeout.py` now handles the runner's SIGINT/SIGTERM,
walks detached descendants, and escalates to SIGKILL within the cancellation
grace period. `xcodebuild_noninteractive.py` uses the same tree cleanup for
detached XCTest app hosts. Focused regressions cover a child in a new process
group and a stubborn child that ignores the first signal. This removes leaked
test processes without cancelling sibling jobs.

## Changes in this PR

GitHub's Actions REST API only cancels a whole run, so a watcher cannot cancel
one downstream job without also hiding independent sibling failures. The PR
therefore relies on the existing dependency DAG: compile consumers already
require a successful producer and skip when it fails, while independent guard,
package, and test jobs continue. The CI, guard, macOS, and web rollups now use
`!cancelled()`: they still report a failed dependency, but do not allocate a
runner after a run has been cancelled. No PR skip runs or new write permissions
are introduced, preserving the lessons from #13475 and #13476.

The add-on's long-tail sample was also folded into the job ceilings:

| job | p50 | p99 | max | new ceiling |
| --- | ---: | ---: | ---: | ---: |
| app-host-unit-tests | 6.5m | 31.5m | 54.8m | 60m |
| swift-package-tests | 2.4m | 15.2m | 60.2m | 60m (retained; full suite is serial) |
| ios-simulator | 2.3m | 14.1m | 15.9m | 25m |
| cli-product-tests | 2.9m | 19.2m | 40.6m | 40m |
| test (E2E) | 3.9m | 19.5m | 45.6m | 45m |
| tests-build-and-lag | 3.6m | 25.7m | 29.1m | 75m (retained; build lane) |
| release-build | 18.1m | 64.2m | 65.1m | 60m |

The Swift package, CLI, E2E, tests-build-and-lag, and release ceilings were left
at their existing values because the package lane is serial and the other
observed maxima reach the current budget or represent legitimate long builds.
The package lane already applies a 900-second per-package total and no-progress
watchdog. App-host shards already use a 1,800-second test watchdog,
1,200-second xcodebuild idle timeout, restart budget, and post-test timeout.
iOS package and simulator steps already use `hung_test_watchdog.py`. The new
job ceilings bound setup, teardown, and a host that stops making progress
without duplicating those watchdogs.

The longest app-host record spent 50 minutes downloading its product and only
3.2 minutes running tests; the longest CLI record spent 25.7 minutes in the
download path, and the longest E2E fallback spent 38 minutes downloading. The
parallel transport is already attempted first. A new fixed fallback timeout
was not added because artifact size and slow-host percentiles are not yet
measured; an arbitrary ceiling could turn a slow but valid transfer into a
false failure. These waits are the next instrumentation target.

## GUI, telemetry, and host side findings

App-host jobs held the GUI token in 3,235 of 3,279 mini records, with a 6.5
minute median while the whole mini used only about 36% CPU. The scarce resource
is the desktop session, so fixed sleeps, app launch, polling, and XCTest setup
are the next profiling targets. The current patch bounds their tail but does
not guess at a safe redesign without per-step timings.

The mini job record's process tree omits the launched `cmux DEV` test app, so
job CPU is undercounted at roughly 0.15 cores. The glaeda hook should attribute
the launched app to its owning job in a follow-up telemetry change; this PR
does not change runner accounting while cancellation behavior is being fixed.

Over five days, `fseventsd` used about 68 hours and `XprotectService` about 33
hours alongside tests. Spotlight and XProtect exclusions need a separate
security and fleet review; this PR makes no speculative host-wide exclusions.

## Savings measurement

The pre-change opportunity is **648 runner-minutes/day**. The post-change
measurement is recorded here after the dependency and timeout changes have
completed a full observation interval; it will report the interval, run count,
cancelled-run tail minutes, timeout reductions, and resulting runner-hours/day.
A short interval is reported as such rather than extrapolated to seven days.

Validation before publication: `actionlint` on all edited workflows,
`python3 tests/test_ci_workflow_run_sources.py`, the focused CI policy tests,
`git diff --check`, and `python3 scripts/verify-local.py` (15/16 selected
checks; native compilation intentionally skipped).
