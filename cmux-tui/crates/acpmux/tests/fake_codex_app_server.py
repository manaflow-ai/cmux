#!/usr/bin/env python3
"""A fake `codex app-server` for live model list tests and the in-process
Codex bridge (`codex_app_server.rs`): JSON-RPC lines without the `jsonrpc`
field. `model/list` answers in two pages; `thread/start` makes one thread and
`turn/start` streams one message ("ok") and completes the turn.
FAKE_CODEX=unauth refuses `model/list` as a signed-out Codex does;
FAKE_CODEX=hang never answers; FAKE_DELAY waits before each answer.
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


def reply(message):
    delay = float(os.environ.get("FAKE_DELAY", "0"))
    if delay:
        time.sleep(delay)
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


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
        reply({"id": rid, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
        reply({"method": "turn/started", "params": {"threadId": thread, "turn": {"id": turn, "status": "inProgress", "items": []}}})
        reply({"method": "item/agentMessage/delta", "params": {"threadId": thread, "turnId": turn, "itemId": "m1", "delta": "ok"}})
        reply({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": turn, "status": "completed", "items": []}}})
    else:
        reply({"id": rid, "error": {"code": -32601, "message": "unknown method"}})
