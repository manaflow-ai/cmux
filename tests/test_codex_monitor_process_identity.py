#!/usr/bin/env python3
"""Monitor assertions and cleanup must only select their exact test session."""

import subprocess
import unittest
from unittest.mock import patch

from test_codex_feed_hooks import monitor_pids_for_session


class MonitorProcessIdentityTests(unittest.TestCase):
    def monitor_pids(self, session_id: str, commands: str) -> list[int]:
        result = subprocess.CompletedProcess([], 0, stdout=commands, stderr="")
        with patch("test_codex_feed_hooks.shutil.which", return_value="/bin/ps"), patch(
            "test_codex_feed_hooks.subprocess.run", return_value=result
        ):
            return monitor_pids_for_session(session_id)

    def test_numeric_session_prefix_does_not_select_another_tests_monitor(self):
        commands = (
            "101 /test/cmux hooks codex monitor --session memory-123 --socket /tmp/one\n"
            "202 /test/cmux hooks codex monitor --session memory-1234 --socket /tmp/two\n"
        )
        self.assertEqual(self.monitor_pids("memory-123", commands), [101])
        self.assertEqual(self.monitor_pids("memory-1234", commands), [202])

    def test_exact_session_at_end_of_command_is_selected(self):
        self.assertEqual(
            self.monitor_pids(
                "memory-123",
                "101 /test/cmux hooks codex monitor --session memory-123\n",
            ),
            [101],
        )

    def test_cleanup_finds_no_monitor_when_only_a_neighboring_session_remains(self):
        self.assertEqual(
            self.monitor_pids(
                "memory-123",
                "202 /test/cmux hooks codex monitor --session memory-1234\n",
            ),
            [],
        )


if __name__ == "__main__":
    unittest.main()
