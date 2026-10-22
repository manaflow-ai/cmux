#!/usr/bin/env python3
"""Tests for scripts/ci/starved_labels.py over fixture job JSON (no network)."""

from __future__ import annotations

import datetime as dt
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/starved_labels.py"
WORKFLOW = ROOT / ".github/workflows/ci-queue-janitor.yml"
SPEC = importlib.util.spec_from_file_location("starved_labels", SCRIPT)
starved_labels = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules["starved_labels"] = starved_labels
SPEC.loader.exec_module(starved_labels)

NOW = dt.datetime(2026, 10, 22, 6, 0, tzinfo=dt.timezone.utc)
SIDE = "glaeda-side-light-xcode-26.6"
OTHER = "glaeda-xl-xcode-26.6"
_ids = iter(range(5000, 100000))


def iso(minutes_ago: float) -> str:
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def job(*, label=SIDE, status="queued", created=30, started=None, runner=None, name="cmux-next app compile (build fleet)"):
    job_id = next(_ids)
    return {
        "id": job_id, "name": name, "status": status, "labels": [label],
        "created_at": iso(created), "started_at": iso(created if started is None else started),
        "runner_name": runner, "html_url": f"https://github.com/manaflow-ai/cmux/actions/runs/1/job/{job_id}",
    }


def starved(*jobs):
    return starved_labels.starved([{"id": 1}], {1: list(jobs)}, now=NOW)


class StarvedDetectionTests(unittest.TestCase):
    def test_a_label_queued_past_ten_minutes_with_no_start_is_starved(self) -> None:
        queued = job(created=130)
        found = starved(queued, job(created=20))
        self.assertEqual([entry["label"] for entry in found], [SIDE])
        self.assertEqual(found[0]["oldest_queued_minutes"], 130)
        self.assertEqual(found[0]["queued"], 2)
        self.assertEqual(found[0]["job_url"], queued["html_url"])

    def test_a_recent_start_on_the_label_means_it_is_served(self) -> None:
        self.assertEqual(starved(job(created=60), job(status="completed", created=20, started=4, runner="mini-3")), [])
        self.assertEqual(starved(job(created=60), job(status="in_progress", created=90, started=80, runner="mini-3")),
                         [])

    def test_an_old_start_does_not_count(self) -> None:
        found = starved(job(created=60), job(status="completed", created=50, started=40, runner="mini-3"))
        self.assertEqual([entry["label"] for entry in found], [SIDE])

    def test_a_queue_younger_than_ten_minutes_is_not_starved(self) -> None:
        self.assertEqual(starved(job(created=9)), [])

    def test_a_start_on_another_label_does_not_serve_this_one(self) -> None:
        found = starved(job(created=60), job(label=OTHER, status="in_progress", created=5, started=2, runner="m"))
        self.assertEqual([entry["label"] for entry in found], [SIDE])

    def test_only_fleet_labels_are_in_scope(self) -> None:
        self.assertEqual(starved(job(label="blacksmith-6vcpu-macos-15", created=60)), [])

    def test_a_cancelled_job_that_never_got_a_runner_is_no_start(self) -> None:
        found = starved(job(created=60), job(status="completed", created=8, started=8, runner=None))
        self.assertEqual([entry["label"] for entry in found], [SIDE])


def issue(label: str, number: int) -> dict:
    return {"number": number, "title": starved_labels.issue_title(label), "state": "open"}


class IssuePlanTests(unittest.TestCase):
    ENTRY = {"label": SIDE, "oldest_queued_minutes": 130, "queued": 2, "job_url": "u", "job": "j"}

    def test_a_new_starved_label_opens_one_issue(self) -> None:
        plan = starved_labels.plan_issues([self.ENTRY], [])
        self.assertEqual([entry["label"] for entry in plan.open], [SIDE])
        self.assertEqual((plan.update, plan.close), ([], []))

    def test_a_still_starved_label_updates_its_issue(self) -> None:
        plan = starved_labels.plan_issues([self.ENTRY], [issue(SIDE, 7)])
        self.assertEqual(plan.open, [])
        self.assertEqual([(found["number"], entry["label"]) for found, entry in plan.update], [(7, SIDE)])

    def test_recovery_closes_the_issue(self) -> None:
        plan = starved_labels.plan_issues([], [issue(SIDE, 7), {"number": 8, "title": "unrelated"}])
        self.assertEqual([found["number"] for found in plan.close], [7])
        self.assertEqual((plan.open, plan.update), ([], []))


class MainTests(unittest.TestCase):
    def run_main(self, snapshot: dict, env: dict) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "load.json"
            summary = Path(tmp) / "summary.md"
            path.write_text(json.dumps(snapshot), encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                code = starved_labels.main(["--snapshot", str(path), "--summary", str(summary)], env=env)
            return code, out.getvalue(), summary.read_text(encoding="utf-8") if summary.exists() else ""

    def test_starved_without_an_issue_token_fails_loudly(self) -> None:
        entry = {"label": SIDE, "oldest_queued_minutes": 130, "queued": 1,
                 "job_url": "https://example.test/job/1", "job": "cmux-next app compile (build fleet)"}
        code, out, summary = self.run_main({"starved": [entry]}, env={"GH_REPO": "manaflow-ai/cmux"})
        self.assertEqual(code, 1)
        self.assertIn(f"::error title=Runner label starved::{SIDE}", out)
        self.assertIn(SIDE, summary)
        self.assertIn("https://example.test/job/1", summary)
        self.assertIn("2h10m", summary)

    def test_a_snapshot_without_the_starved_key_closes_nothing(self) -> None:
        code, out, _ = self.run_main({"pools": {}}, env={"GH_REPO": "manaflow-ai/cmux"})
        self.assertEqual(code, 0)
        self.assertNotIn("::error", out)


class WorkflowTests(unittest.TestCase):
    def test_the_alert_step_uses_the_bot_token_and_adds_no_permission(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        sweep = workflow["jobs"]["sweep"]
        self.assertNotIn("issues", sweep["permissions"])
        step = next(step for step in sweep["steps"] if "starved_labels.py" in str(step.get("run")))
        self.assertEqual(step["env"]["GH_TOKEN"], "${{ steps.cmux-bot-token.outputs.token }}")
        self.assertIn("macos-pool-load.json", step["env"]["POOL_LOAD_OUT"])
        self.assertIn("!cancelled()", step["if"])


if __name__ == "__main__":
    unittest.main()
