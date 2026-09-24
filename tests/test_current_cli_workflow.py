#!/usr/bin/env python3
"""Execute the actual current CLI workflow step with controlled test failures."""
from __future__ import annotations

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CurrentWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = (ROOT / ".github/workflows/cli-pipe-regressions.yml").read_text()
        section = workflow.split("      - name: Exercise bounded read-only current-work consumers\n", 1)[1]
        run = section.split("        run: |\n", 1)[1].split("\n      - ", 1)[0]
        cls.script = textwrap.dedent(run)

    def test_both_checks_produce_logs_and_any_failure_fails_step(self):
        for first, second in ((0, 0), (7, 0), (0, 9), (7, 9)):
            with self.subTest(first=first, second=second), tempfile.TemporaryDirectory(prefix="cmux-current-workflow-") as directory:
                root = Path(directory)
                test_bin = root / "bin"
                test_bin.mkdir()
                # Inject only the test process, leaving bash/pipefail/tee and the
                # workflow's control flow unchanged, including both log paths.
                runner = test_bin / "python3"
                runner.write_text(textwrap.dedent("""\
                    #!/bin/sh
                    case "$1" in
                      tests/test_cli_current.py) echo "first current check"; exit "$FIRST_STATUS" ;;
                      tests/test_current_command_fixture.py) echo "second current check"; exit "$SECOND_STATUS" ;;
                      *) echo "unexpected test: $1" >&2; exit 99 ;;
                    esac
                    """))
                runner.chmod(0o700)
                env = dict(os.environ, PATH=f"{test_bin}:{os.environ['PATH']}",
                           CMUX_CLI_DERIVED=str(root / "derived"), RUNNER_TEMP=str(root),
                           FIRST_STATUS=str(first), SECOND_STATUS=str(second))
                result = subprocess.run(["/bin/bash", "-c", self.script], capture_output=True,
                                        text=True, timeout=10, env=env)
                self.assertEqual(result.returncode == 0, first == second == 0, result.stderr)
                self.assertEqual((root / "current-cli.log").read_text(), "first current check\n")
                self.assertEqual((root / "current-fixture.log").read_text(), "second current check\n")


if __name__ == "__main__":
    unittest.main()
