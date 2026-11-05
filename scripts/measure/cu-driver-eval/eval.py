#!/usr/bin/env python3
"""The cu-driver eval's results file and its summary.md, with each number's change against an
earlier run's results.json.

  eval.py results OUT.json RUN_JSON SUITES_DIR [BLOCKED]
  eval.py summary RESULTS.json OUT.md [--previous EARLIER.json]

results.json: {"schema": SCHEMA, "run": {...}, "suites": {"input_ab": <input_ab.py's input-ab.json>
or {"ok": false, "errors": [...]}}}. Later suites (the Cua Driver Bench v2 run, the macOSWorld
subset) add their own key under "suites"; a key is never renamed or given another meaning
without a new SCHEMA, so any two runs line up key by key.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCHEMA = "cmux.cu-driver-eval/1"
GESTURES = ["click", "key", "scroll"]


def load(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def results(out: Path, run: str, suites_dir: Path, blocked: str) -> None:
    run_info = json.loads(run)
    if blocked:
        run_info["blocked"] = blocked
    suites = {}
    ab = load(suites_dir / "input-ab" / "input-ab.json")
    suites["input_ab"] = ab if ab else {"ok": False, "errors": [blocked or "the input A/B wrote no input-ab.json"]}
    out.write_text(json.dumps({"schema": SCHEMA, "run": run_info, "suites": suites}, indent=2, sort_keys=True) + "\n")


def frac(row: dict | None, num: str) -> str:
    if not row:
        return "–"
    if row.get("unsupported"):
        return "n/a"
    if not row.get("n"):
        return "no run" if not row.get("setup_failed") else f"setup failed ×{row['setup_failed']}"
    return f"{row.get(num) or 0}/{row['n']}"


def disturbances(row: dict | None) -> str:
    if not row or not row.get("n"):
        return ""
    parts = []
    for field, label in (("focus_steals", "focus"), ("key_losses", "key"), ("raises", "raise"),
                         ("pointer_moved", "pointer"), ("stray", "stray"), ("duplicates", "dup")):
        value = row.get(field)
        if value:
            parts.append(f"{label} {value}")
    return ", ".join(parts)


def changes(cur: dict, prev: dict | None) -> list[str]:
    if not prev:
        return []
    out = []
    old_rows = prev.get("rows") or {}
    for key, row in sorted((cur.get("rows") or {}).items()):
        old = old_rows.get(key)
        if not old:
            out.append(f"- `{key}`: new row")
            continue
        for field in ("clean_rate", "delivered_rate"):
            a, b = old.get(field), row.get(field)
            if a != b and not (a is None and b is None):
                out.append(f"- `{key}` {field}: {a} → {b}")
    for key in sorted(set(old_rows) - set(cur.get("rows") or {})):
        out.append(f"- `{key}`: gone")
    return out


def summary(results_path: Path, out: Path, previous: Path | None) -> None:
    data = load(results_path) or {}
    prev = load(previous) if previous else None
    run = data.get("run") or {}
    lines = ["# Computer Use driver eval", ""]
    lines.append(f"{run.get('host', '?')}, macOS {run.get('macos', '?')}, {run.get('display', '?')}, rev `{str(run.get('rev', '?'))[:12]}`, {run.get('at', '?')}")
    if run.get("blocked"):
        lines += ["", f"**Blocked:** {run['blocked']}"]
    ab = (data.get("suites") or {}).get("input_ab") or {}
    lines += ["", "## Input A/B", ""]
    if not ab.get("rows"):
        lines.append("No trials ran. " + "; ".join(ab.get("errors") or []))
    else:
        lines.append("Each cell is background clean / background delivered / foreground delivered, out of the trials that ran. "
                     "Clean means delivered with no focus steal, no key loss on the user's window, no window raised over it, "
                     "no pointer movement and no input landing in it.")
        grants = ab.get("grants") or {}
        lines.append(f"Grants: {', '.join(k for k, v in sorted(grants.items()) if v) or 'none'}.")
        rows = ab["rows"]
        for target in ab.get("targets") or []:
            lines += ["", f"### {target}", "", "| arm | " + " | ".join(GESTURES) + " | background disturbances | call ms p50 |",
                      "|---|" + "---|" * len(GESTURES) + "---|---|"]
            for arm in ab.get("arms") or []:
                cells, dist, ms = [], [], []
                for gesture in GESTURES:
                    bg = rows.get(f"{arm}|{target}|{gesture}|background")
                    fg = rows.get(f"{arm}|{target}|{gesture}|foreground")
                    if bg and bg.get("unsupported"):
                        cells.append("n/a")
                    else:
                        cells.append(f"{frac(bg, 'clean')} / {frac(bg, 'delivered')} / {frac(fg, 'delivered')}")
                    if disturbances(bg):
                        dist.append(f"{gesture}: {disturbances(bg)}")
                    if bg and bg.get("call_ms_p50") is not None:
                        ms.append(f"{bg['call_ms_p50']:.0f}")
                lines.append(f"| {arm} | " + " | ".join(cells) + f" | {'; '.join(dist)} | {'/'.join(ms)} |")
        wins = ab.get("wins") or {}
        if wins:
            lines += ["", "### What wins (most clean background trials, then foreground delivery, then speed)", "",
                      "| target | gesture | arm | background clean | foreground delivered |", "|---|---|---|---|---|"]
            for target, by_gesture in wins.items():
                for gesture, win in by_gesture.items():
                    lines.append(f"| {target} | {gesture} | {win['arm']} | {win['background_clean_rate']} | {win['foreground_delivered_rate']} |")
        errors = ab.get("errors") or []
        row_errors = sorted({f"{key}: {e}" for key, row in rows.items() for e in row.get("errors") or []})
        if errors or row_errors:
            lines += ["", "### Errors", ""] + [f"- {e}" for e in errors + row_errors[:30]]
        delta = changes(ab, ((prev or {}).get("suites") or {}).get("input_ab"))
        if prev:
            lines += ["", "### Since the previous run", ""] + (delta or ["No rate changed."])
    out.write_text("\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("results")
    r.add_argument("out")
    r.add_argument("run")
    r.add_argument("suites_dir")
    r.add_argument("blocked", nargs="?", default="")
    s = sub.add_parser("summary")
    s.add_argument("results")
    s.add_argument("out")
    s.add_argument("--previous")
    args = parser.parse_args()
    if args.command == "results":
        results(Path(args.out), args.run, Path(args.suites_dir), args.blocked)
    else:
        summary(Path(args.results), Path(args.out), Path(args.previous) if args.previous else None)
    return 0


if __name__ == "__main__":
    sys.exit(main())
