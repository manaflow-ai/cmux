#!/usr/bin/env python3
"""Side-lane placement: trusted jobs stay on the owned side label while minis drain.

Side-lane workflows have no picker. Their macOS jobs took vars.CI_SIDE_LANE_RUNNER
on attempt 1 blindly, so a busy fleet left them queued until the owned-pool
rescue cancelled the run and re-ran it on Blacksmith (cmux-next.yml, 2026-10-02:
49 of 60 runs needed attempt 2). scripts/ci/side_lane_placement.py records the
idle runners for observability, but a busy fleet remains queued on the owned
label. The rescue supplies the measured overflow boundary.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/side_lane_placement.py"
WORKFLOWS = ROOT / ".github/workflows"
SIDE = "glaeda-side-std-xcode-26.6"
STD = "glaeda-std-xcode-26.6"
FALLBACK = "blacksmith-6vcpu-macos-26"
JOBS = ("cmux-scheme-compile", "release-compile", "swift-test")

sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate, github_context  # noqa: E402


def load():
    spec = importlib.util.spec_from_file_location("side_lane_placement", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["side_lane_placement"] = module
    spec.loader.exec_module(module)
    return module


placement = load() if SCRIPT.exists() else None


def runner(name: str, *, busy: bool = False, status: str = "online", labels=(STD, SIDE)) -> dict:
    return {"name": name, "status": status, "busy": busy,
            "labels": [{"name": label} for label in ("self-hosted", *labels)]}


def env(**overrides: str) -> dict:
    return {"SIDE_LABEL": SIDE, "JOBS": " ".join(JOBS), "GITHUB_RUN_ATTEMPT": "1", **overrides}


class Decide(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(placement, "scripts/ci/side_lane_placement.py is missing")

    def test_a_busy_pool_stays_on_the_owned_label(self):
        # No idle owned runner: every job remains queued for the long rescue budget.
        busy = [runner("mini-a-glaeda-3", busy=True), runner("mini-b-glaeda-3", busy=True),
                runner("mini-c-glaeda-3", status="offline")]
        owned, fallback, why = placement.decide(env(), busy)
        self.assertEqual((owned, fallback), ((), ()))
        self.assertIn("no idle", why)

    def test_an_idle_owned_runner_takes_a_job(self):
        runners = [runner("mini-a-glaeda-3"), runner("mini-b-glaeda-3", busy=True)]
        self.assertEqual(placement.decide(env(), runners)[:2], (JOBS[:1], ()))
        idle = [runner(f"mini-{host}-glaeda-3") for host in "abcd"]
        self.assertEqual(placement.decide(env(), idle)[:2], (JOBS, ()))

    def test_only_runners_carrying_the_side_label_count(self):
        # A root runner of the same mini (std label, no side label) is not a side runner.
        runners = [runner("mini-a-glaeda", labels=(STD, "glaeda-root-std-xcode-26.6")), runner("mini-a-glaeda-3")]
        self.assertEqual(placement.decide(env(), runners)[:2], (JOBS[:1], ()))

    def test_attempt_2_and_later_are_unchanged(self):
        # Attempt 2+ keeps its own route (the workflow's expression sends it to the fallback): no decision.
        idle = [runner(f"mini-{host}-glaeda-3") for host in "abc"]
        for attempt in ("2", "3"):
            self.assertEqual(placement.decide(env(GITHUB_RUN_ATTEMPT=attempt), idle)[:2], ((), ()))

    def test_uncertainty_keeps_todays_route(self):
        # Unreadable runners, or a route that is not an owned side label (a fork, owned pools off), decide
        # nothing: the jobs keep attempt 1's owned label and the rescue watches them, as before.
        idle = [runner("mini-a-glaeda-3")]
        self.assertEqual(placement.decide(env(), None)[:2], ((), ()))
        for label in ("", FALLBACK, "macos-26", STD, "glaeda-root-std-xcode-26.6"):
            self.assertEqual(placement.decide(env(SIDE_LABEL=label), idle)[:2], ((), ()), label)

    def test_it_reuses_the_main_pickers_idle_placement(self):
        # One rule for both callers: pr_runner_pool.idle_placement().
        runners = [runner("mini-a-glaeda-3"), runner("mini-b-glaeda-3")]
        self.assertEqual(placement.pool.idle_placement(runners, SIDE, JOBS), JOBS[:2])
        with mock.patch.object(placement.pool, "idle_placement", return_value=()) as shared:
            self.assertEqual(placement.decide(env(), runners)[:2], ((), ()))
        shared.assert_called_once()

    def test_main_writes_the_outputs(self):
        # The script's ::warning:: lines stay out of the guard job's log.
        with tempfile.TemporaryDirectory() as tmp, contextlib.redirect_stdout(io.StringIO()):
            output = Path(tmp) / "out"
            fake = mock.Mock()
            fake.runners.return_value = [runner("mini-a-glaeda-3")]
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(lines["owned_jobs"], " cmux-scheme-compile ")
            self.assertEqual(lines["fallback_jobs"], "")
            self.assertEqual(lines["watch"], "true")
            # Every job on the fallback: no owned job for the rescue to watch.
            output.write_text("")
            fake.runners.return_value = []
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["owned_jobs"], lines["fallback_jobs"], lines["watch"]), ("", "", "true"))
            # Unreadable: no decision, today's route, watched.
            output.write_text("")
            fake.runners.side_effect = RuntimeError("HTTP 403")
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["fallback_jobs"], lines["watch"]), ("", "true"))


class CmuxNextWiring(unittest.TestCase):
    """cmux-next's Mac jobs go straight to the side label; no placement job sits before them.

    The placement job's fallback_jobs output was read by no runs-on, so it was a
    Linux hop on every run's critical path. Its one real effect, the opt-in
    owned-pool watch marker, moved into path_route.
    """
    MAC_JOBS = (*JOBS, "daemon-test", "generated-files")

    def workflow(self) -> dict:
        return yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text(encoding="utf-8"))

    def context(self, attempt: str = "1", fork: bool = False, triggering_actor: str = "teamleaderleo",
                rescue: str = "1", macos: str = "true") -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", CI_PR_POOL_OWNED="1",
                                 CI_SIDE_LANE_RUNNER=SIDE, CMUX_NEXT_POOL_RESCUE=rescue)
        context["vars"].pop("MACOS_RUNNER_PR")
        head = "someone/cmux" if fork else "manaflow-ai/cmux"
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt,
                                 triggering_actor=triggering_actor,
                                 event={"pull_request": {"head": {"repo": {"full_name": head}}}})
        context["needs"] = {"path_route": {"outputs": {"native": "true", "macos": macos}}}
        context["steps"] = {"route": {"outputs": {"macos": macos}}}
        workflow = self.workflow()
        context["env"]["CMUX_NEXT_SIDE_ROUTE"] = evaluate(workflow["env"]["CMUX_NEXT_SIDE_ROUTE"], context)
        return context

    def test_mac_jobs_start_right_after_routing(self):
        jobs = self.workflow()["jobs"]
        self.assertNotIn("macos-placement", jobs)
        for name in self.MAC_JOBS:
            job = jobs[name]
            with self.subTest(job=name):
                self.assertNotIn("macos-placement", job["needs"])
                self.assertIn("path_route", job["needs"])
                self.assertTrue(job["if"].startswith("${{ !cancelled() && "), job["if"])
                # The job's own copy of its label (mini-only steps) agrees with runs-on.
                self.assertEqual(job["env"]["CMUX_NEXT_RUNNER"], job["runs-on"])

    def test_trusted_attempts_stay_on_the_side_label_until_overflow(self):
        jobs = self.workflow()["jobs"]
        for name in self.MAC_JOBS:
            runs_on = jobs[name]["runs-on"]
            with self.subTest(job=name):
                self.assertEqual(evaluate(runs_on, self.context()), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("2")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("2", triggering_actor="github-actions[bot]")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("3", triggering_actor="teamleaderleo")), SIDE)
                # The rescue's third attempt is the measured overflow route.
                self.assertEqual(evaluate(runs_on, self.context("3", triggering_actor="github-actions[bot]")), FALLBACK)
                self.assertEqual(evaluate(runs_on, self.context(fork=True)), FALLBACK)

    def test_the_watch_marker_is_opt_in_and_only_where_mac_jobs_take_the_side_label(self):
        route = self.workflow()["jobs"]["path_route"]["steps"]
        mark = next(step for step in route if step.get("id") == "marker")
        self.assertTrue(evaluate(mark["if"], self.context()))
        push = self.context()
        push["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
        push["env"]["CMUX_NEXT_SIDE_ROUTE"] = evaluate(self.workflow()["env"]["CMUX_NEXT_SIDE_ROUTE"], push)
        self.assertTrue(evaluate(mark["if"], push))
        for why, context in {"rescue not opted in": self.context(rescue=""), "fork": self.context(fork=True),
                             "attempt 2": self.context("2"), "no Mac work": self.context(macos="false")}.items():
            self.assertFalse(evaluate(mark["if"], context), why)
        upload = next(step for step in route if step.get("uses", "").startswith("actions/upload-artifact"))
        self.assertEqual(upload["with"]["name"], "owned-pool-watch")
        self.assertEqual(upload["if"], "${{ steps.marker.outputs.path != '' }}")

    def test_a_re_push_cancels_each_superseded_job_not_the_whole_run(self):
        workflow = self.workflow()
        # A workflow-level group made a re-push wait for every old job to finish cancelling.
        self.assertNotIn("concurrency", workflow)
        for name, job in workflow["jobs"].items():
            with self.subTest(job=name):
                group = job["concurrency"]["group"]
                self.assertEqual(group, "cmux-next-${{ github.event.pull_request.number || github.run_id }}-" + name)
                self.assertEqual(job["concurrency"]["cancel-in-progress"], "${{ github.event_name == 'pull_request' }}")

if __name__ == "__main__":
    unittest.main()
