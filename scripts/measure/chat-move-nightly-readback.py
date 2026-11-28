#!/usr/bin/env python3
"""Drive a NIGHTLY side copy's own `cmux` CLI through every chat-move direction and time each one.

Leo, 2026-11-25 (ask-af0e3bf355): "cli stuff/agents being able to toggle to and from and whatever
autocloud and such".

chat-move-nightly-readback.sh makes the copy, signs it in and launches it; this starts one chat on the copy
(`cmux chat --on here --cwd FOLDER`), then moves it L->C, C->A, A->L, L->A, A->C, C->L with `cmux chat move
SESSION --on PLACE --json`. A move is timed from the command to the point where the same move answers
`already` with `from` the place asked: the chat's row (`_acpmux/chat_move` reads it before it decides) says
that place, so the read back is the product's own. A move answering `moving` is polled that way until it
lands. Then the chat's own agent is asked to run `cmux chat move --on cloud --json` from its shell (the
agent half: AutoCloud is on in the copy's settings), read back the same way.

Prints CMV PASS/FAIL lines and `CHAT_MOVE_READBACK {json}`; exit 0 all passed, 1 a product failure, 3 rig.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import subprocess
import sys
import time
from pathlib import Path

DIRECTIONS = [("local", "cloud"), ("cloud", "auto"), ("auto", "local"),
              ("local", "auto"), ("auto", "cloud"), ("cloud", "local")]
ARROW = {"local": "L", "cloud": "C", "auto": "A"}
LAND_DEADLINE_S = 600


class Rig(Exception):
    pass


def cli_of(app: Path) -> tuple[str, dict]:
    cli = app / "Contents" / "Resources" / "bin" / "cmux"
    if not cli.is_file():
        raise Rig(f"no bundled CLI at {cli}")
    with open(app / "Contents" / "Info.plist", "rb") as handle:
        info = plistlib.load(handle)
    env = {k: v for k, v in os.environ.items() if k != "CMUX_CI_SIGNIN_FILE"}
    env.update({k: str(v) for k, v in (info.get("LSEnvironment") or {}).items()})
    env["CMUX_BUNDLE_ID"] = info["CFBundleIdentifier"]
    env.pop("ACPMUX_SESSION_ID", None)
    return str(cli), env


def call(cli: str, env: dict, words: list, timeout: float = 660) -> tuple[int, dict, str]:
    try:
        done = subprocess.run([cli, *words], env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, {}, f"timed out after {timeout:.0f}s"
    text = done.stdout.strip()
    try:
        value = json.loads(text) if text else {}
    except ValueError:
        value = {}
    return done.returncode, value if isinstance(value, dict) else {"value": value}, (text or done.stderr.strip())[-2000:]


def payload(answer: dict) -> dict:
    """The answer itself, under a `result`/`data` envelope or not."""
    for key in ("result", "data"):
        if isinstance(answer.get(key), dict) and ("status" in answer[key] or "session_id" in answer[key]):
            return answer[key]
    return answer


def start_chat(cli: str, env: dict, folder: str, out: Path) -> str:
    words = ["chat", "--on", "here", "--cwd", folder, "--name", "chat-move-readback", "--json",
             "--mode", "bypassPermissions", "--prompt", "Reply with only the word ready."]
    deadline = time.monotonic() + 180
    last = ""
    while time.monotonic() < deadline:
        code, answer, text = call(cli, env, words, timeout=120)
        (out / "start.json").write_text(text + "\n")
        body = payload(answer)
        sid = body.get("session_id") or body.get("sessionId") or body.get("id")
        if code == 0 and sid:
            return str(sid)
        last = text
        time.sleep(3)  # the copy's daemon may still be starting
    raise Rig(f"no chat started on the copy: {last[-600:]}")


def read_place(cli: str, env: dict, sid: str, place: str) -> tuple[str, dict]:
    """Ask the move again: `already` with from == place is the row reading that place."""
    code, answer, text = call(cli, env, ["chat", "move", sid, "--on", place, "--json"])
    body = payload(answer)
    return (body.get("status") or f"exit {code}: {text[-300:]}"), body


def move(cli: str, env: dict, sid: str, frm: str, to: str, out: Path, n: int, agent: bool = False) -> dict:
    t0 = time.monotonic()
    if agent:
        code, answer, text = agent_move(cli, env, sid, to, out)
    else:
        code, answer, text = call(cli, env, ["chat", "move", sid, "--on", to, "--json",
                                             "--reason", "chat-move-nightly-readback"])
    answered_ms = round((time.monotonic() - t0) * 1000)
    body = payload(answer)
    (out / f"move-{n}-{frm}-{to}.json").write_text(text + "\n")
    step = {"from": frm, "to": to, "by": "agent" if agent else "person", "answered_ms": answered_ms,
            "status": body.get("status"), "answer_from": body.get("from"), "answer_to": body.get("to"),
            "row": body.get("autoSession"), "exit": code}
    if code != 0 or body.get("status") not in ("moved", "moving", "already"):
        step.update(ok=False, why=(body.get("why") or text)[-600:])
        return step
    polls, status, read = 0, "", {}
    while time.monotonic() - t0 < LAND_DEADLINE_S:
        status, read = read_place(cli, env, sid, to)
        polls += 1
        if status == "already" and read.get("from") == to:
            break
        time.sleep(1.0)
    step.update(landed_ms=round((time.monotonic() - t0) * 1000), polls=polls, read_back=read.get("from"),
                read_status=status)
    step["ok"] = status == "already" and read.get("from") == to
    if not step["ok"]:
        step["why"] = f"read back {status} from={read.get('from')} after {LAND_DEADLINE_S}s"
    return step


def agent_move(cli: str, env: dict, sid: str, to: str, out: Path) -> tuple[int, dict, str]:
    """The chat's own agent runs the move from its shell; its reply carries the JSON it printed."""
    prompt = (f"Run this exact shell command once and reply with only its output, nothing else: "
              f"cmux chat move --on {to} --json")
    code, answer, text = call(cli, env, ["chat", "send", sid, "--wait", "--timeout", "300s", "--json", prompt],
                              timeout=330)
    (out / "agent-send.json").write_text(text + "\n")
    if code == 2:
        return code, {}, f"the agent waits on a permission (or bad arguments): {text}"
    reply = json.dumps(answer) if answer else text
    for blob in _json_objects(reply):
        if blob.get("status") in ("moved", "moving", "already", "needs_person"):
            return 0, blob, json.dumps(blob)
    return 2, {}, f"the agent's reply carried no move answer: {reply[-800:]}"


def _json_objects(text: str):
    """Every JSON object in TEXT, also inside a JSON string (the reply's text)."""
    seen = [text]
    try:
        whole = json.loads(text)
        stack = [whole]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                yield node
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)
            elif isinstance(node, str) and "{" in node:
                seen.append(node)
    except ValueError:
        pass
    decoder = json.JSONDecoder()
    for s in seen:
        i = s.find("{")
        while i != -1:
            try:
                obj, end = decoder.raw_decode(s, i)
                if isinstance(obj, dict):
                    yield obj
                i = s.find("{", end)
            except ValueError:
                i = s.find("{", i + 1)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--folder", required=True)
    parser.add_argument("--dmg", default="")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    app = Path(args.app)
    receipt = {"dmg": args.dmg, "steps": []}
    try:
        with open(app / "Contents" / "Info.plist", "rb") as handle:
            info = plistlib.load(handle)
        receipt.update(build=info.get("CFBundleVersion"), commit=info.get("CMUXCommit"))
        print(f"CMV app build {receipt['build']} commit {receipt['commit']}")
        cli, env = cli_of(app)
        _, ver, vtext = call(cli, env, ["version"], timeout=30)
        print(f"CMV cli {vtext.splitlines()[0] if vtext else '?'}")
        t0 = time.monotonic()
        sid = start_chat(cli, env, args.folder, out)
        receipt["session"] = sid
        receipt["start_ms"] = round((time.monotonic() - t0) * 1000)
        print(f"CMV chat {sid} started here in {receipt['start_ms']} ms")
        status, read = read_place(cli, env, sid, "local")
        if not (status == "already" and read.get("from") == "local"):
            print(f"CMV FAIL start: the new chat does not read local ({status} {json.dumps(read)[:300]})")
            receipt["start_place"] = read
            return finish(receipt, out, 1)
    except Rig as rig:
        print(f"CMV FAIL rig: {rig}")
        return finish(receipt, out, 3)
    failed = False
    for n, (frm, to) in enumerate(DIRECTIONS, 1):
        step = move(cli, env, sid, frm, to, out, n)
        receipt["steps"].append(step)
        label = f"{ARROW[frm]}->{ARROW[to]}"
        if step["ok"]:
            print(f"CMV PASS {label} {step['status']} answered {step['answered_ms']} ms, reads {step['read_back']} "
                  f"at {step['landed_ms']} ms ({step['polls']} reads)")
        else:
            failed = True
            print(f"CMV FAIL {label}: {step.get('why')}")
            break
    if not failed:
        step = move(cli, env, sid, "local", "cloud", out, 7, agent=True)
        receipt["steps"].append(step)
        if step["ok"]:
            print(f"CMV PASS agent L->C {step['status']} answered {step['answered_ms']} ms (agent turn), reads "
                  f"{step['read_back']} at {step['landed_ms']} ms")
            back = move(cli, env, sid, "cloud", "local", out, 8)
            receipt["steps"].append(back)
            print(f"CMV {'PASS' if back['ok'] else 'FAIL'} home C->L {back.get('landed_ms')} ms")
            failed = failed or not back["ok"]
        else:
            failed = True
            print(f"CMV FAIL agent L->C: {step.get('why')}")
    return finish(receipt, out, 1 if failed else 0)


def finish(receipt: dict, out: Path, code: int) -> int:
    receipt["exit"] = code
    (out / "result.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("CHAT_MOVE_READBACK " + json.dumps(receipt, separators=(",", ":")))
    return code


if __name__ == "__main__":
    sys.exit(main())
