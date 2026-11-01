"""Behavioral native adapter checks; no desktop or live helper is used."""
import copy
import base64
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import unittest
from unittest.mock import patch

import native


STEP = {"id": "check", "action": "native.click", "target": {
    "fixture": "toggle", "role": "AXCheckBox", "name": "Synthetic toggle"},
    "args": {}, "expect": {"checked": True}}
CONFIG = {"targets": {"toggle": {"pid": 42, "window_id": 7}}}
SESSION = {"id": "session-1", "agent": {"proxy_pid": 123, "actor": "agent:10"}}
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")


def event(seq, tool):
    return {"session": "session-1", "seq": seq, "tx": f"tx-{seq}", "tool": tool,
            "actor": "agent:10", "target": {"pid": 42, "window_id": 7},
            "after_frame": "blob", "result": {"ok": True}}


class FakeMCP:
    proc = type("Process", (), {"pid": 123})()

    def __init__(self, denied=False):
        self.denied = denied
        self.calls = []
        self.checked = False

    def initialize(self):
        return {"check_permissions", "get_window_state", "click"}

    def call(self, name, args):
        self.calls.append(name)
        if name == "check_permissions":
            return {"accessibility": not self.denied, "screen_recording": not self.denied}
        if name == "click":
            self.checked = True
            return {}
        return {"elements": [{"role": "AXCheckBox", "label": "Synthetic toggle",
                               "value": "1" if self.checked else "0", "element_index": 5}]}


class FakeActivity:
    def __init__(self, stale=False, expired=False):
        self.calls = []
        self.stale = stale
        self.expired = expired

    def read(self, method, args):
        self.calls.append(method)
        if method == "activity_sessions_list":
            return {"sessions": [SESSION]}
        if method == "activity_frame":
            return {"mime": "image/png", "data_base64": base64.b64encode(PNG).decode()}
        rows = [event(1, "get_window_state")]
        if "after_seq" in args and not self.stale:
            rows = [event(2, "click"), event(3, "get_window_state")]
        return {"events": rows, "frames": {"blob": {"expired": self.expired}}}


class NativeTests(unittest.TestCase):
    def test_fresh_action_and_observation_produce_linked_semantic_receipt(self):
        mcp, activity = FakeMCP(), FakeActivity()
        result = native.perform(STEP, CONFIG, mcp, activity)
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["state"]["checked"], True)
        self.assertEqual([row["seq"] for row in result["event_refs"]], [1, 2, 3])
        self.assertEqual(result["evidence"]["before"]["screenshot"]["session"], "session-1")
        self.assertNotIn("Synthetic toggle", json.dumps(result))
        self.assertNotIn("cGl4ZWxz", json.dumps(result))

    def test_denied_consent_stops_all_further_calls(self):
        mcp, activity = FakeMCP(denied=True), FakeActivity()
        with self.assertRaises(native.Unavailable):
            native.perform(STEP, CONFIG, mcp, activity)
        self.assertEqual(mcp.calls, ["check_permissions"])
        self.assertEqual(activity.calls, [])

    def test_stale_sequence_cannot_pass(self):
        with self.assertRaises(native.Unavailable):
            native.perform(STEP, CONFIG, FakeMCP(), FakeActivity(stale=True))

    def test_refused_action_stops_without_another_observation_or_activity_read(self):
        mcp, activity = FakeMCP(), FakeActivity()
        call = mcp.call

        def refuse(name, args):
            if name == "click":
                mcp.calls.append(name)
                return native.payload({"result": {"structuredContent": {"ok": False, "error": "consent_required"}}})
            return call(name, args)

        mcp.call = refuse
        with self.assertRaises(native.Unavailable):
            native.perform(STEP, CONFIG, mcp, activity)
        self.assertEqual(mcp.calls, ["check_permissions", "get_window_state", "click"])
        self.assertEqual(activity.calls, ["activity_sessions_list", "activity_sessions_list", "activity_timeline", "activity_frame"])

    def test_event_from_another_target_is_not_evidence(self):
        wrong = event(2, "click")
        wrong["target"]["window_id"] = 8
        with self.assertRaises(native.Unavailable):
            native.correlated({"events": [wrong]}, SESSION, 1, "click", CONFIG["targets"]["toggle"])

    def test_expired_frame_cannot_pass(self):
        mcp = FakeMCP()
        with self.assertRaises(native.Unavailable):
            native.perform(STEP, CONFIG, mcp, FakeActivity(expired=True))
        self.assertNotIn("click", mcp.calls)

    def test_text_encoded_refusal_stops_without_mcp_error_flag(self):
        with self.assertRaises(native.Unavailable):
            native.payload({"result": {"content": [{"type": "text", "text": '{"ok":false,"error":"consent_required"}'}]}})

    def test_structured_consent_request_stops_without_error(self):
        with self.assertRaises(native.Unavailable):
            native.payload({"result": {"structuredContent": {"consentRequired": True}}})

    def test_assertion_failure_is_observed(self):
        step = copy.deepcopy(STEP)
        step["expect"]["checked"] = False
        result = native.perform(step, CONFIG, FakeMCP(), FakeActivity())
        self.assertEqual(result["status"], "failed")
        self.assertEqual(result["assertions"][0], {"name": "checked", "ok": False})

    def test_failed_assertion_exports_existing_frames_and_exact_engine_events(self):
        step = copy.deepcopy(STEP)
        step["expect"]["checked"] = False
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            result = native.perform(step, CONFIG, FakeMCP(), FakeActivity(), out=out)
            self.assertEqual(result["status"], "failed")
            for phase in ("before", "after"):
                screenshot = result["evidence"][phase]["screenshot"]
                path = out / screenshot["path"]
                self.assertEqual(path.read_bytes(), PNG)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                self.assertEqual(screenshot["blob"], "blob")
                self.assertIs(screenshot["expired"], False)
                self.assertEqual(result["evidence"][phase]["state"]["checked"], phase == "after")
            path = out / result["evidence"]["events"]["path"]
            self.assertEqual(json.loads(path.read_text()), [event(1, "get_window_state"), event(2, "click"), event(3, "get_window_state")])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual([row["path"] for row in result["event_refs"]], ["cua-events.json"] * 3)
            # An exported bundle remains readable without the helper or its original store.
            self.assertNotIn("Synthetic toggle", path.read_text())
            self.assertNotIn("structuredContent", path.read_text())

    def test_refusal_preserves_before_export_without_further_capture(self):
        mcp, activity, progress = FakeMCP(), FakeActivity(), {}
        call = mcp.call

        def refuse(name, args):
            if name == "click":
                mcp.calls.append(name)
                raise native.Unavailable("consent required")
            return call(name, args)

        mcp.call = refuse
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            with self.assertRaises(native.Unavailable):
                native.perform(STEP, CONFIG, mcp, activity, out=out, progress=progress)
            self.assertEqual(sorted(path.name for path in out.iterdir()), ["before-events.json", "before.png"])
            self.assertEqual(progress["evidence"]["before"]["screenshot"]["path"], "before.png")
            self.assertEqual(progress["event_refs"][0]["path"], "before-events.json")
        self.assertEqual(mcp.calls, ["check_permissions", "get_window_state", "click"])
        self.assertEqual(activity.calls.count("activity_frame"), 1)

    def test_event_export_refuses_raw_payload_fields(self):
        for field in ("raw_reply", "raw_ax"):
            row = event(1, "get_window_state")
            row[field] = "private"
            with tempfile.TemporaryDirectory() as directory:
                with self.assertRaises(native.Unavailable):
                    native.export_events(Path(directory), "events.json", [row])
                self.assertEqual(list(Path(directory).iterdir()), [])
        row = event(1, "get_window_state")
        row["target"]["label"] = "not a redacted title"
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(native.Unavailable):
                native.export_events(Path(directory), "events.json", [row])

    def test_activity_client_authenticates_and_never_accepts_mutations(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / "activity.sock")
            requests = []
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(path)
                server.listen(1)

                def serve():
                    connection, _ = server.accept()
                    with connection:
                        data = b""
                        while b"\n" not in data:
                            data += connection.recv(4096)
                        requests.append(json.loads(data))
                        connection.sendall(b'{"ok":true,"result":{"sessions":[]}}\n')

                thread = threading.Thread(target=serve)
                thread.start()
                with patch.dict(os.environ, {"WORKFLOW_TEST_TOKEN": "synthetic-token"}):
                    client = native.Activity({"socket": path, "token_env": "WORKFLOW_TEST_TOKEN"})
                    self.assertEqual(client.read("activity_sessions_list", {}), {"sessions": []})
                    with self.assertRaises(native.Unavailable):
                        client.read("call", {"name": "click"})
                thread.join(timeout=5)
                self.assertFalse(thread.is_alive())
            self.assertEqual(requests, [{"auth_token": "synthetic-token", "request": {
                "method": "activity_sessions_list", "args": {}}}])


if __name__ == "__main__":
    unittest.main()
