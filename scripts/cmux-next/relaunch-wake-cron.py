#!/usr/bin/env python3
"""The perf cron's relaunch and wake parts (split-spring-terminal.py --suite=relaunch, --suite=wake): the app after a
quit and reopen, and after a wake, as perf-cron rows.

Leo, 2026-11-19: "a lot of this is just applying things properly and having those measurements in so that we're aware
of things. I wonder if there's any other like incomplete or uninvestigated or underinvestigated areas as well." The
cron had no row for either.

--suite=relaunch runs two existing benches on the cron's app and writes report.json `rows` (perf-cron.py's budgets
kind):
- bench_relaunch_reconnect.py, modes warm (Quit and Keep Sessions, then reopen, the daemon kept) and update (the bundle
  swapped in place first, as an update does, so the daemon is handed off): local chats on the test agent, the shown one
  streaming. Per mode, ms since the reopened app's process started:
    launch.relaunch.<mode>.first_window_frame_ms  budget 1000 (LAUNCH_BUDGETS first_window_frame_committed, the launch rows);
    launch.relaunch.<mode>.chat_painted_ms        the shown chat drawn, budget 600;
    launch.relaunch.<mode>.chat_live_ms           the shown chat's first live event, budget 600 (cmuxterm-hq goal
                                           restart-to-chat: "the open chat is drawn live within 600 ms");
    launch.relaunch.<mode>.chat_missing_runs      relaunches whose chat never went live, budget 0.
- quit-launch-bound.py, quit `interactive` (Cmd-Q answered Keep Sessions): a session of workspaces with terminals, a
  split, Chromium and WebKit tabs, quit and reopened --rounds times:
    launch.relaunch.session.quit_ms               quit request to process exit, budget 6000 (quit-launch-bound's own bound:
                                           the app's 4 s quit deadline after an interactive quit's 1 s fact read);
    launch.relaunch.session.first_window_frame_ms budget 1000, as above;
    launch.relaunch.session.terminal_live_ms      the first live terminal frame, budget 300 (cmuxterm-hq
                                           docs/design/launch-shell-first.md: "under 300 ms from process start to a
                                           usable window on a relaunch");
    launch.relaunch.session.longest_stall_ms      the main thread's longest stall in the first 12 s, budget 2000
                                           (quit-launch-bound's own bound);
    launch.relaunch.session.lost_items            workspaces and tabs missing after the restore, budget 0.

--suite=wake runs wake-proxy-bench.py (every process of the app stopped --sleep seconds, then resumed: why a proxy and
what it leaves out is in that file):
    launch.wake_proxy.app_answer_ms        resume to the main thread answering, budget 1000;
    launch.wake_proxy.terminal_echo_ms     resume to a typed command's output drawn, budget 1000 (plans/cmux-next/
                                           transport.md: "Wake from sleep: <= 1 s to first byte");
    launch.wake_proxy.awake_echo_ms        the same echo with nothing frozen (reporting only: the floor under it);
    launch.wake_proxy.missed_rounds        rounds whose echo never came, budget 0.
A row missing from a bench that ran marks the report incomplete (perf-cron.py: no done part).
Both parts' rows sit under launch.: perf-cron.py judges that family by each row's own budget (target_of), so these
rows need no change to the cron's judging.
"""
from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MS_FLOOR = 20.0
WINDOW_BUDGET_MS = 1000
CHAT_BUDGET_MS = 600
TERMINAL_BUDGET_MS = 300
QUIT_BUDGET_MS = 6000
STALL_BUDGET_MS = 2000
WAKE_BUDGET_MS = 1000
RECONNECT_MODES = ("warm", "update")


def pct(values: list[float], share: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, int(round(share * (len(ordered) - 1)))))]


def ms_row(name: str, values: list, budget: float) -> dict | None:
    values = [float(v) for v in values if isinstance(v, (int, float))]
    if not values:
        return None
    return {"name": name, "p50": round(statistics.median(values), 1), "p95": round(pct(values, 0.95), 1), "unit": "ms",
            "budget": budget, "floor": MS_FLOOR, "n": len(values)}


def count_row(name: str, value: int, unit: str) -> dict:
    return {"name": name, "p50": value, "p95": value, "unit": unit, "budget": 0, "floor": 0.5}


def reconnect_rows(report: dict) -> list[dict]:
    """Rows from bench_relaunch_reconnect.py's --out report (pure)."""
    rows = []
    rounds = [r for r in report.get("rounds") or [] if isinstance(r, dict)]
    for mode in RECONNECT_MODES:
        mine = [r.get("phases") or {} for r in rounds if r.get("mode") == mode]
        if not mine:
            continue
        for name, column, budget in (("first_window_frame_ms", "first window frame", WINDOW_BUDGET_MS),
                                     ("chat_painted_ms", "pane painted", CHAT_BUDGET_MS),
                                     ("chat_live_ms", "first live event", CHAT_BUDGET_MS)):
            row = ms_row(f"launch.relaunch.{mode}.{name}", [p.get(column) for p in mine], budget)
            if row:
                rows.append(row)
        missing = sum(1 for p in mine if not isinstance(p.get("first live event"), (int, float)))
        rows.append(count_row(f"launch.relaunch.{mode}.chat_missing_runs", missing, "runs"))
    return rows


def lost_items(before: dict, after: dict) -> int:
    """Workspaces and tabs (by kind) of `before` that `after` lacks (pure)."""
    lost = max(0, int(before.get("workspaces") or 0) - int(after.get("workspaces") or 0))
    have = after.get("tabs") or {}
    for kind, count in (before.get("tabs") or {}).items():
        lost += max(0, int(count or 0) - int(have.get(kind) or 0))
    return lost


def session_rows(report: dict) -> list[dict]:
    """Rows from quit-launch-bound.py's quit-launch-bound.json (pure). Marks are ms since process start."""
    rows = []
    quits = [q for q in report.get("quits") or [] if isinstance(q, dict)]
    launches = [l for l in report.get("launches") or [] if isinstance(l, dict)]
    row = ms_row("launch.relaunch.session.quit_ms",
                 [q["seconds"] * 1000 for q in quits if q.get("exited") and isinstance(q.get("seconds"), (int, float))],
                 QUIT_BUDGET_MS)
    if row:
        rows.append(row)
    marks = [l.get("marks") or {} for l in launches]
    for name, mark, budget in (("first_window_frame_ms", "first_window_frame_committed", WINDOW_BUDGET_MS),
                               ("terminal_live_ms", "first_terminal_frame", TERMINAL_BUDGET_MS)):
        row = ms_row(f"launch.relaunch.session.{name}", [m.get(mark) for m in marks], budget)
        if row:
            rows.append(row)
    row = ms_row("launch.relaunch.session.longest_stall_ms", [l.get("longest_stall_ms") for l in launches], STALL_BUDGET_MS)
    if row:
        rows.append(row)
    census = report.get("census")
    if isinstance(census, dict) and launches:
        lost = max(lost_items(census, l.get("census") or {}) for l in launches)
        rows.append(count_row("launch.relaunch.session.lost_items", lost, "items"))
    return rows


def wake_rows(report: dict) -> list[dict]:
    """Rows from wake-proxy-bench.py's report (pure)."""
    rounds = [r for r in report.get("rounds") or [] if isinstance(r, dict)]
    if not rounds:
        return []
    rows = []
    for name, budget in (("app_answer_ms", WAKE_BUDGET_MS), ("terminal_echo_ms", WAKE_BUDGET_MS),
                         ("awake_echo_ms", WAKE_BUDGET_MS)):
        row = ms_row(f"launch.wake_proxy.{name}", [r.get(name) for r in rounds], budget)
        if row:
            row["sleep_s"] = report.get("sleep_s")
            rows.append(row)
    missed = sum(1 for r in rounds if not isinstance(r.get("terminal_echo_ms"), (int, float)))
    rows.append(count_row("launch.wake_proxy.missed_rounds", missed, "rounds"))
    return rows


RELAUNCH_EXPECTED = [f"launch.relaunch.{m}.chat_live_ms" for m in RECONNECT_MODES] + [
    "launch.relaunch.session.quit_ms", "launch.relaunch.session.terminal_live_ms", "launch.relaunch.session.lost_items"]
WAKE_EXPECTED = ["launch.wake_proxy.app_answer_ms", "launch.wake_proxy.terminal_echo_ms"]


def missing_rows(rows: list[dict], expected: list[str]) -> list[str]:
    have = {r["name"] for r in rows}
    return [f"no {name}" for name in expected if name not in have]


def read_json(path: str) -> dict:
    try:
        with open(path) as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def run(cmd: list[str], timeout: float) -> int:
    print("relaunch-wake:", " ".join(cmd[1:3]), flush=True)
    try:
        return subprocess.run(cmd, timeout=timeout, env={**os.environ, "CMUX_BENCH_LAUNCH": "direct"}).returncode
    except subprocess.TimeoutExpired:
        return 124


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--suite", required=True, choices=("relaunch", "wake"))
    parser.add_argument("--app", required=True)
    parser.add_argument("--json", required=True, help="the part's report.json")
    parser.add_argument("--out", default=None, help="split-spring's artifact folder")
    parser.add_argument("--rounds", default="3")
    parser.add_argument("--sleep", default="30", help="wake: seconds the app stays frozen")
    args, _rest = parser.parse_known_args(argv)  # split-spring's own args (--tag) are not this suite's
    out_dir = args.out or os.path.dirname(os.path.abspath(args.json))
    os.makedirs(out_dir, exist_ok=True)
    py = sys.executable
    status = {}
    if args.suite == "relaunch":
        raw = os.path.join(out_dir, "relaunch-reconnect.json")
        status["reconnect"] = run([py, os.path.join(HERE, "bench_relaunch_reconnect.py"), "--app", args.app,
                                   "--modes", ",".join(RECONNECT_MODES), "--rounds", args.rounds, "--chats", "3",
                                   "--out", raw], 900)
        session_dir = os.path.join(out_dir, "relaunch-session")
        status["session"] = run([py, os.path.join(HERE, "quit-launch-bound.py"), "--app", args.app,
                                 "--out", session_dir, "--quit", "interactive", "--rounds", args.rounds,
                                 "--workspaces", "4", "--no-agent", "--no-sample", "--launch-advisory"], 600)
        rows = reconnect_rows(read_json(raw)) + session_rows(read_json(os.path.join(session_dir, "quit-launch-bound.json")))
        expected = RELAUNCH_EXPECTED
    else:
        raw = os.path.join(out_dir, "wake-proxy.json")
        status["wake"] = run([py, os.path.join(HERE, "wake-proxy-bench.py"), "--app", args.app, "--rounds", args.rounds,
                              "--sleep", args.sleep, "--out", raw], 600)
        rows = wake_rows(read_json(raw))
        expected = WAKE_EXPECTED
    out = {"rows": rows, "suite": args.suite, "bench_status": status}
    missing = missing_rows(rows, expected)
    if missing:
        out["incomplete"] = missing + [f"bench exits {status}"]
    with open(args.json, "w") as handle:
        json.dump(out, handle, indent=1)
    for r in rows:
        print(f"relaunch-wake: {r['name']} = p50 {r['p50']} p95 {r['p95']} {r['unit']} (budget {r['budget']})")
    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
