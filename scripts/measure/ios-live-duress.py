#!/usr/bin/env python3
"""ios-live under duress: a Swift body edit on an always-on simulator, rebuilt against live patched, idle and
under CPU load, then live patches round after round on the same running app with its memory sampled each round.

  scripts/measure/ios-live-duress.sh [--ref SHA] [--n 5] [--minutes 90] [--round-edits 6]

Runs on a fleet Mac (cmux-ci run --class exclusive). It brings up the ios-live slot path itself
(scripts/ios-live/host.sh up, in a fresh IOS_LIVE_ROOT under $TMPDIR, removed at the end), launched with
CMUX_LIVE_CODE_PROBE=1 so the app shows one color (cmux-next-ios/App/LiveCodeProbe.swift). Then, with one
harness (scripts/measure/ios-live-code.py, the same edits and the same pixel check):

  before  --mode rebuild: warm incremental xcodebuild, simctl install, relaunch (what `ios-live swap` does on a
          base with no live code, the fallback): one warm-up edit, then N edits idle and N under load
  after   --mode live: ios-sim.sh patch into the running app (`ios-live swift`): N idle, N under load
  duress  rounds of --round-edits live patches each, alternating idle and load, until --minutes pass, on the
          same app process: per round the p50, the app's and the simulator's resident memory, the live
          folder's patch count, and whether the app's process changed (a crash or relaunch)

The harness and the probe are read from the slot's own checkout at --ref, so --ref must carry them
(the live Swift engine, cmux#45397); this script and host.sh run from the reviewed commit. Load is one `yes` per core. Prints JSON lines; the last is the summary.
"""
import argparse
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OLD = "Color(red: 0.5, green: 0.5, blue: 0.5)"
PROBE = "cmux-next-ios/App/LiveCodeProbe.swift"


def emit(**row):
    print(json.dumps(row), flush=True)


def sh(*args, env=None, check=True):
    run = subprocess.run(list(args), capture_output=True, text=True, env=env)
    if check and run.returncode != 0:
        sys.stderr.write(run.stdout[-4000:] + run.stderr[-4000:])
        raise SystemExit(f"ios-live-duress: {' '.join(args[:3])} exited {run.returncode}")
    return run


class Load:
    def __init__(self, on):
        self.procs = []
        if on:
            self.procs = [subprocess.Popen(["yes"], stdout=subprocess.DEVNULL) for _ in range(os.cpu_count() or 8)]

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        for p in self.procs:
            p.kill()
            p.wait()


def app_pid(udid):
    out = sh("ps", "-axo", "pid=,command=", check=False).stdout
    for line in out.splitlines():
        if udid in line and "CmuxMobileApp.app/CmuxMobileApp" in line:
            return int(line.split()[0])
    return None


def memory(udid):
    """Resident MB of the app and of every process whose command names the device, and the host's free percent."""
    app_mb = sim_mb = 0.0
    for line in sh("ps", "-axo", "rss=,command=", check=False).stdout.splitlines():
        rss, _, cmd = line.strip().partition(" ")
        if udid in cmd:
            sim_mb += int(rss) / 1024
            if "CmuxMobileApp.app/CmuxMobileApp" in cmd:
                app_mb += int(rss) / 1024
    free = None
    for line in sh("memory_pressure", check=False).stdout.splitlines():
        if "free percentage" in line:
            free = line.rsplit(":", 1)[-1].strip()
    return {"app_mb": round(app_mb), "sim_mb": round(sim_mb), "host_free": free}


def screen_center(udid, env):
    shot = tempfile.mktemp(suffix=".bmp")
    try:
        sh("xcrun", "simctl", "--set", env["IOS_SIM_SET"], "io", udid, "screenshot", "--type=bmp", shot)
        import struct
        with open(shot, "rb") as f:
            width, height = struct.unpack_from("<ii", f.read(26), 18)
        return width // 2, abs(height) // 2
    finally:
        if os.path.exists(shot):
            os.remove(shot)


def harness(src, env, mode, edits, extra, phase, load):
    args = [sys.executable, os.path.join(src, "scripts/measure/ios-live-code.py"), "--mode", mode, "--edits", str(edits),
            "--old", OLD, "--timeout", "2400"] + extra + [os.path.join(src, PROBE)]
    with Load(load):
        run = subprocess.run(args, capture_output=True, text=True, env=env)
    rows = []
    for line in run.stdout.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if "edit" in row:
            rows.append(row["visible_s"])
            emit(phase=phase, load=load, **row)
    if run.returncode != 0:
        emit(phase=phase, load=load, failed=run.stderr.strip()[-600:])
    return rows


def p(values):
    if not values:
        return None
    s = sorted(values)
    return {"n": len(s), "p50": round(statistics.median(s), 2), "p95": round(s[min(len(s) - 1, round(0.95 * (len(s) - 1)))], 2),
            "min": round(s[0], 2), "max": round(s[-1], 2)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ref", default=None)
    ap.add_argument("--n", type=int, default=5)
    ap.add_argument("--minutes", type=float, default=90)
    ap.add_argument("--round-edits", type=int, default=6)
    a = ap.parse_args()
    ref = a.ref or sh("git", "-C", ROOT, "rev-parse", "HEAD").stdout.strip()
    live_root = tempfile.mkdtemp(prefix="ios-live-duress-")
    host = os.path.join(ROOT, "scripts/ios-live/host.sh")
    env = dict(os.environ, IOS_LIVE_ROOT=live_root)
    owner = "ios-live-duress"
    udid = None
    started = time.time()
    try:
        with open(os.path.join(live_root, "launch.env"), "w") as f:
            f.write("CMUX_LIVE_CODE_PROBE=1\n")
        sh("bash", host, "lease", "take", owner, "120", env=env)
        up = sh("bash", host, "up", owner, ref, env=env)
        state = json.load(open(os.path.join(live_root, "state.json")))
        emit(phase="up", **{k: state.get(k) for k in ("base", "build_kind", "ffi_how", "ffi_ms", "gen_ms", "build_ms", "install_launch_ms", "total_ms")})
        if state.get("build_kind") != "live-code":
            raise SystemExit("ios-live-duress: host.sh up made no live code build:\n" + up.stdout[-2000:])
        udid, src = state["udid"], os.path.join(live_root, "src")
        henv = dict(env, IOS_SIM_SET=os.path.join(live_root, "sims"), SIMCTL_CHILD_CMUX_LIVE_CODE_PROBE="1")
        time.sleep(3)
        x, y = screen_center(udid, henv)
        point = ["--udid", udid, "--x", str(x), "--y", str(y), "--bundle-id", state["bundle_id"]]
        emit(phase="probe", x=x, y=y, **memory(udid))

        # before: the rebuild fallback, in its own warm DerivedData (one warm-up edit, not counted)
        rebuild = point + ["--derived-data", os.path.join(live_root, "dd")]
        harness(src, henv, "rebuild", 1, rebuild, "warmup", False)
        before_idle = harness(src, henv, "rebuild", a.n, rebuild, "before", False)
        before_load = harness(src, henv, "rebuild", a.n, rebuild, "before", True)

        # after: the live code app back on the device, patched live
        sh("bash", host, "relaunch", owner, env=env)
        time.sleep(3)
        live = point + ["--out", os.path.join(live_root, "live")]
        after_idle = harness(src, henv, "live", a.n, live, "after", False)
        after_load = harness(src, henv, "live", a.n, live, "after", True)

        # duress: the same app process, round after round
        pid0, rounds, all_live, changed = app_pid(udid), 0, [], 0
        first_mem = memory(udid)
        emit(phase="duress-start", pid=pid0, **first_mem)
        deadline = time.time() + a.minutes * 60
        while time.time() < deadline:
            rounds += 1
            load = rounds % 2 == 0
            sh("bash", host, "lease", "beat", owner, "120", env=env, check=False)
            got = harness(src, henv, "live", a.round_edits, live, "duress", load)
            all_live += [g for g in got if g is not None]
            pid = app_pid(udid)
            if pid != pid0:
                changed += 1
                pid0 = pid
            patches = len([n for n in os.listdir(os.path.join(live_root, "live", "live")) if n.endswith(".dylib")])
            emit(phase="round", round=rounds, load=load, elapsed_min=round((time.time() - started) / 60, 1),
                 round_p50=p(got)["p50"] if got else None, edits_ok=len(got), pid=pid, process_changed=changed, patches=patches, **memory(udid))
            if pid is None:
                emit(phase="duress", failed="the app is not running")
                break
        last_mem = memory(udid)
        emit(phase="summary", before_idle=p(before_idle), before_load=p(before_load), after_idle=p(after_idle), after_load=p(after_load),
             duress={"rounds": rounds, "edits": p(all_live), "process_changed": changed, "app_mb_first": first_mem["app_mb"],
                     "app_mb_last": last_mem["app_mb"], "sim_mb_first": first_mem["sim_mb"], "sim_mb_last": last_mem["sim_mb"]},
             minutes=round((time.time() - started) / 60, 1))
    finally:
        if udid:
            sh("xcrun", "simctl", "--set", os.path.join(live_root, "sims"), "shutdown", "all", check=False)
            sh("xcrun", "simctl", "--set", os.path.join(live_root, "sims"), "delete", "all", check=False)
        sh("bash", host, "lease", "release", owner, env=env, check=False)
        shutil.rmtree(live_root, ignore_errors=True)


if __name__ == "__main__":
    main()
