"""typing-frame-bench.py agent_typing_verdict: a run is complete on its measurement (each key's frame and paint, in
order, with the exact text, joined to its native dispatch); a key with no listener or work stage is counted in
stage_missing and does not void the run. L2 on cmux20-bench at 8372af35 (2026-11-20) read incomplete over one key
whose work mark never came, of 200."""
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.join(HERE, "..", "typing-frame-bench.py")


def load_bench():
    out = tempfile.mkdtemp(prefix="typing-verdict-test-")
    before = set(os.listdir(tempfile.gettempdir()))
    with mock.patch.object(sys, "argv", ["typing-frame-bench.py", "--app", "/nonexistent.app", "--tag", "verdict-test",
                                         "--out", out]):
        spec = importlib.util.spec_from_file_location("typing_frame_bench", BENCH)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    made = set(os.listdir(tempfile.gettempdir())) - before
    for name in made | {os.path.basename(out)}:
        if name.startswith(("typing-verdict-test-", "typing-verdict-test", "typing-work-verdict-test-")):
            shutil.rmtree(os.path.join(tempfile.gettempdir(), name), ignore_errors=True)
    return mod


bench = load_bench()


def run(text, **broken):
    """Samples and native dispatches for TEXT, each key painted 10 ms after its dispatch; broken[i] edits sample i."""
    samples, dispatch = [], []
    for i, key in enumerate(text):
        sample = {"key": key, "frame": 5.0, "paint": 9.0, "listener": 1.0, "work": 3.0, "paint_epoch_ms": 1000.0 + i * 50 + 10}
        sample.update(broken.get(f"k{i}", {}))
        samples.append({k: v for k, v in sample.items() if v is not None})
        dispatch.append({"epoch_ms": 1000.0 + i * 50})
    return {"samples": samples, "composer_text": text}, dispatch


class AgentTypingVerdict(unittest.TestCase):
    TEXT = bench.agent_expected_text(5)

    def test_a_key_without_its_work_stage_is_counted_and_the_run_stays_complete(self):
        stats, dispatch = run(self.TEXT, k2={"work": None}, k4={"listener": None, "work": None})
        verdict = bench.agent_typing_verdict(stats, self.TEXT, dispatch)
        self.assertTrue(verdict["complete"])
        self.assertEqual(verdict["stage_missing"], {"listener": 1, "work": 2})
        self.assertEqual(verdict["dispatch_to_after_frame_p95_ms"], 10.0)

    def test_a_key_without_its_frame_or_paint_is_not_measured(self):
        for field in ("frame", "paint"):
            stats, dispatch = run(self.TEXT, k1={field: None})
            self.assertFalse(bench.agent_typing_verdict(stats, self.TEXT, dispatch)["complete"], field)

    def test_a_lost_or_reordered_key_is_never_complete(self):
        stats, dispatch = run(self.TEXT)
        stats["samples"].pop()
        self.assertFalse(bench.agent_typing_verdict(stats, self.TEXT, dispatch[:-1])["complete"])
        stats, dispatch = run("abdce")
        stats["composer_text"] = self.TEXT
        self.assertFalse(bench.agent_typing_verdict(stats, self.TEXT, dispatch)["key_order_ok"])


class StreamLoadMissing(unittest.TestCase):
    """cmux20-bench at 8372af35 (2026-11-20): all 18 real-agent chats stayed new_chat pending (attached=False), so L1,
    L2, L3 and L5 measured no stream while their runs read complete. A chat that never attached is named instead."""

    def test_a_real_chat_that_never_attached_names_the_missing_stream(self):
        with mock.patch.object(bench.opts, "chat_agent", "real"):
            attach = {"a": {"attached": True}, "b": {"attached": False}, "c": {"attached": False}}
            self.assertEqual(bench.stream_load_missing(["a", "b", "c"], attach),
                             "2 of 3 streaming chats never attached to the agent, so their streams never ran")
            self.assertEqual(bench.stream_load_missing(["d"], attach),
                             "1 of 1 streaming chats never attached to the agent, so their streams never ran")
            self.assertIsNone(bench.stream_load_missing(["a"], attach))
            self.assertIsNone(bench.stream_load_missing([], attach), "a mode with no stream misses none")

    def test_the_mock_agent_streams_without_a_session(self):
        with mock.patch.object(bench.opts, "chat_agent", "mock"):
            self.assertIsNone(bench.stream_load_missing(["b"], {"b": {"attached": False}}))


class SeedShort(unittest.TestCase):
    """cmux23 at f9ea9362 (2026-11-20): L3 seeded 99,999 of 100,000 rows (whole three-row turns) and read short."""

    def test_the_last_partial_turn_is_not_a_short_seed(self):
        self.assertFalse(bench.seed_short({"requested": 100000, "rows": 99999}))
        self.assertFalse(bench.seed_short({"requested": 100000, "rows": 100000}))

    def test_a_seed_a_turn_or_more_short_is_named(self):
        self.assertTrue(bench.seed_short({"requested": 100000, "rows": 99997}))
        self.assertTrue(bench.seed_short({"requested": 100000, "rows": 0}))


if __name__ == "__main__":
    unittest.main()
