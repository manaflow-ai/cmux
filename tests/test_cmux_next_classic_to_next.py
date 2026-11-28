#!/usr/bin/env python3
"""classic-to-next.py carries a classic workspace's split layout to cmux-next.

The fixture is a real classic session file: cmux 0.64.19 saved it on a fleet
mini after its own CLI built a workspace of two tabs on the left and a
top/bottom split on the right, each terminal in its own folder. The script runs
on it with --apply against a stand-in cmux-next socket, so the test checks the
request cmux-next receives (session.transfer.open). Before, every terminal of
a split workspace came over as a tab of one pane.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "cmux-next" / "classic-to-next.py"
FIXTURE = ROOT / "tests" / "fixtures" / "classic-to-next" / "session-com.cmuxterm.app.json"
PROJ = "/Users/cmux/p4rt-classic/proj"


def serve(path: str, requests: list, stop: threading.Event) -> threading.Thread:
    """A stand-in cmux-next socket: records each request and answers ok until `stop`."""
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen()
    server.settimeout(0.2)

    def run() -> None:
        with server:
            while not stop.is_set():
                try:
                    conn, _ = server.accept()
                except TimeoutError:
                    continue
                with conn:
                    data = b""
                    while b"\n" not in data:
                        chunk = conn.recv(1 << 16)
                        if not chunk:
                            break
                        data += chunk
                    request = json.loads(data.split(b"\n", 1)[0])
                    requests.append(request)
                    conn.sendall(json.dumps({"id": request["id"], "ok": True, "result": {"workspace": "ws_1"}}).encode() + b"\n")

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def opened_workspace(session: dict) -> dict:
    """Runs the script on `session` with --apply and returns the workspace it sent."""
    with tempfile.TemporaryDirectory(prefix="c2n-") as scratch:
        classic = os.path.join(scratch, "classic")
        empty = os.path.join(scratch, "empty")
        os.makedirs(classic)
        os.makedirs(empty)
        with open(os.path.join(classic, "session-com.cmuxterm.app.json"), "w") as f:
            json.dump(session, f)
        common = [sys.executable, "-I", str(SCRIPT), "--classic-dir", classic, "--hook-dir", empty,
                  "--claude-dir", empty, "--codex-dir", empty, "--bundle", "com.cmuxterm.app", "--days", "0"]
        listed = json.loads(subprocess.run([*common, "--json"], check=True, capture_output=True, text=True).stdout)
        row = next(w["id"] for w in listed["workspaces"] if w["title"] == "split api")
        sock = os.path.join(scratch, "next.sock")
        requests: list = []
        stop = threading.Event()
        thread = serve(sock, requests, stop)
        subprocess.run([*common, "--apply", "--select", row, "--socket", sock], check=True, capture_output=True, text=True,
                       timeout=60)
        stop.set()
        thread.join(5)
        opens = [r["params"]["workspace"] for r in requests
                 if r["method"] == "session.transfer.open" and "workspace" in r["params"]]
        assert len(opens) == 1, requests
        return opens[0]


def test_a_split_workspace_keeps_its_panes() -> None:
    workspace = opened_workspace(json.loads(FIXTURE.read_text()))
    assert [(t["title"], t["cwd"]) for t in workspace["terminals"]] == [
        ("api", f"{PROJ}/api"), ("logs", f"{PROJ}/api/logs"), ("web", f"{PROJ}/web"), ("db", f"{PROJ}/db"),
    ], workspace["terminals"]
    # Left: api and logs as tabs of one pane; right: web over db.
    assert workspace.get("layout") == {
        "split": "right", "ratio": 0.5,
        "first": {"terminals": [0, 1]},
        "second": {"split": "down", "ratio": 0.5, "first": {"terminals": [2]}, "second": {"terminals": [3]}},
    }, workspace.get("layout")


def test_a_pane_holding_only_an_agent_chat_folds_away() -> None:
    session = json.loads(FIXTURE.read_text())
    workspace = next(w for w in session["windows"][0]["tabManager"]["workspaces"] if w.get("customTitle") == "split api")
    db = next(p for p in workspace["panels"] if p.get("title") == "db")
    # The chat opens as its own cmux-next agent workspace, so its pane has no terminal here.
    db["terminal"]["resumeBinding"] = {"kind": "claude", "command": "claude --resume 0b4c1f7e-5a52-4f7c-9a55-1d9c3b2f6a10"}
    sent = opened_workspace(session)
    assert [t["title"] for t in sent["terminals"]] == ["api", "logs", "web"], sent["terminals"]
    assert sent.get("layout") == {"split": "right", "ratio": 0.5, "first": {"terminals": [0, 1]}, "second": {"terminals": [2]}}, \
        sent.get("layout")


def test_a_malformed_layout_still_brings_every_terminal() -> None:
    session = json.loads(FIXTURE.read_text())
    workspace = next(w for w in session["windows"][0]["tabManager"]["workspaces"] if w.get("customTitle") == "split api")
    panels = {p.get("title"): p for p in workspace["panels"]}
    # A hand-edited or damaged file: a split body that is not an object, a
    # pane listing a non-string id, and two terminals sharing an id.
    workspace["layout"]["split"]["second"]["split"] = ["not", "a", "split"]
    workspace["layout"]["split"]["first"]["pane"]["panelIds"].insert(0, {"id": 1})
    panels["logs"]["id"] = panels["api"]["id"]
    sent = opened_workspace(session)
    assert sorted(t["title"] for t in sent["terminals"]) == ["api", "db", "logs", "web"], sent["terminals"]
    assert sent.get("layout") is None, sent.get("layout")


def main() -> int:
    failures = 0
    for name, test in sorted(globals().items()):
        if name.startswith("test_") and callable(test):
            try:
                test()
                print(f"ok   {name}")
            except AssertionError as error:
                failures += 1
                print(f"FAIL {name}: {error}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
