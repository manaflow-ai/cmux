#!/usr/bin/env python3
"""The RAM baseline: total physical footprint of cmux NEXT and of other desktop apps, all processes.

Leo, 2026-11-08: "how good can we get our baseline down to?" This runs the same workloads on the
cmux app and on other apps, each from a fresh launch with a scratch HOME, and prints one table of
total phys_footprint (what Activity Monitor calls Memory) summed over every process the app owns:
the app, its Chromium or Electron helpers (renderers, GPU, utility), the WebKit processes it is
responsible for, and its daemons.

Workloads (cmux, built over the app socket by bench_memory.py, one fresh launch each):
  idle     just launched, one window with its first workspace
  light    2 workspaces: the first one's terminal, then a chat and one browser tab
  medium   6 workspaces: 4 chats with history, a terminal in each, 3 browser tabs
  extreme  30 workspaces: chats, browser tabs and several terminals in each

Other apps (--peer BUNDLE, repeatable) are launched with a scratch HOME and their own
--user-data-dir, so they start signed out and apart from any copy already running. Only the
launched process, its descendants and the processes it is responsible for count, and only the
launch's own process group is ended. A signed-out app shows its sign-in page, so only `idle` is
measured for them; --attach NAME=PID records a running, signed-in app as it is, labelled as such.

Usage:
  bench_ram_baseline.py --app CMUX_BUNDLE [--peer BUNDLE]... [--attach NAME=PID]...
      [--workloads idle,light,medium,extreme] [--settle 60] [--samples 3]
      [--fake-agent cmux-tui/crates/acpmux/tests/fake_agent.py] [--out DIR]

macOS only. It launches GUI apps: run it on an idle Mac with a login session.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory  # noqa: E402  (usage, process_table, _responsible, MB)

# workspaces, mix for bench_memory.py (the launch workspace counts as the first one and keeps its
# terminal; every chat workspace opens on its chat with a terminal first under --fake-agent).
WORKLOADS = {
    "idle": (1, "none"),
    "light": (2, "chat+browser"),
    "medium": (6, "chat+browser,chat+browser,chat+browser,chat,terminal"),
    "extreme": (30, "chat+browser+terminal,chat+terminal,terminal+browser+browser,terminal+terminal+chat"),
}
# A chat with history: its first prompt is long, and the fake agent echoes it back.
HISTORY_PROMPT = " ".join(
    f"Paragraph {n}: the build failed on step {n} because the cache key changed; retry with the "
    f"old key, then compare the two logs line by line and list every difference." for n in range(120))


def tree(root: int) -> list[dict]:
    """`root`, its descendants and the processes it is responsible for, with their footprints."""
    rows = bench_memory.process_table()
    children: dict[int, list[int]] = {}
    for pid, ppid, _ in rows:
        children.setdefault(ppid, []).append(pid)
    found, stack = set(), [root]
    while stack:
        pid = stack.pop()
        if pid not in found:
            found.add(pid)
            stack.extend(children.get(pid, []))
    if bench_memory._responsible is not None:
        found |= {pid for pid, _, _ in rows if pid != root and bench_memory._responsible(pid) == root}
    command = {pid: cmd for pid, _, cmd in rows}
    out = []
    for pid in found:
        got = bench_memory.usage(pid)
        if got is not None:
            out.append({"pid": pid, "rss_mb": round(got[0] / bench_memory.MB, 1),
                        "footprint_mb": round(got[1] / bench_memory.MB, 1), "command": command.get(pid, "")[:160]})
    return sorted(out, key=lambda row: -row["footprint_mb"])


def median(values: list[float]) -> float | None:
    ordered = sorted(values)
    return ordered[len(ordered) // 2] if ordered else None


def sample_tree(root: int, samples: int, gap: float = 10) -> dict:
    totals, rows = [], []
    for index in range(samples):
        rows = tree(root)
        if not rows:
            break
        totals.append(round(sum(row["footprint_mb"] for row in rows), 1))
        if index + 1 < samples:
            time.sleep(gap)  # bench: spacing between samples
    return {"footprint_mb": median(totals), "samples_mb": totals, "processes": len(rows), "top": rows[:12]}


def peer_idle(bundle: str, settle: float, samples: int) -> dict:
    with open(os.path.join(bundle, "Contents", "Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    binary = os.path.join(bundle, "Contents", "MacOS", info["CFBundleExecutable"])
    scratch = tempfile.mkdtemp(prefix="ram-baseline-")
    home = os.path.join(scratch, "home")
    os.makedirs(os.path.join(home, "Library"), exist_ok=True)
    env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.path.join(scratch, "tmp") + "/",
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    os.makedirs(env["TMPDIR"])
    log = open(os.path.join(scratch, "app.log"), "w")
    # --user-data-dir keeps an Electron or Chromium app apart from a copy already running (its
    # single-instance lock is per data dir); a native app ignores the argument.
    child = subprocess.Popen([binary, f"--user-data-dir={home}/user-data"], env=env, stdout=log, stderr=log,
                             stdin=subprocess.DEVNULL, start_new_session=True)
    result = {"bundle": bundle, "version": info.get("CFBundleShortVersionString"), "signed_in": False}
    try:
        time.sleep(settle)  # bench: let the fresh app go idle
        if child.poll() is not None:
            log.flush()
            with open(os.path.join(scratch, "app.log"), errors="replace") as handle:
                result["error"] = f"the app exited ({child.returncode}): {handle.read()[-400:]}"
            return result
        result.update(sample_tree(child.pid, samples))
        return result
    finally:
        for sig, grace in ((signal.SIGTERM, 8), (signal.SIGKILL, 0)):
            try:
                os.killpg(child.pid, sig)
            except (ProcessLookupError, PermissionError):  # the group is gone (or only its zombies are left)
                break
            time.sleep(grace)  # bench: let the app quit before the hard kill
        child.wait(timeout=10)
        shutil.rmtree(scratch, ignore_errors=True)


def cmux_workload(app: str, workload: str, settle: float, fake_agent: str | None, out_dir: str) -> dict:
    count, mix = WORKLOADS[workload]
    out = os.path.join(out_dir, f"cmux-{workload}.json")
    argv = [sys.executable, os.path.join(HERE, "bench_memory.py"), "--app", app, "--workspaces", str(count),
            "--mix", mix, "--settle", str(settle), "--top", "20", "--out", out]
    if fake_agent and "chat" in mix:
        argv += ["--fake-agent", fake_agent]
        if workload != "light":
            argv += ["--chat-prompt", HISTORY_PROMPT]
    done = subprocess.run(argv)
    if done.returncode != 0 or not os.path.exists(out):
        return {"error": f"bench_memory.py exited {done.returncode}"}
    with open(out) as handle:
        report = json.load(handle)
    last = report["samples"][-1]
    # bench_memory.py goes on, and exits 0, when a workspace or a pane fails to open: a sample of fewer
    # workspaces or panes than the workload asked for is not that workload.
    failures = last.get("pane_failures", 0)
    if last["workspaces"] < count or failures:
        return {"error": f"partial {workload}: {last['workspaces']} of {count} workspaces, {failures} panes failed "
                         f"({'; '.join(report.get('pane_failures', [])[:3])})",
                "partial_footprint_mb": last["total_footprint_mb"]}
    return {"footprint_mb": last["total_footprint_mb"], "processes": len(last["processes"]),
            "workspaces": last["workspaces"], "kinds": last["kinds"], "top": last["processes"][:12]}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help="the cmux NEXT bundle (a Release build measures what users get)")
    parser.add_argument("--peer", action="append", default=[], help="another app's bundle, launched signed out")
    parser.add_argument("--attach", action="append", default=[], metavar="NAME=PID",
                        help="a running app recorded as it is (signed in, its own state)")
    parser.add_argument("--workloads", default="idle,light,medium,extreme")
    parser.add_argument("--settle", type=float, default=60)
    parser.add_argument("--samples", type=int, default=3)
    parser.add_argument("--fake-agent", help="the ACP test agent whose chats answer (bench_memory --fake-agent)")
    parser.add_argument("--out", default=".")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise SystemExit("bench-ram-baseline: macOS only")
    workloads = [w for w in args.workloads.split(",") if w]
    unknown = [w for w in workloads if w not in WORKLOADS]
    if unknown:
        parser.error(f"unknown workloads {unknown}; known: {', '.join(WORKLOADS)}")
    os.makedirs(args.out, exist_ok=True)
    results: dict[str, dict[str, dict]] = {}
    if args.app:
        app = os.path.realpath(args.app)
        results["cmux"] = {w: cmux_workload(app, w, args.settle, args.fake_agent, args.out) for w in workloads}
    for bundle in args.peer:
        bundle = os.path.realpath(bundle)
        name = os.path.basename(bundle).removesuffix(".app")
        results[name] = {"idle": peer_idle(bundle, args.settle, args.samples)}
    for spec in args.attach:
        name, _, pid = spec.partition("=")
        results[f"{name} (running, signed in)"] = {"as-is": dict(sample_tree(int(pid), args.samples), signed_in=True)}
    with open(os.path.join(args.out, "ram-baseline.json"), "w") as handle:
        json.dump({"time": round(time.time()), "settle_s": args.settle, "results": results}, handle, indent=2)
    columns = workloads + (["as-is"] if args.attach else [])
    print(f"\n{'app':<34}" + "".join(f"{c:>12}" for c in columns) + "   (total phys_footprint MB, all processes)")
    for name, by_workload in results.items():
        cells = []
        for column in columns:
            got = by_workload.get(column) or {}
            value = got.get("footprint_mb")
            cells.append(f"{value:>12.0f}" if isinstance(value, (int, float)) else f"{('err' if got.get('error') else '-'):>12}")
        print(f"{name:<34}" + "".join(cells))
    for name, by_workload in results.items():
        for column, got in by_workload.items():
            if got.get("error"):
                print(f"{name} {column}: {got['error']}")
    print(f"bench-ram-baseline: wrote {os.path.join(args.out, 'ram-baseline.json')}")
    if any(got.get("error") for by_workload in results.values() for got in by_workload.values()):
        raise SystemExit(1)  # a failed or partial workload is not a baseline


if __name__ == "__main__":
    main()
