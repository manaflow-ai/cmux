"""hashFiles() matches only files under the workspace (GITHUB_WORKSPACE).

A gate like `hashFiles(format('{0}/x', runner.temp)) != ''` is therefore always false: the step it guards
never runs. swift-linux-packages.yml's Mac-fallback handoff was gated that way, so every Linux failure
went green unhanded (run 45812450713, job 139886253605: ios-kit ran 637 tests, 2 failed, job green).
This scans every workflow and composite action for hashFiles() pointed outside the workspace, and runs
the handoff step to show it hands a failure and stays quiet without one.
"""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
OUTSIDE = re.compile(r"runner\.temp|RUNNER_TEMP|runner\.tool_cache|env\.HOME|github\.action_path|['\"]/")


def hashfiles_args(text):
    """Every hashFiles( ... ) call's argument text, balanced on parentheses."""
    out = []
    for match in re.finditer(r"hashFiles\(", text):
        depth, i = 1, match.end()
        while i < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[i], 0)
            i += 1
        out.append(text[match.end():i - 1])
    return out


class HashFilesWorkspaceOnly(unittest.TestCase):
    def test_no_hashfiles_outside_the_workspace(self):
        files = sorted((ROOT / ".github").rglob("*.yml")) + sorted((ROOT / ".github").rglob("*.yaml"))
        self.assertTrue(files)
        bad = []
        for path in files:
            for args in hashfiles_args(path.read_text()):
                if OUTSIDE.search(args):
                    bad.append(f"{path.relative_to(ROOT)}: hashFiles({args})")
        self.assertEqual(bad, [], "hashFiles() sees only the workspace; test the file in the step instead")

    def test_detector_catches_the_old_gate(self):
        old = "if: always() && hashFiles(format('{0}/linux-failed.tsv', runner.temp)) != ''"
        self.assertTrue(any(OUTSIDE.search(a) for a in hashfiles_args(old)))
        self.assertFalse(any(OUTSIDE.search(a) for a in hashfiles_args("key: x-${{ hashFiles('**/Package.resolved') }}")))


class FallbackHandoff(unittest.TestCase):
    def run_handoff(self, tsv):
        job = yaml.safe_load((ROOT / ".github/workflows/swift-linux-packages.yml").read_text())["jobs"]["swift-linux-packages"]
        step = next(s for s in job["steps"] if s.get("id") == "handoff")
        self.assertNotIn("hashFiles", step["if"])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            if tsv:
                (root / "linux-failed.tsv").write_text(tsv)
            out, summary = root / "out", root / "summary"
            run = step["run"].replace("${{ matrix.group }}", "ios-kit")
            env = {**os.environ, "RUNNER_TEMP": str(root), "GITHUB_OUTPUT": str(out), "GITHUB_STEP_SUMMARY": str(summary)}
            result = subprocess.run(["bash", "-c", run], cwd=root, env=env, text=True, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            handed = out.read_text() if out.exists() else ""
            copied = (root / "linux-failed-ios-kit.tsv").exists()
            return handed, copied

    def test_a_linux_failure_is_handed(self):
        handed, copied = self.run_handoff("whole\tcmux-next-ios/CmuxMobileKit\t\n")
        self.assertIn("handed=1", handed)
        self.assertTrue(copied)

    def test_no_failure_hands_nothing(self):
        handed, copied = self.run_handoff("")
        self.assertNotIn("handed=1", handed)
        self.assertFalse(copied)


if __name__ == "__main__":
    unittest.main()
