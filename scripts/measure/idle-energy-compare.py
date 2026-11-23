#!/usr/bin/env python3
"""Idle energy of cmux NEXT, Claude Code desktop and Terminal.app on one Mac, under the same conditions.

Run by idle-energy-compare.sh on a fleet display worker (cmux-ci --class exclusive --measurement --display).
Each window launches one app from a fresh, signed-out profile (an empty HOME and CFFIXED_USER_HOME, the
bundle's defaults domain set aside, a login keychain in that home), lets it settle, then measures an equal
idle window and quits it. Windows are interleaved: round r runs the apps in an order rotated by r, so with
three apps and three rounds every app takes every position once. A calibration runs first: an idle window
with no app (host load, and package power when `sudo -n powermetrics` works) and a known-active control
(`yes`) that proves the energy counters move.

What each window records, per app (the app's own processes, its descendants and any process run from its
bundle): CPU energy (mW, proc_pid_rusage ri_energy_nj, no root, no GPU/display), CPU % of one core,
wakeups per second (package idle plus interrupt) and footprint.

Baseline counters (cmuxterm-hq#19931): every member's counters are read at the window's start. A process
alive before the window whose first read failed would charge its whole lifetime to the window (101x in that
note's replay); such a window is invalid and kept as unavailable, never zero-filled. A process that started
inside the window counts from zero and is listed. A member that exits inside the window invalidates it too.

Prints IDLE-COMPARE-WINDOW per window, a Markdown ranking between IDLE-COMPARE-TABLE-BEGIN/END and one
IDLE-COMPARE-RESULT JSON line; writes report.json to --out.
"""
from __future__ import annotations

import argparse
import datetime
import json
import os
import platform
import plistlib
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
METRICS = ("mw", "cpu_pct", "wakeups_per_s", "footprint_mb")
# A process whose start is this long before the window's first read was not new in the window.
NEW_PROCESS_SLACK_S = 2.0


def utc() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def schedule(apps: list[str], rounds: int) -> list[tuple[int, str]]:
    """(round, app) in run order: round r is the app list rotated left by r."""
    out = []
    for r in range(rounds):
        k = r % len(apps)
        out += [(r, app) for app in apps[k:] + apps[:k]]
    return out


def parse_etime(text: str) -> float | None:
    """`ps -o etime` ([[dd-]hh:]mm:ss) in seconds."""
    text = text.strip()
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        if not d.isdigit():
            return None
        days = int(d)
    parts = text.split(":")
    if not all(p.isdigit() for p in parts) or not 1 <= len(parts) <= 3:
        return None
    seconds = 0
    for p in parts:
        seconds = seconds * 60 + int(p)
    return float(days * 86400 + seconds)


def process_table() -> list[tuple[int, int, int, float | None, str]]:
    """(pid, ppid, uid, started at as a unix time, command) for every process."""
    now = time.time()
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,uid=,etime=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 4)
        if len(parts) == 5 and parts[0].isdigit() and parts[1].isdigit() and parts[2].isdigit():
            age = parse_etime(parts[3])
            rows.append((int(parts[0]), int(parts[1]), int(parts[2]), None if age is None else now - age, parts[4]))
    return rows


def members(table, app_pid: int, bundle_roots: tuple[str, ...]) -> dict[int, dict]:
    """{pid: {"cmd", "started", "uid"}}: the app, every descendant of it, and every process run from one of
    bundle_roots (a private copy of the bundle, so nothing else matches) with its descendants."""
    found = {}
    children: dict[int, list] = {}
    rows = {}
    for pid, ppid, uid, started, cmd in table:
        children.setdefault(ppid, []).append(pid)
        rows[pid] = {"cmd": cmd, "started": started, "uid": uid}
        if pid == app_pid or any(cmd.startswith(root.rstrip("/") + "/") for root in bundle_roots):
            found[pid] = rows[pid]
    stack = list(found)
    while stack:
        for child in children.get(stack.pop(), []):
            if child not in found:
                found[child] = rows[child]
                stack.append(child)
    return found


def window_delta(first: dict, last: dict, started: dict, window_start: float, elapsed: float) -> dict:
    """Totals of one window from counters read at its start (`first`) and end (`last`).

    first/last: {pid: (energy nJ, cpu ns, wakeups, footprint bytes) or None}; `first` holds every member
    seen at the start, `last` every member seen at the end. started: {pid: unix start time or None}.
    A member with no readable first counter that was alive before the window makes it invalid (it would
    charge its lifetime); one that started inside the window counts from zero. A start member missing at
    the end (exited, or unreadable) makes it invalid too."""
    total = {"mw": 0.0, "cpu_pct": 0.0, "wakeups_per_s": 0.0, "footprint_mb": 0.0}
    problems, new = [], []
    for pid in sorted(set(first) | set(last)):
        a, b = first.get(pid), last.get(pid)
        if b is None:
            problems.append(f"pid {pid}: no end counter (exited or unreadable)")
            continue
        if a is None:
            s = started.get(pid)
            if pid in first or s is None or s < window_start - NEW_PROCESS_SLACK_S:
                problems.append(f"pid {pid}: no baseline counter for a process alive before the window")
                continue
            new.append(pid)
            a = (0, 0, 0, 0)
        total["mw"] += (b[0] - a[0]) / 1e6 / elapsed
        total["cpu_pct"] += 100 * (b[1] - a[1]) / 1e9 / elapsed
        total["wakeups_per_s"] += (b[2] - a[2]) / elapsed
        total["footprint_mb"] += b[3] / 1048576.0
    return {"total": {k: round(v, 3) for k, v in total.items()}, "valid": not problems,
            "problems": problems, "new_in_window": new, "members": len(set(first) | set(last))}


def rank(windows: list[dict], apps: list[str]) -> list[dict]:
    """Per app over its valid windows: mean, min and max of each metric; ordered by mean mW."""
    rows = []
    for app in apps:
        valid = [w for w in windows if w["app"] == app and w.get("valid")]
        row = {"app": app, "n_valid": len(valid), "n": sum(1 for w in windows if w["app"] == app)}
        for key in METRICS:
            values = [w["total"][key] for w in valid]
            row[key] = round(statistics.mean(values), 3) if values else None
            row[key + "_min"] = round(min(values), 3) if values else None
            row[key + "_max"] = round(max(values), 3) if values else None
        pkg = [w["package_mw"] for w in valid if w.get("package_mw") is not None]
        row["package_mw"] = round(statistics.mean(pkg), 1) if pkg else None
        rows.append(row)
    rows.sort(key=lambda r: (r["mw"] is None, r["mw"] if r["mw"] is not None else 0))
    for i, row in enumerate(rows):
        row["rank"] = i + 1 if row["mw"] is not None else None
    return rows


def markdown(ranking: list[dict], names: dict[str, str], calibration: dict) -> str:
    lines = ["| rank | app | CPU energy mW (min-max) | CPU % of a core | wakeups/s | footprint MB | package mW | valid windows |",
             "|---:|---|---:|---:|---:|---:|---:|---:|"]
    fmt = lambda v: "n/a" if v is None else f"{v:g}"
    for r in ranking:
        lines.append(f"| {fmt(r['rank'])} | {names.get(r['app'], r['app'])} | {fmt(r['mw'])} ({fmt(r['mw_min'])}-{fmt(r['mw_max'])}) "
                     f"| {fmt(r['cpu_pct'])} | {fmt(r['wakeups_per_s'])} | {fmt(r['footprint_mb'])} | {fmt(r['package_mw'])} "
                     f"| {r['n_valid']}/{r['n']} |")
    idle = calibration.get("idle", {})
    lines.append("")
    lines.append(f"Calibration: no-app idle package {fmt(idle.get('package_mw'))} mW, load {idle.get('loadavg')}; "
                 f"control `yes` {fmt(calibration.get('control', {}).get('mw'))} mW, "
                 f"{fmt(calibration.get('control', {}).get('cpu_pct'))} % CPU.")
    return "\n".join(lines)


# ------------------------------------------------------------------------------ macOS side


class Mac:
    """The parts that need macOS: counters, powermetrics, launching and quitting an app."""

    def __init__(self):
        sys.path.insert(0, os.path.join(HERE, "..", "cmux-next"))
        import bench_power as bp  # noqa: E402  (proc_pid_rusage V6 counters, powermetrics)
        self.bp = bp
        self.sudo = subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode == 0

    def counters(self, pid: int):
        return self.bp.counters(pid)

    def powermetrics_async(self, seconds: float) -> tuple[threading.Thread, dict]:
        found: dict = {}
        def run():
            if self.sudo:
                found.update(self.bp.powermetrics(seconds) or {})
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread, found


def loadavg() -> list[float]:
    try:
        return [round(x, 2) for x in os.getloadavg()]
    except OSError:
        return []


def fresh_home(root: str) -> dict:
    home = os.path.join(root, "home")
    for sub in ("Library/Preferences", "Library/Application Support", "Library/Caches", "Library/Logs", "Library/Keychains"):
        os.makedirs(os.path.join(home, sub), exist_ok=True)
    tmp = os.path.join(root, "tmp")
    os.makedirs(tmp, exist_ok=True)
    env = {"HOME": home, "CFFIXED_USER_HOME": home, "TMPDIR": tmp + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "USER": os.environ.get("USER", ""), "LOGNAME": os.environ.get("USER", ""), "LANG": "en_US.UTF-8",
           "SHELL": "/bin/zsh"}
    # A login keychain in the fresh home, as a real first install has: without one a Chromium or Electron app
    # asks for "Safe Storage" through a Keychain dialog nobody answers (fresh_home_launch_smoke.py).
    keychain = os.path.join(home, "Library/Keychains/login.keychain-db")
    scoped = {k: env[k] for k in ("HOME", "CFFIXED_USER_HOME", "PATH", "USER")}
    for args in (["create-keychain", "-p", "", keychain], ["list-keychains", "-d", "user", "-s", keychain],
                 ["default-keychain", "-d", "user", "-s", keychain], ["set-keychain-settings", keychain]):
        subprocess.run(["security", *args], env=scoped, capture_output=True, timeout=30, start_new_session=True)
    return env


class DefaultsAside:
    """The bundle's defaults domain set aside for one window and put back after it (cfprefsd keeps an app's
    defaults in the account's preferences whatever HOME says). Skipped for a bundle already running outside
    this run (Terminal on a console): its prefs stay, and the window says so."""

    def __init__(self, bundle_id: str, root: str, skip: bool):
        self.bundle_id, self.skip = bundle_id, skip
        self.copy = os.path.join(root, f"{bundle_id}.defaults.plist")

    def __enter__(self):
        if not self.skip:
            subprocess.run(["defaults", "export", self.bundle_id, self.copy], capture_output=True, timeout=60)
            subprocess.run(["defaults", "delete", self.bundle_id], capture_output=True, timeout=60)
        return self

    def __exit__(self, *exc):
        if not self.skip and os.path.exists(self.copy):
            subprocess.run(["defaults", "import", self.bundle_id, self.copy], capture_output=True, timeout=60)
        return False


def bundle_info(bundle: str) -> dict:
    with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    return {"bundle_id": info.get("CFBundleIdentifier"), "version": info.get("CFBundleShortVersionString"),
            "build": info.get("CFBundleVersion"), "exe": os.path.join(bundle, "Contents/MacOS", info["CFBundleExecutable"]),
            "commit": info.get("CMUXCommit")}


def exe_pids(exe: str) -> set[int]:
    real = os.path.realpath(exe)
    return {row[0] for row in process_table() if row[4].startswith(exe) or row[4].startswith(real)}


def launch(bundle: str, env: dict, info: dict, timeout: float = 60) -> int:
    """`open -n -F` (a new instance, no restored windows) with the fresh env; the new instance's pid."""
    before = exe_pids(info["exe"])
    argv = ["open", "-n", "-F"]
    for key, value in env.items():
        argv += ["--env", f"{key}={value}"]
    subprocess.run(argv + [bundle], check=True, capture_output=True, timeout=60)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        new = exe_pids(info["exe"]) - before
        if new:
            return min(new)
        time.sleep(0.5)  # test script: waiting for the launched process to appear
    raise RuntimeError(f"{bundle}: no new process within {timeout} s")


def quit_family(pid: int, roots: tuple[str, ...], grace: float = 15) -> list[int]:
    """SIGTERM the app, then SIGKILL what is left of the processes this window launched."""
    family = set(members(process_table(), pid, roots))
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline and pid in {row[0] for row in process_table()}:
        time.sleep(0.5)  # test script: waiting for the app to quit
    family |= set(members(process_table(), pid, roots))
    alive = {row[0] for row in process_table()}
    left = sorted(p for p in family if p in alive)
    for p in left:
        try:
            os.kill(p, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return left


def measure_window(mac: Mac, app_pid: int, roots: tuple[str, ...], seconds: float) -> dict:
    start_members = members(process_table(), app_pid, roots)
    window_start = time.time()
    first = {pid: mac.counters(pid) for pid in start_members}
    started_mono = time.monotonic()
    load_before = loadavg()
    pm_thread, pm = mac.powermetrics_async(seconds)
    time.sleep(seconds)  # test script: the measured idle window
    end_members = members(process_table(), app_pid, roots)
    last = {pid: mac.counters(pid) for pid in end_members}
    elapsed = time.monotonic() - started_mono
    pm_thread.join(timeout=40)
    every = {**start_members, **end_members}
    # Another user's process (Terminal's setuid-root `login`) is never readable without root: it is left
    # out and named, not taken for a missing baseline. One of ours that cannot be read still invalidates.
    other_user = sorted(pid for pid, m in every.items() if m["uid"] != os.getuid()
                        and first.get(pid) is None and last.get(pid) is None)
    for pid in other_user:
        first.pop(pid, None)
        last.pop(pid, None)
    result = window_delta(first, last, {pid: m["started"] for pid, m in every.items()}, window_start, elapsed)
    result.update(seconds=round(elapsed, 1), loadavg_before=load_before, loadavg_after=loadavg(),
                  package_mw=pm.get("combined_power_mw") or pm.get("cpu_power_mw"), powermetrics=pm,
                  unreadable_other_user=[{"pid": pid, "cmd": every[pid]["cmd"][:120]} for pid in other_user],
                  processes=sorted({os.path.basename(m["cmd"].split()[0]) for m in every.values()}))
    return result


def calibrate(mac: Mac, seconds: float) -> dict:
    pm_thread, pm = mac.powermetrics_async(seconds)
    before = loadavg()
    time.sleep(seconds)  # test script: the no-app calibration window
    pm_thread.join(timeout=40)
    idle = {"seconds": seconds, "loadavg_before": before, "loadavg": loadavg(), "powermetrics": pm,
            "package_mw": pm.get("combined_power_mw") or pm.get("cpu_power_mw")}
    control = subprocess.Popen(["/usr/bin/yes"], stdout=subprocess.DEVNULL)
    try:
        a = mac.counters(control.pid)
        t0 = time.monotonic()
        time.sleep(5)  # test script: the known-active control's window
        b = mac.counters(control.pid)
        elapsed = time.monotonic() - t0
    finally:
        control.kill()
        control.wait(timeout=10)
    ok = a is not None and b is not None
    ctl = {"pid": control.pid, "readable": ok,
           "mw": round((b[0] - a[0]) / 1e6 / elapsed, 3) if ok else None,
           "cpu_pct": round(100 * (b[1] - a[1]) / 1e9 / elapsed, 3) if ok else None}
    ctl["counters_move"] = bool(ok and ctl["mw"] > 0 and ctl["cpu_pct"] > 50)
    return {"idle": idle, "control": ctl}


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", action="append", default=[], metavar="NAME=BUNDLE", help="repeatable; run order is the given order")
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--seconds", type=float, default=60)
    p.add_argument("--settle", type=float, default=60)
    p.add_argument("--calibrate", type=float, default=60)
    p.add_argument("--out", required=True)
    o = p.parse_args(argv)
    if o.rounds < 3:
        raise SystemExit("idle-energy-compare: at least 3 rounds")
    apps, bundles = [], {}
    for item in o.app:
        name, _, bundle = item.partition("=")
        apps.append(name)
        bundles[name] = os.path.realpath(bundle)
    names = {"next": "cmux NEXT", "claude": "Claude Code desktop", "terminal": "Terminal.app"}
    os.makedirs(o.out, exist_ok=True)
    # A step cancel (SIGTERM) unwinds through each window's finally, so the app it launched is quit.
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
    mac = Mac()
    infos = {name: bundle_info(b) for name, b in bundles.items()}
    report = {"host": platform.node().split(".")[0], "os": platform.mac_ver()[0], "chip": platform.machine(),
              "start": utc(), "rounds": o.rounds, "seconds": o.seconds, "settle": o.settle,
              "apps": {n: {"bundle": bundles[n], **{k: v for k, v in infos[n].items() if k != "exe"}} for n in apps},
              "sudo_powermetrics": mac.sudo, "windows": []}
    print("IDLE-COMPARE-START " + json.dumps({k: report[k] for k in ("host", "os", "chip", "start", "apps", "sudo_powermetrics")}), flush=True)
    report["calibration"] = calibrate(mac, o.calibrate)
    print("IDLE-COMPARE-CALIBRATION " + json.dumps(report["calibration"]), flush=True)
    if not report["calibration"]["control"]["counters_move"]:
        print("IDLE-COMPARE energy counters did not move under the active control; results are not comparable", flush=True)
    for r, app in schedule(apps, o.rounds):
        bundle, info = bundles[app], infos[app]
        system_app = bundle.startswith("/System/")
        roots = () if system_app else (bundle, bundle.removeprefix("/private"))
        running_elsewhere = bool(exe_pids(info["exe"]))
        root = tempfile.mkdtemp(prefix=f"idle-{app}-")
        window = {"round": r, "app": app, "start": None}
        try:
            env = fresh_home(root)
            with DefaultsAside(info["bundle_id"], root, skip=running_elsewhere):
                window["defaults_set_aside"] = not running_elsewhere
                pid = launch(bundle, env, info)
                try:
                    time.sleep(o.settle)  # test script: settle after launch, outside the window
                    window["start"] = utc()
                    window.update(measure_window(mac, pid, roots, o.seconds))
                    window["profile_isolated"] = any(os.scandir(os.path.join(env["HOME"], "Library/Application Support"))) or \
                        any(os.scandir(os.path.join(env["HOME"], "Library/Preferences")))
                finally:
                    window["killed_after_grace"] = quit_family(pid, roots)
        except Exception as error:  # a window that could not run is kept as unavailable
            window.update(valid=False, problems=[f"{type(error).__name__}: {error}"])
        finally:
            shutil.rmtree(root, ignore_errors=True)
        report["windows"].append(window)
        print("IDLE-COMPARE-WINDOW " + json.dumps(window), flush=True)
    report["end"] = utc()
    report["ranking"] = rank(report["windows"], apps)
    report["markdown"] = markdown(report["ranking"], names, report["calibration"])
    report["scope"] = ("per-process CPU energy of each app's own processes, descendants and bundle processes; "
                       "excludes GPU and display energy; package power only where sudo -n powermetrics works")
    with open(os.path.join(o.out, "report.json"), "w") as handle:
        json.dump(report, handle, indent=2)
    print("IDLE-COMPARE-TABLE-BEGIN\n" + report["markdown"] + "\nIDLE-COMPARE-TABLE-END", flush=True)
    print("IDLE-COMPARE-RESULT " + json.dumps({k: report[k] for k in ("host", "os", "chip", "start", "end", "rounds",
                                                                       "seconds", "apps", "calibration", "ranking")}), flush=True)
    return 0 if all(r["n_valid"] for r in report["ranking"]) else 1


if __name__ == "__main__":
    sys.exit(main())
