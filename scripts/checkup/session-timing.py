#!/usr/bin/env python3
"""Checkup: a chat's recorded turn timings, the same numbers the ACP inspector's Timing tab draws.

Leo, 2026-11-20: "we ought to have good tools/scripts checkups for these" (ask-f70cfb2563, on cmux#47799: the
inspector's Timing tab and Settings > Advanced > Check Configuration). This reads `acpmux history SESSION --json`
(the daemon's `_acpmux/history`, cmux-tui/crates/acpmux/src/hub/history_timing.rs), the latest 100 turns as the
Timing tab does, and prints the breakdown: per turn the send delay (`toAgentMs`: prompt accepted to prompt written
to the agent) and first output (`firstModelMs`: prompt written to the model's first output), and per session their
p50, p95 and max, unknown stamps, idle time between turns, and the chat's start (`agentStart`).

It fails on what would make the Timing tab draw a wrong picture:
  - a history for a different session than asked (the tab must never show another chat's turns);
  - a turn ending before it started, or `wallMs` other than `endedAt - startedAt`;
  - send delay plus first output longer than the turn's wall time;
  - a negative or non-number duration, or a repeated `seq`;
  - a send delay over `--send-budget-ms` (default 2000; 0 turns it off), or a first output over
    `--first-output-budget-ms` (default off).
A missing stamp is "unknown", never zero, and only counted. A history it cannot read is its own verdict (exit 2),
never a clean one.

Usage:
  scripts/checkup/session-timing.py SESSION [SESSION...]   chats by acpmux name or id
  scripts/checkup/session-timing.py --all                  every chat `acpmux ls --json` lists on this machine
  scripts/checkup/session-timing.py --from-file F.json     a saved `acpmux history --json` (or a list of them)
Options: -n LIMIT (100), --json, --send-budget-ms MS, --first-output-budget-ms MS, --timeout S (20).
Exit: 0 clean, 1 findings, 2 a history could not be read (or usage).
Test: python3 -I scripts/checkup/tests/session-timing.test.py
"""
from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from typing import Any

LIMIT = 100  # InspectorTiming reads the latest 100 turns (direct.ts inspectorHistory).


def is_ms(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def percentile(values: list[float], q: float) -> float | None:
    """Nearest-rank percentile; None for no values."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, math.ceil(q * len(ordered)))
    return ordered[rank - 1]


def spread(values: list[float]) -> dict[str, Any]:
    return {
        "n": len(values),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "max": max(values) if values else None,
    }


def check_history(
    history: Any,
    asked: str | None,
    send_budget_ms: float = 2000,
    first_output_budget_ms: float = 0,
) -> dict[str, Any]:
    """The checkup of one `acpmux history --json` answer: its summary and its findings."""
    findings: list[dict[str, Any]] = []

    def find(kind: str, message: str, seq: Any = None) -> None:
        entry: dict[str, Any] = {"kind": kind, "message": message}
        if seq is not None:
            entry["seq"] = seq
        findings.append(entry)

    if not isinstance(history, dict) or not isinstance(history.get("turns"), list):
        return {"session": asked, "readable": False, "error": "history has no turns list", "findings": []}
    session = history.get("sessionId")
    # `acpmux history NAME` resolves a name to an id, so only an id the caller gave can be compared.
    if asked and session and looks_like_id(asked) and session != asked:
        find("wrong_session", f"asked for {asked}, history is for {session}")

    sends: list[float] = []
    firsts: list[float] = []
    walls: list[float] = []
    unknown = {"toAgentMs": 0, "firstModelMs": 0, "wallMs": 0}
    seen: set[Any] = set()
    idle_ms = 0.0
    previous_end: float | None = None
    open_turns = 0
    turns = history["turns"]
    for turn in turns:
        if not isinstance(turn, dict):
            find("bad_turn", f"turn is {type(turn).__name__}, not an object")
            continue
        seq = turn.get("seq")
        if seq in seen:
            find("repeated_seq", f"seq {seq} appears twice", seq)
        seen.add(seq)
        started, ended = turn.get("startedAt"), turn.get("endedAt")
        if not is_ms(started):
            find("bad_stamp", "startedAt is missing or not a number", seq)
            continue
        if ended is None:
            open_turns += 1
        elif not is_ms(ended):
            find("bad_stamp", "endedAt is not a number", seq)
            ended = None
        elif ended < started:
            find("ended_before_start", f"endedAt {ended} is before startedAt {started}", seq)
        if previous_end is not None and started > previous_end:
            idle_ms += started - previous_end
        if is_ms(ended):
            previous_end = max(previous_end or ended, ended)

        values: dict[str, float | None] = {}
        for key in ("toAgentMs", "firstModelMs", "wallMs"):
            value = turn.get(key)
            if value is None:
                values[key] = None
                if key != "wallMs" or ended is not None:
                    unknown[key] += 1
            elif not is_ms(value) or value < 0:
                find("bad_duration", f"{key} is {value!r}", seq)
                values[key] = None
            else:
                values[key] = float(value)
        send, first, wall = values["toAgentMs"], values["firstModelMs"], values["wallMs"]
        if wall is not None and is_ms(ended) and ended >= started and wall != ended - started:
            find("wall_mismatch", f"wallMs {wall:g} is not endedAt - startedAt = {ended - started:g}", seq)
        if wall is not None and (send or 0) + (first or 0) > wall:
            find(
                "phases_exceed_wall",
                f"send delay {send or 0:g} ms + first output {first or 0:g} ms is longer than the turn ({wall:g} ms)",
                seq,
            )
        if send is not None:
            sends.append(send)
            if send_budget_ms and send > send_budget_ms:
                find("slow_send", f"send delay {send:g} ms is over the {send_budget_ms:g} ms budget", seq)
        if first is not None:
            firsts.append(first)
            if first_output_budget_ms and first > first_output_budget_ms:
                find("slow_first_output", f"first output {first:g} ms is over the {first_output_budget_ms:g} ms budget", seq)
        if wall is not None:
            walls.append(wall)

    start = next((t.get("agentStart") for t in turns if isinstance(t, dict) and t.get("agentStart")), None)
    return {
        "session": session or asked,
        "readable": True,
        "turns": len(turns),
        "open": open_turns,
        "sendDelayMs": spread(sends),
        "firstOutputMs": spread(firsts),
        "wallMs": spread(walls),
        "unknown": unknown,
        "idleMs": idle_ms,
        "agentStart": start,
        "findings": findings,
    }


def looks_like_id(text: str) -> bool:
    parts = text.split("-")
    return len(parts) == 5 and all(p and all(c in "0123456789abcdef" for c in p.lower()) for p in parts)


def read_history(session: str, limit: int, timeout: float) -> tuple[Any, str | None]:
    try:
        done = subprocess.run(
            ["acpmux", "history", session, "--json", "-n", str(limit)],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        return None, "acpmux is not on PATH"
    except subprocess.TimeoutExpired:
        return None, f"acpmux history gave no answer in {timeout:g} s"
    if done.returncode != 0:
        return None, error_message(done.stderr) or error_message(done.stdout) or f"acpmux history exited {done.returncode}"
    try:
        return json.loads(done.stdout), None
    except json.JSONDecodeError as error:
        return None, f"acpmux history printed no JSON: {error}"


def error_message(text: str) -> str:
    """acpmux's `{"error": {"message": ...}}` as its message; other text as it is."""
    try:
        answer = json.loads(text)
    except json.JSONDecodeError:
        return text.strip()
    error = answer.get("error") if isinstance(answer, dict) else None
    if isinstance(error, dict) and error.get("message"):
        return str(error["message"])
    return text.strip()


def local_sessions(timeout: float) -> tuple[list[str], str | None]:
    try:
        done = subprocess.run(["acpmux", "ls", "--json"], capture_output=True, text=True, timeout=timeout)
        listed = json.loads(done.stdout)
    except (FileNotFoundError, subprocess.TimeoutExpired, json.JSONDecodeError) as error:
        return [], f"acpmux ls --json: {error}"
    items = listed if isinstance(listed, list) else listed.get("sessions", []) if isinstance(listed, dict) else []
    names = []
    for item in items:
        if not isinstance(item, dict):
            continue
        name = item.get("name") or item.get("sessionId")
        # A peer's or the send relay's chat (`peer`, `via`, "host/name") keeps its history on that host, which
        # this daemon cannot read, so --all stays on this machine.
        if not name or "/" in name or item.get("peer") or item.get("via"):
            continue
        names.append(name)
    return names, None


def fmt_ms(value: Any) -> str:
    if value is None:
        return "unknown"
    if value >= 60_000:
        return f"{value / 60_000:.1f}m"
    if value >= 1000:
        return f"{value / 1000:.1f}s"
    return f"{value:g}ms"


def render(report: dict[str, Any]) -> str:
    if not report["readable"]:
        return f"{report['session']}: UNREADABLE: {report['error']}"
    title = f"{report['name']} ({report['session']})" if report.get("name") else report["session"]
    lines = [f"{title}: {report['turns']} turns ({report['open']} open), idle between turns {fmt_ms(report['idleMs'])}"]
    for label, key in (("send delay", "sendDelayMs"), ("first output", "firstOutputMs"), ("turn wall", "wallMs")):
        s = report[key]
        lines.append(f"  {label:<13} p50 {fmt_ms(s['p50']):>8}  p95 {fmt_ms(s['p95']):>8}  max {fmt_ms(s['max']):>8}  (n={s['n']})")
    unknown = report["unknown"]
    if any(unknown.values()):
        lines.append(
            f"  unknown stamps: send {unknown['toAgentMs']}, first output {unknown['firstModelMs']}, wall {unknown['wallMs']}"
        )
    start = report.get("agentStart")
    if isinstance(start, dict):
        steps = ", ".join(f"{s.get('method')} {fmt_ms(s.get('ms'))}" for s in start.get("steps", []) if isinstance(s, dict))
        lines.append(f"  chat start: first prompt {fmt_ms(start.get('firstPromptMs'))}, ready {fmt_ms(start.get('readyMs'))}" + (f" ({steps})" if steps else ""))
    for f in report["findings"]:
        where = f" seq {f['seq']}" if "seq" in f else ""
        lines.append(f"  FINDING {f['kind']}{where}: {f['message']}")
    if not report["findings"]:
        lines.append("  clean")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("sessions", nargs="*")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--from-file")
    parser.add_argument("-n", "--limit", type=int, default=LIMIT)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--send-budget-ms", type=float, default=2000)
    parser.add_argument("--first-output-budget-ms", type=float, default=0)
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args(argv)
    if not (args.sessions or args.all or args.from_file):
        parser.print_usage(sys.stderr)
        print("session-timing: name a session, --all or --from-file", file=sys.stderr)
        return 2

    budgets = {"send_budget_ms": args.send_budget_ms, "first_output_budget_ms": args.first_output_budget_ms}
    reports: list[dict[str, Any]] = []
    if args.from_file:
        try:
            with open(args.from_file, encoding="utf-8") as handle:
                loaded = json.load(handle)
        except (OSError, json.JSONDecodeError) as error:
            reports.append({"session": args.from_file, "readable": False, "error": str(error), "findings": []})
        else:
            for history in loaded if isinstance(loaded, list) else [loaded]:
                reports.append(check_history(history, None, **budgets))
    sessions = list(args.sessions)
    if args.all:
        listed, error = local_sessions(args.timeout)
        if error:
            reports.append({"session": "--all", "readable": False, "error": error, "findings": []})
        sessions += [s for s in listed if s not in sessions]
    checked: set[str] = set()
    for session in sessions:
        history, error = read_history(session, args.limit, args.timeout)
        if error:
            reports.append({"session": session, "readable": False, "error": error, "findings": []})
            continue
        # A name and an id of one chat (or --all's name of a chat also named) read the same history once.
        resolved = history.get("sessionId") if isinstance(history, dict) else None
        if resolved and resolved in checked:
            continue
        if resolved:
            checked.add(resolved)
        report = check_history(history, session, **budgets)
        if resolved and resolved != session:
            report["name"] = session
        reports.append(report)

    if args.json:
        print(json.dumps({"schema": "cmux-checkup-session-timing/v1", "reports": reports}, indent=2))
    else:
        print("\n".join(render(r) for r in reports) if reports else "no sessions")
    if any(not r["readable"] for r in reports):
        return 2
    return 1 if any(r["findings"] for r in reports) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
