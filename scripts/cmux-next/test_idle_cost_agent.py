"""idle_cost_agent.py reads `stream:` from a prompt a program sent, with acpmux's lead mark ahead of it."""
import importlib.util
import os
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))


def load():
    spec = importlib.util.spec_from_file_location("idle_cost_agent", os.path.join(HERE, "idle_cost_agent.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Stream(unittest.TestCase):
    def run_prompt(self, blocks):
        module = load()
        sent = []

        def update(sid, upd):
            # One chunk, then the turn is cancelled: the loop ends without waiting.
            sent.append(upd)
            module.agent.cancelled.add(sid)

        with mock.patch.object(module.agent, "update", update), \
                mock.patch.object(module.agent, "send", lambda obj: sent.append(obj)), \
                mock.patch.object(module, "_handle_prompt", lambda rid, params: sent.append("fake_agent")), \
                mock.patch.object(module.time, "sleep", lambda s: None):
            module.handle_prompt(1, {"sessionId": "s", "prompt": blocks})
        return sent

    def test_a_plain_stream_prompt_streams(self):
        sent = self.run_prompt([{"type": "text", "text": "stream: 900 8"}])
        self.assertNotIn("fake_agent", sent)
        self.assertEqual(sent[0]["content"]["text"], "word0 ")

    def test_a_chunk_size_fills_each_chunk(self):
        sent = self.run_prompt([{"type": "text", "text": "stream: 900 8 400"}])
        text = sent[0]["content"]["text"]
        self.assertTrue(text.startswith("word0 "))
        self.assertEqual(len(text), 400)

    def test_a_title_size_retitles_with_a_large_title(self):
        sent = self.run_prompt([{"type": "text", "text": "stream: 900 8 0 80000 5"}])
        self.assertEqual(sent[0]["content"]["text"], "word0 ")
        self.assertEqual(sent[1]["sessionUpdate"], "session_info_update")
        self.assertEqual(len(sent[1]["title"]), 20000)  # the first retitle: a quarter of the most
        module = load()
        sizes = [len(module.title_text(n, 80000)) for n in range(100)]
        self.assertEqual((min(sizes), max(sizes)), (20000, 80000))
        self.assertEqual(len({module.title_text(n, 80000) for n in range(5)}), 5)  # each one a change

    def test_a_stream_prompt_behind_a_lead_mark_streams(self):
        mark = {"type": "text", "text": "From a program that did not say who it is, not the person:",
                "_meta": {"acpmux": {"attribution": True}}}
        sent = self.run_prompt([mark, {"type": "text", "text": "stream: 900 8"}])
        self.assertNotIn("fake_agent", sent)
        self.assertEqual(sent[0]["content"]["text"], "word0 ")

    def test_another_prompt_is_fake_agents(self):
        self.assertEqual(self.run_prompt([{"type": "text", "text": "whoami"}]), ["fake_agent"])


if __name__ == "__main__":
    unittest.main()
