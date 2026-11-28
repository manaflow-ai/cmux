#!/usr/bin/env python3
"""The transcript-replay perf report's summary: per record kind, base against head.

Reads the logs webviews/bench/transcript-replay-ab.sh writes (`before-<round>.log`, `after-<round>.log`: the
bench's `PERF_ROW {json}` lines) and the optional duress readings (`duress-before.json`, `duress-after.json`, from
scripts/measure/replay-under-load.sh), and prints Markdown: one row per record kind (thought, token, tool_call,
tool_output, whatever kinds the bench measured) with `<kind>_ms` p50 and p95, pane renders per record and hidden
pane renders per record, each base -> head. Report only: it never exits non-zero on a regression.

  scripts/ci/transcript_replay_report.py DIR [--base SHA] [--head SHA] [--class CLASS] [--series FILE]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys

PREFIX = "transcript_replay.long."
ROW = re.compile(r"^PERF_ROW (\{.*\})\s*$")
KIND_MS = re.compile(r"^transcript_replay\.long\.([a-z_]+)_ms$")
SIDES = (("before", "base"), ("after", "head"))
# A head p95 past both bounds reads as a regression (or improvement); inside them, as noise. One run per side on a
# shared runner: the per-kind ms moved ~1 ms between back-to-back runs on one VM, the render counts not at all.
MS_BOUND = 1.0
MS_SHARE = 0.20
COUNT_BOUND = 0.05
# Past this 1-minute load average per core on either side's runs, an ms move reads as "noisy" and not as a
# regression: a no-op head on a VM at load 38 over 8 cores read token p95 8.6 -> 19.5 ms. Render counts don't move
# with load, so they still read as regressions.
LOAD_BOUND = 1.0


def side_rows(directory: str, side: str) -> dict[str, dict[str, float]]:
    """{row name: {"p50", "p95"}}, the median over the side's rounds."""
    seen: dict[str, dict[str, list[float]]] = {}
    for name in sorted(os.listdir(directory)):
        if not re.fullmatch(rf"{side}-\d+\.log", name):
            continue
        with open(os.path.join(directory, name), errors="replace") as f:
            for line in f:
                m = ROW.match(line)
                if not m:
                    continue
                try:
                    row = json.loads(m[1])
                except ValueError:
                    continue
                if not str(row.get("name", "")).startswith("transcript_replay."):
                    continue
                for stat in ("p50", "p95"):
                    if isinstance(row.get(stat), (int, float)):
                        seen.setdefault(row["name"], {}).setdefault(stat, []).append(float(row[stat]))
    return {name: {k: statistics.median(v) for k, v in stats.items()} for name, stats in seen.items()}


def side_load(directory: str, side: str) -> float | None:
    """The highest load per core the side's `<side>-<round>.load` files recorded, or None."""
    seen = []
    for name in sorted(os.listdir(directory)):
        if re.fullmatch(rf"{side}-\d+\.load", name):
            with open(os.path.join(directory, name), errors="replace") as f:
                for line in f:
                    try:
                        seen.append(float(line))
                    except ValueError:
                        pass
    return max(seen) if seen else None


def first_error(directory: str, side: str) -> str:
    for name in sorted(os.listdir(directory)):
        if not re.fullmatch(rf"{side}-\d+\.log", name):
            continue
        with open(os.path.join(directory, name), errors="replace") as f:
            for line in f:
                line = re.sub(r"\x1b\[[0-9;]*m", "", line).strip()
                if re.search(r"FAILED:|\b\w*Error\b:|\berror:", line):
                    return line[:300]
    return ""


def kinds(*sides: dict[str, dict[str, float]]) -> list[str]:
    found = {m[1] for rows in sides for name in rows if (m := KIND_MS.match(name))}
    # Slopes are `<kind>_slope_ms_per_krow`, not a kind.
    return sorted(k for k in found if not k.endswith("_slope"))


def fmt(v: float | None, unit: str = "") -> str:
    return "-" if v is None else f"{v:g}{unit}"


def verdict(b: float | None, a: float | None, bound: float, share: float = 0.0) -> str:
    if b is None or a is None:
        return ""
    d = a - b
    edge = max(bound, share * b)
    return "**regression**" if d > edge else "improvement" if d < -edge else ""


def cell(rows_b, rows_a, name: str, stat: str, unit: str = "") -> tuple[str, float | None, float | None]:
    b = rows_b.get(name, {}).get(stat)
    a = rows_a.get(name, {}).get(stat)
    return f"{fmt(b, unit)} → {fmt(a, unit)}", b, a


def report(directory: str, base: str, head: str, klass: str) -> tuple[list[str], list[dict]]:
    rows = {side: side_rows(directory, side) for side, _ in SIDES}
    rb, ra = rows["before"], rows["after"]
    out = ["## Long-chat transcript replay, base vs head (report only)", "",
           f"Runner class `{klass}`; base `{base[:12]}`, head `{head[:12]}`; "
           "`RENDERS=1 SPLIT=1 bun bench/transcript-replay.bench.ts --only long` at both panes with the head's bench "
           "(webviews/bench/transcript-replay-ab.sh). Each cell is base → head.", ""]
    series: list[dict] = []
    for side, label in SIDES:
        if not rows[side]:
            why = first_error(directory, side)
            out.append(f"**No {label} rows**" + (f": `{why}`" if why else " (the run crashed or did not run)."))
    regressions = []
    loads = {label: side_load(directory, side) for side, label in SIDES}
    busiest = max((v for v in loads.values() if v is not None), default=None)
    noisy = busiest is not None and busiest > LOAD_BOUND
    if busiest is not None:
        out.append("Host load per core over the runs: " + ", ".join(
            f"{label} {fmt(v)}" for label, v in loads.items() if v is not None)
            + (f". Past {LOAD_BOUND:g}, so an ms move reads as noisy, not as a regression." if noisy else "."))
        out.append("")
    ks = kinds(rb, ra)
    if ks:
        out += ["| kind | ms p50 | ms p95 | renders / record | hidden pane renders / record | reads as |",
                "|---|---|---|---|---|---|"]
        for k in ks:
            p50, _, _ = cell(rb, ra, f"{PREFIX}{k}_ms", "p50")
            p95, b95, a95 = cell(rb, ra, f"{PREFIX}{k}_ms", "p95")
            # Every counted render per record (pane, transcript, row, frame, content), as `<kind>.renders_per_record`.
            renders, _, _ = cell(rb, ra, f"{PREFIX}{k}.renders_per_record", "p50")
            hidden, bh, ah = cell(rb, ra, f"{PREFIX}{k}.hidden_pane_renders_per_record", "p50")
            ms = verdict(b95, a95, MS_BOUND, MS_SHARE)
            if ms and noisy:
                ms = f"noisy (host load {busiest:g} per core)"
            marks = [m for m in (verdict(bh, ah, COUNT_BOUND), ms) if m]
            word = "**regression**" if "**regression**" in marks else marks[0] if marks else "noise"
            if word == "**regression**":
                regressions.append(k)
            out.append(f"| {k} | {p50} | {p95} | {renders} | {hidden} | {word} |")
            for name, stat in ((f"{k}_ms", "p50"), (f"{k}_ms", "p95"), (f"{k}.hidden_pane_renders_per_record", "p50")):
                b = rb.get(PREFIX + name, {}).get(stat)
                a = ra.get(PREFIX + name, {}).get(stat)
                if a is not None:
                    series.append({"series": f"{PREFIX}{name}.{stat}@{klass}", "runner_class": klass,
                                   "base": b, "head": a, "base_sha": base, "head_sha": head})
        worst = {lbl: max((r.get(f"{PREFIX}{k}_ms", {}).get("p95", 0.0) for k in ks), default=None)
                 for lbl, r in (("base", rb), ("head", ra)) if r}
        out += ["", "Worst kind's ms p95 (the per-record React time the 10 ms frame budget reads): "
                + ", ".join(f"{lbl} {v:g} ms" for lbl, v in worst.items())]
    elif rb or ra:
        out.append("**No per-kind rows** in the bench output.")
    duress = {}
    for side, label in SIDES:
        path = os.path.join(directory, f"duress-{side}.json")
        try:
            with open(path) as f:
                duress[label] = json.load(f)
        except (OSError, ValueError):
            pass
    out.append("")
    if duress:
        out += ["Duress (`scripts/measure/replay-under-load.sh --cores 2`, stress-ng 4 workers per core):", "",
                "| side | frame p50 | frame p95 | frame p99 | renderer main busy | long tasks | load per core |",
                "|---|---|---|---|---|---|---|"]
        for label, d in duress.items():
            out.append(f"| {label} | {fmt(d.get('frame_p50_ms'), ' ms')} | {fmt(d.get('frame_p95_ms'), ' ms')} | "
                       f"{fmt(d.get('frame_p99_ms'), ' ms')} | {fmt(d.get('renderer_main_busy_pct'), '%')} | "
                       f"{fmt(d.get('long_tasks'))} | {fmt(d.get('load_per_core'))} |")
        for label, d in duress.items():
            if d.get("frame_p95_ms") is None and d.get("error"):
                why = str(d["error"]).strip().splitlines()[0][:300]
                out.append(f"\n**{label} duress reading failed**: `{why}`")
    else:
        out.append("Duress not run on this class (no stress-ng on the runner).")
    out += ["", f"A kind reads as a regression when its head ms p95 is past {MS_BOUND:g} ms and {MS_SHARE:.0%} of "
            f"base, or its hidden pane renders per record rose past {COUNT_BOUND:g}. Report only: nothing here fails "
            "the pull request."]
    if regressions:
        out.insert(4, f"**Reads as a regression:** {', '.join(regressions)}.")
        out.insert(5, "")
    return out, series


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("dir")
    p.add_argument("--base", default="")
    p.add_argument("--head", default="")
    p.add_argument("--class", dest="klass", default="unknown")
    p.add_argument("--series")
    a = p.parse_args(argv)
    if not os.path.isdir(a.dir):
        print(f"## Long-chat transcript replay (report only)\n\n**The bench did not run** (no `{a.dir}`).")
        return 0
    lines, series = report(a.dir, a.base, a.head, a.klass)
    print("\n".join(lines))
    if a.series:
        with open(a.series, "w") as f:
            json.dump(series, f, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
