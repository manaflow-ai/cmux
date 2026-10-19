#!/usr/bin/env python3
"""Exercise resource diagnostics in a running, explicitly targeted DEV app."""

import argparse
import json
from pathlib import Path
import socket
import unittest
import uuid


class MemoryResourceDiagnosticsTests(unittest.TestCase):
    socket_path = ""
    expected_bundle = ""
    artifact_directory = Path(".")

    def rpc(self, method, params=None):
        request = {"id": str(uuid.uuid4()), "method": method, "params": params or {}}
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(30)
            connection.connect(self.socket_path)
            connection.sendall((json.dumps(request) + "\n").encode())
            response = connection.makefile("rb").readline()
        payload = json.loads(response)
        self.assertTrue(payload.get("ok"), payload)
        return payload["result"]

    def test_live_resource_context_and_monitor_are_observable(self):
        identity = self.rpc("system.identify")
        self.assertEqual(identity["bundle_identifier"], self.expected_bundle)
        self.assertEqual(identity["socket_path"], self.socket_path)
        payload = self.rpc("system.memory", {"all_windows": True})
        self.artifact_directory.mkdir(parents=True, exist_ok=True)
        (self.artifact_directory / "system-memory.json").write_text(
            json.dumps(payload, indent=2) + "\n", encoding="utf-8"
        )
        self.assertIn("resource_context", payload)
        context = payload["resource_context"]
        self.assertGreater(context["app"]["physical_footprint_bytes"], 0)
        self.assertIn(context["aggregate"]["severity"], ("normal", "warning", "critical"))
        self.assertGreater(context["aggregate"]["physical_memory_bytes"], 0)
        self.assertIsInstance(context["aggregate"]["complete"], bool)
        self.assertGreaterEqual(context["descendants"]["unique_descendant_count"], 1)
        self.assertGreaterEqual(context["descendants"]["rss_bytes"], 0)
        self.assertGreaterEqual(context["system_memory"]["compressor_bytes"], 0)
        self.assertGreaterEqual(context["system_memory"]["available_bytes"], 0)
        descriptors = context["file_descriptors"]
        self.assertTrue(descriptors["complete"])
        self.assertGreater(descriptors["table_capacity"], 0)
        self.assertEqual(descriptors["open_count"], sum(descriptors["type_counts"].values()))
        self.assertGreater(descriptors["open_count"], 0)
        self.assertGreaterEqual(context["views"]["realized_renderer_count"], 1)
        self.assertIn("browser_panel_count", context["views"])
        monitor = context["monitor"]
        self.assertIn(monitor["system_severity"], ("normal", "warning", "critical"))
        self.assertIn(monitor["aggregate"]["severity"], ("normal", "warning", "critical"))
        self.assertIn("sampled_at", monitor["aggregate"])
        self.assertNotIn("windows", context)
        self.assertNotIn("path", context["app"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--expected-bundle", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if not args.socket.startswith("/tmp/cmux-debug-"):
        parser.error("Only an explicitly tagged DEV socket may be tested")
    if not args.expected_bundle.startswith("com.cmuxterm.app.debug."):
        parser.error("Only an explicitly tagged DEV bundle may be tested")
    MemoryResourceDiagnosticsTests.socket_path = args.socket
    MemoryResourceDiagnosticsTests.expected_bundle = args.expected_bundle
    MemoryResourceDiagnosticsTests.artifact_directory = args.out
    unittest.main(argv=[__file__], verbosity=2)
