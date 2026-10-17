#!/usr/bin/env python3
"""Summarize the agent pane fling bench (bench.sh) as markdown for the run summary.

    summarize.py OUT_DIR [--receipt PATH]

Reads OUT_DIR/display.txt and OUT_DIR/<mode>-<n>.json (mode 0 is the capped
render rate, 1 is full rate) and prints one table row per mode: flings, frames
per fling, the median of the flings' p50 and p95 frame intervals, and dropped
frames over all flings. A mode past its threshold is flagged in the table and
reported on stderr as a ::warning:: annotation. The script never exits non-zero
for a regression: this bench gates nothing.
"""

from __future__ import annotations

import json
import os
import statistics
import sys
from datetime import datetime, timezone
from argparse import ArgumentParser
from dataclasses import dataclass
from pathlib import Path

MODES = {"0": "capped (60 Hz)", "1": "full rate (120 Hz)"}
# Frame interval medians a healthy run stays within on a 120 Hz display: full
# rate draws every 8.3 ms frame, capped every other one (16.7 ms).
P50_LIMIT_MS = {"0": 18.0, "1": 9.0}
# More dropped frames than this share of all frames is a regression in either mode.
DROPPED_LIMIT = 0.05


@dataclass(frozen=True)
class ModeResult:
    mode: str
    flings: int
    frames: float
    p50_ms: float
    p95_ms: float
    dropped: int
    total_frames: int

    def regressions(self) -> list[str]:
        found = []
        if self.p50_ms > P50_LIMIT_MS[self.mode]:
            found.append(f"p50 {self.p50_ms:g} ms > {P50_LIMIT_MS[self.mode]:g} ms")
        if self.total_frames and self.dropped / self.total_frames > DROPPED_LIMIT:
            found.append(f"dropped {self.dropped}/{self.total_frames} > {DROPPED_LIMIT:.0%}")
        return found

    def receipt(self) -> dict[str, object]:
        """Return stable, reviewable measurements for CI artifacts."""
        problems = self.regressions()
        return {
            "status": "regression" if problems else "ok",
            "flings": self.flings,
            "frames_per_fling_median": self.frames,
            "p50_ms_median": self.p50_ms,
            "p95_ms_median": self.p95_ms,
            "dropped_frames": self.dropped,
            "total_frames": self.total_frames,
            "regressions": problems,
            "thresholds": {
                "p50_ms": P50_LIMIT_MS[self.mode],
                "dropped_fraction": DROPPED_LIMIT,
            },
        }


def load_mode(out: Path, mode: str) -> ModeResult | None:
    flings = []
    for path in sorted(out.glob(f"{mode}-*.json")):
        try:
            fling = json.loads(path.read_text())["fling"]
            flings.append((int(fling["frames"]), float(fling["p50_ms"]), float(fling["p95_ms"]), int(fling["dropped_frames"])))
        except (ValueError, KeyError, TypeError):
            continue
    # A fling the page never drew (a locked console) has no frames to judge.
    flings = [fling for fling in flings if fling[0] > 0]
    if not flings:
        return None
    return ModeResult(
        mode=mode,
        flings=len(flings),
        frames=statistics.median(fling[0] for fling in flings),
        p50_ms=statistics.median(fling[1] for fling in flings),
        p95_ms=statistics.median(fling[2] for fling in flings),
        dropped=sum(fling[3] for fling in flings),
        total_frames=sum(fling[0] for fling in flings),
    )


def summarize(out: Path) -> tuple[str, list[str]]:
    """The markdown summary and the regression warnings."""
    display = (out / "display.txt").read_text().strip() if (out / "display.txt").exists() else ""
    lines = ["## Agent pane frame pacing (120 Hz virtual display)", ""]
    if not display.startswith("ready"):
        lines.append(f"Skipped: the virtual display did not come up ({display or 'no report'}).")
        return "\n".join(lines) + "\n", []
    fields = display.split()
    lines.append(f"Virtual display {fields[1]} ticks every {fields[2]} ms (CVDisplayLink p50).")
    lines += ["", "| mode | flings | frames/fling | p50 | p95 | dropped | |", "|---|---|---|---|---|---|---|"]
    warnings = []
    for mode, name in MODES.items():
        result = load_mode(out, mode)
        if result is None:
            error = (out / f"{mode}-error.txt")
            reason = error.read_text().strip() if error.exists() else "no fling drew a frame"
            lines.append(f"| {name} | 0 | | | | | not measured: {reason} |")
            continue
        found = result.regressions()
        warnings += [f"{name}: {item}" for item in found]
        flag = "regression: " + "; ".join(found) if found else "ok"
        lines.append(
            f"| {name} | {result.flings} | {result.frames:g} | {result.p50_ms:g} ms | {result.p95_ms:g} ms "
            f"| {result.dropped}/{result.total_frames} | {flag} |"
        )
    lines += ["", f"Thresholds: p50 above {P50_LIMIT_MS['1']:g} ms at full rate or {P50_LIMIT_MS['0']:g} ms capped, "
              f"or more than {DROPPED_LIMIT:.0%} of frames dropped. They are reported, never enforced."]
    return "\n".join(lines) + "\n", warnings


def write_receipt(out: Path, path: Path, skip_reason: str | None = None) -> None:
    """Persist the same measurements shown in the run summary.

    The frame-pacing job is intentionally warning-only today. Keeping a
    machine-readable receipt alongside the raw fling files makes each run
    reviewable and gives a later ratchet a stable input without changing the
    job's existing failure policy.
    """
    display = (out / "display.txt").read_text().strip() if (out / "display.txt").exists() else ""
    payload: dict[str, object] = {
        "schema": "cmux.next.frame-pacing.v1",
        "recorded_at": datetime.now(timezone.utc).isoformat(),
        "source_sha": os.environ.get("CMUX_PERF_SOURCE_SHA") or os.environ.get("GITHUB_SHA"),
        "workflow_sha": os.environ.get("CMUX_PERF_WORKFLOW_SHA") or os.environ.get("GITHUB_WORKFLOW_SHA"),
        "display": display,
        "thresholds_enforced": False,
        "modes": {},
    }
    if skip_reason:
        payload["status"] = "skipped"
        payload["reason"] = skip_reason
    elif not display.startswith("ready"):
        payload["status"] = "skipped"
        payload["reason"] = display or "no display report"
    else:
        payload["status"] = "ok"
        unmeasured_modes = []
        for mode, name in MODES.items():
            result = load_mode(out, mode)
            if result is None:
                error = out / f"{mode}-error.txt"
                payload["modes"][mode] = {
                    "name": name,
                    "status": "not_measured",
                    "reason": error.read_text().strip() if error.exists() else "no fling drew a frame",
                }
                unmeasured_modes.append(mode)
                continue
            data = result.receipt()
            data["name"] = name
            payload["modes"][mode] = data
            if data["status"] == "regression":
                payload["status"] = "regression"
        if unmeasured_modes and payload["status"] == "ok":
            payload["status"] = "partial"
        if unmeasured_modes:
            payload["unmeasured_modes"] = unmeasured_modes
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def main(argv: list[str]) -> int:
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("out", type=Path)
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--skip-reason")
    args = parser.parse_args(argv[1:])
    markdown, warnings = summarize(args.out)
    sys.stdout.write(markdown)
    for warning in warnings:
        print(f"::warning title=Agent pane frame pacing::{warning}", file=sys.stderr)
    if args.receipt:
        write_receipt(args.out, args.receipt, args.skip_reason)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
