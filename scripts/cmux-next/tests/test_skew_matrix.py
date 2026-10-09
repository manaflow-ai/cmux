#!/usr/bin/env python3
"""Behavior tests of the skew matrix classifier (scripts/cmux-next/skew-matrix.py).

Pure: no daemon, no binary. Run: python3 -I scripts/cmux-next/tests/test_skew_matrix.py
"""

import importlib.util
import json
import pathlib
import unittest

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE.parent / "skew-matrix.py"
CASES = HERE.parent / "skew-matrix-cases.json"

spec = importlib.util.spec_from_file_location("skew_matrix", SCRIPT)
skew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skew)

CLI = "/opt/new build/cmux-tui"
DAEMON_CLI = "/Applications/cmux.app/Contents/Resources/bin/cmux"
SOCKET = "/tmp/skm.x/cmux-1000/skm.sock"
CASE = {"id": "server-stats", "argv": ["server", "stats"], "capability": "server-stats-v1"}


def run(exit_code=1, stdout="", stderr="", timed_out=False, case=CASE):
    outcome = {"exit": exit_code, "stdout": stdout, "stderr": stderr, "timed_out": timed_out}
    return skew.classify(case, outcome, cli=CLI, daemon_cli=DAEMON_CLI, socket=SOCKET)


def q(path):
    return "'" + path.replace("'", "'\\''") + "'"


RESTART = f"{q(CLI)} daemon stop --socket {q(SOCKET)} && {q(CLI)} daemon ensure --socket {q(SOCKET)}"
STOP = f"{q(CLI)} daemon stop --socket {q(SOCKET)}"
REEXEC = (
    "cmux: this CLI (build abc) does not match the daemon (build def); "
    f"running the daemon's CLI {DAEMON_CLI}"
)


class ClassifyTests(unittest.TestCase):
    def test_exit_zero_works(self):
        self.assertEqual(run(0, stdout='{"ok":true}')[0], "works")

    def test_restart_fix_command_passes(self):
        verdict, _ = run(1, stderr=f"cmux: this server does not support server-stats. Restart it with this CLI: {RESTART}")
        self.assertEqual(verdict, "fix")

    def test_stop_only_fix_command_passes(self):
        verdict, _ = run(1, stderr=f"cmux: no conversations (capability local-conversations-v1 is missing): {STOP}")
        self.assertEqual(verdict, "fix")

    def test_fix_command_inside_json_error_passes(self):
        body = json.dumps({"ok": False, "error": {"code": "server.stats_unsupported", "message": f"old build: {RESTART}"}})
        self.assertEqual(run(1, stdout=body + "\n")[0], "fix")

    def test_fix_for_another_socket_fails(self):
        other = RESTART.replace(SOCKET, "/tmp/other.sock")
        verdict, detail = run(1, stderr=f"cmux: unsupported; {other}")
        self.assertEqual(verdict, "FAIL")
        self.assertIn("capability", detail)

    def test_fix_naming_another_cli_fails(self):
        other = RESTART.replace(CLI, "/usr/local/bin/cmux")
        self.assertEqual(run(1, stderr=f"cmux: unsupported; {other}")[0], "FAIL")

    def test_two_different_fix_commands_fail(self):
        verdict, detail = run(1, stderr=f"try {STOP}\nor {RESTART}")
        self.assertEqual(verdict, "FAIL")
        self.assertIn("2 fix commands", detail)

    def test_raw_capability_error_fails(self):
        verdict, detail = run(1, stderr="resident session does not support journal subscriptions; restart it with this cmux-tui binary")
        self.assertEqual(verdict, "FAIL")
        self.assertIn("raw capability error", detail)

    def test_update_the_app_fails(self):
        verdict, _ = run(1, stderr="this daemon is too old; update the cmux app or daemon")
        self.assertEqual(verdict, "FAIL")

    def test_other_error_fails(self):
        verdict, detail = run(3, stderr="cmux: connection refused")
        self.assertEqual(verdict, "FAIL")
        self.assertIn("other error", detail)

    def test_reexec_to_daemon_cli_passes(self):
        self.assertEqual(run(0, stderr=REEXEC + "\n")[0], "re-exec")

    def test_reexec_passes_even_when_the_daemon_cli_then_fails(self):
        self.assertEqual(run(1, stderr=REEXEC + "\nsome error\n")[0], "re-exec")

    def test_reexec_to_another_cli_fails(self):
        line = REEXEC.replace(DAEMON_CLI, "/tmp/evil/cmux")
        verdict, detail = run(0, stderr=line)
        self.assertEqual(verdict, "FAIL")
        self.assertIn("/tmp/evil/cmux", detail)

    def test_two_reexec_lines_fail(self):
        self.assertEqual(run(0, stderr=REEXEC + "\n" + REEXEC + "\n")[0], "FAIL")

    def test_reexec_without_daemon_cli_fails(self):
        outcome = {"exit": 0, "stdout": "", "stderr": REEXEC, "timed_out": False}
        verdict, _ = skew.classify(CASE, outcome, cli=CLI, daemon_cli=None, socket=SOCKET)
        self.assertEqual(verdict, "FAIL")

    def test_expected_domain_error_works(self):
        case = dict(CASE, works_if=["no Chief conversation"])
        verdict, _ = run(1, stderr="cmux: no Chief conversation on this session yet", case=case)
        self.assertEqual(verdict, "works")

    def test_expected_domain_error_does_not_hide_a_capability_error(self):
        case = dict(CASE, works_if=["no Chief conversation"])
        verdict, _ = run(1, stderr="cmux: capability local-conversations-v1 is missing; no Chief conversation", case=case)
        self.assertEqual(verdict, "FAIL")

    def test_timeout_fails(self):
        verdict, detail = run(None, timed_out=True)
        self.assertEqual(verdict, "FAIL")
        self.assertIn("timed out", detail)


class CasesFileTests(unittest.TestCase):
    def test_cases_file_is_valid(self):
        cases, skipped = skew.load_cases(CASES)
        self.assertTrue(cases)
        ids = [case["id"] for case in cases]
        self.assertEqual(len(ids), len(set(ids)))
        for case in cases:
            self.assertTrue(case["argv"] and case["capability"] and case["pass"])
        for entry in skipped:
            self.assertTrue(entry["reason"])

    def test_load_cases_refuses_a_case_without_capability(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "c.json"
            path.write_text(json.dumps({"cases": [{"id": "x", "argv": ["a"], "pass": "y"}], "skipped": []}))
            with self.assertRaises(ValueError):
                skew.load_cases(path)


class TableTests(unittest.TestCase):
    def test_table_lists_every_row_and_exit_status(self):
        rows = [
            {"direction": "cli=new daemon=old", "case": "server-stats", "verdict": "works", "detail": "exit 0"},
            {"direction": "cli=old daemon=new", "case": "server-stats", "verdict": "FAIL", "detail": "raw capability error"},
        ]
        text = skew.render_table(rows)
        self.assertIn("cli=new daemon=old", text)
        self.assertIn("FAIL", text)
        self.assertEqual(skew.exit_status(rows), 1)
        self.assertEqual(skew.exit_status(rows[:1]), 0)


if __name__ == "__main__":
    unittest.main(verbosity=1)
