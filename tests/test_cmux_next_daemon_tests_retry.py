#!/usr/bin/env python3
"""scripts/ci/cmux-next-daemon-tests.sh retries what a retry can fix, and only that.

Job 141050286394 (cmux-tui artifacts run 46168107258, 2026-11-28): the test compile failed on
error[E0063] (a test initializer missing a new field), the script retried it twice at fewer jobs, and
the step hit its 65-minute limit. The same source fails the same way, so a rustc error ends the run on
its first attempt; a SIGKILLed rustc (out of memory) still retries at half the jobs.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "cmux-next-daemon-tests.sh"

COMPILE_ERROR = """\
error[E0063]: missing field `same_build_installed` in initializer of `host_update::UpdateOptions`
    --> crates/acpmux/src/cli/host_update_tests.rs:1058:34
error: could not compile `acpmux` (lib test) due to 1 previous error
"""
SIGKILL = """\
error: could not compile `cmux-tui-core` (lib test)

Caused by:
  process didn't exit successfully: `rustc --crate-name cmux_tui_core` (signal: 9, SIGKILL: kill)
"""


class RetryTests(unittest.TestCase):
    def run_script(self, cargo_output: str) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp) / "repo"
            (repo / "cmux-tui").mkdir(parents=True)
            (repo / "scripts" / "ci").mkdir(parents=True)
            (repo / "scripts" / "cmux-next").mkdir(parents=True)
            shutil.copy(SCRIPT, repo / "scripts" / "ci" / SCRIPT.name)
            packages = repo / "scripts" / "ci" / "cmux-next-daemon-test-packages.sh"
            packages.write_text("#!/usr/bin/env bash\necho -p acpmux\n", encoding="utf-8")
            packages.chmod(0o755)
            # Not a stale Cargo.lock: the lock explainer finds nothing to name.
            (repo / "scripts" / "cmux-next" / "cargo-locks.py").write_text("import sys\nsys.exit(1)\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q", str(repo)], check=True)

            bin_dir = Path(tmp) / "bin"
            bin_dir.mkdir()
            calls = Path(tmp) / "calls"
            output = Path(tmp) / "cargo-output"
            output.write_text(cargo_output, encoding="utf-8")
            cargo = bin_dir / "cargo"
            cargo.write_text(
                f'#!/usr/bin/env bash\necho "jobs=${{CARGO_BUILD_JOBS:-}}" >> "{calls}"\ncat "{output}"\nexit 101\n',
                encoding="utf-8",
            )
            cargo.chmod(0o755)
            sleep = bin_dir / "sleep"
            sleep.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            sleep.chmod(0o755)

            env = dict(os.environ)
            env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
            env["CARGO_BUILD_JOBS"] = "4"
            env["RUNNER_TEMP"] = tmp
            result = subprocess.run(
                ["bash", str(repo / "scripts" / "ci" / SCRIPT.name)],
                cwd=repo,
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            return result, calls.read_text(encoding="utf-8").split()

    def test_a_compile_error_fails_on_the_first_attempt(self) -> None:
        result, calls = self.run_script(COMPILE_ERROR)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["jobs=4"])
        self.assertIn("does not compile", result.stderr)

    def test_a_sigkilled_rustc_still_retries_at_half_the_jobs(self) -> None:
        result, calls = self.run_script(SIGKILL)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ["jobs=4", "jobs=2", "jobs=1"])
        self.assertIn("failed after 3 attempts", result.stderr)


if __name__ == "__main__":
    unittest.main()
