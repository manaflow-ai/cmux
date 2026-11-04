#!/usr/bin/env python3
"""The agent pane's streaming stand-in: acpmux's test agent (fake_agent.py) with one more prompt.

  "stream: SEED SECONDS CPS"   streams tuikit's seeded agent answer (numbered paragraphs, tool calls
                               with output, diffs) as agent_message_chunk updates of 1-6 characters at
                               CPS characters a second for SECONDS seconds, then ends the turn
                               (end_turn); a session/cancel ends it at the next chunk (cancelled).

Every other prompt is fake_agent.py's. fake_agent.py is found at $CMUX_TUIKIT_FAKE_AGENT, beside this
file, or in the repo (cmux-tui/crates/acpmux/tests/fake_agent.py). The same SEED gives the same text.
Harness profile (in the build's acpmux home, harnesses/tuikit-stream.toml; heavy_profile.py writes it):

  id = "tuikit-stream"
  name = "tuikit stream"
  command = "/usr/bin/python3"
  args = ["<this file>"]
"""
import importlib.util
import os
import random
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tuikit  # noqa: E402

FAKE = os.environ.get("CMUX_TUIKIT_FAKE_AGENT") or os.path.join(HERE, "fake_agent.py")
if not os.path.exists(FAKE):
    FAKE = os.path.join(HERE, "..", "..", "..", "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py")
spec = importlib.util.spec_from_file_location("fake_agent", FAKE)
fake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fake)
original = fake.handle_prompt


def markdown(block):
    kind = block[0]
    if kind == "heading":
        return "\n## %s\n\n" % block[1]
    if kind == "para":
        return block[1] + "\n\n"
    if kind == "diff":
        return "`%s`\n\n```diff\n%s\n```\n\n" % (block[1], "\n".join(block[2]))
    return ""


def stream(sid, seed, seconds, cps):
    """Returns the stop reason."""
    rng = random.Random(seed ^ 0x5EED)
    start = time.monotonic()
    sent = 0
    call = 0
    for block in tuikit.agent_blocks(seed):
        if block[0] == "tool":
            call += 1
            call_id = "tk-%d-%d" % (seed, call)
            fake.update(sid, {"sessionUpdate": "tool_call", "toolCallId": call_id, "title": block[1], "kind": "execute",
                              "status": "in_progress", "rawInput": {"command": block[1]}})
            fake.update(sid, {"sessionUpdate": "tool_call_update", "toolCallId": call_id, "status": "completed",
                              "content": [{"type": "content", "content": {"type": "text", "text": "\n".join(block[2])}}]})
            continue
        for tok in tuikit.tokens(markdown(block), rng):
            if sid in fake.cancelled:
                fake.cancelled.discard(sid)
                return "cancelled"
            if time.monotonic() - start >= seconds:
                return "end_turn"
            fake.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": tok}})
            sent += len(tok)
            due = start + sent / cps if cps > 0 else 0
            now = time.monotonic()
            if due > now:
                time.sleep(due - now)
    return "end_turn"


def handle_prompt(rid, params):
    said = "".join(block.get("text", "") for block in params.get("prompt", [])).strip()
    if not said.startswith("stream:"):
        original(rid, params)
        return
    parts = said[len("stream:"):].split()
    seed = int(parts[0]) if parts else 1
    seconds = float(parts[1]) if len(parts) > 1 else 60.0
    cps = float(parts[2]) if len(parts) > 2 else 400.0
    reason = stream(params["sessionId"], seed, seconds, cps)
    fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": reason}})


fake.handle_prompt = handle_prompt

if __name__ == "__main__":
    sys.argv[0] = FAKE
    fake.main()
