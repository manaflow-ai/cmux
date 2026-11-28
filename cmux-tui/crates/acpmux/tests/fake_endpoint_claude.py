#!/usr/bin/env python3
"""A stand-in for `claude -p` against an Anthropic-compatible endpoint, for
the doctor's endpoint tests (byo_endpoint_tests.rs).

`--version` prints a version. `-p --input-format stream-json --output-format
stream-json [--model M]` reads one user message from stdin, sends one Messages
API request to $ANTHROPIC_BASE_URL/v1/messages with `Authorization: Bearer
$ANTHROPIC_AUTH_TOKEN` and prints an init line and Claude Code's result line:
the reply text, or `API Error: ...` with is_error true and exit 1, as Claude
Code does. Any other headless shape is refused as `sr2 claude2` refuses it
(cmux#57823), so a doctor that drifts from a session's shape fails here. On an HTTP error it also writes the token it
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


def stream_json():
    return arg("--input-format") == "stream-json" and arg("--output-format") == "stream-json"


if not stream_json():
    sys.stderr.write("fake claude: runs headless only with -p --input-format stream-json\n")
    sys.exit(1)
print(json.dumps({"type": "system", "subtype": "init", "tools": ["Bash", "Read"]}))

if os.environ.get("ANTHROPIC_API_KEY"):
    result("ANTHROPIC_API_KEY leaked into the endpoint harness", True)

prompt = ""
for line in sys.stdin:
    line = line.strip()
    if line:
        content = json.loads(line)["message"]["content"]
        prompt = content if isinstance(content, str) else "".join(b.get("text", "") for b in content)
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
