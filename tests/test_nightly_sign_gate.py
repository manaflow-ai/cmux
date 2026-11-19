"""A superseded nightly-next build leaves in resolve, before it takes the signing Mac (scripts/ci/nightly_sign_gate.py).

Leo, 2026-11-19: "if i wait for the nightly then i might as well just update to the thing".

Run: python3 tests/test_nightly_sign_gate.py
"""

from __future__ import annotations

import datetime as dt
import importlib.util
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_nightly_sign_yield as ty  # noqa: E402  (its Fake, feed and job helpers)

sys.modules["nightly_sign_yield"] = ty.sy  # one Unreadable class for the gate and the yield test's Fake
SCRIPT = ROOT / "scripts/ci/nightly_sign_gate.py"
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
spec = importlib.util.spec_from_file_location("nightly_sign_gate", SCRIPT)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

ONE = "nightly-next-one"
SPLIT = "build-sign-notarize-nightly"


def env(run_id=100, sign_job=ONE, **over):
    return ty.env(run_id, SIGN_JOB=sign_job, **over)


def decide(run_id, runs, published=(1,), sign_job=ONE, created=None, now=ty.NOW, **over):
    fake = ty.Fake(runs, created=created)
    result = gate.decide(env(run_id, sign_job, **over), fake, feed=lambda: ty.feed(*published),
                         now=lambda: now, log=lambda _: None)
    return result, fake


def resolve_job():
    return yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]["resolve-nightly-cmux-tui-client"]


class SignGateDecisionTest(unittest.TestCase):
    def test_a_newer_build_on_the_feed_supersedes_without_reading_runs(self):
        for sign_job in (ONE, SPLIT):
            with self.subTest(sign_job=sign_job):
                (superseded, why), fake = decide(100, {}, published=(99, 101), sign_job=sign_job)
                self.assertTrue(superseded)
                self.assertIn("10101", why)
                self.assertEqual(fake.paths, [], "a certain answer reads no run")

    def test_the_feed_compares_whole_build_numbers_so_a_rerun_of_the_published_run_is_not_superseded(self):
        # Attempt 2 of run 100 builds 10002, above the feed's 10001 (attempt 1 of the same run).
        (superseded, _), _ = decide(100, {}, published=(100,), GITHUB_RUN_ATTEMPT="2")
        self.assertFalse(superseded)

    def test_an_older_or_equal_feed_and_no_newer_signer_builds(self):
        for published in ((), (99,), (100,)):
            with self.subTest(published=published):
                (superseded, _), _ = decide(100, {100: [ty.job(ONE, "pending")]}, published=published)
                self.assertFalse(superseded)

    def test_a_newer_runs_queued_pending_or_running_one_job_supersedes(self):
        for status in ("queued", "pending", "waiting", "in_progress"):
            with self.subTest(status=status):
                (superseded, why), _ = decide(100, {101: [ty.job(ONE, status)]})
                self.assertTrue(superseded)
                self.assertIn("101", why)

    def test_a_newer_finished_one_job_is_no_reason_since_it_may_have_left_its_slot(self):
        # nightly-next-one ends green when it leaves its slot; only the feed (above) reads a finished one.
        for state in (("completed", "success"), ("completed", "failure"), ("completed", "skipped")):
            with self.subTest(state=state):
                (superseded, _), _ = decide(100, {101: [ty.job(ONE, *state)]})
                self.assertFalse(superseded)

    def test_the_split_sign_job_keeps_the_yield_rule_where_a_signed_newer_job_counts(self):
        (superseded, _), _ = decide(100, {101: [ty.job(f"{SPLIT} (arm64)", "completed", "success")]}, sign_job=SPLIT)
        self.assertTrue(superseded)
        # The other topology's job is not this run's sign job.
        (superseded, _), _ = decide(100, {101: [ty.job(ONE, "in_progress")]}, sign_job=SPLIT)
        self.assertFalse(superseded)

    def test_a_newer_push_alone_never_counts(self):
        (superseded, _), _ = decide(100, {101: [ty.job("decide", "in_progress")]})
        self.assertFalse(superseded)

    def test_leos_thirty_minute_rule_pins_an_unpublished_landing(self):
        landed = {100: ty.NOW - dt.timedelta(minutes=31), 101: ty.NOW}
        (superseded, why), _ = decide(100, {101: [ty.job(ONE, "pending")]}, created=landed)
        self.assertFalse(superseded)
        self.assertIn("due", why)

    def test_doubt_builds_and_signs(self):
        def unreadable():
            raise gate.sy.Unreadable("down")
        superseded, why = gate.decide(env(100), ty.Fake({}), feed=unreadable, log=lambda _: None)
        self.assertEqual((superseded, why), (False, "unreadable feed"))
        superseded, _ = gate.decide(env(100), ty.Fake({101: [ty.job(ONE, "pending")]}, fail="/runs"),
                                    feed=lambda: ty.feed(1), log=lambda _: None)
        self.assertFalse(superseded)

    def test_scope_and_switch(self):
        runs = {101: [ty.job(ONE, "pending")]}
        for over in ({"NIGHTLY_NEXT_SIGN_GATE": "0"}, {"TRACK": "nightly"}, {"GITHUB_REF_NAME": "main"},
                     {"SIGN_JOB": ""}, {"GITHUB_RUN_ID": "x"}):
            with self.subTest(over=over):
                superseded, _ = gate.decide({**env(100), **over}, ty.Fake(runs), feed=lambda: ty.feed(1),
                                            log=lambda _: None)
                self.assertFalse(superseded)
        # The yield's own scope: a re-run or a dispatch reads only the feed.
        for over in ({"GITHUB_RUN_ATTEMPT": "2"}, {"GITHUB_EVENT_NAME": "workflow_dispatch"}):
            with self.subTest(over=over):
                (superseded, _), _ = decide(100, runs, **over)
                self.assertFalse(superseded)
                (superseded, _), _ = decide(100, runs, published=(105,), **over)
                self.assertTrue(superseded)


class SignGateCliTest(unittest.TestCase):
    def test_the_cli_writes_superseded_and_always_exits_0(self):
        import os
        import tempfile
        from unittest import mock
        for answer in ((True, "newer"), (False, "none")):
            with self.subTest(answer=answer), tempfile.TemporaryDirectory() as tmp:
                out = Path(tmp) / "out"
                with mock.patch.dict(os.environ, {"GITHUB_OUTPUT": str(out)}), \
                        mock.patch.object(gate, "decide", lambda *_a, **_k: answer):
                    self.assertEqual(gate.main(), 0)
                self.assertEqual(out.read_text(), f"superseded={'true' if answer[0] else 'false'}\n")


class SignGateWorkflowTest(unittest.TestCase):
    def test_resolve_runs_the_gate_after_the_slot_check_and_exports_it(self):
        job = resolve_job()
        ids = [s.get("id") for s in job["steps"]]
        self.assertIn("sign-gate", ids)
        self.assertLess(ids.index("superseded"), ids.index("sign-gate"))
        step = job["steps"][ids.index("sign-gate")]
        self.assertEqual(step["run"], "python3 scripts/ci/nightly_sign_gate.py")
        self.assertEqual(step.get("continue-on-error"), "true", "a failed gate must not fail the run")
        self.assertIn("steps.superseded.outputs.superseded != 'true'", step["if"])
        self.assertIn("github.event_name == 'push'", step["if"])
        self.assertIn("nightly-next-one", step["env"]["SIGN_JOB"])
        self.assertIn("build-sign-notarize-nightly", step["env"]["SIGN_JOB"])
        self.assertTrue(job["outputs"]["superseded"].startswith("${{ steps.sign-gate.outputs.superseded == 'true' && 'true' ||"))
        self.assertIn("steps.sign-superseded.outputs.superseded", job["outputs"]["superseded"])

    def test_both_sign_jobs_and_the_retry_skip_on_resolves_superseded(self):
        jobs = yaml.load(WORKFLOW.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
        for name in (ONE, SPLIT, "retry-nightly-next"):
            with self.subTest(job=name):
                self.assertIn("needs.resolve-nightly-cmux-tui-client.outputs.superseded != 'true'", jobs[name]["if"])

    def test_the_gate_wins_only_with_true_since_the_slot_steps_false_is_a_truthy_string(self):
        # GitHub's || returns its first truthy operand and 'false' is truthy, so the gate's answer must be compared
        # to 'true' first; the slot step's own answer (true or false) and the sign stage's follow, as before.
        expr = resolve_job()["outputs"]["superseded"][3:-2].strip()
        self.assertEqual(expr, "steps.sign-gate.outputs.superseded == 'true' && 'true' || "
                               "steps.superseded.outputs.superseded || steps.sign-superseded.outputs.superseded")


if __name__ == "__main__":
    unittest.main()
