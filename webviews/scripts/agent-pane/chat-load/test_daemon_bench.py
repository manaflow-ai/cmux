"""Behavioral checks for the daemon benchmark's production open contract."""
import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch


source = Path(os.environ.get("DAEMON_BENCH_SOURCE", Path(__file__).with_name("daemon_bench.py")))
spec = importlib.util.spec_from_file_location("daemon_bench", source)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class Rpc:
    def __init__(self, page):
        self.page = page
        self.calls = []

    def call(self, method, params):
        self.calls.append((method, params))
        return (self.page if method == "_acpmux/attach" else {}), 100


def page(**fields):
    return {"events": [{"seq": 10, "dir": "in", "kind": "agent_message_chunk"}],
            "hasMore": True, "lastSeq": 11, "session": {}, **fields}


class OpenTests(unittest.TestCase):
    def test_missing_newest_message_fails_the_sample(self):
        with self.assertRaisesRegex(AssertionError, "newest fixture message"):
            bench.open_chat(Rpc(page(turnOpener=None)), "chat", "TAIL 9999: ")

    def test_open_does_not_wait_for_log_restore(self):
        rpc = Rpc(page(turnOpener=None))
        bench.open_chat(rpc, "chat")
        self.assertIs(rpc.calls[0][1].get("waitLogs"), False)

    def test_served_opener_does_not_trigger_a_second_scan(self):
        for opener in (None, {"seq": 1, "dir": "mux", "kind": "user_message"}):
            with self.subTest(opener=opener):
                rpc = Rpc(page(turnOpener=opener))
                result = bench.open_chat(rpc, "chat")
                self.assertNotIn("opener", result["calls"])

    def test_older_daemon_still_gets_opener_fallback(self):
        rpc = Rpc(page())
        result = bench.open_chat(rpc, "chat")
        self.assertIn("opener", result["calls"])
        request = next(params for method, params in rpc.calls
                       if method == "_acpmux/events" and params["kinds"] == ["user_message"])
        self.assertEqual(request["beforeSeq"], 10)

    def test_first_page_and_draw_ready_exclude_background_command_read(self):
        rpc = Rpc(page(turnOpener=None))
        with patch.object(bench.time, "perf_counter", side_effect=[0, .01, .03, .04, .05, .25, .26, .27]):
            result = bench.open_chat(rpc, "chat")
        self.assertEqual(result["first_page_ms"], 30)
        self.assertEqual(result["draw_ready_ms"], 40)
        self.assertEqual(result["stages"][0],
                         {"name": "attach", "sent_ms": 10, "received_ms": 30, "wall_ms": 20, "bytes": 100})
        self.assertGreater(result["stages"][1]["received_ms"], result["draw_ready_ms"])


if __name__ == "__main__":
    unittest.main()
