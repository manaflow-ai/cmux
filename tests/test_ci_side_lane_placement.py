#!/usr/bin/env python3
"""Side-lane placement: a side-lane macOS job takes an owned runner on attempt 1 only when one is idle now.

Side-lane workflows have no picker. Their macOS jobs took vars.CI_SIDE_LANE_RUNNER
on attempt 1 blindly, so a busy fleet left them queued until the owned-pool
rescue cancelled the run and re-ran it on Blacksmith (cmux-next.yml, 2026-10-02:
49 of 60 runs needed attempt 2). scripts/ci/side_lane_placement.py places each
job the way pr_runner_pool.py places side lanes: an idle owned runner takes it
now, else it keeps the job's fallback.
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

    def test_a_busy_pool_falls_back_on_attempt_1(self):
        # No idle owned runner: every job keeps its fallback now, and none queues for the rescue to cancel.
        busy = [runner("mini-a-glaeda-3", busy=True), runner("mini-b-glaeda-3", busy=True),
                runner("mini-c-glaeda-3", status="offline")]
        owned, fallback, why = placement.decide(env(), busy)
        self.assertEqual((owned, fallback), ((), JOBS))
        self.assertIn("no idle", why)

    def test_an_idle_owned_runner_takes_a_job(self):
        runners = [runner("mini-a-glaeda-3"), runner("mini-b-glaeda-3", busy=True)]
        self.assertEqual(placement.decide(env(), runners)[:2], (JOBS[:1], JOBS[1:]))
        idle = [runner(f"mini-{host}-glaeda-3") for host in "abcd"]
        self.assertEqual(placement.decide(env(), idle)[:2], (JOBS, ()))

    def test_only_runners_carrying_the_side_label_count(self):
        # A root runner of the same mini (std label, no side label) is not a side runner.
        runners = [runner("mini-a-glaeda", labels=(STD, "glaeda-root-std-xcode-26.6")), runner("mini-a-glaeda-3")]
        self.assertEqual(placement.decide(env(), runners)[:2], (JOBS[:1], JOBS[1:]))

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
            self.assertEqual(placement.decide(env(), runners)[:2], ((), JOBS))
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
            self.assertEqual(lines["fallback_jobs"], " release-compile swift-test ")
            self.assertEqual(lines["watch"], "true")
            # Every job on the fallback: no owned job for the rescue to watch.
            output.write_text("")
            fake.runners.return_value = []
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["owned_jobs"], lines["watch"]), ("", "false"))
            # Unreadable: no decision, today's route, watched.
            output.write_text("")
            fake.runners.side_effect = RuntimeError("HTTP 403")
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["fallback_jobs"], lines["watch"]), ("", "true"))


class CmuxNextWiring(unittest.TestCase):
    PLACEMENT = "macos-placement"

    def workflow(self) -> dict:
        return yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text(encoding="utf-8"))

    def context(self, attempt: str = "1", fallback_jobs: str | None = "", fork: bool = False) -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", CI_PR_POOL_OWNED="1",
                                 CI_SIDE_LANE_RUNNER=SIDE)
        context["vars"].pop("MACOS_RUNNER_PR")
        head = "someone/cmux" if fork else "manaflow-ai/cmux"
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt,
                                 event={"pull_request": {"head": {"repo": {"full_name": head}}}})
        outputs = {} if fallback_jobs is None else {"fallback_jobs": fallback_jobs}
        context["needs"] = {self.PLACEMENT: {"outputs": outputs}}
        return context

    def test_every_mac_job_reads_the_placement(self):
        jobs = self.workflow()["jobs"]
        placement_job = jobs[self.PLACEMENT]
        place = next(step for step in placement_job["steps"] if step.get("id") == "place")
        self.assertEqual(place["run"], "python3 scripts/ci/side_lane_placement.py")
        placed = tuple(place["env"]["JOBS"].split())
        self.assertEqual(set(placed), set(JOBS))
        for name in placed:
            job = jobs[name]
            with self.subTest(job=name):
                self.assertIn(self.PLACEMENT, job["needs"] if isinstance(job["needs"], list) else [job["needs"]])
                # A failed placement job must not skip the Mac jobs: they keep today's route.
                self.assertTrue(job["if"].startswith("${{ !cancelled() && "), job["if"])
                self.assertIn(f"' {name} '", job["runs-on"])
                # The job's own copy of its label (mini-only steps) agrees with runs-on.
                self.assertEqual(job["env"]["CMUX_NEXT_RUNNER"], job["runs-on"])

    def test_attempt_1_takes_the_side_label_unless_placed_on_the_fallback(self):
        jobs = self.workflow()["jobs"]
        for name in JOBS:
            runs_on = jobs[name]["runs-on"]
            with self.subTest(job=name):
                # Placed on an idle runner, or no placement (skipped, failed, unreadable): the owned label.
                self.assertEqual(evaluate(runs_on, self.context(fallback_jobs=" other ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context(fallback_jobs=None)), SIDE)
                # No idle owned runner: the job's fallback, the same label attempt 2 takes.
                self.assertEqual(evaluate(runs_on, self.context(fallback_jobs=f" {name} ")), FALLBACK)
                for attempt in ("2", "3"):
                    for fallback_jobs in ("", f" {name} "):
                        self.assertEqual(evaluate(runs_on, self.context(attempt, fallback_jobs)), FALLBACK)
                self.assertEqual(evaluate(runs_on, self.context(fork=True)), FALLBACK)

    def test_placement_starts_only_where_attempt_1_may_take_the_side_label(self):
        # A fork, another owner, owned pools off or a re-run starts no Linux runner before the Mac jobs.
        jobs = self.workflow()["jobs"]
        gate = jobs[self.PLACEMENT]["if"]
        self.assertTrue(evaluate(gate, self.context()))
        push = self.context()
        push["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
        self.assertTrue(evaluate(gate, push))
        other_owner = self.context()
        other_owner["github"]["repository_owner"] = "someone"
        owned_off = self.context()
        owned_off["vars"]["CI_PR_POOL_OWNED"] = "0"
        dispatch_elsewhere = self.context()
        dispatch_elsewhere["github"].update(event_name="workflow_dispatch", ref="refs/heads/main")
        for why, context in {"fork": self.context(fork=True), "attempt 2": self.context("2"),
                             "attempt 3": self.context("3"), "another owner": other_owner,
                             "owned pools off": owned_off, "dispatch off feat-cmux-next": dispatch_elsewhere}.items():
            self.assertFalse(evaluate(gate, context), why)
        # Wherever a Mac job may take an owned label the placement runs, so its marker can upload:
        # every context above that skips it routes every Mac job to the fallback.
        for name in JOBS:
            runs_on = jobs[name]["runs-on"]
            for why, context in {"fork": self.context(fork=True), "attempt 2": self.context("2"),
                                 "another owner": other_owner, "owned pools off": owned_off}.items():
                context["needs"] = {}  # the skipped placement has no outputs
                self.assertFalse(str(evaluate(runs_on, context)).startswith("glaeda-"), (name, why))
            # A skipped placement leaves the Mac jobs running (!cancelled()) and its empty output keeps the label.
            self.assertTrue(evaluate(jobs[name]["if"].replace("!cancelled() && ", ""), self.context()))
            self.assertEqual(evaluate(runs_on, dict(self.context(), needs={})), SIDE)

    def test_the_watch_marker_follows_the_placement(self):
        steps = self.workflow()["jobs"][self.PLACEMENT]["steps"]
        names = [step.get("name") for step in steps]
        mark = next(step for step in steps if step.get("id") == "marker")
        # The marker comes after the placement and skips a run with every job on the fallback.
        self.assertLess(names.index(next(step["name"] for step in steps if step.get("id") == "place")),
                        names.index(mark["name"]))
        self.assertIn("steps.place.outputs.watch != 'false'", mark["if"])
        upload = next(step for step in steps if step.get("uses", "").startswith("actions/upload-artifact"))
        self.assertEqual(upload["with"]["name"], "owned-pool-watch")
        checks = self.workflow()["jobs"]["checks"]["steps"]
        self.assertFalse(any(step.get("with", {}).get("name") == "owned-pool-watch" for step in checks))


if __name__ == "__main__":
    unittest.main()
