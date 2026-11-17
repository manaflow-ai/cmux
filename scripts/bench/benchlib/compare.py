"""Compare two runs row by row: `cmux-bench compare A B`.

A selector names one run:
  <run id or a unique prefix>        20261116T041209Z-launch-3f2a9c1d, or 20261116T0412
  BENCH@latest, BENCH@latest~N       the newest run of BENCH, or the Nth before it
  BENCH@nightly, BENCH@nightly~N     the newest run on the newest NIGHTLY build, or N NIGHTLY builds back
  BENCH@sha:PREFIX                   the newest run of BENCH on a build at that commit
  BENCH@version:V                    the newest run of BENCH on build version V
With --bench NAME the BENCH@ part may be left out.

A delta is a regression when the metric got worse by more than its threshold (percent, the bench's
`thresholds` or DEFAULT_THRESHOLD) and by more than the unit's floor (so 3 ms on a 20 ms metric is noise).
"""
from __future__ import annotations

import re
from typing import Any

from .schema import metric_key

DEFAULT_THRESHOLD = 10.0
FLOORS = {"ms": 5.0, "s": 0.005, "us": 50.0, "MB": 15.0, "KB": 512.0, "GB": 0.015, "bytes": 1_000_000.0,
          "mW": 2.0, "W": 0.002, "%": 0.1, "per_s": 2.0, "fps": 2.0, "kbps": 100.0, "Mbps": 0.1, "count": 0.0, "x": 0.0}


class SelectorError(ValueError):
    pass


def resolve(selector: str, runs: list[dict[str, Any]], bench: str | None = None) -> dict[str, Any]:
    if "@" in selector:
        bench, selector = selector.split("@", 1)
    pool = [r for r in runs if bench is None or r["bench"] == bench]
    m = re.fullmatch(r"(latest|nightly)(?:~(\d+))?", selector)
    if m:
        if bench is None:
            raise SelectorError(f"{selector!r} needs a bench: BENCH@{selector} or --bench")
        back = int(m.group(2) or 0)
        if m.group(1) == "latest":
            if back >= len(pool):
                raise SelectorError(f"{bench}@{selector}: only {len(pool)} runs")
            return pool[-1 - back]
        builds: list[str] = []
        for r in reversed(pool):
            b = r["build"]
            if b.get("channel") != "nightly":
                continue
            ident = b.get("version") or b.get("sha") or r["run_id"]
            if ident not in builds:
                builds.append(ident)
        if back >= len(builds):
            raise SelectorError(f"{bench}@{selector}: only {len(builds)} NIGHTLY builds measured")
        want = builds[back]
        return next(r for r in reversed(pool) if r["build"].get("channel") == "nightly"
                    and (r["build"].get("version") or r["build"].get("sha") or r["run_id"]) == want)
    if selector.startswith("sha:"):
        pre = selector[4:]
        hits = [r for r in pool if (r["build"].get("sha") or "").startswith(pre)]
    elif selector.startswith("version:"):
        hits = [r for r in pool if r["build"].get("version") == selector[8:]]
    else:
        hits = [r for r in pool if r["run_id"].startswith(selector)]
        if len({r["run_id"] for r in hits}) > 1:
            raise SelectorError(f"{selector!r} matches {len(hits)} runs: " + ", ".join(r["run_id"] for r in hits[:5]))
    if not hits:
        raise SelectorError(f"no run matches {selector!r}" + (f" for {bench}" if bench else ""))
    return hits[-1]


def compare(a: dict[str, Any], b: dict[str, Any], thresholds: dict[str, float] | None = None,
            default_threshold: float = DEFAULT_THRESHOLD, floors: dict[str, float] | None = None) -> dict[str, Any]:
    """floors: per-metric absolute floors (in the metric's unit) that replace the unit's FLOORS entry."""
    thresholds = thresholds or {}
    floors = floors or {}
    rows_a = {metric_key(r): r for r in a["rows"]}
    rows_b = {metric_key(r): r for r in b["rows"]}
    out = []
    for key in sorted(set(rows_a) | set(rows_b)):
        ra, rb = rows_a.get(key), rows_b.get(key)
        ref = rb or ra
        assert ref is not None
        entry: dict[str, Any] = {"metric": key[1], "labels": key[2], "unit": ref["unit"], "better": ref["better"],
                                 "a": ra["value"] if ra else None, "b": rb["value"] if rb else None,
                                 "a_p95": ra.get("p95") if ra else None, "b_p95": rb.get("p95") if rb else None}
        if ra is None or rb is None:
            entry.update(delta=None, delta_pct=None, verdict="only-b" if ra is None else "only-a")
        elif ra["unit"] != rb["unit"]:
            entry.update(delta=None, delta_pct=None, verdict="unit-changed")
        else:
            delta = rb["value"] - ra["value"]
            pct = (delta / abs(ra["value"]) * 100.0) if ra["value"] else (0.0 if delta == 0 else float("inf"))
            limit = thresholds.get(key[1], default_threshold)
            floor = floors.get(key[1], FLOORS.get(ref["unit"], 0.0))
            worse = (delta > 0) if ref["better"] == "lower" else (delta < 0) if ref["better"] == "higher" else False
            big = abs(pct) > limit and abs(delta) > floor
            verdict = "same" if not big or ref["better"] == "none" else ("regressed" if worse else "improved")
            entry.update(delta=delta, delta_pct=pct, threshold_pct=limit, verdict=verdict)
        out.append(entry)

    def ident(run: dict[str, Any]) -> dict[str, Any]:
        return {"run_id": run["run_id"], "bench": run["bench"], "build": run["build"], "host": run["host"],
                "harness": run["harness"], "timestamp": run["timestamp"]}

    warnings = []
    if a["harness"].get("version", "").split("+")[0] != b["harness"].get("version", "").split("+")[0]:
        warnings.append(f"harness versions differ ({a['harness'].get('version')} vs {b['harness'].get('version')}): "
                        "a metric may mean something else")
    if a["host"].get("chip") and b["host"].get("chip") and a["host"]["chip"] != b["host"]["chip"]:
        warnings.append(f"different chips ({a['host']['chip']} vs {b['host']['chip']})")
    return {"a": ident(a), "b": ident(b), "rows": out, "warnings": warnings,
            "regressions": [r for r in out if r["verdict"] == "regressed"]}


def _fmt(v: float | None) -> str:
    if v is None:
        return "-"
    if float(v).is_integer() and abs(v) < 1e15:
        return f"{int(v):,}"
    if abs(v) >= 100:
        return f"{v:,.0f}"
    if abs(v) >= 10:
        return f"{v:.1f}"
    return f"{v:.2f}"


def label_text(row: dict[str, Any]) -> str:
    labels = row.get("labels") or {}
    return " [" + ", ".join(f"{k}={labels[k]}" for k in sorted(labels)) + "]" if labels else ""


def build_label(run: dict[str, Any]) -> str:
    b = run["build"]
    parts = [b.get("channel") or "?"]
    if b.get("version"):
        parts.append(b["version"])
    if b.get("sha"):
        parts.append(b["sha"][:9])
    return " ".join(parts)


def render(result: dict[str, Any]) -> str:
    a, b = result["a"], result["b"]
    lines = [f"A: {a['run_id']}  {build_label(a)}  on {a['host'].get('name')}  ({a['harness'].get('version')})",
             f"B: {b['run_id']}  {build_label(b)}  on {b['host'].get('name')}  ({b['harness'].get('version')})", ""]
    head = ["metric", "labels", "unit", "A", "B", "delta", "delta %", "verdict"]
    table = [head]
    for r in result["rows"]:
        pct = "-" if r["delta_pct"] is None else f"{r['delta_pct']:+.1f}%"
        delta = "-" if r["delta"] is None else ("+" if r["delta"] > 0 else "") + _fmt(r["delta"])
        table.append([r["metric"], r["labels"] or "", r["unit"], _fmt(r["a"]), _fmt(r["b"]), delta, pct, r["verdict"]])
    widths = [max(len(row[i]) for row in table) for i in range(len(head))]
    for i, row in enumerate(table):
        lines.append("  ".join(cell.ljust(widths[j]) if j < 3 else cell.rjust(widths[j]) for j, cell in enumerate(row)).rstrip())
        if i == 0:
            lines.append("  ".join("-" * w for w in widths))
    for w in result["warnings"]:
        lines.append(f"warning: {w}")
    n = len(result["regressions"])
    lines.append(f"{n} regression{'s' if n != 1 else ''} past threshold" if n else "no regression past threshold")
    return "\n".join(lines)


def render_markdown(result: dict[str, Any]) -> str:
    a, b = result["a"], result["b"]
    lines = [f"A `{a['run_id']}` ({build_label(a)}, {a['host'].get('name')}) vs B `{b['run_id']}` "
             f"({build_label(b)}, {b['host'].get('name')})", "",
             "| metric | labels | unit | A | B | delta % | verdict |", "|---|---|---|--:|--:|--:|---|"]
    for r in result["rows"]:
        pct = "-" if r["delta_pct"] is None else f"{r['delta_pct']:+.1f}%"
        lines.append(f"| {r['metric']} | {r['labels']} | {r['unit']} | {_fmt(r['a'])} | {_fmt(r['b'])} | {pct} | {r['verdict']} |")
    for w in result["warnings"]:
        lines.append(f"\nwarning: {w}")
    return "\n".join(lines)
