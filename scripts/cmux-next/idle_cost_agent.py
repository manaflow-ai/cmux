#!/usr/bin/env python3
"""The acpmux test agent (cmux-tui/crates/acpmux/tests/fake_agent.py) plus one prompt, for the
idle-cost bench (bench_power.py `loaded`):

  "stream: S R"  streams a word R times a second for S seconds (at most 3600), honours session/cancel

a reply still coming in through the measured window. Every other prompt is fake_agent's. It lives
here, not in fake_agent.py, so the bench leaves the cmux-tui tree as it is: a fleet app build
takes the cmux-tui published for that tree.
"""
import importlib.util
import os
import sys
import time

_PATH = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                      "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py"))
_spec = importlib.util.spec_from_file_location("fake_agent", _PATH)
agent = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(agent)
_handle_prompt = agent.handle_prompt


def handle_prompt(rid, params):
    sid = params["sessionId"]
    text = "".join(b.get("text", "") for b in params.get("prompt", []))
    if not text.startswith("stream:"):
        return _handle_prompt(rid, params)
    words = text[len("stream:"):].split()
    seconds = min(float(words[0]) if words else 60.0, 3600.0)
    rate = max(float(words[1]) if len(words) > 1 else 4.0, 0.1)
    deadline, n = time.monotonic() + seconds, 0
    while time.monotonic() < deadline:
        if sid in agent.cancelled:
            agent.cancelled.discard(sid)
            agent.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
            return
        agent.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"word{n} "}})
        n += 1
        time.sleep(1 / rate)
    agent.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


# fake_agent's main loop looks handle_prompt up as a module global for each prompt.
agent.handle_prompt = handle_prompt

if __name__ == "__main__":
    sys.exit(agent.main())
