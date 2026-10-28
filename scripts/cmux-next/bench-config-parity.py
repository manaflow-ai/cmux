#!/usr/bin/env python3
"""Is a bench build as fast as Release? Same actions, same host, interleaved runs.

A bench build (`scripts/reload.sh --config bench`: Release optimization with `-DCMUX_BENCH_HOOKS
-DCMUX_BLOCKING_CHECKS`, scripts/cmux-next/lib/bench-swift-defines.sh) keeps the debug.* control commands
the fleet benches drive and the main-thread blocking detector (record only, as a Nightly has it), so it
is not byte-for-byte the shipped Release app. This compares it with a Release build of the same commit on what both builds have:

  * the always-on action signposts (`action.perform`, `action.commit`; CmuxNextSignposts), for the
    same actions run through `action.run` (a normal socket method): --rounds of newTab + closeTab
    and splitRight + closeTab per launch;
  * the app process's CPU time over --idle seconds of idle after a settle (ps cputime).

Runs alternate (Release, bench, Release, bench, ...) --runs times each, each a fresh launch through
bench_launch.BenchApp (the lab's bench env, a scratch config), so drift on the host hits both builds alike.
The verdict per row: the difference of the two medians (perf_stats.pct, the lab's one percentile) against
the larger run-to-run spread (max - min of the per-run values) of either build; within noise when
|diff| <= spread (or <= 0.05 ms for sub-0.1 ms rows). Each run's rows carry p50, p95 and p99.

The parity story (`--story bench-parity`, p12-perf-process.md 3.2 and done check 4): each interleaved pair
gives one sample of `bench_parity.action_commit_delta_pct`, 100 * (bench - release) / release of the two runs'
action.commit p50 over every action, written as cmux-perf-result/v1 through the Release arm's BenchApp.record
(config release, the story's); done check 4 judges the series' p50 (its max_parity_delta_pct). It records
only when both bundles name the same commit, every run lost no signpost and ran every action, and every pair
has action.commit runs; otherwise it writes nothing and exits 1. Chrome measures its reference build in the same job, on the same
device, for the same reason (`run_reference_build`, tools/perf/core/bot_platforms.py; telemetry's
`--browser=reference`).

Usage (a fleet GUI host, never a laptop):
  bench-config-parity.py --release APP --bench APP [--runs 3] [--rounds 20] [--idle 30] [--out DIR]
      [--story bench-parity]
  --app is the same as --release, so the story runner's `--app --tag --out` parse. The runner does not yet
  build or fetch a Release artifact or pass a second build as --bench, so the lab catalog marks the story
  not measurable (stories.d/bench-parity.json `not_measurable`) and plans no round for it. Run it by hand
  on a fleet GUI host with both builds of one commit.
"""

import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)  # bench_launch under `python3 -I` too
import bench_launch  # noqa: E402
from bench_launch import PERF_LAB, BenchApp, load_by_path  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
signposts = load_by_path("perf_signposts", os.path.join(HERE, "perf-signposts.py"))

KINDS = ("release", "bench")
ACTIONS = ("newTab", "closeTab", "splitRight", "closeTab")
SIGNPOST_NAMES = ("action.perform", "action.commit")
SIGNPOST_DETAILS = ("newTab", "closeTab", "splitRight", "*")
STATS = ("p50", "p95", "p99")
PARITY_STORY = "bench-parity"
PARITY_METRIC = "bench_parity.action_commit_delta_pct"
PARITY_ROW = "action.commit *"
SUB_MS_FLOOR = 0.05


def cpu_seconds(pid):
    """The process's CPU time (ps cputime) in seconds, or None when it is gone."""
    out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    seconds = 0.0
    for part in out.replace("-", ":").split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def scenario(app, rounds):
    """Runs the actions through the app's action.run; returns the errors (at most 20 kept) and their count."""
    errors = []
    count = 0
    for _ in range(rounds):
        for action in ACTIONS:
            reply = app.rpc("action.run", {"action": action})
            if isinstance(reply, dict) and reply.get("error"):
                count += 1
                if len(errors) < 20:
                    errors.append({"action": action, "error": reply["error"]})
            time.sleep(0.05)  # spacing between presses, as a person types; not a wait for a condition
    return {"errors": errors, "error_count": count}


def run_rows(intervals):
    """{"<name> <detail>": {n, p50, p95, p99}} of the action signposts (perf-signposts summarize: perf_stats)."""
    rows = {(r["name"], r["detail"]): r for r in signposts.summarize(intervals)}
    out = {}
    for name in SIGNPOST_NAMES:
        for detail in SIGNPOST_DETAILS:
            row = rows.get((name, detail))
            if row:
                out[f"{name} {detail}"] = {"n": row["count"], "p50": row["p50_ms"], "p95": row["p95_ms"],
                                           "p99": row["p99_ms"]}
    return out


def make_apps(opts):
    """{kind: BenchApp}: one per arm for every run of it (one teardown, one perf_result.Run), in --out."""
    configs = {"release": "release", "bench": "bench"}
    apps = {}
    for kind, bundle in (("release", opts.release), ("bench", opts.bench)):
        app = BenchApp(bundle, out=opts.out, build_config=configs[kind], log_name=f"app-{kind}.log")
        # The lean bench, never bench-checks: its blocking detector is not in the shipped app (task 147).
        bench_launch.build_config(app.app, app.binary, configs[kind])
        apps[kind] = app
    if apps["release"].tag == apps["bench"].tag:
        raise SystemExit(f"bench-config-parity: both bundles are tag {apps['bench'].tag}; their sockets and saved "
                         "state would collide: build them under two tags")
    return apps


def same_commit(apps):
    """The commit both bundles name, or a RecordError saying why there is none."""
    shas = {kind: bench_launch.build_sha(app.app) for kind, app in apps.items()}
    if shas["release"] != shas["bench"]:
        raise bench_launch.RecordError(f"bench-config-parity: release is {shas['release']}, bench is {shas['bench']}: "
                                       "parity compares two builds of one commit")
    return shas["release"]


def stop(app):
    """Quits the launched app (app.quit: a Release build answers no debug.*), then BenchApp.stop (TERM of its own
    PID if it did not exit, and the tag's daemons)."""
    if app.process is not None and app.process.poll() is None:
        app.rpc("app.quit", {}, timeout=10)
        try:
            app.process.wait(30)
        except subprocess.TimeoutExpired:
            pass  # BenchApp.stop ends it
    app.stop()


def one_run(kind, app, opts, index):
    out = os.path.join(opts.out, f"{kind}-{index}")
    os.makedirs(out, exist_ok=True)
    def spawned(_process):
        if app.teardown:
            app.teardown.remember()  # one teardown for every launch of this bundle, armed at this one's spawn

    try:
        # A Release build answers no debug.*: both arms are ready at the same answer. Inside the try, so a launch
        # that fails after its spawn is still stopped.
        app.launch(ready="system.ping", on_start=spawned)
        pid = app.process.pid
        time.sleep(opts.settle)  # the measured settle after launch (launch work done), not a poll
        cpu0 = cpu_seconds(pid)
        time.sleep(opts.idle)  # the idle window itself
        cpu1 = cpu_seconds(pid)
        recording = signposts.Recording(pid, ["action"])
        try:
            scen = scenario(app, opts.rounds)
        finally:
            lines = recording.stop()
        with open(os.path.join(out, "run.ndjson"), "w") as f:
            f.write("\n".join(lines) + "\n")
        with open(os.path.join(out, "scenario.json"), "w") as f:
            json.dump(scen, f)
        parsed = signposts.parse(lines, None)  # the header line carries the timebase
        idle_pct = None if cpu0 is None or cpu1 is None else round(100 * (cpu1 - cpu0) / opts.idle, 3)
        result = {"kind": kind, "run": index, "idle_cpu_pct": idle_pct, "lost": parsed["lost"],
                  "action_errors": scen["error_count"], "rows": run_rows(parsed["intervals"])}
        print("PARITY-RUN " + json.dumps(result), flush=True)
        return result
    finally:
        stop(app)


def verdict(runs):
    """(table, ok): per metric the two builds' per-run values, their medians and spread, and within_noise."""
    table, ok = [], True
    keys = sorted({k for r in runs for k in r["rows"]})
    metrics = [("idle_cpu_pct", None)] + [(k, stat) for stat in STATS for k in keys]
    for key, stat in metrics:
        per = {}
        for kind in KINDS:
            values = [r[key] if stat is None else r["rows"].get(key, {}).get(stat) for r in runs if r["kind"] == kind]
            per[kind] = [v for v in values if v is not None]
        if not per["release"] or not per["bench"]:
            continue
        med = {k: perf_stats.pct(v, 0.50) for k, v in per.items()}
        spread = max(max(v) - min(v) for v in per.values())
        diff = med["bench"] - med["release"]
        within = abs(diff) <= max(spread, SUB_MS_FLOOR)
        ok &= within
        table.append({"metric": key if stat is None else f"{key} {stat}", "release": per["release"], "bench": per["bench"],
                      "median_release": round(med["release"], 3), "median_bench": round(med["bench"], 3),
                      "diff": round(diff, 3), "spread": round(spread, 3), "within_noise": within})
    return table, ok


def parity_deltas(runs):
    """(deltas, problems): one `bench_parity.action_commit_delta_pct` sample per interleaved pair, and why the runs
    are not a fair parity sample (lost signposts, failed actions, a pair with no action.commit)."""
    problems, deltas = [], []
    for r in runs:
        if r["lost"]:
            problems.append(f"{r['kind']} run {r['run']}: log stream lost messages {r['lost']} time(s)")
        if r["action_errors"]:
            problems.append(f"{r['kind']} run {r['run']}: {r['action_errors']} action.run error(s)")
    by_run = {}
    for r in runs:
        by_run.setdefault(r["run"], {})[r["kind"]] = r
    for index in sorted(by_run):
        pair = by_run[index]
        p50 = {kind: pair.get(kind, {}).get("rows", {}).get(PARITY_ROW, {}).get("p50") for kind in KINDS}
        if None in p50.values() or not p50["release"]:
            problems.append(f"run {index}: no {PARITY_ROW} p50 in both builds ({p50})")
            continue
        deltas.append(round(100 * (p50["bench"] - p50["release"]) / p50["release"], 3))
    return deltas, problems


def record_parity(app, story, runs):
    """Writes the parity samples through the Release arm's BenchApp; returns (path or "not recorded: ...", ok)."""
    deltas, problems = parity_deltas(runs)
    if problems:
        return "not recorded: " + "; ".join(problems), False
    try:
        return str(app.record(story, PARITY_METRIC, "percent", deltas, better="lower", engine="none")), True
    except bench_launch.RecordError as error:
        return f"not recorded: {error}", False


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--release", "--app", dest="release",
                        help="the Release build (the story runner's --app: the story's config)")
    parser.add_argument("--bench", help="the `--config bench` build of the same commit")
    parser.add_argument("--tag", help="the story runner's; each bundle names its own tag")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--rounds", type=int, default=20)
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--idle", type=float, default=30)
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/bench-config-parity")
    parser.add_argument("--story", help=f"write the parity series as cmux-perf-result/v1 under this story "
                                        f"({PARITY_STORY})")
    opts = parser.parse_args(argv)
    if not (opts.release and opts.bench):
        parser.error("--release (or --app) and --bench are required")
    return opts


def main(argv=None):
    opts = parse_args(argv)
    opts.out = os.path.abspath(opts.out)
    os.makedirs(opts.out, exist_ok=True)
    try:
        apps = make_apps(opts)
        if opts.story:
            same_commit(apps)  # refuses before any launch: a cross-commit delta is no parity point
    except bench_launch.RecordError as error:
        raise SystemExit(str(error)) from error
    runs = []
    for index in range(opts.runs):
        for kind in KINDS:
            runs.append(one_run(kind, apps[kind], opts, index))
    table, ok = verdict(runs)
    deltas, problems = parity_deltas(runs)
    report = {"host": os.uname().nodename, "runs": runs, "table": table, "within_noise": ok,
              "action_commit_delta_pct": deltas, "parity_problems": problems}
    recorded = True
    if opts.story:
        report["result"], recorded = record_parity(apps["release"], opts.story, runs)
    with open(os.path.join(opts.out, "parity.json"), "w") as f:
        json.dump(report, f, indent=1)
    print(f"{'metric':42} {'release med':>11} {'bench med':>10} {'diff':>8} {'spread':>8}  verdict")
    for row in table:
        print(f"{row['metric']:42} {row['median_release']:11.3f} {row['median_bench']:10.3f} {row['diff']:8.3f} "
              f"{row['spread']:8.3f}  {'ok' if row['within_noise'] else 'OUTSIDE NOISE'}")
    print(f"action.commit delta per pair (%): {deltas}" + (f"; problems: {problems}" if problems else ""))
    if opts.story:
        print(f"bench-config-parity: result-v1 {PARITY_METRIC}: {report['result']}")
    print("BENCH-CONFIG-PARITY " + json.dumps({"within_noise": ok, "table": table, "action_commit_delta_pct": deltas}),
          flush=True)
    return 0 if ok and recorded else 1


if __name__ == "__main__":
    sys.exit(main())
