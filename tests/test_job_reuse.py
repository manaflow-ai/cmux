#!/usr/bin/env python3
"""scripts/ci/job_reuse.py: a job reuses only a pass that a trusted run of this repository recorded.

A pass is an Actions artifact named after the job's input key (scripts/ci/job_input_fingerprint.py).
Artifacts are listed repository-wide, so a pull request reads the passes that the base and other pull
requests recorded, which a GitHub cache entry scoped to another pull request's ref never allows. Any run
can upload an artifact, a fork pull request's included, so the lookup takes only an artifact whose run
came from this repository (head repository = repository). A lookup that fails reuses nothing.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/job_reuse.py"
sys.path.insert(0, str(ROOT / "scripts/ci"))

REPO_ID = 1000
FORK_ID = 2000
KEY = "job-pass-swift-test-" + "a" * 40


def artifact(run_id: int, *, name: str = KEY, head_repo: int = REPO_ID, repo: int = REPO_ID,
             expired: bool = False, created: str = "2026-10-21T10:00:00Z", sha: str = "b" * 40) -> dict:
    return {"id": run_id * 10, "name": name, "expired": expired, "created_at": created,
            "workflow_run": {"id": run_id, "repository_id": repo, "head_repository_id": head_repo,
                             "head_branch": "topic", "head_sha": sha}}


def lookup(artifacts: list[dict] | str, key: str = KEY, **env: str) -> tuple[dict, str, int]:
    with tempfile.TemporaryDirectory() as tmp:
        listing = Path(tmp) / "artifacts.json"
        listing.write_text(artifacts if isinstance(artifacts, str) else json.dumps(
            {"total_count": len(artifacts), "artifacts": artifacts}))
        environment = {"PATH": os.environ.get("PATH", ""), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                       "GITHUB_REPOSITORY_ID": str(REPO_ID), "GITHUB_SERVER_URL": "https://github.com", **env}
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "lookup", "--key", key,
                                 "--artifacts-json", str(listing)],
                                capture_output=True, text=True, timeout=60, env=environment)
    outputs = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    return outputs, result.stderr, result.returncode


class Lookup(unittest.TestCase):
    def test_a_pass_from_this_repository_is_reused_and_named(self):
        outputs, _, code = lookup([artifact(77, sha="c" * 40)])
        self.assertEqual(code, 0)
        self.assertEqual(outputs["hit"], "true")
        self.assertEqual(outputs["run_url"], "https://github.com/manaflow-ai/cmux/actions/runs/77")
        self.assertEqual(outputs["sha"], "c" * 40)

    def test_a_fork_pass_is_never_reused(self):
        # A fork pull request's run can upload an artifact under any name; its head repository is the fork.
        outputs, stderr, code = lookup([artifact(78, head_repo=FORK_ID)])
        self.assertEqual(code, 0)
        self.assertEqual(outputs["hit"], "false")
        outputs, _, _ = lookup([artifact(79, repo=FORK_ID, head_repo=FORK_ID)])
        self.assertEqual(outputs["hit"], "false")

    def test_a_trusted_pass_is_found_among_fork_passes(self):
        outputs, _, _ = lookup([artifact(80, head_repo=FORK_ID, created="2026-10-21T12:00:00Z"),
                                artifact(81, created="2026-10-21T09:00:00Z")])
        self.assertEqual(outputs["hit"], "true")
        self.assertTrue(outputs["run_url"].endswith("/runs/81"))

    def test_the_newest_trusted_pass_is_named(self):
        outputs, _, _ = lookup([artifact(82, created="2026-10-21T09:00:00Z"),
                                artifact(83, created="2026-10-21T11:00:00Z")])
        self.assertTrue(outputs["run_url"].endswith("/runs/83"))

    def test_an_expired_pass_or_another_key_is_not_reused(self):
        self.assertEqual(lookup([artifact(84, expired=True)])[0]["hit"], "false")
        self.assertEqual(lookup([artifact(85, name=KEY[:-1] + "b")])[0]["hit"], "false")
        self.assertEqual(lookup([])[0]["hit"], "false")

    def test_a_failed_lookup_reuses_nothing(self):
        outputs, stderr, code = lookup("not json")
        self.assertEqual((code, outputs["hit"]), (0, "false"))
        self.assertIn("::notice", stderr)
        # No repository id: nothing can be checked, so nothing is trusted.
        environment = {"GITHUB_REPOSITORY_ID": ""}
        outputs, _, code = lookup([artifact(86)], **environment)
        self.assertEqual((code, outputs["hit"]), (0, "false"))

    def test_without_a_listing_or_a_token_it_reuses_nothing(self):
        environment = {"PATH": os.environ.get("PATH", ""), "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                       "GITHUB_REPOSITORY_ID": str(REPO_ID)}
        result = subprocess.run([sys.executable, "-I", str(SCRIPT), "lookup", "--key", KEY],
                                capture_output=True, text=True, timeout=60, env=environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("hit=false", result.stdout)

    def test_a_key_that_is_not_a_pass_key_is_refused(self):
        outputs, _, code = lookup([artifact(87, name="job-pass-x")], key="job-pass-x/../y")
        self.assertEqual((code, outputs["hit"]), (0, "false"))


if __name__ == "__main__":
    unittest.main()
