#!/usr/bin/env python3
"""A fake Claude Code running in a terminal, for the terminal-driven chat tests
(tests/hub_integration/watch_terminal.rs).

It registers itself as Claude Code 2.1 does (`<CLAUDE_CONFIG_DIR>/sessions/<pid>.json` with
`messagingSocketPath`, and the 0600 `<pid>.<sha256 of the socket path>.key` with its peer token),
listens on that inbox, and reads prompts typed in its terminal from stdin, one per line. It writes
its transcript the way the real CLI (2.1.310, measured on 2026-11-14) does:

- a prompt typed while idle: its `user` line at once, then the turn;
- a prompt typed while a turn runs: a `queue-operation` `enqueue` line at once; at the turn's tool
  boundary a `remove` (reason `absorbed_mid_turn`) and a `queued_command` attachment, and the
  turn answers it with its own end;
- a message from its inbox while a turn runs: queued, and run after the turn as its own turn
  (`dequeue`, then a `peer` user line with the uuid it was sent with).

Each turn: an assistant `tool_use` line, FAKE_TURN_MS of work, the tool result, then the answer
`ANSWER <prompt>` with stop reason `end_turn`. FAKE_LOG gets `RECV`, `RUN` and `END` lines with a
monotonic time in ns, so a test reads what the harness got, when, and in which order.

Before it reads its terminal it asks the daemon for the hand-off as `acpmux resume-here` does,
from its own process, so the daemon binds the pid the kernel gives it at accept: with FAKE_DAEMON_SOCK
and FAKE_CHAT it sends `_acpmux/release_to_watch {sessionId, terminalPid: its pid}` over that unix
socket and logs `RELEASED` with the answer (or `REFUSED` with the error).

Environment: FAKE_CONFIG (the Claude store), FAKE_SESSION, FAKE_TRANSCRIPT, FAKE_LOG,
FAKE_TURN_MS (default 600), FAKE_NO_INBOX=1 (no inbox, as with cross-session messaging off),
FAKE_DAEMON_SOCK and FAKE_CHAT (the hand-off), FAKE_NAMED_PID (a pid to name instead of its own).
"""
import hashlib
import json
import os
import queue
import socket
import sys
import threading
import time
import uuid

CONFIG = os.environ["FAKE_CONFIG"]
SESSION = os.environ["FAKE_SESSION"]
TRANSCRIPT = os.environ["FAKE_TRANSCRIPT"]
LOG = os.environ["FAKE_LOG"]
TURN = int(os.environ.get("FAKE_TURN_MS", "600")) / 1000.0
TOKEN = "fake-peer-token-0123456789abcdef"

lock = threading.Lock()
work = queue.Queue()
pending = []  # [(kind, text, uuid)] waiting for the turn to end
typed_mid_turn = []  # texts typed during the running turn, before its tool boundary
state = {"busy": False, "boundary": False}


def now_iso():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % int((t % 1) * 1000)


def log(kind, text):
    with open(LOG, "a") as f:
        f.write("%s %d %s\n" % (kind, time.monotonic_ns(), json.dumps(text)))
        f.flush()


def write(record):
    record.setdefault("sessionId", SESSION)
    record.setdefault("timestamp", now_iso())
    with open(TRANSCRIPT, "a") as f:
        f.write(json.dumps(record) + "\n")
        f.flush()


def user_line(text, line_uuid=None, peer=False):
    rec = {"type": "user", "uuid": line_uuid or str(uuid.uuid4()),
           "message": {"role": "user", "content": text}}
    if peer:
        rec["origin"] = {"kind": "peer"}
    write(rec)


def run_turn(text):
    log("RUN", text)
    tool = "toolu_" + uuid.uuid4().hex[:12]
    write({"type": "assistant", "message": {"role": "assistant", "stop_reason": "tool_use",
           "content": [{"type": "tool_use", "id": tool, "name": "Bash", "input": {"command": "work"}}]}})
    time.sleep(TURN)
    write({"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tool, "content": "done"}]}})
    # The tool boundary: prompts typed meanwhile go into this turn.
    with lock:
        state["boundary"] = True
        absorbed = list(typed_mid_turn)
        typed_mid_turn.clear()
    for t in absorbed:
        source = str(uuid.uuid4())
        write({"type": "queue-operation", "operation": "remove", "content": t,
               "reason": "absorbed_mid_turn", "commandUuid": source})
        write({"type": "attachment", "uuid": str(uuid.uuid4()), "attachment": {
            "type": "queued_command", "prompt": t, "source_uuid": source,
            "commandMode": "prompt", "origin": {"kind": "human"}}})
        log("RUN", t)
    answer = "ANSWER " + " + ".join([text] + absorbed)
    write({"type": "assistant", "message": {"role": "assistant", "stop_reason": "end_turn",
           "content": [{"type": "text", "text": answer}]}})
    for t in [text] + absorbed:
        log("END", t)


def worker():
    while True:
        kind, text, line_uuid = work.get()
        with lock:
            state["busy"] = True
            state["boundary"] = False
        if kind == "inbox":
            user_line(text, line_uuid, peer=True)
        else:
            user_line(text)
        run_turn(text)
        while True:
            with lock:
                if not pending:
                    state["busy"] = False
                    break
                kind, text, line_uuid = pending.pop(0)
                state["boundary"] = False
            write({"type": "queue-operation", "operation": "dequeue"})
            if kind == "inbox":
                user_line(text, line_uuid, peer=True)
            else:
                user_line(text)
            run_turn(text)


def take(kind, text, line_uuid=None):
    """A prompt typed (`typed`) or from the inbox (`inbox`)."""
    log("RECV", text)
    with lock:
        if not state["busy"]:
            state["busy"] = True
            work.put((kind, text, line_uuid))
            return
        write({"type": "queue-operation", "operation": "enqueue", "content": text})
        if kind == "typed" and not state["boundary"]:
            typed_mid_turn.append(text)
        else:
            pending.append((kind, text, line_uuid))


def serve_inbox(server):
    while True:
        conn, _ = server.accept()
        data = b""
        while True:
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        conn.close()
        lines = [json.loads(l) for l in data.decode().splitlines() if l.strip()]
        if not lines or lines[0].get("type") != "auth" or lines[0].get("token") != TOKEN:
            log("REFUSED", data.decode())
            continue
        for msg in lines[1:]:
            if msg.get("type") == "user":
                take("inbox", msg["message"]["content"], msg.get("uuid"))


def release():
    """The hand-off `acpmux resume-here` asks for, as this process."""
    sock_path = os.environ.get("FAKE_DAEMON_SOCK")
    if not sock_path:
        return
    pid = int(os.environ.get("FAKE_NAMED_PID") or os.getpid())
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.connect(sock_path)
    f = conn.makefile("rwb")
    def call(rid, method, params):
        f.write((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        f.flush()
        while True:
            line = f.readline()
            if not line:
                return {"error": {"message": "closed"}}
            msg = json.loads(line)
            if msg.get("id") == rid:
                return msg
    call(1, "initialize", {"protocolVersion": 1, "clientInfo": {"name": "resume-here"}})
    answer = call(2, "_acpmux/release_to_watch", {"sessionId": os.environ["FAKE_CHAT"], "terminalPid": pid})
    conn.close()
    if "result" in answer:
        log("RELEASED", json.dumps(answer["result"]))
    else:
        log("REFUSED", json.dumps(answer.get("error")))


def main():
    pid = os.getpid()
    sessions = os.path.join(CONFIG, "sessions")
    os.makedirs(sessions, exist_ok=True)
    entry = {"pid": pid, "sessionId": SESSION, "cwd": os.getcwd(), "entrypoint": "cli",
             "kind": "interactive", "version": "2.1.310",
             "startedAt": int(time.time() * 1000)}
    if os.environ.get("FAKE_NO_INBOX") != "1":
        sock = os.path.join(sessions, "%d.sock" % pid)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(sock)
        server.listen(16)
        entry["messagingSocketPath"] = sock
        digest = hashlib.sha256(os.path.abspath(sock).encode()).hexdigest()
        key = os.path.join(sessions, "%d.%s.key" % (pid, digest))
        fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.write(fd, json.dumps({"peerToken": TOKEN}).encode())
        os.close(fd)
        threading.Thread(target=serve_inbox, args=(server,), daemon=True).start()
    with open(os.path.join(sessions, "%d.json" % pid), "w") as f:
        json.dump(entry, f)
    threading.Thread(target=worker, daemon=True).start()
    release()
    log("READY", "")
    for line in sys.stdin:
        line = line.rstrip("\n")
        if line:
            take("typed", line)
    # stdin closed: the terminal ended. Let a running turn finish its lines.
    while True:
        with lock:
            if not state["busy"] and work.empty():
                break
        time.sleep(0.05)


if __name__ == "__main__":
    main()
