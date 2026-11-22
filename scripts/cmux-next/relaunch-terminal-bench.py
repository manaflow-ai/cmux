#!/usr/bin/env python3
"""Relaunch to the terminals live again: after Quit and Keep Sessions and a reopen, how long until the shown
workspace's terminal shows its scrollback again, and until a program still running in it draws new output (the perf
cron's relaunch part, relaunch-wake-cron.py).

Leo, 2026-11-19: "a lot of this is just applying things properly and having those measurements in so that we're aware
of things." The relaunch part had rows for the window and the shown chat, none for the terminals.

The load: one workspace made with the app's own CLI (`workspace create --focus`, as wake-proxy-bench makes its own) and
shown; its terminal runs `echo rt-mark-<sum>` and then a counter that prints `rt-tick-<n>` every TICK_S. Then
--rounds times: Quit and Keep Sessions (bench_relaunch_reconnect.quit_app: the daemon and the counter keep running),
reopen the app into the same HOME and state, and read the workspace's terminal view (`debug.surfaces` text) every
POLL_S. Each round, in ms since the reopened app's process started (debug.timings `process_start_epoch_ms`):

  terminal_frame_ms     the launch mark first_terminal_frame (the first terminal frame drawn);
  terminal_restored_ms  the view shows the counter's output again (the terminal's screen came back; the counter
                        kept running while the app was gone, so its screen is newer than the one at the quit);
  terminal_live_ms      the view shows a counter line newer than any it showed before the quit and at its first
                        read after the reopen: the view is attached to the running program again. The counter ticks
                        every TICK_S, so this reads up to TICK_S late.

A round whose view never shows a new counter line within --live-timeout is a missing run (relaunch-wake-cron counts
them). When the typed command never shows before the first quit, the rounds still run and the report says why in
`seed_error`, with the view text the app showed (a failing row is still a value).

  relaunch-terminal-bench.py --app BUNDLE [--rounds 3] [--out FILE.json]
macOS only, on a fleet Mac (CMUX_BENCH_LAUNCH=direct on a fleet step).
"""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402  (launch, App, end_bundle)
import bench_power as bp  # noqa: E402  (rpc, wipe_state)

TICK_S = 0.1
POLL_S = 0.05
SEED_TIMEOUT_S = 30.0
TICK = re.compile(r"rt-tick-(\d+)")


def find_key(value, key: str) -> str | None:
    """The first string under `key` anywhere in `value` (a CLI `--json` answer; pure)."""
    if isinstance(value, dict):
        if isinstance(value.get(key), str):
            return value[key]
        value = list(value.values())
    if isinstance(value, list):
        for item in value:
            found = find_key(item, key)
            if found:
                return found
    return None


def workspace_text(surfaces: dict, workspace: str | None) -> str | None:
    """The text of the terminal views drawing `workspace` (debug.surfaces), else of the focused terminal view; None when
    no terminal view shows (pure)."""
    panes = [p for w in (surfaces or {}).get("windows") or [] for p in w.get("panes") or [] if p.get("kind") == "terminal"]
    mine = [p for p in panes if workspace and p.get("workspace") == workspace] or [p for p in panes if p.get("focused")]
    if not mine:
        return None
    return "\n".join(str(p.get("text") or "") for p in mine)


def last_tick(text: str | None) -> int | None:
    """The newest counter line in a view's text (pure)."""
    ticks = [int(n) for n in TICK.findall(text or "")]
    return max(ticks) if ticks else None


def is_newer(tick: int | None, *earlier: int | None) -> bool:
    """`tick` is past every earlier counter line seen (pure); with none seen, no line is newer."""
    seen = [t for t in earlier if t is not None]
    return tick is not None and bool(seen) and tick > max(seen)


def round_result(reads: list[tuple[float, str | None]], zero: float | None, tick_before: int | None,
                 frame_ms: float | None) -> dict:
    """One relaunch from its view reads ((epoch ms, text) in order; pure): when the counter's output showed again and
    when a counter line newer than the one before the quit and than the first restored read showed."""
    restored = live = None
    first_tick = None
    for at, text in reads:
        tick = last_tick(text)
        if first_tick is None and tick is not None:
            first_tick, restored = tick, at
        if live is None and is_newer(tick, tick_before, first_tick):
            live = at
            break

    def since(at):
        return None if at is None or zero is None else round(at - zero, 1)

    return {"terminal_frame_ms": frame_ms, "terminal_restored_ms": since(restored), "terminal_live_ms": since(live),
            "tick_before": tick_before, "tick_first_read": first_tick, "reads": len(reads)}


class Session:
    """The app's control socket and its CLI, for one bench workspace."""

    def __init__(self, bundle: str, sock: str):
        self.bundle, self.sock = bundle, sock
        self.app = bm.App(bundle, sock)
        self.env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_SOCKET_PATH": sock, "CMUX_QUIET": "1",
                    "HOME": os.environ.get("HOME", "/tmp")}

    def cli(self, *args, timeout=30) -> subprocess.CompletedProcess:
        return subprocess.run([self.app.cli_path, "--app-socket", self.sock, *args], capture_output=True, text=True,
                              timeout=timeout, env=self.env, stdin=subprocess.DEVNULL)

    def surfaces(self) -> dict:
        return bp.rpc(self.sock, "debug.surfaces", {"text": True}, timeout=10) or {}

    def panes(self) -> list[dict]:
        return [{k: p.get(k) for k in ("kind", "workspace", "presence", "focused", "link")} | {"text": str(p.get("text") or "")[-300:]}
                for w in self.surfaces().get("windows") or [] for p in w.get("panes") or []]


def seed(session: Session, report: dict) -> tuple[str | None, str | None, str]:
    """The bench workspace and its counter; returns (workspace, terminal, mark)."""
    done = session.cli("--json", "workspace", "create", "--name", "relaunch-terminal", "--focus")
    try:
        made = json.loads(done.stdout)
    except ValueError:
        made = {}
    term, workspace = find_key(made, "terminal_id"), find_key(made, "workspace_id")
    if not term:
        raise SystemExit(f"relaunch-terminal: workspace create answered {(done.stdout + done.stderr).strip()[:300]}")
    session.app.call("action.run", {"action": "goToWorkspace", "target": f"workspace:{workspace}", "origin": "script",
                                    "focus": True}, timeout=30)
    a, b = random.randrange(1 << 20), random.randrange(1 << 20)
    mark = f"rt-mark-{a + b}"
    # `\r` is Return to the shell, as wake-proxy-bench and evicted-terminal-frame-live type it. Only the output lines
    # hold rt-mark-<sum> and rt-tick-<n>; the typed text holds neither.
    command = f"echo rt-mark-$(({a}+{b})); i=0; while :; do i=$((i+1)); echo rt-tick-$i; sleep {TICK_S}; done\r"
    deadline = time.monotonic() + SEED_TIMEOUT_S
    wrote = None
    while time.monotonic() < deadline:
        text = workspace_text(session.surfaces(), workspace)
        if text is not None and wrote is None:
            wrote = session.cli("terminal", term, "write", "--text", command)
            report["seed_write"] = {"exit": wrote.returncode, "err": (wrote.stderr or "")[-300:]}
        if text and mark in text.replace("\n", "") and last_tick(text) is not None:
            return workspace, term, mark
        time.sleep(POLL_S * 4)  # test script: the view draws by itself; this only reads it
    report["seed_error"] = (f"the workspace's terminal never showed {mark} and a counter line in {SEED_TIMEOUT_S:.0f} s"
                            + ("" if wrote else " (no terminal view of it ever showed, so nothing was typed)"))
    report["seed_panes"] = session.panes()
    print(f"relaunch-terminal: {report['seed_error']}; panes {json.dumps(report['seed_panes'])[:800]}", flush=True)
    return workspace, term, mark


def read_until_live(session: Session, workspace: str | None, tick_before: int | None, seconds: float) -> list:
    """The view reads after a reopen, until a counter line newer than the earlier ones shows or `seconds` pass."""
    reads, first_tick = [], None
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        text = workspace_text(session.surfaces(), workspace)
        reads.append((time.time() * 1000, text))
        tick = last_tick(text)
        first_tick = tick if first_tick is None else first_tick
        if is_newer(tick, tick_before, first_tick):
            break
        time.sleep(POLL_S)  # test script: the view draws by itself; this only reads it
    return reads


def main(argv: list[str] | None = None) -> int:
    from bench_relaunch_reconnect import quit_app  # noqa: E402,PLC0415  (Quit and Keep Sessions, SIGTERM after 20 s)

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--settle", type=float, default=3.0, help="seconds the counter runs before each quit")
    parser.add_argument("--live-timeout", type=float, default=30.0)
    parser.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    signal.signal(signal.SIGTERM, bm.interrupted)
    bp.wipe_state(args.app)
    report: dict = {"app": args.app, "tick_s": TICK_S, "poll_s": POLL_S, "rounds": []}
    scratch = None
    try:
        _pid, sock, scratch = bm.launch(args.app, {})
        session = Session(args.app, sock)
        workspace, term, mark = seed(session, report)
        report.update({"workspace": workspace, "terminal": term, "mark": mark})
        for index in range(args.rounds):
            time.sleep(args.settle)  # test script: the counter runs a while before the quit
            tick_before = last_tick(workspace_text(session.surfaces(), workspace))
            quit_app(sock, args.app)
            _pid, sock, scratch = bm.launch(args.app, {}, scratch=scratch)
            session = Session(args.app, sock)
            reads = read_until_live(session, workspace, tick_before, args.live_timeout)
            timings = bp.rpc(sock, "debug.timings") or {}
            marks = timings.get("launch_ms_since_process_start") or {}
            entry = round_result(reads, timings.get("process_start_epoch_ms"), tick_before, marks.get("first_terminal_frame"))
            entry["round"] = index + 1
            if entry["terminal_live_ms"] is None:
                entry["panes"] = session.panes()
            report["rounds"].append(entry)
            print(f"PERF-RELAUNCH-TERMINAL {json.dumps(entry)[:1500]}", flush=True)
    finally:
        bm.end_bundle(args.app)
        if scratch:
            shutil.rmtree(scratch, ignore_errors=True)
        with open(args.out, "w") as handle:
            json.dump(report, handle, indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
