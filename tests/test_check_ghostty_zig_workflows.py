#!/usr/bin/env python3

import tempfile
from pathlib import Path
import unittest

from check_ghostty_zig_workflows import workflow_failures


class GhosttyZigWorkflowGuardTests(unittest.TestCase):
    def failures_for(self, workflow: str) -> list[str]:
        with tempfile.TemporaryDirectory() as temporary_directory:
            workflow_dir = Path(temporary_directory)
            (workflow_dir / "fixture.yml").write_text(workflow)
            return workflow_failures(workflow_dir)

    def test_ignores_consumer_paths_used_as_metadata(self) -> None:
        failures = self.failures_for(
            """\
jobs:
  decide:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/github-script@v8
        with:
          script: |
            const relevantPaths = [
              'scripts/install-zig-ci.sh',
              'scripts/ghostty-zig-version.sh',
            ];
"""
        )

        self.assertEqual([], failures)

    def test_rejects_consumer_run_before_submodule_checkout(self) -> None:
        failures = self.failures_for(
            """\
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Install Zig
        run: ./scripts/install-zig-ci.sh
"""
        )

        self.assertEqual(1, len(failures))
        self.assertIn("build reads Ghostty before submodule init", failures[0])


if __name__ == "__main__":
    unittest.main()
