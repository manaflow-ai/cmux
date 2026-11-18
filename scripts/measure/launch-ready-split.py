#!/usr/bin/env python3
"""A launch-ready.sh launch split in two: macOS's checks before `main`, and the app's own time from `main` to Home.

Leo, CMUX-629: "for the startup times we shouldnt even count the mac verifying bit per se or at least split it off
from the other parts of startup times".

  verify        process start (sysctl p_starttime) to the app's `main_start` mark: exec, the code signature and
                Gatekeeper / XProtect checks of the executable, dyld. The split nightly-fresh-launch.py calls pre_main
                and launch-premain.sh times on its own (cmux#44013). Most of a new copy's first exec and of a relaunch
                after a full run (the executable's rescan, cmux#44204) is here.
  main_to_home  `main_start` to `home.first_page` (Home's first page in), per launch: the headline. It is the old
                process-start-to-Home number less verify, from the same marks.

LaunchServices' own part before the process starts (request_to_start) stays its own field, outside both.
launch-ready.swift writes verify and main_to_home into each LR-RUN row; a row from before it (an older runs.jsonl or
step log) gets them from its marks here, the same way.
"""
from __future__ import annotations

import statistics

MAIN_MARK = "main_start"
HOME_MARK = "home.first_page"
# The headline launch-ready.sh prints per side (LR-HEADLINE, and LR-MEDIAN's "headline"): verify is never in it.
HEADLINE = "main_to_home"


def split(row: dict) -> dict:
    """One launch's {"verify": ms, "main_to_home": ms}, either None when its marks lack main_start or Home."""
    marks = row.get("marks") or {}
    main, home = marks.get(MAIN_MARK), marks.get(HOME_MARK)
    verify = row["verify"] if row.get("verify") is not None else main
    if row.get("main_to_home") is not None:
        to_home = row["main_to_home"]
    else:
        to_home = None if main is None or home is None else round(home - main, 1)
    return {"verify": verify, "main_to_home": to_home}


def medians(rows: list[dict]) -> dict:
    """The median of each launch's verify and main_to_home (each launch split first, then the median taken), and n."""
    parts = [split(r) for r in rows]
    out: dict = {"headline": HEADLINE}
    for key in ("main_to_home", "verify"):
        vals = [p[key] for p in parts if p[key] is not None]
        out[key] = round(statistics.median(vals), 1) if vals else None
    out["split_n"] = sum(p["main_to_home"] is not None for p in parts)
    return out


def headline_line(side: str, med: dict) -> str:
    """LR-HEADLINE SIDE main_to_home=MS verify=MS n=N: the headline, with verify beside it and not in it."""
    def fmt(value):
        return "none" if value is None else f"{value}"
    return f"LR-HEADLINE {side} main_to_home={fmt(med.get('main_to_home'))} verify={fmt(med.get('verify'))} n={med.get('split_n', 0)}"
