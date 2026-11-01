#!/usr/bin/env python3
"""The nightly-next app build never waits on one label with no fallback.

Row 3 of the 2026-10-27 nightly path audit: build-nightly-app read
vars.CI_NIGHTLY_NEXT_BUILD_RUNNER alone on nightly-next, for every attempt
(prepare-nightly-variant-primary did too until it moved to Linux, #25885). Runs 40446901975 and 40448164753 died at "Set up
runner" on that label, and run 40453543604's rescue re-run was refused on the same
label again. scripts/ci/nightly_build_runner.py now picks the dedicated nightly-next
builder while it is free (waiting up to 1 min while it is busy), else an idle owned Mac,
else a moving Blacksmith label, and a re-run of failed jobs that keeps the pick takes
Blacksmith. A workflow_dispatch run and a re-run that picks again go through the same pick
as attempt 1 of a push (until 2026-10-27 they never got the routing token).
"""

from __future__ import annotations

import datetime as dt
import itertools
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
sys.path.insert(0, str(Path(__file__).parent))

import nightly_build_runner as picker  # noqa: E402
from test_ci_fork_runner_routing import parse_expression  # noqa: E402
from test_nightly_trusted_routing import DOC, evaluate  # noqa: E402

NOW = dt.datetime(2026, 10, 27, 6, 0, tzinfo=dt.timezone.utc)
SIDE = "glaeda-side-std-xcode-26.6"
DEV = "glaeda-dev-std-xcode-26.6"
LARGE, SMALL = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"
DEDICATED = "glaeda-trusted-next-nightly"
BUILDER = ("glaeda-trusted-light-xcode-26.6", "glaeda-runner-cmux7s-mac-mini-nightly-next", DEDICATED)
TRUSTED_POOL = "glaeda-trusted-std-xcode-26.6"
TRUSTED_RUNNER = "glaeda-runner-cmux15-glaeda"
# Each guarded job and the picker job whose outputs route it.
GUARDED = {"build-nightly-app": "pick-nightly-build-runner"}


def runner(*labels: str, busy: bool = False, status: str = "online") -> dict:
    return {"status": status, "busy": busy, "labels": [{"name": name} for name in labels]}


def snapshot(waits: dict[str, int]) -> dict:
    return {"generated_at": (NOW - dt.timedelta(minutes=2)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "pools": {label: {"queued": 1 if wait else 0, "oldest_queued_minutes": wait}
                      for label, wait in waits.items()}}


class OwnedRoute(unittest.TestCase):
    def test_an_idle_owned_runner_takes_the_build(self) -> None:
        runners = [runner(SIDE, busy=True), runner(SIDE)]
        self.assertEqual(picker.owned_route(SIDE, runners)[0], SIDE)
        # The variable's unwatched DEV label is skipped, and the side label still gets its turn.
        self.assertEqual(picker.owned_route(f"{DEV} {SIDE}", [runner(DEV), runner(SIDE)])[0], SIDE)

    def test_a_busy_or_offline_fleet_is_never_waited_on(self) -> None:
        for runners in ([runner(SIDE, busy=True)], [runner(SIDE, status="offline")], []):
            with self.subTest(runners=runners):
                self.assertEqual(picker.owned_route(SIDE, runners)[0], "")

    def test_unread_runners_or_a_non_owned_label_picks_no_owned_mac(self) -> None:
        idle = [runner(SIDE)]
        self.assertEqual(picker.owned_route(SIDE, None)[0], "")
        for label in ("", SMALL, "macos-26", "glaeda-runner-cmux1"):
            with self.subTest(label=label):
                self.assertEqual(picker.owned_route(label, idle)[0], "")

    def test_the_nightly_slot_comes_first_while_idle(self) -> None:
        # vars.CI_NIGHTLY_NEXT_BUILD_RUNNER names glaeda's nightly slot, then the side label: an idle slot takes the
        # build, and a busy one leaves it to the side label, never a wait.
        slot = "glaeda-nightly-std-xcode-26.6"
        self.assertTrue(picker.owned_label(slot))
        for label in ("glaeda-nightly", "glaeda-nightly-std", "glaeda-nightlyx-std-xcode-26.6"):
            self.assertFalse(picker.owned_label(label), label)
        labels = f"{slot} {SIDE}"

        def route(runners: list) -> str:  # attempt 1, with or without owned_route's attempt argument
            try:
                return picker.owned_route(labels, runners, "1")[0]
            except TypeError:
                return picker.owned_route(labels, runners)[0]

        self.assertEqual(route([runner(SIDE), runner(slot)]), slot)
        self.assertEqual(route([runner(SIDE), runner(slot, busy=True)]), SIDE)

    def test_a_label_the_rescue_does_not_watch_is_never_offered(self) -> None:
        # The DEV slot: a refusal there is never re-run (runs 40446901975, 40448164753).
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import owned_pool_rescue as rescue
        self.assertIsNone(rescue.job_pool({"labels": [DEV]}))
        self.assertEqual(picker.owned_route(DEV, [runner(DEV)])[0], "")
        self.assertEqual(rescue.job_pool({"labels": [SIDE]}), SIDE)


class Clock:
    """A fake monotonic clock that sleep() advances."""

    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps: list[float] = []

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


class DedicatedRoute(unittest.TestCase):
    def route(self, states: list, label: str = DEDICATED):
        clock, reads = Clock(), iter(states)
        result = picker.dedicated_route(label, lambda: next(reads), sleep=clock.sleep, clock=clock)
        return result, clock

    def test_an_idle_builder_takes_the_build_at_once(self) -> None:
        (label, _), clock = self.route([[runner(*BUILDER)]])
        self.assertEqual(label, DEDICATED)
        self.assertEqual(clock.sleeps, [])

    def test_a_busy_builder_is_waited_on_up_to_a_minute(self) -> None:
        busy, idle = [runner(*BUILDER, busy=True)], [runner(*BUILDER)]
        (label, _), clock = self.route([busy, busy, idle])
        self.assertEqual(label, DEDICATED)
        self.assertEqual(clock.sleeps, [30, 30])
        self.assertEqual(picker.DEDICATED_WAIT_SECONDS, 60)
        (label, why), clock = self.route([busy] * 100)
        self.assertEqual(label, "")
        self.assertIn("stayed busy", why)
        self.assertLessEqual(sum(clock.sleeps), picker.DEDICATED_WAIT_SECONDS)

    def test_offline_unread_or_off_is_skipped_without_waiting(self) -> None:
        for states, label in (([[runner(*BUILDER, status="offline")]], DEDICATED),
                              ([[]], DEDICATED), ([None], DEDICATED),
                              ([[runner(*BUILDER)]], ""),
                              ([[runner(SIDE)]], SIDE)):
            with self.subTest(states=states, label=label):
                (picked, _), clock = self.route(states, label)
                self.assertEqual(picked, "")
                self.assertEqual(clock.sleeps, [])

    def test_a_pool_runner_carrying_the_label_is_not_the_builder(self) -> None:
        # Run 40593692340 (2026-10-27): cmux15's trusted pool runners still carried the label beside
        # the dedicated builder, read as "online and idle", and refused the build at "Set up runner"
        # on attempts 1 and 2 (capacity units, then the attempt-1-only rule).
        pool_runner = runner("self-hosted", "macOS", "glaeda-mini", "glaeda-trusted", DEDICATED)
        (label, why), clock = self.route([[pool_runner]])
        self.assertEqual((label, why), ("", f"`{DEDICATED}` is offline"))
        self.assertEqual(clock.sleeps, [])
        # The builder beside it still counts, busy or idle, whatever the pool runner is doing.
        (label, _), _ = self.route([[pool_runner, runner(*BUILDER)]])
        self.assertEqual(label, DEDICATED)
        (label, why), _ = self.route([[pool_runner, runner(*BUILDER, busy=True)]] * 100)
        self.assertEqual(label, "")
        self.assertIn("stayed busy", why)

    def test_the_rescue_moves_a_build_queued_on_the_builder(self) -> None:
        # Two runs can both see it idle; the second waits on it until the rescue moves it.
        import owned_pool_rescue as rescue
        self.assertEqual(rescue.job_pool({"labels": [DEDICATED]}), DEDICATED)


def admission_job(setup: str, minutes_ago: float, label: str = DEDICATED, name: str = "build-nightly-app",
                  run_id: int = 40614043040) -> dict:
    at = (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"name": name, "labels": [label], "run_id": run_id, "runner_name": "cmux7s-mac-mini-glaeda-nightly-next",
            "status": "completed" if setup == "failure" else "in_progress", "started_at": at, "completed_at": at,
            "steps": [{"name": "Set up job", "conclusion": "success"}, {"name": "Set up runner", "conclusion": setup}]}


class DedicatedRefusal(unittest.TestCase):
    """#25708: cmux7's admission refused every push's build below its 40 GiB disk floor while GitHub listed
    it idle, so each push lost attempt 1 and a rescue re-run (run 40614043040, 2026-10-28)."""

    def test_a_recent_refusal_holds_the_builder_off(self) -> None:
        job = picker.latest_admission(DEDICATED, [admission_job("failure", 5)])
        why = picker.refusal(DEDICATED, job, NOW)
        self.assertIn("refused run 40614043040", why)
        self.assertIn("Set up runner", why)

    def test_an_old_refusal_or_a_later_admission_offers_it_again(self) -> None:
        old = picker.latest_admission(DEDICATED, [admission_job("failure", 31)])
        self.assertEqual(picker.refusal(DEDICATED, old, NOW), "")
        later = picker.latest_admission(DEDICATED, [admission_job("failure", 20), admission_job("success", 10)])
        self.assertEqual(picker.refusal(DEDICATED, later, NOW), "")
        self.assertEqual(picker.refusal(DEDICATED, None, NOW), "")

    def test_only_the_builders_own_build_job_counts(self) -> None:
        for job in (admission_job("failure", 5, label=SIDE), admission_job("failure", 5, name="signer-app"),
                    admission_job("", 5)):
            with self.subTest(job=job):
                self.assertIsNone(picker.latest_admission(DEDICATED, [job]))

    def test_the_reader_pages_jobs_and_ignores_older_admissions(self) -> None:
        pages = {"/actions/workflows/nightly.yml/runs?branch=nightly-next&per_page=6":
                     {"workflow_runs": [{"id": 3}, {"id": 2}, {"id": 1}]},
                 "/actions/runs/3/jobs?filter=all&per_page=100&page=1": {"jobs": [admission_job("", 1)]},
                 # A run on its third attempt: the refused job is on the second page.
                 "/actions/runs/2/jobs?filter=all&per_page=100&page=1":
                     {"jobs": [admission_job("success", 9, name="decide", run_id=2)] * 100},
                 "/actions/runs/2/jobs?filter=all&per_page=100&page=2": {"jobs": [admission_job("failure", 4, run_id=2)]},
                 "/actions/runs/1/jobs?filter=all&per_page=100&page=1": {"jobs": [admission_job("success", 20, run_id=1)]}}
        seen = []

        class Fake:
            def get(self, path):
                seen.append(path)
                return pages[path]

        self.assertEqual(picker.read_admission(Fake(), DEDICATED)["run_id"], 2)
        self.assertIn("/actions/runs/1/jobs?filter=all&per_page=100&page=1", seen)

    def test_the_reader_uses_job_time_across_run_creation_order(self) -> None:
        # An older-created run can execute later through a full rerun or delayed dependencies.
        for latest_setup, earlier_setup in (("failure", "success"), ("success", "failure")):
            with self.subTest(latest_setup=latest_setup):
                pages = {"/actions/workflows/nightly.yml/runs?branch=nightly-next&per_page=6":
                             {"workflow_runs": [{"id": 2}, {"id": 1}]},
                         "/actions/runs/2/jobs?filter=all&per_page=100&page=1":
                             {"jobs": [admission_job(earlier_setup, 20, run_id=2)]},
                         "/actions/runs/1/jobs?filter=all&per_page=100&page=1":
                             {"jobs": [admission_job(latest_setup, 5, run_id=1)]}}

                class Fake:
                    def get(self, path):
                        return pages[path]

                latest = picker.read_admission(Fake(), DEDICATED)
                self.assertEqual(latest["run_id"], 1)
                self.assertEqual(bool(picker.refusal(DEDICATED, latest, NOW)), latest_setup == "failure")

    def run_pick(self, admission):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "1",
                   "GITHUB_EVENT_NAME": "push", "ROUTE_TOKEN": "r", "SNAPSHOT_TOKEN": "s",
                   "OWNED_LABELS": f"{DEV} {SIDE}", "CANDIDATE": LARGE, "DEDICATED_LABEL": DEDICATED}
            clock = Clock()
            picker.main(env, now=NOW, sleep=clock.sleep, clock=clock,
                        read_runners=lambda t, r: [runner(*BUILDER), runner(SIDE)],
                        read_snapshot=lambda t, r: snapshot({}), read_admission_fn=admission)
            return dict(line.split("=", 1) for line in output.read_text().splitlines()), clock

    def test_an_idle_but_refusing_builder_is_skipped_for_the_owned_pool(self) -> None:
        out, clock = self.run_pick(lambda t, r: admission_job("failure", 5))
        self.assertEqual((out["dedicated"], out["owned"], out["runner"]), ("", SIDE, SIDE))
        self.assertEqual(clock.sleeps, [])
        out, _ = self.run_pick(lambda t, r: admission_job("success", 5))
        self.assertEqual(out["owned"], DEDICATED)

    def test_the_dedicated_mode_honours_the_hold(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output), "GITHUB_EVENT_NAME": "push",
                   "ROUTE_TOKEN": "r", "SNAPSHOT_TOKEN": "s", "DEDICATED_LABEL": DEDICATED}
            picker.main(env, now=NOW, argv=("dedicated",), read_runners=lambda t, r: [runner(*BUILDER)],
                        read_admission_fn=lambda t, r: admission_job("failure", 5))
            self.assertEqual(output.read_text().strip(), "dedicated=")

    def test_an_unread_admission_history_leaves_the_builder_offered(self) -> None:
        def broken(token, repo):
            raise OSError("HTTP 403")
        out, _ = self.run_pick(broken)
        self.assertEqual(out["owned"], DEDICATED)

    # Production names the dedicated builder as the trusted pair too (vars.CI_NIGHTLY_NEXT_TRUSTED_POOL and
    # _RUNNER are labels of the same cmux7s runner, BUILDER here), and build-nightly-app takes `trusted` before
    # `owned`: a hold that cleared only `dedicated` sent the build back to the Mac that refused it (#29768).
    def run_trusted_pick(self, admission):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "1",
                   "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/nightly-next", "ROUTE_TOKEN": "r",
                   "SNAPSHOT_TOKEN": "s", "OWNED_LABELS": f"{DEV} {SIDE}", "CANDIDATE": LARGE,
                   "DEDICATED_LABEL": DEDICATED, "TRUSTED_POOL": BUILDER[0], "TRUSTED_RUNNER": BUILDER[1]}
            clock = Clock()
            picker.main(env, now=NOW, sleep=clock.sleep, clock=clock,
                        read_runners=lambda t, r: [runner(*BUILDER), runner(SIDE)],
                        read_snapshot=lambda t, r: snapshot({}), read_admission_fn=admission)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_a_refusing_builder_is_not_offered_as_the_trusted_pair_either(self) -> None:
        out = self.run_trusted_pick(lambda t, r: admission_job("failure", 5))
        self.assertEqual((out["dedicated"], out["trusted"], out["owned"]), ("", "", SIDE))
        out = self.run_trusted_pick(lambda t, r: admission_job("success", 5))
        self.assertEqual(out["dedicated"], DEDICATED)

    def test_a_refusal_of_a_build_routed_by_the_trusted_pair_counts(self) -> None:
        # A trusted-routed build-nightly-app carries only the pair's labels, not the dedicated label.
        job = dict(admission_job("failure", 5), labels=[BUILDER[0], BUILDER[1]])
        self.assertIsNone(picker.latest_admission(DEDICATED, [job]))
        self.assertEqual(picker.latest_admission([DEDICATED, BUILDER[1]], [job]), job)
        self.assertIn("refused run 40614043040", picker.refusal(DEDICATED, job, NOW))


class TrustedRoute(unittest.TestCase):
    def test_trusted_pair_is_selected_with_both_labels(self) -> None:
        selector, why = picker.trusted_route(
            TRUSTED_POOL, TRUSTED_RUNNER,
            [runner(TRUSTED_POOL, TRUSTED_RUNNER)],
            event="push", ref="refs/heads/nightly-next",
        )
        self.assertEqual(selector, f'["{TRUSTED_POOL}","{TRUSTED_RUNNER}"]')
        self.assertIn("idle", why)

    def test_unread_trusted_pair_falls_through_to_a_watched_route(self) -> None:
        selector, why = picker.trusted_route(
            TRUSTED_POOL, TRUSTED_RUNNER, None,
            event="push", ref="refs/heads/nightly-next",
        )
        self.assertEqual(selector, "")
        self.assertIn("unread", why)

    def test_trusted_pair_never_leaks_to_other_events(self) -> None:
        selector, _ = picker.trusted_route(
            TRUSTED_POOL, TRUSTED_RUNNER, None,
            event="workflow_dispatch", ref="refs/heads/nightly-next",
        )
        self.assertEqual(selector, "")


class NightlyOnlyBuilderRoute(unittest.TestCase):
    def test_builder_only_while_a_runner_carrying_it_is_idle(self) -> None:
        builder, plain = picker.NIGHTLY_ONLY_BUILDER_LABEL, picker.NIGHTLY_ONLY_LABEL

        def runner(status: str = "online", busy: bool = False, *labels: str) -> dict:
            return {"status": status, "busy": busy, "labels": [{"name": label} for label in labels or (plain, builder)]}
        self.assertEqual(picker.nightly_only_builder_route(builder, plain, [runner(busy=True), runner()])[0], builder)
        for label, runners in ((builder, [runner(busy=True)]), (builder, [runner("offline")]),
                               (builder, [runner("online", False, plain)]), (builder, None),
                               ("", [runner()]), (plain, [runner()]), ("glaeda-unregistered", [runner()])):
            with self.subTest(label=label, runners=runners):
                self.assertEqual(picker.nightly_only_builder_route(label, plain, runners)[0], plain)


class BlacksmithRoute(unittest.TestCase):
    def test_the_moving_label_is_picked(self) -> None:
        self.assertEqual(picker.blacksmith_route(LARGE, snapshot({LARGE: 90}), NOW)[0], SMALL)
        self.assertEqual(picker.blacksmith_route(LARGE, None, NOW)[0], LARGE)

    def test_an_excluded_label_is_skipped_while_another_moves(self) -> None:
        self.assertEqual(picker.blacksmith_route(SMALL, snapshot({}), NOW, exclude=SMALL)[0], LARGE)
        # Every other label stalled: the excluded one is still better than none.
        self.assertEqual(picker.blacksmith_route(SMALL, snapshot({LARGE: 90}), NOW, exclude=SMALL)[0], SMALL)

    def test_never_empty(self) -> None:
        for variable in ("", "glaeda-side-std-xcode-26.6", "macos-26"):
            with self.subTest(variable=variable):
                self.assertTrue(picker.blacksmith_route(variable, None, NOW)[0].startswith("blacksmith-"))


class DeadLabel(unittest.TestCase):
    """A stale snapshot still shows a dead label (nightly_sign_runner.dead()): the route never takes it."""

    @staticmethod
    def stale(dead: str) -> dict:
        generated = NOW - dt.timedelta(minutes=38)
        alive = SMALL if dead == LARGE else LARGE
        stamp = (generated - dt.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        return {"generated_at": generated.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "pools": {dead: {"queued": 0, "running": 0}, alive: {"queued": 0, "running": 4}},
                "label_started": {alive: stamp}}

    def test_a_stale_snapshot_keeps_the_route_off_a_dead_label(self):
        self.assertEqual(picker.blacksmith_route(LARGE, self.stale(LARGE), NOW)[0], SMALL)
        # The excluded label's only alternative is dead: the route keeps the excluded one.
        self.assertEqual(picker.blacksmith_route(SMALL, self.stale(LARGE), NOW, exclude=SMALL)[0], SMALL)


class Main(unittest.TestCase):
    def run_main(self, env: dict, argv: tuple = (), **reads) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            base = {"GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "1",
                    "GITHUB_EVENT_NAME": "push", "GITHUB_REF": "refs/heads/nightly-next",
                    "ROUTE_TOKEN": "r", "SNAPSHOT_TOKEN": "s", "OWNED_LABELS": f"{DEV} {SIDE}", "CANDIDATE": LARGE}
            clock = Clock()
            reads.setdefault("read_admission_fn", lambda token, repo: None)
            self.assertEqual(picker.main({**base, **env}, now=NOW, argv=argv, sleep=clock.sleep, clock=clock,
                                         **reads), 0)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_idle_owned_first(self) -> None:
        out = self.run_main({}, read_runners=lambda t, r: [runner(SIDE)], read_snapshot=lambda t, r: snapshot({}))
        self.assertEqual(out, {"dedicated": "", "trusted": "", "owned": SIDE, "blacksmith": LARGE, "runner": SIDE, "helper": SIDE,
                               "attempt": "1"})

    def test_trusted_next_pair_is_emitted_before_shared_owned_pool(self) -> None:
        out = self.run_main(
            {"TRUSTED_POOL": TRUSTED_POOL, "TRUSTED_RUNNER": TRUSTED_RUNNER},
            read_runners=lambda t, r: [runner(TRUSTED_POOL, TRUSTED_RUNNER), runner(SIDE)],
            read_snapshot=lambda t, r: snapshot({}),
        )
        self.assertEqual(out["trusted"], f'["{TRUSTED_POOL}","{TRUSTED_RUNNER}"]')
        self.assertEqual(out["owned"], SIDE)

    def test_a_rerun_picks_like_attempt_one(self) -> None:
        # A re-run that runs the picker again (a full re-run, or one after the picker failed) picks
        # the same way, the dedicated builder first, and says which attempt the pick is for.
        for attempt in ("2", "3"):
            with self.subTest(attempt=attempt):
                out = self.run_main({"GITHUB_RUN_ATTEMPT": attempt}, read_runners=lambda t, r: [runner(SIDE)],
                                    read_snapshot=lambda t, r: snapshot({LARGE: 90}))
                self.assertEqual(out, {"dedicated": "", "trusted": "", "owned": SIDE, "blacksmith": SMALL, "runner": SIDE,
                                       "helper": SIDE, "attempt": attempt})
                out = self.run_main({"GITHUB_RUN_ATTEMPT": attempt, "DEDICATED_LABEL": DEDICATED},
                                    read_runners=lambda t, r: [runner(*BUILDER), runner(SIDE)],
                                    read_snapshot=lambda t, r: snapshot({}))
                self.assertEqual((out["owned"], out["attempt"]), (DEDICATED, attempt))

    def test_busy_owned_goes_to_blacksmith(self) -> None:
        out = self.run_main({}, read_runners=lambda t, r: [runner(SIDE, busy=True)],
                            read_snapshot=lambda t, r: snapshot({LARGE: 90}))
        self.assertEqual(out, {"dedicated": "", "trusted": "", "owned": "", "blacksmith": SMALL, "runner": SMALL, "helper": "",
                               "attempt": "1"})

    def test_failed_reads_never_fail_the_job(self) -> None:
        def broken(token: str, repo: str):
            raise OSError("HTTP 403")
        out = self.run_main({"UNREAD_OWNED_FALLBACK": "1"}, read_runners=broken, read_snapshot=broken)
        # Fleet first: unread runners queue the build on the first watched owned pool, not Blacksmith (run
        # 41203691245, 2026-10-31: a 403 rate limit on /actions/runners sent the tip build to a stalled label).
        self.assertEqual(out, {"dedicated": "", "trusted": "", "owned": SIDE, "blacksmith": LARGE, "runner": SIDE, "helper": SIDE,
                               "attempt": "1"})

    def test_unread_runners_with_no_watched_owned_label_still_take_blacksmith(self) -> None:
        def broken(token: str, repo: str):
            raise OSError("HTTP 403")
        out = self.run_main({"OWNED_LABELS": f"{DEV} {SMALL}", "UNREAD_OWNED_FALLBACK": "1"},
                            read_runners=broken, read_snapshot=broken)
        self.assertEqual((out["owned"], out["runner"]), ("", LARGE))

    def test_unread_runners_without_the_opt_in_take_blacksmith(self) -> None:
        # The CI_PR_POOL_OWNED kill switch off (nightly.yml leaves UNREAD_OWNED_FALLBACK empty), and the train
        # picker (nightly-next-train.yml, no owned-pool rescue): an unread pool never offers an owned label.
        def broken(token: str, repo: str):
            raise OSError("HTTP 403")
        for env in ({}, {"UNREAD_OWNED_FALLBACK": ""}, {"UNREAD_OWNED_FALLBACK": "0"}, {"ROUTE_TOKEN": ""}):
            with self.subTest(env=env):
                out = self.run_main(env, read_runners=broken, read_snapshot=broken)
                self.assertEqual((out["owned"], out["runner"]), ("", LARGE))

    def test_the_dedicated_builder_comes_first(self) -> None:
        fleet = [runner(*BUILDER), runner(SIDE)]
        out = self.run_main({"DEDICATED_LABEL": DEDICATED}, read_runners=lambda t, r: fleet,
                            read_snapshot=lambda t, r: snapshot({}))
        self.assertEqual(out, {"dedicated": DEDICATED, "trusted": "", "owned": DEDICATED, "blacksmith": LARGE, "runner": DEDICATED,
                               "helper": SIDE, "attempt": "1"})

    def test_the_helper_takes_an_idle_owned_mac_while_the_app_build_holds_the_builder(self) -> None:
        # Run 40990112293: the app build took the dedicated builder, so the helper took
        # blacksmith-6vcpu-macos-26 and waited there 39 minutes while side Macs were idle.
        out = self.run_main({"DEDICATED_LABEL": DEDICATED}, read_runners=lambda t, r: [runner(*BUILDER), runner(SIDE)],
                            read_snapshot=lambda t, r: snapshot({}))
        self.assertEqual((out["owned"], out["helper"]), (DEDICATED, SIDE))
        # No idle owned Mac besides the builder: no owned helper pick, so the helper takes Blacksmith.
        for fleet in ([runner(*BUILDER)], [runner(*BUILDER), runner(SIDE, busy=True)]):
            with self.subTest(fleet=fleet):
                out = self.run_main({"DEDICATED_LABEL": DEDICATED}, read_runners=lambda t, r: fleet,
                                    read_snapshot=lambda t, r: snapshot({}))
                self.assertEqual((out["owned"], out["helper"], out["blacksmith"]), (DEDICATED, "", LARGE))
        # The helper pick is never the dedicated builder, even when only the builder carries a watched label.
        out = self.run_main({"DEDICATED_LABEL": DEDICATED, "OWNED_LABELS": f"{DEV} {SIDE} {DEDICATED}"},
                            read_runners=lambda t, r: [runner(*BUILDER)], read_snapshot=lambda t, r: snapshot({}))
        self.assertNotEqual(out["helper"], DEDICATED)

    def test_only_a_push_is_offered_the_builder(self) -> None:
        # The builder admits only a push to nightly-next: run 40594111618, a dispatch, was refused at
        # "Set up runner" ("event workflow_dispatch is not push"). Other events go to the owned pool.
        fleet = [runner(*BUILDER), runner(SIDE)]
        for event in ("workflow_dispatch", "schedule", ""):
            with self.subTest(event=event):
                out = self.run_main({"DEDICATED_LABEL": DEDICATED, "GITHUB_EVENT_NAME": event},
                                    read_runners=lambda t, r: fleet, read_snapshot=lambda t, r: snapshot({}))
                self.assertEqual(out, {"dedicated": "", "trusted": "", "owned": SIDE, "blacksmith": LARGE, "runner": SIDE,
                                       "helper": SIDE, "attempt": "1"})
                out = self.run_main({"DEDICATED_LABEL": DEDICATED, "GITHUB_EVENT_NAME": event}, argv=("dedicated",),
                                    read_runners=lambda t, r: fleet)
                self.assertEqual(out, {"dedicated": ""})

    def test_a_builder_busy_past_the_wait_falls_back_to_the_owned_pool(self) -> None:
        fleet = [runner(*BUILDER, busy=True), runner(SIDE)]
        out = self.run_main({"DEDICATED_LABEL": DEDICATED}, read_runners=lambda t, r: fleet,
                            read_snapshot=lambda t, r: snapshot({}))
        self.assertEqual(out, {"dedicated": "", "trusted": "", "owned": SIDE, "blacksmith": LARGE, "runner": SIDE, "helper": SIDE,
                               "attempt": "1"})
        # No idle owned Mac either: Blacksmith.
        out = self.run_main({"DEDICATED_LABEL": DEDICATED}, read_runners=lambda t, r: [runner(*BUILDER, status="offline")],
                            read_snapshot=lambda t, r: snapshot({}))
        self.assertEqual(out["runner"], LARGE)

    def test_the_blacksmith_pick_reads_queue_ages_after_the_wait(self) -> None:
        # The Blacksmith pick reads queue ages after the wait: `now` moves by the time waited.
        fleet = [runner(*BUILDER, busy=True)]
        seen = {}

        def read_snapshot(token: str, repo: str):
            return snapshot({LARGE: 8})

        import nightly_sign_runner
        original = nightly_sign_runner.pick

        def pick(variable, snap, now):
            seen["now"] = now
            return original(variable, snap, now)

        nightly_sign_runner.pick = pick
        try:
            out = self.run_main({"DEDICATED_LABEL": DEDICATED}, read_runners=lambda t, r: fleet,
                                read_snapshot=read_snapshot)
        finally:
            nightly_sign_runner.pick = original
        self.assertGreaterEqual(seen["now"] - NOW, dt.timedelta(seconds=picker.DEDICATED_WAIT_SECONDS - 30))
        self.assertEqual(out["dedicated"], "")

    def test_the_dedicated_mode_never_waits(self) -> None:
        out = self.run_main({"DEDICATED_LABEL": DEDICATED}, argv=("dedicated",),
                            read_runners=lambda t, r: [runner(*BUILDER, busy=True)])
        self.assertEqual(out, {"dedicated": ""})
        out = self.run_main({"DEDICATED_LABEL": DEDICATED}, argv=("dedicated",),
                            read_runners=lambda t, r: [runner(*BUILDER)])
        self.assertEqual(out, {"dedicated": DEDICATED})

    def test_the_verify_mode_prints_owned_only_and_never_the_dedicated_builder(self) -> None:
        fleet = [runner(*BUILDER), runner(SIDE)]
        out = self.run_main({"DEDICATED_LABEL": DEDICATED}, argv=("verify",), read_runners=lambda t, r: fleet,
                            read_snapshot=lambda t, r: snapshot({}))
        self.assertEqual(out, {"owned": SIDE})
        out = self.run_main({}, argv=("verify",), read_runners=lambda t, r: [runner(SIDE, busy=True)],
                            read_snapshot=lambda t, r: snapshot({LARGE: 90}))
        self.assertEqual(out, {"owned": ""})
        # While every Blacksmith label is stalled, a busy owned pool is queued on instead: it frees within
        # one build, and the rescue holds the job there until the Blacksmith label moves.
        out = self.run_main({}, argv=("verify",), read_runners=lambda t, r: [runner(SIDE, busy=True)],
                            read_snapshot=lambda t, r: snapshot({LARGE: 90, SMALL: 90}))
        self.assertEqual(out, {"owned": SIDE})

    def test_the_verify_mode_queues_unread_runners_on_the_owned_pool(self) -> None:
        # Run 41335987427: every routing-App read got a 403 rate limit, and the verify jobs went blind to
        # blacksmith-6vcpu-macos-26. A refused read is not "no owned runners": with the opt-in they queue on
        # the first watched owned pool; without it they keep Blacksmith.
        def broken(token: str, repo: str):
            raise OSError("HTTP 403: API rate limit exceeded for installation")
        out = self.run_main({"UNREAD_OWNED_FALLBACK": "1"}, argv=("verify",), read_runners=broken, read_snapshot=broken)
        self.assertEqual(out, {"owned": SIDE})
        out = self.run_main({}, argv=("verify",), read_runners=broken, read_snapshot=broken)
        self.assertEqual(out, {"owned": ""})

    def test_every_blacksmith_label_stalled_queues_on_the_busy_owned_pool(self) -> None:
        # Run 40622241620 (2026-10-28): build-nightly-app waited 15 min on a stalled Blacksmith label
        # while the owned nightly slots took the next two tips.
        stalled = snapshot({LARGE: 90, SMALL: 90})
        out = self.run_main({}, read_runners=lambda t, r: [runner(SIDE, busy=True)],
                            read_snapshot=lambda t, r: stalled)
        self.assertEqual((out["owned"], out["runner"]), (SIDE, SIDE))
        # One Blacksmith label still moves: it takes the build, as before.
        out = self.run_main({}, read_runners=lambda t, r: [runner(SIDE, busy=True)],
                            read_snapshot=lambda t, r: snapshot({LARGE: 90}))
        self.assertEqual((out["owned"], out["runner"]), ("", SMALL))
        # An offline-only pool still beats the stalled label: the job is watched there and picked again
        # (review P1 on #26614: nothing watches a nightly build queued on a stalled Blacksmith label).
        out = self.run_main({}, read_runners=lambda t, r: [runner(SIDE, status="offline")],
                            read_snapshot=lambda t, r: stalled)
        self.assertEqual((out["owned"], out["runner"]), (SIDE, SIDE))
        # An online runner's label comes before an offline-only one.
        out = self.run_main({},
                            read_runners=lambda t, r: [runner(DEV, status="offline"), runner(SIDE, busy=True)],
                            read_snapshot=lambda t, r: stalled)
        self.assertEqual(out["owned"], SIDE)
        # No snapshot, or no registered runner on the pool: Blacksmith.
        for runners, snap in (([runner(SIDE, busy=True)], None), ([], stalled)):
            with self.subTest(runners=runners, snap=snap):
                out = self.run_main({}, read_runners=lambda t, r, runners=runners: runners,
                                    read_snapshot=lambda t, r, snap=snap: snap)
                self.assertEqual(out["owned"], "")
                self.assertTrue(out["runner"].startswith("blacksmith-"))
        # Unread runners (no routing token): the owned pool still comes before Blacksmith.
        out = self.run_main({"ROUTE_TOKEN": "", "UNREAD_OWNED_FALLBACK": "1"}, read_snapshot=lambda t, r: stalled)
        self.assertEqual(out["owned"], SIDE)

    def test_no_route_token_reads_no_runners(self) -> None:
        def unexpected(token: str, repo: str):
            raise AssertionError("runners read without a route token")
        out = self.run_main({"ROUTE_TOKEN": "", "UNREAD_OWNED_FALLBACK": "1"}, read_runners=unexpected,
                            read_snapshot=lambda t, r: None)
        self.assertEqual(out["owned"], SIDE)  # unread: the watched owned pool, never a read


class Workflow(unittest.TestCase):
    def test_only_the_nightly_build_and_verify_picks_opt_into_the_unread_owned_fallback(self) -> None:
        # nightly.yml's build pick and the sign picker's verify pick (run 41335987427): on only while the
        # CI_PR_POOL_OWNED kill switch is on.
        import yaml  # noqa: PLC0415
        picks = {"pick-nightly-build-runner": "pick", "pick-nightly-sign-runner": "owned"}
        for job, step_id in picks.items():
            steps = DOC["jobs"][job]["steps"]
            pick = next(step for step in steps if step.get("id") == step_id)
            flag = pick["env"]["UNREAD_OWNED_FALLBACK"].removeprefix("${{").removesuffix("}}")
            # And only while the rescue runs (ci-owned-pool-rescue.yml: CI_OWNED_POOL_RESCUE unset or not '0').
            for owned_on, rescue_on, want in (("1", "", "1"), ("1", "1", "1"), ("1", "0", ""), ("0", "", ""),
                                              ("", "", ""), ("0", "1", "")):
                with self.subTest(job=job, owned_on=owned_on, rescue_on=rescue_on):
                    context = {"vars.CI_PR_POOL_OWNED": owned_on, "vars.CI_OWNED_POOL_RESCUE": rescue_on}
                    self.assertEqual(evaluate(parse_expression(flag), context) or "", want)
        # The signing pick (signing_runner.py owned) never takes it: its exclusive claim needs a pinned runner.
        sign = next(step for step in DOC["jobs"]["pick-nightly-sign-runner"]["steps"] if step.get("id") == "sign-owned")
        self.assertNotIn("UNREAD_OWNED_FALLBACK", sign.get("env") or {})
        # nightly-next-train.yml has no owned-pool rescue, so its pick never sets it.
        train = yaml.safe_load((ROOT / ".github" / "workflows" / "nightly-next-train.yml").read_text())
        for step in train["jobs"]["pick-train-runner"]["steps"]:
            self.assertNotIn("UNREAD_OWNED_FALLBACK", step.get("env") or {}, step.get("name"))

    def test_no_guarded_job_reads_a_single_label_variable(self) -> None:
        for job in GUARDED:
            with self.subTest(job=job):
                runs_on = DOC["jobs"][job]["runs-on"]
                self.assertNotIn("CI_NIGHTLY_NEXT_BUILD_RUNNER", runs_on)
                self.assertIn(f"needs.{GUARDED[job]}.outputs.owned", runs_on)
                self.assertIn(f"needs.{GUARDED[job]}.outputs.blacksmith", runs_on)

    def test_every_nightly_next_route_has_a_blacksmith_fallback(self) -> None:
        # Owned only when the picker saw it idle for this very attempt; anything else (a re-run of
        # failed jobs that kept an earlier attempt's pick included) is Blacksmith, whatever
        # vars.MACOS_RUNNER_26 holds (a hosted or owned value never routes around the pick).
        for job, pick in GUARDED.items():
            source = DOC["jobs"][job]["runs-on"].removeprefix("${{").removesuffix("}}")
            for event, attempt, picked_for, owned, blacksmith, owned_on, variable in itertools.product(
                    ("push", "workflow_dispatch"), (1, 2, 3), ("1", "2", ""), ("", SIDE), ("", SMALL), ("1", "0"),
                    ("macos-26", "macos-15", SIDE, LARGE, "")):
                context = {"github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
                           "github.event_name": event, "github.ref": "refs/heads/nightly-next",
                           "github.run_attempt": attempt, "vars.CI_PR_POOL_OWNED": owned_on,
                           "vars.CI_SIDE_LANE_RUNNER": SIDE, "vars.CI_NIGHTLY_NEXT_BUILD_RUNNER": DEV,
                           "vars.CI_SEED_TRUSTED_POOL": "glaeda-trusted-std-xcode-26.6",
                           "vars.MACOS_RUNNER_26": variable, f"needs.{pick}.outputs.attempt": picked_for,
                           f"needs.{pick}.outputs.owned": owned, f"needs.{pick}.outputs.blacksmith": blacksmith}
                with self.subTest(job=job, event=event, attempt=attempt, picked_for=picked_for, owned=owned,
                                  blacksmith=blacksmith, owned_on=owned_on, variable=variable):
                    label = evaluate(parse_expression(source), context)
                    if picked_for == str(attempt) and owned:
                        self.assertEqual(label, owned)
                    else:
                        self.assertTrue(str(label).startswith("blacksmith-"), label)

    def test_the_ghostty_helper_takes_the_owned_or_blacksmith_pick_never_the_dedicated_builder(self) -> None:
        # Starved on Blacksmith macos-26 behind the bare label (run 40500413442). The dedicated
        # builder's hook admits only build-nightly-app, so the helper never takes it.
        job = DOC["jobs"]["build-nightly-ghostty-cli-helper"]
        self.assertIn("pick-nightly-build-runner", job["needs"])
        source = job["runs-on"].removeprefix("${{").removesuffix("}}")
        pick = "pick-nightly-build-runner"
        for event, attempt, picked_for, helper, dedicated, blacksmith in itertools.product(
                ("push", "workflow_dispatch"), (1, 2), ("1", "2"), ("", SIDE, DEDICATED), ("", DEDICATED), ("", LARGE)):
            if helper == DEDICATED and dedicated != DEDICATED:
                continue  # the picker names the builder only as `dedicated` (see the Main helper tests)
            context = {"github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
                       "github.event_name": event, "github.ref": "refs/heads/nightly-next",
                       "github.run_attempt": attempt, "vars.CI_PR_POOL_OWNED": "1",
                       "vars.CI_SIDE_LANE_RUNNER": SIDE, "vars.CI_SEED_TRUSTED_POOL": "glaeda-trusted-std-xcode-26.6",
                       "vars.LINUX_RUNNER": "", "inputs.nightly_next_unsigned_run": "",
                       f"needs.{pick}.outputs.attempt": picked_for,
                       "needs.resolve-nightly-ghostty-cli-helper.outputs.hit": "false",
                       f"needs.{pick}.outputs.owned": dedicated or helper,
                       f"needs.{pick}.outputs.helper": helper, f"needs.{pick}.outputs.dedicated": dedicated,
                       f"needs.{pick}.outputs.blacksmith": blacksmith}
            with self.subTest(event=event, attempt=attempt, picked_for=picked_for, helper=helper, dedicated=dedicated,
                              blacksmith=blacksmith):
                label = evaluate(parse_expression(source), context)
                # The same rule as build-nightly-app: only a pick made for this attempt; the helper
                # pick, which stands while the app build holds the dedicated builder, never that builder.
                if picked_for == str(attempt) and helper == SIDE:
                    self.assertEqual(label, SIDE)
                else:
                    # The picker's moving label, else the default; never a dropped pick.
                    self.assertEqual(label, blacksmith or SMALL)

    def test_the_pickers_never_block_their_job(self) -> None:
        for job, pick in GUARDED.items():
            with self.subTest(pick=pick):
                definition = DOC["jobs"][pick]
                self.assertTrue(definition["continue-on-error"])
                self.assertIn("!cancelled()", definition["if"])
                needs = DOC["jobs"][job]["needs"]
                self.assertIn(pick, needs)
                step = next(s for s in definition["steps"] if s.get("id") == "pick")
                self.assertTrue(step["continue-on-error"])
                self.assertEqual(step["run"].strip(), "python3 .publish-tooling/scripts/ci/nightly_build_runner.py")
                self.assertEqual(step["env"]["OWNED_LABELS"],
                                 "${{ format('{0} {1}', vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, vars.CI_SIDE_LANE_RUNNER) }}")
                self.assertEqual(step["env"]["DEDICATED_LABEL"], "${{ vars.CI_NIGHTLY_NEXT_DEDICATED_LABEL }}")
                # The wait for a busy dedicated builder fits in the step and the job.
                self.assertGreaterEqual(step["timeout-minutes"] * 60, picker.DEDICATED_WAIT_SECONDS + 120)
                self.assertGreater(definition["timeout-minutes"], step["timeout-minutes"] + 2)
                self.assertIn("steps.pick.outputs.owned", definition["outputs"]["owned"])
                self.assertEqual(definition["outputs"]["blacksmith"], "${{ steps.pick.outputs.blacksmith }}")
                # The helper's pick stands on the same terms as `owned`.
                self.assertEqual(definition["outputs"]["helper"],
                                 definition["outputs"]["owned"].replace("steps.pick.outputs.owned",
                                                                        "steps.pick.outputs.helper"))

    def route_token_if(self, pick: str, **changes) -> bool:
        step = next(s for s in DOC["jobs"][pick]["steps"] if s.get("id") == "route-token")
        context = {"github.repository": "manaflow-ai/cmux", "github.run_attempt": 1, "vars.CI_PR_POOL_OWNED": "1",
                   "vars.GLAEDA_ROUTE_APP_ID": "123", "github.event_name": "push",
                   "github.ref": "refs/heads/nightly-next", **changes}
        return bool(evaluate(parse_expression(step["if"]), context))

    def test_owned_is_offered_only_where_the_rescue_watches(self) -> None:
        # owned_pool_rescue.nightly_target (on main) watches nightly-next push and dispatch runs at
        # every attempt while owned pools are on; the routing token (and so any owned pick) exists
        # only there.
        for pick in GUARDED.values():
            for changes in ({"vars.CI_PR_POOL_OWNED": "0"}, {"vars.GLAEDA_ROUTE_APP_ID": ""},
                            {"github.repository": "someone/cmux"}, {"github.ref": "refs/heads/main"},
                            {"github.event_name": "schedule"}, {"github.event_name": "pull_request"}):
                with self.subTest(pick=pick, changes=changes):
                    self.assertFalse(self.route_token_if(pick, **changes))

    def test_a_dispatch_and_a_second_attempt_get_the_routing_token(self) -> None:
        # Until 2026-10-27 only attempt 1 of a push got it, so a dispatched or re-run tip nightly
        # could never build on an owned Mac and queued on a stalled Blacksmith label instead.
        for pick in GUARDED.values():
            for changes in ({}, {"github.event_name": "workflow_dispatch"}, {"github.run_attempt": 2},
                            {"github.event_name": "workflow_dispatch", "github.run_attempt": 3}):
                with self.subTest(pick=pick, changes=changes):
                    self.assertTrue(self.route_token_if(pick, **changes))

    def test_a_dispatch_and_a_second_attempt_build_on_a_free_owned_mac(self) -> None:
        # End to end: the picker's outputs for that attempt, then build-nightly-app's runs-on.
        for event, attempt in (("workflow_dispatch", 1), ("push", 2), ("workflow_dispatch", 2)):
            with self.subTest(event=event, attempt=attempt):
                with tempfile.TemporaryDirectory() as tmp:
                    output = Path(tmp) / "out"
                    env = {"GITHUB_REPOSITORY": "manaflow-ai/cmux", "GITHUB_OUTPUT": str(output),
                           "GITHUB_RUN_ATTEMPT": str(attempt), "ROUTE_TOKEN": "r", "SNAPSHOT_TOKEN": "s",
                           "OWNED_LABELS": f"{DEV} {SIDE}", "CANDIDATE": SMALL}
                    picker.main(env, now=NOW, read_runners=lambda t, r: [runner(SIDE, busy=True), runner(SIDE)],
                                read_snapshot=lambda t, r: snapshot({SMALL: 90}))
                    out = dict(line.split("=", 1) for line in output.read_text().splitlines())
                self.assertEqual(out["owned"], SIDE)
                self.assertEqual(out["attempt"], str(attempt))
                for job, pick in GUARDED.items():
                    context = {"github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
                               "github.event_name": event, "github.ref": "refs/heads/nightly-next",
                               "github.run_attempt": attempt, "vars.CI_PR_POOL_OWNED": "1",
                               **{f"needs.{pick}.outputs.{key}": value for key, value in out.items()}}
                    source = DOC["jobs"][job]["runs-on"].removeprefix("${{").removesuffix("}}")
                    self.assertEqual(evaluate(parse_expression(source), context), SIDE)
                    # A re-run of failed jobs that kept the previous attempt's pick takes the moving
                    # Blacksmith label, so a refused owned label is never taken again.
                    stale = {**context, "github.run_attempt": attempt + 1}
                    self.assertEqual(evaluate(parse_expression(source), stale), LARGE)

    def test_an_owned_pick_outside_the_workflow_run_watch_leaves_a_marker(self) -> None:
        for pick in GUARDED.values():
            steps = DOC["jobs"][pick]["steps"]
            marker = next(s for s in steps if s.get("id") == "marker")
            upload = next(s for s in steps if str(s.get("uses", "")).startswith("actions/upload-artifact@"))
            self.assertEqual(upload["with"]["name"], "owned-pool-watch")
            self.assertTrue(upload["with"]["overwrite"])
            self.assertEqual(upload["if"], "steps.marker.outputs.path != ''")
            self.assertTrue(marker["continue-on-error"] and upload["continue-on-error"])
            self.assertEqual(DOC["jobs"][pick]["outputs"]["attempt"], "${{ steps.pick.outputs.attempt }}")
            self.assertEqual(upload["id"], "upload-marker")
            # The job's `owned` output: outside attempt 1 of a push, only once the marker is uploaded.
            owned_output = DOC["jobs"][pick]["outputs"]["owned"].removeprefix("${{").removesuffix("}}")
            for event, attempt, upload_outcome, wanted in (
                    ("push", 1, "", SIDE), ("push", 1, "failure", SIDE),
                    ("push", 2, "success", SIDE), ("push", 2, "failure", ""), ("push", 2, "", ""),
                    ("workflow_dispatch", 1, "success", SIDE), ("workflow_dispatch", 1, "failure", ""),
                    ("workflow_dispatch", 1, "skipped", "")):
                with self.subTest(output=True, event=event, attempt=attempt, upload=upload_outcome):
                    context = {"github.event_name": event, "github.run_attempt": attempt,
                               "steps.upload-marker.outcome": upload_outcome, "steps.pick.outputs.owned": SIDE}
                    self.assertEqual(evaluate(parse_expression(owned_output), context), wanted)
            for event, attempt, owned, wanted in (("push", 1, SIDE, False), ("push", 2, SIDE, True),
                                                  ("workflow_dispatch", 1, SIDE, True),
                                                  ("workflow_dispatch", 1, "", False)):
                with self.subTest(event=event, attempt=attempt, owned=owned):
                    context = {"github.event_name": event, "github.run_attempt": attempt,
                               "steps.pick.outputs.owned": owned}
                    self.assertEqual(bool(evaluate(parse_expression(marker["if"]), context)), wanted)


if __name__ == "__main__":
    unittest.main()
