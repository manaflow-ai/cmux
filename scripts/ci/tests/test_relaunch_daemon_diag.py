"""relaunch_restore_check's daemon diagnosis: a round that lost its daemon prints the app's processes either side of
the quit, the daemon lines of both app logs and the end of the owner's log, since a failed job uploads no artifact
(bench 8bc82d8d05d9: every round spawned a new daemon and the log held no line saying why).

Run: python3 -I scripts/ci/tests/test_relaunch_daemon_diag.py"""

import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    import relaunch_restore_check as R  # noqa: E402
except ImportError as error:
    raise unittest.SkipTest(f"relaunch_restore_check does not import here: {error}")


class DiagnosisTests(unittest.TestCase):
    def test_reads_owner_log_and_daemon_lines_of_app_logs(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root, "h")
            state = home / "Library" / "Application Support" / "cmux" / "tui"
            state.mkdir(parents=True)
            (state / "client.log").write_text("".join(f"line {i}\n" for i in range(100)) + "owner: stopping\n")
            Path(root, "app.log").write_text("window shown\nend sessions: ended 1 terminals\nchrome ready\n")
            Path(root, "app-relaunched.log").write_text("daemon.spawned\nunrelated\n")
            got = R.daemon_diagnosis(str(home), Path(root), ["1 1 1 00:01 a"], [])
            owner = got["logs"]["Library/Application Support/cmux/tui/client.log"]
            self.assertEqual(len(owner), R.DIAG_LOG_LINES)
            self.assertEqual(owner[-1], "owner: stopping")
            self.assertEqual(got["logs"]["app.log"], ["end sessions: ended 1 terminals"])
            self.assertEqual(got["logs"]["app-relaunched.log"], ["daemon.spawned"])
            self.assertEqual(got["ps_before_quit"], ["1 1 1 00:01 a"])

    def test_a_home_with_no_library_still_answers(self):
        with tempfile.TemporaryDirectory() as root:
            got = R.daemon_diagnosis(str(Path(root, "h")), Path(root), [], [])
            self.assertEqual(got["logs"], {})


if __name__ == "__main__":
    unittest.main()
