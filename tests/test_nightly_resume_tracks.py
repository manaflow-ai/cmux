#!/usr/bin/env python3
"""The nightly notarization continuation only resumes main's and RC's tracks.

nightly-next publishes to its own release, feed and R2 bucket from the
release-next environment (nightly.yml on nightly-next). This workflow runs on
main and publishes to the `nightly` release and main's feed, so resuming a
nightly-next run here would put a cmux-next build on main's nightly feed.
"""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/auto-resume-nightly-notarization.yml"
SHA = "a" * 40


def preflight_check(branch: str) -> tuple[str, str]:
    """Runs the preflight step up to the artifact lookup; returns (exit code, GITHUB_OUTPUT)."""
    step = yaml.safe_load(WORKFLOW.read_text())["jobs"]["preflight"]["steps"][0]
    script = step["run"].split('gh api "repos/$GITHUB_REPOSITORY/actions/runs/$SOURCE_RUN_ID/artifacts', 1)[0]
    with tempfile.TemporaryDirectory() as temp:
        temp_path = Path(temp)
        run = {
            "path": ".github/workflows/nightly.yml",
            "repository": {"full_name": "o/r"},
            "head_sha": SHA,
            "head_branch": branch,
            "run_attempt": 1,
            "event": "push",
            "conclusion": "failure",
        }
        bin_dir = temp_path / "bin"
        bin_dir.mkdir()
        gh = bin_dir / "gh"
        gh.write_text(f"#!/bin/sh\ncat <<'JSON'\n{json.dumps(run)}\nJSON\n")
        gh.chmod(0o755)
        output = temp_path / "output"
        output.touch()
        env = dict(
            os.environ,
            PATH=f"{bin_dir}:{os.environ['PATH']}",
            RUNNER_TEMP=temp,
            GITHUB_OUTPUT=str(output),
            GITHUB_REPOSITORY="o/r",
            SOURCE_RUN_ID="1",
            SOURCE_RUN_ATTEMPT="1",
            SOURCE_HEAD_SHA=SHA,
            SOURCE_BRANCH=branch,
            SOURCE_REPOSITORY="o/r",
        )
        # The part before the artifact lookup ends in `exit 0` for a skipped
        # source; a resumable one falls through, which `exit 3` marks here.
        result = subprocess.run(["bash", "-c", script + "\nexit 3\n"], env=env, capture_output=True, text=True)
        return str(result.returncode), output.read_text()


class NightlyResumeTrackTests(unittest.TestCase):
    def test_nightly_next_is_not_resumed_on_main_s_channel(self):
        status, output = preflight_check("nightly-next")
        self.assertEqual(status, "0", output)
        self.assertIn("ready=false", output.splitlines())
        self.assertIn("reason=nightly-next-continues-on-its-own-track", output.splitlines())

    def test_main_and_rc_are_resumed(self):
        for branch in ("main", "rc/1.2"):
            status, output = preflight_check(branch)
            self.assertEqual(status, "3", f"{branch}: {output}")
            self.assertNotIn("ready=false", output.splitlines())

    def test_other_branches_are_not_published(self):
        status, output = preflight_check("feature")
        self.assertEqual(status, "0", output)
        self.assertIn("reason=source-branch-is-not-published", output.splitlines())


if __name__ == "__main__":
    unittest.main()
