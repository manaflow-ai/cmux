#!/usr/bin/env python3
"""rivals page: the daily head-to-head of cmux NEXT against the desktop agent apps (wow-20 idea 4).

Leo, 2026-11-08 (ask-ecadef4111): "three more “wow” ideas / you might as well just go for broke. say 20. we can just
keep finding more and more work to do". Idea 4, "Head-to-head bench vs desktop apps": a page that updates daily.

.github/workflows/rivals-nightly.yml runs scripts/measure/rivals.sh (RFD 0131's apps and ChatGPT) on one fleet Mac
once a day and hands its results.json here with the previous history (index.json from the bucket, or none):

  rivals_page.py page --today results.json [--history index.json] --out DIR [--sha SHA] [--days 90]

writes DIR/index.json (one entry per day: date, sha, host, apps, the median of every row per app; the newest
--days days, one entry per date: a rerun replaces the day) and DIR/index.md (today's three headline scenarios with
cmux's ratio to each rival, every other row, and the last 14 days of the headline rows). Both go to the
cmux-ci-cache-next bucket at rivals/v1/ (public at https://ci-cache-next.cmux.com/rivals/v1/index.md), plus the
day's full results.json at rivals/v1/days/<date>.json.

The three headline scenarios are the ones the harness measures today without a signed-in profile:
  fresh-window      first launch of a new install to its first window (ms)
  warm-window       warm relaunch to window (ms)
  soak-memory-peak  peak footprint over the idle soak, every process the app owns (MB)
Prompt to first token, a 5,000-message scroll, 20 open chats and a pasted 2 MB log need cmux-cua to drive each app
signed in: the follow-up issue linked from the PR tracks them.
Tests: python3 -I scripts/perf-bench/tests/test_rivals_page.py
"""
from __future__ import annotations

import argparse
import json
import os
import sys

HEADLINE = [("fresh-window", "Cold start to first window", "ms"),
            ("warm-window", "Warm relaunch to window", "ms"),
            ("soak-memory-peak", "Idle memory ceiling", "MB")]
ORDER = ["cmux", "claude", "chatgpt", "codex", "t3code", "zed", "rex", "slack", "chrome", "edge", "helium", "safari"]
TREND_DAYS = 14


def medians(result: dict) -> dict:
    """{row: {app: median}} from a rivals.py results.json."""
    out: dict = {}
    for row, apps in (result.get("rows") or {}).items():
        for app, stats in (apps or {}).items():
            if isinstance(stats, dict) and isinstance(stats.get("median"), (int, float)):
                out.setdefault(row, {})[app] = stats["median"]
    return out


def entry_of(result: dict, sha: str | None) -> dict:
    machine = result.get("machine") or {}
    return {"date": result.get("date"), "sha": sha or result.get("cmux_ref"), "host": machine.get("host"),
            "chip": machine.get("chip"), "macos": machine.get("macos"),
            "apps": {k: (v or {}).get("version") for k, v in (result.get("apps") or {}).items()},
            "rows": medians(result), "errors": len(result.get("errors") or [])}


def merge(history: list, entry: dict, days: int) -> list:
    """The history with today's entry: one entry per date (a rerun replaces its day), newest last, at most `days`."""
    kept = [e for e in history if isinstance(e, dict) and e.get("date") and e.get("date") != entry["date"]]
    kept.append(entry)
    kept.sort(key=lambda e: e["date"])
    return kept[-days:]


def app_order(apps) -> list:
    apps = list(apps)
    return [a for a in ORDER if a in apps] + sorted(a for a in apps if a not in ORDER)


def fmt(value, unit: str) -> str:
    if not isinstance(value, (int, float)):
        return "—"
    if unit in ("ms", "MB"):
        return f"{value:,.0f} {unit}"
    return f"{value:.2f} {unit}".rstrip()


def ratio(cmux, other) -> str:
    """How many times cmux's value the rival's is (lower is better for every headline row)."""
    if not isinstance(cmux, (int, float)) or not isinstance(other, (int, float)) or cmux <= 0:
        return ""
    return f" ({other / cmux:.1f}×)"


def render(index: list, units: dict | None = None) -> str:
    units = units or {}
    today = index[-1]
    rows = today["rows"]
    apps = app_order({a for r in rows.values() for a in r} | set(today.get("apps") or {}))
    lines = [f"# cmux NEXT head-to-head, {today['date']}", "",
             f"One fleet Mac ({today.get('chip') or '?'}, macOS {today.get('macos') or '?'}, host "
             f"{today.get('host') or '?'}), cmux at {str(today.get('sha') or '?')[:12]}, signed out, measured by "
             "scripts/perf-bench/rivals.py. Lower is better; a rival's value shows how many times cmux's it is.", ""]
    versions = ", ".join(f"{a} {today['apps'].get(a) or '?'}" for a in apps if a in (today.get("apps") or {}))
    if versions:
        lines += [f"Versions: {versions}.", ""]
    lines += ["| Scenario | " + " | ".join(apps) + " |", "|---|" + "---|" * len(apps)]
    for row, label, unit in HEADLINE:
        values = rows.get(row) or {}
        cells = [fmt(values.get(a), unit) + ("" if a == "cmux" else ratio(values.get("cmux"), values.get(a)))
                 for a in apps]
        lines.append(f"| {label} | " + " | ".join(cells) + " |")
    rest = sorted(r for r in rows if r not in {h[0] for h in HEADLINE})
    if rest:
        lines += ["", "## Every other row", "", "| Row | " + " | ".join(apps) + " |", "|---|" + "---|" * len(apps)]
        for row in rest:
            unit = units.get(row, "")
            lines.append(f"| {row} | " + " | ".join(fmt(rows[row].get(a), unit) for a in apps) + " |")
    recent = index[-TREND_DAYS:]
    if len(recent) > 1:
        lines += ["", f"## Last {len(recent)} days (cmux / best rival)", "",
                  "| Date | sha | " + " | ".join(h[1] for h in HEADLINE) + " |", "|---|---|" + "---|" * len(HEADLINE)]
        for e in reversed(recent):
            cells = []
            for row, _label, unit in HEADLINE:
                values = e["rows"].get(row) or {}
                rivals = [v for a, v in values.items() if a != "cmux" and isinstance(v, (int, float))]
                cells.append(f"{fmt(values.get('cmux'), unit)} / {fmt(min(rivals), unit) if rivals else '—'}")
            lines.append(f"| {e['date']} | {str(e.get('sha') or '')[:8]} | " + " | ".join(cells) + " |")
    if today.get("errors"):
        lines += ["", f"{today['errors']} sample(s) failed today: see the day's results.json `errors`."]
    lines += ["", "History: index.json beside this page; each day's full run: days/<date>.json.", ""]
    return "\n".join(lines)


def page(today_path: str, history_path: str | None, out: str, sha: str | None, days: int) -> int:
    with open(today_path) as handle:
        result = json.load(handle)
    if not medians(result):
        print(f"rivals page: {today_path} has no measured row; nothing to publish", file=sys.stderr)
        return 1
    history = []
    if history_path and os.path.exists(history_path):
        try:
            with open(history_path) as handle:
                loaded = json.load(handle)
            history = loaded if isinstance(loaded, list) else []
        except (OSError, ValueError) as error:
            print(f"rivals page: ignoring unreadable history {history_path}: {error}", file=sys.stderr)
    index = merge(history, entry_of(result, sha), days)
    units = {}
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import rivals  # noqa: PLC0415  (imports procs lazily)
        units = dict(rivals.UNITS)
    except Exception:  # the page still renders; the extra rows just carry no unit
        pass
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "index.json"), "w") as handle:
        json.dump(index, handle, indent=1)
    md = render(index, units)
    with open(os.path.join(out, "index.md"), "w") as handle:
        handle.write(md)
    print(md)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("page", help="merge today's results.json into the history and render the page")
    p.add_argument("--today", required=True)
    p.add_argument("--history")
    p.add_argument("--out", required=True)
    p.add_argument("--sha")
    p.add_argument("--days", type=int, default=90)
    args = parser.parse_args()
    return page(args.today, args.history, args.out, args.sha, args.days)


if __name__ == "__main__":
    sys.exit(main())
