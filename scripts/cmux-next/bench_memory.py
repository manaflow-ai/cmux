#!/usr/bin/env python3
"""Resident memory of a cmux-next app and every process it owns.

Measures resident size (RSS) and physical footprint (what Activity Monitor
calls Memory) per process: the app, its Chromium helpers, the WebKit
processes it is responsible for (agent chats and pages), the cmux-tui
daemons and terminal hosts, acpmux, and the other bundled helpers. It
builds workspaces over the app socket (each takes the next entry of
--mix, for example terminal+chat, terminal+browser, terminal), measures at
each count in --workspaces after --settle seconds, then optionally churns:
for --churn-minutes it opens a workspace of the mix and closes it again,
and every --sample-minutes it lets the app settle at the same workspace
count and samples again. Growth across those samples at an unchanged
workspace count is a leak.

Two ways to run (macOS only, a fleet or capture mini, never a laptop):
  attach  --socket PATH --app-pid PID: an app someone else launched, for
          example by `capture-host launch` into a capture slot (capture
          leases end after 10 minutes, so churn there stays short).
  launch  no --socket: starts the bundle's app with a scratch HOME,
          TMPDIR and config, and quits it at the end.

Usage:
  bench_memory.py --app BUNDLE [--socket PATH --app-pid PID]
      [--workspaces 1,10,30] [--mix terminal+chat,terminal+browser,terminal]
      [--settle 30] [--churn-minutes 0] [--sample-minutes 5]
      [--url URL] [--top 15] [--out FILE.json]

Prints a table per measurement (top processes by footprint, totals per
kind) and writes every sample to --out.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
_libsystem = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
try:
    _responsible = _libsystem.responsibility_get_pid_responsible_for_pid
    _responsible.restype = ctypes.c_int
    _responsible.argtypes = [ctypes.c_int]
except AttributeError:  # an OS without the call: WebKit processes are not attributed
    _responsible = None

MB = 1048576.0


def usage(pid: int):
    """(resident, footprint, lifetime max footprint) in bytes, or None once the pid is gone."""
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(buf)) != 0:
        return None
    # RUSAGE_INFO_V4 in u64 words: uuid (2), user, system, pkg idle wakeups,
    # interrupt wakeups, pageins, wired (7), resident (8), phys_footprint (9),
    # ... ri_lifetime_max_phys_footprint (30).
    return buf[8], buf[9], buf[30]


def process_table():
    rows = []
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def kind_of(cmd: str, bundle: str) -> str:
    rel = cmd[len(bundle):] if cmd.startswith(bundle) else cmd
    if " Helper" in rel:
        for flag, name in (("--type=renderer", "cef-renderer"), ("--type=gpu-process", "cef-gpu"),
                           ("--type=utility", "cef-utility"), ("--type=plugin", "cef-plugin")):
            if flag in rel:
                return name
        return "cef-helper"
    if rel.startswith("/Contents/MacOS/"):
        return "app"
    if "/bin/cmux-tui" in rel or "/bin/cmux " in rel or rel.endswith("/bin/cmux"):
        if "__terminal-host" in rel:
            return "terminal-host"
        if "--session cmux-chief" in rel:
            return "tui-daemon-chief"
        return "tui-daemon"
    if "/bin/acpmux" in rel:
        return "acpmux-" + (rel.split("/bin/acpmux", 1)[1].split() or ["agent"])[0]
    if "/bin/" in rel:
        return rel.split("/bin/", 1)[1].split()[0]
    if "com.apple.WebKit." in cmd:
        return "webkit-" + cmd.split("com.apple.WebKit.", 1)[1].split()[0].split(".")[0].lower()
    return os.path.basename(cmd.split()[0])


def owned(app_pid: int, bundle: str):
    """{pid: (kind, command)} for every process from the bundle, plus the
    WebKit processes the app is responsible for."""
    found = {}
    for pid, _ppid, cmd in process_table():
        if cmd.startswith(bundle):
            found[pid] = (kind_of(cmd, bundle), cmd)
        elif _responsible is not None and "com.apple.WebKit." in cmd and _responsible(pid) == app_pid:
            found[pid] = (kind_of(cmd, bundle), cmd)
    return found


def sample(app_pid: int, bundle: str, label: str, workspaces: int):
    rows = []
    for pid, (kind, cmd) in owned(app_pid, bundle).items():
        got = usage(pid)
        if got is None:
            continue
        rows.append({"pid": pid, "kind": kind, "rss_mb": round(got[0] / MB, 1),
                     "footprint_mb": round(got[1] / MB, 1), "max_footprint_mb": round(got[2] / MB, 1),
                     "command": cmd[:160]})
    rows.sort(key=lambda row: -row["footprint_mb"])
    kinds = {}
    for row in rows:
        entry = kinds.setdefault(row["kind"], {"count": 0, "rss_mb": 0.0, "footprint_mb": 0.0})
        entry["count"] += 1
        entry["rss_mb"] = round(entry["rss_mb"] + row["rss_mb"], 1)
        entry["footprint_mb"] = round(entry["footprint_mb"] + row["footprint_mb"], 1)
    return {"label": label, "workspaces": workspaces, "time": round(time.time()),
            "total_rss_mb": round(sum(r["rss_mb"] for r in rows), 1),
            "total_footprint_mb": round(sum(r["footprint_mb"] for r in rows), 1),
            "kinds": dict(sorted(kinds.items(), key=lambda item: -item[1]["footprint_mb"])),
            "processes": rows}


def print_sample(result, top: int):
    print(f"== {result['label']}: {result['workspaces']} workspaces, {len(result['processes'])} processes, "
          f"footprint {result['total_footprint_mb']:.0f} MB, RSS {result['total_rss_mb']:.0f} MB")
    print(f"   {'kind':<22}{'n':>4}{'footprint MB':>14}{'RSS MB':>10}")
    for kind, entry in result["kinds"].items():
        print(f"   {kind:<22}{entry['count']:>4}{entry['footprint_mb']:>14.1f}{entry['rss_mb']:>10.1f}")
    print(f"   top {top} processes by footprint:")
    for row in result["processes"][:top]:
        print(f"   {row['footprint_mb']:>8.1f} MB  RSS {row['rss_mb']:>7.1f}  max {row['max_footprint_mb']:>7.1f}  "
              f"{row['kind']:<20} pid {row['pid']}")
    sys.stdout.flush()


class App:
    """The app's control socket, through the app's own bundled CLI."""

    def __init__(self, bundle: str, socket_path: str):
        self.cli = os.path.join(bundle, "Contents/Resources/bin/cmux")
        self.socket = socket_path

    def run(self, action: str, target: str | None = None, **args):
        argv = [self.cli, "--app-socket", self.socket, "--json", "action", "run", action]
        if target:
            argv += ["--target", target]
        for name, value in args.items():
            argv += [f"--{name}", str(value)]
        out = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        try:
            return json.loads(out.stdout or "{}")
        except ValueError:
            return {"error": (out.stdout + out.stderr).strip()[:300]}

    def ping(self) -> bool:
        out = subprocess.run([self.cli, "--app-socket", self.socket, "app", "ping"],
                             capture_output=True, text=True, timeout=30)
        return out.returncode == 0


def open_workspace(app: App, recipe: str, url: str, index: int):
    """One workspace of `recipe` (kinds joined by +); returns its id or None."""
    made = app.run("workspace.newAtBottom")
    created = [item for item in made.get("created", []) if str(item).startswith("ws_")]
    if not created:
        print(f"   workspace.newAtBottom: {made.get('error') or made.get('message') or made}", file=sys.stderr)
        return None
    workspace = created[0]
    for kind in recipe.split("+"):
        if kind == "terminal":
            response = app.run("newSurface", target=workspace)
        elif kind == "browser":
            response = app.run("openBrowser.chromium", target=workspace, url=url)
        elif kind == "chat":
            # A prompt opens an agent chat tab. Fleet minis carry no agent
            # credentials, so the turn fails and the chat page stays.
            response = app.run("newTab.submit", target=workspace, text=f"memory bench chat {index}")
        else:
            raise SystemExit(f"bench-memory: unknown kind {kind!r} in --mix")
        if response.get("error") or response.get("code"):
            print(f"   {kind} in {workspace}: {response.get('message') or response.get('error')}", file=sys.stderr)
    # Tabs of a workspace that was never shown do not load; show it once, as
    # a user who opened it would, so its pages and renderers count.
    app.run("workspace.selectLast")
    return workspace


def close_workspace(app: App, workspace: str):
    response = app.run("closeWorkspace", target=workspace)
    if response.get("error") or response.get("code"):
        response = app.run("closeWorkspace", target=workspace, confirm="true")
    return response


def launch(bundle: str):
    """Starts the app with a scratch HOME, TMPDIR and config; returns (process, socket, scratch)."""
    binary_dir = os.path.join(bundle, "Contents/MacOS")
    binary = os.path.join(binary_dir, sorted(os.listdir(binary_dir))[0])
    if any(cmd.startswith(binary) for _, _, cmd in process_table()):
        raise SystemExit(f"bench-memory: {bundle} is already running; quit it first")
    scratch = tempfile.mkdtemp(prefix="bench-memory-")
    home = os.path.join(scratch, "home")
    os.makedirs(os.path.join(home, "Library"), exist_ok=True)
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.path.join(scratch, "tmp") + "/",
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json")}
    os.makedirs(env["TMPDIR"], exist_ok=True)
    dirs = ["/tmp", env["TMPDIR"]]
    before = {os.path.join(d, n) for d in dirs for n in os.listdir(d) if n.endswith(".sock")}
    process = subprocess.Popen([binary], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        fresh = [os.path.join(d, n) for d in dirs for n in os.listdir(d)
                 if n.endswith(".sock") and n.startswith("cmux") and os.path.join(d, n) not in before]
        for path in fresh:
            app = App(bundle, path)
            if app.ping():
                return process, app.socket, scratch
        time.sleep(1)  # test script: waiting for the launched app's socket
    process.kill()
    raise SystemExit("bench-memory: the launched app opened no socket within 90 s")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the .app bundle")
    parser.add_argument("--socket", help="attach: the running app's control socket")
    parser.add_argument("--app-pid", type=int, help="attach: the running app's pid")
    parser.add_argument("--workspaces", default="1,10,30")
    parser.add_argument("--mix", default="terminal+chat,terminal+browser,terminal")
    parser.add_argument("--settle", type=float, default=30)
    parser.add_argument("--churn-minutes", type=float, default=0)
    parser.add_argument("--sample-minutes", type=float, default=5)
    parser.add_argument("--url", default="https://example.com")
    parser.add_argument("--top", type=int, default=15)
    parser.add_argument("--out")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("bench-memory: macOS only (run it on a fleet or capture mini)")

    bundle = os.path.realpath(args.app)
    process = scratch = None
    if args.socket:
        if not args.app_pid:
            raise SystemExit("bench-memory: --socket needs --app-pid")
        socket_path, app_pid = args.socket, args.app_pid
    else:
        process, socket_path, scratch = launch(bundle)
        app_pid = process.pid
    app = App(bundle, socket_path)
    recipes = args.mix.split(",")
    counts = sorted(int(n) for n in args.workspaces.split(",") if n)
    report = {"app": bundle, "mix": recipes, "settle_s": args.settle, "samples": [],
              "webkit_attributed": _responsible is not None}
    opened = []

    def settle_and_sample(label):
        time.sleep(args.settle)  # test script: let the app and its helpers go idle
        result = sample(app_pid, bundle, label, len(opened) + 1)
        report["samples"].append(result)
        print_sample(result, args.top)
        return result

    try:
        settle_and_sample("idle-launch")
        for count in counts:
            # The launch workspace counts as the first one.
            while len(opened) + 1 < count:
                workspace = open_workspace(app, recipes[len(opened) % len(recipes)], args.url, len(opened))
                if workspace is None:
                    break
                opened.append(workspace)
            settle_and_sample(f"idle-{count}")
        if args.churn_minutes > 0:
            end = time.monotonic() + args.churn_minutes * 60
            next_sample = time.monotonic() + args.sample_minutes * 60
            cycles = 0
            while time.monotonic() < end:
                workspace = open_workspace(app, recipes[cycles % len(recipes)], args.url, 1000 + cycles)
                time.sleep(2)  # test script: let the new tabs load before closing them
                if workspace:
                    close_workspace(app, workspace)
                cycles += 1
                if time.monotonic() >= next_sample:
                    settle_and_sample(f"churn-{cycles}")
                    next_sample = time.monotonic() + args.sample_minutes * 60
            report["churn_cycles"] = cycles
            churn = [s for s in report["samples"] if s["label"].startswith("churn-")]
            base = report["samples"][-len(churn) - 1] if churn else None
            if base and churn:
                growth = {}
                for kind in set(base["kinds"]) | set(churn[-1]["kinds"]):
                    first = base["kinds"].get(kind, {}).get("footprint_mb", 0.0)
                    last = churn[-1]["kinds"].get(kind, {}).get("footprint_mb", 0.0)
                    growth[kind] = round(last - first, 1)
                report["churn_growth_mb"] = dict(sorted(growth.items(), key=lambda item: -item[1]))
                print(f"== churn: {cycles} open/close cycles; footprint growth at {base['workspaces']} workspaces:")
                for kind, delta in report["churn_growth_mb"].items():
                    print(f"   {kind:<22}{delta:>+10.1f} MB")
    finally:
        for workspace in opened:
            close_workspace(app, workspace)
        if process is not None:
            app.run("quit")
            try:
                process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.send_signal(signal.SIGTERM)
                process.wait(timeout=10)
            # The app's daemons (cmux-tui, acpmux) detach and outlive it. In
            # launch mode they run from this bundle with this run's scratch
            # HOME, so end exactly those pids.
            for pid, (kind, cmd) in owned(app_pid, bundle).items():
                if cmd.startswith(bundle):
                    try:
                        os.kill(pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        if args.out:
            with open(args.out, "w") as handle:
                json.dump(report, handle, indent=2)
            print(f"bench-memory: wrote {args.out}")
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    main()
