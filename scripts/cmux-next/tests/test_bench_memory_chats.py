#!/usr/bin/env python3
"""Portable checks for rendered-chat evidence and WebKit PID attribution."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import MagicMock, patch


spec = importlib.util.spec_from_file_location("memory_chat_bench", Path(__file__).resolve().parents[1] / "bench_memory.py")
bm = importlib.util.module_from_spec(spec)
with patch("ctypes.CDLL", return_value=MagicMock()):
    spec.loader.exec_module(bm)


class ChatMeasurements(unittest.TestCase):
    def setUp(self):
        bm._observed_webkit.clear()
        self.chats = bm.FakeChats.__new__(bm.FakeChats)
        self.chats.app = MagicMock()
        self.chats.app_pid = 50
        self.chats.sessions = {"ws_chat": "session_expected"}
        self.chats.pages = {}

    def test_observation_waits_for_the_expected_session_before_capturing_pid(self):
        self.chats.app.rpc.side_effect = [
            {"pane": "pane_chat", "sessionId": "session_previous", "lastAssistant": {"text": "previous"}},
            {"pane": "pane_chat", "sessionId": "session_expected", "lastAssistant": {"text": "answer"}, "rows": 2},
            {"pane": "pane_chat", "engine": "webkit:own-host"},
            {"pane": "pane_chat", "pid": 70},
        ]
        with patch.object(bm, "process_table", return_value=[(70, 1, "com.apple.WebKit.WebContent")]), \
                patch.object(bm, "process_started", return_value="birth"), patch.object(bm.time, "sleep"):
            self.chats.observe("ws_chat")
        self.assertEqual(self.chats.pages["ws_chat"]["session"], "session_expected")
        self.assertEqual(self.chats.pages["ws_chat"]["renderer_pid"], 70)
        self.assertEqual(bm._observed_webkit, {50: {70: "birth"}})

    def test_observed_renderer_is_counted_when_launch_responsibility_is_elsewhere(self):
        bm._observed_webkit[50] = {70: "birth"}
        with patch.object(bm, "process_table", return_value=[(70, 1, "com.apple.WebKit.WebContent")]), \
                patch.object(bm, "_responsible", return_value=999), \
                patch.object(bm, "process_started", return_value="birth"):
            self.assertIn(70, bm.owned(50, "/app"))
            self.assertNotIn(70, bm.owned(51, "/app"))

    def test_reused_pid_is_excluded(self):
        bm._observed_webkit[50] = {70: "birth"}
        with patch.object(bm, "process_table", return_value=[(70, 1, "com.apple.WebKit.WebContent")]), \
                patch.object(bm, "_responsible", return_value=999), \
                patch.object(bm, "process_started", return_value="later birth"):
            self.assertNotIn(70, bm.owned(50, "/app"))

    def test_chat_count_and_distinct_surviving_renderers_are_separate(self):
        self.chats.sessions["ws_other"] = "session_other"
        self.chats.pages = {w: {"engine": "webkit:own-host", "renderer_pid": 70} for w in self.chats.sessions}
        result = {"processes": [], "kinds": {}}
        got = self.chats.observation(["ws_chat", "ws_other"], result)
        self.assertEqual(got["count"], 2)
        self.assertEqual(got["rendered_count"], 2)
        self.assertEqual(got["observed_webkit_renderer_pids"], [70])
        self.assertEqual(got["surviving_webkit_renderer_pids"], [])
        self.assertEqual(got["webkit_webcontent_count"], 0)

    def test_unrendered_chat_fails_instead_of_silently_lowering_counts(self):
        with self.assertRaisesRegex(RuntimeError, "never observed rendering"):
            self.chats.observation(["ws_chat"], {"processes": [], "kinds": {}})


if __name__ == "__main__":
    unittest.main()
