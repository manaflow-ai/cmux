#!/usr/bin/env python3
"""SHORTCUT FRAMES: the deliverable table (handoff/resize-videos/SHORTCUT-FRAMES.md) from the list and judge reports.

  table.py --list shortcut-list.json --cases shortcut-cases.json [--judged DIR] --out SHORTCUT-FRAMES.md

--judged DIR holds one judge.py report per case (any *.json with "presses" and "summary"), plus optional
`<report>.video` text files with the case's gallery link. A row per shortcut and case condition that has run;
every other shortcut is listed with "not run" so the table always shows the whole list.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

HEADER = """# SHORTCUT FRAMES

Order (Lawrence 2026-11-02, via the Performance Lead): every default shortcut opens its first visible frame (the new
tab/pane/page, focused, with its chrome) in the NEXT display refresh after the HID key-down (<= 8.3 ms at 120 Hz),
with no blank, flash, half-drawn chrome, layout jump or later re-layout; content that loads later fills in place.

Method: real HID key presses (CuaDriver, through the HARNESS kit, handoff/resize-videos/KIT.md) on a granted M6 mini,
the app's own-window ScreenCaptureKit movie at display rate, the key-down time from the HID event
(NSEvent.timestamp via debug.action_budget, CLOCK_UPTIME_RAW = the frames' clock). "Refreshes" = display refreshes
from the key-down to the first changed frame (1 = the next refresh). Judge: scripts/cmux-next/shortcut-frames/judge.py.
List: scripts/cmux-next/shortcut-frames/enumerate.py ({rows} cases, {actions} actions with a default key, {menu} AppKit menu keys).

Defect words: late (refreshes > 1), half-drawn (first frame's layout lines differ from the settled frame's), re-layout
(a line moves after the first frame), jump-back, flash, blank, blink-back. A defect counts until 5 of 5 clean runs.

"""


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--list", required=True)
    p.add_argument("--cases", required=True)
    p.add_argument("--judged")
    p.add_argument("--out", required=True)
    p.add_argument("--notes", help="a Markdown file put after the measured cases (findings, recorder caveats)")
    a = p.parse_args()
    listing = json.load(open(a.list, encoding="utf-8"))
    summary = listing["summary"]
    judged: dict[str, dict] = {}
    videos: dict[str, str] = {}
    if a.judged:
        for path in sorted(glob.glob(os.path.join(a.judged, "*.json"))):
            report = json.load(open(path, encoding="utf-8"))
            for case, row in (report.get("summary") or {}).items():
                judged[case] = row
                link = path + ".video"
                if os.path.exists(link):
                    videos[case] = open(link, encoding="utf-8").read().strip()
    lines = [HEADER.format(rows=summary["rows"], actions=summary["actions_with_keys"], menu=summary["menu_keys"])]
    lines += ["## Measured cases", "",
              "| Shortcut | Action | Case (arm/load/theme/animations/build) | Presses | Refreshes p50 / p95 / max | Defects | Video |",
              "|---|---|---|---|---|---|---|"]
    ran = set()
    for case, row in sorted(judged.items()):
        action_stroke, _, rest = case.partition("/")
        action, _, stroke = action_stroke.partition("[")
        ran.add(action_stroke)
        defects = ", ".join(f"{k} x{v}" for k, v in sorted(row["defects"].items())) or "none"
        lines.append(f"| `{stroke.rstrip(']')}` | {action} | {rest} | {row['presses']} | {row['refreshes_p50']} / "
                     f"{row['refreshes_p95']} / {row['refreshes_max']} | {defects} | {videos.get(case, '')} |")
    if not judged:
        lines.append("| | | no case judged yet | | | | |")
    if a.notes and os.path.exists(a.notes):
        lines += ["", open(a.notes, encoding="utf-8").read().rstrip()]
    lines += ["", "## Not run yet", "", "| P | Stroke | Action | Effect | Context |", "|---|---|---|---|---|"]
    for r in listing["rows"]:
        if f"{r['action']}[{r['stroke']}]" not in ran:
            lines.append(f"| {r['priority']} | `{r['stroke']}` | {r['action']} | {r['effect']} | {r['context']} |")
    open(a.out, "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print(json.dumps({"judged_cases": len(judged), "out": a.out}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
