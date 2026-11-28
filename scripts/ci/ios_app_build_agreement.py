#!/usr/bin/env python3
"""Count RFD 0051 route 9's shadow agreement: the iOS app build on the build fleet's Linux pool vs this Mac's.

ios-fast (scripts/ci/ios_fast_verdict.sh, CMUX_IOS_APP_BUILD_LINUX=shadow) prints one line per run:
  IOS_APP_BUILD_AGREEMENT {"sha":..,"linux":"pass|fail|none","linux_exit":..,"linux_seconds":N,"mac":..,"agree":"yes|no|none"}

A run counts when both sides gave an answer (pass or fail). The cutover rule (flip the var to `on`) holds after
N=5 consecutive counted runs that agree, newest last, with no disagreement in the window read.

Input, oldest first: log files (`-` is stdin), or `--run ID` (repeatable), read with `gh run view ID --log`.
Exit: 0 the rule holds, 1 not yet, 2 a disagreement was seen (read its sha before any cutover).
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys

LINE = re.compile(r"IOS_APP_BUILD_AGREEMENT (\{.*?\})\s*$")
ANSWERS = ("pass", "fail")


def records(text: str, source: str = "") -> list[dict]:
    out = []
    for line in text.splitlines():
        m = LINE.search(line)
        if not m:
            continue
        try:
            rec = json.loads(m.group(1))
        except json.JSONDecodeError:
            continue
        if source:
            rec["source"] = source
        out.append(rec)
    return out


def judge(recs: list[dict], need: int = 5) -> dict:
    counted = [r for r in recs if r.get("linux") in ANSWERS and r.get("mac") in ANSWERS]
    agree = [r for r in counted if r["linux"] == r["mac"]]
    disagree = [r for r in counted if r["linux"] != r["mac"]]
    streak = 0
    for r in reversed(counted):
        if r["linux"] != r["mac"]:
            break
        streak += 1
    secs = sorted(int(r.get("linux_seconds", 0)) for r in counted)
    if disagree:
        verdict, code = "disagreement", 2
    elif streak >= need:
        verdict, code = "holds", 0
    else:
        verdict, code = "not yet", 1
    return {
        "lines": len(recs),
        "counted": len(counted),
        "agree": len(agree),
        "disagree": [{"sha": r.get("sha", ""), "linux": r["linux"], "mac": r["mac"],
                      "source": r.get("source", "")} for r in disagree],
        "no_answer": len(recs) - len(counted),
        "streak": streak,
        "need": need,
        "linux_seconds_median": secs[len(secs) // 2] if secs else None,
        "verdict": verdict,
        "exit": code,
    }


def run_log(run_id: str, repo: str, run=subprocess.run) -> str:
    done = run(["gh", "run", "view", run_id, "--repo", repo, "--log"], capture_output=True, text=True, timeout=300)
    if done.returncode != 0:
        raise RuntimeError(f"gh run view {run_id}: exit {done.returncode}: {done.stderr.strip()[:200]}")
    return done.stdout


def main(argv: list[str] | None = None, run=subprocess.run) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("logs", nargs="*", help="log files, oldest first ('-' is stdin)")
    p.add_argument("--run", action="append", default=[], help="Actions run id, oldest first (repeatable)")
    p.add_argument("--repo", default="manaflow-ai/cmux")
    p.add_argument("--need", type=int, default=5, help="consecutive agreeing counted runs (default 5)")
    p.add_argument("--json", action="store_true")
    a = p.parse_args(argv)
    recs: list[dict] = []
    for path in a.logs:
        text = sys.stdin.read() if path == "-" else open(path, encoding="utf-8", errors="replace").read()
        recs += records(text, path)
    for rid in a.run:
        recs += records(run_log(rid, a.repo, run), f"run {rid}")
    v = judge(recs, a.need)
    if a.json:
        print(json.dumps(v, indent=1))
    else:
        print(f"route 9 cutover: {v['verdict']}: {v['streak']}/{v['need']} agreeing in a row; "
              f"{v['counted']} counted ({v['agree']} agree, {len(v['disagree'])} disagree), "
              f"{v['no_answer']} without an answer; Linux median {v['linux_seconds_median']} s")
        for d in v["disagree"]:
            print(f"  disagree at {d['sha'][:12]}: Linux {d['linux']}, Mac {d['mac']} ({d['source']})")
    return v["exit"]


if __name__ == "__main__":
    sys.exit(main())
