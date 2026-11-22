#!/usr/bin/env python3
"""Prototype feed adapter for Claude Code (plans/cmux-next/feed.md 8).

The shipping adapter is `cmux feed hook <harness>` in the Rust CLI; this
script is its stand-in for dogfood until that verb exists. It talks only to
the cmux app's control socket (`$CMUX_SOCKET_PATH`); the app posts to the
user's feed as the signed-in user. It never blocks the agent: no socket, an
error, a timeout or a cancel print the native "no decision" output (`{}`), so
Claude Code shows its own prompt.

  feed-hook.py claude-code request    PermissionRequest hook (synchronous); also PreToolUse
                                      for print mode, which shows no dialog
  feed-hook.py claude-code supersede  PreToolUse, PostToolUse, PostToolUseFailure,
                                      UserPromptSubmit, Stop, SessionEnd hooks:
                                      cancels open items of the session
                                      (answered in the terminal)
"""
import hashlib
import json
import os
import socket
import sys
import time

WAIT_SECONDS = int(os.environ.get("CMUX_FEED_HOOK_WAIT", "115"))
STATE_DIR = os.path.join(os.environ.get("TMPDIR", "/tmp"), "cmux-feed-hook")


def call(method, params, timeout):
    path = os.environ.get("CMUX_SOCKET_PATH")
    if not path:
        return None
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
        s.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        reply = json.loads(buf.split(b"\n", 1)[0] or b"{}")
    except (OSError, ValueError):
        return None
    finally:
        s.close()
    return reply.get("result") if reply.get("ok", "result" in reply) else None


def canonical(v):
    return json.dumps(v, sort_keys=True, separators=(",", ":"))


def post_for(event):
    """Maps a PermissionRequest to feed.post params (feed.md 8.2)."""
    tool = event.get("tool_name", "")
    tin = event.get("tool_input") or {}
    session = event.get("session_id", "")
    key = "claude-code:%s:%s" % (session, hashlib.sha256((tool + canonical(tin)).encode()).hexdigest()[:24])
    base = {
        "type": "request",
        "dedupe_key": key,
        "thread": "claude-code:%s" % session,
        "poster": {"kind": "harness", "harness": "Claude Code", "label": os.path.basename(event.get("cwd") or "")[:80],
                   "agent": os.environ.get("CMUX_TUI_TERMINAL_ID") or "claude-code:%s" % session},
        "expires_in_ms": (WAIT_SECONDS + 60) * 1000,
    }
    if os.environ.get("CMUX_TUI_TERMINAL_ID"):
        base["context"] = {"terminal": os.environ["CMUX_TUI_TERMINAL_ID"]}
    if tool == "AskUserQuestion":
        qs = tin.get("questions") or []
        questions = [{"id": "q%d" % i, "question": q.get("question", "")[:1000], "header": (q.get("header") or "")[:40],
                      "options": [{"id": "o%d" % j, "label": o.get("label", "")[:200], "description": (o.get("description") or "")[:1000]}
                                  for j, o in enumerate(q.get("options") or [])][:8],
                      "multi": bool(q.get("multiSelect")), "allow_other": True} for i, q in enumerate(qs[:4])]
        return dict(base, kind="choice", title=(qs[0].get("question") if qs else "Claude Code has a question")[:200],
                    prompt={"questions": questions})
    if tool == "ExitPlanMode":
        return dict(base, kind="review", title="Review Claude Code's plan", body=(tin.get("plan") or "")[:4096],
                    prompt={"subject": "plan", "ref": (tin.get("planFilePath") or "plan")[:2048]})
    if tool == "Bash":
        action = {"type": "command", "summary": (tin.get("description") or "Run a command")[:500], "command": (tin.get("command") or "")[:8000],
                  "cwd": (event.get("cwd") or "")[:1000], "tool": tool}
        title = ("Run %s?" % (tin.get("command") or "a command").splitlines()[0])[:200]
    elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        action = {"type": "edit", "summary": ("%s %s" % (tool, tin.get("file_path") or ""))[:500], "tool": tool}
        title = ("%s %s?" % (tool, os.path.basename(tin.get("file_path") or "a file")))[:200]
    else:
        action = {"type": "tool", "summary": ("Use %s" % tool)[:500], "tool": tool[:200]}
        title = ("Allow %s?" % tool)[:200]
    scopes = ["once", "session"] if event.get("permission_suggestions") else ["once"]
    return dict(base, kind="approve", title=title, prompt={"action": action, "scopes": scopes})


def decision_for(event, item):
    """The owner's answer as Claude Code's PermissionRequest decision, or None for no decision."""
    if not item or item.get("state") != "answered":
        return None
    value = (item.get("answer") or {}).get("value") or {}
    tool = event.get("tool_name", "")
    if item.get("kind") == "choice":
        qs = (event.get("tool_input") or {}).get("questions") or []
        answers = {}
        for i, q in enumerate(qs[:4]):
            a = (value.get("answers") or {}).get("q%d" % i) or {}
            labels = [(q.get("options") or [])[int(o[1:])].get("label", "") for o in a.get("selected", []) if o[1:].isdigit()]
            if a.get("other"):
                labels.append(a["other"])
            answers[q.get("question", "")] = ", ".join(labels)
        return {"behavior": "allow", "updatedInput": dict(event.get("tool_input") or {}, answers=answers)}
    if item.get("kind") == "review":
        if value.get("verdict") == "approve":
            return {"behavior": "allow"}
        return {"behavior": "deny", "message": value.get("comment") or "The plan was not approved."}
    if value.get("decision") == "allow":
        d = {"behavior": "allow"}
        if value.get("scope") in ("session", "always") and event.get("permission_suggestions"):
            d["updatedPermissions"] = event["permission_suggestions"]
        return d
    return {"behavior": "deny", "message": value.get("reason") or "Denied in the cmux feed."}


def state_path(session):
    return os.path.join(STATE_DIR, hashlib.sha256(session.encode()).hexdigest()[:32] + ".json")


def remember(session, item_id, add):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    path = state_path(session)
    try:
        ids = set(json.load(open(path)))
    except (OSError, ValueError):
        ids = set()
    ids = (ids | {item_id}) if add else (ids - {item_id})
    with open(path, "w") as f:
        json.dump(sorted(ids), f)


def request(event):
    post = post_for(event)
    key = "req:" + post["dedupe_key"] + ":" + str(int(time.time() * 1000))
    result = call("feed.request", {"post": post, "idempotency_key": key, "wait_seconds": WAIT_SECONDS}, WAIT_SECONDS + 20)
    if not result:
        return {}
    item = result.get("item") or {}
    if item.get("state") == "open":
        remember(event.get("session_id", ""), item.get("id", ""), True)
        return {}
    decision = decision_for(event, item)
    if not decision:
        return {}
    if event.get("hook_event_name") == "PreToolUse":
        # Print mode (`claude -p`) shows no dialog, so the adapter can also sit on PreToolUse.
        out = {"hookEventName": "PreToolUse", "permissionDecision": decision["behavior"]}
        if decision.get("message"):
            out["permissionDecisionReason"] = decision["message"]
        if decision.get("updatedInput"):
            out["updatedInput"] = decision["updatedInput"]
        return {"hookSpecificOutput": out}
    return {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}


def supersede(event):
    """A later event of the session means the terminal prompt was answered: withdraw the open items."""
    name = event.get("hook_event_name", "")
    if name == "PreToolUse" and event.get("tool_name") in ("AskUserQuestion", "ExitPlanMode"):
        return {}
    session = event.get("session_id", "")
    try:
        ids = json.load(open(state_path(session)))
    except (OSError, ValueError):
        return {}
    for item_id in ids:
        call("feed.cancel", {"item": item_id, "reason": "answered_elsewhere"}, 5)
        remember(session, item_id, False)
    return {}


def main():
    if len(sys.argv) < 3 or sys.argv[1] != "claude-code" or sys.argv[2] not in ("request", "supersede"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        event = json.load(sys.stdin)
        out = request(event) if sys.argv[2] == "request" else supersede(event)
    except Exception:  # noqa: BLE001 - an adapter error must never block the agent
        out = {}
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
