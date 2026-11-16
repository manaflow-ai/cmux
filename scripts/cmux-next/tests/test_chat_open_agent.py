#!/usr/bin/env python3
"""chat_open_agent.py, the seed agent of the chat-open bench, answers its commands as acpmux sends them:
after the sender line acpmux puts ahead of a program's prompt and beside the context it adds to a first turn."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def load_agent():
    spec = importlib.util.spec_from_file_location("chat_open_agent", HERE / "chat_open_agent.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# A prompt as the bundled acpmux sends `acpmux send SESSION TEXT` from a program (hub/prompt_attribution.rs): a
# sender line marked `attribution`, then the text. Seen in a seeding daemon's log, 2026-11-16.
def sent(text):
    return {"sessionId": "chat-1", "prompt": [
        {"_meta": {"acpmux": {"attribution": True}}, "type": "text",
         "text": "From the program chat-open-bench.py on a Mac (acpmux checked its process), not the person:"},
        {"type": "text", "text": text}]}


# A first turn (`acpmux new ... TEXT`): the text, then the context blocks acpmux adds.
def first(text):
    return {"sessionId": "chat-1", "prompt": [
        {"type": "text", "text": text},
        {"_meta": {"acpmux": {"context": True, "contextSource": "cmux-default"}}, "type": "text",
         "text": "<cmux-default-context>Before each tool step, list what you need next.</cmux-default-context>"},
        {"_meta": {"acpmux": {"context": True, "contextSource": "cmux-guidance"}}, "type": "text"}]}


class SeedAgentTests(unittest.TestCase):
    def setUp(self):
        self.agent = load_agent()
        self.out = []
        self.agent.fake.send = self.out.append

    def kinds(self):
        return [((m.get("params") or {}).get("update") or {}).get("sessionUpdate") for m in self.out]

    def test_a_sent_subagents_prompt_spawns_its_subagents(self):
        # 2026-11-16: every seed of the subagent chat answered "echo: subagents: 5" and spawned none, so a
        # chat-open run stopped as "seed invalid" (spawned 0 of 5 subagents).
        self.agent.handle_prompt(7, sent("subagents: 5"))
        self.assertEqual(self.kinds().count("subagent_spawned"), 5)

    def test_a_sent_turn_prompt_is_a_whole_turn(self):
        self.agent.handle_prompt(7, sent("turn: 3"))
        self.assertGreaterEqual(self.kinds().count("tool_call"), 2)
        self.assertNotIn("echo:", "".join(str(m) for m in self.out))

    def test_a_first_turn_with_acpmux_context_is_a_whole_turn(self):
        self.agent.handle_prompt(7, first("turn: 0"))
        self.assertGreaterEqual(self.kinds().count("tool_call"), 2)


if __name__ == "__main__":
    unittest.main()
