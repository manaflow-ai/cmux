# SCHEDULER_LIVE: the end of the MVP tick

The lab scheduler is not live yet. Until it is, `mvp_tick.py` measures one
bench baseline at a time on one measure host, so the other programs have
baselines early (p12-perf-process-161, hours 6 to 12 of the plan).

When the scheduler takes over, its landing commit adds the empty file
`scripts/perf-lab/SCHEDULER_LIVE`. The MVP loop reads the tip of its branch
before each new step. When the file is at that tip (or in the loop's own
checkout), the loop does not submit again: it finishes the step in flight,
stores its results and exits 0. No controller or workflow change is needed
to stop it, the same as `scripts/perf-lab/OWNS_MEASUREMENT` stops the perf
cron (p12-perf-process-026).

## What one tick does

1. `git fetch` the newest commit of `feat-cmux-next` (the controller runs
   `scripts/measure/split-spring.sh` only at the blob reviewed at that tip).
2. Submit one step at background priority, on the measure host only:

   ```
   cmux-ci run --class exclusive --background --measurement --label bench --label measure \
     --target-worker cmux20-bench --no-supersede --script scripts/measure/split-spring.sh \
     --ref SHA --key perf-lab-mvp-SHA12-TIME --artifact artifacts/split-spring/report.json \
     --timeout 3600 --arg=--config=bench --arg=--vdisplay=120
   ```

   The step builds an optimized bench app, opens it on a 120 Hz virtual
   display, and presses Cmd-D (then Cmd-Shift-D) five times, 100 ms apart, in
   3 rounds.
3. When the step ends, take its `report.json` and write it as
   `cmux-perf-result/v1` into `STATE/results/`:
   - story `split-spring.right` and `split-spring.down` (one per direction),
   - one result per report key (`frames_p50_ms` ... `hangs`, the names as
     they are), with one raw sample per round,
   - build `{sha, config: bench, measure_version: SPLIT_SPRING_MEASURE_VERSION at SHA}`,
   - host block from `bench_launch.host_record`: the fingerprint and the
     series host class (chip / memory / Hz) are the same as for rows that
     `BenchApp.record` writes on that host,
   - run id = the controller step id.
4. Run `lab.py ingest --kind waterfall --host-name cmux20-bench` on the new
   file. The store keys each point by its build sha and each series by its
   host class. While `lab.py` is not in the checkout, the result is kept as
   `pending`. A later `lab.py ingest --db DB STATE/results` stores it. The
   ingest is idempotent.
5. Start the next tick at once. Wait 300 s first only when no step could
   start (no newer tip after a failed one, the host is gone, or the
   controller did not answer).

A step that fails marks its commit: the loop does not submit that commit
again and waits for a newer tip. A cancelled step is submitted again.
After a restart the loop finds the step in flight (`STATE/state.json` keeps
its key, `STATE/steps/KEY.log` its id) and waits for it. It never submits a
second step for it.

## Host facts

The step's report gives only the macOS version and the display refresh. Read
the other facts once on the measure host and keep them in a JSON file on the
Mac that runs the loop:

```
ssh cmux20-bench 'sysctl -n machdep.cpu.brand_string hw.memsize; sw_vers -productVersion; sw_vers -buildVersion'
```

```json
{"cmux20-bench": {"chip": "Apple M4", "memory_bytes": 17179869184, "macos": "27.0", "macos_build": "27A123"}}
```

Use the real values from the command. Do not copy the example values. When
the report's macOS version is not the one in the file (an OS update), the
loop stops with exit 1 and stores nothing. Read the facts again and restart
the loop.

## Run it

On cmux-lawrence, in a full (not shallow) checkout:

```
nohup nice -n 10 python3 -I scripts/perf-lab/mvp_tick.py run \
  --db ~/perf-lab/lab.sqlite3 --state-dir ~/perf-lab/mvp-tick \
  --host-facts ~/perf-lab/host-facts.json --worker cmux20-bench \
  >> ~/perf-lab/mvp-tick/loop.log 2>&1 &
```

- `--max-ticks 3` stops after 3 ended steps (the test phase: 3 ticks in a
  row on cmux20-bench, each with stored results).
- `STATE/state.json` keeps the last ticks: sha, step id, state (`stored`,
  `failed`, `unconverted`, `refused`), the result file and the ingest
  report.
- `python3 -I scripts/perf-lab/mvp_tick.py convert --report R --job J
  --host-facts F --measure-version N --out DIR` converts one report by hand
  (`J` is the output of `cmux-ci status ID`).
- To stop it before the scheduler lands, end the process. Or create
  `scripts/perf-lab/SCHEDULER_LIVE` in the loop's checkout; the loop then
  stops before its next submission.

Tests: `python3 -m unittest scripts/perf-lab/tests/test_mvp_tick.py`.
