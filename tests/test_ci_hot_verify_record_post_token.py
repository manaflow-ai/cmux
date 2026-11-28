"""cmux-next-hot-verify.yml: the proof record's first posting token can comment on the pull request.

2026-11-28 21:25Z (cmux#62219 run 46191523658, cmux#65006): every token the record was posted with was scoped
read-only for issues ("Resource not accessible by integration", create-an-issue-comment), so cmux/ui-proof stayed
pending on a look that passed.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-hot-verify.yml"


class HotVerifyRecordPostTokenTest(unittest.TestCase):
    def test_the_record_posts_first_on_a_token_minted_with_issues_write(self) -> None:
        doc = yaml.safe_load(WORKFLOW.read_text())
        found = False
        for job in doc["jobs"].values():
            steps = job.get("steps", [])
            post = next((s for s in steps if s.get("name") == "Post the proof record"), None)
            if post is None:
                continue
            found = True
            first = post["env"]["POST_TOKENS"].split("}}")[0] + "}}"
            self.assertEqual(first.strip(), "${{ steps.cmux-bot-post-token.outputs.token }}")
            mint = next(s for s in steps if s.get("id") == "cmux-bot-post-token")
            self.assertEqual(mint["with"].get("permission-issues"), "write")
        self.assertTrue(found)


if __name__ == "__main__":
    unittest.main()
