#!/usr/bin/env python3
"""Credit-free ACP agent for pair-e2e's new-chat leg (cmux_next_pair_e2e.py).

acpmux's own test agent (`cmux-tui/crates/acpmux/tests/fake_agent.py`, path in FAKE_AGENT),
except that a plain prompt streams its reply a word at a time, 150 ms apart, so the phone's
recording shows the reply arriving in the chat. Prefixed prompts (`ask:`, `question:`, ...) are
fake_agent's own.
"""
import importlib.util
import os
import time

spec = importlib.util.spec_from_file_location("fake_agent", os.environ["FAKE_AGENT"])
fake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake)

original_prompt = fake.handle_prompt
REPLY = ("Streaming from the Mac: this chat started from the phone's first message, "
         "and the reply arrives here word by word. Done.")


def handle_prompt(rid, params):
    sid = params["sessionId"]
    text = "".join(b.get("text", "") for b in params.get("prompt", []))
    if ":" in text.split(" ")[0]:
        return original_prompt(rid, params)
    for word in REPLY.split(" "):
        if sid in fake.cancelled:
            fake.cancelled.discard(sid)
            fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
            return
        fake.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": word + " "}})
        time.sleep(0.15)
    fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


fake.handle_prompt = handle_prompt
if __name__ == "__main__":
    fake.main()
