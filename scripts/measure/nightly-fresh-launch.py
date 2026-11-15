#!/usr/bin/env python3
"""Where a published NEXT nightly's fresh-home launch spends its time (goal next-launch-instant, CMUX-571).

    nightly-fresh-launch.py --dmg DMG --out DIR [--rounds N] [--seconds S]

The nightly dogfood's launch number (app_launch_ms) is a first install's launch: a fresh copy of the app out of the
DMG, an empty HOME (scripts/ci/fresh_home_launch_smoke.py). It mixes two kinds of first-time cost: the first exec
of a binary no process has run yet (the kernel's and dyld's first look at a new file, the signature checks), and the
app's own first-run work in an empty home. Each round here launches three times, with the smoke's own environment,
defaults set aside as it does, and its watch (Home rendered in a visible window):

  fresh-copy   a new copy of the app (ditto out of the DMG), a new HOME: the nightly dogfood's launch
  same-copy    the same copy again, another new HOME: the first-exec cost of the copy is gone, the home's is not
  warm         the same copy and the same-copy arm's HOME again: a person's next launch

and prints, per launch, every launch mark the app streamed (ms since its process start) and the phases:
  pre_main   process start to main_start (exec, dyld, static initializers)
  to_frame   main_start to first_window_frame_committed
  to_page    first_window_frame_committed to home.first_page (Home's first page in)
  harness    the smoke's time to Home rendered (it polls snapshot.get every 0.25 s)
It also records the copy's facts once: its size, its main executable's size and load commands, its extended
attributes (quarantine, provenance) and its signature (codesign -dv).

Lines: NFL-FACT <json>, NFL-LAUNCH <round> <arm> <json>, NFL-MEDIAN <arm> <json>. report.json keeps it all.
Exit 0: every launch rendered Home. 1: one did not. 3: could not run.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SMOKE_PATH = HERE.parent / "ci" / "fresh_home_launch_smoke.py"
ARMS = ("fresh-copy", "same-copy", "warm")
PHASE_KEYS = ("main_start", "first_window_frame_committed", "home.first_page", "reveal.home")


def load_smoke():
    spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke", SMOKE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_text(args: list[str], timeout: float = 120) -> str:
    try:
        done = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as error:
        return f"error: {error}"
    return (done.stdout + done.stderr).strip()


def facts(app: Path, executable: str, copy_s: float) -> dict:
    exe = app / "Contents" / "MacOS" / executable
    loads = run_text(["otool", "-L", str(exe)]).splitlines()[1:]
    frameworks = app / "Contents" / "Frameworks"
    started = time.monotonic()
    verify = run_text(["codesign", "--verify", "--strict", str(exe)], timeout=600)
    verify_s = time.monotonic() - started
    # The whole bundle, as a first-launch Gatekeeper check of an app hashes it (every nested framework and resource).
    started = time.monotonic()
    deep = run_text(["codesign", "--verify", "--deep", "--strict", str(app)], timeout=900)
    deep_s = time.monotonic() - started
    return {
        "codesign_verify_deep_s": round(deep_s, 2), "codesign_verify_deep": deep or "ok",
        "frameworks_du": run_text(["du", "-sh", str(frameworks)]).split("\t")[0] if frameworks.is_dir() else None,
        "copy_s": round(copy_s, 2),
        "bundle_du": run_text(["du", "-sh", str(app)]).split("\t")[0],
        "frameworks": sorted(p.name for p in frameworks.iterdir()) if frameworks.is_dir() else [],
        "exe_bytes": exe.stat().st_size,
        "exe_loads": [line.strip().split(" (")[0] for line in loads],
        "xattr_app": run_text(["xattr", str(app)]).splitlines(),
        "xattr_exe": run_text(["xattr", str(exe)]).splitlines(),
        "codesign": [line for line in run_text(["codesign", "-dv", str(exe)]).splitlines()
                     if not line.startswith("Executable=")],
        "codesign_verify_exe_s": round(verify_s, 2), "codesign_verify": verify or "ok",
        "macos": run_text(["sw_vers", "-productVersion"]), "chip": run_text(["sysctl", "-n", "machdep.cpu.brand_string"]),
    }


def phases(marks: dict, rendered_at: float | None) -> dict:
    def get(key):
        return marks.get(key)
    start, frame, page = get("main_start"), get("first_window_frame_committed"), get("home.first_page")
    def gap(a, b):
        return None if a is None or b is None else round(b - a, 1)
    return {"pre_main": start, "to_frame": gap(start, frame), "to_page": gap(frame, page),
            "frame": frame, "page": page, "reveal_home": get("reveal.home"),
            "harness": None if rendered_at is None else round(rendered_at * 1000)}


def launch(smoke, root: Path, app: Path, executable: str, home_root: Path, seconds: float, name: str) -> dict:
    """One launch of APP from HOME_ROOT/h (the smoke's fresh_env), watched until Home rendered and SECONDS passed."""
    socket_path, marks_path = home_root / f"{name}.sock", home_root / f"marks-{name}"
    marks_read, marks_write = os.pipe()
    try:
        try:
            env = smoke.fresh_env(home_root, socket_path, marks_write)
            with open(home_root / f"app-{name}.log", "wb") as app_log:
                process = subprocess.Popen([str(app / "Contents" / "MacOS" / executable),
                                            "-ApplePersistenceIgnoreState", "YES"],
                                           env=env, cwd=env["HOME"], stdin=subprocess.DEVNULL, stdout=app_log,
                                           stderr=subprocess.STDOUT, pass_fds=(marks_write,), start_new_session=True)
        finally:
            os.close(marks_write)
        try:
            seen = smoke.watch(process, marks_read, marks_path, socket_path, seconds, max(seconds, 90.0))
        finally:
            smoke.stop_child(process)
            smoke.stop(smoke.own_pids(root))
    finally:
        os.close(marks_read)
    marks = dict(sorted(smoke.read_marks(marks_path).items(), key=lambda kv: kv[1]))
    return {"exit": seen["exit"], "rendered_at": seen["rendered_at"], "host": seen["host"],
            "phases": phases(marks, seen["rendered_at"]), "marks": marks}


def round_once(smoke, mount_app: Path, bundle_id: str, executable: str, seconds: float, index: int,
               report: dict) -> list[dict]:
    root = Path(tempfile.mkdtemp(prefix="cmux-nfl-", dir="/tmp"))
    rows: list[dict] = []
    try:
        started = time.monotonic()
        app = smoke.copy_app(mount_app, root)
        copy_s = time.monotonic() - started
        if index == 1:
            report["facts"] = facts(app, executable, copy_s)
            print("NFL-FACT", json.dumps(report["facts"]), flush=True)
        first, second = root / "a", root / "b"
        first.mkdir()
        second.mkdir()
        with smoke.DefaultsAside(bundle_id, root):
            rows.append({"arm": "fresh-copy", **launch(smoke, root, app, executable, first, seconds, "fresh")})
        with smoke.DefaultsAside(bundle_id, root):
            rows.append({"arm": "same-copy", **launch(smoke, root, app, executable, second, seconds, "same")})
            rows.append({"arm": "warm", **launch(smoke, root, app, executable, second, seconds, "warm")})
        for row in rows:
            row["round"] = index
            print("NFL-LAUNCH", index, row["arm"], json.dumps({k: row[k] for k in ("exit", "rendered_at", "phases")}),
                  flush=True)
            print("NFL-MARKS", index, row["arm"], json.dumps(row["marks"]), flush=True)
    finally:
        smoke.stop(smoke.own_pids(root))
        shutil.rmtree(root, ignore_errors=True)
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--rounds", type=int, default=2, choices=range(1, 6))
    parser.add_argument("--seconds", type=float, default=8.0)
    args = parser.parse_args(argv)
    os.umask(0o022)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    smoke = load_smoke()
    report: dict = {"dmg": args.dmg, "launches": []}
    problem = smoke.gui_session_problem()
    if smoke.signing_keychains_present() or problem:
        print(f"NFL cannot run: {problem or 'a signing keychain is present'}", flush=True)
        return 3
    mount = Path(tempfile.mkdtemp(prefix="cmux-nfl-mnt-", dir="/tmp"))
    status = 0
    try:
        subprocess.run(["hdiutil", "attach", args.dmg, "-nobrowse", "-readonly", "-mountpoint", str(mount)],
                       check=True, stdout=subprocess.DEVNULL, timeout=300)
        apps = sorted(mount.glob("*.app"))
        if not apps:
            print("NFL cannot run: no app in the DMG", flush=True)
            return 3
        bundle_id, executable = smoke.bundle_info(apps[0])
        report["bundle_id"] = bundle_id
        for index in range(1, args.rounds + 1):
            rows = round_once(smoke, apps[0], bundle_id, executable, args.seconds, index, report)
            report["launches"].extend(rows)
            if any(row["rendered_at"] is None for row in rows):
                status = 1
    except (smoke.CannotRun, OSError, subprocess.SubprocessError) as error:
        print(f"NFL cannot run: {error}", flush=True)
        status = 3
    finally:
        smoke.detach(mount)
        shutil.rmtree(mount, ignore_errors=True)
    medians = {}
    for arm in ARMS:
        rows = [r for r in report["launches"] if r["arm"] == arm and r["rendered_at"] is not None]
        med = {}
        for key in ("pre_main", "to_frame", "to_page", "frame", "page", "harness"):
            vals = [r["phases"][key] for r in rows if r["phases"].get(key) is not None]
            med[key] = round(statistics.median(vals), 1) if vals else None
        medians[arm] = {"n": len(rows), **med}
        print("NFL-MEDIAN", arm, json.dumps(medians[arm]), flush=True)
    report["medians"] = medians
    (out / "report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    print(f"NFL verdict exit {status}", flush=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
