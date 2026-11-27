#!/usr/bin/env python3
"""cmux-tui-tree-request.yml pr=N: an open same-repository PR's head gets one cmux-tui artifacts dispatch on its
branch, which publishes the head's tree and cmux-tui/<sha>/mac-live.json, so `cmux app try N` goes live for a
daemon-only PR (lane branches never build on push, and a lane cannot dispatch one). Runs the step's own shell with
gh and curl stubbed.

Run: python3 tests/test_cmux_tui_tree_request_pr.py
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/cmux-tui-tree-request.yml").read_text())
SHA = "b" * 40


def run_step(pr: str, pulls: str, live: bool) -> tuple[int, list[str], str]:
    job = WORKFLOW["jobs"]["request-pr"]
    script = job["steps"][0]["run"]
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        calls = root / "calls"
        (root / "gh").write_text(
            '#!/usr/bin/env bash\necho "gh $*" >> "$CALLS"\n'
            'if [[ "$1" == api ]]; then printf "%s\\n" "$PULLS"; fi\n'
        )
        (root / "curl").write_text(f'#!/usr/bin/env bash\necho "curl $*" >> "$CALLS"\nexit {0 if live else 22}\n')
        for name in ("gh", "curl"):
            (root / name).chmod(0o755)
        summary = root / "summary"
        env = {**os.environ, "PATH": f"{root}:{os.environ['PATH']}", "CALLS": str(calls), "PULLS": pulls,
               "PR": pr, "REPO": "manaflow-ai/cmux", "GITHUB_RUN_ID": "1", "GITHUB_STEP_SUMMARY": str(summary)}
        done = subprocess.run(["bash", "-e", "-c", script], env=env, capture_output=True, text=True)
        lines = calls.read_text().splitlines() if calls.exists() else []
        return done.returncode, lines, (summary.read_text() if summary.exists() else "") + done.stdout


def open_pr(branch: str = "lane/daemon-fix", repo: str = "manaflow-ai/cmux", state: str = "open") -> str:
    return f"{state}\t{branch}\t{SHA}\t{repo}"


class TreeRequestPr(unittest.TestCase):
    def test_an_open_lane_pr_head_is_dispatched_on_its_branch(self) -> None:
        code, calls, summary = run_step("123", open_pr(), live=False)
        self.assertEqual(code, 0)
        self.assertIn("gh workflow run cmux-tui-artifacts.yml --repo manaflow-ai/cmux --ref lane/daemon-fix "
                      "-f daemon_tests=false", calls)
        self.assertIn(f"cmux-tui/{SHA}/mac-live.json", summary)
        self.assertIn("cmux app try 123", summary)

    def test_a_head_with_a_live_file_is_not_built_again(self) -> None:
        code, calls, summary = run_step("123", open_pr(), live=True)
        self.assertEqual(code, 0)
        self.assertFalse([c for c in calls if "workflow run" in c])
        self.assertIn("nothing is built", summary)

    def test_refusals_dispatch_nothing(self) -> None:
        for pr, pulls in (("abc", open_pr()), ("123", open_pr(state="closed")),
                          ("123", open_pr(repo="someone/fork")), ("123", open_pr(branch="cmux-tui-pin-x")),
                          ("123", open_pr(branch="feat-cmux-next"))):
            with self.subTest(pr=pr, pulls=pulls):
                code, calls, _ = run_step(pr, pulls, live=False)
                self.assertNotEqual(code, 0)
                self.assertFalse([c for c in calls if "workflow run" in c])

    def test_the_commit_job_and_the_pr_job_never_both_run(self) -> None:
        jobs = WORKFLOW["jobs"]
        self.assertIn("inputs.pr == ''", jobs["request"]["if"])
        self.assertIn("inputs.pr != ''", jobs["request-pr"]["if"])
        for job in ("request", "request-pr"):
            self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", jobs[job]["if"])
        self.assertEqual(jobs["request-pr"]["permissions"], {"actions": "write", "pull-requests": "read"})


if __name__ == "__main__":
    unittest.main()
