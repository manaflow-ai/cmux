#!/usr/bin/env python3
"""Exercise Grok's native-title hook through an isolated socket and session store.

Run with --cli pointing at the exact built CLI. No provider or running app is used.
"""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.parse
import uuid


def run_case(cli, summary, expected, *, stale=False, unrelated_claude=False):
    with tempfile.TemporaryDirectory(prefix="grok-title-", dir="/tmp") as temporary:
        root = Path(temporary)
        workspace, surface, session = (str(uuid.uuid4()) for _ in range(3))
        cwd = str(root / "project with spaces")
        session_dir = root / "grok" / "sessions" / urllib.parse.quote(cwd, safe="") / session
        session_dir.mkdir(parents=True)
        (session_dir / "summary.json").write_text(json.dumps(summary))
        now = time.time()
        record = {"sessionId": session, "workspaceId": workspace, "surfaceId": surface,
                  "cwd": cwd, "startedAt": now, "updatedAt": now}
        active = {"sessionId": "new-session" if stale else session, "updatedAt": now}
        store = {"version": 1, "sessions": {session: record},
                 "activeSessionsBySurface": {surface: active}}
        if stale:
            store["sessions"]["new-session"] = dict(record, sessionId="new-session")
        (root / "grok-hook-sessions.json").write_text(json.dumps(store))
        claude_path = root / "claude-hook-sessions.json"
        if unrelated_claude:
            claude_path.write_text(json.dumps({"version": 1,
                "sessions": {"claude-session": dict(record, sessionId="claude-session")},
                "activeSessionsBySurface": {surface: {"sessionId": "claude-session", "updatedAt": now}}}))
        requests = []
        socket_path = str(root / "control.sock")
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(socket_path)
        listener.listen()
        listener.settimeout(0.2)
        stopped = threading.Event()
        failures = []

        def serve():
            try:
                while not stopped.is_set():
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    with connection:
                        connection.settimeout(5)
                        stream = connection.makefile("rwb")
                        for raw in stream:
                            request = json.loads(raw)
                            requests.append(request)
                            stream.write((json.dumps({"id": request["id"], "ok": True,
                                "result": {"applied": True, "enabled": False}}) + "\n").encode())
                            stream.flush()
            except Exception as error:
                failures.append(error)

        server = threading.Thread(target=serve, daemon=True)
        server.start()
        try:
            result = subprocess.run([
                cli, "--socket", socket_path, "hooks", "grok", "sync-native-title",
                "--session", session, "--workspace", workspace, "--surface", surface,
            ], env={"PATH": "/usr/bin:/bin", "HOME": temporary,
                    "CMUX_AGENT_HOOK_STATE_DIR": temporary,
                    "CMUX_CLAUDE_HOOK_STATE_PATH": str(claude_path),
                    "GROK_HOME": str(root / "grok"), "CMUX_CLI_SENTRY_DISABLED": "1"},
                capture_output=True, text=True, timeout=15)
        finally:
            stopped.set()
            server.join(timeout=6)
            listener.close()
        assert not server.is_alive(), "Socket fixture did not stop"
        assert not failures, failures
        assert result.returncode == 0, result.stderr
        applied = [r for r in requests if "title" in r.get("params", {})]
        if expected is None:
            assert not applied, applied
        else:
            assert len(applied) == 1, requests
            request = applied[0]
            assert request["method"] == "surface.sync_grok_native_title", request
            assert request["params"]["title"] == expected, request
            assert request["params"]["workspace_id"] == workspace, request
            assert request["params"]["panel_id"] == surface, request
        assert all(r["method"] != "workspace.set_auto_title" for r in requests), requests
        print(f"PASS title={expected!r}, stale={stale}, unrelated_claude={unrelated_claude}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", default=os.environ.get("CMUX_CLI_BIN"))
    args = parser.parse_args()
    if not args.cli:
        parser.error("--cli or CMUX_CLI_BIN is required")
    cli = str(Path(args.cli).resolve())
    generated = "Fix Broken Magic Mouse Desktop Gestures"
    run_case(cli, {"generated_title": generated}, generated)
    run_case(cli, {"generated_title": generated, "display_name": "My Grok session"}, "My Grok session")
    run_case(cli, {"generated_title": generated, "display_name": "  "}, generated)
    run_case(cli, {"generated_title": generated}, generated, unrelated_claude=True)
    run_case(cli, {"generated_title": generated}, None, stale=True)
    run_case(cli, {"generated_title": None, "display_name": 42}, None)
