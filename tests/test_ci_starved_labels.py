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
from unittest import mock

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
        other = job(label=OTHER, status="in_progress", created=5, started=2, runner="m")
        found = starved_labels.starved([{"id": 1}, {"id": 2}], {1: [job(created=60)], 2: [other]}, now=NOW)
        self.assertEqual([entry["label"] for entry in found], [SIDE])

    def test_only_fleet_labels_are_in_scope(self) -> None:
        self.assertEqual(starved(job(label="blacksmith-6vcpu-macos-15", created=60)), [])

    def test_a_cancelled_job_that_never_got_a_runner_is_no_start(self) -> None:
        found = starved(job(created=60), job(status="completed", created=8, started=8, runner=None))
        self.assertEqual([entry["label"] for entry in found], [SIDE])

    # The jobs API can list a job before its `needs` finished, and names no `needs`
    # (queue_janitor.lost_wait_start()), so a fleet job may be waiting on a sibling.
    def test_a_job_waiting_behind_a_running_sibling_is_not_starved(self) -> None:
        build = job(label="blacksmith-4vcpu-ubuntu-2404", status="in_progress", created=40, started=39, runner="bs-1",
                    name="build")
        self.assertEqual(starved(job(created=40), build), [])

    def test_the_wait_counts_from_the_last_sibling_completion(self) -> None:
        gate = job(label="blacksmith-4vcpu-ubuntu-2404", status="completed", created=40, started=39, runner="bs-1",
                   name="build")
        gate["completed_at"] = iso(6)
        self.assertEqual(starved(job(created=40), gate), [])
        gate["completed_at"] = iso(25)
        found = starved(job(created=40), gate)
        self.assertEqual([(entry["label"], entry["oldest_queued_minutes"]) for entry in found], [(SIDE, 25)])

    def test_a_job_behind_a_queued_sibling_waits_the_longer_gated_bound(self) -> None:
        # The queued sibling may be its `needs` (queue_janitor._gated()), even on a pool serving other jobs,
        # or a dependent of the stuck fleet job: the API cannot tell. The alert waits STARVED_GATED_AFTER.
        build = job(label="blacksmith-4vcpu-ubuntu-2404", created=40, name="build")
        elsewhere = job(label="blacksmith-4vcpu-ubuntu-2404", status="in_progress", created=3, started=2,
                        runner="bs-9", name="lint")
        bound = int(starved_labels.STARVED_GATED_AFTER.total_seconds() // 60)
        self.assertGreater(bound, 40)
        self.assertEqual(starved_labels.starved([{"id": 1}, {"id": 2}], {1: [job(created=40), build], 2: [elsewhere]},
                                                now=NOW), [])
        stuck = job(created=bound + 5)
        dependent = job(label="blacksmith-4vcpu-ubuntu-2404", created=bound + 5, name="cloud tests")
        found = starved(stuck, dependent)
        self.assertEqual([(entry["label"], entry["oldest_queued_minutes"]) for entry in found], [(SIDE, bound + 5)])

    def test_a_running_sibling_gates_without_a_bound(self) -> None:
        build = job(label="blacksmith-4vcpu-ubuntu-2404", status="in_progress", created=300, started=299,
                    runner="bs-1", name="build")
        self.assertEqual(starved(job(created=300), build), [])

    def test_two_stuck_fleet_jobs_never_mask_each_other(self) -> None:
        found = starved(job(created=40), job(label=OTHER, created=40, name="other compile"))
        self.assertEqual([entry["label"] for entry in found], [SIDE, OTHER] if SIDE < OTHER else [OTHER, SIDE])

    def test_a_recent_start_in_a_completed_run_serves_the_label(self) -> None:
        # Main's lost-assignment evidence lists completed runs too; their starts are service.
        done = job(status="completed", created=8, started=5, runner="mini-3")
        jobs = {1: [job(created=60)], 2: [done]}
        self.assertEqual(starved_labels.starved([{"id": 1}], jobs, now=NOW, evidence={2: [done]}), [])
        self.assertEqual(starved_labels.unserved([{"id": 1}], jobs, now=NOW, evidence={2: [done]}), [])


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


class UnservedTests(unittest.TestCase):
    def test_a_young_replacement_queue_on_an_unserved_label_is_unserved_not_starved(self) -> None:
        jobs = {1: [job(created=3)]}
        self.assertEqual(starved_labels.starved([{"id": 1}], jobs, now=NOW), [])
        self.assertEqual(starved_labels.unserved([{"id": 1}], jobs, now=NOW), [SIDE])

    def test_a_served_label_is_not_unserved(self) -> None:
        jobs = {1: [job(created=3), job(status="in_progress", created=30, started=20, runner="mini-3")]}
        self.assertEqual(starved_labels.unserved([{"id": 1}], jobs, now=NOW), [])


def search_item(label: str, number: int, updated: float = 30) -> dict:
    return {"number": number, "title": starved_labels.issue_title(label), "state": "open", "updated_at": iso(updated)}


class FakeGitHub:
    repo = "manaflow-ai/cmux"

    def __init__(self, items: list) -> None:
        self.items = items
        self.calls: list = []

    def request(self, method: str, path: str, body=None):
        self.calls.append((method, path, body))
        if method == "GET":
            return {"items": self.items}
        if method == "POST" and path.endswith("/issues"):
            return {"number": 99}
        return {}

    def closed(self) -> list:
        return [int(path.rsplit("/", 1)[1]) for method, path, body in self.calls
                if method == "PATCH" and (body or {}).get("state") == "closed"]

    def opened(self) -> int:
        return sum(1 for method, path, _ in self.calls if method == "POST" and path.endswith("/issues"))


class SyncIssuesTests(unittest.TestCase):
    ENTRY = {"label": SIDE, "oldest_queued_minutes": 130, "queued": 2, "job_url": "u", "job": "j"}
    GENERATED = iso(0)

    def test_duplicate_titles_close_all_but_the_oldest(self) -> None:
        github = FakeGitHub([search_item(SIDE, 12), search_item(SIDE, 7), search_item(SIDE, 15)])
        starved_labels.sync_issues(github, [self.ENTRY], self.GENERATED)
        self.assertEqual(sorted(github.closed()), [12, 15])
        self.assertEqual(github.opened(), 0)
        updated = [path for method, path, body in github.calls if method == "PATCH" and "state" not in (body or {})]
        self.assertEqual(updated, ["/repos/manaflow-ai/cmux/issues/7"])

    def test_an_unserved_young_queue_keeps_the_alert_open(self) -> None:
        github = FakeGitHub([search_item(SIDE, 7)])
        starved_labels.sync_issues(github, [], self.GENERATED, unserved=[SIDE])
        self.assertEqual(github.closed(), [])
        self.assertFalse(any(method == "POST" and "comments" in path for method, path, _ in github.calls))

    def test_recovery_closes_once_with_one_comment(self) -> None:
        github = FakeGitHub([search_item(SIDE, 7)])
        starved_labels.sync_issues(github, [], self.GENERATED, unserved=[])
        self.assertEqual(github.closed(), [7])
        self.assertEqual(sum(1 for method, path, _ in github.calls if "comments" in path), 1)

    def test_an_older_snapshot_never_closes_an_issue_updated_after_it(self) -> None:
        github = FakeGitHub([search_item(SIDE, 7, updated=1)])
        starved_labels.sync_issues(github, [], iso(5), unserved=[])
        self.assertEqual(github.closed(), [])


    def test_a_duplicate_updated_after_the_snapshot_keeps_the_label_tracked(self) -> None:
        # Keeper #7 updated before the snapshot, duplicate #12 after it: this older snapshot closes neither.
        github = FakeGitHub([search_item(SIDE, 7, updated=10), search_item(SIDE, 12, updated=1)])
        starved_labels.sync_issues(github, [], iso(5), unserved=[])
        self.assertEqual(github.closed(), [])

    def test_stale_duplicates_still_close_beside_a_fenced_one(self) -> None:
        github = FakeGitHub([search_item(SIDE, 7, updated=10), search_item(SIDE, 12, updated=1),
                             search_item(SIDE, 15, updated=20)])
        starved_labels.sync_issues(github, [], iso(5), unserved=[])
        self.assertEqual(github.closed(), [15])


class IncompleteInventoryTests(unittest.TestCase):
    def test_an_incomplete_inventory_closes_nothing_as_recovered(self) -> None:
        plan = starved_labels.plan_issues([], [issue(SIDE, 7)], incomplete=True)
        self.assertEqual((plan.open, plan.update, plan.close), ([], [], []))

    def test_an_incomplete_inventory_still_opens_and_updates(self) -> None:
        entry = {"label": SIDE, "oldest_queued_minutes": 30, "queued": 1, "job_url": "u", "job": "j"}
        plan = starved_labels.plan_issues([entry, dict(entry, label=OTHER)], [issue(OTHER, 8)], incomplete=True)
        self.assertEqual([entry["label"] for entry in plan.open], [SIDE])
        self.assertEqual([found["number"] for found, _ in plan.update], [8])


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

    def test_the_snapshot_carries_unserved_labels_into_the_sync(self) -> None:
        github = FakeGitHub([search_item(SIDE, 7)])
        with mock.patch.object(starved_labels, "client", return_value=github):
            code, _, _ = self.run_main({"generated_at": iso(0), "starved": [], "unserved": [SIDE]},
                                       env={"GH_REPO": "manaflow-ai/cmux", "GH_TOKEN": "t"})
        self.assertEqual(code, 0)
        self.assertEqual(github.closed(), [])

    def test_an_incomplete_snapshot_closes_nothing(self) -> None:
        github = FakeGitHub([search_item(SIDE, 7)])
        with mock.patch.object(starved_labels, "client", return_value=github):
            code, out, _ = self.run_main({"generated_at": iso(0), "starved": [], "unserved": [],
                                          "starved_incomplete": True},
                                         env={"GH_REPO": "manaflow-ai/cmux", "GH_TOKEN": "t"})
        self.assertEqual(code, 0)
        self.assertEqual(github.closed(), [])
        self.assertIn("::warning", out)

    def test_a_snapshot_without_the_starved_key_closes_nothing(self) -> None:
        code, out, _ = self.run_main({"pools": {}}, env={"GH_REPO": "manaflow-ai/cmux"})
        self.assertEqual(code, 0)
        self.assertNotIn("::error", out)


class WorkflowTests(unittest.TestCase):
    def test_sweeps_are_serialized_and_never_cancelled_mid_reconcile(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        concurrency = workflow["concurrency"]
        self.assertIs(concurrency["cancel-in-progress"], False)
        # every run that sweeps shares one group; only a run whose job starts no sweep gets its own
        self.assertTrue(concurrency["group"].endswith("|| 'ci-queue-janitor' }}"), concurrency["group"])

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
