#!/usr/bin/env python3
"""Tally of the routing journeys' attempts (ext_routing.py routing_marker): right, wrong, lost, split per case and build.

    python3 scripts/journeys/routing/tally.py RUN_DIR [RUN_DIR ...] [--markdown]

RUN_DIR: a run.py --out folder (results.jsonl and <journey>/result.json). Each routing_marker check's LAST read is the
attempt's verdict (the expect polls until it holds or times out). An attempt the journey never reached (an earlier
step failed or the lease ended) is not counted. Prints JSON rows, or a Markdown table with --markdown.
"""
import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path


def attempts(run_dir):
    run_dir = Path(run_dir)
    rows = {}
    try:
        for line in (run_dir / "results.jsonl").read_text().splitlines():
            r = json.loads(line)
            rows[r["id"]] = r
    except (OSError, ValueError):
        return
    for ident, row in rows.items():
        if not ident.startswith("routing-"):
            continue
        try:
            record = json.loads((run_dir / ident / "result.json").read_text())
        except (OSError, ValueError):
            continue
        env = any(isinstance(st.get("result"), dict) and st["result"].get("smoke_env")
                  for st in record.get("steps") or [] if st.get("do") == "env_windows")
        if env:
            yield {"case": ident, "build": row.get("build_job"), "commit": row.get("commit"), "host": row.get("host"),
                   "attempt": None, "verdict": "smoke_env", "run": str(run_dir)}
            continue
        for ev in record.get("evidence") or []:
            if not isinstance(ev, dict) or ev.get("check") != "routing_marker" or not isinstance(ev.get("detail"), dict):
                continue
            d = ev["detail"]
            yield {"case": ident, "build": row.get("build_job"), "commit": row.get("commit"), "host": row.get("host"),
                   "attempt": d.get("attempt"), "verdict": d.get("verdict"), "line": d.get("line"),
                   "landed": d.get("landed"), "pass": ev.get("pass"), "elapsed_ms": ev.get("elapsed_ms"),
                   "run": str(run_dir), "step": ev.get("step")}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--markdown", action="store_true")
    opts = ap.parse_args()
    rows = [a for r in opts.runs for a in attempts(r)]
    if not opts.markdown:
        for a in rows:
            print(json.dumps(a))
        return 0
    table = defaultdict(lambda: defaultdict(int))
    for a in rows:
        table[(a["case"], a["build"])][a["verdict"]] += 1
    print("| Case | Build | Attempts | Right | Wrong | Lost | Split | Unjudged | SMOKE ENV runs |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for (case, build), c in sorted(table.items()):
        print(f"| {case} | {str(build)[:12]} | {sum(v for k, v in c.items() if k != 'smoke_env')} | {c['right']} | {c['wrong']} | {c['lost']} | {c['split']} | {c['unjudged']} | {c['smoke_env']} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
