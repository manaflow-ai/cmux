#!/usr/bin/env python3
"""scripts/ci/pr_ran_line.py: the status comment's `ran` line names the workflows a diff starts and why.

Each case writes a small .github/workflows tree and checks which workflows the line says ran: a path filter that
admits a changed file starts its workflow and names that file, one that admits none leaves it out, a workflow with
no filter is listed under "on every PR", and a trigger whose branches or activity types a push to a pull request
into the base does not fire is not counted.
"""
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import pr_ran_line  # noqa: E402

WORKFLOWS = {
    "web.yml": "name: web\non:\n  pull_request:\n    paths: ['webviews/**']\n",
    "rust.yml": "name: rust\non:\n  pull_request:\n    paths: ['cmux-tui/**', '!cmux-tui/**/*.md']\n",
    "always.yml": "name: always\non:\n  pull_request:\n",
    "main-only.yml": "name: main only\non:\n  pull_request:\n    branches: [main]\n",
    "closed.yml": "name: closed\non:\n  pull_request:\n    types: [closed]\n",
    "docs-ignored.yml": "name: not docs\non:\n  pull_request:\n    paths-ignore: ['docs/**']\n",
    "push.yml": "name: push only\non:\n  push:\n",
}


class RanLineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / ".github" / "workflows").mkdir(parents=True)
        for name, text in WORKFLOWS.items():
            (self.root / ".github" / "workflows" / name).write_text(text)

    def tearDown(self):
        self.tmp.cleanup()

    def started(self, changed, branch="feat-cmux-next"):
        runs, skipped = pr_ran_line.plan(self.root, branch, changed)
        return {r.name: r.why for r in runs}, skipped

    def test_a_web_change_starts_web_and_the_unfiltered_workflows_only(self):
        runs, skipped = self.started(["webviews/src/a.tsx", "webviews/src/b.tsx"])
        self.assertEqual(runs, {"web": "webviews/src/a.tsx +1", "always": "", "not docs": "webviews/src/a.tsx +1"})
        self.assertEqual(skipped, 2)  # rust and main only; closed and push-only workflows are not counted

    def test_a_negated_pattern_keeps_its_workflow_off(self):
        runs, _ = self.started(["cmux-tui/README.md"])
        self.assertNotIn("rust", runs)

    def test_a_docs_only_change_starts_only_the_unfiltered_workflow(self):
        runs, _ = self.started(["docs/x.md"])
        self.assertEqual(runs, {"always": ""})

    def test_a_branch_filter_admits_its_branch(self):
        runs, _ = self.started(["docs/x.md"], branch="main")
        self.assertIn("main only", runs)

    def test_the_line_says_every_pr_and_not_started(self):
        text = pr_ran_line.ran_line(self.root, "feat-cmux-next", ["webviews/src/a.tsx"])
        self.assertEqual(text, "ran 3 workflows for this diff: not docs (webviews/src/a.tsx), web (webviews/src/a.tsx); "
                               "on every PR: always; not started: 2 (no changed file in their paths)")


if __name__ == "__main__":
    unittest.main()
