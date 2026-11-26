#!/usr/bin/env python3
"""The acpmux test agent (cmux-tui/crates/acpmux/tests/fake_agent.py) plus one prompt, for the
idle-cost bench (bench_power.py `loaded`):

  "stream: S R [B [T U]]"  streams a word R times a second for S seconds (at most 3600), honours session/cancel;
                    with B, each chunk is about B bytes of text (a word and filler words), as a fast agent writes;
                    with T, U times a second the chat is retitled (`session_info_update`) to a title of T/4 to T
                    bytes, so every list watcher gets a large changed row (the timeBreakdown-sized rows of #48408)

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


def title_text(n: int, most: int) -> str:
    """The `n`th retitle: a new title each time, from a quarter of `most` bytes up to `most`."""
    size = most // 4 + (most - most // 4) * ((n * 37) % 100) // 99
    head = f"Retitle {n} "
    return head + ("timeBreakdown tokens " * (size // 21 + 1))[:max(size - len(head), 0)]


def handle_prompt(rid, params):
    sid = params["sessionId"]
    # fake_agent's own reader: it leaves out the lead marks acpmux puts ahead of a prompt a program sent (`cmux agents
    # chat send` from a script: "From a program that did not say who it is, not the person:") and the hidden guidance,
    # so a prompt from a script still starts with "stream:".
    text = agent.prompt_text(params)
    if not text.startswith("stream:"):
        return _handle_prompt(rid, params)
    words = text[len("stream:"):].split()
    seconds = min(float(words[0]) if words else 60.0, 3600.0)
    rate = max(float(words[1]) if len(words) > 1 else 4.0, 0.1)
    chunk = min(max(int(float(words[2])) if len(words) > 2 else 0, 0), 65536)
    title = min(max(int(float(words[3])) if len(words) > 3 else 0, 0), 262144)
    title_every = 1 / max(float(words[4]) if len(words) > 4 else 1.0, 0.01)
    deadline, n = time.monotonic() + seconds, 0
    next_title, titles = time.monotonic(), 0
    while time.monotonic() < deadline:
        if sid in agent.cancelled:
            agent.cancelled.discard(sid)
            agent.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
            return
        text = f"word{n} "
        if chunk > len(text):
            text += ("lorem ipsum dolor sit amet " * (chunk // 27 + 1))[:chunk - len(text)]
        agent.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})
        if title and time.monotonic() >= next_title:
            agent.update(sid, {"sessionUpdate": "session_info_update", "title": title_text(titles, title)})
            titles += 1
            next_title += title_every
        n += 1
        time.sleep(1 / rate)
    agent.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


# fake_agent's main loop looks handle_prompt up as a module global for each prompt.
agent.handle_prompt = handle_prompt

if __name__ == "__main__":
    sys.exit(agent.main())
