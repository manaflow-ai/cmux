#!/usr/bin/env python3
"""cmux-next's macOS cascade: idle minis, Blacksmith 12 vCPU, 6 vCPU, hosted macos-26, then the minis' queue.

The placement decides from live counts (Blacksmith's scale-set runner groups)
and the janitor's queued counts and waits; the workflow's runs-on reads its outputs.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import itertools
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts/ci"
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
LARGE, SMALL, HOSTED = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26", "macos-26"
SIDE = "glaeda-side-light-xcode-26.6"
GUI = "glaeda-gui-std-xcode-26.6"
CASCADED = ("fast-tier", "swift-canary", "cmux-scheme-compile", "release-compile")
PROMOTE = "glaeda-promote-side-trusted-std-xcode-26.6"
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


def snapshot(minutes_old: float = 2, oldest: dict | None = None, hosted: tuple[int, int] = (0, 0),
             **queued: int) -> dict:
    """A janitor snapshot; `oldest` maps "large"/"small" to oldest_queued_minutes, `hosted` is
    macos-26's (queued, running)."""
    generated = (NOW - dt.timedelta(minutes=minutes_old)).strftime("%Y-%m-%dT%H:%M:%SZ")
    oldest = oldest or {}
    return {"generated_at": generated,
            "pools": {LARGE: {"queued": queued.get("large", 0), "running": 0,
                              "oldest_queued_minutes": oldest.get("large", 0)},
                      SMALL: {"queued": queued.get("small", 0), "running": 0,
                              "oldest_queued_minutes": oldest.get("small", 0)},
                      HOSTED: {"queued": hosted[0], "running": hosted[1], "oldest_queued_minutes": 0}}}


def none_placed(**jobs: tuple) -> dict:
    return {LARGE: (), SMALL: (), HOSTED: (), **jobs}


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
        self.assertEqual(placed, none_placed(**{LARGE: ("fast-tier",), SMALL: ("swift-canary",)}))

    def test_a_full_twelve_sends_the_jobs_to_six(self):
        placed = cascade.cascade(CASCADED[:2], {LARGE: 5, SMALL: 2}, {LARGE: 0, SMALL: 0})
        self.assertEqual(placed, none_placed(**{SMALL: CASCADED[:2]}))

    def test_one_run_takes_at_most_max_per_run_slots_on_a_label(self):
        # A burst of runs in one snapshot window sees the same free slots; each takes few of them.
        placed = cascade.cascade(CASCADED, {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(cascade.MAX_PER_RUN, 2)
        self.assertEqual(placed, none_placed(**{LARGE: ("fast-tier", "swift-canary"),
                                                SMALL: ("cmux-scheme-compile", "release-compile")}))

    def test_queued_jobs_take_free_slots_first(self):
        # Five free 12 vCPU slots on the runner count, but five jobs already wait for them.
        placed = cascade.cascade(CASCADED, {LARGE: 0, SMALL: 10}, {LARGE: 5, SMALL: 0})
        self.assertEqual(placed, none_placed())

    def test_retry_goes_to_the_least_loaded_label(self):
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 4}, {LARGE: 6, SMALL: 3}), SMALL)
        # No free slot anywhere: no Blacksmith label, so the overflow waits on the owned label.
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 6, SMALL: 0}), "")
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 10}, {LARGE: 0, SMALL: 0}), LARGE)

    def test_a_full_fleet_overflows_to_6_vcpu_whose_slots_turn_over(self):
        # 2026-10-20 01:04-02:35Z: other workflows' long jobs held 12 vCPU's five slots. The
        # overflow sent 25 cmux-next jobs there by load ratio and none started (14 queued over
        # 15 minutes, up to 89, then cancelled) while 6 vCPU started 69 at a median 2.5 minutes.
        # Both full: never a Blacksmith queue (5+ hour waits on 12 vCPU, 2026-10-20); the owned label.
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 0}), "")
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 9}, {LARGE: 0, SMALL: 0}), SMALL)
        # The placement log of run 39358219316: 12 vCPU 5 + 1 of 5, 6 vCPU 10 + 4 of 10.
        self.assertEqual(cascade.retry_label({LARGE: 5, SMALL: 10}, {LARGE: 1, SMALL: 4}), "")
        self.assertEqual(cascade.retry_label({LARGE: 7, SMALL: 30}, {LARGE: 0, SMALL: 9}), "")
        # A stalled label is never the overflow, however free it looks.
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 9}, {LARGE: 0, SMALL: 0}, (LARGE,)), SMALL)
        self.assertEqual(cascade.retry_label({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, (LARGE, SMALL)), "")


class Place(unittest.TestCase):
    def test_jobs_an_idle_mini_took_and_gui_jobs_stay_off_blacksmith(self):
        result = cascade.place(env(), ("fast-tier",), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("swift-canary", "cmux-scheme-compile")}))
        # 12 vCPU is now 2 of 5 with this run's jobs, 6 vCPU 0 of 10.
        self.assertEqual(result.retry_runner, SMALL)

    def test_an_idle_mini_given_a_job_that_does_not_run_still_takes_one_that_does(self):
        # fast-tier is on its fast-lane runner (not in CASCADE_RUNS), yet idle_placement named it for
        # the one idle mini: that mini still takes swift-canary, and only the scheme compile pays Blacksmith.
        result = cascade.place(env(CASCADE_RUNS=" swift-canary cmux-scheme-compile "), ("fast-tier",),
                               {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))

    def test_only_jobs_that_run_on_this_route_take_a_slot(self):
        # fast-tier on its own fast-lane runner, or a canary the pull request's labels skip, spends no slot.
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), {LARGE: 4, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        self.assertEqual(cascade.place(env(CASCADE_RUNS=""), (), {LARGE: 0, SMALL: 0},
                                       {LARGE: 0, SMALL: 0}).jobs, none_placed())
        # A Release compile that does not run (a same-repository PR without full-ci) takes no slot either.
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), {LARGE: 0, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertNotIn("release-compile", result.jobs[LARGE] + result.jobs[SMALL])

    def test_a_release_compile_no_idle_mini_took_overflows_to_blacksmith(self):
        """2026-10-21 ~20:10Z: 76 Release compiles queued on the minis. The CEF shim check it skips off a
        mini is advisory (a Blacksmith re-run already skips it)."""
        self.assertIn("release-compile", cascade.CASCADE_JOBS)
        self.assertNotIn("release-compile", cascade.HOSTED_JOBS)
        runs = " swift-canary cmux-scheme-compile release-compile "
        result = cascade.place(env(CASCADE_RUNS=runs), (), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("swift-canary", "cmux-scheme-compile"),
                                                     SMALL: ("release-compile",)}))
        # Two idle minis take the canary and the scheme compile; the Release compile gets 12 vCPU.
        result = cascade.place(env(CASCADE_RUNS=runs), ("fast-tier", "swift-canary"), {LARGE: 0, SMALL: 0},
                               {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("release-compile",)}))

    def test_a_feat_push_release_compile_keeps_an_idle_promotion_mini(self):
        # Attempt 1 of a feat-cmux-next push compiles on vars.CI_NEXT_PROMOTE_POOL; while one of its
        # runners is idle the Release compile stays there and takes no side mini's share or Blacksmith slot.
        runs = " cmux-scheme-compile release-compile "
        free = {LARGE: 0, SMALL: 0}
        idle = cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), (), free, free, promote_busy=False)
        self.assertEqual(idle.jobs, none_placed(**{LARGE: ("cmux-scheme-compile",)}))
        # One idle side mini takes the scheme compile, not the promoted Release compile's turn.
        self.assertEqual(cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), ("fast-tier",), free, free,
                                       promote_busy=False).jobs, none_placed())

    def test_a_feat_push_release_compile_takes_the_runs_first_slot(self):
        # Run 40298786351 (2026-10-26 09:21Z): 6 vCPU had room, but MAX_PER_RUN went to fast-tier and the
        # scheme compile ahead of it in JOBS, and the Release compile queued on the owned label.
        runs = " fast-tier cmux-scheme-compile release-compile "
        live, waiting = {LARGE: 0, SMALL: 5}, {LARGE: 7, SMALL: 0}
        stalled = cascade.Seen(waits={LARGE: 227.0}, age=1.0, hosted=18)
        before = cascade.place(env(CASCADE_RUNS=runs), (), live, waiting, stalled)
        self.assertEqual(before.jobs[SMALL], ("fast-tier", "cmux-scheme-compile"))
        first = env(CASCADE_RUNS=runs, FIRST_JOBS="release-compile")
        self.assertEqual(cascade.place(first, (), live, waiting, stalled).jobs[SMALL], ("release-compile", "fast-tier"))
        # The idle minis are spent on the run's other jobs first: one idle mini, and the Release compile still
        # has its slot (fast-tier races for the mini); as many idle minis as side jobs, and nothing cascades.
        one = cascade.place(first, ("fast-tier",), live, waiting, stalled)
        self.assertEqual(one.jobs[SMALL], ("release-compile", "cmux-scheme-compile"))
        three = cascade.place(first, ("fast-tier", "swift-canary", "cmux-scheme-compile"), live, waiting, stalled)
        self.assertEqual(three.jobs, none_placed())
        two = cascade.place(first, ("fast-tier", "swift-canary"), live, waiting, stalled)
        self.assertEqual(two.jobs[SMALL], ("release-compile",))

    def test_the_placement_names_the_first_jobs_only_on_a_feat_push_attempt_1(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        place = next(step for step in jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["FIRST_JOBS"]
        for event, ref, attempt, expected in (("push", "refs/heads/feat-cmux-next", "1", "release-compile"),
                                              ("push", "refs/heads/feat-cmux-next", "2", ""),
                                              ("push", "refs/heads/next-batch/abc", "1", ""),
                                              ("pull_request", "refs/pull/1/merge", "1", "")):
            with self.subTest(event=event, ref=ref, attempt=attempt):
                context = {"github": {"event_name": event, "ref": ref, "run_attempt": attempt}}
                self.assertEqual(evaluate(expression, context), expected)

    def test_a_busy_promotion_mini_sends_the_feat_push_release_compile_to_blacksmith_first(self):
        runs = " swift-canary cmux-scheme-compile release-compile "
        free = {LARGE: 0, SMALL: 0}
        busy = cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), (), free, free, promote_busy=True)
        # It gates the nightly-next request, so it goes first; it never counts against an idle side mini.
        self.assertEqual(busy.jobs, none_placed(**{LARGE: ("release-compile", "swift-canary"),
                                                   SMALL: ("cmux-scheme-compile",)}))
        busy = cascade.place(env(CASCADE_RUNS=runs, PROMOTE_LABEL=PROMOTE), ("fast-tier", "swift-canary", "x"),
                             free, free, promote_busy=True)
        self.assertEqual(busy.jobs, none_placed(**{LARGE: ("release-compile",)}))

    def test_a_partly_free_fleet_splits_and_leaves_the_rest_queued(self):
        result = cascade.place(env(), (), {LARGE: 4, SMALL: 9}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("fast-tier",), SMALL: ("swift-canary",)}))
        self.assertIn("cmux-scheme-compile stay queued on the owned label", result.why)

    def test_the_overflow_counts_the_slots_this_run_just_took(self):
        # 6 vCPU had one free slot and this run's fast-tier took it: the overflow has none left.
        result = cascade.place(env(), (), {LARGE: 5, SMALL: 9}, {LARGE: 0, SMALL: 0})
        self.assertEqual(result.jobs, none_placed(**{SMALL: ("fast-tier",)}))
        self.assertEqual(result.retry_runner, "")

    def test_unread_counts_place_nothing(self):
        self.assertEqual(cascade.place(env(), (), None, None).jobs, none_placed())
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 0}, None)
        self.assertEqual(result.jobs, none_placed())
        # Without the queue count no slot is known free: the overflow keeps the owned label.
        self.assertEqual(result.retry_runner, "")

    def test_only_attempt_1_of_an_owned_side_label_cascades(self):
        free = {LARGE: 0, SMALL: 0}
        for overrides in ({"GITHUB_RUN_ATTEMPT": "2"}, {"SIDE_LABEL": "blacksmith-6vcpu-macos-26"}, {"SIDE_LABEL": ""}):
            with self.subTest(**overrides):
                self.assertEqual(cascade.place(env(**overrides), (), free, free).jobs, none_placed())

    def test_a_skipped_run_reads_nothing(self):
        pool = mock.Mock()
        with mock.patch.object(cascade, "Api") as api:
            self.assertEqual(cascade.read(env(GITHUB_RUN_ATTEMPT="2", ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s",
                                              GITHUB_REPOSITORY="manaflow-ai/cmux"), pool, now=NOW), (None, None, None))
        api.assert_not_called()
        pool.GitHub.assert_not_called()

    def test_reads_fail_closed(self):
        pool = mock.Mock()
        pool.GitHub.return_value.snapshot.return_value = snapshot(large=1, oldest={"large": 3})
        live_env = env(ROUTE_TOKEN="t", SNAPSHOT_TOKEN="s", GITHUB_REPOSITORY="manaflow-ai/cmux")
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 2, SMALL: 3}):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None),
                             ({LARGE: 2, SMALL: 3}, {LARGE: 1, SMALL: 0},
                              cascade.Seen(waits={LARGE: 5.0, SMALL: 0.0}, hosted=0, age=2.0)))
        with mock.patch.object(cascade.Api, "in_flight", side_effect=OSError("boom")):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None), (None, None, None))
        pool.GitHub.return_value.snapshot.side_effect = OSError("boom")
        with mock.patch.object(cascade.Api, "in_flight", return_value={LARGE: 2, SMALL: 3}):
            self.assertEqual(cascade.read(live_env, pool, now=NOW, log=lambda _: None),
                             ({LARGE: 2, SMALL: 3}, None, None))

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
            live, waiting, seen = cascade.read(env(ROUTE_TOKEN="route", SNAPSHOT_TOKEN="gh",
                                                   GITHUB_REPOSITORY="manaflow-ai/cmux"), pool, now=NOW)
        self.assertEqual((live, waiting), ({LARGE: 3, SMALL: 1}, {LARGE: 2, SMALL: 0}))
        self.assertEqual(seen, cascade.Seen(waits={LARGE: 2.0, SMALL: 0.0}, hosted=0, age=2.0))
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
        self.assertEqual(result, ({LARGE: 0, SMALL: 0}, None, None))
        pool.GitHub.assert_not_called()

    def test_side_lane_placement_writes_the_cascade_outputs(self):
        runners = [{"name": "mini", "status": "online", "busy": False,
                    "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}]
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            fake = mock.Mock()
            fake.return_value.runners.return_value = runners
            with mock.patch.object(placement.pool, "GitHub", fake), \
                    mock.patch.object(placement.cascade, "read",
                                      return_value=({LARGE: 4, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)):
                placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output)))
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        # The idle mini takes the first job; 12 vCPU's one free slot the next; 6 vCPU the rest.
        self.assertEqual(lines["owned_jobs"], " fast-tier ")
        self.assertEqual(lines["blacksmith_12_jobs"], " swift-canary ")
        self.assertEqual(lines["blacksmith_6_jobs"], " cmux-scheme-compile ")
        self.assertEqual(lines["retry_runner"], SMALL)
        self.assertEqual((lines["hosted_jobs"], lines["hosted_runner"]), ("", ""))

    def test_side_lane_placement_reads_the_promotion_minis_load(self):
        side = {"name": "side-mini", "status": "online", "busy": True,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}

        def outputs(promote_busy: bool | None, **extra: str) -> dict:
            runners = [side]
            if promote_busy is not None:
                runners.append({"name": "cmux14-glaeda", "status": "online", "busy": promote_busy,
                                "labels": [{"name": label} for label in
                                           ("self-hosted", "glaeda-promote-trusted-std-xcode-26.6", PROMOTE)]})
            with tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                fake = mock.Mock()
                fake.return_value.runners.return_value = runners
                with mock.patch.object(placement.pool, "GitHub", fake), \
                        mock.patch.object(placement.cascade, "read",
                                          return_value=({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)):
                    placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux", GITHUB_OUTPUT=str(output),
                                       CASCADE_RUNS=" release-compile ", **extra))
                return dict(line.split("=", 1) for line in output.read_text().splitlines())

        # A feat-cmux-next push (PROMOTE_LABEL set) with the promotion mini busy: Blacksmith 12 vCPU.
        self.assertEqual(outputs(True, PROMOTE_LABEL=PROMOTE)["blacksmith_12_jobs"], " release-compile ")
        # No online promotion runner at all (the mini is down) overflows the same way.
        self.assertEqual(outputs(None, PROMOTE_LABEL=PROMOTE)["blacksmith_12_jobs"], " release-compile ")
        # An idle promotion mini keeps it.
        self.assertEqual(outputs(False, PROMOTE_LABEL=PROMOTE)["blacksmith_12_jobs"], "")
        # Any other run (no promotion label) cascades it as a side job: the side mini is busy.
        self.assertEqual(outputs(False)["blacksmith_12_jobs"], " release-compile ")

    def test_dedicated_nightly_builder_gets_release_compile_before_blacksmith(self):
        side = {"name": "side-mini", "status": "online", "busy": True,
                "labels": [{"name": label} for label in ("self-hosted", "glaeda-light-xcode-26.6", SIDE)]}
        dedicated = {"name": "cmux22", "status": "online", "busy": False,
                     "labels": [{"name": label} for label in
                                ("self-hosted", "glaeda-trusted-light-xcode-26.6",
                                 "glaeda-runner-cmux22-nightly-next", "glaeda-trusted-next-nightly")]}

        def run(busy: bool):
            dedicated_copy = {**dedicated, "busy": busy}
            with tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "out"
                fake = mock.Mock()
                fake.return_value.runners.return_value = [side, dedicated_copy]
                with mock.patch.object(placement.pool, "GitHub", fake), \
                        mock.patch.object(placement.cascade, "read",
                                          return_value=({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, None)):
                    placement.main(env(ROUTE_TOKEN="t", GITHUB_REPOSITORY="manaflow-ai/cmux",
                                       GITHUB_OUTPUT=str(output), CASCADE_RUNS=" release-compile ",
                                       PROMOTE_LABEL=PROMOTE,
                                       NIGHTLY_POOL="glaeda-trusted-light-xcode-26.6",
                                       NIGHTLY_RUNNER="glaeda-runner-cmux22-nightly-next"))
                return dict(line.split("=", 1) for line in output.read_text().splitlines())

        ready = run(False)
        self.assertEqual(ready["nightly_runner_ready"], "true")
        self.assertEqual(ready["blacksmith_12_jobs"], "")
        overflow = run(True)
        self.assertEqual(overflow["nightly_runner_ready"], "")
        self.assertEqual(overflow["blacksmith_12_jobs"], " release-compile ")


class Stall(unittest.TestCase):
    """A Blacksmith label whose queue is not moving gets no job; hosted macos-26 takes the overflow."""

    # Run 39409184395's placement, 2026-10-20 10:38Z, during Blacksmith's macOS start delay:
    # neither label had a runner online, 12 vCPU's oldest queued job had waited 41 min,
    # and the cascade still sent fast-tier to 12 vCPU, where it never started.
    INCIDENT_LIVE = {LARGE: 0, SMALL: 0}
    INCIDENT_QUEUED = {LARGE: 4, SMALL: 6}

    def incident_seen(self, hosted: int = 0):
        return cascade.Seen(waits={LARGE: 46.0, SMALL: 13.0}, hosted=hosted)

    def test_seen_reads_each_labels_wait_by_now_and_the_hosted_load(self):
        shot = snapshot(5, oldest={"large": 41, "small": 8}, hosted=(1, 2), large=3, small=6)
        shot["pools"]["macos-15"] = {"queued": 0, "running": 1}
        shot["pools"]["blacksmith-6vcpu-macos-15"] = {"queued": 4, "running": 3}
        seen = cascade.seen(shot, NOW)
        # The oldest job has waited the snapshot's age longer by now; every hosted macOS pool counts.
        self.assertEqual(seen, cascade.Seen(waits={LARGE: 46.0, SMALL: 13.0}, hosted=4, age=5.0))
        # An empty queue has no wait, whatever a stale oldest field says.
        self.assertEqual(cascade.seen(snapshot(5, oldest={"large": 41}), NOW).waits, {LARGE: 0.0, SMALL: 0.0})
        self.assertIsNone(cascade.seen(snapshot(minutes_old=cascade.QUEUE_SNAPSHOT_MINUTES + 1), NOW))
        self.assertIsNone(cascade.seen(None, NOW))

    def test_a_long_wait_or_an_unserved_queue_is_a_stall(self):
        self.assertEqual(cascade.stalled(self.INCIDENT_LIVE, self.INCIDENT_QUEUED, self.incident_seen().waits),
                         (LARGE, SMALL))
        # Busy but moving: jobs start within minutes.
        self.assertEqual(cascade.stalled({LARGE: 5, SMALL: 3}, {LARGE: 1, SMALL: 1}, {LARGE: 10.0, SMALL: 3.0}), ())
        # A queue nobody serves for IDLE_STALL_MINUTES is a stall even before STALL_MINUTES.
        idle = cascade.IDLE_STALL_MINUTES
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 2}, {LARGE: 1, SMALL: 1},
                                         {LARGE: float(idle), SMALL: float(idle)}), (LARGE,))
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 0}, {LARGE: 1, SMALL: 0},
                                         {LARGE: idle - 1.0, SMALL: 0.0}), ())
        # An idle scale set has no runner online: a job the snapshot saw queued only briefly
        # is not a stall however old the snapshot is (it may have run since).
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 0}, {LARGE: 1, SMALL: 0},
                                         {LARGE: 12.0, SMALL: 0.0}, age=10.0), ())
        # A runner online does not excuse a queue that has waited STALL_MINUTES.
        self.assertEqual(cascade.stalled({LARGE: 3, SMALL: 0}, {LARGE: 1, SMALL: 0},
                                         {LARGE: float(cascade.STALL_MINUTES), SMALL: 0.0}), (LARGE,))
        # Nothing queued is never a stall.
        self.assertEqual(cascade.stalled({LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0}, {LARGE: 90.0, SMALL: 90.0}), ())

    def test_the_incident_sends_nothing_to_blacksmith_and_the_overflow_to_hosted(self):
        result = cascade.place(env(), (), self.INCIDENT_LIVE, self.INCIDENT_QUEUED, self.incident_seen())
        self.assertEqual(result.jobs, none_placed(**{HOSTED: ("fast-tier", "swift-canary")}))
        # The scheme compile keeps the minis' queue: a cold full app compile on a 3 vCPU hosted runner
        # is not measured against its 60 min budget and launch-time gate.
        self.assertIn("cmux-scheme-compile stay queued on the owned label", result.why)
        self.assertIn("stalled", result.why)

    def test_hosted_takes_only_what_blacksmith_cannot(self):
        # Free, moving Blacksmith slots come first.
        result = cascade.place(env(), (), {LARGE: 0, SMALL: 0}, {LARGE: 0, SMALL: 0},
                               cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0}, hosted=0))
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("fast-tier", "swift-canary"),
                                                     SMALL: ("cmux-scheme-compile",)}))
        # A full but moving fleet overflows to hosted too: hosted must not sit idle while Blacksmith queues.
        result = cascade.place(env(), (), {LARGE: 5, SMALL: 10}, {LARGE: 0, SMALL: 0},
                               cascade.Seen(waits={LARGE: 0.0, SMALL: 0.0}, hosted=0))
        self.assertEqual(result.jobs, none_placed(**{HOSTED: ("fast-tier", "swift-canary")}))

    def test_hosted_keeps_to_its_concurrency(self):
        free_one = cascade.place(env(), (), self.INCIDENT_LIVE, self.INCIDENT_QUEUED,
                                 self.incident_seen(hosted=cascade.HOSTED_CAPACITY - 1))
        self.assertEqual(free_one.jobs, none_placed(**{HOSTED: ("fast-tier",)}))
        full = cascade.place(env(), (), self.INCIDENT_LIVE, self.INCIDENT_QUEUED,
                             self.incident_seen(hosted=cascade.HOSTED_CAPACITY))
        self.assertEqual(full.jobs, none_placed())

    def test_hosted_takes_only_jobs_that_pin_nothing_it_lacks(self):
        self.assertEqual(set(cascade.HOSTED_JOBS), {"fast-tier", "swift-canary"})
        self.assertTrue(set(cascade.HOSTED_JOBS) <= set(cascade.CASCADE_JOBS))
        result = cascade.place(env(CASCADE_RUNS=" cmux-scheme-compile "), (), self.INCIDENT_LIVE,
                               self.INCIDENT_QUEUED, self.incident_seen())
        self.assertEqual(result.jobs, none_placed())

    def test_without_the_snapshots_waits_nothing_changes(self):
        # Fail toward the current behavior: no stall known, no hosted spill.
        result = cascade.place(env(), (), {LARGE: 4, SMALL: 10}, {LARGE: 0, SMALL: 0}, None)
        self.assertEqual(result.jobs, none_placed(**{LARGE: ("fast-tier",)}))

    def test_the_bots_overflow_avoids_a_stalled_label(self):
        live, waiting = {LARGE: 0, SMALL: 9}, {LARGE: 1, SMALL: 0}
        self.assertEqual(cascade.retry_label(live, waiting), LARGE)
        seen = cascade.Seen(waits={LARGE: 30.0, SMALL: 0.0}, hosted=0)
        self.assertEqual(cascade.place(env(), (), {LARGE: 0, SMALL: 5}, waiting, seen).retry_runner, SMALL)
        # The one free 6 vCPU slot goes to this run's fast-tier, so no label is left for the overflow.
        self.assertEqual(cascade.place(env(), (), live, waiting, seen).retry_runner, "")
        # Both stalled: no Blacksmith label; the overflow waits on the owned label.
        both = cascade.Seen(waits={LARGE: 30.0, SMALL: 30.0}, hosted=0)
        self.assertEqual(cascade.place(env(), (), live, {LARGE: 1, SMALL: 1}, both).retry_runner, "")

    def test_only_the_hosted_jobs_read_the_hosted_route_and_get_more_time(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        readers = {name for name, job in jobs.items() if "outputs.hosted_runner" in str(job.get("runs-on", ""))}
        self.assertEqual(readers, {"fast-tier", "swift-canary"})
        # Their runs-on, and swift-canary's CMUX_NEXT_RUNNER copy of it: no other job reads the hosted label.
        self.assertEqual(WORKFLOW.read_text(encoding="utf-8").count("needs.macos-placement.outputs.hosted_runner"), 3)
        for name in readers:
            with self.subTest(job=name):
                timeout = jobs[name]["timeout-minutes"]
                hosted = {"needs": {"macos-placement": {"outputs": {"hosted_jobs": f" {name} "}}}}
                self.assertEqual(evaluate(timeout, hosted), 45)
                self.assertEqual(evaluate(timeout, {"needs": {"macos-placement": {"outputs": {"hosted_jobs": ""}}}}), 20)

    def test_the_placement_writes_the_hosted_route(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            placed = cascade.place(env(), (), self.INCIDENT_LIVE, self.INCIDENT_QUEUED, self.incident_seen())
            cascade.write(placed, {"GITHUB_OUTPUT": str(output)})
            lines = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(lines["hosted_jobs"], " fast-tier swift-canary ")
        self.assertEqual(lines["hosted_runner"], HOSTED)
        self.assertEqual((lines["blacksmith_12_jobs"], lines["blacksmith_6_jobs"]), ("", ""))


class Wiring(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]

    def context(self, attempt: str = "1", actor: str = "teamleaderleo", large: str = "", small: str = "",
                retry: str = "", runner: str = SIDE, fork: bool = False, hosted: str = "") -> dict:
        context = github_context("pull_request", ref="refs/pull/1/merge", CI_PR_POOL_OWNED="1",
                                 CI_SIDE_LANE_RUNNER=SIDE, MACOS_RUNNER_26=LARGE)
        context["vars"].pop("MACOS_RUNNER_PR", None)
        head = "someone/cmux" if fork else "manaflow-ai/cmux"
        context["github"].update(repository="manaflow-ai/cmux", run_attempt=attempt, triggering_actor=actor,
                                 event={"pull_request": {"head": {"repo": {"full_name": head}},
                                                         "labels": [{"name": "full-ci"}]}})
        context["needs"] = {"macos-placement": {"outputs": {
            "runner": runner, "gui_runner": GUI if runner else "", "fallback_jobs": "",
            "blacksmith_12_jobs": large, "blacksmith_6_jobs": small, "retry_runner": retry,
            "hosted_jobs": hosted, "hosted_runner": HOSTED if hosted else ""}}}
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

    def test_attempt_1_takes_the_hosted_spill_the_placement_chose(self):
        for name in CASCADED:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                spilled = HOSTED if name in cascade.HOSTED_JOBS else SIDE
                self.assertEqual(evaluate(runs_on, self.context(hosted=f" x {name} ")), spilled)
                self.assertEqual(evaluate(runs_on, self.context(hosted=f" {name}-x ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("2", BOT, hosted=f" {name} ")), spilled)
                # A person's re-run and the bot's overflow attempt do not reuse attempt 1's spill.
                self.assertEqual(evaluate(runs_on, self.context("2", hosted=f" {name} ")), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=SMALL, hosted=f" {name} ")), SMALL)
                # A fork keeps its own route.
                self.assertEqual(evaluate(runs_on, self.context(fork=True, hosted=f" {name} ")), SMALL)

    def test_a_feat_push_release_compile_uses_a_free_fleet_mac_then_blacksmith(self):
        runs_on = self.jobs["release-compile"]["runs-on"]

        def push(**outputs: str) -> dict:
            context = self.context(**outputs)
            context["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
            context["github"]["event"] = {}
            context["vars"]["CI_NEXT_PROMOTE_POOL"] = PROMOTE
            return context

        # An idle owned Mac wins: the cascade then gives the compile no Blacksmith slot and it takes the
        # owned label. The cascade places it on Blacksmith only when no idle mini took it, so its slot comes
        # before the owned label, which is then a queue (2026-10-26: 10-40 min on the std side label).
        self.assertEqual(evaluate(runs_on, push(runner="free-owned-mac")), "free-owned-mac")
        self.assertEqual(evaluate(runs_on, push()), SIDE)
        self.assertEqual(evaluate(runs_on, push(runner="")), SMALL)
        self.assertEqual(evaluate(runs_on, push(large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, push(small=" release-compile ")), SMALL)
        self.assertEqual(evaluate(runs_on, push(runner="", large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, push(runner="", small=" release-compile ")), SMALL)
        # Another job's slot is not the Release compile's.
        self.assertEqual(evaluate(runs_on, push(large=" cmux-scheme-compile ")), SIDE)
        # A re-run of the push does not reuse attempt 1's slot.
        rerun = push(large=" release-compile ")
        rerun["github"]["run_attempt"] = "2"
        self.assertEqual(evaluate(runs_on, rerun), SIDE)
        # The job's own label variable agrees with its runs-on.
        runner_env = self.jobs["release-compile"]["env"]["CMUX_NEXT_RUNNER"]
        for outputs in ({}, {"large": " release-compile "}, {"small": " release-compile "}, {"runner": ""}):
            self.assertEqual(evaluate(runner_env, push(**outputs)), evaluate(runs_on, push(**outputs)))
        self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=SMALL)), SMALL)
        # Release compile never targets the dedicated nightly runner.
        self.assertNotIn("CI_NIGHTLY_NEXT_TRUSTED_RUNNER", self.jobs["release-compile"]["runs-on"])
        self.assertNotIn("CI_NIGHTLY_NEXT_TRUSTED_RUNNER", self.jobs["release-compile"]["env"]["CMUX_NEXT_RUNNER"])

    NIGHTLY_POOL = "glaeda-trusted-light-xcode-26.6"
    NIGHTLY_RUNNER = "glaeda-runner-cmux22-nightly-next"

    # The events release-compile runs on: a push to either branch, a dispatch, and a same-repo or fork pull request.
    EVENTS = (("push", "refs/heads/feat-cmux-next", False), ("push", "refs/heads/main", False),
              ("workflow_dispatch", "refs/heads/feat-cmux-next", False), ("pull_request", "refs/pull/1/merge", False),
              ("pull_request", "refs/pull/1/merge", True))

    def nightly_push(self, ready: str, attempt: str = "1", fast: tuple[str, str] = ("skipped", ""),
                     event: tuple[str, str, bool] = EVENTS[0], actor: str = "teamleaderleo", config: str = "owned",
                     **outputs: str) -> dict:
        name, ref, fork = event
        context = self.context(attempt, actor, fork=fork, **outputs)
        if config == "another owner":
            context["github"]["repository_owner"] = "someone"
        elif config == "pool not owned":
            context["vars"].pop("CI_PR_POOL_OWNED")
        elif config == "no side route":
            context["vars"].update(CI_SIDE_LANE_RUNNER="", MACOS_RUNNER_26="")
        # The fleet fast check: skipped (no idle gateway), no verdict, or an unavailable fleet.
        context["needs"]["release-compile-fast"] = {"result": fast[0], "outputs": {"verdict": fast[1]}}
        context["github"].update(event_name=name, ref=ref)
        if name != "pull_request":
            context["github"]["event"] = {}
        context["vars"].update(CI_NIGHTLY_NEXT_TRUSTED_POOL=self.NIGHTLY_POOL,
                               CI_NIGHTLY_NEXT_TRUSTED_RUNNER=self.NIGHTLY_RUNNER, CI_NEXT_PROMOTE_POOL=PROMOTE)
        # The job sees placement's step outputs through the workflow's own `outputs:` mapping, evaluated here,
        # so a mapping that names a nightly variable reaches the runs-on.
        placed = dict(context["needs"]["macos-placement"]["outputs"], nightly_runner_ready=ready)
        mapping = self.jobs["macos-placement"]["outputs"]
        step = {}
        for key, expression in mapping.items():
            match = re.fullmatch(r"\$\{\{ steps\.place\.outputs\.(\w+) \}\}", expression)
            if match:
                step[match.group(1)] = placed.get(key, "")
        scope = dict(context, steps={"place": {"outputs": step}})
        context["needs"]["macos-placement"]["outputs"] = {key: evaluate(expression, scope)
                                                          for key, expression in mapping.items()}
        if config == "placement skipped":
            context["needs"]["macos-placement"] = {"result": "skipped", "outputs": {}}
        return context

    def off_the_nightly_runner(self, label) -> bool:
        """`label` (a runs-on value: one label, or a list every runner must carry) is set and names no nightly label."""
        labels = label if isinstance(label, list) else [label]
        return bool(labels) and all(isinstance(name, str) and name and name not in (self.NIGHTLY_POOL, self.NIGHTLY_RUNNER)
                                    and "nightly" not in name for name in labels)

    CONFIGS = ("owned", "another owner", "pool not owned", "no side route", "placement skipped")

    def test_release_compile_never_targets_the_dedicated_nightly_runner(self):
        """The nightly runner builds and signs nightly-next; the Release compile that gates it never takes it,
        whatever placement read about it. The runs-on and the job's own label variable are evaluated, as a
        single label or a label list, on every event the workflow runs on, for every attempt, owner and pool
        configuration, fast-check state and placement output it can see."""
        job = self.jobs["release-compile"]
        seen = {event: set() for event in self.EVENTS}
        failures = []
        attempts = (("1", "teamleaderleo"), ("2", "teamleaderleo"), ("2", BOT), ("3", "teamleaderleo"), ("3", BOT),
                    ("4", BOT))
        # Every fast-check state release-compile runs after: skipped, no verdict (failed, or the
        # continue-on-error step left success with none), or an unavailable fleet.
        fasts = (("skipped", ""), ("failure", ""), ("success", ""), ("success", "unavailable"),
                 ("failure", "unavailable"))
        placed = ({}, {"runner": ""}, {"large": " release-compile "}, {"small": " release-compile "}, {"retry": SMALL})
        for event, config, ready, (attempt, actor), fast, outputs in itertools.product(
                self.EVENTS, self.CONFIGS, ("true", ""), attempts, fasts, placed):
            context = self.nightly_push(ready, attempt, fast, event, actor, config, **outputs)
            label = evaluate(job["runs-on"], context)
            if config == "owned" and attempt in ("1", "2"):
                seen[event].add(tuple(label) if isinstance(label, list) else label)
            for name, value in (("runs-on", label), ("CMUX_NEXT_RUNNER", evaluate(job["env"]["CMUX_NEXT_RUNNER"],
                                                                                   context))):
                if not self.off_the_nightly_runner(value):
                    failures.append(f"{name}={value!r}: {event} {config} ready={ready!r} attempt={attempt} {actor} "
                                    f"fast={fast} outputs={outputs}")
        self.assertEqual(failures[:10], [], f"{len(failures)} cases name the nightly runner")
        # Every route each event can take was evaluated: the cascade's two slots and the owned side label
        # (a feat push also takes 6 vCPU with no placement runner, or a fast check that died before its
        # verdict); a fork pull request takes 6 vCPU only. side_lane_placement never writes a nightly label
        # into the runner outputs (test_ci_side_lane_placement.NightlyRunnerStaysOffTheRoutes).
        for event in self.EVENTS:
            self.assertEqual(seen[event], {SMALL} if event[2] else {LARGE, SMALL, SIDE}, event)
        self.assertEqual(evaluate(job["runs-on"], self.nightly_push("", fast=("failure", ""))), SMALL)

    def test_a_configured_but_unavailable_dedicated_runner_overflows_to_blacksmith(self):
        # Dedicated runner configured but not ready: the Blacksmith slot placement gave, else the owned route.
        runs_on = self.jobs["release-compile"]["runs-on"]
        self.assertEqual(evaluate(runs_on, self.nightly_push("", large=" release-compile ")), LARGE)
        self.assertEqual(evaluate(runs_on, self.nightly_push("", small=" release-compile ")), SMALL)
        self.assertEqual(evaluate(runs_on, self.nightly_push("")), SIDE)
        self.assertEqual(evaluate(runs_on, self.nightly_push("", runner="")), SMALL)

    def test_the_placement_knows_the_promotion_label_only_on_a_feat_push(self):
        place = next(step for step in self.jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["PROMOTE_LABEL"]
        context = self.context()
        context["vars"]["CI_NEXT_PROMOTE_POOL"] = PROMOTE
        self.assertEqual(evaluate(expression, context), "")
        context["github"].update(event_name="push", ref="refs/heads/feat-cmux-next")
        self.assertEqual(evaluate(expression, context), PROMOTE)
        context["github"].update(ref="refs/heads/next-batch/abc")
        self.assertEqual(evaluate(expression, context), "")
        context["github"].update(ref="refs/heads/feat-cmux-next", run_attempt="2")
        self.assertEqual(evaluate(expression, context), "")

    def test_cascade_runs_names_only_jobs_that_run_on_this_route(self):
        place = next(step for step in self.jobs["macos-placement"]["steps"] if step.get("id") == "place")
        expression = place["env"]["CASCADE_RUNS"]

        def runs(event="pull_request", labels=("full-ci",), fast_lane="", canary="true", scheme="true",
                 association="MEMBER", inputs=None, native="true"):
            context = self.context()
            context["inputs"] = inputs or {"same_tree_sha": ""}
            context["github"]["event"]["pull_request"]["author_association"] = association
            context["github"].update(event_name=event, base_ref="feat-cmux-next",
                                     ref="refs/heads/feat-cmux-next" if event == "push" else "refs/pull/1/merge")
            context["github"]["event"]["pull_request"]["labels"] = [{"name": label} for label in labels]
            context["vars"]["CI_FAST_LANE_RUNNER"] = fast_lane
            context["needs"]["path_route"] = {"outputs": {"swift_canary": canary, "scheme": scheme, "native": native}}
            return set(evaluate(expression, context).split())

        self.assertEqual(runs(), set(CASCADED))
        self.assertEqual(runs(native="false"), set(CASCADED) - {"release-compile"})
        # A same-repository pull request runs its routed canary with no label (#22303); the two heavy
        # compiles need full-ci again, except a member's dev-build scheme compile (its dogfood app).
        self.assertEqual(runs(labels=()), {"fast-tier", "swift-canary"})
        self.assertEqual(runs(labels=(), canary="false", scheme="false"), {"fast-tier"})
        # The fast lane's label is a preference the placement takes only while it is idle
        # (side_lane_placement.fast_route()), so the fast tier is always a cascade candidate.
        self.assertEqual(runs(fast_lane="glaeda-fast-std-xcode-26.6"), set(CASCADED))
        self.assertEqual(runs("push", labels=(), canary="false"), {"fast-tier", "cmux-scheme-compile", "release-compile"})
        self.assertEqual(runs(labels=("dev-build",), association="CONTRIBUTOR"), {"fast-tier", "swift-canary"})
        self.assertEqual(runs(labels=("dev-build",)), {"fast-tier", "swift-canary", "cmux-scheme-compile"})
        # A same-tree dispatch asking for the scheme tier has no path routing output.
        self.assertEqual(runs("workflow_dispatch", labels=(), canary="", scheme="", native="",
                              inputs={"same_tree_sha": "a" * 40, "same_tree_state": "ready",
                                      "same_tree_tiers": "scheme,swift"}), {"cmux-scheme-compile"})

    def test_the_bots_overflow_takes_the_placements_retry_label(self):
        for name in CASCADED:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=SMALL)), SMALL)
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry=LARGE, small=f" {name} ")), LARGE)
                # No free slot (an empty label), or no placement output: the owned side label, never
                # vars.MACOS_RUNNER_26, a Blacksmith label with no free-slot check.
                self.assertEqual(evaluate(runs_on, self.context("3", BOT)), SIDE)
                self.assertEqual(evaluate(runs_on, self.context("3", BOT, retry="")), SIDE)

    def test_gui_jobs_keep_their_route(self):
        for name in GUI_JOBS:
            runs_on = self.jobs[name]["runs-on"]
            with self.subTest(job=name):
                self.assertNotIn("blacksmith_12_jobs", runs_on)
                self.assertEqual(evaluate(runs_on, self.context(large=f" {name} ", small=f" {name} ")), GUI)

    def test_each_jobs_own_label_copy_matches_runs_on(self):
        for name in CASCADED:
            job_env = self.jobs[name].get("env") or {}
            if "CMUX_NEXT_RUNNER" in job_env and name != "release-compile":
                self.assertEqual(job_env["CMUX_NEXT_RUNNER"], self.jobs[name]["runs-on"], name)

    def test_the_placement_job_reads_the_snapshot_and_exports_the_cascade(self):
        job = self.jobs["macos-placement"]
        self.assertEqual(job["permissions"].get("actions"), "read")
        place = next(step for step in job["steps"] if step.get("id") == "place")
        # The pool snapshot reads with the glaeda read token (its own budget), else GITHUB_TOKEN.
        self.assertEqual(place["env"]["SNAPSHOT_TOKEN"], "${{ steps.snapshot-read-token.outputs.token || github.token }}")
        for output in ("blacksmith_12_jobs", "blacksmith_6_jobs", "hosted_jobs", "hosted_runner",
                       "nightly_runner_ready"):
            self.assertEqual(job["outputs"][output], f"${{{{ steps.place.outputs.{output} }}}}")
        # A placement script that predates the free-slot rule (a pull request's old base) writes only
        # retry_runner, which may name a full label; the job reads the key only the new rule writes.
        self.assertEqual(job["outputs"]["retry_runner"], "${{ steps.place.outputs.free_retry_runner }}")
        self.assertEqual(set(cascade.CASCADE_JOBS), set(CASCADED))
        self.assertTrue(set(cascade.CASCADE_JOBS) <= set(place["env"]["JOBS"].split()))


if __name__ == "__main__":
    unittest.main()
