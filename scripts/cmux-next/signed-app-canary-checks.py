#!/usr/bin/env python3
"""The canary checks of smoke-signed-app-cli.sh --canary, on a running signed app.

Runs against a Release bundle, so it uses only what a Release control socket
serves (no debug.* method): snapshot.get for windows and tabs, the bundled CLI
for the New Tab, and the app's own acpmux daemon for an agent session. The
agent is acpmux's test agent (cmux-tui/crates/acpmux/tests/fake_agent.py),
registered in the scratch ACPMUX_HOME config the smoke wrote, so no account or
network is needed. The control and acpmux clients are the readiness soak's
(bench_idle.Client, readiness-soak.py Acpmux).

  signed-app-canary-checks.py --socket S --cli CLI --acpmux-home H --harness ID --cwd DIR

Prints one `ok:` line per check and exits 1 on the first failure.
"""
from __future__ import annotations

import argparse
import importlib.util
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_idle import Client  # noqa: E402

_spec = importlib.util.spec_from_file_location("readiness_soak", os.path.join(HERE, "readiness-soak.py"))
soak = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(soak)

PROMPT = "cmux nightly canary ping"


class Failed(Exception):
    pass


def wait(condition, seconds, step=0.5):
    deadline = time.monotonic() + seconds
    while True:
        value = condition()
        if value or time.monotonic() >= deadline:
            return value
        time.sleep(step)


def snapshot(socket_path):
    reply = Client(socket_path, timeout=10).call("snapshot.get")
    if "error" in reply:
        raise Failed(f"snapshot.get: {reply['error']}")
    return reply.get("result") or {}


def tabs(node):
    """Every object in any `tabs` list of the snapshot, by id."""
    found = {}
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "tabs" and isinstance(value, list):
                found.update({tab["id"]: tab for tab in value if isinstance(tab, dict) and "id" in tab})
            found.update(tabs(value))
    elif isinstance(node, list):
        for value in node:
            found.update(tabs(value))
    return found


def visible_window(socket_path):
    # snapshot.get answers {topology: {windows: [{id, visible, ...}], workspaces: [...]}}
    # (ControlTopology+JSON.swift); `cmux window list` reads the same list.
    windows = (snapshot(socket_path).get("topology") or {}).get("windows") or []
    return next((w for w in windows if w.get("visible") is True), None)


def agent_turn(acpmux_home, harness, cwd, timeout):
    """Start a session of the test agent in the app's own acpmux and prompt it once; the
    session id once the agent's reply is in the session's events."""
    acp = soak.Acpmux(soak.acpmux_socket(acpmux_home))
    if not wait(lambda: "error" not in (acp.call("_acpmux/status", timeout=3) or {"error": 1}), timeout, 1):
        raise Failed(f"the app's acpmux did not answer within {timeout:.0f}s")
    acp.call("_acpmux/reload_config")
    acp.call("acp.trust.set", {"cwd": cwd, "level": "trusted"})
    created = acp.call("session/new", {"cwd": cwd, "mcpServers": [],
                                       "_meta": {"acpmux": {"harness": harness}}}) or {}
    session = created.get("sessionId")
    if not session:
        raise Failed(f"session/new: {str(created)[:400]}")
    print(f"ok: agent session {session} started")
    answered = acp.call("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": PROMPT}]},
                        timeout=timeout) or {}
    if "error" in answered:
        raise Failed(f"session/prompt: {str(answered)[:400]}")

    def reply():
        page = acp.call("_acpmux/events", {"sessionId": session}) or {}
        text = []
        for event in page.get("events", []) if isinstance(page, dict) else []:
            msg = event.get("msg") or {}
            update = msg.get("params", {}).get("update") or msg.get("update") or {}
            if update.get("sessionUpdate") == "agent_message_chunk":
                text.append((update.get("content") or {}).get("text", ""))
        return PROMPT in "".join(text)
    if not wait(reply, 20):
        raise Failed("the agent's reply is not in the session's events")
    print(f"ok: the agent answered the prompt (stopReason {answered.get('stopReason')})")
    return session


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", required=True)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--acpmux-home", required=True)
    parser.add_argument("--harness", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args(argv)
    try:
        window = wait(lambda: visible_window(args.socket), args.timeout)
        if not window:
            raise Failed(f"no visible window within {args.timeout:.0f}s")
        print(f"ok: window {window.get('id')} is visible")

        before = tabs(snapshot(args.socket))
        made = subprocess.run([args.cli, "--app-socket", args.socket, "tab", "new-page"],
                              capture_output=True, text=True, timeout=30)
        if made.returncode != 0:
            raise Failed(f"cmux tab new-page exited {made.returncode}: {made.stderr.strip()[-400:]}")
        new = wait(lambda: {k: v for k, v in tabs(snapshot(args.socket)).items() if k not in before}, 20)
        if not new:
            raise Failed("cmux tab new-page answered but no new tab is in snapshot.get")
        tab = next(iter(new.values()))
        print(f"ok: New Tab {tab.get('id')} (kind {tab.get('kind')}, page {tab.get('page')}, title {tab.get('title')!r})")

        agent_turn(args.acpmux_home, args.harness, args.cwd, args.timeout)
    except (Failed, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
