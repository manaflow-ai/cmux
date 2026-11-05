#!/usr/bin/env python3
"""Measure interaction latency as the number of workspaces grows.

The bench deliberately reuses the existing NEXT probes (new surfaces, sidebar stress and
automation typing).  It emits one row per interaction and workspace count, including p50/p95/p99,
then prints an advisory warning when the 1000-workspace p95 is more than 10% above its real baseline.
Warnings never fail the job: this is a trend budget, not a merge gate.  The one-workspace sidebar
scroll and switch rows are present but explicitly marked undefined because there is no real gesture
or second workspace to select; both use the 100-workspace baseline for the ratio.

For report-only use (and unit tests), pass ``--instant-report``, ``--sidebar-report`` and
``--typing-report``.  With ``--app`` the three probes are run for each count and their reports are
loaded automatically.
"""
import argparse
import json
import os
import pathlib
import signal
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
    report = report if isinstance(report, dict) else {}
    summary = report.get("summary")
    if not isinstance(summary, dict):
        return {}
    runs = report.get("runs")
    if not isinstance(runs, list):
        runs = []
    out = {}
    suffix = f"@{count}ws"
    # ``idle@Nws/new_workspace`` is the warm, same-harness interaction at N workspaces.
    for interaction, command in (("new_workspace", "new_workspace"), ("open_pane", "split_right")):
        entry = summary.get(f"idle{suffix}/{command}") or summary.get(f"idle/{command}")
        if not isinstance(entry, dict):
            continue
        values = []
        if entry:
            # Keep every warm-arm sample when present so p50/p95/p99 are meaningful.
            values = [r.get("visible_ms") for r in runs if isinstance(r, dict)
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
    report = report if isinstance(report, dict) else {}
    sizes = report.get("sizes")
    if not isinstance(sizes, dict):
        return {}
    size = sizes.get(str(count))
    if not isinstance(size, dict):
        return {}
    out = {}
    scroll = size.get("scroll")
    if not isinstance(scroll, dict):
        scroll = {}
    frame_reply = scroll.get("frames")
    if not isinstance(frame_reply, dict):
        frame_reply = {}
    frame_metrics = frame_reply.get("frame_metrics") or {}
    if not isinstance(frame_metrics, dict):
        frame_metrics = {}
    values = frame_reply.get("intervals_ms") or []
    # Do not substitute RPC handling time for frame intervals: they measure different
    # surfaces, so comparing one topology's frame time with another's RPC time would
    # manufacture a scaling result.
    if values and frame_metrics.get("complete") is True:
        out["sidebar_scroll"] = stats(values)
    switch = size.get("switch")
    if not isinstance(switch, dict):
        switch = {}
    switch_frame_reply = switch.get("frames")
    if not isinstance(switch_frame_reply, dict):
        switch_frame_reply = {}
    switch_frames = switch_frame_reply.get("frame_metrics") or {}
    if not isinstance(switch_frames, dict):
        switch_frames = {}
    switch_stats = switch.get("click_to_idle_ms")
    if switch_frames.get("complete") is True and isinstance(switch_stats, dict) and isinstance(switch_stats.get("p95"), (int, float)):
        out["switch"] = {"p50": switch_stats.get("p50", switch_stats["p95"]),
                          "p95": switch_stats["p95"],
                          "p99": switch_stats.get("p99", switch_stats["p95"]),
                          "n": switch_stats.get("n")}
    elif switch_frames.get("complete") is True and isinstance(switch_stats, (int, float)):
        out["switch"] = stats([switch_stats])
    return out


def typing_rows(report, count):
    # automation-typing-bench reports a phase for the seeded workspace count.  Prefer automation
    # (load) and fall back to light so older reports remain consumable.
    report = report if isinstance(report, dict) else {}
    phases = report.get("phases")
    if not isinstance(phases, list):
        return {}
    # A percentile is a valid scaling sample only when every requested key produced a
    # complete frame record. Partial phases are reported as incomplete by coverage_failures.
    complete = [p for p in phases if isinstance(p, dict) and isinstance(p.get("keys"), int)
                and isinstance(p.get("complete"), int) and p.get("keys") > 0
                and p.get("complete") >= p.get("keys") and p.get("key_to_frame_ms")]
    candidates = [p for p in complete if "automation" in str(p.get("phase", ""))]
    candidates += [p for p in complete if "light" in str(p.get("phase", ""))]
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
        # A one-row sidebar cannot perform a real scroll or workspace switch.  Use
        # the smallest topology with a real gesture/selection for those interactions.
        baseline_count = 100 if interaction in ("sidebar_scroll", "switch") else 1
        one = (values.get(baseline_count) or {}).get("p95")
        many = (values.get(1000) or {}).get("p95")
        if not isinstance(one, (int, float)) or not isinstance(many, (int, float)) or one <= 0:
            continue
        ratio = many / one
        if ratio > limit:
            warnings.append({"interaction": interaction, "p95_baseline": one,
                             "baseline_workspaces": baseline_count, "p95_1000": many,
                             "ratio": round(ratio, 3), "limit": limit})
    return warnings


def collect(reports):
    rows = []
    for count in COUNTS:
        docs = reports.get(count) or {}
        if not isinstance(docs, dict):
            docs = {}
        merged = {}
        invalid = set(docs.get("invalid_probes") or ())
        if "instant" not in invalid:
            merged.update(instant_rows(docs.get("instant"), count))
        if "sidebar" not in invalid:
            # The raw sidebar probe starts with one bootstrap row and receives count-1 from
            # app mode. Preserve that same offset for report-only replay when no metadata was
            # stored beside the raw results.
            sidebar_count = docs.get("sidebar_count", count - 1 if count > 1 else count)
            merged.update(sidebar_rows(docs.get("sidebar"), sidebar_count))
        if "typing" not in invalid:
            merged.update(typing_rows(docs.get("typing"), count))
        if count == 1 and "sidebar" not in invalid:
            # A single workspace cannot scroll a list or switch to another workspace. Keep both
            # rows explicit while excluding them from ratio warnings.
            merged["sidebar_scroll"] = {"p50": None, "p95": None, "p99": None, "n": 0, "status": "undefined"}
            merged["switch"] = {"p50": None, "p95": None, "p99": None, "n": 0, "status": "undefined"}
        for interaction, values in merged.items():
            rows.append({"name": f"workspace_scaling.{interaction}.{count}", "interaction": interaction,
                         "workspaces": count, "unit": "ms", "budget": None, "floor": 1.0, **values})
    return rows


def coverage_failures(rows):
    """Return missing interaction rows for report-only replay validation."""
    present = {(int(row["workspaces"]), row["interaction"]) for row in rows
               if isinstance(row.get("workspaces"), int) and isinstance(row.get("interaction"), str)}
    failures = []
    for count in COUNTS:
        expected = {"new_workspace", "open_pane", "type"}
        if count > 1:
            expected |= {"sidebar_scroll", "switch"}
        measured = {interaction for topology, interaction in present if topology == count}
        missing = sorted(expected - measured)
        if missing:
            failures.append({"workspaces": count, "missing": missing, "incomplete": "missing_rows"})
    return failures


def run_probe(script, args, out, timeout=900):
    path = out / (script.stem + ".log")
    with path.open("w") as log:
        process = subprocess.Popen([sys.executable, str(script), *args], stdout=log, stderr=subprocess.STDOUT,
                                    cwd=HERE.parent.parent, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            log.write(f"workspace-scaling: probe timed out after {timeout}s\n")
            try:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=10)
            except (ProcessLookupError, subprocess.TimeoutExpired):
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            return 124


def read_report(path):
    """Load a probe report without turning a failed or truncated probe into a crash."""
    try:
        value = json.loads(path.read_text())
        # A probe report is always a JSON object. Treat a valid scalar/list as an absent
        # report so collection records missing rows as incomplete instead of raising while
        # indexing the probe's fields.
        return value if isinstance(value, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def run_app(opts):
    reports, failures = {}, []
    for count in COUNTS:
        root = pathlib.Path(opts.out) / str(count)
        root.mkdir(parents=True, exist_ok=True)
        failure_start = len(failures)
        probe_timeout = opts.probe_timeout if count < 1000 else opts.large_probe_timeout
        instant = root / "instant"
        code = run_probe(HERE / "instant-new-surfaces-bench.py",
                         ["--tag", opts.tag, "--app", opts.app, "--commands", "new_workspace,split_right",
                          "--workspaces", str(count), "--empty-workspaces", "--exact-workspaces",
                          "--arms", "warm", "--phases", "idle", "--runs", "6",
                          "--out", str(instant), "--json", str(instant / "report.json")], root, probe_timeout)
        if code != 0 or not (instant / "report.json").exists():
            failures.append({"workspaces": count, "probe": "instant", "exit": code,
                             "report": str(instant / "report.json")})
        sidebar = root / "sidebar"
        # sidebar-stress-bench starts with one workspace before grow(size). Ask it to grow size-1 so
        # its measured topology is exactly the headline count rather than count+1. A one-row list
        # cannot perform either gesture, so skip the probe instead of asking it to run a zero-size
        # switch scenario that reports a false incomplete measurement.
        sidebar_count = max(0, count - 1)
        if count == 1:
            sidebar_report = {}
        else:
            code = run_probe(HERE / "sidebar-stress-bench.py",
                             ["--tag", opts.tag, "--app", opts.app, "--sizes", str(sidebar_count), "--tickers", "15",
                              "--scenarios", "scroll,scroll_ticking,switch", "--stop", "--no-trace", "--out", str(sidebar)], root,
                             probe_timeout)
            if code != 0 or not (sidebar / "results.json").exists():
                failures.append({"workspaces": count, "probe": "sidebar", "exit": code,
                                 "report": str(sidebar / "results.json")})
            sidebar_report = read_report(sidebar / "results.json")
        typing = root / "typing"
        # Keep the typing workload invariant across topology sizes. The typing workspace is the
        # sole active row and all other seeded rows are empty, so a ratio reflects workspace count
        # rather than a different number of agents or browser operations.
        agents = 0
        code = run_probe(HERE / "automation-typing-bench.py",
                         ["--app", opts.app, "--agents", str(agents), "--workspace-count", str(count), "--layouts", "light", "--samples", "30",
                          "--rounds", "1", "--no-browser", "--out", str(typing), "--json", str(typing / "report.json")], root,
                         probe_timeout)
        if code != 0 or not (typing / "report.json").exists():
            failures.append({"workspaces": count, "probe": "typing", "exit": code,
                             "report": str(typing / "report.json")})
        reports[count] = {"instant": read_report(instant / "report.json"),
                          "sidebar": sidebar_report,
                          "typing": read_report(typing / "report.json"),
                          "sidebar_count": sidebar_count}
        # A successful probe can still contain missed display samples. Do not let a partial
        # percentile set become a valid scaling baseline; the instant probe is requested for six
        # warm samples per interaction at each topology.
        instant_summary = reports[count]["instant"].get("summary") or {}
        for command in ("new_workspace", "split_right"):
            entry = instant_summary.get(f"idle@{count}ws/{command}") or instant_summary.get(f"idle/{command}")
            if not isinstance(entry, dict):
                failures.append({"workspaces": count, "probe": "instant", "command": command,
                                 "incomplete": "missing_summary"})
            else:
                missed = entry.get("missed") or 0
                samples = entry.get("n") or 0
                if missed or samples < 6:
                    failures.append({"workspaces": count, "probe": "instant", "command": command,
                                     "incomplete": "missed_samples", "samples": samples, "missed": missed})
        probes = (instant_rows(reports[count]["instant"], count),
                  sidebar_rows(reports[count]["sidebar"], sidebar_count),
                  typing_rows(reports[count]["typing"], count))
        # A one-workspace sidebar has no real scroll or workspace-to-workspace switch. Both are
        # explicit undefined rows and use the 100-workspace topology as their ratio baseline.
        sidebar_expected = ("sidebar_scroll", "switch") if count > 1 else ()
        expected = (("new_workspace", "open_pane"), sidebar_expected, ("type",))
        for probe, got, names in zip(("instant", "sidebar", "typing"), probes, expected):
            missing = [name for name in names if name not in got]
            if missing:
                failures.append({"workspaces": count, "probe": probe, "missing": missing})
        measured = ((reports[count]["sidebar"].get("sizes") or {}).get(str(sidebar_count)) or {}).get("rows_listed")
        if isinstance(measured, int) and measured != count:
            failures.append({"workspaces": count, "probe": "sidebar", "expected_rows": count,
                             "measured_rows": measured})
        reports[count]["invalid_probes"] = sorted({failure.get("probe") for failure in failures[failure_start:]
                                                    if failure.get("probe")})
        # Preserve completed topology reports if the outer cron budget interrupts a later probe.
        partial = {"workspaces": list(COUNTS), "rows": collect(reports),
                   "warnings": scaling_warnings(collect(reports)), "incomplete": failures,
                   "budget": {"ratio": LIMIT, "advisory": True}}
        output = pathlib.Path(opts.json)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(partial, indent=2) + "\n")
    return reports, failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app")
    ap.add_argument("--tag", default="workspace-scaling")
    ap.add_argument("--out", required=True)
    ap.add_argument("--json", required=True)
    ap.add_argument("--probe-timeout", type=int, default=240,
                    help="maximum seconds for each GUI probe before recording it incomplete")
    ap.add_argument("--large-probe-timeout", type=int, default=600,
                    help="maximum seconds for each 1000-workspace probe before recording it incomplete")
    ap.add_argument("--instant-report", action="append", default=[])
    ap.add_argument("--sidebar-report", action="append", default=[])
    ap.add_argument("--typing-report", action="append", default=[])
    opts = ap.parse_args()
    reports, failures = {}, []
    if opts.app:
        reports, failures = run_app(opts)
    else:
        paths = {"instant": opts.instant_report, "sidebar": opts.sidebar_report, "typing": opts.typing_report}
        for probe, values in paths.items():
            if len(values) != len(COUNTS):
                failures.append({"probe": probe, "expected_reports": len(COUNTS), "actual_reports": len(values)})
        for index, count in enumerate(COUNTS):
            reports[count] = {}
            for probe, values in paths.items():
                if index >= len(values):
                    reports[count][probe] = {}
                    continue
                try:
                    with open(values[index]) as handle:
                        value = json.load(handle)
                    if not isinstance(value, dict):
                        raise ValueError("expected a JSON object")
                    reports[count][probe] = value
                except (OSError, json.JSONDecodeError) as error:
                    failures.append({"workspaces": count, "probe": probe, "report": values[index],
                                     "error": str(error)})
                    reports[count][probe] = {}
                except ValueError as error:
                    failures.append({"workspaces": count, "probe": probe, "report": values[index],
                                     "error": str(error)})
                    reports[count][probe] = {}
    rows = collect(reports)
    # Report-only mode is used by CI replay and should have the same coverage contract as an
    # app run. Empty or malformed JSON must be visible as an incomplete budget part, rather than
    # silently producing a successful report with no scaling rows. App mode already validates each
    # topology while it runs, so do not duplicate those failure records here.
    if not opts.app:
        failures.extend(coverage_failures(rows))
    warnings = scaling_warnings(rows)
    result = {"workspaces": list(COUNTS), "rows": rows, "warnings": warnings, "incomplete": failures,
              "budget": {"ratio": LIMIT, "advisory": True}}
    output = pathlib.Path(opts.json)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    for warning in warnings:
        print("WORKSPACE-SCALING-WARNING " + json.dumps(warning), flush=True)
    for failure in failures:
        print("WORKSPACE-SCALING-INCOMPLETE " + json.dumps(failure), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
