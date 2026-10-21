#!/usr/bin/env python3
"""A stand-in for `claude -p` against an Anthropic-compatible endpoint, for
the doctor's endpoint tests (byo_endpoint_tests.rs).

`--version` prints a version. `-p PROMPT [--model M] --output-format json`
sends one Messages API request to $ANTHROPIC_BASE_URL/v1/messages with
`Authorization: Bearer $ANTHROPIC_AUTH_TOKEN` and prints Claude Code's
result object: the reply text, or `API Error: ...` with is_error true and
exit 1, as Claude Code does. On an HTTP error it also writes the token it
sent to stderr, so a test can prove the doctor masks it. An inherited
ANTHROPIC_API_KEY fails the turn: an endpoint harness must not get one.
"""
import json
import os
import sys
import urllib.error
import urllib.request

args = sys.argv[1:]
if "--version" in args:
    print("9.9.9 (Claude Code stand-in)")
    sys.exit(0)


def arg(name, default=""):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else default


def result(text, error):
    print(json.dumps({"type": "result", "subtype": "success", "is_error": error, "result": text}))
    sys.exit(1 if error else 0)


if os.environ.get("ANTHROPIC_API_KEY"):
    result("ANTHROPIC_API_KEY leaked into the endpoint harness", True)

prompt = arg("-p")
model = arg("--model", os.environ.get("ANTHROPIC_MODEL", ""))
base = os.environ.get("ANTHROPIC_BASE_URL", "https://api.anthropic.com").rstrip("/")
token = os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
body = json.dumps(
    {"model": model, "max_tokens": 64, "messages": [{"role": "user", "content": prompt}]}
).encode()
request = urllib.request.Request(
    base + "/v1/messages",
    data=body,
    headers={
        "content-type": "application/json",
        "authorization": "Bearer " + token,
        "anthropic-version": "2023-06-01",
    },
)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
try:
    with opener.open(request, timeout=20) as response:
        reply = json.load(response)
except urllib.error.HTTPError as e:
    sys.stderr.write("fake claude: sent Authorization: Bearer %s\n" % token)
    result("API Error: %d %s" % (e.code, e.read().decode("utf-8", "replace")), True)
except Exception as e:  # noqa: BLE001 - every transport error is Claude's "Connection error"
    result("API Error: Connection error. (%s)" % e, True)
text = "".join(b.get("text", "") for b in reply.get("content", []) if b.get("type") == "text")
result(text, False)
