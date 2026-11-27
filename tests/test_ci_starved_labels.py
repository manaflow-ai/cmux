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
        self.assertEqual(starved(job(label="blacksmith-16vcpu-ubuntu-2404", created=60)), [])

    def test_the_owned_linux_label_is_in_scope(self) -> None:
        # cmux run 43807536777 (PR #44167): `web / react-doctor` sat queued on cmux-fleet-linux-x64 from
        # 05:05:41Z on 2026-11-16 for 13 h with no alert. That pool had booted no runner since
        # 2026-11-01 (its cloud sign-in grant was missing), and only glaeda-* labels were judged.
        queued = job(label="cmux-fleet-linux-x64", created=780, name="web / react-doctor")
        found = starved(queued)
        self.assertEqual([entry["label"] for entry in found], ["cmux-fleet-linux-x64"])
        self.assertEqual(found[0]["job_url"], queued["html_url"])
        self.assertEqual(starved(queued, job(label="cmux-fleet-linux-x64", status="in_progress", created=30,
                                             started=20, runner="cmux-gha-runner-1116-1")), [])

    def test_the_persistent_linux_pool_label_is_in_scope(self) -> None:
        # Same-repository jobs name cmux-linux (PR #47956); a pool that stops listening must alert too.
        queued = job(label="cmux-linux", created=780, name="web / react-doctor")
        self.assertEqual([entry["label"] for entry in starved(queued)], ["cmux-linux"])
        self.assertEqual(starved(queued, job(label="cmux-linux", status="in_progress", created=30,
                                             started=20, runner="cmux-gha-runner-1120-1")), [])

    def test_one_pool_label_running_serves_the_other(self) -> None:
        # Every pool runner registers both cmux-linux and cmux-fleet-linux-x64, so either label's running job
        # proves a listener for the other (router-review F1 on #47956).
        for queued_label, running_label in (("cmux-linux", "cmux-fleet-linux-x64"),
                                            ("cmux-fleet-linux-x64", "cmux-linux")):
            with self.subTest(queued=queued_label):
                queued = job(label=queued_label, created=60)
                running = job(label=running_label, status="in_progress", created=30, started=20,
                              runner="cmux-runner-pool-c1f-0014-1")
                self.assertEqual([e["label"] for e in starved(queued)], [queued_label])
                # Two runs, so the running job is no sibling that may gate the queued one (wait_start()).
                self.assertEqual(starved_labels.starved([{"id": 1}, {"id": 2}], {1: [queued], 2: [running]},
                                                        now=NOW), [])
        # A glaeda label is not the pool's: a pool job (in another run, so it is no sibling) serves no Mac label.
        pool_job = job(label="cmux-linux", status="in_progress", created=30, started=20, runner="p-1")
        found = starved_labels.starved([{"id": 1}, {"id": 2}], {1: [job(created=60)], 2: [pool_job]}, now=NOW)
        self.assertEqual([e["label"] for e in found], [SIDE])

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


IOS = "glaeda-ios-sim+glaeda-std-xcode-26.6"


def dispatches(github: FakeGitHub) -> list:
    return [(body or {}).get("inputs", {}).get("run_id") for method, path, body in github.calls
            if method == "POST" and path.endswith("/actions/workflows/ci-owned-pool-rescue.yml/dispatches")]


def gate_row(*, listening=0, busy=0, units=0, cpu=0, livelock=0, other=0, down=0, unreported=0) -> dict:
    return {"listening": listening, "busy": busy, "down": down, "unreported": unreported, "queued": 1,
            "oldest_queued_s": 1800, "as_of": iso(1),
            "held_offline": {"total": units + cpu + livelock + other, "units": units, "cpu": cpu,
                             "livelock": livelock, "other": other}}


def gates(minutes_ago: float = 1, **rows) -> dict:
    return {"version": 1, "as_of": iso(minutes_ago), "labels": rows}


STD = "glaeda-std-xcode-26.6"


class CarrierTests(unittest.TestCase):
    """Full (busy, or held for units or load) is capacity; offline (down with no hold) is an outage."""

    def state(self, label: str, reading) -> str:
        return starved_labels.carriers(label, reading, NOW)["state"]

    def test_every_carrier_busy_or_held_for_units_reads_full(self) -> None:
        # cmux#45614: every std mini ran jobs or held its root runner for units; GitHub showed them offline.
        found = starved_labels.carriers(STD, gates(**{STD: gate_row(busy=13, units=24, other=17)}), NOW)
        self.assertEqual(found["state"], "full")
        self.assertIn("13 busy", found["why"])
        self.assertIn("24 units", found["why"])

    def test_carriers_held_only_for_load_read_full(self) -> None:
        self.assertEqual(self.state(SIDE, gates(**{SIDE: gate_row(cpu=5, other=2)})), "full")

    def test_carriers_down_with_no_hold_and_none_running_read_offline(self) -> None:
        self.assertEqual(self.state(SIDE, gates(**{SIDE: gate_row(down=4)})), "offline")

    def test_one_busy_carrier_beside_down_ones_reads_full_and_names_the_down_ones(self) -> None:
        found = starved_labels.carriers(SIDE, gates(**{SIDE: gate_row(busy=1, down=3)}), NOW)
        self.assertEqual(found["state"], "full")
        entry = {"label": SIDE, "oldest_queued_minutes": 30, "queued": 1, "job_url": "u", "job": "j", "carriers": found}
        self.assertIn("3 of its carriers are down with no hold", starved_labels.issue_body(entry, iso(0)))

    def test_down_carriers_beside_unreported_ones_read_unknown(self) -> None:
        self.assertEqual(self.state(SIDE, gates(**{SIDE: gate_row(down=1, unreported=10)})), "unknown")

    def test_an_idle_listener_reads_listening(self) -> None:
        self.assertEqual(self.state(SIDE, gates(**{SIDE: gate_row(listening=1, busy=2)})), "listening")

    def test_a_label_with_no_carrier_reads_none(self) -> None:
        self.assertEqual(self.state(SIDE, gates(**{SIDE: gate_row()})), "none")

    def test_only_unreported_carriers_read_unknown(self) -> None:
        self.assertEqual(self.state(SIDE, gates(**{SIDE: gate_row(unreported=3)})), "unknown")

    def test_no_stale_or_missing_reading_reads_unknown(self) -> None:
        self.assertEqual(self.state(SIDE, None), "unknown")
        self.assertEqual(self.state(SIDE, gates(minutes_ago=6, **{SIDE: gate_row(busy=1)})), "unknown")
        self.assertEqual(self.state(SIDE, gates(**{OTHER: gate_row(busy=1)})), "unknown")

    def test_a_label_over_several_parts_reads_its_worst_part_and_an_unlisted_part_is_unknown(self) -> None:
        # cmux#45620: glaeda-ios-sim+glaeda-std; the reading lists std only, so std being full proves nothing.
        both = f"glaeda-ios-sim+{STD}"
        self.assertEqual(self.state(both, gates(**{STD: gate_row(busy=3, units=4)})), "unknown")
        self.assertEqual(self.state(both, gates(**{STD: gate_row(busy=3), "glaeda-ios-sim": gate_row(units=2)})),
                         "full")
        self.assertEqual(self.state(both, gates(**{STD: gate_row(busy=3), "glaeda-ios-sim": gate_row(down=2)})),
                         "offline")

    def test_a_missing_or_stale_reading_says_why_and_how_old(self) -> None:
        # cmux#55737, #55844: the pages said "no fleet gate reading" while the janitor had refused one, and a stale
        # reading named only a clock time with no day.
        refused = starved_labels.carriers(SIDE, None, NOW, "CI_FLEET_GATES label 'x' is out of shape")
        self.assertEqual(refused["state"], "unknown")
        self.assertEqual(refused["why"],
                         "the janitor could not read the fleet gates: CI_FLEET_GATES label 'x' is out of shape")
        self.assertIn("no fleet gate reading (CI_FLEET_GATES)", starved_labels.carriers(SIDE, None, NOW)["why"])
        stale = starved_labels.carriers(SIDE, gates(minutes_ago=4 * 24 * 60, **{SIDE: gate_row(busy=1)}), NOW)
        self.assertEqual(stale["state"], "unknown")
        self.assertIn(f"from {(NOW - dt.timedelta(days=4)).strftime('%Y-%m-%d %H:%M:%SZ')}, ", stale["why"])
        self.assertIn(starved_labels.format_minutes(4 * 24 * 60) + " old, stale", stale["why"])

    def test_the_stale_bound_matches_the_janitors(self) -> None:
        text = (ROOT / "scripts/ci/queue_janitor.py").read_text(encoding="utf-8")
        self.assertIn(f"FLEET_GATES_STALE_S = {starved_labels.CARRIER_READING_STALE_S}\n", text)

    def test_the_issue_body_says_full_or_offline(self) -> None:
        entry = {"label": SIDE, "oldest_queued_minutes": 30, "queued": 1, "job_url": "u", "job": "j"}
        full = starved_labels.issue_body({**entry, "carriers": {"state": "full", "why": "x"}}, iso(0))
        offline = starved_labels.issue_body({**entry, "carriers": {"state": "offline", "why": "x"}}, iso(0))
        self.assertIn("full, not offline", full)
        self.assertNotIn("outage", full)
        self.assertIn("outage", offline)
        self.assertIn("No runner with this label is taking jobs", starved_labels.issue_body(entry, iso(0)))

    def test_main_classifies_each_starved_label_from_the_snapshot_gates(self) -> None:
        entry = {"label": SIDE, "oldest_queued_minutes": 30, "queued": 1, "job_url": "u", "job": "j"}
        snapshot = {"generated_at": iso(0), "starved": [entry, {**entry, "label": OTHER}],
                    "gates": gates(**{SIDE: gate_row(busy=2, units=3), OTHER: gate_row(down=2)})}
        github = FakeGitHub([])
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(starved_labels, "client", return_value=github):
            path = Path(tmp) / "load.json"
            path.write_text(json.dumps(snapshot), encoding="utf-8")
            out = io.StringIO()
            with redirect_stdout(out):
                code = starved_labels.main(["--snapshot", str(path)], env={"GH_REPO": "manaflow-ai/cmux", "GH_TOKEN": "t"})
        self.assertEqual(code, 0)
        self.assertIn(f"{SIDE} took no job for 30m, carriers full", out.getvalue())
        self.assertIn(f"{OTHER} took no job for 30m, carriers offline", out.getvalue())
        bodies = {body["title"]: body["body"] for method, path, body in github.calls
                  if method == "POST" and path.endswith("/issues")}
        self.assertIn("full, not offline", bodies[starved_labels.issue_title(SIDE)])
        self.assertIn("an outage", bodies[starved_labels.issue_title(OTHER)])


class RescueTests(unittest.TestCase):
    """cmux#45115 (2026-11-17): glaeda-ios-sim+glaeda-std-xcode-26.6 unserved 539 minutes, 16 jobs queued, every
    carrier held off by its mini's gate; the alert opened an issue and NOW paged it, and nothing moved a job."""

    def stuck_ios(self, run: int, created: float) -> dict:
        entry = job(label="glaeda-std-xcode-26.6", created=created, name="ios-simulator-build")
        entry["labels"] = ["glaeda-std-xcode-26.6", "glaeda-ios-sim"]
        entry["run_id"], entry["run_attempt"] = run, 1
        return entry

    def test_a_label_starved_past_thirty_minutes_starts_each_stuck_runs_rescue(self) -> None:
        runs = [{"id": 11}, {"id": 12}, {"id": 13}]
        jobs = {11: [self.stuck_ios(11, 231)], 12: [self.stuck_ios(12, 90)], 13: [self.stuck_ios(13, 20)]}
        found = starved_labels.starved(runs, jobs, now=NOW)
        github = FakeGitHub([dict(search_item(IOS, 45115), body="old")])
        lines = starved_labels.sync_issues(github, found, iso(0), now=NOW)
        # the two runs stuck past 30 minutes, oldest first; the 20-minute one waits for its own 30
        self.assertEqual(dispatches(github), ["11", "12"])
        self.assertTrue(any("started run 11's rescue" in line for line in lines), lines)
        patch = next(body for method, path, body in github.calls if method == "PATCH" and path.endswith("/45115"))
        self.assertEqual(sorted(starved_labels.rescued_runs(patch["body"])), [11, 12])

    def test_a_run_already_rescued_is_not_dispatched_again_within_the_repeat(self) -> None:
        found = starved_labels.starved([{"id": 11}], {11: [self.stuck_ios(11, 231)]}, now=NOW)
        body = f"x\n\n<!-- starved-rescue: 11@{iso(10)} -->"
        github = FakeGitHub([dict(search_item(IOS, 45115), body=body)])
        starved_labels.sync_issues(github, found, iso(0), now=NOW)
        self.assertEqual(dispatches(github), [])
        github = FakeGitHub([dict(search_item(IOS, 45115), body=f"<!-- starved-rescue: 11@{iso(230)} -->")])
        starved_labels.sync_issues(github, found, iso(0), now=NOW)
        self.assertEqual(dispatches(github), ["11"])

    def test_the_persistent_pool_label_alerts_but_starts_no_rescue(self) -> None:
        # A job on cmux-linux names it literally, so the rescue cannot move it (PR #47956 review).
        stuck = job(label="cmux-linux", created=231, name="full bake")
        stuck["run_id"], stuck["run_attempt"] = 11, 1
        found = starved_labels.starved([{"id": 11}], {11: [stuck]}, now=NOW)
        self.assertEqual([entry["label"] for entry in found], ["cmux-linux"])
        self.assertEqual(starved_labels.rescue_plan(found[0], {}, NOW), [])
        github = FakeGitHub([])
        starved_labels.sync_issues(github, found, iso(0), now=NOW)
        self.assertEqual(dispatches(github), [])
        self.assertEqual(github.opened(), 1)

    def test_a_label_starved_under_thirty_minutes_only_alerts(self) -> None:
        found = starved_labels.starved([{"id": 11}], {11: [self.stuck_ios(11, 25)]}, now=NOW)
        self.assertEqual(len(found), 1)
        github = FakeGitHub([])
        starved_labels.sync_issues(github, found, iso(0), now=NOW)
        self.assertEqual(dispatches(github), [])
        self.assertEqual(github.opened(), 1)

    def test_a_refused_dispatch_never_fails_the_alert(self) -> None:
        class Refusing(FakeGitHub):
            def request(self, method, path, body=None):
                if path.endswith("/dispatches"):
                    raise RuntimeError("POST dispatches failed (403)")
                return super().request(method, path, body)
        found = starved_labels.starved([{"id": 11}], {11: [self.stuck_ios(11, 231)]}, now=NOW)
        github = Refusing([])
        lines = starved_labels.sync_issues(github, found, iso(0), now=NOW)
        self.assertEqual(github.opened(), 1)
        self.assertTrue(any("could not start run 11's rescue" in line for line in lines), lines)

    def test_a_run_with_its_own_requested_watch_or_a_later_attempt_gets_no_dispatch(self) -> None:
        # A dispatch shares owned-pool-rescue-RUN-ATTEMPT with a nightly's own watch and would cancel it; the watch
        # path watches attempt 1 only.
        runs = [{"id": 11, "path": ".github/workflows/nightly.yml"}, {"id": 12, "path": ".github/workflows/ci.yml"},
                {"id": 13, "path": ".github/workflows/test-ios.yml"}]
        later = self.stuck_ios(12, 200)
        later["run_attempt"] = 2
        jobs = {11: [self.stuck_ios(11, 231)], 12: [later], 13: [self.stuck_ios(13, 100)]}
        found = starved_labels.starved(runs, jobs, now=NOW)
        self.assertEqual(found[0]["runs"], [[13, 1]])

    def test_the_request_watched_paths_match_the_rescue_workflow(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/ci-owned-pool-rescue.yml").read_text(encoding="utf-8"))
        sources = set(workflow["env"]["SOURCE_WORKFLOW_PATHS"].split())
        self.assertEqual(starved_labels.REQUEST_WATCHED_PATHS, sources - {".github/workflows/cmux-next.yml"})

    def test_the_sweep_caps_its_dispatches(self) -> None:
        runs = [{"id": n} for n in range(20, 40)]
        jobs = {n: [self.stuck_ios(n, 100 + n)] for n in range(20, 40)}
        found = starved_labels.starved(runs, jobs, now=NOW)
        github = FakeGitHub([])
        starved_labels.sync_issues(github, found, iso(0), now=NOW)
        self.assertEqual(len(dispatches(github)), starved_labels.RESCUE_RUNS_PER_SWEEP)


class WorkflowTests(unittest.TestCase):
    def test_sweeps_are_serialized_and_never_cancelled_mid_reconcile(self) -> None:
        workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
        concurrency = workflow["concurrency"]
        self.assertIs(concurrency["cancel-in-progress"], False)
        # every run that sweeps shares one group; only a run whose job starts no sweep gets its own
        self.assertTrue(concurrency["group"].endswith("|| 'ci-queue-janitor-v2' }}"), concurrency["group"])

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
