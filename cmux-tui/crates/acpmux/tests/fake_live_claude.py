#!/usr/bin/env python3
"""A fake `claude -p` in stream-json mode for live model list tests.

It answers the SDK's `initialize` and `list_models` control requests.
FAKE_LIST=refuse refuses `list_models` (an older Claude Code); FAKE_DELAY
waits that many seconds before each answer.
"""
import json
import os
import sys
import time

INIT_MODELS = [{"value": "opus", "displayName": "Opus"}]
LISTED = [
    {"value": "default", "displayName": "Default"},
    {
        "value": "opus",
        "displayName": "Opus",
        "description": "Opus 5.5 · Most capable",
        "resolvedModel": "claude-opus-5-5",
        "supportedEffortLevels": ["low", "medium", "high", "xhigh", "max"],
        "supportsFastMode": True,
    },
    {
        "value": "sonnet[1m]",
        "displayName": "Sonnet (1M context)",
        "resolvedModel": "claude-sonnet-5-5[1m]",
        "supportsEffort": True,
    },
    {"value": "haiku-4-5", "displayName": "Haiku 4.5", "disabled": True},
    {"value": "opus-5", "displayName": "Opus 5", "supportsFastMode": False},
    {"value": "cc-update-required-2", "displayName": "Update Claude Code"},
]


def say(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def answer(request_id, response=None, error=None):
    delay = float(os.environ.get("FAKE_DELAY", "0"))
    if delay:
        time.sleep(delay)
    inner = {"subtype": "error", "request_id": request_id, "error": error} if error else {
        "subtype": "success",
        "request_id": request_id,
        "response": response,
    }
    say({"type": "control_response", "response": inner})


sys.stdout.write("not json: a banner line\n")
for line in sys.stdin:
    try:
        message = json.loads(line)
    except ValueError:
        continue
    if message.get("type") != "control_request":
        continue
    request_id = message.get("request_id")
    subtype = message.get("request", {}).get("subtype")
    if subtype == "initialize":
        say({"type": "system", "subtype": "init"})
        answer(request_id, {"commands": [], "models": INIT_MODELS})
    elif subtype == "list_models":
        if os.environ.get("FAKE_LIST") == "refuse":
            answer(request_id, error="Unknown control request subtype: list_models")
        else:
            answer(request_id, {"models": LISTED})
