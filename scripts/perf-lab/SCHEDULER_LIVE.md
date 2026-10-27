# SCHEDULER_LIVE: the end of the MVP tick

`scripts/perf-lab/SCHEDULER_LIVE` (no extension) is the sentinel that stops the MVP tick
(`scripts/perf-lab/mvp_tick.py`, task p12-perf-process-161). This file only explains it; it is
not the sentinel, so it stops nothing.

## What the MVP tick does until then

Until the scheduler (`scheduler.py`) and labd run the waterfall, one loop on cmux-lawrence gives the
other programs bench baselines (p12-perf-process.md 5, hours 6 to 12). Each tick:

1. Fetches the measured branch (default `feat-cmux-next`). It takes the newest first-parent commit
   that has a published cmux-tui tree, the same rule as the perf cron.
2. Runs one step on cmux20-bench and waits for it to end:
   `cmux-ci run --class exclusive --measurement --background --label bench --label measure
   --target-worker cmux20-bench --script scripts/measure/split-spring.sh --ref SHA
   --arg=--config=bench --arg=--vdisplay=120`.
3. Gets the step's `report.json`. It turns the gestures into cmux-perf-result/v1
   (`split_spring.<right|down>.{frame,missed,resizes_sent}`, story `split-spring`) and ingests them
   as waterfall runs. The rows are keyed by sha and host class.

The next tick starts when the step ends. A tip that did not move is measured again, which adds
samples to that commit. A commit whose step ran and failed twice is skipped. A tick that started
no step (the client could not run, or the controller refused or was not reachable) is a
`fleet-error`: it counts against no commit, and the loop waits 5 minutes. A git, client or lab
database error is a recorded tick with its reason; the loop does not stop. No controller or
workflow changes.

## Run it on cmux-lawrence

```bash
cd ~/fun/cmux-lab   # a checkout of perf/chrome-parity (the lab code); not shallow
export CMUX_PERF_LAB_DB=~/.local/share/cmux-perf-lab/lab.sqlite3
nohup taskpolicy -b python3 -I scripts/perf-lab/lab.py mvp-loop > ~/.local/share/cmux-perf-lab/mvp-loop.log 2>&1 &
python3 -I scripts/perf-lab/lab.py mvp-status            # the last 20 ticks
python3 -I scripts/perf-lab/lab.py mvp-status --require 3 # exit 0: the last 3 measured ticks stored results
```

The loop also lowers its own CPU priority (`nice` 10). The state, each step's log, report and
result files are in `~/.local/share/cmux-perf-lab/mvp-tick` (`--state-dir` or
`$CMUX_PERF_LAB_MVP_DIR`). One loop holds the lock of a state directory at a time. A restarted loop
resubmits the pending step with the same idempotency key, which attaches to the step that is
already queued.

## Stop it

Commit an empty `scripts/perf-lab/SCHEDULER_LIVE` when the scheduler measures T0 on its own. The
loop stops at its next tick when the file is in its own checkout, on `origin/perf/chrome-parity`
(`--live-ref`, repeatable) or on the measured branch. It checks before every tick, never during a
step, so the step that is running ends first. To stop it at once, kill the loop. The step that is
running continues; cancel it with `cmux-ci cancel STEP_ID` (the ID is in `mvp-status`).

## What the converted rows know

- **Host class.** Chip and memory come from `pool.json`. The Hz is 120 or 60: the lab's rule
  (`host_env.hz_for`) applied to the measured interval (`display.refresh_ms`). Display jitter does not
  change the series, and a run that fell back to a 60 Hz display goes into a 60 Hz series. A display
  slower than 60 Hz is not recorded.
- **Fingerprint.** It is the tick's own, because `report.json` names no macOS build.
- **Features.** They are empty, because the bench at the tip writes no features snapshot.
- **measure_version.** It is the measured `split-spring.sh`'s `SPLIT_SPRING_MEASURE_VERSION`.
- **Frame series.** A tip whose bench sends no raw frame intervals stores only `missed` and
  `resizes_sent`. The tick records the frame series as skipped.
