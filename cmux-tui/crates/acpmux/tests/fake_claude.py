#!/usr/bin/env python3
"""A tiny stand-in for Claude Code's stream-json protocol, for tests.

It answers every control_request with success, reports system/init after
initialize, and replies to every user message with its own arguments as
JSON (spawn-time checks of the Claude command line).

With FAKE_CLAUDE_STORE set it keeps Claude Code's own session store there:
the init reports the `--session-id`/`--resume` id, a conversation exists
once a user message reached it, and `--resume` of one that does not exist
fails the first prompt with Claude's own "No conversation found" line.
FAKE_CLAUDE_DIE=1 dies on the first prompt before anything is stored (a
launcher whose proxy is down); FAKE_CLAUDE_DIE_IF=<path> does so while that
file exists. With CLAUDE_CONFIG_DIR set (and no FAKE_CLAUDE_STORE), the store
is Claude Code's own layout: <CLAUDE_CONFIG_DIR>/projects/p/<id>.jsonl, with
a user and an assistant line per prompt; "history-probe" replies with the
prompts the conversation holds (a resumed or forked transcript's included).
"hold: PATH" answers once PATH exists, so a test can act while a turn runs.
"""
import json
import os
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# Like Claude Code, init reports the mode `--permission-mode` pinned.
MODE = "default"
if "--permission-mode" in sys.argv[:-1]:
    MODE = sys.argv[sys.argv.index("--permission-mode") + 1]

STORE = os.environ.get("FAKE_CLAUDE_STORE")
LAYOUT = None
if not STORE and os.environ.get("CLAUDE_CONFIG_DIR"):
    STORE = os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "projects", "p")
    LAYOUT = ".jsonl"
    os.makedirs(STORE, exist_ok=True)


def stored(sid):
    return os.path.join(STORE, sid + (LAYOUT or ""))
SESSION = "fake-claude-session"
RESUME = None
if STORE:
    for flag in ("--session-id", "--resume"):
        if flag in sys.argv[:-1]:
            SESSION = sys.argv[sys.argv.index(flag) + 1]
            if flag == "--resume":
                RESUME = SESSION

for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    kind = msg.get("type")
    if kind == "control_request":
        request = msg.get("request") or {}
        send({"type": "control_response", "response": {"subtype": "success", "request_id": msg.get("request_id"), "response": {}}})
        if request.get("subtype") == "initialize":
            send({"type": "system", "subtype": "init", "session_id": SESSION, "model": "fake",
                  "permissionMode": MODE, "tools": [], "mcp_servers": []})
    elif kind == "user":
        die_if = os.environ.get("FAKE_CLAUDE_DIE_IF")
        if os.environ.get("FAKE_CLAUDE_DIE") == "1" or (die_if and os.path.exists(die_if)):
            sys.stderr.write("proxy down\n")
            sys.stderr.flush()
            sys.exit(1)
        if STORE and RESUME and not os.path.exists(stored(RESUME)):
            sys.stderr.write("No conversation found with session ID: %s\n" % RESUME)
            sys.stderr.flush()
            sys.exit(1)
        content = (msg.get("message") or {}).get("content") or []
        said = "".join(b.get("text", "") for b in content if isinstance(b, dict))
        if STORE and LAYOUT:
            # Claude Code stamps each line with its UTC time to the millisecond.
            import datetime
            at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
            with open(stored(SESSION), "a") as f:
                f.write(json.dumps({"type": "user", "sessionId": SESSION, "timestamp": at, "message": {"role": "user", "content": said}}) + "\n")
                f.write(json.dumps({"type": "assistant", "sessionId": SESSION, "timestamp": at, "message": {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}}) + "\n")
            # The model's reply takes time: a turn's prompt is never stored in
            # the millisecond its turn ends.
            import time
            time.sleep(0.02)
        elif STORE:
            open(stored(SESSION), "w").close()
        # "hold: PATH" keeps the turn running until PATH exists.
        if said.startswith("hold: "):
            import time
            while not os.path.exists(said[len("hold: "):]):
                time.sleep(0.02)
        text = json.dumps(sys.argv[1:])
        if said.strip() == "history-probe" and STORE and LAYOUT:
            with open(stored(SESSION)) as f:
                records = [json.loads(line) for line in f if line.strip()]
            text = json.dumps({"prompts": [r["message"]["content"] for r in records
                                           if r.get("type") == "user" and r["message"]["content"] != "history-probe"],
                               "sessions": sorted({r["sessionId"] for r in records})})
        documents = [b for b in content if isinstance(b, dict) and b.get("type") == "document"]
        if said.strip() == "document-probe":
            text = json.dumps({
                "documents": [
                    {
                        "type": b.get("type"),
                        "title": b.get("title"),
                        "media_type": (b.get("source") or {}).get("media_type"),
                        "data": (b.get("source") or {}).get("data"),
                    }
                    for b in documents
                ]
            }, sort_keys=True)
        # "sandbox-probe OUTSIDE PORT": what this process may do, as JSON:
        # write a file at OUTSIDE, connect to 127.0.0.1:PORT, write in its cwd.
        # "keychain-probe": whether this process may query the keychain
        # (`security dump-keychain` lists item metadata when it may).
        if said.strip() == "keychain-probe":
            import subprocess
            rc = subprocess.run(["/usr/bin/security", "dump-keychain"], capture_output=True).returncode
            text = json.dumps({"keychain": "allowed" if rc == 0 else "denied"})
        if said.startswith("sandbox-probe "):
            import os
            import socket
            outside, port = said.split()[1], int(said.split()[2])
            result = {}
            try:
                with open(outside, "w") as f:
                    f.write("x")
                result["outside"] = "allowed"
            except OSError:
                result["outside"] = "denied"
            try:
                socket.create_connection(("127.0.0.1", port), timeout=3).close()
                result["loopback"] = "allowed"
            except OSError:
                result["loopback"] = "denied"
            try:
                with open(os.path.join(os.getcwd(), "sandbox-probe.txt"), "w") as f:
                    f.write("x")
                result["cwd"] = "allowed"
            except OSError:
                result["cwd"] = "denied"
            text = json.dumps(result)
        # "todo-probe": the turn writes its todo list with Claude Code's TodoWrite tool.
        if said.strip() == "todo-probe":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_todo", "name": "TodoWrite",
                  "input": {"todos": [
                      {"content": "Add retry", "status": "completed", "activeForm": "Adding retry"},
                      {"content": "Cover it", "status": "in_progress", "activeForm": "Covering it"},
                      {"content": "Update docs", "status": "pending", "activeForm": "Updating docs"}]}}]}})
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": text}}})
        send({"type": "result", "subtype": "success", "result": text, "num_turns": 1, "duration_api_ms": 1,
              "usage": {"input_tokens": 1, "output_tokens": 1}})
