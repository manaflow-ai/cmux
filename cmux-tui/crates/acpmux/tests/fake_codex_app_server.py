#!/usr/bin/env python3
"""A fake `codex app-server` for live model list tests: JSON-RPC lines
without the `jsonrpc` field. `model/list` answers in two pages.
FAKE_CODEX=unauth refuses `model/list` as a signed-out Codex does;
FAKE_CODEX=hang never answers; FAKE_DELAY waits before each answer.
"""
import json
import os
import sys
import time

if len(sys.argv) < 2 or sys.argv[1] != "app-server":
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
    else:
        reply({"id": rid, "error": {"code": -32601, "message": "unknown method"}})
