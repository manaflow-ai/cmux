#!/usr/bin/env python3
"""cmux-next's macOS cascade: idle minis, then Blacksmith 12 vCPU, then 6 vCPU, then the minis' queue.

The placement decides from live counts (Blacksmith's scale-set runner groups)
and the janitor's queued counts; the workflow's runs-on reads its outputs.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/ci"
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
LARGE, SMALL = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"
SIDE = "glaeda-side-light-xcode-26.6"
GUI = "glaeda-gui-std-xcode-26.6"
CASCADED = ("fast-tier", "swift-canary", "cmux-scheme-compile")
GUI_JOBS = ("swift-test", "daemon-test", "generated-files")
ALL_JOBS = "fast-tier swift-canary cmux-scheme-compile release-compile swift-test daemon-test generated-files"
NOW = dt.datetime(2026, 10, 19, 22, 0, tzinfo=dt.timezone.utc)
BOT = "github-actions[bot]"

sys.path.insert(0, str(ROOT / "tests"))
from test_seed_derived_data import evaluate, github_context  # noqa: E402


def load(name: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


cascade = load("next_macos_cascade")
placement = load("side_lane_placement")


def env(**overrides: str) -> dict:
    return {"SIDE_LABEL": SIDE, "JOBS": ALL_JOBS, "GITHUB_RUN_ATTEMPT": "1",
            "CASCADE_RUNS": " fast-tier swift-canary cmux-scheme-compile ", **overrides}


def snapshot(minutes_old: float = 2, **queued: int) -> dict:
    generated = (NOW - dt.timedelta(minutes=minutes_old)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"generated_at": generated,
            "pools": {LARGE: {"queued": queued.get("large", 0), "running": 0},
                      SMALL: {"queued": queued.get("small", 0), "running": 0}}}


class Counts(unittest.TestCase):
    GROUPS = [{"id": 15, "name": f"Blacksmith scale sets - {LARGE}"},
              {"id": 10, "name": f"Blacksmith scale sets - {SMALL}"},
              {"id": 8, "name": "Blacksmith scale sets - blacksmith-6vcpu-macos-15"}]

    def test_in_flight_counts_each_labels_online_runners(self):
        runners = {15: [{"status": "online", "busy": True}] * 4 + [{"status": "offline", "busy": False}] * 3,
                   10: [{"status": "online", "busy": True}] * 9 + [{"status": "online", "busy": False}],
                   8: [{"status": "online", "busy": True}] * 7}
        self.assertEqual(cascade.in_flight(self.GROUPS, runners.__getitem__), {LARGE: 4, SMALL: 10})

    def test_a_missing_scale_set_group_counts_nothing(self):
        self.assertIsNone(cascade.in_flight(self.GROUPS[1:], lambda group: []))

    def test_queued_comes_from_a_fresh_snapshot_only(self):
        self.assertEqual(cascade.queued(snapshot(large=3, small=1), NOW), {LARGE: 3, SMALL: 1})
        self.assertIsNone(cascade.queued(snapshot(minutes_old=cascade.QUEUE_SNAPSHOT_MINUTES + 1), NOW))
        self.assertIsNone(cascade.queued({"generated_at": "not a time", "pools": {}}, NOW))
        self.assertIsNone(cascade.queued(None, NOW))
        # A label the janitor saw nothing on has nothing queued.
        self.assertEqual(cascade.queued({"generated_at": "2026-10-19T21:58:00Z", "pools": {}}, NOW),
                         {LARGE: 0, SMALL: 0})


class Cascade(unittest.TestCase):
    def test_twelve_vcpu_first_then_six_then_the_queue(self):
        placed = cascade.cascade(CASCADED, {LARGE: 4, SMALL: 8}, {LARGE: 0, SMALL: 1})
        self.assertEqual(placed, {LARGE: ("fast-tier",), SMALL: ("swift-canary",)})

    def test_a_full_twelve_sends_the_jobs_to_six(self):
        placed = cascade.cascade(CASCADED[:2], {LARGE: 5, SMALL: 2}, {LARGE: 0, SMALL: 0})
        self.assertEqual(placed, {LARGE: (), SMALL: CASCADED[:2]})

    def test_one_run_takes_at_most_max_per_run_slots_on_a_label(self):
        # A burst of runs in one snapshot window sees the same free slots; each takes few of them.
        placed = cascade.cascade(CASCADED, {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(cascade.MAX_PER_RUN, 2)
        self.assertEqual(placed, {LARGE: ("fast-tier", "swift-canary"), SMALL: ("cmux-scheme-compile",)})

    def test_queued_jobs_take_free_slots_first(self):
        # Five free 12 vCPU slots on the runner count, but five jobs already wait for them.
        placed = cascade.cascade(CASCADED, {LARGE: 0, SMALL: 10}, {LARGE: 5, SMALL: 0})
        self.assertEqual(placed, {LARGE: (), SMALL: ()})

    def test_retry_goes_to_the_least_loaded_label(self):
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 4}, {LARGE: 6, SMALL: 3}), SMALL)
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 0}), LARGE)  # a tie
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 6, SMALL: 0}), SMALL)


class Place(unittest.TestCase):
    def test_jobs_an_idle_mini_took_and_gui_jobs_stay_off_blacksmith(self):
        result = cascade.place(env(), ("fast-tier",), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, {LARGE: ("swift-canary", "cmux-scheme-compile"), SMALL: ()})
        self.assertEqual(result.retry_runner, LARGE)

    def test_an_idle_mini_given_a_job_that_does_not_run_still_takes_one_that_does(self):
        # fast-tier is on its fast-lane runner (not in CASCADE_RUNS), yet idle_placement named it for
        # the one idle mini: that mini still takes swift-canary, and only the scheme compile pays Blacksmith.
        result = cascade.place(env(CASCADE_RUNS=" swift-canary cmux-scheme-compile "), ("fast-tier",),
                               {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, {LARGE: ("cmux-scheme-compile",), SMALL: ()})

    def test_only_jobs_that_run_on_this_route_take_a_slot(self):
        # fast-tier on its own fast-lane runner, or a canary the pull request's labels skip, spends no slot.
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), {LARGE: 4, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, {LARGE: ("cmux-scheme-compile",), SMALL: ()})
        self.assertEqual(cascade.place(env(CASCADE_RUNS=""), (), {LARGE: 0, SMALL: 0},
                                       {LARGE: 0, SMALL: 0}).jobs, {LARGE: (), SMALL: ()})
        # release-compile stays on the minis: only a mini fetches Chromium and compiles the CEF shim.
        self.assertNotIn("release-compile", cascade.CASCADE_JOBS)

    def test_a_partly_free_fleet_splits_and_leaves_the_rest_queued(self):
        result = cascade.place(env(), (), {LARGE: 4, SMALL: 9}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, {LARGE: ("fast-tier",), SMALL: ("swift-canary",)})
        self.assertIn("cmux-scheme-compile stay queued on the owned label", result.why)

    def test_unread_counts_place_nothing(self):
        self.assertEqual(cascade.place(env(), (), None, None).jobs, {LARGE: (), SMALL: ()})
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 0}, None)
        self.assertEqual(result.jobs, {LARGE: (), SMALL: ()})
        self.assertEqual(result.retry_runner, LARGE)

    def test_only_attempt_1_of_an_owned_side_label_cascades(self):
        free = {LARGE: 0, SMALL: 0}
        for overrides in ({"GITHUB_RUN_ATTEMPT": "2"}, {"SIDE_LABEL": "blacksmith-6vcpu-macos-26"}, {"SIDE_LABEL": ""}):
            with self.subTest(**overrides):
                self.assertEqual(cascade.place(env(**overrides), (), free, free).jobs, {LARGE: (), SMALL: ()})

    def test_a_skipped_run_reads_nothing(self):
        pool = mock.Mock()
        with mock.patch.object(cascade, "Api") as api:
            self.assertEqual(cascade.read(env(GITHUB_RUN_ATTEMPT="2", ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s",
                                              GITHUB_REPOSITORY="manaflow-ai/cmux"), pool, now=NOW), (None, None))
        api.assert_not_called()
        pool.GitHub.assert_not_called()

    def test_reads_fail_closed(self):
        pool = mock.Mock()
        pool.GitHub.return_value.snapshot.return_value = snapshot(large=1)
        live_env = env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s", GITHUB_REPOSITORY="manaflow-ai/cmux")
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 2, SMALL: 3}):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None),
                             ({LARGE: 2, SMALL: 3}, {LARGE: 1, SMALL: 0}))
        with mock.patch.object(cascade.Api, "in_flight", side_effect=OSError("boom")):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None), (None, None))
        pool.GitHub.return_value.snapshot.side_effect = OSError("boom")
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 2, SMALL: 3}):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None), ({LARGE: 2, SMALL: 3}, None))

    def test_the_reads_hit_the_scale_set_groups_and_the_snapshot(self):
        calls = []
        groups = {"runner_groups": [{"id": 15, "name": f"Blacksmith scale sets - {LARGE}"},
                                    {"id": 10, "name": f"Blacksmith scale sets - {SMALL}"}]}
        runners = {15: [{"status": "online"}] * 3, 10: [{"status": "online"}, {"status": "offline"}]}

        def get(_self, path):
            calls.append(path)
            if "/runner-groups?" in path:
                return groups
            return {"runners": runners[int(path.split("/runner-groups/")[1].split("/")[0])]}

        class Snapshots:
            def __init__(self, token, repository):
                self.token, self.repository = token, repository

            def snapshot(self, *, now, branch="main"):  # pr_runner_pool.GitHub.snapshot's signature
                calls.append(("snapshot", self.token, self.repository))
                return snapshot(large=2)

        pool = mock.Mock(GitHub=Snapshots)
        with mock.patch.object(cascade.Api, "_get", get):
            live, waiting = cascade.read(env(ROUTE_TOKEN="route", SNAPSHOT_TOKEN="gh",
                                             GITHUB_REPOSITORY="manaflow-ai/cmux"), pool, now=NOW)
        self.assertEqual((live, waiting), ({LARGE: 3, SMALL: 1}, {LARGE: 2, SMALL: 0}))
        self.assertEqual(calls, ["/orgs/manaflow-ai/actions/runner-groups?per_page=100&visible_to_repository=cmux",
                                 "/orgs/manaflow-ai/actions/runner-groups/15/runners?per_page=100",
                                 "/orgs/manaflow-ai/actions/runner-groups/10/runners?per_page=100",
                                 ("snapshot", "gh", "manaflow-ai/cmux")])

    def test_slow_group_reads_skip_the_snapshot(self):
        pool = mock.Mock()
        ticks = iter([0.0, cascade.READ_BUDGET_SECONDS + 1])
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 0, SMALL: 0}):
            result = cascade.read(env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s", GITHUB_REPOSITORY="manaflow-ai/cmux"),
                                  pool, now=NOW, log=lambda _: None, clock=lambda: next(ticks))
        self.assertEqual(result, ({LARGE: 0, SMALL: 0}, None))
        pool.GitHub.assert_not_called()

    def test_side_lane_placement_writes_the_cascade_outputs(self):
        runners = [{"name": "mini", "status": "online", "busy": False,
                    "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}]
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            fake = mock.Mock()
            fake.return_value.runners.return_value = runners
            with mock.patch.object(placement.pool, "GitHub", fake), \
                    mock.patch.object(placement.cascade, "read", return_value=({LARGE: 4, SMALL: 0}, {LARGE: 0, SMALL: 0})):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        # The idle mini takes the first job; 12 vCPU's one free slot the next; 6 vCPU the rest.
        self.assertEqual(lines["owned_jobs"], " fast-tier ")
        self.assertEqual(lines["blacksmith_12_jobs"], " swift-canary ")
        self.assertEqual(lines["blacksmith_6_jobs"], " cmux-scheme-compile ")
        self.assertEqual(lines["retry_runner"], SMALL)


class Wiring(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def context(self, attempt: str = "1", actor: str = "teamleaderleo", large: str = "", small: str = "",
                retry: str = "", runner: str = SIDE, fork: bool = False) -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", CI_PR_POOL_OWNED="1",
                                 CI_SIDE_LANE_RUNNER=SIDE, MACOS_RUNNER_26=LARGE)
        context["vars"].pop("MACOS_RUNNER_PR", None)
        head = "someone/cmux" if fork else "manaflow-ai/cmux"
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt, triggering_actor=actor,
                                 event={"pull_request": {"head": {"repo": {"full_name": head}},
                                                         "labels": [{"name": "full-ci"}]}})
        context["needs"] = {"macos-placement": {"outputs": {
            "runner": runner, "gui_runner": GUI if runner else "", "fallback_jobs": "",
            "blacksmith_12_jobs": large, "blacksmith_6_jobs": small, "retry_runner": retry}}}
        return context

    def test_attempt_1_takes_the_blacksmith_slot_the_placement_found(self):
        for name in CASCADED:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                self.assertEqual(evaluate(runs_on, self.context(large=f" x {name} ")), LARGE)
                self.assertEqual(evaluate(runs_on, self.context(small=f" {name} y ")), SMALL)
                # Whole keys only: another job's slot is not this job's.
                self.assertEqual(evaluate(runs_on, self.context(large=f" {name}-x ", small=f" x{name} ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context()), SIDE)
                # The bot's attempt 2 (the rescue moved a stuck sibling) keeps the slot.
                self.assertEqual(evaluate(runs_on, self.context("2", BOT, large=f" {name} ")), LARGE)
                # A person's re-run goes back to the minis first: attempt 1's count is stale by then.
                self.assertEqual(evaluate(runs_on, self.context("2", large=f" {name} ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("3", large=f" {name} ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context(fork=True, large=f" {name} ")), SMALL)

    def test_release_compile_never_cascades_but_overflows_by_the_retry_label(self):
        runs_on = self.jobs["release-compile"]["runs-on"]
        self.assertNotIn("blacksmith_12_jobs", runs_on)
        self.assertEqual(evaluate(runs_on, self.context(large=" release-compile ")), SIDE)
        self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=SMALL)), SMALL)

    def test_cascade_runs_names_only_jobs_that_run_on_this_route(self):
        place = next(step for step in self.jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["CASCADE_RUNS"]

        def runs(event="pull_request", labels=("full-ci",), fast_lane="", canary="true", scheme="true",
                 association="MEMBER", inputs=None):
            context = self.context()
            context["inputs"] = inputs or {"same_tree_sha": ""}
            context["github"]["event"]["pull_request"]["author_association"] = association
            context["github"].update(event_name=event, base_ref="feat-cmux-next",
                                     ref="refs/heads/feat-cmux-next" if event == "push" else "refs/pull/1/merge")
            context["github"]["event"]["pull_request"]["labels"] = [{"name": label} for label in labels]
            context["vars"]["CI_FAST_LANE_RUNNER"] = fast_lane
            context["needs"]["path_route"] = {"outputs": {"swift_canary": canary, "scheme": scheme}}
            return set(evaluate(expression, context).split())

        self.assertEqual(runs(), set(CASCADED))
        # An ordinary pull request (no full-ci) runs only the fast tier of these.
        self.assertEqual(runs(labels=()), {"fast-tier"})
        self.assertEqual(runs(fast_lane="glaeda-fast-std-xcode-26.6"), {"swift-canary", "cmux-scheme-compile"})
        self.assertEqual(runs("push", labels=(), canary="false"), {"fast-tier", "cmux-scheme-compile"})
        # A member's dev-build pull request compiles the scheme without full-ci; an outsider's does not.
        self.assertEqual(runs(labels=("dev-build",)), {"fast-tier", "cmux-scheme-compile"})
        self.assertEqual(runs(labels=("dev-build",), association="CONTRIBUTOR"), {"fast-tier"})
        # A same-tree dispatch asking for the scheme tier has no path routing output.
        self.assertEqual(runs("workflow_dispatch", labels=(), canary="", scheme="",
                              inputs={"same_tree_sha": "a" * 40, "same_tree_state": "ready",
                                      "same_tree_tiers": "scheme,swift"}), {"cmux-scheme-compile"})

    def test_the_bots_overflow_takes_the_placements_retry_label(self):
        for name in CASCADED:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=SMALL)), SMALL)
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=LARGE, small=f" {name} ")), LARGE)
                # No placement output: today's configured overflow.
                self.assertEqual(evaluate(runs_on, self.context("3", BOT)), LARGE)

    def test_gui_jobs_keep_their_route(self):
        for name in GUI_JOBS:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                self.assertNotIn("blacksmith_12_jobs", runs_on)
                self.assertEqual(evaluate(runs_on, self.context(large=f" {name} ", small=f" {name} ")), GUI)

    def test_each_jobs_own_label_copy_matches_runs_on(self):
        for name in CASCADED:
            job_env = self.jobs[name].get("env") or {}
            if "CMUX_NEXT_RUNNER" in job_env:
                self.assertEqual(job_env["CMUX_NEXT_RUNNER"], self.jobs[name]["runs-on"], name)

    def test_the_placement_job_reads_the_snapshot_and_exports_the_cascade(self):
        job = self.jobs["macos-placement"]
        self.assertEqual(job["permissions"].get("actions"), "read")
        place = next(step for step in job["steps"] if step.get("id") == "place")
        self.assertEqual(place["env"]["SNAPSHOT_TOKEN"], "${{ github.token }}")
        for output in ("blacksmith_12_jobs", "blacksmith_6_jobs", "retry_runner"):
            self.assertEqual(job["outputs"][output], f"${{{{ steps.place.outputs.{output} }}}}")
        self.assertEqual(set(cascade.CASCADE_JOBS), set(CASCADED))
        self.assertTrue(set(cascade.CASCADE_JOBS) <= set(place["env"]["JOBS"].split()))


if __name__ == "__main__":
    unittest.main()
