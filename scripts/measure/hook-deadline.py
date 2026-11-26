#!/usr/bin/env python3
"""How long each agent hook cmux installs takes to answer its agent, against the hook's timeout.

Runs the hook helper (`cmux-tui-hook <agent> <event>`, the binary every installed hook command runs) the way an
agent does: its payload on stdin, `CMUX_TUI_SOCKET` and `CMUX_TUI_TERMINAL_ID` set, stdout read to EOF. Times the
provider-facing process from spawn to exit, per event, against a stand-in daemon in each state:

  answer    answers every request at once (an idle daemon)
  slow      answers every request after 3 s (a daemon busy with other work)
  stall     reads every request and never answers (a wedged daemon)
  down      no socket at all (the daemon stopped or crashed)
  held      no daemon, and the terminal's hook queue file locked by another process (a sender mid-write on a
            stalled disk): the helper's handoff to its detached child cannot finish

at idle and with 2 x cores spinning processes (`load=1`). Prints one line per cell:

  HOOK-DEADLINE <label> <load> <daemon> <agent> <event> n=.. p50=.. p99=.. max=.. timeout=.. over=.. bad=..   (ms)

`over` counts answers that came after the hook's timeout (the agent's "A hook didn't answer in time" notice);
`bad` counts exits that would deny or show an error (non-zero status, or stdout that is not one JSON object where the
event needs one). Usage: hook-deadline.py LABEL=HELPER [LABEL=HELPER ...] [n=40] [load=0,1] [daemons=...] [events=...]
Each label's helper runs in turn inside every cell (alternating order), so both sides see the same load.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time

# (agent, event, timeout seconds as installed, the event's output contract)
#   "object": stdout must be one JSON object (the command shape prints `{}` only when the helper fails)
#   "any": the command shape always echoes `{}` after the helper, so the helper's output is not the answer
EVENTS = [
    ("claude", "UserPromptSubmit", 5, "object"),
    ("claude", "SessionStart", 5, "object"),
    ("claude", "Stop", 5, "any"),
    ("claude", "PreToolUse", 90, "object"),
    ("codex", "Stop", 5, "object"),
    ("codex", "UserPromptSubmit", 5, "object"),
    ("codex", "SessionStart", 5, "object"),
    ("codex", "SessionEnd", 3, "any"),
    ("codex", "PreToolUse", 90, "object"),
    ("gemini", "BeforeTool", 5, "any"),
    ("muse", "PreToolUse", 10, "any"),
]


def hold_queues(helper: str, sock: str, root: str, work: str) -> list:
    """The `held` state: one event queued with no daemon, then every queue file of the session locked."""
    import fcntl
    env = {"PATH": "/usr/bin:/bin", "HOME": root, "TMPDIR": root, "CMUX_TUI_SOCKET": sock,
           "CMUX_TUI_TERMINAL_ID": "term_00000000000000000000000000000009"}
    subprocess.run([helper, "claude", "Stop"], input=payload("claude", "Stop", work), env=env, capture_output=True,
                   timeout=30)
    spool = os.path.join(root, "hook-spool")
    held = []
    for name in sorted(os.listdir(spool)) if os.path.isdir(spool) else []:
        if name.endswith(".jsonl"):
            f = open(os.path.join(spool, name), "r+b")
            fcntl.flock(f, fcntl.LOCK_EX)
            held.append(f)
    return held


def daemon(path: str, mode: str, stop: threading.Event) -> threading.Thread | None:
    if mode in ("down", "held"):
        return None
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(512)
    server.settimeout(0.2)

    def serve(conn: socket.socket) -> None:
        conn.settimeout(None)
        buf = b""
        try:
            while not stop.is_set():
                chunk = conn.recv(65536)
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    try:
                        req = json.loads(line)
                    except ValueError:
                        continue
                    if mode == "stall":
                        continue
                    if mode == "slow":
                        time.sleep(3)
                    op = req.get("operation", "")
                    result = {"value": {}} if op.endswith(".mark") or op.endswith(".append") else []
                    if op in ("session.get", "terminal.get", "tab.get", "pane.get", "screen.get", "workspace.get"):
                        result = {}
                    reply = {"protocol": "cmux.protocol/2", "type": "response", "id": req.get("id"), "ok": True,
                             "result": result}
                    conn.sendall(json.dumps(reply).encode() + b"\n")
        except OSError:
            return
        finally:
            if mode == "stall":
                stop.wait()
            conn.close()

    def accept() -> None:
        while not stop.is_set():
            try:
                conn, _ = server.accept()
            except (TimeoutError, socket.timeout):
                continue
            except OSError:
                return
            threading.Thread(target=serve, args=(conn,), daemon=True).start()
        server.close()

    t = threading.Thread(target=accept, daemon=True)
    t.start()
    return t


def payload(agent: str, event: str, cwd: str) -> bytes:
    body = {"session_id": f"hook-deadline-{agent}", "hook_event_name": event, "cwd": cwd}
    if "Tool" in event:
        body.update({"tool_name": "Bash", "tool_input": {"command": "true"}})
    if event == "UserPromptSubmit":
        body["prompt"] = "hello"
    if event == "SessionStart":
        body["source"] = "startup"
    return json.dumps(body).encode()


def one(helper: str, agent: str, event: str, env: dict, body: bytes, contract: str, cap: float) -> tuple[float, bool]:
    started = time.monotonic()
    try:
        done = subprocess.run([helper, agent, event], input=body, env=env, capture_output=True, timeout=cap)
    except subprocess.TimeoutExpired:
        return (time.monotonic() - started) * 1000, True
    ms = (time.monotonic() - started) * 1000
    bad = done.returncode != 0
    if contract == "object" and not bad:
        try:
            bad = not isinstance(json.loads(done.stdout.decode() or "null"), dict)
        except ValueError:
            bad = True
    return ms, bad


def pct(values: list[float], q: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, int(round(q * (len(ordered) - 1)))))]


def main(argv: list[str]) -> int:
    opts = {"n": "40", "load": "0,1", "daemons": "answer,slow,stall,down,held", "events": ""}
    helpers: list[tuple[str, str]] = []
    for arg in argv:
        key, _, value = arg.partition("=")
        if key in opts:
            opts[key] = value
        elif value:
            helpers.append((key, value))
    if not helpers:
        print(__doc__, file=sys.stderr)
        return 2
    n = int(opts["n"])
    wanted = set(filter(None, opts["events"].split(",")))
    events = [e for e in EVENTS if not wanted or f"{e[0]}:{e[1]}" in wanted]
    cores = os.cpu_count() or 4
    print(f"HOOK-DEADLINE-HOST cores={cores} helpers={','.join(l for l, _ in helpers)} n={n}", flush=True)
    for load in opts["load"].split(","):
        spinners = []
        if load == "1":
            spinners = [subprocess.Popen([sys.executable, "-c", "while True: pass"]) for _ in range(2 * cores)]
            time.sleep(1)
        try:
            for mode in opts["daemons"].split(","):
                root = tempfile.mkdtemp(prefix="hd-", dir="/tmp")
                os.chmod(root, 0o700)
                sock = os.path.join(root, "s.sock")
                work = os.path.join(root, "cwd")
                os.mkdir(work)
                stop = threading.Event()
                daemon(sock, mode, stop)
                held = hold_queues(helpers[0][1], sock, root, work) if mode == "held" else []
                if mode == "held":
                    print(f"HOOK-DEADLINE-HELD {len(held)} queue file(s)", flush=True)
                try:
                    for agent, event, timeout, contract in events:
                        env = {"PATH": "/usr/bin:/bin", "HOME": root, "TMPDIR": root,
                               "CMUX_TUI_SOCKET": sock, "CMUX_TUI_TERMINAL_ID": "term_00000000000000000000000000000009"}
                        if agent == "codex":
                            env["CMUX_TUI_HOOK_ROUTE"] = "launch"
                        body = payload(agent, event, work)
                        samples: dict[str, list[float]] = {label: [] for label, _ in helpers}
                        bad: dict[str, int] = {label: 0 for label, _ in helpers}
                        # Each held run leaves a detached child waiting on the lock until the cell ends.
                        for i in range(min(n, 10) if mode == "held" else n):
                            order = helpers if i % 2 == 0 else list(reversed(helpers))
                            for label, helper in order:
                                ms, wrong = one(helper, agent, event, env, body, contract, timeout + 30)
                                samples[label].append(ms)
                                bad[label] += int(wrong)
                        for label, _ in helpers:
                            s = samples[label]
                            over = sum(1 for v in s if v > timeout * 1000)
                            print(f"HOOK-DEADLINE {label} {load} {mode} {agent} {event} n={len(s)} "
                                  f"p50={statistics.median(s):.1f} p99={pct(s, 0.99):.1f} max={max(s):.1f} "
                                  f"timeout={timeout * 1000} over={over} bad={bad[label]}", flush=True)
                finally:
                    for f in held:
                        f.close()
                    stop.set()
                    time.sleep(0.3)
                    shutil.rmtree(root, ignore_errors=True)
        finally:
            for p in spinners:
                p.kill()
            for p in spinners:
                p.wait()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
