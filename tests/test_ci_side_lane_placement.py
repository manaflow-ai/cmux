#!/usr/bin/env python3
"""Side-lane placement: trusted jobs use a live side label or the std pool.

Side-lane workflows have no picker. Their macOS jobs use the live side label
when it exists, and fall back to the owned std pool label when no online runner
carries the side label. A busy side label remains queued for the rescue budget.
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
JOBS = ("cmux-scheme-compile", "release-compile", "swift-test", "daemon-test", "generated-files")

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
        self.assertEqual(placement.decide(env(), idle)[:2], (JOBS[:4], ()))

    def test_only_runners_carrying_the_side_label_count(self):
        # A root runner of the same mini (std label, no side label) is not a side runner.
        runners = [runner("mini-a-glaeda", labels=(STD, "glaeda-root-std-xcode-26.6")), runner("mini-a-glaeda-3")]
        self.assertEqual(placement.decide(env(), runners)[:2], (JOBS[:1], ()))

    def test_route_falls_back_to_the_owned_pool_when_side_label_is_absent(self):
        runners = [runner("mini-a-glaeda", labels=(STD,)),
                   runner("mini-b-glaeda", labels=(STD,), busy=True)]
        self.assertEqual(placement.route_label(SIDE, runners), STD)

    def test_route_keeps_side_label_when_any_online_runner_carries_it(self):
        self.assertEqual(placement.route_label(SIDE, [runner("mini-a-glaeda")]), SIDE)

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
            self.assertEqual(lines["runner"], SIDE)
            self.assertEqual(lines["watch"], "true")
            # Every job on the fallback: no owned job for the rescue to watch.
            output.write_text("")
            fake.runners.return_value = []
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["owned_jobs"], lines["fallback_jobs"], lines["runner"], lines["watch"]),
                             ("", "", STD, "true"))
            # Unreadable: no decision, today's route, watched.
            output.write_text("")
            fake.runners.side_effect = RuntimeError("HTTP 403")
            with mock.patch.object(placement.pool, "GitHub", return_value=fake):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual((lines["fallback_jobs"], lines["runner"], lines["watch"]), ("", "", "true"))


class CmuxNextWiring(unittest.TestCase):
    PLACEMENT = "macos-placement"

    def workflow(self) -> dict:
        return yaml.safe_load((WORKFLOWS / "cmux-next.yml").read_text(encoding="utf-8"))

    def context(self, attempt: str = "1", fallback_jobs: str | None = "", runner: str = "",
                fork: bool = False,
                triggering_actor: str = "teamleaderleo") -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", CI_PR_POOL_OWNED="1",
                                 CI_SIDE_LANE_RUNNER=SIDE)
        context["vars"].pop("MACOS_RUNNER_PR")
        head = "someone/cmux" if fork else "manaflow-ai/cmux"
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt,
                                 triggering_actor=triggering_actor,
                                 event={"pull_request": {"head": {"repo": {"full_name": head}}}})
        outputs = {} if fallback_jobs is None else {"fallback_jobs": fallback_jobs, "runner": runner}
        # path_route (#17164) gates every Mac job; these cases are native changes.
        context["needs"] = {"path_route": {"outputs": {"native": "true", "macos": "true", "scheme": "true",
                                                            "swift": "true", "daemon": "true", "generated": "true",
                                                            "tree_state": "ready"}},
                            "push-head-preflight": {"outputs": {"current": "true"}},
                            self.PLACEMENT: {"outputs": outputs}}
        return context

    def test_every_mac_job_reads_the_placement(self):
        jobs = self.workflow()["jobs"]
        placement_job = jobs[self.PLACEMENT]
        place = next(step for step in placement_job["steps"] if step.get("id") == "place")
        self.assertIn("python3 scripts/ci/side_lane_placement.py", place["run"])
        placed = tuple(place["env"]["JOBS"].split())
        self.assertEqual(set(placed), set(JOBS))
        for name in placed:
            job = jobs[name]
            with self.subTest(job=name):
                self.assertIn(self.PLACEMENT, job["needs"] if isinstance(job["needs"], list) else [job["needs"]])
                # A failed placement job must not skip the Mac jobs: they keep today's route.
                self.assertTrue(job["if"].startswith("${{ !cancelled() && "), job["if"])
                self.assertIn("needs.macos-placement.outputs.runner", job["runs-on"])
                # The job's own copy of its label (mini-only steps) agrees with runs-on.
                self.assertEqual(job["env"]["CMUX_NEXT_RUNNER"], job["runs-on"])

    def test_trusted_attempts_use_the_live_route_until_overflow(self):
        jobs = self.workflow()["jobs"]
        for name in JOBS:
            runs_on = jobs[name]["runs-on"]
            with self.subTest(job=name):
                # A live side label remains preferred; no live side label routes to the std pool.
                self.assertEqual(evaluate(runs_on, self.context(runner=SIDE)), SIDE)
                self.assertEqual(evaluate(runs_on, self.context(runner=STD)), STD)
                # Skipped or unreadable placement keeps today's configured route.
                self.assertEqual(evaluate(runs_on, self.context(fallback_jobs=None)), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("2")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("2", triggering_actor="github-actions[bot]")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("3", triggering_actor="teamleaderleo")), SIDE)
                # The rescue's third attempt is the measured overflow route.
                self.assertEqual(evaluate(runs_on, self.context("3", triggering_actor="github-actions[bot]")), FALLBACK)
                self.assertEqual(evaluate(runs_on, self.context("3", fallback_jobs=f" {name} ",
                                                                 triggering_actor="github-actions[bot]")), FALLBACK)
                self.assertEqual(evaluate(runs_on, self.context(fork=True)), FALLBACK)

    def test_placement_starts_only_where_attempt_1_may_take_the_side_label(self):
        # A fork, another owner, owned pools off or a re-run starts no Linux runner before the Mac jobs.
        jobs = self.workflow()["jobs"]
        # !cancelled(): a same-tree mode run (path routing skipped) still places its tree jobs.
        self.assertTrue(jobs[self.PLACEMENT]["if"].startswith("${{ !cancelled() && "))
        gate = jobs[self.PLACEMENT]["if"].replace("!cancelled() && ", "")
        self.assertTrue(evaluate(gate, self.context()))
        same_tree = self.context()
        same_tree["github"].update(event_name="workflow_dispatch", ref="refs/heads/feat-cmux-next")
        same_tree["inputs"] = {"same_tree_sha": "a" * 40, "same_tree_state": "ready"}
        same_tree["needs"] = {}
        self.assertTrue(evaluate(gate, same_tree))
        same_tree["inputs"]["same_tree_state"] = "failed"
        self.assertFalse(evaluate(gate, same_tree))
        push = self.context()
        push["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
        self.assertTrue(evaluate(gate, push))
        other_owner = self.context()
        other_owner["github"]["repository_owner"] = "someone"
        owned_off = self.context()
        owned_off["vars"]["CI_PR_POOL_OWNED"] = "0"
        dispatch_elsewhere = self.context()
        dispatch_elsewhere["github"].update(event_name="workflow_dispatch", ref="refs/heads/main")
        no_mac_work = self.context()
        no_mac_work["needs"]["path_route"]["outputs"].update(native="false", macos="false")
        for why, context in {"fork": self.context(fork=True), "attempt 2": self.context("2"),
                             "attempt 3": self.context("3"), "another owner": other_owner,
                             "owned pools off": owned_off, "dispatch off feat-cmux-next": dispatch_elsewhere,
                             "no Mac work on the path route": no_mac_work}.items():
            self.assertFalse(evaluate(gate, context), why)
        # Wherever a Mac job may take an owned label the placement runs, so its marker can upload:
        # every context above that skips it routes every Mac job to the fallback.
        for name in JOBS:
            runs_on = jobs[name]["runs-on"]
            for why, context in {"fork": self.context(fork=True), "attempt 3": self.context("3", triggering_actor="github-actions[bot]"),
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


    def push(self, run_id: str, event_name: str = "push") -> dict:
        context = self.context()
        context["github"].update(event_name=event_name, ref="refs/heads/feat-cmux-next", run_id=run_id, event={})
        return context

    def test_a_newer_push_replaces_only_a_pending_mac_job(self):
        # 2026-10-07 00:20Z to 01:05Z: pushes about once a minute, and in none of 12
        # tip runs did "cmux-next swift test" complete. The owned-pool rescue cancelled
        # each push run whose Mac jobs waited 30 s for a mini while a newer push run
        # existed, so the newest run was always the next one cancelled. Each Mac job of
        # a push now holds one group per branch: one runs, one waits, and a newer push
        # replaces only the waiting job (cancel-in-progress false). Pull request and
        # dispatch runs keep a group per run.
        jobs = self.workflow()["jobs"]
        push_groups = {}
        for name in JOBS:
            with self.subTest(job=name):
                concurrency = jobs[name].get("concurrency")
                self.assertIsInstance(concurrency, dict, f"{name} has no job-level concurrency")
                self.assertIs(concurrency["cancel-in-progress"], False)
                group = concurrency["group"]
                first, second = evaluate(group, self.push("101")), evaluate(group, self.push("102"))
                self.assertEqual(first, second)
                push_groups[name] = first
                for event_name in ("pull_request", "workflow_dispatch"):
                    one, other = (evaluate(group, self.push(run_id, event_name)) for run_id in ("101", "102"))
                    self.assertNotEqual(one, other, event_name)
                    self.assertNotEqual(one, first, event_name)
        self.assertEqual(len(set(push_groups.values())), len(JOBS))

    def test_push_runs_upload_no_rescue_watch_marker(self):
        # The rescue sweeper adopts a run by its owned-pool-watch marker and cancels a
        # push run with a newer push run behind it, even while its swift test runs.
        # The per-branch job groups above bound the push queue instead.
        steps = self.workflow()["jobs"][self.PLACEMENT]["steps"]
        mark = next(step for step in steps if step.get("id") == "marker")

        def marked(context: dict) -> bool:
            context["env"]["CMUX_NEXT_SIDE_ROUTE"] = SIDE
            context["steps"] = {"place": {"outputs": {"watch": "true"}}}
            return bool(evaluate(mark["if"], context))

        self.assertTrue(marked(self.context()))
        self.assertTrue(marked(self.push("101", "workflow_dispatch")))
        self.assertFalse(marked(self.push("101")))


if __name__ == "__main__":
    unittest.main()
