#!/usr/bin/env python3
"""Regression coverage for the nightly owned-Mac route and its hosted fallback."""

from __future__ import annotations

import argparse
import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("nightly_mini_route", ROOT / "scripts/ci/nightly_mini_route.py")
route = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(route)

SHA = "a" * 40
REQUEST = "123-1"


class OnceWaiter:
    """Probes once; an incomplete probe means the deadline passed."""

    cancel_signal = None

    def until(self, _deadline, probe, **_kwargs):
        complete, value = probe()
        return value if complete else None


class FakeGitHub:
    def __init__(self, job=None, artifacts=None, run=True):
        self.job = job
        self.artifacts = artifacts or []
        self.run = run
        self.dispatched = []
        self.cancelled = []

    def dispatch_nightly(self, ref, fields):
        self.dispatched.append((ref, fields))

    def api(self, path, *, method="GET"):
        if path.startswith("actions/workflows/"):
            runs = [{"id": 77, "display_title": f"nightly-mini-build-{REQUEST}", "head_branch": "main"}] if self.run else []
            return {"workflow_runs": runs}
        if path.endswith("/cancel"):
            self.cancelled.append(path)
            return {}
        if path.startswith("actions/runs/77/jobs"):
            return {"jobs": [self.job] if self.job else []}
        if path.startswith("actions/runs/77/artifacts"):
            return {"artifacts": self.artifacts}
        raise AssertionError(path)


def job(**values):
    return {"name": route.JOB_NAME, "created_at": "2026-09-24T08:00:00Z", **values}


def outputs(path: Path) -> dict[str, str]:
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


class NightlyMiniRouteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.output = Path(self.tmp.name) / "out"
        self.output.touch()

    def tearDown(self):
        self.tmp.cleanup()

    def args(self):
        return argparse.Namespace(
            github_output=self.output, run_id="123", run_attempt="1", ref="main",
            source_sha=SHA, icon_name="AppIcon-Nightly", queue_seconds=300, execution_seconds=2700,
        )

    def run_main(self, *extra):
        argv = [
            "--repository", "manaflow-ai/cmux", "--ref", "main", "--source-sha", SHA,
            "--icon-name", "AppIcon-Nightly", "--run-id", "123", "--run-attempt", "1",
            "--github-output", str(self.output), *extra,
        ]
        self.assertEqual(route.main(argv), 0)
        return outputs(self.output)

    def test_publishing_runs_need_the_all_selector(self):
        self.assertEqual(route.eligible("", False, True), (False, "not_selected"))
        self.assertEqual(route.eligible("build-only", False, False), (False, "not_selected"))
        self.assertEqual(route.eligible("all", False, False), (True, "eligible"))

    def test_build_only_runs_may_be_forced_without_the_variable(self):
        self.assertEqual(route.eligible("", True, True), (True, "eligible"))
        self.assertEqual(route.eligible("build-only", True, False), (True, "eligible"))
        self.assertEqual(route.eligible("", True, False), (False, "not_selected"))

    def test_unselected_run_never_dispatches(self):
        values = self.run_main("--build-only", "false", "--selector", "build-only")
        self.assertEqual(values["use_mini"], "false")
        self.assertEqual(values["fallback_reason"], "not_selected")

    def test_invalid_budget_falls_back_before_dispatch(self):
        values = self.run_main("--build-only", "true", "--forced", "true", "--queue-seconds", "0")
        self.assertEqual(values["fallback_reason"], "invalid_budget")

    def test_no_free_mini_cancels_the_request_and_falls_back(self):
        api = FakeGitHub(job=None)
        route.route(self.args(), api, OnceWaiter())
        values = outputs(self.output)
        self.assertEqual(values["use_mini"], "false")
        self.assertEqual(values["fallback_reason"], "queue_timeout")
        self.assertEqual(api.cancelled, ["actions/runs/77/cancel"])
        self.assertEqual(api.dispatched[0][1]["source_sha"], SHA)

    def test_queued_but_unassigned_job_times_out(self):
        api = FakeGitHub(job=job(status="queued"))
        route.route(self.args(), api, OnceWaiter())
        self.assertEqual(outputs(self.output)["fallback_reason"], "queue_timeout")
        self.assertEqual(api.cancelled, ["actions/runs/77/cancel"])

    def test_failed_producer_falls_back(self):
        api = FakeGitHub(job=job(status="completed", conclusion="failure", started_at="2026-09-24T08:01:00Z"))
        route.route(self.args(), api, OnceWaiter())
        self.assertEqual(outputs(self.output)["fallback_reason"], "producer_failure")

    def test_overrun_cancels_and_falls_back(self):
        api = FakeGitHub(job=job(status="in_progress", started_at="2026-09-24T08:01:00Z"))
        route.route(self.args(), api, OnceWaiter())
        values = outputs(self.output)
        self.assertEqual(values["fallback_reason"], "execution_budget_exceeded")
        self.assertEqual(values["queue_to_start_seconds"], "60.0")
        self.assertEqual(api.cancelled, ["actions/runs/77/cancel"])

    def test_missing_artifact_falls_back(self):
        api = FakeGitHub(job=job(status="completed", conclusion="success", started_at="2026-09-24T08:01:00Z", completed_at="2026-09-24T08:11:00Z"))
        route.route(self.args(), api, OnceWaiter())
        self.assertEqual(outputs(self.output)["fallback_reason"], "producer_artifact_missing")

    def test_success_reports_the_exact_artifact(self):
        api = FakeGitHub(
            job=job(status="completed", conclusion="success", started_at="2026-09-24T08:01:00Z", completed_at="2026-09-24T08:11:00Z"),
            artifacts=[
                {"id": 5, "name": "nightly-mini-build-999-1", "expired": False},
                {"id": 9, "name": f"nightly-mini-build-{REQUEST}", "expired": False},
            ],
        )
        route.route(self.args(), api, OnceWaiter())
        values = outputs(self.output)
        self.assertEqual(values["use_mini"], "true")
        self.assertEqual(values["artifact_id"], "9")
        self.assertEqual(values["producer_seconds"], "600.0")
        self.assertEqual(api.cancelled, [])

    def test_unobservable_dispatch_falls_back(self):
        api = FakeGitHub(run=False)
        route.route(self.args(), api, OnceWaiter())
        self.assertEqual(outputs(self.output)["fallback_reason"], "producer_not_observable")


if __name__ == "__main__":
    unittest.main()
