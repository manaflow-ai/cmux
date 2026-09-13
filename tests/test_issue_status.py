#!/usr/bin/env python3
"""Offline contract tests for scripts/issue-status.sh."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "issue-status.sh"


def fake_gh(directory: Path) -> Path:
    path = directory / "gh"
    path.write_text(
        """#!/usr/bin/env python3
import json
import os
import sys

args = sys.argv[1:]
comments_file = os.environ["COMMENTS_FILE"]
if args[:2] == ["issue", "view"]:
    if "--json" in args and args[args.index("--json") + 1] == "comments":
        comments = open(comments_file).read() if os.path.exists(comments_file) else ""
        print(comments, end="")
    else:
        print(json.dumps({"number": 42, "url": "https://github.com/manaflow-ai/cmux/issues/42", "title": "Example"}))
elif args[:2] == ["pr", "view"]:
    print(json.dumps({"state": "MERGED", "mergedAt": "2026-09-13T00:00:00Z", "url": "https://github.com/manaflow-ai/cmux/pull/99"}))
elif args[:2] == ["issue", "comment"]:
    body = args[args.index("--body") + 1]
    with open(comments_file, "a") as file:
        file.write(body + "\\n")
    print("https://github.com/manaflow-ai/cmux/issues/42#issuecomment-1")
else:
    raise SystemExit(f"unexpected gh invocation: {args!r}")
"""
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def run(state: str, *options: str, comments: str = "") -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        gh = fake_gh(directory)
        comments_file = directory / "comments"
        comments_file.write_text(comments)
        env = os.environ | {"GH_BIN": str(gh), "COMMENTS_FILE": str(comments_file)}
        return subprocess.run(
            [str(SCRIPT), state, "42", "--run-id", "test-run", *options],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )


class IssueStatusTests(unittest.TestCase):
    def test_start_comment_is_exact_and_dry_run(self) -> None:
        result = run("taking-a-look", "--dry-run")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.endswith("Taking a look at this now.\n"))
        self.assertIn("cmux-issue-status state=taking-a-look issue=42 run=test-run", result.stdout)

    def test_needs_detail_requires_detail_text(self) -> None:
        result = run("needs-detail", "--dry-run")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires --details", result.stderr)

    def test_resolved_requires_merged_pr(self) -> None:
        result = run("resolved", "--dry-run", "--pr", "https://github.com/manaflow-ai/cmux/pull/99")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Resolved in https://github.com/manaflow-ai/cmux/pull/99.", result.stdout)

    def test_duplicate_marker_is_idempotent(self) -> None:
        marker = "<!-- cmux-issue-status state=deferred issue=42 run=test-run -->"
        result = run("deferred", comments=marker + "\n")
        self.assertEqual(result.returncode, 0)
        self.assertIn("already posted", result.stdout)


if __name__ == "__main__":
    unittest.main()
