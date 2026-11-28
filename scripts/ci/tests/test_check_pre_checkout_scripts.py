#!/usr/bin/env python3
"""check_pre_checkout_scripts.py: a repo script run before checkout is a hit; a mention is not."""
import pathlib
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
import check_pre_checkout_scripts as module  # noqa: E402

REPO = ROOT.parents[1]

# The step incident general/1114 tripped on (cmux-next.yml generated-files, before this fix).
INCIDENT = """\
on: push
jobs:
  generated-files:
    runs-on: [self-hosted]
    steps:
      - name: Log the Mac fallback
        run: bash scripts/ci/cmux-next-steps/generated-files-linux.sh fallback
      - name: Checkout
        uses: actions/checkout@v6
"""


class InvokedPathsTests(unittest.TestCase):
    def test_invocations_are_hits(self):
        for run, want in [
            ("bash scripts/ci/a.sh fallback", "scripts/ci/a.sh"),
            ("python3 -I scripts/ci/b.py", "scripts/ci/b.py"),
            ("./scripts/c.sh", "./scripts/c.sh"),
            ("set -e; tools/wt new", "tools/wt"),
            ("FOO=1 node .github/x.js", ".github/x.js"),
            ("if bash scripts/d.sh; then :; fi", "scripts/d.sh"),
            ("source scripts/env.sh", "scripts/env.sh"),
        ]:
            self.assertEqual(module.invoked_paths(run), [want], run)

    def test_mentions_are_not_hits(self):
        for run in [
            "needs_verdict() {  # scripts/ci/needs_verdict.py SHELL_RULE (tests/test_needs_verdict.py)",
            "# runs scripts/ci/x.sh later",
            'gh api "repos/$R/actions/workflows/ios.yml/runs" --jq \'.path == ".github/workflows/cmux-next.yml"\'',
            'git --git-dir="$m" archive "$SHA" scripts/ci | tar -x -C "$GITHUB_WORKSPACE"',
            'echo "scripts/ci of $SHA"',
            'bash "$RUNNER_TEMP/scripts/x.sh"',
        ]:
            self.assertEqual(module.invoked_paths(run), [], run)


class FileTests(unittest.TestCase):
    def write(self, text: str) -> pathlib.Path:
        tmp = pathlib.Path(tempfile.mkdtemp()) / "w.yml"
        tmp.write_text(textwrap.dedent(text))
        return tmp

    def test_incident_step_is_a_hit(self):
        hits = module.check_file(self.write(INCIDENT))
        self.assertEqual(len(hits), 1)
        self.assertIn("generated-files-linux.sh", hits[0])

    def test_after_checkout_is_fine(self):
        fixed = INCIDENT.replace(
            "      - name: Log the Mac fallback\n        run: bash scripts/ci/cmux-next-steps/generated-files-linux.sh fallback\n", "")
        fixed += "      - name: Log the Mac fallback\n        run: bash scripts/ci/cmux-next-steps/generated-files-linux.sh fallback\n"
        self.assertEqual(module.check_file(self.write(fixed)), [])

    def test_local_action_before_checkout_is_a_hit(self):
        text = INCIDENT.replace("run: bash scripts/ci/cmux-next-steps/generated-files-linux.sh fallback",
                                "uses: ./.github/actions/setup")
        self.assertEqual(len(module.check_file(self.write(text))), 1)

    def test_job_without_checkout_is_skipped(self):
        text = INCIDENT.replace("      - name: Checkout\n        uses: actions/checkout@v6\n", "")
        self.assertEqual(module.check_file(self.write(text)), [])

    def test_repository_workflows_are_clean(self):
        self.assertEqual(module.main([str(REPO / ".github" / "workflows")]), 0)


if __name__ == "__main__":
    unittest.main()
