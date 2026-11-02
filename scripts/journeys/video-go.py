#!/usr/bin/env python3
"""One video round per mini-scheduler GO (handoff resize-videos/KIT.md).

  video-go.py --spec NAME --build JOB --journey ID [--journey ID ...] --label BUILD_LABEL [--rounds 1]
              [--publish /Users/lawrence/fun/wt/handoff/resize-videos]

Waits for the scheduler's GO of spec NAME (mini-queue/rounds/NAME.go: a whole M6 mini, never cmux16), runs
`run.py --build JOB --journey ID --whole-host --exclusive --hosts <the GO's mini>` for one lease, writes NAME.done,
then copies each recording (<journey>/video/<case>.*) to PUBLISH/<BUILD_LABEL>/<case>.* (read-only) and the run's
results beside it. Exit 0 when every round ran (pass or fail), 75 when a round did not run.
Set CMUX_AGENT_ID first (fleet-rules: capture leases carry their owner).
"""
import argparse
import json
import os
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("smoke_gate", HERE / "smoke-gate.py")
gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate)

MINIS = ("cmux17", "cmux18", "cmux19", "cmux20", "cmux21", "cmux22", "cmux23", "cmux24")
SUFFIXES = (".mov", ".mov.frames.json", ".mov.scan", ".trace.json", ".events.json", ".meta.json")


def publish(run_out, label, dest_root, journey_ids):
    """Copies the recordings of RUN_OUT to DEST_ROOT/LABEL/<case>.*, read-only. Returns the case names."""
    dest = Path(dest_root) / label
    dest.mkdir(parents=True, exist_ok=True)
    cases = []
    for jid in journey_ids:
        vdir = Path(run_out) / jid / "video"
        if not vdir.is_dir():
            continue
        for path in sorted(vdir.iterdir()):
            if not path.is_file() or not path.name.endswith(SUFFIXES):
                continue
            target = dest / path.name
            if target.exists():
                target.chmod(stat.S_IWUSR | stat.S_IRUSR)
                target.unlink()
            shutil.copy2(path, target)
            target.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)
            if path.name.endswith(".mov"):
                cases.append(path.name[:-4])
        result = Path(run_out) / jid / "result.json"
        if result.is_file():
            shutil.copy2(result, dest / f"{jid}.result.json")
    return cases


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--journey", action="append", required=True)
    ap.add_argument("--label", required=True, help="the folder name under PUBLISH (the build's name)")
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--hog-swap-gb", type=float, default=0.0, help="run.py --hog-swap-gb (the 15 GB memory hog case)")
    ap.add_argument("--spec-file", help="a lease-round spec JSON to hand to the mini scheduler once the build is done")
    ap.add_argument("--vdisplay", default="120x1", help="HZxSCALE of the lease's own main display (run.py --vdisplay); "
                    "'none' keeps the mini's own 60 Hz display (geometry only, never pacing evidence)")
    ap.add_argument("--publish", default="/Users/lawrence/fun/wt/handoff/resize-videos")
    ap.add_argument("--out", default="/work/tmp/resize-videos/runs")
    ap.add_argument("--go-wait-hours", type=float, default=6)
    opts = ap.parse_args()
    if not os.environ.get("CMUX_AGENT_ID"):
        ap.error("export CMUX_AGENT_ID first (capture leases carry their owner)")
    # The build first: a GO is a mini held for this round now, never while the build still runs (the scheduler
    # withdraws a GO with no lease after 240 s). A wait timeout leaves the job running: wait again, never resubmit.
    while True:
        state = json.loads(subprocess.run(["cmux-ci", "status", opts.build], capture_output=True, text=True).stdout or "{}").get("state")
        if state == "done":
            break
        if state in ("failed", "cancelled", "superseded"):
            print(f"build {opts.build} is {state}: no round", flush=True)
            return 75
        subprocess.run(["cmux-ci", "wait", opts.build], capture_output=True)
        time.sleep(20)
    if opts.spec_file:
        # The lease-round spec goes to the scheduler only now that the build is done.
        specs = gate.SCHED_ROUNDS.parent / "specs"
        shutil.copy2(opts.spec_file, specs / f"{opts.spec}.json.tmp")
        os.replace(specs / f"{opts.spec}.json.tmp", specs / f"{opts.spec}.json")
        print(f"spec {opts.spec} handed to the mini scheduler", flush=True)
    used, deadline, not_run = set(), time.time() + opts.go_wait_hours * 3600, 0
    for n in range(opts.rounds):
        go, why = gate.await_go(opts.spec, MINIS, used, deadline)
        if not go:
            print(f"round {n + 1}: no GO: {why}", flush=True)
            return 75
        used.add(go["go"])
        host = go["host"]
        out = Path(opts.out) / f"{opts.label}-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{host}"
        env = {**os.environ, "CAPTURE_HOST_HOSTS": host, "CAPTURE_HOST_SLOT_HOSTS": host,
               "CAPTURE_HOST_POOL": "perf-lead", "CAPTURE_HOST_ACQUIRE_TIMEOUT_SECONDS": "600",
               "CAPTURE_HOST_EXCLUSIVE_DRAIN_SECONDS": "900"}
        # --frame-interval 60: the driver's clip snapshots run on the app's main thread; none may fall in a recording.
        cmd = [sys.executable, str(HERE / "run.py"), "--build", opts.build, "--whole-host", "--exclusive", "--frame-interval", "60",
               "--hosts", host, "--out", str(out)]
        if opts.hog_swap_gb > 0:
            cmd += ["--hog-swap-gb", str(opts.hog_swap_gb)]
        if opts.vdisplay != "none":
            cmd += ["--vdisplay", opts.vdisplay]
        for jid in opts.journey:
            cmd += ["--journey", jid]
        print(f"round {n + 1}: GO {host}: {' '.join(cmd)}", flush=True)
        done = subprocess.run(cmd, env=env)
        status = {0: "pass", 1: "fail"}.get(done.returncode, "not run")
        gate.go_done(opts.spec, go, f"{opts.label} round {n + 1}", None if status != "not run" else "not run")
        cases = publish(out, f"{opts.label}-{opts.vdisplay}", opts.publish, opts.journey) if out.is_dir() else []
        if (out / "display.json").is_file():
            shutil.copy2(out / "display.json", Path(opts.publish) / f"{opts.label}-{opts.vdisplay}" / "display.json")
        print(json.dumps({"round": n + 1, "host": host, "status": status, "out": str(out), "published": cases}), flush=True)
        not_run += status == "not run"
    return 75 if not_run else 0


if __name__ == "__main__":
    sys.exit(main())
