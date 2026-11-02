#!/usr/bin/env python3
"""SHORTCUT FRAMES: the key-down times of a journey's measured presses, for judge.py --hid.

  hid_log.py RESULT.json [--out hid.ndjson]

Each `hid_key` step (the HARNESS kit's real key through CuaDriver) is titled "the measured press STROKE (LABEL)",
where LABEL is "<action>[<stroke>]/<condition>/<n>". The next `debug.action_budget` read after it holds the run of
the pressed action: the first unused run with that action id, entrypoint `key`, and a key-down time between the
step's `sent` and `returned` host times (10 ms slack). Key-down = start_uptime_ns - input_age_ms * 1e6: the HID
event's own NSEvent.timestamp on CLOCK_UPTIME_RAW, the clock of the recorder's frames.json `t` (STATUS 4300).
A press with no such run (the key ran nothing, or ran another action) is written with "missing" and no time.
Each row also keeps `sent` (the kit's time just before CuaDriver posted the key): key-down - sent is the input
path's own delay, not the app's.
"""
from __future__ import annotations

import argparse
import json
import sys

SLACK_NS = 10_000_000


def presses(result: dict) -> list[dict]:
    steps = result.get("steps") or []
    used: set[int] = set()
    rows = []
    for i, step in enumerate(steps):
        if step.get("do") not in ("hid_key", "real_key"):
            continue
        title = step.get("title", "")
        if "the measured press" not in title:
            continue
        label = title[title.rfind("(") + 1:-1] if title.endswith(")") else title
        action = label.split("[", 1)[0]
        res = step.get("result") or {}
        sent = res.get("sent")
        returned = res.get("returned")
        lo = int(float(sent) * 1e9) - SLACK_NS if sent is not None else None
        hi = int(float(returned) * 1e9) + SLACK_NS if returned is not None else None
        run, t_ns = None, None
        for later in steps[i + 1:]:
            if later.get("do") in ("hid_key", "real_key"):
                break
            reply = ((later.get("result") or {}).get("reply") or {}) if later.get("do") == "rpc" else {}
            for r in sorted(reply.get("recent") or [], key=lambda r: int(r.get("sequence") or 0)):
                seq = int(r.get("sequence") or 0)
                if seq in used or r.get("id") != action or r.get("entrypoint") != "key":
                    continue
                if float(r.get("input_age_ms", -1)) < 0:
                    continue
                down = int(float(r["start_uptime_ns"]) - float(r["input_age_ms"]) * 1e6)
                if (lo is None or down >= lo) and (hi is None or down <= hi):
                    run, t_ns = r, down
                    used.add(seq)
                    break
            if run:
                break
        row = {"phase": "down", "label": label, "action": action, "sent": sent, "returned": returned}
        if run:
            row["t_ns"] = t_ns
            row["run"] = {k: run.get(k) for k in ("sequence", "id", "commit_ms", "input_age_ms", "outcome")}
            if sent is not None:
                row["input_path_ms"] = round((t_ns - float(sent) * 1e9) / 1e6, 3)
        else:
            row["missing"] = f"no key run of {action} with its key-down between the press's sent and returned times"
        rows.append(row)
    return rows


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("result")
    p.add_argument("--out")
    a = p.parse_args()
    rows = presses(json.load(open(a.result, encoding="utf-8")))
    text = "".join(json.dumps(r) + "\n" for r in rows)
    if a.out:
        open(a.out, "w", encoding="utf-8").write(text)
    else:
        sys.stdout.write(text)
    print(f"{len(rows)} presses, {sum(1 for r in rows if 't_ns' not in r)} without a key run", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
