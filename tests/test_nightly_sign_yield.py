"""An older nightly-next build hands its sign slot to a newer build whose sign job exists; the newest never yields
(scripts/ci/nightly_sign_yield.py, cmuxterm-hq#7079)."""

from pathlib import Path
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/nightly_sign_yield.py"
WORKFLOW = ROOT / ".github/workflows/nightly.yml"
spec = importlib.util.spec_from_file_location("nightly_sign_yield", SCRIPT)
sy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sy)

REPO = "manaflow-ai/cmux"
SIGN = "build-sign-notarize-nightly (arm64)"


def env(run_id=100, **over):
    base = {"GITHUB_REPOSITORY": REPO, "GITHUB_RUN_ID": str(run_id), "GITHUB_RUN_ATTEMPT": "1",
            "GITHUB_EVENT_NAME": "push", "GITHUB_REF_NAME": "nightly-next", "TRACK": "nightly-next"}
    base.update(over)
    return base


def job(name, status, conclusion=None):
    return {"id": hash((name, status)) & 0xFFFF, "name": name, "status": status, "conclusion": conclusion}


class Fake:
    """runs: {run id: [jobs]} of the in-progress nightly-next push runs."""

    def __init__(self, runs, fail=None):
        self.runs, self.fail, self.paths = runs, fail, []

    def __call__(self, path):
        self.paths.append(path)
        if self.fail and self.fail in path:
            raise sy.Unreadable("refused")
        if "/actions/workflows/nightly.yml/runs" in path:
            items = [{"id": rid} for rid in self.runs]
            return {"total_count": len(items), "workflow_runs": items}
        rid = int(path.split("/actions/runs/")[1].split("/")[0])
        jobs = self.runs[rid]
        return {"total_count": len(jobs), "jobs": jobs}


def decide(run_id, runs, **over):
    return sy.decide(env(run_id, **over), Fake(runs), log=lambda _: None)


class SignYieldTest(unittest.TestCase):
    def test_the_newest_queued_build_never_yields(self):
        # The 2026-11-04 shape: three older signs running, three queued. The newest queued one signs.
        runs = {100: [job(SIGN, "in_progress")], 101: [job(SIGN, "in_progress")], 102: [job(SIGN, "in_progress")],
                103: [job(SIGN, "queued")], 104: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]}
        self.assertEqual(decide(105, runs)[0], False)
        # A newer run whose sign job does not exist yet (its build is still running) is no reason either.
        runs[106] = [job("build-nightly-app", "in_progress"), job("decide", "completed", "success")]
        self.assertEqual(decide(105, runs)[0], False)

    def test_an_older_build_yields_to_a_newer_queued_running_or_signed_sign_job(self):
        for state in (("queued", None), ("in_progress", None), ("completed", "success")):
            with self.subTest(state=state):
                yielded, why = decide(103, {103: [job(SIGN, "queued")], 105: [job(SIGN, *state)]})
                self.assertTrue(yielded)
                self.assertIn("105", why)

    def test_a_newer_push_alone_never_counts(self):
        # #33109's rule still holds for a newer push: no sign job, or one that failed, was skipped or cancelled.
        for jobs in ([], [job("build-nightly-app", "queued")], [job(SIGN, "completed", "failure")],
                     [job(SIGN, "completed", "skipped")], [job(SIGN, "completed", "cancelled")],
                     [job("sign-nightly-identity-legacy", "queued")]):
            with self.subTest(jobs=jobs):
                self.assertEqual(decide(103, {103: [job(SIGN, "queued")], 105: jobs})[0], False)

    def test_an_older_run_is_never_a_reason(self):
        self.assertEqual(decide(105, {101: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]})[0], False)

    def test_outside_attempt_1_of_a_nightly_next_push_it_signs_without_a_read(self):
        runs = {103: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]}
        for over in ({"GITHUB_RUN_ATTEMPT": "2"}, {"GITHUB_EVENT_NAME": "workflow_dispatch"},
                     {"GITHUB_REF_NAME": "main"}, {"TRACK": "nightly"}, {"NIGHTLY_NEXT_SIGN_YIELD": "0"},
                     {"GITHUB_RUN_ID": "x"}):
            with self.subTest(over=over):
                fake = Fake(runs)
                self.assertEqual(sy.decide(env(103, **over), fake, log=lambda _: None)[0], False)
                self.assertEqual(fake.paths, [])

    def test_any_doubt_signs(self):
        runs = {103: [job(SIGN, "queued")], 105: [job(SIGN, "queued")]}
        for fail in ("/actions/workflows/", "/actions/runs/105/"):
            with self.subTest(fail=fail):
                self.assertEqual(sy.decide(env(103), Fake(runs, fail=fail), log=lambda _: None)[0], False)
        # A listing that does not add up, and a job with no status.
        short = lambda path: {"total_count": 3, "workflow_runs": [{"id": 105}]}
        self.assertEqual(sy.decide(env(103), short, log=lambda _: None)[0], False)
        bad = {103: [], 105: [{"id": 1, "name": SIGN}]}
        self.assertEqual(decide(103, bad)[0], False)

    def test_the_cli_writes_yielded_and_exits_1_only_when_it_yields(self):
        # No network: an unreadable API (a closed port) signs, writes yielded=false and exits 0.
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            proc = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True,
                                  env={**os.environ, **env(103), "GITHUB_OUTPUT": str(out), "GH_TOKEN": "x",
                                       "GITHUB_API_URL": "http://127.0.0.1:9"})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(out.read_text(), "yielded=false\n")


class SignYieldWiringTest(unittest.TestCase):
    def setUp(self):
        self.jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        self.sign = self.jobs["build-sign-notarize-nightly"]
        self.names = [step.get("name") for step in self.sign["steps"]]

    def test_the_yield_runs_right_after_the_claim_and_before_any_secret(self):
        at = self.names.index("Yield the sign slot to a newer build")
        self.assertEqual(self.names[at - 1], "Claim the whole Mac for signing")
        step = self.sign["steps"][at]
        self.assertEqual(step["run"], "python3 .nightly-signing-control/scripts/ci/nightly_sign_yield.py")
        self.assertNotIn("secrets.", str(step))
        self.assertNotIn("continue-on-error", step)
        self.assertNotIn("if", step)
        for earlier in self.sign["steps"][:at]:
            self.assertNotIn("secrets.", str(earlier), earlier.get("name"))
        self.assertEqual(self.sign["outputs"]["yielded"], "${{ steps.sign-yield.outputs.yielded }}")

    def test_report_nightly_failure_skips_only_a_yielded_sign(self):
        script = self.jobs["report-nightly-failure"]["steps"][0]["with"]["script"]
        self.assertIn("results['build-sign-notarize-nightly']?.outputs?.yielded === 'true'", script)
        self.assertIn("!(yielded && k === 'build-sign-notarize-nightly')", script)
        self.assertIn("if (yielded && failed.length === 0", script)


if __name__ == "__main__":
    unittest.main()
