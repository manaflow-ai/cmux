#!/usr/bin/env python3
"""configuration.py's verdicts on stand-in `cmux --json settings validate` answers, and its CLI on a stand-in cmux.

The answers are the shapes cmux-tui/crates/cmux-tui/src/cli/app/settings.rs prints: valid on stdout, a refusal
(settings.invalid, settings.unreadable) on stderr with exit 1. The checks: valid is clean, and a missing default
file is clean; refused keys are problems with their path and what they accept; a file that is not JSON is a
problem; a missing named file, a cmux that is not there and output that is not JSON are unreadable, never clean.
Run: python3 -I scripts/checkup/tests/configuration.test.py
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "configuration.py"
spec = importlib.util.spec_from_file_location("configuration", SCRIPT)
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)

VALID = json.dumps({"diagnostics": [], "exists": True, "file": "/h/.config/cmux/cmux-next.json", "valid": True})
NO_FILE = json.dumps({"diagnostics": [], "exists": False, "file": "/h/.config/cmux/cmux-next.json", "valid": True})
INVALID = json.dumps(
    {
        "code": "settings.invalid",
        "details": {
            "diagnostics": [
                {
                    "accepted": {"choices": ["context", "planUsage"]},
                    "kind": "invalid_value",
                    "message": "agentPane.composerRing does not accept 12345",
                    "path": "agentPane.composerRing",
                }
            ],
            "file": "/tmp/bad.json",
        },
        "message": "...",
        "retryable": False,
    }
)
NOT_JSON = json.dumps(
    {
        "code": "settings.invalid",
        "details": {"diagnostics": [{"accepted": None, "kind": "unreadable_file", "message": "key must be a string", "path": ""}], "file": "/tmp/x.json"},
    }
)
MISSING = json.dumps({"code": "settings.unreadable", "details": {"file": "/tmp/m.json"}, "message": "cmux: /tmp/m.json: No such file or directory (os error 2)"})


class Classify(unittest.TestCase):
    def test_clean(self):
        self.assertEqual(cc.classify(0, VALID, "", None)["state"], "clean")
        result = cc.classify(0, NO_FILE, "", None)
        self.assertEqual(result["state"], "clean")
        self.assertIn("every key has its default", cc.render(result))

    def test_refused_keys_are_problems(self):
        result = cc.classify(1, "", INVALID, "/tmp/bad.json")
        self.assertEqual(result["state"], "problems")
        self.assertEqual(result["problems"][0]["path"], "agentPane.composerRing")
        self.assertIn("expected one of context, planUsage", cc.render(result))

    def test_not_json_is_a_problem(self):
        result = cc.classify(1, "", NOT_JSON, "/tmp/x.json")
        self.assertEqual(result["state"], "problems")
        self.assertIn("(file): key must be a string", cc.render(result))

    def test_unreadable_is_never_clean(self):
        result = cc.classify(1, "", MISSING, "/tmp/m.json")
        self.assertEqual(result["state"], "unreadable")
        self.assertIn("No such file", result["error"])
        self.assertEqual(cc.classify(0, "not json", "", None)["state"], "unreadable")
        self.assertEqual(cc.classify(1, "", "", None)["state"], "unreadable")
        # Exit 0 with a refusal shape is still not clean.
        self.assertEqual(cc.classify(0, INVALID, "", None)["state"], "problems")

    def test_invalid_with_nothing_listed_is_not_clean(self):
        result = cc.classify(1, "", json.dumps({"code": "settings.invalid", "details": {"diagnostics": []}}), None)
        self.assertEqual(result["state"], "problems")

    def test_accepted_words(self):
        self.assertEqual(cc.accepted_words({"min": 1, "max": 3}), "a number from 1 to 3")
        self.assertEqual(cc.accepted_words({"choices": ["a"], "min": 0, "max": 2}), "one of a, or 0 to 2")
        self.assertEqual(cc.accepted_words(None), "")


class Cli(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        d = Path(self.dir.name)
        for name, text in {"valid": VALID, "invalid": INVALID, "missing": MISSING}.items():
            (d / f"{name}.out").write_text(text)
        self.fake = d / "cmux"
        self.fake.write_text(
            "#!/bin/sh\n"
            '[ "$1 $2 $3" = "--json settings validate" ] || exit 9\n'
            f'case "$4" in\n'
            f'  "") cat "{d}/valid.out" ;;\n'
            f'  bad.json) cat "{d}/invalid.out" >&2; exit 1 ;;\n'
            f'  *) cat "{d}/missing.out" >&2; exit 1 ;;\n'
            "esac\n"
        )
        self.fake.chmod(0o755)

    def tearDown(self):
        self.dir.cleanup()

    def run_script(self, *args):
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--cmux", str(self.fake), *args], capture_output=True, text=True, timeout=60
        )

    def test_exit_codes(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertEqual(self.run_script("bad.json").returncode, 1)
        self.assertEqual(self.run_script("bad.json", "gone.json").returncode, 2)

    def test_json_output(self):
        done = self.run_script("--json", "bad.json")
        answer = json.loads(done.stdout)
        self.assertEqual(answer["schema"], "cmux-checkup-configuration/v1")
        self.assertEqual(answer["results"][0]["state"], "problems")

    def test_cmux_not_found_is_unreadable(self):
        done = subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--cmux", os.path.join(self.dir.name, "nope")], capture_output=True, text=True, timeout=60
        )
        self.assertEqual(done.returncode, 2)
        self.assertIn("UNREADABLE", done.stdout)


if __name__ == "__main__":
    unittest.main()
