#!/usr/bin/env python3
"""A best-effort evidence step must still report that it failed.

Diagnostics and metrics steps run with `continue-on-error: true` because
collecting evidence should never fail a job. Without an `id` whose outcome
something reads, a failure there is invisible: the artifact simply does not
exist and nothing says why. The app-host suite is the largest consumer of
macOS capacity and the least reliable, so losing its diagnostics silently is
the worst case, not a hypothetical one. See #13812.
"""

from pathlib import Path
import os
import subprocess
from tempfile import TemporaryDirectory

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci-macos.yml"
REPORT_STEP = "Report evidence collection outcomes"

# Steps whose failure destroys evidence rather than degrading performance. A
# cache or transport lookup is deliberately not here: when one fails the job
# recompiles, which is slower and still correct.
EVIDENCE_STEPS = {
    "macos-compile-admission": (
        "Upload compile admission metrics",
        "Upload Xcode build metrics receipt",
        # The changed suites compile admission runs itself.
        "Collect app-host failure diagnostics",
        "Upload app-host failure diagnostics",
    ),
    "app-host-unit-tests": (
        "Collect RemoteTmuxMirror crash diagnostics",
        "Upload RemoteTmuxMirror crash diagnostics",
        "Collect app-host failure diagnostics",
        "Upload app-host failure diagnostics",
    ),
}


def jobs() -> dict:
    document = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    assert isinstance(document, dict), "ci-macos.yml did not parse to a mapping"
    return document["jobs"]


def test_every_evidence_step_has_an_outcome_somebody_reads() -> None:
    all_jobs = jobs()

    for job_id, step_names in EVIDENCE_STEPS.items():
        steps = all_jobs[job_id]["steps"]
        by_name = {step.get("name"): step for step in steps if isinstance(step, dict)}

        report = by_name.get(REPORT_STEP)
        assert report is not None, f"{job_id} has no {REPORT_STEP!r} step"
        outcomes = report.get("env", {}).get("EVIDENCE_OUTCOMES", "")
        assert report.get("if") == "${{ always() }}", (
            f"{job_id}/{REPORT_STEP} must run on every path, or it reports "
            "nothing on exactly the runs that lost evidence"
        )

        for name in step_names:
            step = by_name.get(name)
            assert step is not None, f"{job_id} has no step named {name!r}"
            assert step.get("continue-on-error") is True, (
                f"{job_id}/{name} no longer opts out of failing the job; "
                "either drop it from EVIDENCE_STEPS or restore the opt-out"
            )
            step_id = step.get("id")
            assert step_id, (
                f"{job_id}/{name} is continue-on-error with no id, so a "
                "failure there leaves no signal anywhere"
            )
            assert f"steps.{step_id}.outcome" in outcomes, (
                f"{job_id}/{name} has id {step_id!r} but {REPORT_STEP} does "
                "not read its outcome"
            )


def test_the_report_step_never_fails_the_job() -> None:
    """Reporting lost evidence must not itself become a way to lose a run."""
    for job_id in EVIDENCE_STEPS:
        report = next(
            step
            for step in jobs()[job_id]["steps"]
            if isinstance(step, dict) and step.get("name") == REPORT_STEP
        )
        run = report.get("run", "")
        for outcome in ("failure", "skipped", "", "success", "cancelled"):
            with TemporaryDirectory() as directory:
                summary = Path(directory) / "summary.md"
                result = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", run],
                    env={
                        **os.environ,
                        "EVIDENCE_OUTCOMES": f"test-evidence={outcome}",
                        "GITHUB_STEP_SUMMARY": str(summary),
                    },
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                assert result.returncode == 0, (job_id, outcome, result.stderr)
                assert not result.stderr, (job_id, outcome, result.stderr)
                if outcome == "failure":
                    assert "::warning title=Evidence not captured::test-evidence failed" in result.stdout
                else:
                    assert not result.stdout, (job_id, outcome, result.stdout)
                if outcome in ("skipped", ""):
                    assert not summary.exists(), (job_id, outcome)
                else:
                    assert f"- test-evidence: `{outcome}`" in summary.read_text()


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: evidence steps report their own failures")
