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
  quit-launch-bound.py's session restore (workspaces with terminals, quit and reopened) is not in this part: on the
  measure Macs its seeding launch never draws a terminal (step ab0db3de, 2026-11-19), so it would only leave the part
  incomplete. Its rows come back when that launch draws.

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


RELAUNCH_EXPECTED = [f"launch.relaunch.{m}.chat_live_ms" for m in RECONNECT_MODES]
# The app's answer only: with no working terminal the bench still times it, and its echo rows stay empty
# (missed_rounds counts those rounds against its budget of 0).
WAKE_EXPECTED = ["launch.wake_proxy.app_answer_ms"]


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
        rows = reconnect_rows(read_json(raw))
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
