"""The bug-fix proof-section warning that gh-merge-green prints."""
import importlib.util
import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/pr_proof_section.py"
spec = importlib.util.spec_from_file_location("pr_proof_section", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProofSectionTests(unittest.TestCase):
    def test_bug_fix_titles_and_label(self):
        for title in ("fix: x", "fix(sidebar): x", "fix!: x", "bugfix: x", "Fix the sidebar", "fixes a crash", "  FIX: y", "Bug fix: x", "Fixing the crash"):
            with self.subTest(title=title):
                self.assertTrue(module.is_bug_fix({"title": title}))
        for title in ("feat: x", "fixture cleanup", "perf: prefix fix", "docs: fix typo", "fix-ups for docs", "Fixups"):
            with self.subTest(title=title):
                self.assertFalse(module.is_bug_fix({"title": title}))
        self.assertTrue(module.is_bug_fix({"title": "sidebar", "labels": [{"name": "bug"}]}))

    def test_observed_heading_or_bold_line_counts(self):
        for body in ("## Observed / Not run\n- ok", "### Observed\n", "**Observed**: ran it", "#Observed", "- **Observed:** ran it", "> ## Observed"):
            with self.subTest(body=body):
                self.assertTrue(module.has_proof_section(body))
        for body in ("", "We observed it.", "<!-- ## Observed -->", "## Testing\nObserved: ok", "### Observed behavior\nIt crashes.",
                     "```md\n## Observed\n```"):
            with self.subTest(body=body):
                self.assertFalse(module.has_proof_section(body))

    def test_warns_only_for_bug_fix_with_body_and_no_section(self):
        self.assertIsNotNone(module.warning({"title": "fix: x", "body": "## Summary"}))
        self.assertIsNone(module.warning({"title": "fix: x", "body": "## Observed\n"}))
        self.assertIsNone(module.warning({"title": "feat: x", "body": ""}))
        # No body field (old metadata or a stub): nothing to judge.
        self.assertIsNone(module.warning({"title": "fix: x"}))

    def test_cli_never_fails(self):
        for stdin in ("not json", "[]", json.dumps({"title": "fix: x", "body": ""})):
            with self.subTest(stdin=stdin):
                result = subprocess.run([sys.executable, str(SCRIPT)], input=stdin, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
