#!/usr/bin/env python3
"""Compile and exercise actual command presentation/parser/focus policy without an app build."""
from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_cli_current import SNAPSHOT

ROOT = Path(__file__).resolve().parents[1]


class CurrentCommandFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        state = ROOT / ".local"
        state.mkdir(exist_ok=True)
        cls.temp = tempfile.TemporaryDirectory(prefix="current-cli-fixture-", dir=state)
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "current-fixture"
        build = subprocess.run([
            "xcrun", "swiftc", "-o", str(cls.binary), "-module-cache-path", str(Path(cls.temp.name) / "cache"),
            str(ROOT / "CLI/CLIError.swift"), str(ROOT / "CLI/CMUXCLI+Current.swift"), str(ROOT / "CLI/CMUXCLI+JSONOutput.swift"),
            str(ROOT / "CLI/CMUXCLI+WindowDispatch.swift"), str(ROOT / "tests/fixtures/CurrentCommandFixture.swift"),
        ], capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise RuntimeError(build.stderr)

    def invoke(self, *args, payload=None):
        return subprocess.run([str(self.binary), *args], input=json.dumps(SNAPSHOT if payload is None else payload),
                              text=True, capture_output=True, timeout=5)

    def test_dispatch_preserves_json_and_sends_only_bounded_read(self):
        result = self.invoke("--json", "--limit=1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), SNAPSHOT)
        self.assertEqual(json.loads(result.stderr), {"method": "current.list", "params": {"limit": 1}})

    def test_text_renders_cached_unknown_facts_and_truncation(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        for expected in ("Review cmux", "freshness: unknown", "attention: unread_notification", "Limit reached", "agent_sessions: unavailable"):
            self.assertIn(expected, result.stdout)
        self.assertEqual(json.loads(result.stderr), {"method": "current.list", "params": {}})

    def test_actual_shared_window_policy_has_no_read_side_mutation(self):
        for args in (("current",), ("CURRENT",), ("read-screen",), ("rpc", "surface.read_selection"), ("surface", "resume")):
            with self.subTest(args=args):
                self.assertEqual(self.invoke("focus", *args).stdout.strip(), "false")
        self.assertEqual(self.invoke("focus", "select-workspace").stdout.strip(), "true")

    def test_invalid_bounds_and_refresh_never_dispatch(self):
        for args in (("--limit", "0"), ("--limit", "201"), ("--limit",), ("--limit=NaN",),
                     ("--limit=1", "--limit=2"), ("--refresh",)):
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("current:", result.stderr)
                self.assertNotIn('"method"', result.stderr)

    def test_empty_and_malformed_text_payload_are_distinct(self):
        self.assertIn("No current work observed", self.invoke(payload={"items": []}).stdout)
        result = self.invoke(payload={})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("invalid response", result.stderr)

    def test_human_rendering_sanitizes_control_characters(self):
        payload = json.loads(json.dumps(SNAPSHOT))
        payload["items"][0]["label"] = "first\nsecond\x1b[2J"
        result = self.invoke(payload=payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("first second [2J", result.stdout)
        self.assertNotIn("\x1b", result.stdout)


if __name__ == "__main__":
    unittest.main()
