#!/usr/bin/env python3
"""Fail-closed regression cases for scripts/ci/ios_push_sim_gate.py."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("ios_push_sim_gate", ROOT / "scripts/ci/ios_push_sim_gate.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def probe(value):
    return {"AXUniqueId": "debug.open-marks", "AXLabel": json.dumps(value)}


def shown(marker="push-gate-unique"):
    return {"AXUniqueId": "NotificationShortLookView", "AXLabel": "Claude wants to act",
            "frame": {"x": 0, "y": 0, "width": 100, "height": 100},
            "children": [{"AXLabel": marker}]}


class PushSimGateTests(unittest.TestCase):
    def test_launch_requires_permission_delivery_not_just_app_marks(self):
        class Setup(gate.Detector):
            def run(self, *argv, **kwargs):
                self.launch_env = kwargs["env"]
                return "launched"

            def wait(self, name, predicate, timeout=20):
                # App marks may appear before the asynchronous permission prompt.
                self.early = predicate([probe({"cycle": 0})])
                primer = json.loads(self.launch_env["SIMCTL_CHILD_CMUX_MOBILE_DEV_SERVICE_PUSH"])
                return predicate([probe({"cycle": 0}), shown(primer["aps"]["alert"]["body"])])

        detector = Setup(SimpleNamespace(timeout=150, udid="leased", bundle="test"), {})
        self.assertEqual(detector.launch(), {"cycle": 0})
        self.assertIsNone(detector.early)
        self.assertNotIn("cmuxMobile", json.loads(detector.launch_env["SIMCTL_CHILD_CMUX_MOBILE_DEV_SERVICE_PUSH"]))

    def test_private_device_set_reaches_simctl_and_axe(self):
        args = SimpleNamespace(timeout=150, sim_set=Path("/lease/sims"))
        detector = gate.Detector(args, {})
        with patch.object(gate.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="{}")) as run:
            detector.run("xcrun", "simctl", "list", "devices", "--json")
            self.assertEqual(run.call_args.args[0][:4], ("xcrun", "simctl", "--set", "/lease/sims"))
            detector.run("axe", "describe-ui", "--udid", "leased")
            self.assertEqual(run.call_args.kwargs["env"]["CORE_SIMULATOR_DEVICE_SET_PATH"], "/lease/sims")

    def test_stale_wrong_trigger_and_incomplete_marks_fail(self):
        good = {"cycle": 4, "trigger": "notification_tap", "route_opened": 2, "terminal_ready": 3}
        self.assertTrue(gate.ready(good, 3))
        for patch in ({"cycle": 3}, {"trigger": "deep_link"}, {"route_opened": None},
                      {"terminal_ready": None}, {"terminal_ready": float("nan")},
                      {"route_opened": -1}, {"terminal_ready": True}):
            self.assertFalse(gate.ready({**good, **patch}, 3), patch)

    def test_banner_requires_real_banner_and_our_marker(self):
        self.assertIsNotNone(gate.banner([shown()], "push-gate-unique"))
        self.assertIsNone(gate.banner([shown("other-notification")], "push-gate-unique"))
        self.assertIsNone(gate.banner([{"AXLabel": "push-gate-unique"}], "push-gate-unique"))

    def test_payload_must_target_mock_route_with_visible_marker(self):
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "payload.json"
            body = {"aps": {"alert": {"body": "push-gate-unique"}}, "cmuxMobile": {
                "mac": "mac-studio", "sessionId": "mock-t-claude", "eventId": "push-gate-unique"}}
            path.write_text(json.dumps(body))
            self.assertEqual(gate.payload(path)[0], "push-gate-unique")
            body["cmuxMobile"]["sessionId"] = "other-session"
            path.write_text(json.dumps(body))
            with self.assertRaisesRegex(ValueError, "target"):
                gate.payload(path)
            body["cmuxMobile"]["sessionId"] = "mock-t-claude"
            body["aps"]["alert"]["body"] = "unrelated"
            path.write_text(json.dumps(body))
            with self.assertRaisesRegex(ValueError, "visibly"):
                gate.payload(path)

    def detector(self, trees):
        class Fake(gate.Detector):
            def launch(self):
                return {"cycle": 3}

            def tree(self):
                return next(self.trees)

            def run(self, *argv, **kwargs):
                self.commands.append(argv)
                return "Notification sent"

            def wait(self, name, predicate, timeout=20):
                value = predicate(self.tree())
                if value is None or value is False:
                    raise TimeoutError(name)
                return value

        result = Fake(SimpleNamespace(timeout=150, udid="leased", bundle="test"), {"cases": []})
        result.trees, result.commands = iter(trees), []
        return result

    def test_simctl_acceptance_without_delivery_never_passes(self):
        detector = self.detector([[], []])
        with self.assertRaisesRegex(TimeoutError, "banner"):
            detector.check("foreground", Path("body.json"), "push-gate-unique", "digest")
        self.assertTrue(any(command[:3] == ("xcrun", "simctl", "push") for command in detector.commands))
        self.assertEqual(detector.report["cases"], [])

    def test_banner_without_ready_chat_never_passes(self):
        detector = self.detector([[], [shown()], [probe({"cycle": 4, "trigger": "notification_tap"})]])
        with self.assertRaisesRegex(TimeoutError, "ready chat"):
            detector.check("foreground", Path("body.json"), "push-gate-unique", "digest")
        self.assertEqual(detector.report["cases"], [])

    def test_complete_delivery_and_tap_carries_marks(self):
        value = {"cycle": 4, "trigger": "notification_tap", "route_opened": 1, "chat_composer_ready": 2}
        detector = self.detector([[], [shown()], [probe(value)]])
        detector.check("foreground", Path("body.json"), "push-gate-unique", "digest")
        self.assertEqual(detector.report["cases"][0]["marks"], value)
        self.assertTrue(any(command[:2] == ("axe", "tap") for command in detector.commands))

    def test_stale_banner_rejected_before_injection(self):
        detector = self.detector([[shown()]])
        with self.assertRaisesRegex(RuntimeError, "stale"):
            detector.check("foreground", Path("body.json"), "push-gate-unique", "digest")
        self.assertEqual(detector.commands, [])


if __name__ == "__main__":
    unittest.main()
