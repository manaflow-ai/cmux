"""RFD 0062's five growth bounds as advisory perf rows (cmuxterm-hq docs/rfd/0062-ram-cpu-ceiling-and-growth.md).

Leo, 2026-11-22: "gauging our ram/cpu ceiling and growth too probably". The RFD's growth bound table:

  idle, short        least squares slope over the rivals soak (300 s) after its first 90 s: 0.5 MB/min any group,
                     1 MB/min the whole instance
  idle, long         slope of the footprint troughs over an 8 h idle soak (--soak 28800): 0.02 MB/min whole instance
  per item, opened   the marginal footprint of item N for N = 1, 10, 100, 1,000: N=100's within 1.1x of N=10's
  per item, closed   open and close one chat 100 times, settle 90 s: back within 5 MB, 0.05 MB per cycle
  under use          a chat streaming 60 min, idle 90 s, forced GC: renderer within 10 % of the same transcript
                     loaded fresh (1.1x)

Each measured bound prints one PERF_ROW line (webviews/bench/perfRow.ts's format: name, p50, p95, unit, target) and a
row of the report's "Growth bounds" table. They are advisory: nothing here fails a step, a check or a merge (RFD 0062:
"A soak that blocks merges" is not under consideration; perf runs never block). A bound this harness does not measure
says so and names the harness that would.
"""
from __future__ import annotations

import json

PERF_ROW_MARK = "PERF_ROW "

# id, label, limit, unit, what measures it
BOUNDS = [
    ("idle_short", "idle, short: whole instance", 1.0, "MB/min", "rivals.py soak, slope after --settle-cut"),
    ("idle_short_group", "idle, short: worst group", 0.5, "MB/min", "rivals.py soak, per-group slope"),
    ("idle_long", "idle, long: trough slope", 0.02, "MB/min", "rivals.py --soak 28800, trough growth"),
    ("item_opened", "per item, opened: N=100 over N=10 marginal", 1.1, "x",
     "not measured here: bench_memory.py / perf-10x-idle.sh at 10 and 100 items"),
    ("item_closed", "per item, closed: per open/close cycle", 0.05, "MB",
     "not measured here: no harness opens and closes one chat 100 times yet"),
    ("under_use", "under use: renderer after 60 min stream over fresh", 1.1, "x",
     "not measured here: no harness streams a chat 60 min yet"),
]


def measured(rows: dict, app: str = "cmux") -> dict[str, float]:
    """The bounds rivals.py measured for `app`, from aggregate()'s rows (pure)."""
    def median(row):
        return ((rows.get(row) or {}).get(app) or {}).get("median")
    got = {}
    if median("soak-memory-growth") is not None:
        got["idle_short"] = median("soak-memory-growth")
    groups = [v for row, per in rows.items() if row.startswith("soak-group-") and row.endswith("-growth")
              for v in [((per.get(app) or {}).get("median"))] if v is not None]
    if groups:
        got["idle_short_group"] = max(groups)
    if median("soak-memory-trough-growth") is not None:
        got["idle_long"] = median("soak-memory-trough-growth")
    return got


def perf_rows(rows: dict, app: str = "cmux", soak: float | None = None) -> list[dict]:
    """PERF_ROW objects for the measured bounds. idle_long counts only from an hour-long soak up (pure)."""
    out = []
    for bound, label, limit, unit, _how in BOUNDS:
        value = measured(rows, app).get(bound)
        if value is None or (bound == "idle_long" and (soak or 0) < 3600):
            continue
        out.append({"name": f"growth.{bound}", "p50": round(value, 4), "p95": round(value, 4), "unit": unit,
                    "target": limit, "floor": max(limit / 10, 0.01), "clock": "cpu"})
    return out


def lines(rows: dict, app: str = "cmux", soak: float | None = None) -> list[str]:
    """The report's "Growth bounds" section and the PERF_ROW lines after it."""
    have = {r["name"].split(".", 1)[1]: r["p95"] for r in perf_rows(rows, app, soak)}
    out = ["## Growth bounds (RFD 0062, advisory: nothing fails on them)", "",
           "| Bound | Limit | cmux NEXT | Within | Measured by |", "|---|---:|---:|---|---|"]
    for bound, label, limit, unit, how in BOUNDS:
        value = have.get(bound)
        if bound == "idle_long" and value is None and measured(rows, app).get(bound) is not None:
            how = f"needs --soak 3600 or longer (this soak: {soak or 0:g} s)"
        cell = "–" if value is None else f"{value:+.3f}" if unit == "MB/min" else f"{value:g}"
        within = "" if value is None else ("yes" if value <= limit else "OVER")
        out.append(f"| {label} | {limit:g} {unit} | {cell} | {within} | {how} |")
    out.append("")
    out += [PERF_ROW_MARK + json.dumps(row, sort_keys=True) for row in perf_rows(rows, app, soak)]
    out.append("")
    return out
