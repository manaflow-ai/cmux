#!/usr/bin/env python3
"""The nightly's sign, notarize and publish jobs take a Blacksmith macOS label whose queue moves.

On 2026-10-26 vars.MACOS_RUNNER_26 named blacksmith-12vcpu-macos-26, which started
no job from about 01:20Z, and every nightly's signing jobs waited on it: the feed
went eight hours stale. scripts/ci/nightly_sign_runner.py now picks the label
right before those jobs queue, and no signing job's runs-on can resolve to the
variable alone.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import nightly_sign_runner as picker  # noqa: E402

NOW = dt.datetime(2026, 10, 26, 9, 30, tzinfo=dt.timezone.utc)
LARGE, SMALL = "blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26"
LINUX4, LINUX16, LINUX32 = ("blacksmith-4vcpu-ubuntu-2404", "blacksmith-16vcpu-ubuntu-2404",
                             "blacksmith-32vcpu-ubuntu-2404")
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/nightly.yml").read_text(encoding="utf-8"))

# The jobs that sign, notarize, verify a signed build or publish it, and the job whose
# output names their label. Each reads it first, then the variable, then 6 vCPU.
SIGNING_JOBS = {
    "build-sign-notarize-nightly": "needs.pick-nightly-sign-runner.outputs.runner",
    "verify-signed-nightly": "needs.pick-nightly-sign-runner.outputs.runner",
    "verify-final-dmg-nightly": "needs.pick-nightly-sign-runner.outputs.runner",
    "recover-nightly-next-notarization": "needs.find-nightly-next-recovery.outputs.sign_runner",
    "verify-recovered-nightly-next": "needs.find-nightly-next-recovery.outputs.sign_runner",
    # The release-pool path's one Mac job: Apple's checks and the DMG image, no secrets.
    "signer-dmg-image": "needs.pick-nightly-sign-runner.outputs.runner",
}
# Jobs that never take Blacksmith (Lawrence, 2026-10-30: nightlies never use Blacksmith): an owned
# pick where one exists, then the owned nightly slot variable, the owned side lane, then the owned std pool
# literal, so the chain never ends on a reserved lane variable (test_ci_runs_on_fallback.py).
OWNED_ONLY_JOBS = ("sign-nightly-identity-legacy", "verify-nightly-identity-legacy", "generate-nightly-deltas")
OWNED_FALLBACK = "|| vars.CI_NIGHTLY_NEXT_BUILD_RUNNER || vars.CI_SIDE_LANE_RUNNER || 'glaeda-std-xcode-26.6' }}"
# Each picker's re-run label, the other Blacksmith macOS 26 size.
ALTERNATES = {
    "needs.pick-nightly-sign-runner.outputs.runner": "needs.pick-nightly-sign-runner.outputs.alternate",
    "needs.find-nightly-next-recovery.outputs.sign_runner": "needs.find-nightly-next-recovery.outputs.sign_alternate",
    "needs.legacy-identity-target.outputs.sign_runner": "needs.legacy-identity-target.outputs.sign_alternate",
}
# macOS jobs that still read vars.MACOS_RUNNER_26 directly: they build (no signing material)
# and have owned-pool routes of their own.
BUILD_JOBS = {"build-nightly-app", "prepare-nightly-variant-primary"}


def snapshot(waits: dict[str, int], age_minutes: int = 2) -> dict:
    generated = (NOW - dt.timedelta(minutes=age_minutes)).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {"generated_at": generated,
            "pools": {label: {"queued": 1 if wait else 0, "oldest_queued_minutes": wait} for label, wait in waits.items()}}


def linux_snapshot(waits: dict[str, int], age_minutes: int = 2) -> dict:
    return snapshot({**{label: 0 for label in picker.LINUX_LABELS}, **waits}, age_minutes)


class Pick(unittest.TestCase):
    def test_the_variable_comes_first_while_it_moves(self) -> None:
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 3}), NOW)[0], LARGE)
        self.assertEqual(picker.pick(SMALL, snapshot({}), NOW)[0], SMALL)

    def test_a_stalled_variable_falls_back_to_a_moving_label(self) -> None:
        label, why = picker.pick(LARGE, snapshot({LARGE: 90}), NOW)
        self.assertEqual(label, SMALL)
        self.assertIn(LARGE, why)
        self.assertEqual(picker.pick(SMALL, snapshot({SMALL: 40}), NOW)[0], LARGE)

    def test_a_wait_counts_the_snapshot_age(self) -> None:
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 5}, age_minutes=6), NOW)[0], SMALL)
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 5}, age_minutes=1), NOW)[0], LARGE)

    def test_no_fresh_snapshot_keeps_the_variable(self) -> None:
        self.assertEqual(picker.pick(LARGE, None, NOW)[0], LARGE)
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 90}, age_minutes=60), NOW)[0], LARGE)

    def test_a_non_blacksmith_or_empty_variable_is_never_picked(self) -> None:
        for variable in ("", "glaeda-mini", "macos-26", "blacksmith-4vcpu-ubuntu-2404"):
            with self.subTest(variable=variable):
                self.assertEqual(picker.pick(variable, None, NOW)[0], SMALL)
                self.assertNotIn(variable, picker.candidates(variable)) if variable else None

    def test_every_label_stalled_still_names_one(self) -> None:
        self.assertEqual(picker.pick(LARGE, snapshot({LARGE: 90, SMALL: 90}), NOW)[0], SMALL)

    def test_the_alternate_is_the_other_size_and_prefers_a_moving_one(self) -> None:
        # Run 40489472569 (2026-10-27): both 26 sizes were stalled at the pick, so 6 vCPU won;
        # a re-run of its signing jobs must not queue on 6 vCPU again.
        for variable in ("", SMALL, LARGE, "glaeda-mini"):
            for waits in ({}, {SMALL: 90}, {LARGE: 90}, {SMALL: 90, LARGE: 90}):
                with self.subTest(variable=variable, waits=waits):
                    snap = snapshot(waits)
                    label = picker.pick(variable, snap, NOW)[0]
                    other = picker.alternate(variable, label, snap, NOW)
                    self.assertIn(other, (SMALL, LARGE))
                    stalled_others = {SMALL, LARGE} - {label} <= set(waits)
                    self.assertEqual(other == label, stalled_others)
        self.assertEqual(picker.alternate(LARGE, LARGE, None, NOW), SMALL)

    def test_a_stalled_alternate_is_never_offered(self) -> None:
        # Both sizes stalled at the pick: a re-run of failed jobs keeps the pick instead of
        # moving to a size the snapshot already saw stalled (12 vCPU, 2026-10-27 13:01Z on).
        snap = snapshot({SMALL: 90, LARGE: 90})
        self.assertEqual(picker.alternate("", SMALL, snap, NOW), SMALL)
        self.assertEqual(picker.alternate("", SMALL, snapshot({LARGE: 90}), NOW), SMALL)
        self.assertEqual(picker.alternate("", SMALL, snapshot({SMALL: 90}), NOW), LARGE)

    def test_a_failed_jobs_rerun_reads_attempt_ones_alternate(self) -> None:
        # Attempt 1's picker writes the other size; a re-run of failed jobs keeps that output.
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"CANDIDATE": "", "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r",
                   "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "1"}
            self.assertEqual(picker.main(env, read=lambda t, r: snapshot({SMALL: 3}), now=NOW), 0)
            self.assertEqual(output.read_text(), f"runner={SMALL}\nalternate={LARGE}\nplacement=verified\n")


    def test_a_pick_made_on_a_rerun_is_its_own_alternate(self) -> None:
        # A full re-run runs the picker again; its fresh pick must win over the other size.
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"CANDIDATE": "", "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r",
                   "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "2"}
            self.assertEqual(picker.main(env, read=lambda t, r: snapshot({LARGE: 90}), now=NOW), 0)
            self.assertEqual(output.read_text(), f"runner={SMALL}\nalternate={SMALL}\nplacement=verified\n")

    def test_main_writes_the_output_and_never_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"CANDIDATE": LARGE, "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output)}

            def broken(token: str, repo: str) -> dict:
                raise OSError("rate limit")
            self.assertEqual(picker.main(env, read=broken, now=NOW, sleep=lambda s: None), 0)
            # Unreadable: unverified, so the size with the most slots, not the variable (HQ#5168).
            self.assertEqual(output.read_text(), f"runner={SMALL}\nalternate={LARGE}\nplacement=unverified\n")
            output.write_text("")
            self.assertEqual(picker.main(env, read=lambda t, r: snapshot({LARGE: 90}), now=NOW), 0)
            # 12 vCPU is stalled, so a re-run keeps 6 vCPU rather than moving onto it.
            self.assertEqual(output.read_text(), f"runner={SMALL}\nalternate={SMALL}\nplacement=verified\n")


class LinuxPick(unittest.TestCase):
    """Release-pool signer jobs stay on the trusted Blacksmith Linux set."""

    def test_linux_picker_rotates_a_stalled_size(self) -> None:
        snap = linux_snapshot({LINUX4: 4, LINUX16: 2}, age_minutes=0)
        self.assertEqual(picker.linux_place(LINUX4, snap, NOW, 1)[:2], (LINUX16, LINUX32))

    def test_linux_picker_counts_snapshot_age_toward_stall(self) -> None:
        # A queue that was two minutes old in a fourteen-minute-old snapshot
        # has long passed the three-minute overflow threshold.
        snap = linux_snapshot({LINUX4: 2}, age_minutes=14)
        self.assertEqual(picker.linux_place(LINUX4, snap, NOW, 1)[:2], (LINUX16, LINUX32))

    def test_linux_picker_does_not_claim_a_mac_only_snapshot_is_verified(self) -> None:
        label, alternate, _, verified = picker.linux_place(LINUX4, snapshot({}), NOW, 1)
        self.assertEqual((label, alternate, verified), (LINUX4, LINUX16, False))

    def test_linux_picker_never_uses_a_hosted_or_unlisted_label(self) -> None:
        for variable in ("", "ubuntu-24.04", "glaeda-side-std-xcode-26.6"):
            label, alternate, _, _ = picker.linux_place(variable, None, NOW, 1)
            self.assertIn(label, picker.LINUX_LABELS)
            self.assertIn(alternate, picker.LINUX_LABELS)

    def test_linux_mode_writes_bounded_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"PLATFORM": "linux", "CANDIDATE": LINUX32, "SNAPSHOT_TOKEN": "t",
                   "GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output), "GITHUB_RUN_ATTEMPT": "1"}
            self.assertEqual(picker.main(env, read=lambda t, r: linux_snapshot({LINUX32: 90}), now=NOW), 0)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertIn(values["runner"], picker.LINUX_LABELS)
            self.assertIn(values["alternate"], picker.LINUX_LABELS)


class Unverified(unittest.TestCase):
    """Without a fresh pool snapshot the pick is unverified, and says so (HQ#5168).

    A missing, stale or unreadable snapshot used to hand the signing jobs vars.MACOS_RUNNER_26
    unchecked, the label that stranded every nightly for eight hours on 2026-10-26. Now the
    pick takes the size with the most slots (6 vCPU) and offers the other size to a re-run,
    marks the placement unverified in its outputs, a ::warning and the step summary, retries an
    unreadable read a bounded number of times, and still never fails the job.
    """

    def run_main(self, read, attempt: str = "1", candidate: str = LARGE, clock=None):
        with tempfile.TemporaryDirectory() as tmp:
            output, summary = Path(tmp) / "out", Path(tmp) / "summary"
            env = {"CANDIDATE": candidate, "SNAPSHOT_TOKEN": "t", "GITHUB_REPOSITORY": "o/r",
                   "GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary), "GITHUB_RUN_ATTEMPT": attempt}
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                kwargs = {"clock": clock} if clock else {}
                self.assertEqual(picker.main(env, read=read, now=NOW, sleep=lambda s: None, **kwargs), 0)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            return values, summary.read_text(), stdout.getvalue()

    def assert_unverified(self, values: dict, summary: str, stdout: str) -> None:
        self.assertEqual(values, {"runner": SMALL, "alternate": LARGE, "placement": "unverified"})
        self.assertIn("::warning title=nightly sign runner::", stdout)
        self.assertIn("unverified", stdout)
        self.assertIn("unverified", summary)

    def test_a_missing_snapshot_is_unverified_and_never_trusts_the_variable(self) -> None:
        self.assert_unverified(*self.run_main(lambda t, r: None))

    def test_a_stale_snapshot_is_unverified_and_never_trusts_the_variable(self) -> None:
        # 60 minutes old: past QUEUE_SNAPSHOT_MINUTES, so it says nothing about 12 vCPU now.
        values, summary, stdout = self.run_main(lambda t, r: snapshot({}, age_minutes=60))
        self.assert_unverified(values, summary, stdout)
        self.assertIn("stale", summary)

    def test_an_unreadable_snapshot_is_retried_a_bounded_number_of_times(self) -> None:
        calls = []

        def broken(token: str, repo: str) -> dict:
            calls.append(token)
            raise OSError("rate limit")
        values, summary, stdout = self.run_main(broken)
        self.assert_unverified(values, summary, stdout)
        self.assertEqual(len(calls), picker.SNAPSHOT_READS)
        self.assertIn("rate limit", summary)

    def test_the_retries_stop_at_the_deadline(self) -> None:
        # A read that takes the whole budget is not retried: the 2-minute step must still write its outputs.
        ticks = iter([0.0, picker.SNAPSHOT_READ_SECONDS + 1, picker.SNAPSHOT_READ_SECONDS + 1])
        calls = []

        def slow(token: str, repo: str) -> dict:
            calls.append(token)
            raise TimeoutError("timed out")
        values, *_ = self.run_main(slow, clock=lambda: next(ticks))
        self.assertEqual(len(calls), 1)
        self.assertEqual(values["placement"], "unverified")

    def test_a_read_that_recovers_is_verified(self) -> None:
        answers = [OSError("reset"), snapshot({SMALL: 90})]

        def flaky(token: str, repo: str) -> dict:
            answer = answers.pop(0)
            if isinstance(answer, Exception):
                raise answer
            return answer
        values, summary, _ = self.run_main(flaky)
        self.assertEqual(values, {"runner": LARGE, "alternate": LARGE, "placement": "verified"})
        self.assertNotIn("unverified", summary)

    def test_a_spent_read_token_falls_back_to_the_github_token(self) -> None:
        # Run 41335987427 (2026-11-01): the routing App's installation answered 403 with
        # X-RateLimit-Remaining=0 to every read, so the pick was blind. GITHUB_TOKEN has its own budget.
        calls = []

        def spent(token: str, repo: str) -> dict:
            calls.append(token)
            if token == "t":
                raise OSError("HTTP Error 403: Forbidden")
            return snapshot({SMALL: 90})
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            env = {"CANDIDATE": LARGE, "SNAPSHOT_TOKEN": "t", "SNAPSHOT_FALLBACK_TOKEN": "gh",
                   "GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(output)}
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(picker.main(env, read=spent, now=NOW, sleep=lambda s: None), 0)
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
        self.assertEqual(calls, ["t", "gh"])
        self.assertEqual(values, {"runner": LARGE, "alternate": LARGE, "placement": "verified"})

    def test_a_fallback_equal_to_the_read_token_adds_no_read(self) -> None:
        calls = []

        def broken(token: str, repo: str) -> dict:
            calls.append(token)
            raise OSError("rate limit")
        with tempfile.TemporaryDirectory() as tmp:
            env = {"CANDIDATE": LARGE, "SNAPSHOT_TOKEN": "t", "SNAPSHOT_FALLBACK_TOKEN": "t",
                   "GITHUB_REPOSITORY": "o/r", "GITHUB_OUTPUT": str(Path(tmp) / "out")}
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(picker.main(env, read=broken, now=NOW, sleep=lambda s: None), 0)
        self.assertEqual(calls, ["t"] * picker.SNAPSHOT_READS)

    def test_the_sign_pickers_pass_the_github_token_fallback(self) -> None:
        steps = WORKFLOW["jobs"]["pick-nightly-sign-runner"]["steps"]
        for step_id in ("sign-runner", "sign-linux-runner"):
            step = next(step for step in steps if step.get("id") == step_id)
            with self.subTest(step=step_id):
                self.assertEqual(step["env"]["SNAPSHOT_FALLBACK_TOKEN"], "${{ github.token }}")

    def test_a_full_rerun_without_a_snapshot_tries_the_other_size(self) -> None:
        # Attempt 1 took 6 vCPU unverified; a full re-run picks again, still blind, and moves to 12 vCPU.
        values, *_ = self.run_main(lambda t, r: None, attempt="2")
        self.assertEqual(values, {"runner": LARGE, "alternate": LARGE, "placement": "unverified"})
        values, *_ = self.run_main(lambda t, r: None, attempt="3")
        self.assertEqual(values, {"runner": SMALL, "alternate": SMALL, "placement": "unverified"})

    def test_no_token_is_unverified_too(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(picker.main({"CANDIDATE": LARGE, "GITHUB_OUTPUT": str(output)}, now=NOW), 0)
            self.assertEqual(output.read_text(), f"runner={SMALL}\nalternate={LARGE}\nplacement=unverified\n")


def observed(age_minutes: int = 2, **overrides: dict) -> dict:
    """The queue janitor's 2026-10-30 18:37Z snapshot, `age_minutes` old: both labels stalled by the queue rule,
    blacksmith-12vcpu-macos-26 with nothing running and no start (absent from label_started), 6 vCPU busy."""
    generated = NOW - dt.timedelta(minutes=age_minutes)
    pools = {LARGE: {"queued": 180, "running": 0, "oldest_queued_minutes": 1399},
             SMALL: {"queued": 77, "running": 5, "oldest_queued_minutes": 552}}
    for label, entry in overrides.items():
        pools[label] = {**pools[label], **entry}
    started = {SMALL: (generated - dt.timedelta(minutes=1)).strftime("%Y-%m-%dT%H:%M:%SZ")}
    return {"generated_at": generated.strftime("%Y-%m-%dT%H:%M:%SZ"), "pools": pools, "label_started": started}


class DeadLabel(unittest.TestCase):
    """A label that started nothing for an hour is dead, not busy (2026-10-30: run 41100841614's sign pick read a
    38-minute-old snapshot, took 6 vCPU unverified and offered the dead 12 vCPU label to every re-run)."""

    def test_an_unverified_pick_never_offers_a_label_a_stale_snapshot_shows_dead(self) -> None:
        for attempt in (1, 2, 3):
            with self.subTest(attempt=attempt):
                runner, other, _, verified = picker.place(LARGE, observed(age_minutes=38), NOW, attempt)
                self.assertEqual((runner, other, verified), (SMALL, SMALL, False))

    def test_a_dead_variable_label_is_skipped_even_with_its_queue_cleared(self) -> None:
        snap = observed(**{LARGE: {"queued": 0, "oldest_queued_minutes": 0}})
        self.assertEqual(picker.place(LARGE, snap, NOW, 1)[:2], (SMALL, SMALL))

    def test_with_every_label_stalled_the_pick_is_one_that_still_starts_jobs(self) -> None:
        snap = observed(**{SMALL: {"running": 0}, LARGE: {"running": 2}})
        snap["label_started"] = {LARGE: snap["label_started"][SMALL]}
        label, why = picker.pick(SMALL, snap, NOW)
        self.assertEqual(label, LARGE, why)
        self.assertEqual(picker.alternate(SMALL, LARGE, snap, NOW), LARGE)

    def test_a_truncated_snapshot_proves_no_label_dead(self) -> None:
        # Its listing missed in-flight runs, so it can miss a running job or a start on the label.
        snap = dict(observed(age_minutes=38), truncated=True)
        self.assertEqual(picker.dead(snap, NOW), set())
        self.assertEqual(picker.place(LARGE, snap, NOW, 1)[:2], (SMALL, LARGE))

    def test_an_unverified_pick_skips_a_dead_variable_label(self) -> None:
        """pick() is the overflow pick of nightly_build_runner.py:
        a snapshot too old for the stall rule still shows the label dead."""
        label, why = picker.pick(LARGE, observed(age_minutes=38), NOW)
        self.assertEqual(label, SMALL, why)
        self.assertIn("is dead", why)
        self.assertEqual(picker.pick(LARGE, None, NOW)[0], LARGE)
        self.assertEqual(picker.pick(LARGE, dict(observed(age_minutes=38), truncated=True), NOW)[0], LARGE)

    def test_no_label_showing_life_or_an_older_janitor_changes_nothing(self) -> None:
        both = observed(**{SMALL: {"running": 0}})
        both["label_started"] = {}
        self.assertEqual(picker.place(LARGE, both, NOW, 1)[:2], (SMALL, SMALL))  # every label stalled: DEFAULT
        # A stale snapshot showing both dead still offers no dead alternate (EveryLabelDead).
        self.assertEqual(picker.place(LARGE, dict(both, generated_at="2026-10-26T08:50:00Z"), NOW, 1)[:2],
                         (SMALL, SMALL))
        older = observed(age_minutes=38)
        del older["label_started"]
        self.assertEqual(picker.place(LARGE, older, NOW, 1)[:2], (SMALL, LARGE))
        # Past the evidence window a snapshot proves nothing.
        self.assertEqual(picker.place(LARGE, observed(age_minutes=7 * 60), NOW, 1)[:2], (SMALL, LARGE))



def stamp(moment: dt.datetime) -> str:
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def both_dead(age_minutes: int) -> dict:
    """2026-10-31 05:44Z: blacksmith-12vcpu-macos-26 88 queued, none running, the oldest 1403 min; 6 vCPU had
    started nothing for an hour either, so the snapshot shows both labels dead."""
    snap = observed(age_minutes, **{LARGE: {"queued": 88, "oldest_queued_minutes": 1403}, SMALL: {"running": 0}})
    snap["label_started"] = {SMALL: stamp(NOW - dt.timedelta(minutes=age_minutes + 70))}
    return snap


class EveryLabelDead(unittest.TestCase):
    """A re-run never takes a label the snapshot or RUNNER_POOLS' `_dead` marks show dead, even when every label
    shows dead: dead() drops evidence that names both, so a stale snapshot showing both dead still offered
    blacksmith-12vcpu-macos-26 as `alternate` (classic_nightly_build_runner.py had the same flaw, cmux#29018)."""

    def test_a_stale_snapshot_showing_both_dead_offers_no_dead_alternate(self) -> None:
        stale = both_dead(50)
        self.assertEqual(picker.dead(stale, NOW), set())
        self.assertEqual(picker.every_dead(stale, NOW), {LARGE, SMALL})
        for variable in (LARGE, SMALL, ""):
            with self.subTest(variable=variable):
                runner, other, _, verified = picker.place(variable, stale, NOW, 1)
                self.assertEqual((runner, other, verified), (SMALL, SMALL, False))
        # Fresh too: the alternate is never a dead label.
        runner, other, _, verified = picker.place(LARGE, both_dead(2), NOW, 1)
        self.assertTrue(verified)
        self.assertEqual(other, runner)

    def test_runner_pools_marks_count_as_dead(self) -> None:
        pools = {"macos_26": SMALL, "_dead": {LARGE: stamp(NOW - dt.timedelta(minutes=5))}}
        # No snapshot at all: the mark alone keeps the re-run and a 12 vCPU-first pick off 12 vCPU.
        self.assertEqual(picker.place(LARGE, None, NOW, 1, pools=pools)[:2], (SMALL, SMALL))
        self.assertEqual(picker.pick(LARGE, None, NOW, pools)[0], SMALL)
        self.assertEqual(picker.alternate(LARGE, SMALL, snapshot({}), NOW, pools), SMALL)
        # A mark older than runner_pools.DEAD_TTL, one in the future, or a malformed one proves nothing.
        for since in (stamp(NOW - dt.timedelta(minutes=45)), stamp(NOW + dt.timedelta(hours=1)), "soon", None):
            with self.subTest(since=since):
                old = {"macos_26": SMALL, "_dead": {LARGE: since}}
                self.assertEqual(picker.place(LARGE, None, NOW, 1, pools=old)[:2], (SMALL, LARGE))
        for raw in ("", "not json", "[1]", '{"_dead": []}'):
            with self.subTest(raw=raw):
                self.assertEqual(picker.marked_dead(picker.runner_pools(raw), NOW), set())

    def test_every_label_dead_takes_the_pools_live_member(self) -> None:
        pools = {"macos_26": LARGE, "_dead": {LARGE: stamp(NOW), SMALL: stamp(NOW)}}
        for attempt in (1, 2):
            with self.subTest(attempt=attempt):
                self.assertEqual(picker.place(SMALL, None, NOW, attempt, pools=pools)[:2], (LARGE, LARGE))
                self.assertEqual(picker.place(SMALL, both_dead(50), NOW, attempt, pools=pools)[:2], (LARGE, LARGE))
                self.assertEqual(picker.place(SMALL, both_dead(2), NOW, attempt, pools=pools)[:2], (LARGE, LARGE))
        # A member that is not a candidate is never printed, and the alternate is still never a dead label.
        odd = {**pools, "macos_26": "blacksmith-6vcpu-macos-15"}
        self.assertEqual(picker.place(LARGE, None, NOW, 1, pools=odd)[:2], (SMALL, SMALL))

    def test_main_reads_runner_pools(self) -> None:
        pools = '{"macos_26": "%s", "_dead": {"%s": "%s"}}' % (SMALL, LARGE, stamp(NOW))
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "out"
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(picker.main({"CANDIDATE": LARGE, "GITHUB_OUTPUT": str(output),
                                              "RUNNER_POOLS": pools}, now=NOW), 0)
            self.assertEqual(output.read_text(), f"runner={SMALL}\nalternate={SMALL}\nplacement=unverified\n")

    def test_every_picker_step_reads_runner_pools(self) -> None:
        steps = [step for job in WORKFLOW["jobs"].values() for step in job.get("steps", [])
                 if "nightly_sign_runner.py" in str(step.get("run", ""))]
        self.assertTrue(steps)
        for step in steps:
            self.assertEqual(step["env"].get("RUNNER_POOLS"), "${{ vars.RUNNER_POOLS }}")


class Workflow(unittest.TestCase):
    def test_signing_jobs_read_the_picked_label_first(self) -> None:
        jobs = WORKFLOW["jobs"]
        for name, picked in SIGNING_JOBS.items():
            with self.subTest(job=name):
                runs_on = str(jobs[name]["runs-on"])
                self.assertIn(f"|| {picked} || vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'", runs_on)
                # A re-run (attempt 2 on) takes the other size: GitHub never re-routes a queued job,
                # so a label that stalls after the pick is left only by a re-run, which must not
                # queue on it again (run 40489472569, 2026-10-27).
                self.assertIn(f"|| github.run_attempt > 1 && {ALTERNATES[picked]} || {picked} ||", runs_on)
                needs = jobs[name]["needs"]
                self.assertIn(picked.split(".")[1], [needs] if isinstance(needs, str) else needs)

    def test_owned_only_jobs_never_name_blacksmith(self) -> None:
        jobs = WORKFLOW["jobs"]
        for name in OWNED_ONLY_JOBS:
            with self.subTest(job=name):
                runs_on = str(jobs[name]["runs-on"])
                self.assertTrue(runs_on.endswith(OWNED_FALLBACK), runs_on)
                self.assertNotIn("blacksmith", runs_on)
                self.assertNotIn("MACOS_RUNNER", runs_on)
                self.assertNotIn("sign_runner", runs_on)
                self.assertNotIn("sign_alternate", runs_on)

    def test_no_other_macos_job_resolves_to_the_variable_alone(self) -> None:
        reads = {name for name, job in WORKFLOW["jobs"].items() if "vars.MACOS_RUNNER_26" in str(job.get("runs-on", ""))}
        self.assertEqual(reads - set(SIGNING_JOBS) - BUILD_JOBS, set(),
                         "a new macOS job reads vars.MACOS_RUNNER_26 for its route: give it a picked label "
                         "(scripts/ci/nightly_sign_runner.py) or add it to BUILD_JOBS if it signs nothing")
        for name in BUILD_JOBS & reads:
            with self.subTest(job=name):
                self.assertNotIn("environment", WORKFLOW["jobs"][name].get("environment", "") or "")

    def test_the_pickers_run_the_step_and_publish_its_output(self) -> None:
        jobs = WORKFLOW["jobs"]
        for job, output in (("pick-nightly-sign-runner", "runner"), ("find-nightly-next-recovery", "sign_runner"),
                            ("legacy-identity-target", "sign_runner")):
            with self.subTest(job=job):
                step = next(s for s in jobs[job]["steps"] if s.get("id") == "sign-runner")
                self.assertTrue(step["continue-on-error"])
                # The picker job checks out only the publication tooling (tests/test_nightly_cmux_tui_resolve.py).
                tooling = ".publish-tooling/" if job == "pick-nightly-sign-runner" else ""
                self.assertEqual(step["run"].strip(), f"python3 {tooling}scripts/ci/nightly_sign_runner.py")
                self.assertEqual(step["env"]["CANDIDATE"], "${{ vars.MACOS_RUNNER_26 }}")
                self.assertEqual(jobs[job]["outputs"][output], "${{ steps.sign-runner.outputs.runner }}")
                alternate = "alternate" if output == "runner" else "sign_alternate"
                self.assertEqual(jobs[job]["outputs"][alternate], "${{ steps.sign-runner.outputs.alternate }}")
                # legacy-identity-target takes release-next only for the release App credentials of its
                # gh calls (tests/test_gh_app_token.py); that environment has no reviewers, so nothing waits.
                # pick-nightly-sign-runner mints the routing token, so it reads GLAEDA_ROUTE_APP_KEY in
                # ci-routing-agent, as pick-nightly-build-runner does (tests/test_supplychain_security.py).
                expected = {"legacy-identity-target": "release-next", "pick-nightly-sign-runner": "ci-routing-agent"}
                self.assertEqual(jobs[job].get("environment"), expected.get(job))
        self.assertEqual(jobs["pick-nightly-sign-runner"]["permissions"], {"actions": "read", "contents": "read"})
        # A failed pick never blocks signing: the jobs fall back to the variable.
        self.assertTrue(jobs["pick-nightly-sign-runner"]["continue-on-error"])


class OwnedVerify(unittest.TestCase):
    """The secret-free verify jobs take a free owned Mac first, Blacksmith last (2026-10-26).

    nightly-next runs 40396929672 and 40403525126 waited over an hour on blacksmith-6vcpu-macos-26
    behind pull request compiles. The routing order is Linux, owned Macs, then Blacksmith last
    (Leo, 2026-10-24); the signing jobs, which hold the keys, stay on Blacksmith.
    """

    OWNED_JOBS = ("verify-signed-nightly", "verify-final-dmg-nightly", "signer-dmg-image")
    # The cmux NIGHTLY-identity verify, also secret-free, keeps its own picker's Blacksmith labels after
    # the owned pick: on 2026-10-28 it queued 20+ min on blacksmith-6vcpu-macos-26 while 12 vCPU was stalled.
    LEGACY_OWNED_JOBS = ("verify-nightly-identity-legacy",)
    OWNED = "needs.pick-nightly-sign-runner.outputs.owned"

    def test_verify_jobs_read_the_owned_pick_only_for_the_attempt_it_was_made_for(self) -> None:
        # Dispatch run 40594111618 (2026-10-27) reached signing on attempt 3, where signer-dmg-image waited
        # 51 min on blacksmith-6vcpu-macos-26: the pick ran only on attempt 1 of a push.
        jobs = WORKFLOW["jobs"]
        for name in self.OWNED_JOBS:
            with self.subTest(job=name):
                job = jobs[name]
                self.assertNotIn("environment", job)
                self.assertNotIn("secrets.", yaml.safe_dump(job))
                self.assertIn(f"|| needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && {self.OWNED} "
                              "|| github.ref_name == 'nightly-next' && github.run_attempt == 2 "
                              "&& needs.pick-nightly-sign-runner.outputs.attempt == 1 "
                              "&& vars.CI_PR_POOL_OWNED == '1' && "
                              "(vars.CI_NIGHTLY_NEXT_BUILD_RUNNER || vars.CI_SIDE_LANE_RUNNER) "
                              "|| github.run_attempt > 1 && "
                              "needs.pick-nightly-sign-runner.outputs.alternate || needs.pick-nightly-sign-runner.outputs.runner "
                              "|| vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-macos-26'", str(job["runs-on"]))
                xcode = job["env"]["CMUX_CI_XCODE_APP"]
                self.assertIn(f"needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && {self.OWNED} != '' "
                              "|| github.ref_name == 'nightly-next'", xcode)
                self.assertIn("&& vars.CMUX_CI_XCODE_APP_PR", xcode)
                self.assertIn("|| vars.CMUX_CI_XCODE_APP_MACOS_26", xcode)

    def test_failed_job_reruns_rejoin_the_fleet_pool_instead_of_an_old_pick(self) -> None:
        # Run 41253243235 attempt 2 kept attempt 1's picker and queued the DMG
        # image on the Blacksmith alternate after its build and notarization passed.
        from test_ci_fork_runner_routing import parse_expression
        from test_nightly_trusted_routing import evaluate

        base = {
            "github.repository_owner": "manaflow-ai", "github.ref_name": "nightly-next",
            "github.run_attempt": "2", "vars.CI_PR_POOL_OWNED": "1",
            "needs.pick-nightly-sign-runner.outputs.attempt": "1",
            self.OWNED: "glaeda-runner-old-single-host",
            "needs.pick-nightly-sign-runner.outputs.alternate": LARGE,
            "needs.pick-nightly-sign-runner.outputs.runner": SMALL,
            "vars.CI_NIGHTLY_NEXT_BUILD_RUNNER": "glaeda-nightly-std-xcode-26.6",
            "vars.CI_SIDE_LANE_RUNNER": "glaeda-side-std-xcode-26.6",
            "vars.CMUX_CI_XCODE_APP_PR": "/Applications/Xcode-fleet.app",
            "vars.CMUX_CI_XCODE_APP_MACOS_26": "/Applications/Xcode-overflow.app",
        }
        cases = (
            ({}, "glaeda-nightly-std-xcode-26.6", "fleet"),
            ({"vars.CI_NIGHTLY_NEXT_BUILD_RUNNER": ""}, "glaeda-side-std-xcode-26.6", "fleet"),
            ({"github.run_attempt": "3"}, LARGE, "overflow"),
            ({"github.run_attempt": "4"}, LARGE, "overflow"),
            ({"vars.CI_PR_POOL_OWNED": "0"}, LARGE, "overflow"),
            ({"vars.CI_NIGHTLY_NEXT_BUILD_RUNNER": "", "vars.CI_SIDE_LANE_RUNNER": ""}, LARGE, "overflow"),
            ({"github.ref_name": "main"}, LARGE, "overflow"),
            ({"github.repository_owner": "fork"}, "macos-26", "overflow"),
            ({"github.run_attempt": "1"}, "glaeda-runner-old-single-host", "fleet"),
            ({"github.run_attempt": "1", self.OWNED: ""}, SMALL, "overflow"),
            ({"needs.pick-nightly-sign-runner.outputs.attempt": "2", self.OWNED: ""}, LARGE, "overflow"),
            ({"needs.pick-nightly-sign-runner.outputs.attempt": "2", self.OWNED: "glaeda-side-light-xcode-26.6"},
             "glaeda-side-light-xcode-26.6", "fleet"),
        )
        for name in ("verify-signed-nightly", "verify-final-dmg-nightly", "signer-dmg-image"):
            job = WORKFLOW["jobs"][name]
            for changes, runner, xcode in cases:
                with self.subTest(job=name, changes=changes):
                    context = {**base, **changes}
                    def resolve(source):
                        return evaluate(parse_expression(source.removeprefix("${{").removesuffix("}}")), context)
                    self.assertEqual(resolve(job["runs-on"]), runner)
                    if context["github.repository_owner"] == "manaflow-ai":
                        self.assertEqual(resolve(job["env"]["CMUX_CI_XCODE_APP"]),
                                         f"/Applications/Xcode-{xcode}.app")

    def test_the_legacy_verify_reads_the_owned_pick_then_its_own_labels(self) -> None:
        jobs = WORKFLOW["jobs"]
        for name in self.LEGACY_OWNED_JOBS:
            with self.subTest(job=name):
                job = jobs[name]
                self.assertNotIn("environment", job)
                self.assertNotIn("secrets.", yaml.safe_dump(job))
                self.assertIn("pick-nightly-sign-runner", job["needs"])
                # A skipped or failed pick must not skip the verify.
                self.assertTrue(job["if"].startswith("!cancelled()"))
                self.assertIn(f"|| needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && {self.OWNED} "
                              + OWNED_FALLBACK, str(job["runs-on"]))
                xcode = job["env"]["CMUX_CI_XCODE_APP"]
                self.assertIn(f"needs.pick-nightly-sign-runner.outputs.attempt == github.run_attempt && {self.OWNED} != '' "
                              "&& vars.CMUX_CI_XCODE_APP_PR", xcode)
                self.assertIn("|| vars.CMUX_CI_XCODE_APP_MACOS_26", xcode)

    def test_no_job_that_holds_a_secret_reads_the_owned_pick(self) -> None:
        for name, job in WORKFLOW["jobs"].items():
            if self.OWNED not in str(job.get("runs-on", "")):
                continue
            with self.subTest(job=name):
                self.assertIn(name, self.OWNED_JOBS + self.LEGACY_OWNED_JOBS)
                self.assertFalse(job.get("environment"))
                self.assertNotIn("secrets.", yaml.safe_dump(job))

    def test_the_owned_pick_is_bounded_and_never_blocks(self) -> None:
        job = WORKFLOW["jobs"]["pick-nightly-sign-runner"]
        # Outside attempt 1 of a push the pick stands only with the sweeper's marker uploaded.
        self.assertEqual(job["outputs"]["owned"],
                         "${{ (github.event_name == 'push' && github.run_attempt == 1 || "
                         "steps.upload-marker.outcome == 'success') && steps.owned.outputs.owned || '' }}")
        self.assertEqual(job["outputs"]["attempt"], "${{ github.run_attempt }}")
        # The routing environment only scopes the routing App key; it has no reviewers, so nothing waits.
        self.assertEqual(job.get("environment"), "ci-routing-agent")
        step = next(s for s in job["steps"] if s.get("id") == "owned")
        self.assertTrue(step["continue-on-error"])
        self.assertNotIn("github.run_attempt == 1", step["if"])
        self.assertIn("vars.CI_PR_POOL_OWNED == '1'", step["if"])
        # Only where ci-owned-pool-rescue watches (nightly-next push and dispatch): a stuck owned job elsewhere
        # would never fall back.
        for name in ("route-token", "owned"):
            guard = next(s for s in job["steps"] if s.get("id") == name)["if"]
            with self.subTest(step=name):
                self.assertIn("(github.event_name == 'push' || github.event_name == 'workflow_dispatch') "
                              "&& github.ref_name == 'nightly-next'", guard)
                self.assertEqual(guard.count("||"), 1)
        marker = next(s for s in job["steps"] if s.get("id") == "marker")
        self.assertIn("github.event_name != 'push' || github.run_attempt != 1", marker["if"])
        upload = next(s for s in job["steps"] if s.get("id") == "upload-marker")
        self.assertEqual(upload["with"]["name"], "owned-pool-watch")
        # The build picker's owned rule (nightly_build_runner.py verify), over the labels it offers the build,
        # not the pull request pool picker: run 40515681971's verify got blacksmith-6vcpu-macos-15 from that one
        # while owned side runners sat idle.
        self.assertEqual(step["run"].strip(), "python3 .publish-tooling/scripts/ci/nightly_build_runner.py verify")
        self.assertNotIn("e2e_runner_pool.py", yaml.safe_dump(job))
        self.assertEqual(step["env"]["OWNED_LABELS"],
                         "${{ format('{0} {1}', vars.CI_NIGHTLY_NEXT_BUILD_RUNNER, vars.CI_SIDE_LANE_RUNNER) }}")
        self.assertEqual(step["env"]["CANDIDATE"], "${{ vars.MACOS_RUNNER_26 }}")
        self.assertNotIn("DEDICATED_LABEL", step["env"])
        # The job outlives its step budgets, and the Blacksmith pick comes first: a slow App API
        # never cancels the job before `runner` is written (a cancelled pick skips signing).
        ids = [s.get("id") for s in job["steps"]]
        self.assertLess(ids.index("sign-runner"), ids.index("route-token"))
        budget = sum(int(s.get("timeout-minutes", 0)) for s in job["steps"])
        self.assertTrue(all("timeout-minutes" in s for s in job["steps"] if s.get("id")))
        self.assertGreaterEqual(int(job["timeout-minutes"]), budget + 2)


class SnapshotReadToken(unittest.TestCase):
    """The two nightly pickers read the pool snapshot with the routing App's own budget.

    Run 41051244674 (2026-10-30, pick-nightly-sign-runner): with SNAPSHOT_TOKEN set to GITHUB_TOKEN,
    every snapshot read got "HTTP 403 X-RateLimit-Remaining=0 ... API rate limit exceeded for
    installation", the repo-wide GITHUB_TOKEN budget. The sign pick fell to "placement unverified",
    signing_runner.py offered no owned Mac, and signing queued behind PR overflow on Blacksmith. The
    pickers already mint GLAEDA_ROUTE_APP_KEY in ci-routing-agent, so each also mints an actions: read
    token from it, as cmux-next.yml's macos-placement does, and falls back to GITHUB_TOKEN.
    """

    PICKERS = ("pick-nightly-build-runner", "pick-nightly-sign-runner")
    READ = "${{ steps.snapshot-read-token.outputs.token || github.token }}"
    KEY = "secrets.GLAEDA_ROUTE_APP_KEY"
    # The jobs that read the routing App key; no other job gains it (find-nightly-next-recovery and
    # legacy-identity-target keep reading the snapshot with GITHUB_TOKEN). route-visual-gate-nightly
    # picks the visual gate's idle owned Mac with it (docs/ci/nightly-next-visual-gate.md).
    # build-nightly-app reads it in one step after the build, to place the light jobs that follow it on an
    # idle mini (runner list read only; cmux-next-guards.yml's portable-placement reads it the same way on
    # pull requests, outside the environment).
    # decide places early controls through the same read-only routing App.
    KEYED_JOBS = {"decide", "pick-nightly-build-runner", "pick-nightly-sign-runner", "route-visual-gate-nightly",
                  "build-nightly-app", "pick-legacy-identity-runner"}

    def test_each_snapshot_read_uses_the_read_token_with_the_github_token_fallback(self) -> None:
        for name in self.PICKERS:
            job = WORKFLOW["jobs"][name]
            steps = job["steps"]
            ids = [step.get("id") for step in steps]
            readers = [index for index, step in enumerate(steps) if "SNAPSHOT_TOKEN" in (step.get("env") or {})]
            with self.subTest(job=name):
                self.assertTrue(readers)
                mint_at = ids.index("snapshot-read-token")
                self.assertLess(mint_at, min(readers))
                for index in readers:
                    self.assertEqual(steps[index]["env"]["SNAPSHOT_TOKEN"], self.READ, steps[index].get("name"))

    def test_the_read_mint_asks_only_actions_read_of_the_routing_app(self) -> None:
        for name in self.PICKERS:
            job = WORKFLOW["jobs"][name]
            mint = next(step for step in job["steps"] if step.get("id") == "snapshot-read-token")
            route = next(step for step in job["steps"] if step.get("id") == "route-token")
            with self.subTest(job=name):
                self.assertEqual(mint["uses"], route["uses"])
                self.assertTrue(mint["uses"].startswith("actions/create-github-app-token@"))
                self.assertEqual(mint["with"]["app-id"], "${{ vars.GLAEDA_ROUTE_APP_ID }}")
                self.assertEqual(mint["with"]["private-key"], "${{ secrets.GLAEDA_ROUTE_APP_KEY }}")
                self.assertEqual({key: value for key, value in mint["with"].items() if key.startswith("permission-")},
                                 {"permission-actions": "read"})
                # A failed mint never blocks the pick: the reads fall back to GITHUB_TOKEN.
                self.assertTrue(mint["continue-on-error"])
                self.assertEqual(int(mint["timeout-minutes"]), 1)
                # Minted only where the routing token already is (nightly-next push and dispatch).
                self.assertEqual(mint["if"], route["if"])
                # No widening: the job keeps actions: read and contents: read, in the routing environment.
                self.assertEqual(job["permissions"], {"actions": "read", "contents": "read"})
                self.assertEqual(job["environment"], "ci-routing-agent")
                budget = sum(int(step.get("timeout-minutes", 0)) for step in job["steps"])
                self.assertGreaterEqual(int(job["timeout-minutes"]), budget)

    def test_no_other_job_gains_the_routing_app_key(self) -> None:
        keyed = {name for name, job in WORKFLOW["jobs"].items() if self.KEY in yaml.safe_dump(job)}
        self.assertEqual(keyed, self.KEYED_JOBS)
        for name, job in WORKFLOW["jobs"].items():
            if name in self.KEYED_JOBS:
                continue
            with self.subTest(job=name):
                self.assertNotIn("snapshot-read-token", yaml.safe_dump(job))


if __name__ == "__main__":
    unittest.main()
