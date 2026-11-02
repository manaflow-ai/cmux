#!/usr/bin/env python3
"""Play RESIZE VIDEOS suite cases on a mini the scheduler grants (one GO = one round = one lease).

  run_suite.py --spec SPEC --build JOB --kit CHECKOUT --out DIR CASE_ID [CASE_ID ...]

SPEC: the mini-scheduler lease-round spec (mini-queue/specs/SPEC.json, "priority": 8). Before each round this
waits for SPEC's GO file (mini-queue/rounds/SPEC.go), then runs CHECKOUT/scripts/journeys/run.py --build JOB
--whole-host --exclusive on the GO's mini only, inside the GO's window, with the round's case ids, and ends
the GO with SPEC.done. CHECKOUT must be a pinned (detached, clean) checkout that holds the kit and the case
files (run.py refuses results from an unpinned harness). Each round's output: DIR/round-NN/ (run.py's folder).
Cases are played --per-round at a time (default 1, the lease is 10 minutes). Standard library only.
"""
import argparse
import calendar
import json
import os
import subprocess
import sys
import time
from pathlib import Path

ROUNDS = Path(os.environ.get("RV_SCHED_ROUNDS", "/work/wt/chrome-parity-design/mini-queue/rounds"))
GO_MARGIN, GO_MIN_LEFT = 20, 60
OWNER_POOL = "perf-lead"


def utc(text):
    try:
        return calendar.timegm(time.strptime(str(text), "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, OverflowError):
        return None


def read_go(spec):
    try:
        d = json.loads((ROUNDS / f"{spec}.go").read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(d, dict):
        return None
    go, until = utc(d.get("go")), utc(d.get("until"))
    return {"host": d["host"], "go": go, "until": until} if d.get("host") and go and until else None


def go_done(spec, go, cell, status=None):
    """The .done that ends GO, only while GO is still the open one."""
    cur = read_go(spec)
    if not (cur and cur["go"] == go["go"] and cur["host"] == go["host"]):
        return False
    tmp = ROUNDS / f"{spec}.done.tmp"
    tmp.write_text(json.dumps({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "cell": cell,
                               **({"status": status} if status else {})}) + "\n")
    os.replace(tmp, ROUNDS / f"{spec}.done")
    return True


def await_go(spec, used, deadline, poll=5.0):
    while True:
        go = read_go(spec)
        if go and go["go"] not in used:
            left = go["until"] - time.time()
            if left >= GO_MIN_LEFT:
                return go
            if left > 0:
                print(f"GO for {go['host']} given back: {left:.0f} s left", flush=True)
                go_done(spec, go, "given back", "not run")
            used.add(go["go"])
        if time.time() > deadline:
            return None
        time.sleep(poll)


def window_env(until):
    budget = max(0, int(until - time.time()) - GO_MARGIN)
    acquire = max(1, budget // 2)
    return {"CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS": str(acquire),
            "CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS": str(max(0, budget - acquire)),
            "CAPTURE_HOST_DRAIN_SECONDS": str(min(acquire, 180))}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--kit", required=True, help="pinned checkout with scripts/journeys (kit + case files)")
    ap.add_argument("--out", required=True)
    ap.add_argument("--per-round", type=int, default=1)
    ap.add_argument("--wait-hours", type=float, default=3.0)
    ap.add_argument("--journey-option", action="append", default=[])
    ap.add_argument("cases", nargs="+")
    opts = ap.parse_args()
    out = Path(opts.out)
    out.mkdir(parents=True, exist_ok=True)
    runner = Path(opts.kit) / "scripts" / "journeys" / "run.py"
    if not runner.is_file():
        sys.exit(f"no run.py in {opts.kit}")
    groups = [opts.cases[i:i + opts.per_round] for i in range(0, len(opts.cases), opts.per_round)]
    used, deadline, summary = set(), time.time() + opts.wait_hours * 3600, []
    for n, group in enumerate(groups, 1):
        round_out = out / f"round-{n:02d}"
        go = await_go(opts.spec, used, deadline)
        if not go:
            summary.append({"round": n, "cases": group, "status": "not run", "reason": "no GO within the wait"})
            print(f"round {n}: no GO", flush=True)
            continue
        used.add(go["go"])
        print(f"round {n}: GO on {go['host']} until {time.strftime('%H:%M:%SZ', time.gmtime(go['until']))}: {group}", flush=True)
        env = {**os.environ, **window_env(go["until"]), "CAPTURE_HOST_POOL": OWNER_POOL,
               "CAPTURE_HOST_HOSTS": go["host"], "CAPTURE_HOST_SLOT_HOSTS": go["host"]}
        args = [sys.executable, str(runner), "--build", opts.build, "--whole-host", "--exclusive", "--hosts", go["host"],
                "--out", str(round_out)]
        for case in group:
            args += ["--journey", case]
        for option in opts.journey_option:
            args += ["--journey-option", option]
        started = time.time()
        done = subprocess.run(args, capture_output=True, text=True, env=env, cwd=opts.kit)
        round_out.mkdir(parents=True, exist_ok=True)
        (round_out / "run.log").write_text(done.stdout + done.stderr)
        rows = []
        try:
            rows = [json.loads(line) for line in (round_out / "results.jsonl").read_text().splitlines() if line.strip()]
        except (OSError, ValueError):
            pass
        status = "ran" if rows else "not run"
        go_done(opts.spec, go, f"round {n}", None if rows else "not run")
        summary.append({"round": n, "cases": group, "host": go["host"], "exit": done.returncode, "status": status,
                        "seconds": round(time.time() - started), "results": [{k: r.get(k) for k in ("id", "status", "reason")} for r in rows]})
        print(f"round {n}: exit {done.returncode}, {[(r.get('id'), r.get('status')) for r in rows]}", flush=True)
        (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n")
    (out / "summary.json").write_text(json.dumps(summary, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
