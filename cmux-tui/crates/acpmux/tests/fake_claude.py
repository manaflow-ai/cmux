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
FAKE_CLAUDE_AUTH=1 looks for a sign-in the way Claude Code does (the
environment, then `env` and `apiKeyHelper` in <Claude home>/settings.json,
then <Claude home>/.credentials.json; the home is CLAUDE_CONFIG_DIR or
~/.claude) and replies with what it found as JSON, or fails the turn with
Claude Code's own "Not logged in · Please run /login".
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
    elif kind == "user" and os.environ.get("FAKE_CLAUDE_AUTH") == "1":
        import subprocess
        home = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
        env = dict(os.environ)
        settings = {}
        try:
            with open(os.path.join(home, "settings.json")) as f:
                settings = json.load(f)
        except (OSError, ValueError):
            pass
        for k, v in (settings.get("env") or {}).items():
            env.setdefault(k, str(v))
        found = [k for k in ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN") if env.get(k)]
        if env.get("CLAUDE_CODE_USE_BEDROCK") == "1":
            found.append("bedrock")
        helper = settings.get("apiKeyHelper")
        if helper:
            run = subprocess.run(["/bin/sh", "-c", helper], capture_output=True, text=True)
            if run.returncode == 0 and run.stdout.strip():
                found.append("apiKeyHelper")
        if os.path.isfile(os.path.join(home, ".credentials.json")):
            found.append("credentials")
        if found:
            text = json.dumps({"auth": found, "home": home, "base": env.get("ANTHROPIC_BASE_URL"),
                               "awsProfile": env.get("AWS_PROFILE"), "via": env.get("FAKE_CLAUDE_VIA")})
            send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                     "delta": {"type": "text_delta", "text": text}}})
            send({"type": "result", "subtype": "success", "result": text, "num_turns": 1, "duration_api_ms": 1,
                  "usage": {"input_tokens": 1, "output_tokens": 1}})
        else:
            said = "Not logged in \u00b7 Please run /login"
            send({"type": "assistant", "error": "authentication_failed", "message": {"model": "<synthetic>",
                  "content": [{"type": "text", "text": said}]}})
            send({"type": "result", "subtype": "success", "is_error": True, "result": said, "num_turns": 1,
                  "duration_api_ms": 0, "usage": {"input_tokens": 0, "output_tokens": 0}})
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
        # "usage-probe": the token usage Claude Code streams and the context window its result
        # reports for each model the turn used (the chat's own and a smaller subagent model).
        usage = said.strip() in ("usage-probe", "switched-probe", "compact-probe")
        # "switched-probe": the chat moved to another model mid-session: the main loop's messages
        # name it, and the cumulative modelUsage still holds the earlier, larger model.
        if said.strip() == "switched-probe":
            send({"type": "stream_event", "event": {"type": "message_start", "message": {"model": "claude-sonnet-x"}}})
        if usage:
            send({"type": "stream_event", "event": {"type": "message_delta", "usage": {
                "input_tokens": 1200, "cache_read_input_tokens": 3000, "cache_creation_input_tokens": 0,
                "output_tokens": 300}}})
        # "compact-probe": /compact ran after the turn's message: its context is smaller now.
        if said.strip() == "compact-probe":
            send({"type": "system", "subtype": "compact_boundary",
                  "compact_metadata": {"trigger": "manual", "pre_tokens": 4500}})
        # "bg-probe": the turn starts two shells in the background (Bash run_in_background); Claude
        # Code reports each as a local_bash task, and one is killed while the other finishes.
        if said.strip() == "bg-probe":
            for tid, tool, command, status in (("b1", "toolu_bg1", "npm run dev", "killed"),
                                                ("b2", "toolu_bg2", "cargo test", "completed")):
                send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": tool, "name": "Bash",
                      "input": {"command": command, "run_in_background": True, "description": "Run " + command}}]}})
                send({"type": "system", "subtype": "task_started", "task_id": tid, "tool_use_id": tool,
                      "description": "Run " + command, "task_type": "local_bash"})
            send({"type": "system", "subtype": "task_notification", "task_id": "b1", "tool_use_id": "toolu_bg1",
                  "status": "killed", "reason": "Stopped by the agent", "output_file": "", "summary": ""})
            send({"type": "system", "subtype": "task_notification", "task_id": "b2", "tool_use_id": "toolu_bg2",
                  "status": "completed", "output_file": "", "summary": "Tests passed"})
        # "fg-probe": a foreground Bash is a local_bash task too (not backgrounded), and a
        # notification can name a call acpmux never saw run in the background.
        if said.strip() == "fg-probe":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_fg", "name": "Bash",
                  "input": {"command": "ls", "description": "List files"}}]}})
            send({"type": "system", "subtype": "task_started", "task_id": "f1", "tool_use_id": "toolu_fg",
                  "description": "List files", "task_type": "local_bash", "is_backgrounded": False})
            for tid, tool in (("f1", "toolu_fg"), ("x1", "toolu_unknown")):
                send({"type": "system", "subtype": "task_notification", "task_id": tid, "tool_use_id": tool,
                      "status": "completed", "output_file": "", "summary": ""})
        # "bg-left": a shell starts in the background and is still running when the turn ends.
        if said.strip() == "bg-left":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_left", "name": "Bash",
                  "input": {"command": "npm run dev", "run_in_background": True}}]}})
            # A launch that failed (denied, or a bad input) never ran, so nothing stops at exit.
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_err", "name": "Bash",
                  "input": {"command": "rm -rf build", "run_in_background": True}}]}})
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_err",
                  "is_error": True, "content": "Permission denied"}]}})
        # "bg-moved": a foreground shell moved to the background while it ran (a task_updated
        # patch), then ended; its notification names only the task.
        if said.strip() == "bg-moved":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_mv", "name": "Bash",
                  "input": {"command": "npm run build", "description": "Build"}}]}})
            send({"type": "system", "subtype": "task_started", "task_id": "m1", "tool_use_id": "toolu_mv",
                  "description": "Build", "task_type": "local_bash", "is_backgrounded": False})
            send({"type": "system", "subtype": "task_updated", "task_id": "m1", "patch": {"is_backgrounded": True}})
            send({"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_mv",
                  "content": "Command moved to the background with ID: m1"}]}})
            send({"type": "system", "subtype": "task_notification", "task_id": "m1", "status": "completed",
                  "output_file": "", "summary": "Build finished"})
        # "todo-probe": the turn writes its todo list with Claude Code's TodoWrite tool.
        if said.strip() == "todo-probe":
            send({"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_todo", "name": "TodoWrite",
                  "input": {"todos": [
                      {"content": "Add retry", "status": "completed", "activeForm": "Adding retry"},
                      {"content": "Cover it", "status": "in_progress", "activeForm": "Covering it"},
                      {"content": "Update docs", "status": "pending", "activeForm": "Updating docs"}]}}]}})
        send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                 "delta": {"type": "text_delta", "text": text}}})
        result = {"type": "result", "subtype": "success", "result": text, "num_turns": 1, "duration_api_ms": 1,
                  "usage": {"input_tokens": 1, "output_tokens": 1}}
        if said.strip() in ("usage-probe", "compact-probe"):
            result["modelUsage"] = {"claude-haiku": {"inputTokens": 50, "contextWindow": 100000},
                                    "fake": {"inputTokens": 1200, "contextWindow": 200000}}
        if said.strip() == "switched-probe":
            result["modelUsage"] = {"claude-opus-1m": {"inputTokens": 90000, "contextWindow": 1000000},
                                    "claude-sonnet-x": {"inputTokens": 1200, "contextWindow": 200000}}
        send(result)
