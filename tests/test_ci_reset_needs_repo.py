#!/usr/bin/env python3
"""A workspace-repair `git reset --hard HEAD` runs only when a checkout made a repository.

cmux-tui artifacts run 45680718623 (2026-11-25, nightly-next 2bb1acadcd): "wait for same-key tree
publisher" checks out its claim scripts only when the preflight names an owner run, so on a fresh pool
runner the next step, "Repair a reused self-hosted checkout", ran `git reset -q --hard HEAD` in an empty
workspace: "fatal: not a git repository", exit 128. The job failed, the tree for the tip was never
published, and the nightly could not resolve its cmux-tui client. A repair with nothing to repair must
be a no-op, so every such reset sits behind `git rev-parse --git-dir`.
"""

from __future__ import annotations

import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
RESET = "git reset -q --hard HEAD"
GUARD = "if git rev-parse --git-dir >/dev/null 2>&1; then"


class ResetNeedsRepo(unittest.TestCase):
    def test_every_workflow_reset_is_guarded(self) -> None:
        seen = 0
        unguarded = []
        for path in sorted(WORKFLOWS.glob("*.yml")):
            lines = path.read_text().splitlines()
            for index, line in enumerate(lines):
                if line.strip() != RESET:
                    continue
                seen += 1
                if index == 0 or lines[index - 1].strip() != GUARD:
                    unguarded.append(f"{path.name}:{index + 1}")
        self.assertGreater(seen, 0, "no workspace reset found; this test checks nothing")
        self.assertEqual(unguarded, [], "a `git reset --hard HEAD` that fails when no checkout ran")

    def test_the_guarded_reset_passes_in_an_empty_workspace(self) -> None:
        # The step body as the workflows write it, under the runner's `bash -e -o pipefail`.
        body = f"set -e -o pipefail\n{GUARD}\n  {RESET}\nfi\n"
        with tempfile.TemporaryDirectory() as empty:
            result = subprocess.run(["bash", "-c", body], cwd=empty, capture_output=True, text=True,
                                    env={"PATH": "/usr/bin:/bin", "GIT_CEILING_DIRECTORIES": str(Path(empty).parent)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(re.search(r"not a git repository", result.stderr))


if __name__ == "__main__":
    unittest.main()
