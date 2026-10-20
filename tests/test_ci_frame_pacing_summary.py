#!/usr/bin/env python3
"""Behavioral tests for the agent pane frame pacing summary (scripts/ci/frame-pacing/summarize.py).

The nightly bench reports its numbers and flags regressions in the run summary
only: a slow night must show up there and must never fail the run.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "frame-pacing" / "summarize.py"


def write_run(out: Path, display: str, flings: dict[str, list[tuple[int, float, float, int]]]) -> None:
    out.mkdir(parents=True, exist_ok=True)
    (out / "display.txt").write_text(display + "\n")
    for mode, runs in flings.items():
        for n, (frames, p50, p95, dropped) in enumerate(runs, start=1):
            fling = {"frames": frames, "p50_ms": p50, "p95_ms": p95, "dropped_frames": dropped, "nominal_ms": 8}
            (out / f"{mode}-{n}.json").write_text(json.dumps({"fling": fling, "perf": {}}))


def run(
    out: Path,
    receipt: Path | None = None,
    env: dict[str, str] | None = None,
    skip_reason: str | None = None,
) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, str(SCRIPT), str(out)]
    if receipt is not None:
        command += ["--receipt", str(receipt)]
    if skip_reason is not None:
        command += ["--skip-reason", skip_reason]
    process_env = None if env is None else {**os.environ, **env}
    return subprocess.run(command, capture_output=True, text=True, check=False, env=process_env)


def test_a_healthy_night_reports_both_modes_without_warnings() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, "ready 17 8.33 main=17", {
            "0": [(181, 17, 18, 0), (181, 17, 18, 0), (182, 17, 17, 0)],
            "1": [(360, 8, 9, 1), (361, 8, 9, 2), (361, 8, 9, 1)],
        })
        result = run(out)
        assert result.returncode == 0, result.stderr
        assert "| capped (60 Hz) | 3 | 181 | 17 ms | 18 ms | 0/544 | ok |" in result.stdout, result.stdout
        assert "| full rate (120 Hz) | 3 | 361 | 8 ms | 9 ms | 4/1082 | ok |" in result.stdout, result.stdout
        assert "ticks every 8.33 ms" in result.stdout, result.stdout
        assert "::warning" not in result.stderr, result.stderr


def test_a_regression_is_flagged_and_warned_but_exits_zero() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, "ready 17 8.33 main=17", {
            # Capped drops a tenth of its frames; full rate fell back to 60 Hz.
            "0": [(181, 17, 30, 20), (181, 17, 30, 20)],
            "1": [(181, 17, 18, 0), (181, 17, 18, 0)],
        })
        result = run(out)
        assert result.returncode == 0, result.stderr
        assert "regression: dropped 40/362 > 5%" in result.stdout, result.stdout
        assert "regression: p50 17 ms > 9 ms" in result.stdout, result.stdout
        assert result.stderr.count("::warning title=Agent pane frame pacing::") == 2, result.stderr


def test_no_virtual_display_skips_the_table() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, "error: CGVirtualDisplay unavailable", {})
        result = run(out)
        assert result.returncode == 0, result.stderr
        assert "Skipped: the virtual display did not come up (error: CGVirtualDisplay unavailable)." in result.stdout
        assert "| mode |" not in result.stdout, result.stdout


def test_a_mode_that_never_drew_says_why_instead_of_flagging() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        # A locked console: the flings ran but the page drew nothing.
        write_run(out, "ready 17 8.33 main=17", {"0": [(0, 0, 0, 0)], "1": []})
        (out / "1-error.txt").write_text("mode 1: no socket at /tmp/cmux-debug-frame-pacing.sock\n")
        result = run(out)
        assert result.returncode == 0, result.stderr
        assert "| capped (60 Hz) | 0 | | | | | not measured: no fling drew a frame |" in result.stdout, result.stdout
        assert "not measured: mode 1: no socket at /tmp/cmux-debug-frame-pacing.sock" in result.stdout, result.stdout
        assert "::warning" not in result.stderr, result.stderr


def test_a_fling_whose_rpc_replied_with_an_error_is_left_out() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        write_run(out, "ready 17 8.33 main=17", {
            "0": [(181, 17, 18, 0), (181, 17, 18, 0)],
            "1": [(361, 8, 9, 1), (361, 8, 9, 1)],
        })
        # bench.sh splices the CLI's reply in as-is, so a failed rpc leaves text, not JSON.
        (out / "0-3.json").write_text('{"fling":Error: socket closed,"perf":{}}\n')
        result = run(out)
        assert result.returncode == 0, result.stderr
        assert "| capped (60 Hz) | 2 | 181 | 17 ms | 18 ms | 0/362 | ok |" in result.stdout, result.stdout
        assert "::warning" not in result.stderr, result.stderr


def test_receipt_captures_exact_source_and_reviewable_measurements() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        receipt = out / "summary.json"
        write_run(out, "ready 17 8.33 main=17", {
            "0": [(181, 17, 18, 0)],
            "1": [(360, 8, 9, 1)],
        })
        result = run(out, receipt, {"CMUX_PERF_SOURCE_SHA": "source-sha", "CMUX_PERF_WORKFLOW_SHA": "workflow-sha"})
        assert result.returncode == 0, result.stderr
        data = json.loads(receipt.read_text())
        assert data["schema"] == "cmux.next.frame-pacing.v1"
        assert data["source_sha"] == "source-sha"
        assert data["workflow_sha"] == "workflow-sha"
        assert data["status"] == "ok"
        assert data["thresholds_enforced"] is False
        assert data["modes"]["1"]["p50_ms_median"] == 8.0
        assert data["modes"]["1"]["dropped_frames"] == 1


def test_receipt_preserves_skip_reason() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        receipt = out / "summary.json"
        write_run(out, "error: CGVirtualDisplay unavailable", {})
        result = run(out, receipt)
        assert result.returncode == 0, result.stderr
        data = json.loads(receipt.read_text())
        assert data["status"] == "skipped"
        assert data["reason"] == "error: CGVirtualDisplay unavailable"


def test_receipt_marks_unmeasured_mode_as_partial() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp)
        receipt = out / "summary.json"
        write_run(out, "ready 17 8.33 main=17", {"0": [(181, 17, 18, 0)]})
        result = run(out, receipt)
        assert result.returncode == 0, result.stderr
        data = json.loads(receipt.read_text())
        assert data["status"] == "partial"
        assert data["unmeasured_modes"] == ["1"]
        assert data["modes"]["1"]["status"] == "not_measured"


def test_receipt_can_record_a_prebench_skip() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp) / "out"
        receipt = out / "summary.json"
        result = run(out, receipt, skip_reason="no owned Mac was available")
        assert result.returncode == 0, result.stderr
        data = json.loads(receipt.read_text())
        assert data["status"] == "skipped"
        assert data["reason"] == "no owned Mac was available"


def main() -> int:
    test_a_healthy_night_reports_both_modes_without_warnings()
    test_a_regression_is_flagged_and_warned_but_exits_zero()
    test_no_virtual_display_skips_the_table()
    test_a_mode_that_never_drew_says_why_instead_of_flagging()
    test_a_fling_whose_rpc_replied_with_an_error_is_left_out()
    test_receipt_captures_exact_source_and_reviewable_measurements()
    test_receipt_preserves_skip_reason()
    test_receipt_marks_unmeasured_mode_as_partial()
    test_receipt_can_record_a_prebench_skip()
    print("PASS: frame pacing summary reports numbers and flags regressions without failing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
