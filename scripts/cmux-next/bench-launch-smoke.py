#!/usr/bin/env python3
"""One short run of each bench that launches through bench_launch.py, against one tagged app: does each still launch,
reach its socket and take its first measurement. Not a perf number; the check of a launch-path change.

Each bench runs with its smallest settings, one after another, its output in OUT/<name>.log. One line per bench and
a BENCH-SMOKE summary; exit 0 when every bench exited 0.

Usage: bench-launch-smoke.py --app APP --out DIR [--json PATH] [--only name,name]
Fleet: scripts/measure/split-spring.sh --suite=bench-smoke
"""
import argparse, json, os, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--tag")
parser.add_argument("--only", default="")
opts, _unknown = parser.parse_known_args()

sys.path.insert(0, HERE)
from bench_launch import account_home, bundle_id, tag_of  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

TAG = opts.tag or tag_of(opts.app)


def bench(name, script, *args, json_flag=True):
    out = os.path.join(opts.out, name)
    report = ["--json", os.path.join(out, "report.json")] if json_flag else []
    return name, [sys.executable, os.path.join(HERE, script), "--tag", TAG, "--app", opts.app, "--out", out, *report, *args]


BENCHES = [
    bench("launch-check", "split-spring-terminal.py", "--suite=launch-check"),
    bench("split-spring", "split-spring-terminal.py", "--rounds", "1", "--presses", "2", "--directions", "right"),
    bench("app-perf", "app-perf.py", "--workspaces", "10", "--scenarios", "split-right", "--rounds", "1"),
    bench("anim-perf", "anim-perf-terminal.py", "--anims", "tab-new", "--rounds", "1"),
    bench("every-action", "every-action-sweep.py", "--sessions", "light", "--repeat", "1", "--limit", "3", "--no-interactions"),
    bench("tab-switch-stages", "tab-switch-stages.py", "--rounds", "1"),
    bench("palette-open-stages", "palette-open-stages.py", "--rounds", "1", "--no-gate"),
    bench("omnibar-click", "omnibar-click-bench.py", "--runs", "2", "--engines", "webkit"),
    bench("open-panel", "open-panel-bench.py", "--sessions", "light", "--rounds", "2"),
    bench("tab-switch-matrix", "tab-switch-matrix.py", "--kinds", "terminal", "--counts", "3", "--switches", "5"),
    bench("sidebar-stress", "sidebar-stress-bench.py", "--sizes", "20", "--stop", "--tickers", "2", "--scenarios", "ticks", "--no-trace", json_flag=False),
    bench("agent-engine", "agent-engine-bench.py", "--modes", "own", "--chats", "1", "--flings", "1"),
    bench("instant-new-surfaces", "instant-new-surfaces-bench.py", "--runs", "1"),
    bench("typing-frame", "typing-frame-bench.py", "--sessions", "light", "--rounds", "1", "--samples", "10",
          "--surfaces", "terminal,home", "--phases", "idle"),
    bench("sidebar-churn", "sidebar-churn-typing.py", "--workspaces", "10", "--groups", "2", "--samples", "10"),
    bench("bench-idle", "bench_idle.py", "--scenarios", "terminals", "--settle", "2", "--measure", "5", "--no-fail", json_flag=False),
]


def fresh_state():
    """Each bench starts as on its own fleet step: the tag's processes ended (exact PIDs of the bundle) and its saved
    sessions gone (daemon state, sidebar snapshot, agent sessions, Home's memory), so one bench's workspaces never
    restore into the next."""
    TagTeardown(opts.app, log=lambda _line: None).end()
    import shutil
    bundle = bundle_id(opts.app) or ""
    for home in {account_home(), os.path.expanduser("~")}:
        for folder in (os.path.join(home, "Library/Application Support/cmux/tags", TAG),
                       os.path.join(home, ".acpmux/builds", bundle), os.path.join(home, ".cmux/mux/tags", TAG)):
            if bundle and os.path.isdir(folder):
                shutil.rmtree(folder, ignore_errors=True)


def main():
    os.makedirs(opts.out, exist_ok=True)
    wanted = set(filter(None, opts.only.split(",")))
    results = []
    for name, argv in BENCHES:
        if wanted and name not in wanted:
            continue
        os.makedirs(os.path.join(opts.out, name), exist_ok=True)
        fresh_state()
        log_path = os.path.join(opts.out, f"{name}.log")
        start = time.monotonic()
        with open(log_path, "w") as log:
            try:
                code = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, timeout=900).returncode
            except subprocess.TimeoutExpired:
                code = 124
        text = open(log_path, errors="replace").read()
        launched = next((l for l in text.splitlines() if l.startswith("BENCH-LAUNCH ") or "answered on" in l), None)
        row = {"bench": name, "exit": code, "seconds": round(time.monotonic() - start, 1), "launch": launched}
        results.append(row)
        print(f"{'ok  ' if code == 0 else 'FAIL'} {name}: exit {code} in {row['seconds']} s; {launched or 'no launch line'}",
              flush=True)
        if code != 0:
            print("\n".join("    " + l for l in text.splitlines()[-25:]), flush=True)
    summary = {"tag": TAG, "passed": sum(r["exit"] == 0 for r in results), "ran": len(results), "benches": results}
    print("BENCH-SMOKE " + json.dumps(summary), flush=True)
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump(summary, f, indent=1)
    return 0 if results and all(r["exit"] == 0 for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
