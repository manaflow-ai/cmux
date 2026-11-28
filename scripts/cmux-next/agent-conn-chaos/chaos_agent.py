#!/usr/bin/env python3
"""The agent connection chaos suite's scripted agent: acpmux's test agent
(cmux-tui/crates/acpmux/tests/fake_agent.py) plus two prompts, and a log of every prompt it is given. No model call.

  "chaos-stream: TAG COUNT RATE"  streams exactly COUNT words `TAG-0 TAG-1 ... TAG-<COUNT-1>`, RATE words a second,
                                  then ends the turn (end_turn); a session/cancel ends it cancelled. Count-based, not
                                  time-based, so the suite knows the whole reply a turn must show after a fault.
  "chaos-ping: NONCE"             waits 5 s, then answers `pong NONCE`: the prompt a person sends while the link is
                                  down. The wait keeps the stream's row the chat's last reply for a few seconds after
                                  it ends, so the suite reads that row whole on the page.

Every other prompt is fake_agent's (a first turn is echoed). The first argument is the log file: one JSON line per
prompt the agent was given ({"at", "pid", "session", "text"}) and per stream end ({"end", "tag", "sent"}), so the suite
counts each prompt's deliveries from the agent's side (exactly once) and knows how many words the agent wrote.
"""
import importlib.util
import json
import os
import sys
import time

LOG = sys.argv[1] if len(sys.argv) > 1 else os.devnull
_PATH = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..",
                                      "cmux-tui", "crates", "acpmux", "tests", "fake_agent.py"))
_spec = importlib.util.spec_from_file_location("fake_agent", _PATH)
agent = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(agent)
_handle_prompt = agent.handle_prompt


def log(entry: dict):
    entry = {"at": time.time(), "pid": os.getpid(), **entry}
    with open(LOG, "a") as handle:  # one write per line: O_APPEND keeps lines whole across agent processes
        handle.write(json.dumps(entry) + "\n")


def handle_prompt(rid, params):
    sid = params["sessionId"]
    text = agent.prompt_text(params)
    log({"session": sid, "text": text})
    if text.startswith("chaos-ping:"):
        nonce = text[len("chaos-ping:"):].strip()
        time.sleep(5)  # test agent: holds the stream's row as the last reply (the module doc)
        agent.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"pong {nonce}"}})
        agent.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        return
    if not text.startswith("chaos-stream:"):
        return _handle_prompt(rid, params)
    words = text[len("chaos-stream:"):].split()
    tag = words[0]
    count = min(int(words[1]), 20000)
    rate = max(float(words[2]), 0.5)
    sent = 0
    for n in range(count):
        if sid in agent.cancelled:
            agent.cancelled.discard(sid)
            log({"end": "cancelled", "tag": tag, "sent": sent, "session": sid})
            agent.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "cancelled"}})
            return
        agent.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": f"{tag}-{n} "}})
        sent += 1
        time.sleep(1 / rate)  # test agent: the reply's pace
    log({"end": "end_turn", "tag": tag, "sent": sent, "session": sid})
    agent.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


# fake_agent's main loop looks handle_prompt up as a module global for each prompt.
agent.handle_prompt = handle_prompt

if __name__ == "__main__":
    sys.argv = sys.argv[:1]
    sys.exit(agent.main())
