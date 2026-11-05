#!/usr/bin/env python3
"""Typing into an agent chat after a Markdown file opened beside it (issue #25666).

  markdown-chat-typing-e2e.py --socket SOCKET --fake-agent PATH [--dir DIR]

Runs against a running no-activate tagged build (its control socket). An agent chat in
Chromium gets a session from acpmux's test agent (cmux-tui/crates/acpmux/tests/fake_agent.py,
harness `fake`). The pane splits, and a Markdown file opens in the new pane with focus, as an
agent's `cmux open` or a file link does. Then keys go to the chat's own Chromium page window
(`debug.key target: page`): the window AppKit sends a person's keys to after a click in the chat.

Before the fix the key router took them for the Markdown page the focus model named: its
type-ahead queue waited for that page's input and the chat got nothing (`handled_by: app`).
Checks: every key reaches the chat's page, and its composer text grows by the keys typed.
Exit 0 when both hold. Quits nothing: the caller ends the build.
"""
import argparse, json, os, shlex, socket, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the build's control socket")
parser.add_argument("--fake-agent", required=True, help="path of acpmux's tests/fake_agent.py")
parser.add_argument("--dir", help="the chat's folder and the Markdown file's")
opts = parser.parse_args()
opts.dir = opts.dir or tempfile.mkdtemp(prefix="md-chat-typing-")
failures = []


def rpc(method, params=None, timeout=30):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    conn.connect(opts.socket)
    conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = conn.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    conn.close()
    reply = json.loads(buf)
    return reply.get("result", reply)


def wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # test script: polls the app's state
    return predicate()


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def focus():
    window = (rpc("debug.focus").get("windows") or [{}])[0]
    return window.get("model") or {}


def other_panes(chat):
    window = (rpc("debug.focus").get("windows") or [{}])[0]
    return [entry["pane"] for entry in window.get("topology") or [] if entry.get("pane") != chat]


def composer_length(pane):
    return rpc("debug.agent_pane", {"action": "readiness", "pane": pane}).get("composer_text_length")


def main():
    os.makedirs(opts.dir, exist_ok=True)
    note = os.path.join(opts.dir, "notes.md")
    with open(note, "w") as f:
        f.write("# Notes\n\nA plan the agent wrote.\n")
    rpc("action.run", {"action": "agent.harness.add", "args": {"id": "fake", "name": "Fake", "command": sys.executable,
                                                               "args": shlex.quote(os.path.abspath(opts.fake_agent)), "protocol": "acp",
                                                               "replace": "true"}})
    rpc("debug.key", {"key": "t", "modifiers": ["cmd"]})
    chat = wait(lambda: focus().get("resolved") == "agentPage" and focus().get("resolved_pane"), 30)
    if not chat:
        sys.exit(f"no agent page took the focus: {focus()}")
    engine = rpc("debug.agent_pane", {"action": "engine", "pane": chat})
    print(f"chat pane {chat}: {engine}", flush=True)
    made = rpc("debug.agent_pane", {"action": "new_chat", "pane": chat, "harness": "fake", "cwd": opts.dir}, timeout=60)
    if not made.get("sessionId"):
        sys.exit(f"new_chat made no session: {made}")
    wait(lambda: rpc("debug.agent_pane", {"action": "chat_state", "pane": chat}).get("connection") == "attached", 30)

    # Control: the chat takes a key while the focus model names it.
    before = composer_length(chat)
    reply = rpc("debug.key", {"key": "a", "target": "page", "pane": chat})
    check(reply.get("handled_by") == "page", f"a key reaches the focused chat ({reply.get('handled_by')})")
    check(wait(lambda: composer_length(chat) != before, 5), "the focused chat's composer took it")

    # A Markdown file opens with focus in a pane beside the chat (a split when the chat's is the only one).
    if not other_panes(chat):
        rpc("action.run", {"action": "splitRight", "focus": True})
        wait(lambda: other_panes(chat), 15)
    beside = None
    for pane in reversed(other_panes(chat)):  # the newest pane first; one the focus lands in
        rpc("action.run", {"action": "pane.focus", "target": f"pane:{pane}", "focus": True})
        if wait(lambda: focus().get("resolved_pane") == pane, 5):
            beside = pane
            break
    if not beside:
        sys.exit(f"no pane beside the chat takes the focus: {other_panes(chat)}")
    rpc("file.open", {"path": note, "focus": True})
    markdown = wait(lambda: focus().get("resolved") == "page" and focus().get("resolved_pane") not in (None, chat)
                    and focus().get("resolved_pane"), 20)
    check(bool(markdown), f"the Markdown page has the focus ({focus().get('resolved')})")

    # The person types in the chat: the keys go to the chat's own page window.
    before = composer_length(chat)
    handled = [rpc("debug.key", {"key": key, "target": "page", "pane": chat}).get("handled_by") for key in "bcd"]
    check(handled == ["page"] * 3, f"keys in the chat's window reach the chat, not the Markdown page ({handled})")
    check(wait(lambda: composer_length(chat) == before + 3, 5),
          f"the chat's composer took all three ({before} -> {composer_length(chat)})")
    print("RESULT " + ("FAIL: " + "; ".join(failures) if failures else "PASS"), flush=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
