#!/usr/bin/env python3
"""The bash 3.2 parse check runs on Linux with a pinned GNU bash 3.2.57.

signing-keychain-macos.yml's bash32-syntax job parses scripts the way macOS
/bin/bash 3.2 will. It needs no Mac: scripts/ci/build-bash32.sh builds the same
release (3.2.57) from a SHA-256-pinned tarball. These contracts keep the job on
Linux under its name, keep the build pinned, and keep the guard test from
passing by skipping (it skips when the bash it gets is not 3.x).
"""

import re
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "signing-keychain-macos.yml"
BUILD = ROOT / "scripts" / "ci" / "build-bash32.sh"


def job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["bash32-syntax"]


class Bash32LinuxJobTests(unittest.TestCase):
    def test_job_runs_on_linux_and_keeps_its_name(self) -> None:
        bash32 = job()
        self.assertEqual(bash32["name"], "scripts/ci parse under /bin/bash 3.2")
        self.assertIn("ubuntu", bash32["runs-on"])
        self.assertNotIn("macos", bash32["runs-on"])

    def test_build_is_pinned_to_the_macos_release(self) -> None:
        text = BUILD.read_text(encoding="utf-8")
        self.assertIn('version="3.2.57"', text)
        self.assertRegex(text, r'sha256="[0-9a-f]{64}"')

    def test_checks_use_the_built_bash_and_cannot_skip(self) -> None:
        runs = [step.get("run", "") for step in job()["steps"]]
        joined = "\n".join(runs)
        self.assertIn("scripts/ci/build-bash32.sh", joined)
        self.assertIn("CMUX_PARSE_BASH=", joined)
        self.assertNotIn("/bin/bash ", joined)
        guard = next(run for run in runs if "tests/test_bash32_parse_guard.sh" in run)
        self.assertRegex(guard, r"\$CMUX_PARSE_BASH\"? tests/test_bash32_parse_guard\.sh")
        self.assertTrue(re.search(r"grep -q '\^SKIP'", guard), guard)
        self.assertIn("./scripts/ci/check-bash32-parse.sh", joined)


if __name__ == "__main__":
    unittest.main()
