#!/usr/bin/env python3
"""A Cloud chat end to end from a tagged DEV app, signed in as the agent test account.

Run by .github/workflows/cloud-chat-proof.yml after `scripts/reload.sh --tag TAG --launch
--auth-profile agent --credentials-file FILE`. A tagged Debug build signs in on the staging Stack
project and mints VM keys at vm-staging.cmux.dev (CloudConfiguration.resolve,
AppControl+VMAgentKey.vmBaseURL). Through the tagged app's own CLI and socket:

1. waits until the app is signed in (`cloud list-machines` answers),
2. `vm token create --ttl 30m` (the key goes to the login Keychain; it is never printed),
3. `cloud start-chat --prompt ... --wait`: a new machine, a chat on it, the prompt, the reply,
4. kills the machine the chat made.

Each step's exit code and the CLI's own message go to the evidence JSON and the job summary, with
the reply text. Nothing here reads the credentials file; the app does.
"""
import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="the tagged app bundle")
parser.add_argument("--tag", required=True)
parser.add_argument("--prompt", required=True)
parser.add_argument("--agent", default="claude")
parser.add_argument("--evidence", required=True)
args = parser.parse_args()

CLI = str(Path(args.app) / "Contents/Resources/bin/cmux")
ENV = {**os.environ, "CMUX_SOCKET_PATH": f"/tmp/cmux-debug-{args.tag}.sock"}
# Strings that may never reach the evidence or the log, whatever a CLI answer holds.
SECRET_MARKERS = ("cmvm_", "cmk_", "eyJ", "Bearer ", "apiKey", '"key"')
evidence = {"tag": args.tag, "agent": args.agent, "prompt": args.prompt, "steps": []}


def clean(text: str, limit: int = 2000) -> str:
    text = (text or "").strip()
    if any(marker in text for marker in SECRET_MARKERS):
        return "[withheld: the answer held a secret-shaped value]"
    return text[:limit]


def cmux(*words: str, timeout: int = 120) -> tuple[int, str, str]:
    try:
        done = subprocess.run([CLI, *words], env=ENV, capture_output=True, text=True, timeout=timeout)
        return done.returncode, done.stdout, done.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"


def record(name: str, code: int, out: str, err: str, **extra) -> dict:
    step = {"step": name, "exit": code, "stdout": clean(out), "stderr": clean(err), **extra}
    evidence["steps"].append(step)
    print(f"[{'ok' if code == 0 else 'FAIL'}] {name}: exit {code}", flush=True)
    for label, text in (("stdout", step["stdout"]), ("stderr", step["stderr"])):
        if text:
            print(f"  {label}: {text}", flush=True)
    return step


def finish(result: str) -> None:
    evidence["result"] = result
    Path(args.evidence).parent.mkdir(parents=True, exist_ok=True)
    Path(args.evidence).write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    sys.exit(0 if result == "pass" else 1)


def parsed(text: str) -> dict:
    try:
        value = json.loads(text) if text.strip() else {}
    except json.JSONDecodeError:
        return {}
    value = value.get("result", value) if isinstance(value, dict) else {}
    return value if isinstance(value, dict) else {}


def listed() -> tuple[int, str, str, dict]:
    code, out, err = cmux("cloud", "list-machines", "--json", timeout=60)
    return code, out, err, parsed(out) if code == 0 else {}


# 1. Signed in: the auto sign-in runs at launch. list-machines answers while signed out too
# (account.signed_in false), so the wait reads that field, not the exit code.
deadline = time.monotonic() + 240
while True:  # bounded wait on the app's sign-in, not app code
    code, out, err, machines = listed()
    signed_in = (machines.get("account") or {}).get("signed_in") is True
    if signed_in or time.monotonic() > deadline:
        break
    time.sleep(5)
record("signed in (cloud list-machines)", 0 if signed_in else (code or 1), "" if signed_in else out, err,
       signed_in=signed_in)
if not signed_in:
    finish("fail: the app never signed in (cloud list-machines: account.signed_in is not true)")

# 2. A VM agent key at this build's issuer (vm-staging.cmux.dev for a tagged Debug build).
code, out, err = cmux("vm", "token", "create", "--ttl", "30m", "--json", timeout=60)
record("vm token create", code, out, err)
if code != 0:
    finish("fail: vm token create")

# 3. The Cloud chat: start, send, wait for the turn, read the reply. The machine is named after the
# run, so a start still pending (exit 75: creation goes on in the app) is asked again with the same
# name, and the machine can be found for cleanup by that name when no answer named its id.
chat_deadline = time.monotonic() + 1200
while True:  # bounded: the same start-chat again while its machine is still being made
    code, out, err = cmux("cloud", "start-chat", "--prompt", args.prompt, "--agent", args.agent,
                          "--name", args.tag, "--wait", "--timeout", "900", "--json", timeout=1200)
    if code != 75 or time.monotonic() > chat_deadline:
        break
    record("cloud start-chat (machine still starting)", code, "", err)
    time.sleep(10)
answer = parsed(out) if code == 0 else {}
reply = answer.get("reply")
record("cloud start-chat", code, out, err, reply=clean(reply or "", 8000) or None)
# A failed chat answers on stderr: the machine it made is at details.machine_id (chat.turn_failed)
# or details.answer.machine_id (the other failures).
failure = parsed(err).get("details") or {}
machine = answer.get("machine_id") or failure.get("machine_id") or (failure.get("answer") or {}).get("machine_id")
if not machine:
    for row in listed()[3].get("machines") or []:
        if isinstance(row, dict) and row.get("title") == args.tag and row.get("machine_id"):
            machine = row["machine_id"]

# 4. The machine the chat made goes, pass or fail (a destructive verb needs --confirm from a script).
killed = True
if machine:
    code_k, out_k, err_k = cmux("cloud", "kill-machine", "--target", f"machine:{machine}", "--confirm", "--json",
                                timeout=120)
    record("cloud kill-machine", code_k, out_k, err_k)
    killed = code_k == 0

if not (code == 0 and reply):
    finish("fail: cloud start-chat gave no reply")
finish("pass" if killed else "fail: the chat replied but its machine was not killed")
