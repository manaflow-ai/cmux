#!/usr/bin/env python3
"""The launch bench's positive control (startup-tti): did a known delay show up in the bench's numbers?

Leo: "we need to have proper measurments and goals for startup times and just to be doing them. figure out any sort
of way."

    launch_tti_control.py --base BASE/tti.json --delayed DELAYED/tti.json --expected MS [--tolerance 0.3]

scripts/measure/launch-tti.sh control=MS runs launch_tti_check.py's plan twice on the same build: once as is (BASE)
and once with --launch-delay-ms MS (DELAYED: the app waits MS before it makes any window, LaunchTestDelay). Every
startup number the bench reads must then come out about MS later. A bench that cannot see a delay it put in itself
cannot see a regression either, so the bench fails.

The metrics, each the median over the rounds that read it (ms from process start):
  first_frame.KIND             first_frame_ms of KIND's rounds (cold_install, cold_after_update, warm, warm60)
  first_chat_paint             the first_chat_paint stage of the chat rounds
  launch_to_interaction.FRONT  input_ms of FRONT's rounds (chat, terminal)

Each metric both runs read prints `CONTROL metric=NAME base_ms=B delayed_ms=D delta_ms=X expected=MS pass|fail`; it
passes when |X - MS| <= tolerance * MS. A metric only one run read fails (the delay lost it); one neither read is
skipped. Exit 0 when every compared metric passed and at least one was compared, else 1.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys

KINDS = ("cold_install", "cold_after_update", "warm", "warm60")
FRONTS = ("chat", "terminal")
TOLERANCE = 0.3


def _median(values) -> float | None:
    got = [float(v) for v in values if isinstance(v, (int, float)) and not isinstance(v, bool)]
    return round(statistics.median(got), 1) if got else None


def metrics(result: dict) -> dict:
    """Metric name to its median over `result`'s rounds (a tti.json), for the metrics some round read."""
    rounds = [r for r in result.get("rounds") or [] if isinstance(r, dict)]
    found = {}
    for kind in KINDS:
        found[f"first_frame.{kind}"] = _median(r.get("first_frame_ms") for r in rounds if r.get("kind") == kind)
    found["first_chat_paint"] = _median((r.get("stages") or {}).get("first_chat_paint")
                                        for r in rounds if r.get("front") == "chat")
    for front in FRONTS:
        found[f"launch_to_interaction.{front}"] = _median(r.get("input_ms") for r in rounds if r.get("front") == front)
    return {name: value for name, value in found.items() if value is not None}


def judge(delta_ms: float, expected_ms: float, tolerance: float = TOLERANCE) -> bool:
    """True when the measured shift is within tolerance of the injected delay."""
    return abs(delta_ms - expected_ms) <= tolerance * expected_ms


def compare(base: dict, delayed: dict, expected_ms: float, tolerance: float = TOLERANCE) -> list[dict]:
    """One row per metric either run read: base_ms, delayed_ms, delta_ms (None when a side is missing), verdict."""
    rows = []
    for name in sorted(set(base) | set(delayed)):
        b, d = base.get(name), delayed.get(name)
        if b is None or d is None:
            rows.append({"metric": name, "base_ms": b, "delayed_ms": d, "delta_ms": None, "expected": expected_ms,
                         "verdict": "fail", "why": "read by only one run"})
            continue
        delta = round(d - b, 1)
        rows.append({"metric": name, "base_ms": b, "delayed_ms": d, "delta_ms": delta, "expected": expected_ms,
                     "verdict": "pass" if judge(delta, expected_ms, tolerance) else "fail"})
    return rows


def passed(rows: list[dict]) -> bool:
    return bool(rows) and all(r["verdict"] == "pass" for r in rows)


def line(row: dict) -> str:
    expected = int(row["expected"]) if float(row["expected"]).is_integer() else row["expected"]
    text = (f"CONTROL metric={row['metric']} base_ms={row['base_ms']} delayed_ms={row['delayed_ms']} "
            f"delta_ms={row['delta_ms']} expected={expected} {row['verdict']}")
    return text + (f" ({row['why']})" if row.get("why") else "")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="the baseline run's tti.json")
    parser.add_argument("--delayed", required=True, help="the delayed run's tti.json")
    parser.add_argument("--expected", type=float, required=True, help="the injected delay, ms")
    parser.add_argument("--tolerance", type=float, default=TOLERANCE, help="the allowed error, a fraction of --expected")
    args = parser.parse_args(argv)
    if args.expected <= 0:
        parser.error("--expected must be above 0")
    try:
        with open(args.base) as handle:
            base = json.load(handle)
        with open(args.delayed) as handle:
            delayed = json.load(handle)
    except (OSError, ValueError) as error:
        print(f"CONTROL fail: a run's tti.json is unreadable: {error}", flush=True)
        return 1
    rows = compare(metrics(base), metrics(delayed), args.expected, args.tolerance)
    for row in rows:
        print(line(row), flush=True)
    ok = passed(rows)
    print("CONTROL " + json.dumps({"verdict": "pass" if ok else "fail", "expected": args.expected,
                                   "tolerance": args.tolerance, "compared": len(rows),
                                   "failed": [r["metric"] for r in rows if r["verdict"] != "pass"]}), flush=True)
    if not rows:
        print("CONTROL fail: neither run read any metric", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
