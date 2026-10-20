#!/usr/bin/env python3
"""A fake `codex app-server` for live model list tests and the in-process
Codex bridge (`codex_app_server.rs`): JSON-RPC lines without the `jsonrpc`
field. `model/list` answers in two pages; `thread/start` makes one thread and
`turn/start` streams one message ("ok") and completes the turn.
FAKE_CODEX=unauth refuses `model/list` as a signed-out Codex does;
FAKE_CODEX=hang never answers; FAKE_DELAY waits before each answer.
A prompt with "until-interrupt" streams "working" and completes its turn
(interrupted) only on `turn/interrupt`. "long-tool" starts a command that runs
for 30 s; `turn/steer` into it is accepted at once and answered "read: <text>"
in order (Codex takes steered input at once), and the turn completes after the
command.

Background terminals (unified exec): a prompt with "bg-codex" runs `npm run
dev` (process 1001), whose item is still open when the turn completes, `ls`
(1002), which completes in the turn, and `cargo watch` (1003), whose item
completes while its process still runs. "bg-codex-exit" then ends 1003 with
exit code 1. `thread/backgroundTerminals/terminate` stops a running one and
completes its item. A prompt with "codex-die" exits the app-server.
"bg-codex-sub" starts a subagent thread (fake-sub-1) whose `npm run watch`
(2001) runs in the background. "bg-codex-gone": Codex forgets 1001, so its
terminate answers `terminated: false`. "bg-codex-interrupt" leaves `sleep 60`
(3001) open when the turn is interrupted. FAKE_CODEX_END_FIRST=1 completes a
terminated item before answering the terminate.
"""
import json
import os
import sys
import time

# Global options (`-c key=value`, `--config key=value`) come before the subcommand, as codex
# takes them. FAKE_CODEX_ARGS=<path> gets a line with the arguments of each start.
if os.environ.get("FAKE_CODEX_ARGS"):
    with open(os.environ["FAKE_CODEX_ARGS"], "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\n")
args = sys.argv[1:]
while len(args) >= 2 and args[0] in ("-c", "--config"):
    args = args[2:]
if not args or args[0] != "app-server":
    sys.stderr.write("usage: codex app-server\n")
    sys.exit(2)

PAGES = {
    None: (
        [
            {
                "model": "gpt-6-astra",
                "displayName": "gpt-6-astra",
                "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "medium"}],
                "defaultReasoningEffort": "medium",
                "serviceTiers": [{"id": "default"}, {"id": "fast"}],
            },
            {"model": "gpt-secret", "displayName": "Secret", "hidden": True},
        ],
        "p2",
    ),
    "p2": (
        [
            {
                "model": "gpt-6.1-sol",
                "displayName": "GPT-6.1-Sol",
                "isDefault": True,
                "supportedReasoningEfforts": ["low", "high"],
                "serviceTiers": ["default"],
            }
        ],
        None,
    ),
}

mode = os.environ.get("FAKE_CODEX", "")


# processId -> the open item of each background terminal still running.
running = {}


def exec_item(item_id, command, process_id, cwd, status="inProgress", exit_code=None):
    return {
        "type": "commandExecution",
        "id": item_id,
        "command": command,
        "cwd": cwd,
        "processId": process_id,
        "source": "unifiedExecStartup",
        "status": status,
        "commandActions": [],
        "aggregatedOutput": None,
        "exitCode": exit_code,
        "durationMs": None,
    }


def item_event(kind, thread, turn, item):
    reply({"method": "item/" + kind, "params": {"threadId": thread, "turnId": turn, "item": item}})


def background_turn(thread, turn, cwd, text):
    if "bg-codex-sub" in text:
        sub = "fake-sub-1"
        reply({"method": "thread/started", "params": {"thread": {"id": sub, "parentThreadId": thread, "agentNickname": "helper"}}})
        watch = exec_item("call_sub", "npm run watch", "2001", cwd)
        item_event("started", sub, turn, watch)
        item_event("completed", sub, turn, watch)
        running["2001"] = (sub, turn, watch)
        return
    if "bg-codex-interrupt" in text:
        item_event("started", thread, turn, exec_item("call_sleep", "sleep 60", "3001", cwd))
        return
    dev = exec_item("call_dev", "npm run dev", "1001", cwd)
    item_event("started", thread, turn, dev)
    if "bg-codex-gone" not in text:
        running["1001"] = (thread, turn, dev)
    ls = exec_item("call_ls", "ls", "1002", cwd)
    item_event("started", thread, turn, ls)
    item_event("completed", thread, turn, dict(ls, status="completed", exitCode=0))
    watch = exec_item("call_watch", "cargo watch", "1003", cwd)
    item_event("started", thread, turn, watch)
    item_event("completed", thread, turn, watch)
    if "bg-codex-exit" in text:
        item_event("completed", thread, turn, dict(watch, status="failed", exitCode=1))
    else:
        running["1003"] = (thread, turn, watch)


def reply(message):
    delay = float(os.environ.get("FAKE_DELAY", "0"))
    if delay:
        time.sleep(delay)
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


# Turns "until-interrupt" left open: turn id -> thread id.
open_turns = {}

for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if "id" not in message or mode == "hang":
        continue
    method, rid = message.get("method"), message["id"]
    if method == "initialize":
        reply({"method": "codex/event", "params": {"note": "a notification first"}})
        reply({"id": rid, "result": {"userAgent": "fake"}})
    elif method == "model/list":
        if mode == "unauth":
            reply({"id": rid, "error": {"code": -32000, "message": "Not logged in. Run `codex login`."}})
            continue
        data, cursor = PAGES[message.get("params", {}).get("cursor")]
        reply({"id": rid, "result": {"data": data, "nextCursor": cursor}})
    elif method == "thread/start":
        thread = {"id": "fake-thread-1", "cwd": message.get("params", {}).get("cwd"), "turns": []}
        reply({"id": rid, "result": {"thread": thread, "model": "gpt-6.1-sol", "reasoningEffort": None}})
    elif method == "turn/start":
        params = message.get("params", {})
        thread, turn = params.get("threadId"), "fake-turn-%s" % rid
        text = " ".join(i.get("text") or "" for i in params.get("input") or [] if isinstance(i, dict))
        if "codex-die" in text:
            sys.exit(1)
        reply({"id": rid, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
        reply({"method": "turn/started", "params": {"threadId": thread, "turn": {"id": turn, "status": "inProgress", "items": []}}})
        if "long-tool" in text:
            reply({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": turn, "itemId": "m1", "delta": "running a long tool\n"}})
            item_event("started", thread, turn, exec_item("call_long", "sleep 30", "4001", os.getcwd()))
            open_turns[turn] = thread
            continue
        if "until-interrupt" in text:
            reply({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": turn, "itemId": "m1", "delta": "working"}})
            open_turns[turn] = thread
            continue
        if "bg-codex" in text:
            background_turn(thread, turn, os.getcwd(), text)
        reply({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": turn, "itemId": "m1", "delta": "ok"}})
        status = "interrupted" if "bg-codex-interrupt" in text else "completed"
        reply({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": turn, "status": status, "items": []}}})
    elif method == "turn/steer":
        params = message.get("params", {})
        turn = params.get("expectedTurnId")
        thread = params.get("threadId")
        if turn not in open_turns:
            reply({"id": rid, "error": {"code": -32600, "message": "no active turn"}})
            continue
        reply({"id": rid, "result": {"turnId": turn}})
        said = " ".join(i.get("text") or "" for i in params.get("input") or [] if isinstance(i, dict))
        reply({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": turn, "itemId": "m-steer", "delta": "read: " + said + "\n"}})
    elif method == "turn/interrupt" and message.get("params", {}).get("turnId") in open_turns:
        # Only a turn this fake left open ends here; any other interrupt gets the unknown-method
        # answer it always got (a turn that already completed must not complete twice).
        turn = message["params"]["turnId"]
        thread = open_turns.pop(turn)
        reply({"id": rid, "result": {}})
        reply({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": turn, "status": "interrupted", "items": []}}})
    elif method == "thread/backgroundTerminals/terminate":
        params = message.get("params", {})
        found = running.pop(params.get("processId"), None)
        end_first = os.environ.get("FAKE_CODEX_END_FIRST") == "1"
        if found and end_first:
            thread, turn, item = found
            item_event("completed", thread, turn, dict(item, status="failed", exitCode=143))
        reply({"id": rid, "result": {"terminated": found is not None}})
        if found and not end_first:
            thread, turn, item = found
            item_event("completed", thread, turn, dict(item, status="failed"))
    else:
        reply({"id": rid, "error": {"code": -32601, "message": "unknown method"}})
