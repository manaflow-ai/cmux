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
     wall time: tasks overlap), the swift-driver's incremental decisions (files queued, cascaded, invalidated;
     incremental turned off), and the launch to usable time.

The edits are taken back when the run ends (git checkout of the one file), so the warm checkout stays at its
commit; a run refuses to start when that file already has local changes, which the checkout would erase. The log
prints STRUCTURAL-REBUILD-ROW {json} per build and STRUCTURAL-REBUILD {json} at the end.
"""
import argparse, json, os, re, signal, statistics, subprocess, sys, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
sys.path.insert(0, os.path.join(ROOT, "scripts/cmux-next"))
from bench_launch import BenchApp, LaunchError  # noqa: E402

TAG = "srebuild"
EDIT_FILE = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift"
ANCHOR = re.compile(r"^final class HomeHostView: NSView \{$", re.M)
# How long the reload's process group gets after SIGTERM before SIGKILL.
GROUP_GRACE_S = 30
STOP_SIGNALS = {signal.SIGTERM, signal.SIGHUP}
TIMING = re.compile(r"^(?P<kind>[A-Za-z][\w ]*?) \((?P<tasks>\d+) tasks?\) \| (?P<seconds>[\d.]+) seconds?$", re.M)


def reload(config, log_dir, index):
    """One reload.sh build; returns (seconds, app path, reload log path, wall-clock start)."""
    cmd = ["./scripts/reload.sh", "--tag", TAG] + (["--config", config] if config else [])
    env = dict(os.environ, CMUX_DEV_BACKEND_MODE="local", CMUX_SWIFT_INCREMENTAL_DIAGNOSTICS="1")
    started, start = time.time(), time.monotonic()
    # Streamed to the step's log as it runs, so a long cold build is never a silent step the fleet's watchdog ends.
    # Its own process group, so a run that ends early (a SIGTERM, a failed write) ends xcodebuild with it. The stop
    # signals are held from the fork until the try below, so one that arrives in between still finds the group.
    signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
    try:
        proc = subprocess.Popen(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                start_new_session=True)
    except BaseException:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, STOP_SIGNALS)
        raise
    lines = []
    try:
        signal.pthread_sigmask(signal.SIG_UNBLOCK, STOP_SIGNALS)
        with open(os.path.join(log_dir, f"reload-{index}.out"), "w") as f:
            for line in proc.stdout:
                f.write(line)
                lines.append(line)
                print(f"[reload {index}] {line}", end="", flush=True)
        proc.wait()
    except BaseException:
        end_group(proc)
        raise
    seconds = round(time.monotonic() - start, 1)
    out = "".join(lines)
    logs = re.findall(r"^==> log: (.+)$", out, re.M)
    apps = re.findall(r"^App path:\n\s*(.+)$", out, re.M)
    if proc.returncode != 0 or not apps:
        print(out[-4000:], file=sys.stderr)
        raise SystemExit(f"structural-rebuild: reload {index} failed (exit {proc.returncode}) after {seconds} s")
    return seconds, apps[-1].strip(), (logs[-1].strip() if logs else None), started


def end_group(proc):
    """SIGTERM to the reload's process group, then SIGKILL to whatever of the group is left after GROUP_GRACE_S: the
    group, not only reload.sh, since an xcodebuild below it can outlive or ignore the SIGTERM."""
    def group_alive():
        proc.poll()                    # reaps reload.sh, whose zombie would keep the group alive
        try:
            os.killpg(proc.pid, 0)
            return True
        except ProcessLookupError:
            return False
    for sig, grace in ((signal.SIGTERM, GROUP_GRACE_S), (signal.SIGKILL, 10)):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        deadline = time.monotonic() + grace
        # No exit event exists for a process group's last member: its members are checked every 0.2 s, at most grace s.
        while group_alive() and time.monotonic() < deadline:
            time.sleep(0.2)
        if not group_alive():
            return


def exit_on_signal(signum, _frame):
    """A SIGTERM or SIGHUP (the step's timeout) unwinds like an error, so the edits are taken back and the app and
    the reload are ended."""
    raise SystemExit(f"structural-rebuild: ended by signal {signum}")


def build_facts(reload_log, since=0.0):
    """xcodebuild's timing summary, and the swift-driver's incremental diagnostics (scripts/ci/
    swift_incremental_diagnostics.py: how many files it queued as changed, pulled in by a dependency, or scheduled
    as invalidated, and whether incremental was turned off), from reload.sh's log. These are the driver's
    incremental decisions, not a count of the files compiled. The receipt sits next to a log path every reload
    reuses, so one written before `since` (this reload's start) is an earlier build's and is not read."""
    facts = {"timing": {}, "incremental": None}
    if not reload_log or not os.path.exists(reload_log):
        return facts
    text = open(reload_log, errors="replace").read()
    summary = text.rsplit("Build Timing Summary", 1)[-1] if "Build Timing Summary" in text else ""
    for m in TIMING.finditer(summary):
        facts["timing"][m["kind"]] = {"tasks": int(m["tasks"]), "seconds": float(m["seconds"])}
    receipt = reload_log + ".incremental.json"
    if os.path.exists(receipt) and os.path.getmtime(receipt) >= since:
        counts = json.load(open(receipt)).get("counts", {})
        facts["incremental"] = {k: counts.get(k) for k in ("initial_files", "dependency_cascade_files",
                                                           "scheduled_invalidated_files",
                                                           "incremental_disabled_reasons", "dependency_read_failures")}
    return facts


def launcher_for(app, out):
    """The tagged app's launcher. Its stop() quits the app and ends the tag's daemons (TagTeardown), so the next
    launch's fresh start never moves a state folder a live daemon still writes."""
    return BenchApp(app, out=out, log_name=f"app-{TAG}.log", window=None, screen=None)


def add_property(index):
    path = os.path.join(ROOT, EDIT_FILE)
    text = open(path).read()
    match = ANCHOR.search(text)
    if not match:
        raise SystemExit(f"structural-rebuild: {EDIT_FILE} has no `final class HomeHostView: NSView {{` line")
    line = f"\n    var structuralRebuildProbe{index} = {index}"
    open(path, "w").write(text[:match.end()] + line + text[match.end():])


def refuse_local_edits():
    """The run ends with a git checkout of EDIT_FILE, so it refuses to start on a file with edits of its own."""
    dirty = subprocess.run(["git", "status", "--porcelain", "--", EDIT_FILE], cwd=ROOT, capture_output=True,
                           text=True, check=True).stdout.strip()
    if dirty:
        raise SystemExit(f"structural-rebuild: {EDIT_FILE} has local changes ({dirty}); "
                         "commit or remove them first, the run takes its edits back with git checkout")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--edits", type=int, default=3)
    # Plain release compiles out the debug socket methods the launch waits on (debug.windows); bench keeps them.
    parser.add_argument("--config", default="", choices=["", "debug", "bench"],
                        help="reload.sh --config (debug or bench); default its own")
    opts = parser.parse_args()
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, exit_on_signal)
    os.makedirs(opts.out, exist_ok=True)
    refuse_local_edits()
    rows, launcher, edited = [], None, False

    def record(row):
        rows.append(row)
        print("STRUCTURAL-REBUILD-ROW " + json.dumps(row), flush=True)

    try:
        seconds, app, log, started = reload(opts.config, opts.out, 0)
        # Assigned before launch(), so a launch that spawns the app and then fails is still stopped below.
        launcher = launcher_for(app, opts.out)
        launcher.launch(timeout=180)
        record({"build": 0, "edit": None, "reload_s": seconds, "launch_to_usable_s": launcher.ready_seconds,
                **build_facts(log, started)})
        for i in range(1, opts.edits + 1):
            edited = True
            add_property(i)
            stop_start = time.monotonic()
            launcher.stop()
            launcher = None
            stop_s = round(time.monotonic() - stop_start, 1)
            seconds, app, log, started = reload(opts.config, opts.out, i)
            launcher = launcher_for(app, opts.out)
            launcher.launch(timeout=180)
            ready = launcher.ready_seconds
            record({"build": i, "edit": f"stored property {i} on HomeHostView", "stop_s": stop_s,
                    "reload_s": seconds, "launch_to_usable_s": ready,
                    "edit_to_usable_s": round(stop_s + seconds + (ready or 0), 1), **build_facts(log, started)})
    except LaunchError as error:
        raise SystemExit(f"structural-rebuild: launch failed: {error}")
    finally:
        if launcher:
            launcher.stop()
        if edited:
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
