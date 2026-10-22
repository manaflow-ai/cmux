"""perf100 reports: a Markdown table per run, before/after comparison, and the budget gate."""
from __future__ import annotations

import json
import os

import runlib

TABLE_COLS = (("cpu_s", "CPU s"), ("cpu_pct", "CPU %"), ("wakeups_per_s", "wakeups/s"), ("rss_mb", "RSS MB"),
              ("footprint_mb", "footprint MB"), ("peak_footprint_mb", "peak MB"), ("threads", "threads"),
              ("disk_written_mb", "written MB"), ("disk_written_mb_per_min", "written MB/min"), ("procs", "procs"))


def load(path: str) -> dict:
    with open(path) as handle:
        return json.load(handle)


def _fmt(value) -> str:
    if value is None:
        return ""
    if isinstance(value, float):
        if value == 0:
            return "0"
        if abs(value) >= 100:
            return f"{value:,.0f}"
        if abs(value) >= 1:
            return f"{value:.2f}".rstrip("0").rstrip(".")
        return f"{value:.3g}"
    return str(value)


def markdown(run: dict) -> str:
    host = run["host"]
    build = run.get("build", {})
    lines = [f"### {run['scenario']} {run['variant']} (seed {run['seed']})", "",
             f"host `{host.get('name')}` (class `{host.get('class')}`, {host.get('cpu', host.get('model', ''))}, "
             f"{host.get('cores')} cores, {host.get('ram_gb')} GB, {host.get('macos') or host.get('os')}), "
             f"load {host.get('load_at_start')} -> {host.get('load_at_end')}; "
             f"build tag `{build.get('tag')}` sha `{(build.get('sha') or '')[:12]}`; wall {run.get('wall_s')} s", ""]
    if run.get("error"):
        lines += [f"**error:** `{run['error'][:400]}`", ""]
    for name, phase in run.get("phases", {}).items():
        lines.append(f"{name} ({phase['seconds']} s window)")
        lines.append("")
        lines.append("| group | " + " | ".join(label for _, label in TABLE_COLS) + " |")
        lines.append("|---|" + "---:|" * len(TABLE_COLS))
        for group in ("cmux",) + runlib.GROUP_ORDER:
            values = phase["groups"].get(group)
            if not values:
                continue
            label = f"**{group}**" if group == "cmux" else group
            lines.append(f"| {label} | " + " | ".join(_fmt(values.get(k)) for k, _ in TABLE_COLS) + " |")
        for unit, values in (phase.get("per_unit") or {}).items():
            lines.append("")
            lines.append(f"per {unit}: " + ", ".join(f"{k} {_fmt(v)}" for k, v in values.items()))
        lines.append("")
    other = {k: v for k, v in run.get("metrics", {}).items()
             if k.split(".")[0] not in run.get("phases", {}) or k.split(".")[1] not in
             (("cmux",) + runlib.GROUP_ORDER + tuple(f"per_{u}" for u in ("terminal", "tab", "session", "workspace")))}
    if other:
        lines.append("| metric | value |")
        lines.append("|---|---:|")
        for key in sorted(other):
            lines.append(f"| {key} | {_fmt(other[key])} |")
        lines.append("")
    for note in run.get("notes", []):
        lines.append(f"- note: {note}")
    for item in run.get("unverified", []):
        lines.append(f"- UNVERIFIED: {item}")
    return "\n".join(lines).rstrip() + "\n"


def markdown_many(paths: list[str]) -> str:
    runs = [load(p) for p in paths]
    head = ["# perf100 run", ""]
    if runs:
        sources = runs[0].get("sources", {})
        head.append("Counter sources: " + "; ".join(f"{k}: {v}" for k, v in sources.items()))
        head.append("")
        head.append("`cmux` = app + tui + acpmux + browser + helpers. `agents` (replay stand-ins for agent CLIs), "
                    "`workload` (the shells and programs in the terminals) and `harness` (this runner's CLI calls) "
                    "are shown apart and are not in `cmux`. peak MB sums each process kind's peak.")
        head.append("")
    return "\n".join(head) + "\n".join(markdown(r) for r in runs)


def _key(run: dict) -> str:
    return f"{run['scenario']}/{run['variant']}"


def compare(before_paths: list[str], after_paths: list[str], only: str | None = None) -> str:
    """Before, after and before/after for every metric both runs have (same scenario and variant)."""
    before = {_key(r): r for r in map(load, before_paths)}
    after = {_key(r): r for r in map(load, after_paths)}
    out = []
    for key in sorted(set(before) & set(after)):
        b, a = before[key], after[key]
        out.append(f"### {key}: `{b['build'].get('tag')}` ({(b['build'].get('sha') or '')[:12]}, {b['host']['name']}) "
                   f"-> `{a['build'].get('tag')}` ({(a['build'].get('sha') or '')[:12]}, {a['host']['name']})")
        if b["host"].get("class") != a["host"].get("class"):
            out.append("WARNING: different host classes; the numbers do not compare")
        if b.get("seed") != a.get("seed"):
            out.append(f"WARNING: different seeds ({b.get('seed')} vs {a.get('seed')})")
        out.append("")
        out.append("| metric | before | after | before/after |")
        out.append("|---|---:|---:|---:|")
        for metric in sorted(set(b["metrics"]) | set(a["metrics"])):
            if only and only not in metric:
                continue
            x, y = b["metrics"].get(metric), a["metrics"].get(metric)
            ratio = ""
            if isinstance(x, (int, float)) and isinstance(y, (int, float)) and y:
                ratio = f"{x / y:.2f}x"
            elif isinstance(x, (int, float)) and y == 0 and x:
                ratio = "inf"
            out.append(f"| {metric} | {_fmt(x)} | {_fmt(y)} | {ratio} |")
        out.append("")
    missing = sorted(set(before) ^ set(after))
    if missing:
        out.append("Only in one side: " + ", ".join(missing))
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- budgets


def load_budgets(path: str) -> list[dict]:
    with open(path) as handle:
        data = json.load(handle)
    if data.get("schema") != "perf100.budgets.v1":
        raise SystemExit(f"perf100: {path} is not a perf100.budgets.v1 file")
    budgets = data.get("budgets", [])
    seen = set()
    for b in budgets:
        for field in ("id", "scenario", "variant", "host", "metric", "limit", "margin_pct", "lane"):
            if field not in b:
                raise SystemExit(f"perf100: budget {b.get('id')} has no {field}")
        if b["id"] in seen:
            raise SystemExit(f"perf100: duplicate budget id {b['id']}")
        seen.add(b["id"])
        if b.get("direction", "max") not in ("max", "min"):
            raise SystemExit(f"perf100: budget {b['id']}: direction is max or min")
    return budgets


def check_budgets(budget_path: str, result_paths: list[str], host_class: str | None = None) -> tuple[int, str]:
    """Exit code (1 when a budget is broken) and a report. A budget applies to a run of its scenario,
    variant and host class; `limit` is the reference value and `margin_pct` the allowed regression.
    direction max (default): value <= limit * (1 + margin); min: value >= limit * (1 - margin).
    With `host_class`, a budget of that host class (or "*") whose scenario and variant ran in none of
    the results is a failure too (a run that silently stopped measuring must not pass), unless the
    results hold no run of that scenario at all (a subset run: skipped)."""
    budgets = load_budgets(budget_path)
    runs = [load(p) for p in result_paths]
    lines = ["| budget | lane | metric | limit | allowed | value | verdict |", "|---|---|---|---:|---:|---:|---|"]
    failed = 0
    for b in budgets:
        matching = [r for r in runs if r["scenario"] == b["scenario"] and r["variant"] == b["variant"]
                    and (b["host"] == "*" or r["host"].get("class") == b["host"])]
        if not matching:
            ran_scenario = any(r["scenario"] == b["scenario"] for r in runs)
            mine = host_class is not None and b["host"] in (host_class, "*")
            if mine and ran_scenario:
                failed += 1
                lines.append(f"| {b['id']} | {b['lane']} | {b['metric']} | {_fmt(b['limit'])} | | | FAIL (no {b['variant']} run) |")
            else:
                lines.append(f"| {b['id']} | {b['lane']} | {b['metric']} | {_fmt(b['limit'])} | | | skipped (no run) |")
            continue
        for r in matching:
            value = r["metrics"].get(b["metric"])
            margin = b["margin_pct"] / 100.0
            if b.get("direction", "max") == "max":
                allowed = b["limit"] * (1 + margin) + b.get("floor", 0)
                ok = value is not None and value <= allowed
            else:
                allowed = b["limit"] * (1 - margin)
                ok = value is not None and value >= allowed
            if r.get("error"):
                ok = False
            verdict = "ok" if ok else ("FAIL (run error)" if r.get("error") else "FAIL" if value is not None else "FAIL (missing)")
            failed += 0 if ok else 1
            lines.append(f"| {b['id']} | {b['lane']} | {b['metric']} | {_fmt(b['limit'])} | {_fmt(round(allowed, 3))} "
                         f"| {_fmt(value)} | {verdict} |")
    lines.append("")
    lines.append(f"PERF100-BUDGET {'FAIL' if failed else 'OK'}: {failed} broken of {len(budgets)} budgets")
    return (1 if failed else 0), "\n".join(lines) + "\n"


def index(out_dir: str) -> list[str]:
    return sorted(os.path.join(out_dir, n) for n in os.listdir(out_dir)
                  if n.endswith(".json") and (n.startswith("S") or n.startswith("chat-load-")))
