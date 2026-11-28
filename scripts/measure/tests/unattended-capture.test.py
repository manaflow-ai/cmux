"""A scripted ScreenCaptureKit capture never leaves macOS's acknowledgement on a screen nobody watches.

Detector for the 2026-11-28 incident (cmuxterm-hq docs/handbook/prompt-on-an-unattended-screen.md): a fleet step's
`cmux computer-use screenshot` raised '"cmux" is requesting to bypass the system private window picker' on a shared
mini with no MDM bypass, and it stayed up over the next walk. Two halves:

  - unattended_capture.capture_refusal: refuses on a fleet or CI run unless the Mac carries the MDM
    forceBypassScreenCaptureAlert restriction, or a person says they watch the screen;
  - every script under scripts/ that runs `computer-use screenshot` or `computer-use record` calls that gate.
"""
import importlib.util
import plistlib
import re
import tempfile
import unittest
from pathlib import Path

MEASURE = Path(__file__).resolve().parents[1]
SCRIPTS = MEASURE.parent
spec = importlib.util.spec_from_file_location("unattended_capture", MEASURE / "unattended_capture.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

# An argv that captures through the product's ScreenCaptureKit path: "computer-use", "screenshot" | "record".
CAPTURE_ARGV = re.compile(r"""["']computer-use["']\s*,\s*["'](screenshot|record)["']""")


class GateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.managed = Path(self.temp.name) / "com.apple.applicationaccess.plist"

    def managed_with(self, value):
        self.managed.write_bytes(plistlib.dumps({gate.BYPASS_KEY: value}))
        return self.managed

    def test_fleet_step_without_bypass_is_refused(self):
        for env in ({"CMUX_CI_JOB_ID": "abeec0d3099a1b9424296d52"}, {"GITHUB_ACTIONS": "true"}, {"CI": "1"}):
            with self.subTest(env=env):
                reason = gate.capture_refusal(env, managed=self.managed)
                self.assertIn(gate.BYPASS_KEY, reason)
                self.assertIn(gate.ATTENDED_ENV, reason)

    def test_bypass_must_be_true(self):
        env = {"CMUX_CI_JOB_ID": "x"}
        self.assertIsNone(gate.capture_refusal(env, managed=self.managed_with(True)))
        for value in (False, "true", 1):
            with self.subTest(value=value):
                self.assertIsNotNone(gate.capture_refusal(env, managed=self.managed_with(value)))
        self.managed.write_bytes(b"not a plist")
        self.assertIsNotNone(gate.capture_refusal(env, managed=self.managed))

    def test_person_at_the_screen_captures(self):
        self.assertIsNone(gate.capture_refusal({}, managed=self.managed))
        self.assertIsNone(gate.capture_refusal({"CI": "true", gate.ATTENDED_ENV: "1"}, managed=self.managed))
        self.assertIsNone(gate.capture_refusal({"CI": "false"}, managed=self.managed))


class EveryScriptedCaptureIsGated(unittest.TestCase):
    def test_capture_callers_call_the_gate(self):
        callers, ungated = [], []
        for path in sorted(SCRIPTS.rglob("*.py")):
            if path.name.startswith("test_") or path.name.endswith(".test.py") or path == MEASURE / "unattended_capture.py":
                continue
            try:
                text = path.read_text()
            except (OSError, UnicodeDecodeError):
                continue
            if not CAPTURE_ARGV.search(text):
                continue
            callers.append(path.relative_to(SCRIPTS).as_posix())
            if "capture_refusal(" not in text:
                ungated.append(path.relative_to(SCRIPTS).as_posix())
        self.assertIn("measure/ext-rows-capture.py", callers)
        self.assertEqual(ungated, [], "a scripted `cmux computer-use screenshot|record` must first ask "
                         "scripts/measure/unattended_capture.py capture_refusal(): on an unattended Mac without the "
                         "MDM forceBypassScreenCaptureAlert it leaves an alert nobody answers")


if __name__ == "__main__":
    unittest.main()
