#!/usr/bin/env python3
"""Writes the Toggle Terminal and Chat latency tours: idle, and mid-turn with the terminal running the turn.

    terminal-chat-toggle-tours.py tours/terminal-chat-swap-toggle.json terminal-chat-toggle-live-turn.py tours [RUNS]

A tour holds at most 30 steps (the media tour test), so the idle tour swaps 10 times each way and the mid-turn tour 7;
capture each twice for 20 and 14 samples (terminal-chat-toggle-latency.py reads one capture at a time). Each opens its
chat under debug.chat_open_trace, so a slow first swap shows where the open spent its time. The mid-turn hand-off (a
live chat no terminal runs) is not here: its path is being replaced by the writable chat.
"""
import base64
import json
import sys
from pathlib import Path

swap_tour, live_py, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
# A tour holds at most 30 steps (the media tour test): 10 runs each way idle, 7 mid-turn; capture each twice.
RUNS = int(sys.argv[4]) if len(sys.argv) > 4 else 10
RUNS_MID = min(RUNS, 7)
seed_text = json.loads(swap_tour.read_text())["steps"][2]["cmux"][-1]
assert seed_text.startswith("clear; mkdir -p") and seed_text.endswith("echo HOOK-SENT\r"), seed_text[-40:]
TOGGLE_KEY = {"key": "`", "modifiers": ["option", "command"], "above": True}


def ws(name, *rest):
    return ["workspace", f"name:{name}", "screen", "current", "pane", "current", "tab", "current", *rest]


def write(name, text, title, wait=1.0):
    return {"title": title, "daemon": True, "cmux": ws(name, "terminal", "current", "write", "--text", text),
            "wait": wait, "shot": False}


def new_workspace(name):
    return [
        {"title": f"New workspace {name}", "cmux": ["workspace", "new", "--name", name], "wait": 2, "shot": False},
        {"title": f"Show {name}", "cmux": ["workspace", f"name:{name}", "focus"], "wait": 1.5, "shot": False},
    ]


def seed(name, session, tail=""):
    text = seed_text.replace("S=5a7e5a7e-0000-4000-8000-000000002000", f"S={session}")
    assert text != seed_text or session.endswith("2000")
    text = text[:-1] + tail + "\r"
    return {"title": "Seed: a 2,000-turn Claude Code transcript in the Claude store, 3,000 lines of scrollback, and "
                      "the terminal reports the session (agent hook SessionStart)",
            "daemon": True, "cmux": ws(name, "terminal", "current", "write", "--text", text), "wait": 8, "shot": False}


def toggle(title, wait=4.0):
    return {"title": title, "cmux": ["action", "run", "palette.toggleTerminalChat", "--focus"], "wait": wait,
            "shot": False}


def chat_state(title, contains=None, within=None, wait=0.5):
    step = {"title": title, "rpc": {"method": "debug.agent_pane", "params": {"action": "chat_state"}},
            "record": "file", "wait": wait, "shot": False}
    if contains:
        step["readback"] = {"at": "lastAssistant.text", "contains": contains}
        if within:
            step["readback"]["within"] = within
    return step


def strip(title, duration=600, wait=0.3):
    return {"title": title, "rpc": {"method": "debug.new_tab",
                                    "params": {"action": "frame_strip", **TOGGLE_KEY, "duration_ms": duration}},
            "record": "file", "wait": wait, "shot": False}


def timing(action):
    step = {"title": f"debug.tab_switch {action}", "rpc": {"method": "debug.tab_switch", "params": {"action": action}},
            "wait": 0.3, "shot": False}
    if action == "stop":
        step["record"] = "file"
    return step


def swaps(case_a, case_b, n):
    steps = [timing("start")]
    for i in range(1, n + 1):
        steps.append(strip(f"Run {i} {case_a}: Toggle chat to terminal, frames around it"))
        steps.append(strip(f"Run {i} {case_b}: Toggle terminal to chat, frames around it"))
    steps.append(timing("stop"))
    return steps


# acpmux lists a `claude` harness only when the capture Mac has Claude Code on PATH; without one the toggle's View Only
# chat refuses to adopt the session ("unknown harness \"claude\"") and every swap measures an error page. The fixture
# lists `claude` on every mini; a View Only watch reads the transcript and never runs it.
CLAUDE_FIXTURE = {"harnesses": {"claude": {"kind": "claude-stdio", "argv": ["claude"], "family": "claude",
                                           "description": "Synthetic capture harness (Toggle Terminal and Chat tours)"}}}


def tour(title, steps, **extra):
    return {"title": title, "harnessFixture": CLAUDE_FIXTURE, **extra, "steps": steps}


def opened(title):
    """The toggle that opens the chat, traced (debug.chat_open_trace): where a slow first swap starts."""
    return [
        {"title": "Arm the chat open trace", "rpc": {"method": "debug.chat_open_trace", "params": {"action": "arm"}},
         "wait": 0.1, "shot": False, "optional": "debug.chat_open_trace"},
        toggle(title, 0.2),
        {"title": "The chat open trace (until the chat shows, then 1 s of frames)",
         "rpc": {"method": "debug.chat_open_trace",
                 "params": {"action": "wait", "timeout_ms": 15000, "settle_ms": 1000, "page_timing": True}},
         "record": "file", "wait": 2.0, "shot": False, "optional": "debug.chat_open_trace"},
    ]


idle = tour(
    "Toggle Terminal and Chat latency, idle: 2,000-turn Claude Code chat whose session a terminal runs",
    [*new_workspace("Swap"), seed("Swap", "5a7e5a7e-0000-4000-8000-000000002000"),
     *opened("Toggle Terminal and Chat: the reported session opens as its View Only chat"),
     chat_state("Before: the chat painted its newest turn", ["Answer 1999"], 30),
     *swaps("(a) idle", "(b) idle", RUNS),
     chat_state("After: the same newest turn, the same row count", ["Answer 1999"])])

live_b64 = base64.b64encode(live_py.read_bytes()).decode()
# The terminal's own turn starts 12 s after the seed (the chat is open by then): a line every 150 ms.
start_live = (" && echo " + live_b64 + " | base64 -d > \"$HOME/swap-bench/live.py\" && rm -f \"$HOME/swap-bench/stop\" "
              "&& sleep 12 && python3 \"$HOME/swap-bench/live.py\" \"$D/$S.jsonl\" \"$C\" \"$S\" \"$HOME/swap-bench/stop\"")
midturn_terminal = tour(
    "Toggle Terminal and Chat latency, mid-turn: the terminal's Claude Code turn streams into the transcript",
    [*new_workspace("Helper"), *new_workspace("Swap"), seed("Swap", "5a7e5a7e-0000-4000-8000-000000002002", start_live),
     *opened("Toggle Terminal and Chat: the reported session opens as its View Only chat"),
     chat_state("Before: the chat painted its newest turn", ["Answer 1999"], 20),
     chat_state("The chat follows the terminal's running turn", ["Live"], 20),
     *swaps("(c) mid-turn terminal pair", "(d) mid-turn terminal pair", RUNS_MID),
     chat_state("Right after the swaps: the chat shows the newest live line", ["Live"]),
     write("Helper", "touch \"$HOME/swap-bench/stop\"\r", "The turn ends", 3.0),
     chat_state("After: the closing answer, once", ["Live done after"], 20)])

# Held: the terminal face shows past the hidden chat's freeze (30 s) and idle release (60 s) before the swap back, so
# a chat page let go behind its own terminal shows as a rebuild (a late settle) on the swap back.
HOLD_S, RUNS_HOLD = 65, 1  # a capture drives at most 300 s and the setup takes most of it: one held run a capture, pool several


def held_swaps(n):
    steps = [timing("start")]
    for i in range(1, n + 1):
        steps.append(strip(f"Run {i} (e) held: Toggle chat to terminal, frames around it"))
        # A tour step waits at most 30 s (tour.py), so the hold is cut into steps of up to 30 s.
        left = HOLD_S
        while left > 0:
            part = min(left, 30)
            steps.append(write("Helper", "true\r", f"Run {i}: the terminal face shows for {HOLD_S} s"
                               + ("" if left == HOLD_S else f" ({left} s left)"), part))
            left -= part
        steps.append(strip(f"Run {i} (f) held {HOLD_S} s: Toggle terminal to chat, frames around it", 2500))
    steps.append(timing("stop"))
    return steps


held = tour(
    f"Toggle Terminal and Chat latency, held: the terminal face shows {HOLD_S} s before each swap back to the chat",
    [*new_workspace("Helper"), *new_workspace("Swap"), seed("Swap", "5a7e5a7e-0000-4000-8000-000000002004"),
     *opened("Toggle Terminal and Chat: the reported session opens as its View Only chat"),
     chat_state("Before: the chat painted its newest turn", ["Answer 1999"], 30),
     *held_swaps(RUNS_HOLD),
     chat_state("After: the same newest turn", ["Answer 1999"])])

out.mkdir(parents=True, exist_ok=True)
for name, data in (("terminal-chat-toggle-idle", idle), ("terminal-chat-toggle-midturn", midturn_terminal),
                   ("terminal-chat-toggle-held", held)):
    (out / f"{name}.json").write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(name, len(data["steps"]), "steps")
