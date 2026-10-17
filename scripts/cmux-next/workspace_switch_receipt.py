#!/usr/bin/env python3
"""Portable receipt and warning-only summary for the workspace switch bench."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import statistics
import sys

SCHEMA_VERSION = 1
SEMANTICS = "surface_readiness_rpc_upper_bound"
CACHE_STATES = {"cold": "new_workspace", "warm": "parked_revisit", "prefetched": "explicit_previsit"}
# Initial smoke thresholds, not a baseline comparison or a required check.
LIMITS = {"cold": 500.0, "warm": 150.0, "prefetched": 150.0}
SETTLED_LIMIT_MS = 1000.0
DROPPED_RATIO_LIMIT = 0.05


def receipt(sha: str, tag: str, display: dict, parameters: dict, *, status="measured", reason=None) -> dict:
    host = {"name": platform.node(), "system": platform.system(), "release": platform.release(), "machine": platform.machine()}
    fingerprint = {"source_sha": sha, "tag": tag, "host": host, "display": display,
                   "parameters": parameters, "schema_version": SCHEMA_VERSION, "measurement_semantics": SEMANTICS}
    return {**fingerprint, "fingerprint": hashlib.sha256(json.dumps(fingerprint, sort_keys=True).encode()).hexdigest(),
            "recorded_at": datetime.now(timezone.utc).isoformat(), "status": status, "reason": reason, "runs": [],
            "limits": {"first_visible_ms": LIMITS, "settled_ms": SETTLED_LIMIT_MS, "dropped_ratio": DROPPED_RATIO_LIMIT},
            "limitations": ["Surface readiness is sampled over RPC, not pixels presented; polling and RPC overhead are included.",
                            "Prefetched means an explicit previsit simulation; it does not exercise a background prefetch API.",
                            "Dropped frames are debug.frames missed-vsync intervals, not compositor presentation counts.",
                            "Cold means a newly created unvisited workspace; the app process and its New Tab spare may already be warm."]}


def visible_state(surfaces: dict, workspace: str | None) -> tuple[bool, list[str]]:
    panes = [pane for window in surfaces.get("windows", []) for pane in window.get("panes", []) if pane.get("visible")]
    violations = []
    if not panes:
        violations.append("no visible panes")
    for pane in panes:
        prefix = f"pane {pane.get('pane')}"
        if workspace is not None and pane.get("workspace") != workspace:
            violations.append(f"{prefix}: wrong workspace")
        for field in ("window_drawable", "content_installed", "content_in_window", "content_visible"):
            if pane.get(field) is not True:
                violations.append(f"{prefix}: {field} is not true")
        if not pane.get("selected_tab") or pane.get("selected_tab") != pane.get("shown_tab"):
            violations.append(f"{prefix}: selected content is not shown")
        if pane.get("blank") or pane.get("collapsed") or pane.get("foreign_pages", 0):
            violations.append(f"{prefix}: blank, collapsed, or foreign content")
        if pane.get("phase") == "loading":
            violations.append(f"{prefix}: page has not painted")
    return not violations, violations


def frame_metrics(frames: dict) -> dict:
    refresh = frames.get("refresh_ms")
    valid = isinstance(refresh, (int, float)) and refresh > 0 and (frames.get("frames") or 0) > 0
    return {"refresh_ms": refresh if valid else None, "count": frames.get("frames"),
            "overrun_ms": {key: round(max(0, frames[f"{key}_ms"] - refresh), 3)
                           if valid and isinstance(frames.get(f"{key}_ms"), (float, int)) else None
                           for key in ("p50", "p95", "p99")},
            "dropped_frames_proxy": frames.get("missed") if valid else None, "raw": frames}


def warnings(report: dict) -> list[str]:
    if report.get("status") != "measured":
        return []
    found = []
    for scenario, limit in LIMITS.items():
        rows = [row for row in report.get("runs", []) if row.get("scenario") == scenario]
        complete = [row for row in rows if row.get("first_visible_ms") is not None and row.get("settled_ms") is not None]
        if len(complete) < len(rows) or not rows:
            found.append(f"{scenario}: {len(rows) - len(complete)} timed out or no measured runs")
        if complete:
            first = statistics.median(row["first_visible_ms"] for row in complete)
            settled = statistics.median(row["settled_ms"] for row in complete)
            if first > limit:
                found.append(f"{scenario}: median first visible {first:.1f} ms > {limit:g} ms")
            if settled > SETTLED_LIMIT_MS:
                found.append(f"{scenario}: median settled {settled:.1f} ms > {SETTLED_LIMIT_MS:g} ms")
        for row in rows:
            frames = row.get("frames", {})
            drops, count = frames.get("dropped_frames_proxy"), frames.get("count")
            if drops is None or not count:
                found.append(f"{scenario} #{row['iteration']}: no usable display-frame measurement")
            if drops is not None and count and drops / count > DROPPED_RATIO_LIMIT:
                found.append(f"{scenario} #{row['iteration']}: missed-vsync intervals {drops}/{count} > {DROPPED_RATIO_LIMIT:.0%}")
            if row.get("settled_violations"):
                found.append(f"{scenario} #{row['iteration']}: settled content invariant failed")
            if scenario == "prefetched" and row.get("previsit_ready") is False:
                found.append(f"{scenario} #{row['iteration']}: explicit previsit did not settle")
    return found


def invariant_failures(report: dict) -> list[str]:
    """Return only settled, observable content-coherence failures.

    A timeout has no reliable pixels/content verdict and therefore remains an
    unknown in the warning-only report.  Once a journey reports a settled
    readiness sample, however, a non-empty final invariant violation means the
    selected workspace or its shown content was wrong after the switch.  This
    is the narrow signal safe for a blocking CI gate.
    """
    if report.get("status") != "measured":
        return []
    failures = []
    for row in report.get("runs", []):
        if row.get("settled_ms") is None or not row.get("settled_violations"):
            continue
        details = "; ".join(str(item) for item in row["settled_violations"])
        failures.append(f"{row.get('scenario', 'unknown')} #{row.get('iteration', '?')}: {details}")
    return failures


def summarize(report: dict) -> str:
    lines = ["## Workspace switch (warning-only performance; settled coherence gate)", "",
             f"Source: `{report['source_sha']}`; host: `{report['host']['name']}`; tag: `{report['tag']}`.", ""]
    if report["status"] != "measured":
        return "\n".join(lines + [f"{report['status'].capitalize()}: {report.get('reason') or 'no reason supplied'}.", ""])
    lines += ["Times are surface-readiness RPC upper bounds; prefetched is an explicit previsit simulation.", "",
              "| cache state | runs | median first visible | median settled |", "|---|---:|---:|---:|"]
    for scenario, cache in CACHE_STATES.items():
        rows = [row for row in report["runs"] if row["scenario"] == scenario]
        def median(key):
            values = [row[key] for row in rows if row.get(key) is not None]
            return f"{statistics.median(values):.1f} ms" if values else "unknown"
        lines.append(f"| {scenario} ({cache}) | {len(rows)} | {median('first_visible_ms')} | {median('settled_ms')} |")
    found = warnings(report)
    lines += ["", *[f"- Warning: {item}" for item in found], "",
              "Initial smoke limits: median first visible cold 500 ms, warm/prefetched 150 ms; settled 1000 ms; missed-vsync intervals 5%. They never fail a check.",
              "Frame overruns, raw frame stats and transient/settled invariants are in the JSON receipt. Unknown metrics stay null.", ""]
    return "\n".join(lines)


def write_report(report: dict, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    report["warnings"] = warnings(report)
    out.write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--strict-invariants", action="store_true",
                        help="fail only when a measured journey settles with content invariant violations")
    parser.add_argument("--skip-reason")
    parser.add_argument("--sha", default="unknown")
    parser.add_argument("--tag", default="frame-pacing")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args(argv)
    if args.summary:
        try:
            report = json.loads(args.summary.read_text())
            print(summarize(report))
            for warning in warnings(report):
                print(f"::warning title=Workspace switch::{warning}", file=sys.stderr)
            failures = invariant_failures(report)
            for failure in failures:
                print(f"::error title=Workspace switch content invariant::{failure}", file=sys.stderr)
            if args.strict_invariants and failures:
                return 1
        except (OSError, ValueError, KeyError, TypeError) as error:
            print(f"## Workspace switch\n\nNot measured: receipt unavailable ({error}).")
            print("::warning title=Workspace switch::No usable receipt; this is not passing performance evidence.", file=sys.stderr)
    elif args.skip_reason and args.out:
        write_report(receipt(args.sha, args.tag, {}, {}, status="skipped", reason=args.skip_reason), args.out)
    else:
        parser.error("pass --summary RECEIPT or --skip-reason REASON --out RECEIPT")
    return 0


if __name__ == "__main__":
    sys.exit(main())
