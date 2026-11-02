#!/usr/bin/env python3
"""SHORTCUT FRAMES: the key-down times of a journey's measured presses, for judge.py --hid.

  hid_log.py RESULT.json [--out hid.ndjson]

For each `real_key` step (the kit's HID key through CuaDriver) the next `debug.action_budget` read holds the run of
the pressed action: the first run with the case's action id, entrypoint `key` and a sequence above the step's
`action_sequence_before`. Its key-down time is start_uptime_ns - input_age_ms * 1e6 (CLOCK_UPTIME_RAW: the clock of the
recorder's frames.json `t`, STATUS 4300). A press with no such run (the key ran nothing, or ran another action) is
written with "missing" and no time; the judge skips it and the case reports it.
"""
from __future__ import annotations

import argparse
import json
import sys


def presses(result: dict) -> list[dict]:
    action = (result.get("case") or {}).get("action")
    steps = result.get("steps") or []
    rows = []
    for i, step in enumerate(steps):
        if step.get("do") != "real_key":
            continue
        res = step.get("result") or {}
        before = int(res.get("action_sequence_before") or 0)
        # journeys.py titles each press "the measured press STROKE (LABEL)"; the record keeps the title.
        title = step.get("title", "")
        label = res.get("mark") or (title[title.rfind("(") + 1:-1] if title.endswith(")") else title)
        run = None
        for later in steps[i + 1:]:
            if later.get("do") == "real_key":
                break
            reply = ((later.get("result") or {}).get("reply") or {}) if later.get("do") == "rpc" else {}
            for r in sorted(reply.get("recent") or [], key=lambda r: int(r.get("sequence") or 0)):
                if int(r.get("sequence") or 0) > before and (action is None or r.get("id") == action) \
                        and r.get("entrypoint") == "key" and float(r.get("input_age_ms", -1)) >= 0:
                    run = r
                    break
            if run:
                break
        row = {"phase": "down", "label": label, "keys": res.get("keys")}
        if run:
            row["t_ns"] = int(float(run["start_uptime_ns"]) - float(run["input_age_ms"]) * 1e6)
            row["run"] = {k: run.get(k) for k in ("sequence", "id", "commit_ms", "input_age_ms", "outcome")}
        else:
            row["missing"] = f"no key run of {action} after the press"
        rows.append(row)
    return rows


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("result")
    p.add_argument("--out")
    a = p.parse_args()
    result = json.load(open(a.result, encoding="utf-8"))
    rows = presses(result)
    text = "".join(json.dumps(r) + "\n" for r in rows)
    if a.out:
        open(a.out, "w", encoding="utf-8").write(text)
    else:
        sys.stdout.write(text)
    missing = sum(1 for r in rows if "t_ns" not in r)
    print(f"{len(rows)} presses, {missing} without a key run", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
