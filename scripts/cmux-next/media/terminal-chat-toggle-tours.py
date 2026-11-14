#!/usr/bin/env python3
"""Writes the Toggle Terminal and Chat latency tours (idle, mid-turn terminal pair, mid-turn hand-off).

    terminal-chat-toggle-tours.py tours/terminal-chat-swap-toggle.json terminal-chat-toggle-live-turn.py tours RUNS

The idle tour takes RUNS 20; the mid-turn tour takes RUNS 8 (its frame strips take 5-15 s each while the watched chat
follows the running turn, and a capture drives about 150 s of steps), so run it more than once for 20 samples. The
hand-off tour (a live chat on the fake agent as `claude`) is not checked in: on 6607470d288 its new_chat and
send_prompt were refused, so it measured no mid-turn hand-off yet.
"""
import base64
import json
import sys
from pathlib import Path

swap_tour, live_py, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
RUNS = int(sys.argv[4]) if len(sys.argv) > 4 else 20
seed_text = json.loads(swap_tour.read_text())["steps"][2]["cmux"][-1]
assert seed_text.startswith("clear; mkdir -p") and seed_text.endswith("echo HOOK-SENT\r"), seed_text[-40:]
GATE = "/tmp/cmux-toggle-gate-5a7e"
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
        steps.append(strip(f"Run {i} {case_a}: Opt-Cmd-` chat to terminal, frames around it"))
        steps.append(strip(f"Run {i} {case_b}: Opt-Cmd-` terminal to chat, frames around it"))
    steps.append(timing("stop"))
    return steps


def tour(title, steps, **extra):
    return {"title": title, **extra, "steps": steps}


idle = tour(
    "Toggle Terminal and Chat latency, idle: 2,000-turn Claude Code chat whose session a terminal runs",
    [*new_workspace("Swap"), seed("Swap", "5a7e5a7e-0000-4000-8000-000000002000"),
     toggle("Toggle Terminal and Chat: the reported session opens as its View Only chat"),
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
     toggle("Toggle Terminal and Chat: the reported session opens as its View Only chat"),
     chat_state("Before: the chat painted its newest turn", ["Answer 1999"], 20),
     chat_state("The chat follows the terminal's running turn", ["Live"], 20),
     *swaps("(c) mid-turn terminal pair", "(d) mid-turn terminal pair", RUNS),
     chat_state("Right after the swaps: the chat shows the newest live line", ["Live"]),
     write("Helper", "touch \"$HOME/swap-bench/stop\"\r", "The turn ends", 3.0),
     chat_state("After: the closing answer, once", ["Live done after"], 20)])

# The hand-off: a live chat on the claude harness (the fake agent as `claude`), mid-turn on a gate, no terminal
# running it. Its conversation id is the fake agent's first: FAKE_SESSION_PREFIX + "1".
HAND_ID = "5a7e5a7e-0000-4000-8000-000000003001"
cut = seed_text.index(" && cmux agent hook emit")
store_seed = (seed_text[:cut].replace("S=5a7e5a7e-0000-4000-8000-000000002000", f"S={HAND_ID}")
              + f" && rm -f {GATE} && mkfifo {GATE} && echo STORE-READY\r")
HAND_C, HAND_D = int(sys.argv[5]) if len(sys.argv) > 5 else 8, int(sys.argv[6]) if len(sys.argv) > 6 else 10
handoff_steps = [
    *new_workspace("Helper"),
    {"title": "The conversation's transcript in the Claude store (2,000 turns), and the gate", "daemon": True,
     "cmux": ws("Helper", "terminal", "current", "write", "--text", store_seed), "wait": 5, "shot": False},
    *new_workspace("Hand"),
    {"title": "A new agent chat", "cmux": ["action", "run", "palette.newAgentChat", "--focus"], "wait": 3, "shot": False},
    {"title": "On the claude harness (the fake agent)",
     "rpc": {"method": "debug.agent_pane", "params": {"action": "new_chat", "harness": "claude"}}, "record": True,
     "wait": 3, "shot": False},
    {"title": "A first prompt names the conversation",
     "rpc": {"method": "debug.agent_pane", "params": {"action": "send_prompt", "text": "hello"}}, "record": True,
     "wait": 1, "shot": False},
    chat_state("The first answer", ["hello"], 15),
    {"title": "A turn starts and waits on the gate (the fake agent's gate:)",
     "rpc": {"method": "debug.agent_pane", "params": {"action": "send_prompt", "text": f"gate: {GATE}"}},
     "record": True, "wait": 1.0, "shot": False},
    chat_state("Mid-turn: before-gate shows", ["before-gate"], 15),
    timing("start"),
]
for i in range(1, HAND_C + 1):
    handoff_steps += [
        strip(f"Run {i} (c) mid-turn hand-off: Opt-Cmd-` chat to a new terminal running acpmux resume-here", 700),
        {"title": "Close the hand-off terminal, so the next run opens a new one",
         "cmux": ["action", "run", "closeTab", "--focus"], "wait": 1.0, "shot": False},
    ]
handoff_steps.append(strip(f"Run {HAND_C + 1} (c) mid-turn hand-off: Opt-Cmd-` chat to a new terminal running acpmux resume-here", 700))
for i in range(1, HAND_D + 1):
    handoff_steps += [
        strip(f"Run {i} (d) mid-turn hand-off: Opt-Cmd-` the hand-off terminal to the live chat", 500),
        strip(f"Run {i} (e) mid-turn hand-off: Opt-Cmd-` the chat to its open hand-off terminal", 500),
    ]
handoff_steps += [
    timing("stop"),
    toggle("To the chat", 1.0),
    chat_state("Mid-turn after the runs: still before-gate, rows as before", ["before-gate"]),
    write("Helper", f"echo go > {GATE}\r", "The turn ends (the gate opens)", 0.2),
    chat_state("The hand-off: after-gate shows", ["after-gate"], 20, wait=0.2),
    {"title": "The acpmux wire log after the hand-off",
     "rpc": {"method": "debug.agent_pane", "params": {"action": "acp_log", "limit": 80}}, "record": "file",
     "wait": 0.5, "shot": False, "optional": "wire log"},
]
handoff = tour("Toggle Terminal and Chat latency, mid-turn hand-off: a live chat mid-turn resumes in a terminal",
               handoff_steps,
               fakeHarness={"id": "claude", "name": "Claude Code", "family": "claude",
                            "env": {"FAKE_SESSION_PREFIX": "5a7e5a7e-0000-4000-8000-00000000300"}})

out.mkdir(parents=True, exist_ok=True)
for name, data in (("terminal-chat-toggle-idle", idle), ("terminal-chat-toggle-midturn", midturn_terminal),
                   ("terminal-chat-toggle-handoff", handoff)):
    (out / f"{name}.json").write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(name, len(data["steps"]), "steps")
