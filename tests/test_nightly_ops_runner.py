#!/usr/bin/env python3
"""The owned nightly-ops runners admit only merged nightly workflow code on trusted refs."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))
import nightly_ops_runner as ops  # noqa: E402

GIB = 1024 ** 3


def env(**over):
    base = {
        "GITHUB_REPOSITORY": "manaflow-ai/cmux",
        "GITHUB_WORKFLOW_REF": "manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/nightly-next",
        "GITHUB_JOB": "decide",
        "GITHUB_EVENT_NAME": "push",
        "GITHUB_REF": "refs/heads/nightly-next",
    }
    base.update(over)
    return base


class AdmitTest(unittest.TestCase):
    def test_admits_nightly_jobs_on_trusted_refs(self):
        cases = {
            "nightly-next push": env(),
            "dispatch": env(GITHUB_EVENT_NAME="workflow_dispatch"),
            "main schedule": env(GITHUB_REF="refs/heads/main", GITHUB_EVENT_NAME="schedule",
                                 GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/nightly-next-tick.yml@refs/heads/main"),
            "main workflow_run": env(GITHUB_REF="refs/heads/main", GITHUB_EVENT_NAME="workflow_run",
                                     GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/auto-resume-nightly-notarization.yml@refs/heads/main"),
        }
        for name, case in cases.items():
            with self.subTest(case=name):
                ok, reason = ops.admit(case, {"workflow_run": {"event": "push", "pull_requests": []}}, 100 * GIB)
                self.assertTrue(ok, reason)

    def test_refuses_everything_else(self):
        cases = {
            "other repo": (env(GITHUB_REPOSITORY="someone/cmux"), {}),
            "non-nightly workflow": (env(GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/ci.yml@refs/heads/nightly-next"), {}),
            "pull request event": (env(GITHUB_EVENT_NAME="pull_request", GITHUB_REF="refs/pull/1/merge",
                                       GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/nightly.yml@refs/pull/1/merge"), {}),
            "untrusted branch": (env(GITHUB_REF="refs/heads/x",
                                     GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/x"), {}),
            "workflow from another ref": (env(GITHUB_WORKFLOW_REF="manaflow-ai/cmux/.github/workflows/nightly.yml@refs/heads/x"), {}),
            "pull request payload": (env(), {"pull_request": {"number": 1}}),
            "run started by a pull request": (env(GITHUB_EVENT_NAME="workflow_run"),
                                              {"workflow_run": {"event": "pull_request", "pull_requests": [{"number": 1}]}}),
            "unset environment": ({}, {}),
        }
        for name, (case, event) in cases.items():
            with self.subTest(case=name):
                ok, _ = ops.admit(case, event, 100 * GIB)
                self.assertFalse(ok)

    def test_refuses_on_a_full_disk(self):
        ok, reason = ops.admit(env(), {}, 5 * GIB)
        self.assertFalse(ok)
        self.assertIn("GiB free", reason)

    def test_a_crash_refuses(self):
        import os
        old = dict(os.environ)
        try:
            os.environ.clear()
            os.environ["GITHUB_WORKSPACE"] = "/nonexistent/path/for/test"
            self.assertEqual(ops.main(["nightly_ops_runner.py", "admit"]), 1)
        finally:
            os.environ.clear()
            os.environ.update(old)


if __name__ == "__main__":
    unittest.main()
