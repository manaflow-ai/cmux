#!/usr/bin/env python3
"""Measure interaction latency as the number of workspaces grows.

The bench deliberately reuses the existing NEXT probes (new surfaces, sidebar stress and
automation typing).  It emits one row per interaction and workspace count, including p50/p95/p99,
then prints an advisory warning when the 1000-workspace p95 is more than 10% above the one-workspace
value.  Warnings never fail the job: this is a trend budget, not a merge gate.

For report-only use (and unit tests), pass ``--instant-report``, ``--sidebar-report`` and
``--typing-report``.  With ``--app`` the three probes are run for each count and their reports are
loaded automatically.
"""
import argparse
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
COUNTS = (1, 100, 1000)
LIMIT = 1.10


def percentile(values, q):
    values = sorted(float(v) for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    pos = (len(values) - 1) * q
    lo, hi = int(pos), min(int(pos) + 1, len(values) - 1)
    return round(values[lo] + (values[hi] - values[lo]) * (pos - lo), 3)


def stats(values):
    return {"p50": percentile(values, .50), "p95": percentile(values, .95), "p99": percentile(values, .99),
            "n": len([v for v in values if isinstance(v, (int, float))])}


def _samples(summary, key):
    if not isinstance(summary, dict):
        return []
    # Existing probes generally retain raw samples in a list; accept their stat dictionaries too.
    if isinstance(summary.get(key), list):
        return summary[key]
    value = summary.get(key)
    if isinstance(value, dict):
        return [value[k] for k in ("p50", "p95", "p99") if isinstance(value.get(k), (int, float))]
    return [value] if isinstance(value, (int, float)) else []


def instant_rows(report, count):
    """Return new-workspace and open-pane timings from instant-new-surfaces."""
    summary = (report or {}).get("summary") or {}
    out = {}
    suffix = f"@{count}ws"
    # ``idle@Nws/new_workspace`` is the warm, same-harness interaction at N workspaces.
    for interaction, command in (("new_workspace", "new_workspace"), ("open_pane", "split_right")):
        entry = summary.get(f"idle{suffix}/{command}") or summary.get(f"idle/{command}")
        values = []
        if entry:
            # Keep every warm-arm sample when present so p50/p95/p99 are meaningful.
            values = [r.get("visible_ms") for r in (report or {}).get("runs", [])
                      if r.get("phase") == f"idle{suffix}" and r.get("command") == command]
            if not values:
                if isinstance(entry.get("visible_p50"), (int, float)):
                    out[interaction] = {"p50": entry["visible_p50"], "p95": entry.get("visible_p95"),
                                        "p99": entry.get("visible_p99", entry.get("visible_p95")),
                                        "n": entry.get("n")}
                    continue
        if values:
            out[interaction] = stats(values)
    return out


def sidebar_rows(report, count):
    size = ((report or {}).get("sizes") or {}).get(str(count)) or {}
    out = {}
    frame_reply = (size.get("scroll") or {}).get("frames") or {}
    values = frame_reply.get("intervals_ms") or []
    if not values:
        values = _samples((size.get("scroll") or {}).get("event_rpc_ms"), "p95")
    if values:
        out["sidebar_scroll"] = stats(values)
    switch = size.get("switch") or {}
    switch_stats = switch.get("click_to_idle_ms")
    if isinstance(switch_stats, dict) and isinstance(switch_stats.get("p95"), (int, float)):
        out["switch"] = {"p50": switch_stats.get("p50", switch_stats["p95"]),
                          "p95": switch_stats["p95"],
                          "p99": switch_stats.get("p99", switch_stats["p95"]),
                          "n": switch_stats.get("n")}
    elif isinstance(switch_stats, (int, float)):
        out["switch"] = stats([switch_stats])
    return out


def typing_rows(report, count):
    # automation-typing-bench reports a phase for the seeded workspace count.  Prefer automation
    # (load) and fall back to light so older reports remain consumable.
    phases = (report or {}).get("phases") or []
    candidates = [p for p in phases if "automation" in str(p.get("phase", "")) and p.get("key_to_frame_ms")]
    candidates += [p for p in phases if "light" in str(p.get("phase", "")) and p.get("key_to_frame_ms")]
    if not candidates:
        return {}
    value = candidates[-1].get("key_to_frame_ms")
    if isinstance(value, dict) and all(isinstance(value.get(k), (int, float)) for k in ("p50", "p95")):
        return {"type": {"p50": value["p50"], "p95": value["p95"],
                          "p99": value.get("p99", value["p95"]), "n": value.get("n")}}
    values = _samples(value, "p95") or _samples(value, "p50")
    return {"type": stats(values)} if values else {}


def scaling_warnings(rows, limit=LIMIT):
    """Compare 1000 vs 1 p95 per interaction; return advisory warning records."""
    by_name = {}
    for row in rows:
        by_name.setdefault(row["interaction"], {})[int(row["workspaces"])] = row
    warnings = []
    for interaction, values in sorted(by_name.items()):
        one = (values.get(1) or {}).get("p95")
        many = (values.get(1000) or {}).get("p95")
        if not isinstance(one, (int, float)) or not isinstance(many, (int, float)) or one <= 0:
            continue
        ratio = many / one
        if ratio > limit:
            warnings.append({"interaction": interaction, "p95_1": one, "p95_1000": many,
                             "ratio": round(ratio, 3), "limit": limit})
    return warnings


def collect(reports):
    rows = []
    for count in COUNTS:
        docs = reports.get(count) or {}
        merged = {}
        merged.update(instant_rows(docs.get("instant"), count))
        merged.update(sidebar_rows(docs.get("sidebar"), docs.get("sidebar_count", count)))
        merged.update(typing_rows(docs.get("typing"), count))
        for interaction, values in merged.items():
            rows.append({"name": f"workspace_scaling.{interaction}.{count}", "interaction": interaction,
                         "workspaces": count, "unit": "ms", "budget": None, "floor": 1.0, **values})
    return rows


def run_probe(script, args, out):
    path = out / (script.stem + ".log")
    with path.open("w") as log:
        return subprocess.run([sys.executable, str(script), *args], stdout=log, stderr=subprocess.STDOUT,
                              cwd=HERE.parent.parent, check=False).returncode


def run_app(opts):
    reports, failures = {}, []
    for count in COUNTS:
        root = pathlib.Path(opts.out) / str(count)
        root.mkdir(parents=True, exist_ok=True)
        instant = root / "instant"
        code = run_probe(HERE / "instant-new-surfaces-bench.py",
                         ["--tag", opts.tag, "--app", opts.app, "--commands", "new_workspace,split_right",
                          "--workspaces", str(count), "--empty-workspaces", "--arms", "warm", "--phases", "idle", "--runs", "6",
                          "--out", str(instant), "--json", str(instant / "report.json")], root)
        if code != 0 or not (instant / "report.json").exists():
            failures.append({"workspaces": count, "probe": "instant", "exit": code,
                             "report": str(instant / "report.json")})
        sidebar = root / "sidebar"
        # sidebar-stress-bench starts with one workspace before grow(size). Ask it to grow size-1 so
        # its measured topology is exactly the headline count rather than count+1.
        sidebar_count = max(0, count - 1)
        code = run_probe(HERE / "sidebar-stress-bench.py",
                         ["--tag", opts.tag, "--app", opts.app, "--sizes", str(sidebar_count), "--tickers", "15",
                          "--scenarios", "scroll,scroll_ticking,switch", "--stop", "--no-trace", "--out", str(sidebar)], root)
        if code != 0 or not (sidebar / "results.json").exists():
            failures.append({"workspaces": count, "probe": "sidebar", "exit": code,
                             "report": str(sidebar / "results.json")})
        typing = root / "typing"
        # Seed empty rows to reach the requested topology, while keeping only ten active terminals
        # so the 1000-workspace run never exhausts the host's PTY limit.
        agents = min(10, max(0, count - 2))
        code = run_probe(HERE / "automation-typing-bench.py",
                         ["--app", opts.app, "--agents", str(agents), "--workspace-count", str(count), "--layouts", "light", "--samples", "30",
                          "--rounds", "1", *(["--no-browser"] if count == 1 else []), "--out", str(typing), "--json", str(typing / "report.json")], root)
        if code != 0 or not (typing / "report.json").exists():
            failures.append({"workspaces": count, "probe": "typing", "exit": code,
                             "report": str(typing / "report.json")})
        reports[count] = {"instant": json.loads((instant / "report.json").read_text()) if (instant / "report.json").exists() else {},
                          "sidebar": json.loads((sidebar / "results.json").read_text()) if (sidebar / "results.json").exists() else {},
                          "typing": json.loads((typing / "report.json").read_text()) if (typing / "report.json").exists() else {},
                          "sidebar_count": sidebar_count}
        probes = (instant_rows(reports[count]["instant"], count),
                  sidebar_rows(reports[count]["sidebar"], sidebar_count),
                  typing_rows(reports[count]["typing"], count))
        expected = (("new_workspace", "open_pane"), ("sidebar_scroll", "switch"), ("type",))
        for probe, got, names in zip(("instant", "sidebar", "typing"), probes, expected):
            missing = [name for name in names if name not in got]
            if missing:
                failures.append({"workspaces": count, "probe": probe, "missing": missing})
        measured = ((reports[count]["sidebar"].get("sizes") or {}).get(str(sidebar_count)) or {}).get("rows_listed")
        if isinstance(measured, int) and measured != count:
            failures.append({"workspaces": count, "probe": "sidebar", "expected_rows": count,
                             "measured_rows": measured})
    return reports, failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app")
    ap.add_argument("--tag", default="workspace-scaling")
    ap.add_argument("--out", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--instant-report", action="append", default=[])
    ap.add_argument("--sidebar-report", action="append", default=[])
    ap.add_argument("--typing-report", action="append", default=[])
    opts = ap.parse_args()
    reports, failures = {}, []
    if opts.app:
        reports, failures = run_app(opts)
    else:
        for count, instant, sidebar, typing in zip(COUNTS, opts.instant_report, opts.sidebar_report, opts.typing_report):
            reports[count] = {"instant": json.load(open(instant)), "sidebar": json.load(open(sidebar)),
                              "typing": json.load(open(typing))}
    rows = collect(reports)
    warnings = scaling_warnings(rows)
    result = {"workspaces": list(COUNTS), "rows": rows, "warnings": warnings, "incomplete": failures,
              "budget": {"ratio": LIMIT, "advisory": True}}
    pathlib.Path(opts.json).write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    for warning in warnings:
        print("WORKSPACE-SCALING-WARNING " + json.dumps(warning), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
