#!/usr/bin/env python3
"""Idle CPU and wakeups of a cmux NEXT build: the app, its acpmux and its cmux-tui, after N minutes idle.

    idle_cpu.py (--artifact sha256:HEX | --app APP) [--minutes 10] [--window 60] [--windows 3]
                [--chats 0] [--fake-agent SCRIPT] [--no-sample] [--budget-cpu 1.0] [--budget-wakeups 1.0]
                [--out DIR]

A dogfood build must rest when nobody uses it: on 2026-11-04 Lawrence's idle Mac had acpmux daemons at
20-52 % CPU each (cmux-ad m9). This launches the build as a first install would (an empty HOME, no
defaults: scripts/ci/fresh_home_launch_smoke.py), waits for Home in its first window, optionally makes
CHATS agent chats whose first turn has ended (the acpmux test agent, as bench_memory.py --fake-agent),
then leaves the app alone for MINUTES with no call into it. It then measures every process of the
bundle over WINDOWS windows of WINDOW seconds each, from proc_pid_rusage at both ends of each window (no
call into the measured processes): CPU % of one core, package-idle plus interrupt wakeups per second
and context switches per second. A process is judged by its median window. Last, `sample PID 5` of each
acpmux and cmux-tui daemon process and of any process above the CPU budget: the heaviest stacks name the
loop that runs while idle.

Output: IDLE-CPU lines, one per process and window summary, then IDLE-CPU-VERDICT pass|fail with the
processes over budget (acpmux and cmux-tui daemon processes only: CPU % median > --budget-cpu or wakeups/s
median > --budget-wakeups). --out keeps report.json and the samples (sample-<kind>-<pid>.txt).
Exit 0: within budget. 1: over budget. 3: could not run (no app, no GUI session, Home never rendered).

Run it on a quiet fleet Mac only, through the mini scheduler (scripts/measure/idle-cpu.sh); never on a
person's Mac. It never touches another app: every process it starts runs under its own /tmp root and is
stopped by exact pid.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "ci"))

import bench_memory  # noqa: E402  (scripts/cmux-next: process table, rusage, the app's CLI, test chats)
import fresh_home_launch_smoke as smoke  # noqa: E402  (scripts/ci: the first-install launch)

CONTROLLER = os.environ.get("CMUX_CI_CONTROLLER") or "http://100.89.225.106:18765"
# The processes the verdict judges: the daemons that must rest. The app and its helpers are reported too.
DAEMON_KINDS = re.compile(r"^(acpmux-.*|tui-daemon.*|terminal-host)$")
SAMPLE_KINDS = re.compile(r"^(acpmux-.*|tui-daemon.*)$")


def log(message: str) -> None:
    print(message, flush=True)


def fetch_app(digest: str, cache_root: Path) -> Path:
    """The build's app from the controller store by sha256 (checked), cached per digest."""
    hexd = digest.removeprefix("sha256:")
    if not re.fullmatch(r"[0-9a-f]{64}", hexd):
        raise SystemExit("idle-cpu: --artifact must be sha256:<64 hex>")
    folder = cache_root / hexd
    apps = sorted(folder.glob("x/*.app")) if (folder / "ok").exists() else []
    if apps:
        log(f"idle-cpu: app of {hexd[:12]} from the cache")
        return apps[0]
    shutil.rmtree(folder, ignore_errors=True)
    (folder / "x").mkdir(parents=True)
    with urllib.request.urlopen(f"{CONTROLLER}/v1/artifacts/sha256:{hexd}/url", timeout=60) as reply:
        url = json.load(reply).get("url") or ""
    if not re.fullmatch(r"https://[^\s\"']+", url):
        raise SystemExit(f"idle-cpu: the controller gave no download URL for {hexd[:12]}")
    archive = folder / "app.zip"
    # The URL is short-lived and signed: never printed.
    subprocess.run(["curl", "-fsS", "--retry", "3", "-o", str(archive), url], check=True, timeout=1800)
    digest_now = hashlib.sha256()
    with open(archive, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest_now.update(chunk)
    if digest_now.hexdigest() != hexd:
        raise SystemExit(f"idle-cpu: the download of {hexd[:12]} has sha256 {digest_now.hexdigest()[:12]}")
    subprocess.run(["ditto", "-x", "-k", str(archive), str(folder / "x")], check=True, timeout=600)
    archive.unlink()
    apps = sorted((folder / "x").glob("*.app"))
    if not apps:
        raise SystemExit(f"idle-cpu: the artifact {hexd[:12]} holds no .app")
    (folder / "ok").touch()
    # Keep the newest four builds.
    for old in sorted((p for p in cache_root.iterdir() if p.is_dir() and p != folder),
                      key=lambda p: p.stat().st_mtime)[:-3]:
        shutil.rmtree(old, ignore_errors=True)
    return apps[0]


def switches(pid: int) -> int | None:
    """Context switches of all threads (proc_pidinfo PROC_PIDTASKINFO pti_csw), or None once the pid is gone."""
    import ctypes
    buf = (ctypes.c_int32 * 32)()
    size = ctypes.sizeof(buf)
    got = bench_memory._libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(4), ctypes.c_uint64(0),
                                             ctypes.byref(buf), ctypes.c_int(size))
    if got < 96:
        return None
    # proc_taskinfo: 6 u64 (12 i32 words), then policy, faults, pageins, cow_faults, messages_sent,
    # messages_received, syscalls_mach, syscalls_unix, csw (word 20), threadnum, numrunning, priority.
    return int(buf[20])


def measure(app_pid: int, bundle: str, windows: int, window: float) -> list[dict]:
    """Per process: kind, command and each window's CPU %, wakeups/s, switches/s, then the medians."""
    procs = bench_memory.owned(app_pid, bundle)
    marks = []
    for index in range(windows + 1):
        if index:
            time.sleep(window)  # the measured idle window: no call into the app or its processes
        marks.append({pid: (bench_memory.usage(pid), switches(pid)) for pid in procs})
    rows = []
    for pid, (kind, cmd) in procs.items():
        per = []
        for before, after in zip(marks, marks[1:]):
            (u0, c0), (u1, c1) = before.get(pid, (None, None)), after.get(pid, (None, None))
            if u0 is None or u1 is None:
                continue
            per.append({"cpu_pct": round(100 * (u1[3] - u0[3]) / 1e9 / window, 3),
                        "wakeups_per_s": round((u1[4] - u0[4]) / window, 2),
                        "switches_per_s": round((c1 - c0) / window, 2) if c0 is not None and c1 is not None else None})
        if not per:
            continue
        def mid(key):
            values = sorted(w[key] for w in per if w[key] is not None)
            return values[len(values) // 2] if values else None
        rows.append({"pid": pid, "kind": kind, "command": cmd[:200], "windows": per,
                     "cpu_pct": mid("cpu_pct"), "wakeups_per_s": mid("wakeups_per_s"),
                     "switches_per_s": mid("switches_per_s")})
    rows.sort(key=lambda row: -(row["cpu_pct"] or 0))
    return rows


def top_lines(pids: list[int]) -> str:
    """`top` idle wakeups (idlew) and CPU of PIDS over one 5 s sample, as a cross-check."""
    if not pids:
        return ""
    argv = ["top", "-l", "2", "-s", "5", "-stats", "pid,command,cpu,idlew,csw,threads"]
    for pid in pids[:20]:
        argv += ["-pid", str(pid)]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError) as error:
        return f"(top failed: {error})"
    # The second sample is the one with rates.
    parts = out.split("PID ")
    return ("PID " + parts[-1]).rstrip() if len(parts) > 1 else out[-2000:]


def heaviest(text: str, lines: int = 45) -> str:
    """The call graph's first LINES lines and the 'Sort by top of stack' list of a `sample` report."""
    graph = text.split("Call graph:", 1)
    head = "\n".join(graph[1].splitlines()[:lines]) if len(graph) > 1 else ""
    tops = text.split("Sort by top of stack, same collapsed", 1)
    tail = "\n".join(tops[1].splitlines()[:20]) if len(tops) > 1 else ""
    return f"Call graph (first {lines} lines):\n{head}\nTop of stack:\n{tail}"


def sample(pid: int, kind: str, out: Path | None) -> None:
    target = (out or Path("/tmp")) / f"sample-{kind}-{pid}.txt"
    try:
        subprocess.run(["sample", str(pid), "5", "-mayDie", "-file", str(target)],
                       capture_output=True, text=True, timeout=90)
        text = target.read_text(errors="replace")
    except (OSError, subprocess.SubprocessError) as error:
        log(f"IDLE-CPU-SAMPLE {kind} pid={pid} failed: {error}")
        return
    log(f"IDLE-CPU-SAMPLE {kind} pid={pid} ({target.name})\n{heaviest(text)}\nIDLE-CPU-SAMPLE-END {kind} pid={pid}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--artifact", help="sha256:HEX of a fleet build's app zip (cmux-ci status JOB: artifact)")
    source.add_argument("--app", help="an app bundle on this Mac")
    parser.add_argument("--minutes", type=float, default=10.0, help="idle time before the measure")
    parser.add_argument("--window", type=float, default=60.0, help="seconds per measured window")
    parser.add_argument("--windows", type=int, default=3, help="measured windows (median judged)")
    parser.add_argument("--chats", type=int, default=0, help="agent chats with a finished turn, made before the idle")
    parser.add_argument("--fake-agent", default=str(HERE.parent.parent / "cmux-tui/crates/acpmux/tests/fake_agent.py"))
    parser.add_argument("--no-sample", action="store_true")
    parser.add_argument("--budget-cpu", type=float, default=1.0, help="CPU %% of one core per daemon process")
    parser.add_argument("--budget-wakeups", type=float, default=1.0, help="wakeups per second per daemon process")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    out = Path(args.out) if args.out else None
    if out:
        out.mkdir(parents=True, exist_ok=True)
    cache = Path(os.environ.get("CI_SHARED_CACHE_DIR") or "/tmp") / "idle-cpu-apps"
    cache.mkdir(parents=True, exist_ok=True)
    app_source = fetch_app(args.artifact, cache) if args.artifact else Path(args.app)
    result: dict = {"minutes": args.minutes, "window_s": args.window, "windows": args.windows, "chats": args.chats,
                    "host": os.uname().nodename, "artifact": args.artifact}
    verdict = {"status": 3}

    def after_render(process, socket_path, env, app, out_dir, report):
        bundle = str(app)
        client = bench_memory.App(bundle, str(socket_path))
        made = 0
        if args.chats > 0:
            chats = bench_memory.FakeChats(client, bundle, args.fake_agent)
            for index in range(args.chats):
                made += chats.open(index) is not None
            log(f"idle-cpu: {made} of {args.chats} chats made, their first turn answered")
        result["chats_made"] = made
        log(f"idle-cpu: idle {args.minutes:g} min from now, no call into the app")
        time.sleep(args.minutes * 60)  # the idle period itself
        if process.poll() is not None:
            verdict["status"] = 3
            return [f"the app exited during the idle period (status {process.returncode})"]
        rows = measure(process.pid, bundle, args.windows, args.window)
        result["processes"] = rows
        for row in rows:
            log(f"IDLE-CPU {row['kind']} pid={row['pid']} cpu_pct={row['cpu_pct']} wakeups_per_s={row['wakeups_per_s']} "
                f"switches_per_s={row['switches_per_s']} windows={json.dumps([[w['cpu_pct'], w['wakeups_per_s']] for w in row['windows']])}")
        kinds: dict = {}
        for row in rows:
            entry = kinds.setdefault(row["kind"], {"n": 0, "cpu_pct": 0.0, "wakeups_per_s": 0.0})
            entry["n"] += 1
            entry["cpu_pct"] = round(entry["cpu_pct"] + row["cpu_pct"], 3)
            entry["wakeups_per_s"] = round(entry["wakeups_per_s"] + row["wakeups_per_s"], 2)
        result["kinds"] = kinds
        for kind, entry in sorted(kinds.items(), key=lambda item: -item[1]["cpu_pct"]):
            log(f"IDLE-CPU-KIND {kind} n={entry['n']} cpu_pct={entry['cpu_pct']} wakeups_per_s={entry['wakeups_per_s']}")
        top = top_lines([row["pid"] for row in rows if SAMPLE_KINDS.match(row["kind"]) or row["kind"] == "app"])
        log("IDLE-CPU-TOP\n" + top)
        if not args.no_sample:
            for row in rows:
                if SAMPLE_KINDS.match(row["kind"]) or row["cpu_pct"] > args.budget_cpu:
                    sample(row["pid"], row["kind"], out)
        over = [row for row in rows if DAEMON_KINDS.match(row["kind"])
                and (row["cpu_pct"] > args.budget_cpu or row["wakeups_per_s"] > args.budget_wakeups)]
        result["over_budget"] = [{k: row[k] for k in ("kind", "pid", "cpu_pct", "wakeups_per_s")} for row in over]
        verdict["status"] = 1 if over else 0
        return []

    smoke.AFTER_RENDER = after_render
    status = smoke.main(["--app", str(app_source), "--seconds", "5", "--startup-timeout", "180",
                         *(["--out", str(out / "launch")] if out else [])])
    if status != 0 and verdict["status"] != 1:
        verdict["status"] = 3
    over = result.get("over_budget") or []
    word = {0: "pass", 1: "fail"}.get(verdict["status"], "cannot-run")
    detail = "; ".join(f"{r['kind']} pid {r['pid']} cpu {r['cpu_pct']}% wakeups {r['wakeups_per_s']}/s" for r in over)
    log(f"IDLE-CPU-VERDICT {word} minutes={args.minutes:g} chats={result.get('chats_made', 0)} "
        f"budget cpu<={args.budget_cpu}% wakeups<={args.budget_wakeups}/s per daemon process"
        + (f": {detail}" if detail else ""))
    if out:
        (out / "report.json").write_text(json.dumps(result, indent=2, sort_keys=True))
    return verdict["status"]


if __name__ == "__main__":
    sys.exit(main())
