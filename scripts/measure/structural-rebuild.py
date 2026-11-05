#!/usr/bin/env python3
"""Structural rebuild timing (scripts/measure/structural-rebuild.sh): a stored property added to a CmuxNextApp
type, to a relaunched tagged DEV app that answers on its socket.

A function-body edit can be injected into the running app (scripts/live-code); a new stored property, signature,
type or file cannot, and those are most app Swift PRs (leo-workspace research/2026-11-04-try-pr-live-apply.md).
This times that path, one phase at a time, so a change to the build can show what it saves:

  1. One reload.sh build at this checkout (warm when the step's .build kept a DerivedData, cold otherwise), then a
     launch, so the edits below start from a built, running app.
  2. Per edit: add one stored property to HomeHostView, stop the app, rebuild with reload.sh, launch again.
     Each row has the reload's wall time, xcodebuild's timing summary (task time per kind of task, which is not
     wall time: tasks overlap), the Swift files the driver compiled, and the launch to usable time.

The edits are taken back when the run ends (git checkout of the one file), so the warm checkout stays at its
commit. The log prints STRUCTURAL-REBUILD-ROW {json} per build and STRUCTURAL-REBUILD {json} at the end.
"""
import argparse, json, os, re, statistics, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, os.path.join(ROOT, "scripts/cmux-next"))
from bench_launch import BenchApp, LaunchError  # noqa: E402

TAG = "srebuild"
EDIT_FILE = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift"
ANCHOR = re.compile(r"^final class HomeHostView: NSView \{$", re.M)
TIMING = re.compile(r"^(?P<kind>[A-Za-z][\w ]*?) \((?P<tasks>\d+) tasks?\) \| (?P<seconds>[\d.]+) seconds?$", re.M)


def reload(config, log_dir, index):
    """One reload.sh build; returns (seconds, app path, reload log path)."""
    cmd = ["./scripts/reload.sh", "--tag", TAG] + (["--config", config] if config else [])
    env = dict(os.environ, CMUX_DEV_BACKEND_MODE="local", CMUX_SWIFT_INCREMENTAL_DIAGNOSTICS="1")
    start = time.monotonic()
    proc = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    seconds = round(time.monotonic() - start, 1)
    out = proc.stdout + proc.stderr
    with open(os.path.join(log_dir, f"reload-{index}.out"), "w") as f:
        f.write(out)
    logs = re.findall(r"^==> log: (.+)$", out, re.M)
    apps = re.findall(r"^App path:\n\s*(.+)$", out, re.M)
    if proc.returncode != 0 or not apps:
        print(out[-4000:], file=sys.stderr)
        raise SystemExit(f"structural-rebuild: reload {index} failed (exit {proc.returncode}) after {seconds} s")
    return seconds, apps[-1].strip(), (logs[-1].strip() if logs else None)


def build_facts(reload_log):
    """xcodebuild's timing summary and the driver's compiled Swift files, from reload.sh's log."""
    facts = {"timing": {}, "swift_files": None}
    if not reload_log or not os.path.exists(reload_log):
        return facts
    text = open(reload_log, errors="replace").read()
    summary = text.rsplit("Build Timing Summary", 1)[-1] if "Build Timing Summary" in text else ""
    for m in TIMING.finditer(summary):
        facts["timing"][m["kind"]] = {"tasks": int(m["tasks"]), "seconds": float(m["seconds"])}
    receipt = reload_log + ".incremental.json"
    if os.path.exists(receipt):
        counts = json.load(open(receipt)).get("counts", {})
        facts["swift_files"] = {k: counts.get(k) for k in ("initial_files", "dependency_cascade_files",
                                                           "scheduled_invalidated_files")}
    return facts


def launch(app, out):
    """Launches the tagged app; returns (launcher, seconds to a window on the socket)."""
    launcher = BenchApp(app, out=out, log_name=f"app-{TAG}.log", window=None, screen=None, teardown=False)
    launcher.launch(timeout=180)
    return launcher, launcher.ready_seconds


def add_property(index):
    path = os.path.join(ROOT, EDIT_FILE)
    text = open(path).read()
    match = ANCHOR.search(text)
    if not match:
        raise SystemExit(f"structural-rebuild: {EDIT_FILE} has no `final class HomeHostView: NSView {{` line")
    line = f"\n    var structuralRebuildProbe{index} = {index}"
    open(path, "w").write(text[:match.end()] + line + text[match.end():])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--edits", type=int, default=3)
    parser.add_argument("--config", default="", help="reload.sh --config (debug, release, bench); default its own")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    rows, launcher = [], None

    def record(row):
        rows.append(row)
        print("STRUCTURAL-REBUILD-ROW " + json.dumps(row), flush=True)

    try:
        seconds, app, log = reload(opts.config, opts.out, 0)
        launcher, ready = launch(app, opts.out)
        record({"build": 0, "edit": None, "reload_s": seconds, "launch_to_usable_s": ready, **build_facts(log)})
        for i in range(1, opts.edits + 1):
            add_property(i)
            stop_start = time.monotonic()
            launcher.stop()
            stop_s = round(time.monotonic() - stop_start, 1)
            seconds, app, log = reload(opts.config, opts.out, i)
            launcher, ready = launch(app, opts.out)
            record({"build": i, "edit": f"stored property {i} on HomeHostView", "stop_s": stop_s,
                    "reload_s": seconds, "launch_to_usable_s": ready,
                    "edit_to_usable_s": round(stop_s + seconds + (ready or 0), 1), **build_facts(log)})
    except LaunchError as error:
        raise SystemExit(f"structural-rebuild: launch failed: {error}")
    finally:
        if launcher:
            launcher.stop()
        subprocess.run(["git", "checkout", "--", EDIT_FILE], cwd=ROOT, check=False)

    edits = [r for r in rows if r["edit"]]
    summary = {"sha": subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip(),
               "config": opts.config or "default", "edits": len(edits), "first_reload_s": rows[0]["reload_s"]}
    for key in ("reload_s", "launch_to_usable_s", "edit_to_usable_s"):
        values = [r[key] for r in edits if r.get(key) is not None]
        summary[f"{key}_p50"] = statistics.median(values) if values else None
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump({"summary": summary, "rows": rows}, f, indent=2)
    print("STRUCTURAL-REBUILD " + json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
