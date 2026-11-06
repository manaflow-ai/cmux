#!/usr/bin/env python3
"""Relaunch to the first live chat event: how long a cmux NEXT app takes, after it relaunches, to
show a running agent's reply streaming again in the chat it shows.

Leo, 2026-11-04: "i feel like the restarted after nightly update does too many layout
shifts/flicker renderings and takes too long to reconnect acpmux or whatever". This is the
reconnect half (manaflow-ai/cmuxterm-hq#6338).

The load: `--chats` local chats on the app's own acpmux daemon (the test agent, idle_cost_agent.py),
each in its own workspace and shown once; the first one streams a reply (`stream:`, `--rate` words
a second) through the whole run, and its workspace is the one shown when the app quits. Then, for
each mode in `--modes`, `--rounds` times: quit the app (Quit and Keep Sessions, as an update relaunch keeps them; SIGTERM if it is still up
after 20 s), do what the mode says, relaunch it into the same HOME and state, and wait until the
shown chat gets a live event (one that arrives within LIVE_EVENT_LAG_MS of when acpmux recorded it,
webviews perf.ts). Modes:

  warm     the daemon keeps running (its streaming turn keeps it), same build: a plain relaunch.
  update   the bundle is replaced in place while the app is gone, as Sparkle's installer does (a copy
           staged beside it, swapped in atomically, the old one deleted), so the running daemon's
           executable is gone: the relaunched app hands it off (AcpmuxVersionHandoff) and starts
           the bundled one, which adopts the streaming agent.
  cold     the daemon is stopped (SIGTERM) after the quit: the relaunched app starts one.

Each round's phases, in ms since the relaunched app's process started (debug.timings' launch marks,
and the shown page's own wall-clock marks lined up with them through `process_start_epoch_ms`):

  app main (main_start) -> did_finish_launching_end -> acpmux.lookup_start -> acpmux.adopted ->
  acpmux.status_answered -> acpmux.handed_off (update) -> acpmux.spawn_start -> acpmux.spawn_ready ->
  acpmux.lookup_end -> agent_pane.view_created -> agent_pane.page_loaded -> page handshakeStart ->
  agent_pane.handshake_end / page handshakeReady -> page connectStart -> agent_pane.transport_open ->
  page connected -> agent_pane.painted -> page firstEvent -> page liveEvent

plus the daemon's own log lines (stopping, ready) when its log has them. Prints one
PERF-RELAUNCH line per round, a per-mode median table between PERF-RELAUNCH-TABLE-BEGIN and -END,
and writes the JSON to --out.

  bench_relaunch_reconnect.py --app BUNDLE [--modes warm,update,cold] [--rounds 3] [--chats 6]
      [--out FILE.json] [--md FILE.md]
One command on the fleet (bench_power.py's `relaunch-reconnect` scenario; --arg=chats=N sets the chats):
  cmux-ci run --class exclusive --measurement --display --label measure \\
    --script scripts/measure/perf-idle-power.sh --ref SHA --arg=scenarios=relaunch-reconnect \\
    --arg=config=bench --artifact artifacts/perf-idle-power.json
macOS only, on a fleet Mac (it launches the app with a scratch HOME).
"""
from __future__ import annotations

import argparse
import ctypes
import glob
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402  (launch, App, FakeChats, end_bundle, process_table)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)
import idle_cost_load as load  # noqa: E402  (new_session, stream, open_workspace)

AGENT = os.path.join(HERE, "idle_cost_agent.py")
# Every phase, in the order the relaunch reaches them: (column, source, mark).
PHASES = [
    ("app main", "app", "main_start"),
    ("did finish launching", "app", "did_finish_launching_end"),
    ("lookup start", "app", "acpmux.lookup_start"),
    ("build homes adopted", "app", "acpmux.adopted"),
    ("daemon status answered", "app", "acpmux.status_answered"),
    ("bundled build read", "app", "acpmux.bundled_build_read"),
    ("old daemon handed off", "app", "acpmux.handed_off"),
    ("daemon spawn start", "app", "acpmux.spawn_start"),
    ("daemon ready (log)", "daemon", "ready"),
    ("daemon spawn ready", "app", "acpmux.spawn_ready"),
    ("lookup end", "app", "acpmux.lookup_end"),
    ("pane view created", "app", "agent_pane.view_created"),
    ("page loaded", "app", "agent_pane.page_loaded"),
    ("page handshake start", "page", "handshakeStart"),
    ("handshake answered", "page", "handshakeReady"),
    ("page connect start", "page", "connectStart"),
    ("transport open", "app", "agent_pane.transport_open"),
    ("page socket open", "page", "socketOpen"),
    ("page initialized", "page", "initialized"),
    ("page chat attached", "page", "attached"),
    ("page connected", "page", "connected"),
    ("page chat drawn", "page", "chatDrawn"),
    ("page paint posted", "page", "paintPosted"),
    ("pane painted", "app", "agent_pane.painted"),
    ("first event", "page", "firstEvent"),
    ("first live event", "page", "liveEvent"),
]


ANSI = re.compile(r"\x1b\[[0-9;]*m")
# Daemon log lines a round keeps (after the quit): what stopped, started, adopted or replayed.
LOG_KEEP = re.compile(r"ready|stopping|shutting down|stopped|owner|adopt|replay|host|handoff|lock|resum|warn|error", re.I)


def daemon_log(home: str, since: float) -> tuple[dict, list[str]]:
    """The daemon log since `since` (ms since 1970): the first `acpmux ready` and `shutting down`
    times, and the lines LOG_KEEP matches (at most 300)."""
    found: dict[str, float] = {}
    kept: list[str] = []
    for path in sorted(glob.glob(os.path.join(home, "**", "*.log"), recursive=True)):
        try:
            with open(path, errors="replace") as handle:
                lines = handle.readlines()[-20000:]
        except OSError:
            continue
        for raw in lines:
            line = ANSI.sub("", raw).rstrip()
            stamp = re.match(r"\s*(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?)(Z|[+-]\d\d:?\d\d)?", line)
            if not stamp:
                continue
            text = stamp.group(1)[:26] + (stamp.group(2) or "Z").replace("Z", "+00:00")
            try:
                at = datetime.fromisoformat(text).timestamp() * 1000
            except ValueError:
                continue
            if at < since:
                continue
            for name, needle in (("ready", "acpmux ready pid="), ("shutting_down", "shutting down")):
                if needle in line and (name not in found or at < found[name]):
                    found[name] = at
            if LOG_KEEP.search(line) and len(kept) < 300:
                kept.append(f"{os.path.basename(path)}: {line[:400]}")
    return found, kept


RENAME_SWAP = 0x2  # <stdio.h>: renamex_np swaps the two paths


def quit_app(sock: str, bundle: str):
    """The Quit action, as a person's Cmd-Q; SIGTERM (also a normal quit) when the app is still up after 20 s."""
    binary_dir = os.path.join(bundle, "Contents/MacOS")
    apps = {pid for pid, _, cmd in bm.process_table() if cmd.startswith(binary_dir + "/") and not bm.is_clone_cleanup(cmd)}
    bm.App(bundle, sock).action("quitKeepSessions", wait=False)
    left = bm.still_running(apps, 20)
    if left:
        print(f"   quit: the app was still up after 20 s; SIGTERM {sorted(left)}", file=sys.stderr)
        bm.end_processes(left)


def daemon_pids(bundle: str) -> set[int]:
    return {pid for pid, _, cmd in bm.process_table()
            if bm.in_bundle(cmd, bundle) is not None and "/bin/acpmux daemon run" in cmd}


def replace_bundle(bundle: str):
    """An update's swap, as Sparkle's installer does it (SUPlainInstaller): the new copy (an APFS
    clone) staged in a temporary folder on the bundle's volume, swapped with the installed bundle
    in one `renamex_np(RENAME_SWAP)`, so the bundle's path never goes missing, then the old bundle
    deleted. Sparkle deletes it right after it asks for the relaunch, seconds before the new app
    looks at its daemon; deleting it before the relaunch keeps that order every round, so the
    running daemon's executable is gone and the relaunched app hands it off
    (AcpmuxVersionHandoff.replaced) as it does after a real update."""
    bundle = bundle.rstrip("/")
    staged = tempfile.mkdtemp(prefix=".bench-update-", dir=os.path.dirname(bundle))
    try:
        new = os.path.join(staged, os.path.basename(bundle))
        subprocess.run(["cp", "-cR", bundle, new], check=True, timeout=600)
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renamex_np(new.encode(), bundle.encode(), RENAME_SWAP) != 0:
            raise OSError(ctypes.get_errno(), "renamex_np(RENAME_SWAP) failed", bundle)
    finally:
        shutil.rmtree(staged, ignore_errors=True)


def wait_live(sock: str, seconds: float) -> dict:
    """The shown pane's launch marks once it has a live event (or `seconds` pass)."""
    deadline, last = time.monotonic() + seconds, {}
    while time.monotonic() < deadline:
        stats = bp.rpc(sock, "debug.agent_pane", {"action": "perf_stats"}, timeout=15)
        launch = stats.get("launch") if isinstance(stats, dict) else None
        if isinstance(launch, dict):
            last = launch
            if "liveEvent_epoch_ms" in launch:
                return launch
        time.sleep(0.25)  # test script: the page records its own times; this only waits for them
    return last


def round_phases(timings: dict, page: dict, daemon: dict) -> dict:
    """Each phase in ms since the app process started (None when it never happened)."""
    zero = timings.get("process_start_epoch_ms")
    marks = timings.get("launch_ms_since_process_start") or {}
    out = {}
    for column, source, mark in PHASES:
        value = None
        if source == "app":
            value = marks.get(mark)
        elif zero is not None and source == "page" and page.get(f"{mark}_epoch_ms") is not None:
            value = page[f"{mark}_epoch_ms"] - zero
        elif zero is not None and source == "daemon" and daemon.get(mark) is not None:
            value = daemon[mark] - zero
        out[column] = None if value is None else round(float(value), 1)
    out["handshake attempts"] = page.get("handshake_attempts")
    return out


def median_table(rounds: list[dict], modes: list[str]) -> str:
    def cell(values):
        values = [v for v in values if v is not None]
        return "-" if not values else f"{statistics.median(values):.0f}"
    lines = ["| phase (ms since process start, median) | " + " | ".join(modes) + " |",
             "| --- |" + " --- |" * len(modes)]
    for column, _, _ in PHASES + [("handshake attempts", "", "")]:
        lines.append(f"| {column} | " + " | ".join(
            cell([r["phases"].get(column) for r in rounds if r["mode"] == mode]) for mode in modes) + " |")
    lines.append("| rounds live | " + " | ".join(
        f"{sum(1 for r in rounds if r['mode'] == mode and r['phases'].get('first live event') is not None)}"
        f"/{sum(1 for r in rounds if r['mode'] == mode)}" for mode in modes) + " |")
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--modes", default="warm,update,cold")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--chats", type=int, default=6, help="local chats, each in its own workspace")
    parser.add_argument("--rate", type=float, default=10, help="streamed words a second")
    parser.add_argument("--settle", type=float, default=10, help="seconds after the shown chat is live before each quit")
    parser.add_argument("--live-timeout", type=float, default=120)
    parser.add_argument("--config", default="{}")
    parser.add_argument("--out")
    parser.add_argument("--md")
    args = parser.parse_args(argv)
    modes = [mode for mode in args.modes.split(",") if mode]
    for mode in modes:
        if mode not in ("warm", "update", "cold"):
            raise SystemExit(f"bench-relaunch: unknown mode {mode}")
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(args.app)
    root = tempfile.mkdtemp(prefix="relaunch-reconnect-")
    acpmux_home = os.path.join(root, "acpmux")
    env = {"ACPMUX_HOME": acpmux_home}
    config = json.loads(args.config)
    rounds, scratch, load_info = [], None, {}
    total = len(modes) * args.rounds
    stream_s = 600 + total * 120  # the reply streams through every round
    try:
        pid, sock, scratch = bm.launch(args.app, config, env)
        app = bm.App(args.app, sock)
        chats = bm.FakeChats(app, args.app, AGENT)
        shown, streaming = None, None
        for i in range(args.chats):
            session = load.new_session(app.cli_path, chats.env, f"relaunch chat {i}")
            workspace = load.open_workspace(app, session) if session else None
            if workspace and streaming is None and load.stream([app.cli_path, "acp"], chats.env, session, stream_s, args.rate):
                shown, streaming = workspace, session
        if not shown:
            raise SystemExit("bench-relaunch: no streaming chat opened")
        app.action("goToWorkspace", workspace=shown)
        first = wait_live(sock, args.live_timeout)
        load_info = {"chats": args.chats, "streaming_session": streaming, "first_launch_live": "liveEvent_epoch_ms" in first}
        print(f"PERF-RELAUNCH-LOAD {json.dumps(load_info)}", flush=True)
        for mode in modes:
            for index in range(args.rounds):
                time.sleep(args.settle)  # test script: the chat streams a while before the quit
                quit_at = time.time() * 1000
                quit_app(sock, args.app)
                if mode == "cold":
                    bm.end_processes(daemon_pids(args.app))
                elif mode == "update":
                    replace_bundle(args.app)
                running = sorted(daemon_pids(args.app))
                started = time.time() * 1000
                pid, sock, scratch = bm.launch(args.app, config, env, scratch=scratch)
                page = wait_live(sock, args.live_timeout)
                timings = bp.rpc(sock, "debug.timings") or {}
                daemon, log_lines = daemon_log(acpmux_home, quit_at)
                daemon = {name: at for name, at in daemon.items() if at >= started}
                phases = round_phases(timings, page, daemon)
                zero = timings.get("process_start_epoch_ms")
                entry = {"mode": mode, "round": index + 1, "daemon_before": running,
                         "launch_to_process_ms": None if zero is None else round(zero - started, 1),
                         "phases": phases, "page": page, "daemon_log": daemon, "daemon_log_lines": log_lines,
                         "daemon_after": sorted(daemon_pids(args.app)),
                         "app_marks": timings.get("launch_ms_since_process_start")}
                rounds.append(entry)
                print(f"PERF-RELAUNCH mode={mode} round={index + 1} live_ms={phases.get('first live event')} "
                      f"{json.dumps(phases)}", flush=True)
    finally:
        bm.end_bundle(args.app)
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)
    sha = subprocess.run(["git", "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True).stdout.strip()
    model = subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip()
    harness = f"bench_relaunch_reconnect.py @{sha or '?'} {model}, {args.chats} chats, {args.rounds} rounds"
    table = median_table(rounds, modes)
    print("PERF-RELAUNCH-TABLE-BEGIN")
    print(f"harness: {harness}")
    print(table, end="")
    print("PERF-RELAUNCH-TABLE-END", flush=True)
    if args.md:
        with open(args.md, "w") as handle:
            handle.write(f"harness: {harness}\n\n{table}")
    if args.out:
        with open(args.out, "w") as handle:
            json.dump({"app": args.app, "harness": harness, "load": load_info, "rounds": rounds,
                       "markdown": table}, handle, indent=1)


if __name__ == "__main__":
    main()
