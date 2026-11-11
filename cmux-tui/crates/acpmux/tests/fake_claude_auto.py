#!/usr/bin/env python3
"""Claude Code in `auto` mode over its stream-json protocol, for policy tests.

It runs every tool call without asking (no `can_use_tool`), as Claude Code does in `auto`
(its classifier decides) or for a call its settings allow, whatever mode acpmux sets. It still
fires every PreToolUse hook the client registered at `initialize` (a `hook_callback` per
callback id of each matcher that matches), as Claude Code does in every mode, and obeys the
answers: a `deny` blocks the call, an `ask` sends `can_use_tool` and obeys that answer, and
anything else runs the call.

A prompt "auto-tools: <JSON>" runs the calls in the JSON list, each `[tool_name, tool_input]`:
`Bash` runs `command` with `sh -c` in the working directory, `Write` writes `content` to
`file_path`, any other tool does nothing. FAKE_AUTO_LOG=<path> gets one JSON line per call:
`{"tool", "input", "ran", "reason", "hookMs"}` (`hookMs`: each hook callback's id and how long it
took to be answered, `{"callback", "ms"}`). The turn's result text lists the same.

Claude Code's own cross-session messaging, as Claude Code 2.1.322 does it (measured on a fleet
Mac, W7-A 2026-11-10): unless `CLAUDE_CODE_HARBOR_KITE=0`, the session registers itself in the
machine-wide peer registry (FAKE_CLAUDE_PEER_REGISTRY, standing in for `~/.claude/sessions`) under
its `--name`, offers `ListAgents` (every other live registered session, whichever acpmux daemon
started it) and lets `SendMessage` reach a registered peer's inbox (the result says "in that
session's inbox, not yet read"). With `CLAUDE_CODE_HARBOR_KITE=0` it registers nothing, has no
`ListAgents` ("No such tool available") and `SendMessage` reaches only "main" ("No agent named 'X'
is reachable."). FAKE_CLAUDE_IGNORE_SWITCH=1 models a Claude Code that renamed or dropped the
switch: messaging stays on whatever `CLAUDE_CODE_HARBOR_KITE` says. A logged call has its tool
result as `output`.

A prompt "peer-hold: <JSON>" writes Claude Code's `system/peer_message_hold` line with the JSON's
fields (`state`, `message_uuid`, `from`, `from_name`, `cause`, `outcome`, `lane`) and ends the turn.
"""
import atexit
import json
import os
import subprocess
import sys
import time

SESSION = "auto-claude-session"
for flag in ("--session-id", "--resume"):
    if flag in sys.argv[:-1]:
        SESSION = sys.argv[sys.argv.index(flag) + 1]
NAME = SESSION
if "--name" in sys.argv[:-1]:
    NAME = sys.argv[sys.argv.index("--name") + 1]
# Claude Code's cross-session messaging (module docs).
MESSAGING = (
    os.environ.get("FAKE_CLAUDE_IGNORE_SWITCH") == "1"
    or os.environ.get("CLAUDE_CODE_HARBOR_KITE") != "0"
)
REGISTRY = os.environ.get("FAKE_CLAUDE_PEER_REGISTRY")
if MESSAGING and REGISTRY:
    ENTRY = os.path.join(REGISTRY, "%d.json" % os.getpid())
    with open(ENTRY, "w") as f:
        json.dump({"pid": os.getpid(), "name": NAME, "sessionId": SESSION}, f)
    atexit.register(lambda: os.path.exists(ENTRY) and os.remove(ENTRY))


def peers():
    """The other live sessions of the peer registry, by name."""
    names = []
    for entry in sorted(os.listdir(REGISTRY)) if REGISTRY and os.path.isdir(REGISTRY) else []:
        try:
            with open(os.path.join(REGISTRY, entry)) as f:
                record = json.load(f)
            if record["pid"] == os.getpid():
                continue
            os.kill(record["pid"], 0)
        except (OSError, ValueError, KeyError):
            continue
        names.append(record["name"])
    return names
MODE = "auto"
if "--permission-mode" in sys.argv[:-1]:
    MODE = sys.argv[sys.argv.index("--permission-mode") + 1]
# PreToolUse matchers registered at initialize: [(matcher, [callback ids])].
PRE_TOOL = []
NEXT = [0]


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def init():
    return {"type": "system", "subtype": "init", "session_id": SESSION, "model": "fake",
            "permissionMode": MODE, "tools": [], "mcp_servers": []}


def answer_control(msg):
    """Answers one of the client's control requests as Claude Code does."""
    global MODE
    request = msg.get("request") or {}
    sub = request.get("subtype")
    if sub == "initialize":
        hooks = (request.get("hooks") or {}).get("PreToolUse") or []
        PRE_TOOL.extend((h.get("matcher") or "*", list(h.get("hookCallbackIds") or [])) for h in hooks)
    if sub == "set_permission_mode" and isinstance(request.get("mode"), str):
        MODE = request["mode"]
    response = {"commands": [], "models": [], "account": {}} if sub == "initialize" else {}
    send({"type": "control_response", "response": {"subtype": "success",
          "request_id": msg.get("request_id"), "response": response}})
    if sub == "initialize":
        send(init())


def wait_for(rid):
    """The answer to this process's control request `rid`; other lines are handled meanwhile."""
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("type") == "control_response":
            response = msg.get("response") or {}
            if response.get("request_id") == rid:
                return response
            continue
        if msg.get("type") == "control_request":
            answer_control(msg)
    sys.exit(0)


def request(body):
    NEXT[0] += 1
    rid = "auto-%d" % NEXT[0]
    send({"type": "control_request", "request_id": rid, "request": body})
    return wait_for(rid)


def matches(matcher, tool):
    return matcher in ("*", "") or tool in matcher.split("|")


# Each hook callback's id and milliseconds to its answer, for the last call judged.
GATE_MS = []


def judge(tool, tool_input, use_id, cwd):
    """What the registered PreToolUse hooks decide for one call: (runs, reason)."""
    decisions = []
    del GATE_MS[:]
    for matcher, ids in PRE_TOOL:
        if not matches(matcher, tool):
            continue
        for callback in ids:
            hook_input = {"session_id": SESSION, "cwd": cwd, "permission_mode": MODE,
                          "hook_event_name": "PreToolUse", "tool_name": tool,
                          "tool_input": tool_input, "tool_use_id": use_id}
            started = time.monotonic()
            response = request({"subtype": "hook_callback", "callback_id": callback,
                                "input": hook_input, "tool_use_id": use_id})
            GATE_MS.append({"callback": callback,
                            "ms": round((time.monotonic() - started) * 1000, 3)})
            if response.get("subtype") != "success":
                decisions.append(("deny", "hook failed: %s" % response.get("error")))
                continue
            out = (response.get("response") or {}).get("hookSpecificOutput") or {}
            decision = out.get("permissionDecision")
            if decision:
                decisions.append((decision, out.get("permissionDecisionReason") or ""))
    for decision, reason in decisions:
        if decision == "deny":
            return False, reason
    if any(d == "ask" for d, _ in decisions):
        response = request({"subtype": "can_use_tool", "tool_name": tool, "input": tool_input,
                            "tool_use_id": use_id})
        answer = response.get("response") or {}
        if answer.get("behavior") != "allow":
            return False, answer.get("message") or "denied when asked"
        return True, "allowed when asked"
    return True, ""


def native_message(tool, tool_input):
    """Claude Code's own result for ListAgents or SendMessage (module docs)."""
    if tool == "ListAgents":
        return "This session is %s.\n\nPeer sessions (%d):\n%s" % (
            NAME, len(peers()), "\n".join("  " + p for p in peers()))
    to = tool_input.get("to", "")
    if to == "main" or (MESSAGING and to in peers()):
        return json.dumps({"success": True, "message": "%s (another Claude session on this machine; "
                           "in that session's inbox, not yet read by its Claude)" % to})
    return json.dumps({"success": False, "message": "No agent named '%s' is reachable." % to})


def run(tool, tool_input, cwd):
    if tool in ("ListAgents", "SendMessage"):
        return native_message(tool, tool_input)
    if tool == "Bash":
        subprocess.run(["sh", "-c", tool_input.get("command", "")], cwd=cwd, stdin=subprocess.DEVNULL,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    elif tool == "Write":
        with open(tool_input["file_path"], "w") as f:
            f.write(tool_input.get("content", ""))


def turn(text):
    cwd = os.getcwd()
    lines = []
    if text.startswith("auto-tools: "):
        for i, (tool, tool_input) in enumerate(json.loads(text[len("auto-tools: "):])):
            output = None
            if tool == "ListAgents" and not MESSAGING:
                # No such tool in this session: the model cannot call it, so no hook fires.
                runs, reason = False, "No such tool available: ListAgents"
                del GATE_MS[:]
            else:
                runs, reason = judge(tool, tool_input, "toolu_auto_%d" % i, cwd)
            if runs:
                output = run(tool, tool_input, cwd)
            record = {"tool": tool, "input": tool_input, "ran": runs, "reason": reason,
                      "output": output, "hookMs": list(GATE_MS)}
            lines.append(json.dumps(record))
            if os.environ.get("FAKE_AUTO_LOG"):
                with open(os.environ["FAKE_AUTO_LOG"], "a") as f:
                    f.write(json.dumps(record) + "\n")
    if text.startswith("peer-hold: "):
        hold = {"type": "system", "subtype": "peer_message_hold", "lane": "socket",
                "uuid": "hold-%d" % time.monotonic_ns(), "session_id": SESSION}
        hold.update(json.loads(text[len("peer-hold: "):]))
        send(hold)
    said = "\n".join(lines) or "ok"
    send({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
          "delta": {"type": "text_delta", "text": said}}, "session_id": SESSION})
    send({"type": "result", "subtype": "success", "result": said, "num_turns": 1,
          "duration_api_ms": 1, "session_id": SESSION,
          "usage": {"input_tokens": 1, "output_tokens": 1}})


for line in sys.stdin:
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    kind = msg.get("type")
    if kind == "control_request":
        answer_control(msg)
    elif kind == "user":
        content = (msg.get("message") or {}).get("content")
        if isinstance(content, str):
            text = content
        else:
            text = "".join(b.get("text", "") for b in content or [] if isinstance(b, dict)
                           and b.get("text", "").startswith(("auto-tools: ", "peer-hold: ")))
        turn(text.strip())
