#!/usr/bin/env python3
"""The nightly-next app build never waits on one label with no fallback.

Row 3 of the 2026-10-27 nightly path audit: build-nightly-app read
vars.CI_NIGHTLY_NEXT_BUILD_RUNNER alone on nightly-next, for every attempt
(prepare-nightly-variant-primary did too until it moved to Linux, #25885). Runs 40446901975 and 40448164753 died at "Set up
runner" on that label, and run 40453543604's rescue re-run was refused on the same
label again. scripts/ci/nightly_build_runner.py now picks an idle owned Mac, else a
moving Blacksmith label, and a re-run takes Blacksmith.
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
        self.assertEqual(picker.owned_route(SIDE, runners, "1")[0], SIDE)
        # The variable's unwatched DEV label is skipped, and the side label still gets its turn.
        self.assertEqual(picker.owned_route(f"{DEV} {SIDE}", [runner(DEV), runner(SIDE)], "1")[0], SIDE)

    def test_a_busy_or_offline_fleet_is_never_waited_on(self) -> None:
        for runners in ([runner(SIDE, busy=True)], [runner(SIDE, status="offline")], []):
            with self.subTest(runners=runners):
                self.assertEqual(picker.owned_route(SIDE, runners, "1")[0], "")

    def test_a_retry_unread_runners_or_a_non_owned_label_picks_no_owned_mac(self) -> None:
        idle = [runner(SIDE)]
        self.assertEqual(picker.owned_route(SIDE, idle, "2")[0], "")
        self.assertEqual(picker.owned_route(SIDE, None, "1")[0], "")
        for label in ("", SMALL, "macos-26", "glaeda-runner-cmux1"):
            with self.subTest(label=label):
                self.assertEqual(picker.owned_route(label, idle, "1")[0], "")

    def test_a_label_the_rescue_does_not_watch_is_never_offered(self) -> None:
        # The DEV slot: a refusal there is never re-run (runs 40446901975, 40448164753).
        sys.path.insert(0, str(ROOT / "scripts" / "ci"))
        import owned_pool_rescue as rescue
        self.assertIsNone(rescue.job_pool({"labels": [DEV]}))
        self.assertEqual(picker.owned_route(DEV, [runner(DEV)], "1")[0], "")
        self.assertEqual(rescue.job_pool({"labels": [SIDE]}), SIDE)


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


class Main(unittest.TestCase):
    def run_main(self, env: dict, **reads) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            base = {"GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "1",
                    "ROUTE_TOKEN": "r", "SNAPSHOT_TOKEN": "s", "OWNED_LABELS": f"{DEV} {SIDE}", "CANDIDATE": LARGE}
            self.assertEqual(picker.main({**base, **env}, now=NOW, **reads), 0)
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_idle_owned_first(self) -> None:
        out = self.run_main({}, read_runners=lambda t, r: [runner(SIDE)], read_snapshot=lambda t, r: snapshot({}))
        self.assertEqual(out, {"owned": SIDE, "blacksmith": LARGE, "runner": SIDE})

    def test_busy_owned_goes_to_blacksmith(self) -> None:
        out = self.run_main({}, read_runners=lambda t, r: [runner(SIDE, busy=True)],
                            read_snapshot=lambda t, r: snapshot({LARGE: 90}))
        self.assertEqual(out, {"owned": "", "blacksmith": SMALL, "runner": SMALL})

    def test_failed_reads_never_fail_the_job(self) -> None:
        def broken(token: str, repo: str):
            raise OSError("HTTP 403")
        out = self.run_main({}, read_runners=broken, read_snapshot=broken)
        self.assertEqual(out, {"owned": "", "blacksmith": LARGE, "runner": LARGE})

    def test_no_route_token_reads_no_runners(self) -> None:
        def unexpected(token: str, repo: str):
            raise AssertionError("runners read without a route token")
        out = self.run_main({"ROUTE_TOKEN": ""}, read_runners=unexpected, read_snapshot=lambda t, r: None)
        self.assertEqual(out["owned"], "")


class Workflow(unittest.TestCase):
    def test_no_guarded_job_reads_a_single_label_variable(self) -> None:
        for job in GUARDED:
            with self.subTest(job=job):
                runs_on = DOC["jobs"][job]["runs-on"]
                self.assertNotIn("CI_NIGHTLY_NEXT_BUILD_RUNNER", runs_on)
                self.assertIn(f"needs.{GUARDED[job]}.outputs.owned", runs_on)
                self.assertIn(f"needs.{GUARDED[job]}.outputs.blacksmith", runs_on)

    def test_every_nightly_next_route_has_a_blacksmith_fallback(self) -> None:
        # Owned only on attempt 1 and only when the picker saw it idle; anything else is Blacksmith,
        # whatever vars.MACOS_RUNNER_26 holds (a hosted or owned value never routes around the pick).
        for job, pick in GUARDED.items():
            source = DOC["jobs"][job]["runs-on"].removeprefix("${{").removesuffix("}}")
            for attempt, owned, blacksmith, owned_on, variable in itertools.product(
                    (1, 2, 3), ("", SIDE), ("", SMALL), ("1", "0"), ("macos-26", "macos-15", SIDE, LARGE, "")):
                context = {"github.repository_owner": "manaflow-ai", "github.repository": "manaflow-ai/cmux",
                           "github.event_name": "push", "github.ref": "refs/heads/nightly-next",
                           "github.run_attempt": attempt, "vars.CI_PR_POOL_OWNED": owned_on,
                           "vars.CI_SIDE_LANE_RUNNER": SIDE, "vars.CI_NIGHTLY_NEXT_BUILD_RUNNER": DEV,
                           "vars.CI_SEED_TRUSTED_POOL": "glaeda-trusted-std-xcode-26.6",
                           "vars.MACOS_RUNNER_26": variable,
                           f"needs.{pick}.outputs.owned": owned, f"needs.{pick}.outputs.blacksmith": blacksmith}
                with self.subTest(job=job, attempt=attempt, owned=owned, blacksmith=blacksmith, owned_on=owned_on,
                                  variable=variable):
                    label = evaluate(parse_expression(source), context)
                    if attempt == 1 and owned:
                        self.assertEqual(label, owned)
                    else:
                        self.assertTrue(str(label).startswith("blacksmith-"), label)

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
                self.assertEqual(definition["outputs"]["owned"], "${{ steps.pick.outputs.owned }}")
                self.assertEqual(definition["outputs"]["blacksmith"], "${{ steps.pick.outputs.blacksmith }}")

    def test_owned_is_offered_only_where_the_rescue_watches(self) -> None:
        # owned_pool_rescue.nightly_target watches attempt 1 of nightly-next push runs while owned
        # pools are on; the routing token (and so any owned pick) exists only there.
        for pick in GUARDED.values():
            step = next(s for s in DOC["jobs"][pick]["steps"] if s.get("id") == "route-token")
            for clause in ("github.run_attempt == 1", "vars.CI_PR_POOL_OWNED == '1'",
                           "github.event_name == 'push'", "github.ref == 'refs/heads/nightly-next'"):
                with self.subTest(pick=pick, clause=clause):
                    self.assertIn(clause, step["if"])


if __name__ == "__main__":
    unittest.main()
