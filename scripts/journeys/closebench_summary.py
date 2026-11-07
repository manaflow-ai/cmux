#!/usr/bin/env python3
"""CLOSE PERF bench: summary of cp-close-bench journey results (task close-perf, cmux-ad m56).

  closebench_summary.py RESULT_JSON_OR_RUN_DIR [...] [--json]

Per session (light, stress) and case (A: a tab of a pane that keeps a tab, B: the last tab of a split pane, C: the last
tab of the last pane), p50/p95/p99/max over the counted closes (warm-ups not counted) of:
  key_to_commit_ms  Cmd-W key -> the close's committed frame (debug.action_budget: input age + commit_ms)
  missed            display refreshes missed in the 1 s after the key (debug.frames: the close's motion)
  main_max_ms       the busiest main-thread frame in that second
A close with no action-budget run is counted as missed (n vs missed), never dropped silently."""
import json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmdn_latency_summary import stats  # noqa: E402

KEYS = ("key_to_commit_ms", "missed", "main_max_ms")


def load(path):
    if os.path.isdir(path):
        path = os.path.join(path, "cp-close-bench", "result.json") if os.path.isdir(os.path.join(path, "cp-close-bench")) \
            else os.path.join(path, "result.json")
    return path, json.load(open(path))


def summarize(result):
    out = {"status": result.get("status"), "reason": (result.get("reason") or "")[:200], "sessions": {}}
    for step in result.get("steps") or []:
        res = step.get("result") or {}
        if step.get("do") != "close_bench" or not res.get("label") or "warmup" in res["label"]:
            continue
        rows = res.get("rows") or []
        cell = out["sessions"].setdefault(res["label"], {}).setdefault(res.get("case"), {})
        for key in KEYS:
            cell[key] = stats([r.get(key) for r in rows])
        cell["actions"] = sorted({str(r.get("action")) for r in rows if r.get("action")})
    return out


def main(argv):
    rows = []
    for arg in [a for a in argv if a != "--json"]:
        try:
            path, result = load(arg)
        except (OSError, ValueError) as error:
            rows.append({"path": arg, "error": str(error)})
            continue
        rows.append(dict(path=path, **summarize(result)))
    if "--json" in argv:
        print(json.dumps(rows, indent=1))
        return
    for row in rows:
        print(f"== {row['path']}  status={row.get('status')} {row.get('reason') or row.get('error', '')}")
        for label, cases in (row.get("sessions") or {}).items():
            for case, cell in sorted(cases.items()):
                for key in KEYS:
                    v = cell.get(key) or {}
                    print(f"  {label:7s} close {case} {key:16s} n={v.get('n')} missed={v.get('missed')} p50={v.get('p50')} "
                          f"p95={v.get('p95')} p99={v.get('p99')} max={v.get('max')}")


if __name__ == "__main__":
    main(sys.argv[1:])
