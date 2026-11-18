#!/usr/bin/env python3
"""scripts/ci/gh_pages.py pages a GitHub list one `gh api` call per page.

The agent hosts' gh-quota shim refuses `gh api --paginate`. gh-merge-green read a
pull request's files, check runs and statuses that way, so on every host with
the shim those reads were refused, and the cmux-next paths and Vercel gates
refused the merge.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAGER = ROOT / "scripts" / "ci" / "gh_pages.py"

# A gh that refuses --paginate as the shim does, logs each call, and answers
# ?page=N from the JSON file pages.json next to it (a list of pages).
FAKE_GH = """#!/usr/bin/env python3
import json, pathlib, re, sys
here = pathlib.Path(sys.argv[0]).parent
args = sys.argv[1:]
with open(here / "calls", "a") as log:
    log.write(" ".join(args) + "\\n")
if "--paginate" in args:
    print("gh-quota: refused: `gh api --paginate` makes any number of requests", file=sys.stderr)
    sys.exit(3)
pages = json.loads((here / "pages.json").read_text())
n = int(re.search(r"[?&]page=(\\d+)", args[-1]).group(1))
print(json.dumps(pages[n - 1] if n <= len(pages) else []))
"""


class GhPagesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="gh-pages-")
        self.addCleanup(temporary.cleanup)
        self.bin = Path(temporary.name)
        gh = self.bin / "gh"
        gh.write_text(FAKE_GH)
        gh.chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.bin}{os.pathsep}{os.environ.get('PATH', '')}"}

    def pager(self, pages, *argv):
        (self.bin / "pages.json").write_text(json.dumps(pages))
        return subprocess.run([sys.executable, str(PAGER), *argv], env=self.env, text=True,
                              capture_output=True, timeout=60)

    def calls(self):
        return (self.bin / "calls").read_text().splitlines()

    def test_lists_each_items_field_across_pages_one_call_each(self):
        first = [{"filename": f"a/{n}.swift", "patch": "@@"} for n in range(100)]
        second = [{"filename": "b.md"}, {"filename": "c.png"}]
        result = self.pager([first, second], "repos/o/r/pulls/7/files?per_page=100", "filename")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [f"a/{n}.swift" for n in range(100)] + ["b.md", "c.png"])
        self.assertEqual(len(self.calls()), 2)
        self.assertTrue(all("--paginate" not in call for call in self.calls()), self.calls())

    def test_skips_items_without_the_field(self):
        result = self.pager([[{"filename": "a", "patch": "@@ -1 +1 @@"}, {"filename": "b.png"}]],
                            "repos/o/r/pulls/7/files?per_page=100", "patch")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "@@ -1 +1 @@\n")

    def test_without_a_field_prints_the_pages_as_slurp_did(self):
        page = {"total_count": 1, "check_runs": [{"name": "ci", "conclusion": "success"}]}
        result = self.pager([page], "repos/o/r/commits/abc/check-runs?per_page=100")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [page])

    def test_a_refused_page_fails_closed_with_no_output(self):
        gh = self.bin / "gh"
        gh.write_text("#!/bin/sh\necho 'gh: Server Error (HTTP 502)' >&2\nexit 1\n")
        result = self.pager([], "repos/o/r/pulls/7/files?per_page=100", "filename")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")


class GhMergeGreenNeverPaginatesTests(unittest.TestCase):
    """Detector: the shim refuses `gh api --paginate`, so gh-merge-green pages through gh_pages.py."""

    def test_gh_merge_green_has_no_paginate_call(self):
        source = (ROOT / "scripts" / "gh-merge-green").read_text()
        calls = [line.strip() for line in source.splitlines()
                 if re.search(r"--paginate\b", line) and not line.lstrip().startswith("#")]
        self.assertEqual(calls, [], "page with scripts/ci/gh_pages.py instead")


if __name__ == "__main__":
    unittest.main()
