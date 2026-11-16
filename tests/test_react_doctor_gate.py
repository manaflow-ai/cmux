#!/usr/bin/env python3
"""The React Doctor ratchet fails on an added error, passes on old ones, and routes by changed paths.

Runs scripts/ci/react_doctor_gate.py's main on stand-in JSON reports (the shape
React Doctor 0.9 writes with --json) and a temporary baseline, so no scan runs.
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts", "ci"))
import react_doctor_gate as gate  # noqa: E402


def diag(path, rule, severity="error", line=3):
    return {"id": f"{path}::{line}:1::react-doctor/{rule}::abc", "filePath": path, "plugin": "react-doctor",
            "rule": rule, "severity": severity, "line": line, "column": 1, "message": "m", "help": "h"}


def report(*diagnostics):
    return {"ok": True, "reactDetected": True, "diagnostics": list(diagnostics)}


class GateTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.baseline = os.path.join(self.tmp, "baseline.json")
        self.reports = os.path.join(self.tmp, "reports")
        os.makedirs(self.reports)
        patcher = mock.patch.object(gate, "BASELINE", self.baseline)
        patcher.start()
        self.addCleanup(patcher.stop)
        env = mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "", "GITHUB_STEP_SUMMARY": ""})
        env.start()
        self.addCleanup(env.stop)

    def write(self, project, data):
        with open(os.path.join(self.reports, gate.report_name(project) + ".json"), "w") as handle:
            json.dump(data, handle)

    def run_gate(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = gate.main(["--from-json-dir", self.reports, "--project", "webviews", *args])
        return code, out.getvalue()

    def test_old_errors_pass_and_a_new_one_fails(self):
        self.write("webviews", report(diag("src/a.tsx", "no-ref-current-in-render"), diag("src/a.tsx", "x", "warning")))
        self.assertEqual(self.run_gate("--update-baseline")[0], 0)
        self.assertEqual(self.run_gate()[0], 0)
        self.write("webviews", report(diag("src/a.tsx", "no-ref-current-in-render"),
                                      diag("src/a.tsx", "no-ref-current-in-render", line=9)))
        code, out = self.run_gate()
        self.assertEqual(code, 1)
        self.assertIn("webviews/src/a.tsx:9", out)

    def test_a_new_file_must_be_clean_and_warnings_never_fail(self):
        self.write("webviews", report())
        self.run_gate("--update-baseline")
        self.write("webviews", report(*[diag("src/b.tsx", "w", "warning")] * 5))
        self.assertEqual(self.run_gate()[0], 0)
        self.write("webviews", report(diag("src/b.tsx", "effect-needs-cleanup")))
        self.assertEqual(self.run_gate()[0], 1)

    def test_a_fix_passes_and_says_to_lower_the_baseline(self):
        self.write("webviews", report(diag("src/a.tsx", "r"), diag("src/a.tsx", "r", line=5)))
        self.run_gate("--update-baseline")
        self.write("webviews", report(diag("src/a.tsx", "r")))
        code, out = self.run_gate()
        self.assertEqual(code, 0)
        self.assertIn("--update-baseline", out)

    def test_a_failed_scan_fails(self):
        self.write("webviews", {"ok": False, "reactDetected": False, "error": "boom", "diagnostics": []})
        self.assertEqual(self.run_gate()[0], 1)

    def test_routing(self):
        self.assertEqual(gate.select_projects(["webviews/src/x.tsx", "README.md"]), ["webviews"])
        self.assertEqual(gate.select_projects(["cmux-tui/frontends/web/src/a.tsx"]), ["cmux-tui/frontends/web"])
        self.assertEqual(gate.select_projects(["cmux-tui/src/main.rs", "web-other/x"]), [])
        self.assertEqual(gate.select_projects(["scripts/react-doctor/package.json"]), gate.PROJECTS)


if __name__ == "__main__":
    unittest.main()
