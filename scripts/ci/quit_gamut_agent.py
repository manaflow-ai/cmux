#!/usr/bin/env python3
"""The quit gamut's test agent (scripts/ci/quit_gamut_check.py): idle_cost_agent.py (fake_agent.py plus
"stream:") with each prompt cut to its fixture command.

`cmux agents chat send` hands a person's text to the chat through the agent mailbox, which delivers it framed as a
notice (lines of its own ahead of the text), so a fixture that matches the prompt's start ("gate:", "work-gate:",
"stream:") never sees its command. This agent finds the first fixture command anywhere in the prompt and passes the
prompt on from there, so the gamut drives the same fixtures however the build frames a delivery.
Lives beside idle_cost_agent.py (scripts/cmux-next/ in the copy the gamut makes) and loads it from there.
"""
import importlib.util
import os
import sys

_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "idle_cost_agent.py")
_spec = importlib.util.spec_from_file_location("idle_cost_agent", _PATH)
idle = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(idle)
agent = idle.agent
_handle_prompt = agent.handle_prompt  # idle_cost_agent's, which passes everything but "stream:" to fake_agent's

# Longest first, so "work-gate:" is not found as "gate:".
COMMANDS = ("work-gate:", "stream:", "gate:", "whoami")


def handle_prompt(rid, params):
    text = agent.prompt_text(params)
    found = [(text.find(c), c) for c in COMMANDS if c in text]
    if found:
        at = min(found)[0]
        # The command runs to the end of its line: a framed delivery may close with lines of its own.
        command = text[at:].split("\n", 1)[0].strip()
        params = {**params, "prompt": [{"type": "text", "text": command}]}
    return _handle_prompt(rid, params)


agent.handle_prompt = handle_prompt

if __name__ == "__main__":
    sys.exit(agent.main())
