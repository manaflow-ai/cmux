#!/usr/bin/env python3
"""A media tour retries a before tree's submodule clone.

Run 45837430593 (job 139976029698) lost ghostty-next's clone in the before
tree 8f9660c2 to "curl 18" and "early EOF"; that tree had no app, so the
befores of warn-before-quit-shortcut, iphone-pairs-without-qr and
space-button-spacing were all dropped. Both before trees (the merge base and
each other before) now run submodules(), which tries 3 times. This test runs
the function from the workflow against a fake git that fails N times.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-media.yml"

FAKE_GIT = """#!/usr/bin/env bash
here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
n=$(( $(cat "$here/calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$here/calls"
[ "$n" -gt "$(cat "$here/fails")" ] || { echo "error: RPC failed; curl 18" >&2; exit 1; }
"""


def steps():
    doc = yaml.safe_load(WORKFLOW.read_text())
    for job in doc["jobs"].values():
        for step in job.get("steps", []):
            run = step.get("run", "")
            if "submodule" in run:
                yield step.get("name", ""), run


def function(run: str) -> str:
    m = re.search(r"^submodules\(\) \{.*?^\}$", run, re.S | re.M)
    assert m, "submodules() not defined"
    return m.group(0)


class SubmoduleRetryTest(unittest.TestCase):
    def test_every_tree_uses_the_retry(self):
        found = list(steps())
        self.assertGreaterEqual(len(found), 2)
        for name, run in found:
            bare = [l for l in run.splitlines()
                    if "submodule update" in l and '"$1"' not in l]
            self.assertEqual(bare, [], f"{name}: bare submodule update")
            if 'submodules "' in run:
                function(run)

    def run_with(self, fails: int):
        _, run = next((n, r) for n, r in steps() if 'submodules "$tree"' in r)
        with tempfile.TemporaryDirectory() as d:
            bin_ = Path(d)
            (bin_ / "git").write_text(FAKE_GIT)
            (bin_ / "git").chmod(0o755)
            (bin_ / "fails").write_text(str(fails))
            # Each try runs submodules-from-local.sh from the workspace: stand in the fake git for it.
            ws = bin_ / "ws"
            (ws / "scripts/cmux-next/media").mkdir(parents=True)
            (ws / "scripts/cmux-next/media/submodules-from-local.sh").symlink_to(bin_ / "git")
            script = function(run) + '\nsubmodules /tree\n'
            env = {**os.environ, "PATH": f"{d}:{os.environ['PATH']}", "GITHUB_WORKSPACE": str(ws),
                   "MEDIA_SUBMODULE_RETRY_SECONDS": "0"}
            p = subprocess.run(["bash", "-c", script], env=env, capture_output=True)
            return p.returncode, int((bin_ / "calls").read_text())

    def test_two_failures_then_success(self):
        self.assertEqual(self.run_with(2), (0, 3))

    def test_three_failures_give_up(self):
        code, calls = self.run_with(3)
        self.assertNotEqual(code, 0)
        self.assertEqual(calls, 3)

    def test_success_first_try(self):
        self.assertEqual(self.run_with(0), (0, 1))


if __name__ == "__main__":
    unittest.main()
