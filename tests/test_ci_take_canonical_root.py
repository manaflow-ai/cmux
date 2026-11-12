#!/usr/bin/env python3
"""Tests for the authoritative Glaeda canonical-root boundary."""

from __future__ import annotations

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/take-canonical-root.sh"


class CanonicalRootTests(unittest.TestCase):
    def run_helper(self, exit_code: int, placed: str = "", *, requested: str = "/private/tmp/cmux-ci") -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            temp = Path(tmp)
            helper = temp / "helper-glaeda-canonical-root"
            helper.write_text(
                f"#!/bin/sh\nprintf '%s' '{placed}' > \"$RUNNER_TEMP/glaeda-canonical-root\"\nexit {exit_code}\n"
            )
            helper.chmod(0o755)
            environment = {
                "PATH": os.environ["PATH"],
                "RUNNER_TEMP": str(temp),
                "CMUX_CI_CANONICAL_ROOT": requested,
                "CMUX_CI_CANONICAL_ROOT_HELPER": str(helper),
                "CMUX_PRODUCT_RUNNER": "glaeda-std-xcode-26.6",
            }
            return subprocess.run([str(SCRIPT)], env=environment, capture_output=True, text=True)

    def test_helper_holds_requested_root(self) -> None:
        result = self.run_helper(0)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "/private/tmp/cmux-ci")

    def test_different_held_root_fails_closed(self) -> None:
        result = self.run_helper(2, "/private/tmp/cmux-ci-2")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("different root", result.stderr)

    def test_invalid_roots_are_rejected(self) -> None:
        result = self.run_helper(0, requested="/private/tmp/cmux-ci-1")
        self.assertNotEqual(result.returncode, 0)

    def test_owned_runner_without_helper_fails_closed(self) -> None:
        environment = {
            "PATH": os.environ["PATH"],
            "CMUX_PRODUCT_RUNNER": "glaeda-std-xcode-26.6",
            "CMUX_CI_CANONICAL_ROOT_HELPER": "/tmp/does-not-exist",
        }
        result = subprocess.run([str(SCRIPT)], env=environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no Glaeda root helper", result.stderr)

    def test_admission_uses_the_held_root_before_cleanup(self) -> None:
        workflow = (ROOT / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8")
        step_start = workflow.index(
            "      - name: Choose this job's canonical build root\n        id: build-slot"
        )
        step_end = workflow.find("\n      - name: ", step_start + 1)
        self.assertNotEqual(step_end, -1)
        step = workflow[step_start:step_end]
        take = step.index("scripts/ci/canonical-build-root.sh --print-root")
        self.assertLess(take, step.index('echo "root=$root" >> "$GITHUB_OUTPUT"'))
        self.assertLess(step_end, workflow.index("Prepare isolated admission DerivedData", step_end))


if __name__ == "__main__":
    unittest.main()
