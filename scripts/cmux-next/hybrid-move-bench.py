#!/usr/bin/env python3
"""hybrid-move-bench: how long moving a chat from one acpmux daemon to another takes, idle and
mid-turn, for a chat whose store is over 50 MB.

Leo, 2026-11-23: "say you move an existing chat over there. How do we make that as fast as
possible ... with as little jank as possible". The hybrid chats work (cmux#52145) answers a new
Cloud chat locally while its VM boots and then moves it there, and moves a chat mid-turn with no
visible interruption; its stop condition holds "a move takes under 3 s for a session over 50 MB".
This is the one harness for the before and after numbers.

What runs, all on one machine, nothing of the person's touched:
  * two stand-in model servers (Anthropic Messages), one per side, so each side's requests are
    told apart. Real Claude Code runs under each daemon against its own stand-in.
  * two acpmux daemons, each with its own ACPMUX_HOME, HOME and CLAUDE_CONFIG_DIR (as
    cmux-tui/crates/acpmux/tests/transfer_cli.rs does: two state roots on one machine).
  * one chat on the source, filled to --size-mb by "HMB-FILL" turns the stand-in answers with
    --fill-mb of text each (word salad from a fixed vocabulary, about as compressible as prose).
  * the move, driven over both daemons' sockets exactly as `acpmux transfer` / `acpmux session
    move` drive it (cli/run/transfer.rs): `_acpmux/transfer_begin` on the source (default
    `atToolBoundary`, asked again while it answers `transfer.tool_in_flight`, as
    `begin_move_live` does; `--interrupt` cuts at once), `transfer_receive`, every file paged
    with `transfer_read`/`transfer_write`, `transfer_finish` on the target, `transfer_commit` on
    the source.

Moves (one JSON line each):
  idle         a finished chat: an "HMB-PING" turn ends, the move begins at once; once the target
               took it a "HMB-PROBE" prompt is sent there (the person typing again).
  turn         mid-turn at a tool boundary (the default cut): an "HMB-WORK" turn of --steps Bash
               calls; the source's stand-in holds its answer to step 1's result, and the move
               begins while that model request is in flight (no tool runs).
  interrupt    mid-turn with `--interrupt` (`interrupt: true`): step 2's Bash call blocks (it reads
               a FIFO only the source's stand-in names), and the move begins while it runs.

Fields:
  session_bytes   sum of the bundle's file sizes (transfer_begin `files`)
  bytes_sent      bytes paged source -> target (decoded); wire_bytes as base64 on the socket
  freeze_ms       daemon clocks: the last event the source's log accepted before `transfer_out`
                  -> the first event the target's log accepted after `transferred_in` (idle: the
                  probe prompt the bench sends the moment transfer_finish answers)
  first_output_ms the same start -> the target's first agent output event (text or tool call)
  total_ms        bench clock: transfer_begin sent -> transfer_commit answered
  begin_ms / copy_ms / finish_ms / commit_ms   each step's share of total_ms
  turn_finished   the turn's last step ran and the target's stand-in answered "HMB-WORK DONE"
  continuation_msgs  distinct user text blocks the target's model saw that no bench prompt sent
                  (the move's continuation; Claude Code's own <system-reminder> blocks left out)
  rerun_tool_calls   Bash steps that ran more than once, over both sides (a marks file each step
                  appends to)

Every wait is on an event (a socket line, a model request arriving, a daemon log line) with a
deadline; nothing sleeps for time.

Usage:
  hybrid-move-bench.py --acpmux PATH [--size-mb 55] [--fill-mb 4] [--moves idle,turn,interrupt]
                       [--steps 3] [--keep DIR] [--out FILE.jsonl]
Requires `claude` (Claude Code) on PATH.
"""

from __future__ import annotations

import argparse
import base64
import errno
import http.server
import json
import os
import random
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid

PREFIX = "HMB-"
MODEL = "claude-opus-5-5"

# ---------------------------------------------------------------- stand-in model


def _words(seed: int) -> list[str]:
    rnd = random.Random(seed)
    letters = "etaoinshrdlucmfwypvbgkjqxz"
    weights = [12, 9, 8, 8, 7, 7, 6, 6, 6, 4, 4, 3, 3, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1]
    return ["".join(rnd.choices(letters, weights, k=rnd.randint(2, 10))) for _ in range(4000)]


VOCAB = _words(7)


def fill_text(nbytes: int, seed: int) -> str:
    rnd = random.Random(seed)
    out, size = [], 0
    while size < nbytes:
        line = " ".join(rnd.choices(VOCAB, k=14)) + ".\n"
        out.append(line)
        size += len(line)
    return "".join(out)[:nbytes]


def sse(events):
    out = []
    for name, data in events:
        out.append(f"event: {name}\n")
        out.append(f"data: {json.dumps(data)}\n\n")
    return "".join(out).encode()


def text_events(text: str, chunk: int = 256 << 10):
    usage = {"input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 0,
             "cache_creation_input_tokens": 0}
    ev = [("message_start", {"type": "message_start", "message": {
        "id": "msg_" + uuid.uuid4().hex[:12], "type": "message", "role": "assistant", "model": MODEL,
        "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}}),
        ("content_block_start", {"type": "content_block_start", "index": 0,
                                 "content_block": {"type": "text", "text": ""}})]
    for i in range(0, max(len(text), 1), chunk):
        ev.append(("content_block_delta", {"type": "content_block_delta", "index": 0,
                                           "delta": {"type": "text_delta", "text": text[i:i + chunk]}}))
    ev += [("content_block_stop", {"type": "content_block_stop", "index": 0}),
           ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                              "usage": {"output_tokens": 1}}),
           ("message_stop", {"type": "message_stop"})]
    return ev


def tool_events(command: str, description: str):
    usage = {"input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 0,
             "cache_creation_input_tokens": 0}
    call = {"command": command, "description": description, "timeout": 600000}
    return [
        ("message_start", {"type": "message_start", "message": {
            "id": "msg_" + uuid.uuid4().hex[:12], "type": "message", "role": "assistant", "model": MODEL,
            "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}}),
        ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {
            "type": "tool_use", "id": "toolu_hmb_" + uuid.uuid4().hex[:12], "name": "Bash", "input": {}}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                 "delta": {"type": "input_json_delta", "partial_json": json.dumps(call)}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None},
                           "usage": {"output_tokens": 1}}),
        ("message_stop", {"type": "message_stop"}),
    ]


def blocks_of(message) -> list[dict]:
    c = message.get("content")
    if isinstance(c, str):
        return [{"type": "text", "text": c}]
    return [b for b in c or [] if isinstance(b, dict)]


def result_text(block) -> str:
    inner = block.get("content")
    if isinstance(inner, str):
        return inner
    return "".join(c.get("text", "") for c in inner or [] if isinstance(c, dict))


class StandIn(http.server.ThreadingHTTPServer):
    """One side's model. Decides each main-loop answer from the conversation it is sent, as a
    model would: the last bench prompt names the turn, the tool results after it how far it got."""

    daemon_threads = True

    def __init__(self, side: str, marks: str, fifo: str, steps: int, fill_bytes: int):
        super().__init__(("127.0.0.1", 0), Handler)
        self.side, self.marks, self.fifo, self.steps, self.fill_bytes = side, marks, fifo, steps, fill_bytes
        self.cv = threading.Condition()
        self.requests = 0
        self.foreign: dict[str, int] = {}  # user texts no bench prompt sent -> times seen
        self.markers: dict[str, int] = {}  # Claude Code's own "[Request interrupted ...]" texts
        self.answered: list[str] = []      # what each main request was answered with
        self.hold_after_step = 0           # hold the answer to this step's result until released
        self.held = False                  # a request is being held now
        self.release = threading.Event()
        self.block_step = 0                # this step's command blocks on the FIFO (source only)

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_address[1]}"

    def note(self, what: str):
        with self.cv:
            self.answered.append(what)
            self.cv.notify_all()

    def wait_for(self, pred, timeout: float, what: str):
        deadline = time.monotonic() + timeout
        with self.cv:
            while not pred():
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError(f"{self.side} stand-in: no {what} in {timeout:.0f}s")
                self.cv.wait(left)

    def decide(self, body) -> tuple[str, list]:
        if not any(t.get("name") == "Bash" for t in body.get("tools") or []):
            return "side", text_events("ok")
        msgs = body.get("messages") or []
        if msgs and any((b.get("text") or "").startswith("[SUGGESTION MODE") for b in blocks_of(msgs[-1])):
            return "side", text_events("ok")  # Claude Code's next-prompt suggestion, not the turn
        last_prompt, at = None, -1
        for i, m in enumerate(msgs):
            if m.get("role") != "user":
                continue
            for b in blocks_of(m):
                t = b.get("text") or ""
                if b.get("type") == "text" and t.startswith(PREFIX):
                    last_prompt, at = t, i
                elif b.get("type") == "text" and t.strip() and not t.lstrip().startswith("<system-reminder>"):
                    seen = self.markers if t.startswith("[Request interrupted") else self.foreign
                    with self.cv:
                        seen[t[:2000]] = seen.get(t[:2000], 0) + 1
        if last_prompt is None:
            return "none", text_events("ok")
        kind = last_prompt[len(PREFIX):].split()[0]
        if kind == "FILL":
            return "fill", text_events(fill_text(self.fill_bytes, hash(last_prompt) & 0xFFFF))
        if kind != "WORK":
            return kind.lower(), text_events("ok")
        done = 0
        for m in msgs[at + 1:]:
            for b in blocks_of(m):
                if b.get("type") == "tool_result" and "HMB-STEP-DONE" in result_text(b):
                    done += 1
        step = done + 1
        if step > self.steps:
            return "work-done", text_events("HMB-WORK DONE")
        cmd = f"printf 'STEP-{step}\\n' >> {self.marks}"
        if step == self.block_step:
            cmd += f" && cat {self.fifo} > /dev/null"
        cmd += f" && echo HMB-STEP-DONE {step}"
        return f"step-{step}", tool_events(cmd, f"Step {step}")


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def reply(self, code, body: bytes, ctype="application/json"):
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            return self.reply(200, json.dumps({"object": "list", "data": [{"id": MODEL, "object": "model"}]}).encode())
        self.reply(404, b"{}")

    def do_HEAD(self):
        self.reply(200, b"")

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        raw = self.rfile.read(n) if n else b""
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        path = self.path.split("?")[0]
        srv: StandIn = self.server
        if path.endswith("/count_tokens"):
            return self.reply(200, b'{"input_tokens": 10}')
        if not path.endswith("/messages"):
            return self.reply(404, b"{}")
        with srv.cv:
            srv.requests += 1
        what, events = srv.decide(body)
        if not body.get("stream"):
            text = "ok"
            msg = {"id": "msg_hmb", "type": "message", "role": "assistant", "model": MODEL,
                   "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                   "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 1}}
            return self.reply(200, json.dumps(msg).encode())
        # The turn cut mid-model-request: the answer after step N's result waits for the move.
        if srv.hold_after_step and what == f"step-{srv.hold_after_step + 1}":
            with srv.cv:
                srv.held = True
                srv.cv.notify_all()
            srv.release.wait(300)
        srv.note(what)
        try:
            self.reply(200, sse(events), "text/event-stream")
        except (BrokenPipeError, ConnectionResetError):
            pass


# ---------------------------------------------------------------- acpmux side


class Rpc:
    """Newline JSON-RPC over a daemon socket; every line timestamped on arrival."""

    def __init__(self, path: str):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.connect(path)
        self.rf = self.s.makefile("rb")
        self.cv = threading.Condition()
        self.items: list[tuple[float, dict]] = []
        self.closed = False
        self.next = 0
        self.send_lock = threading.Lock()
        threading.Thread(target=self._pump, daemon=True).start()
        self.init = self.call("initialize", {"protocolVersion": 1, "clientInfo": {"name": "hybrid-move-bench"}})

    def _pump(self):
        for line in self.rf:
            t = time.perf_counter()
            try:
                m = json.loads(line)
            except ValueError:
                continue
            with self.cv:
                self.items.append((t, m))
                self.cv.notify_all()
        with self.cv:
            self.closed = True
            self.cv.notify_all()

    def mark(self) -> int:
        with self.cv:
            return len(self.items)

    def wait(self, pred, timeout: float, start: int = 0, what: str = "message"):
        deadline = time.monotonic() + timeout
        i = start
        with self.cv:
            while True:
                while i < len(self.items):
                    t, m = self.items[i]
                    i += 1
                    if pred(m):
                        return t, m
                if self.closed:
                    raise RuntimeError(f"socket closed before {what}")
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError(f"no {what} in {timeout:.0f}s")
                self.cv.wait(left)

    def send(self, method: str, params: dict) -> int:
        # The history that follows a move is sent on a thread while the bench prompts the chat.
        with self.send_lock:
            self.next += 1
            rid = self.next
            self.s.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        return rid

    def result(self, rid: int, start: int, timeout: float, method: str):
        t, m = self.wait(lambda m: m.get("id") == rid and "method" not in m, timeout, start, f"{method} answer")
        if "error" in m:
            raise RpcError(method, m["error"])
        return t, m["result"]

    def call(self, method: str, params: dict, timeout: float = 120.0):
        start = self.mark()
        rid = self.send(method, params)
        return self.result(rid, start, timeout, method)[1]

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


class RpcError(RuntimeError):
    def __init__(self, method, error):
        super().__init__(f"{method}: {json.dumps(error)[:600]}")
        self.error = error


def scrubbed_env(scratch: str, name: str, stand_url: str) -> dict:
    env = dict(os.environ)
    for k in list(env):
        # CLAUDECODE (run from a Claude Code session) makes acpmux drop ANTHROPIC_* for children.
        if k.startswith(("ANTHROPIC_", "OPENAI_", "CLAUDE_CODE_", "CMUX_", "ACPMUX_", "CODEX_")) or k == "CLAUDECODE":
            env.pop(k)
    root = os.path.join(scratch, name)
    private_dir(root)
    for d in ("home", "xdg-config", "acpmux"):
        private_dir(os.path.join(root, d))
    env.update({
        "HOME": os.path.join(root, "home"), "XDG_CONFIG_HOME": os.path.join(root, "xdg-config"),
        "ANTHROPIC_BASE_URL": stand_url, "ANTHROPIC_API_KEY": "sk-ant-bench-placeholder",
        # No CLAUDE_CONFIG_DIR: a move carries Claude Code's transcript from HOME/.claude only
        # (native.rs `locate`), as on a person's machine.
        "DISABLE_AUTOUPDATER": "1",
        "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTO_COMPACT": "1",
        "ANTHROPIC_MODEL": MODEL, "ANTHROPIC_SMALL_FAST_MODEL": MODEL,
        "ACPMUX_HOME": os.path.join(root, "acpmux"),
        "ACPMUX_SOCKET": os.path.join(root, "acpmux", "s.sock"),
        # The harness is the daemon's own child, so the daemon's exit ends it (no host outlives it).
        "ACPMUX_AGENT_HOSTS": "0", "ACPMUX_LOGIN_ENV": "0",
    })
    return env


class Daemon:
    def __init__(self, binary: str, env: dict, name: str, timeout: float = 60.0):
        self.name, self.env = name, env
        self.home, self.sock = env["ACPMUX_HOME"], env["ACPMUX_SOCKET"]
        self.log_path = os.path.join(self.home, "daemon.log")
        self.log = open(self.log_path, "ab")
        self.p = subprocess.Popen([binary, "daemon", "run", "--log", "info"], env=env, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        # Ready is the daemon's own "listening on SOCKET" line, read as it is written.
        ready = threading.Event()

        def pump():
            for line in self.p.stdout:
                self.log.write(line)
                self.log.flush()
                if b"listening on" in line and self.sock.encode() in line:
                    ready.set()
            ready.set()

        threading.Thread(target=pump, daemon=True).start()
        if not ready.wait(timeout) or self.p.poll() is not None:
            raise RuntimeError(f"{name} daemon did not listen; see {self.log_path}")
        self.rpc = Rpc(self.sock)

    def close(self):
        self.rpc.close()
        if self.p.poll() is None:
            self.p.terminate()
            try:
                self.p.wait(15)
            except subprocess.TimeoutExpired:
                self.p.kill()
                self.p.wait(5)


def prompt(rpc: Rpc, sid: str, text: str) -> tuple[int, int]:
    start = rpc.mark()
    rid = rpc.send("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": text}],
                                      "_meta": {"acpmux": {"promptId": "hmb-" + uuid.uuid4().hex[:10]}}})
    return rid, start


def turn(rpc: Rpc, sid: str, text: str, timeout: float = 600.0):
    rid, start = prompt(rpc, sid, text)
    return rpc.result(rid, start, timeout, "session/prompt")


def events(rpc: Rpc, sid: str, **params) -> list[dict]:
    page = rpc.call("_acpmux/events", {"sessionId": sid, **params})
    return page.get("events") or []


def tree_bytes(*roots: str) -> int:
    total = 0
    for root in roots:
        for d, _, files in os.walk(root):
            for f in files:
                p = os.path.join(d, f)
                try:
                    st = os.lstat(p)
                except OSError:
                    continue
                if stat.S_ISREG(st.st_mode) and not f.endswith(".log") and not f.endswith(".sock"):
                    total += st.st_size
    return total


# ---------------------------------------------------------------- the move


TOOL_IN_FLIGHT = "tool_in_flight"


def move(src: Rpc, dst: Rpc, sid: str, cwd: str, interrupt: bool, dst_sock: str) -> dict:
    """cli/run/transfer.rs `move_chat`, with `begin_move_live`'s retry for a tool in flight."""
    t0 = time.perf_counter()
    begin_params = {"sessionId": sid, "interrupt": interrupt, "atToolBoundary": not interrupt,
                    "afterTurn": False, "gatesQueueApproval": True, "to": {"socket": dst_sock}}
    tries = 0
    while True:
        tries += 1
        try:
            begin = src.call("_acpmux/transfer_begin", begin_params, timeout=900)
            break
        except RpcError as e:
            text = json.dumps(e.error)
            if TOOL_IN_FLIGHT in text or "compacting" in text:
                # begin_move_live asks again every 500 ms; here the next ask waits on the source's
                # next session/update (a tool call ending), bounded at 15 min like TOOL_WAIT.
                mark = src.mark()
                src.wait(lambda m: m.get("method") == "session/update", 900, mark, "tool call end")
                continue
            raise
    t_begun = time.perf_counter()
    tid, epoch = begin.get("transferId"), begin.get("epoch", 0)
    receive = dst.call("_acpmux/transfer_receive", {"manifest": begin})
    rid = receive.get("receiveId")
    sent = wire = 0
    for f in begin.get("files") or []:
        off = 0
        while True:
            page = src.call("_acpmux/transfer_read", {"transferId": tid, "path": f["path"], "offset": off, "epoch": epoch})
            data = page["data"]
            dst.call("_acpmux/transfer_write", {"receiveId": rid, "path": f["path"], "offset": off, "data": data, "epoch": epoch})
            wire += len(data)
            sent += len(base64.b64decode(data))
            off = page["next"]
            if page.get("eof"):
                break
    t_copied = time.perf_counter()
    finished = dst.call("_acpmux/transfer_finish", {"receiveId": rid, "from": {"sessionId": sid}, "epoch": epoch, "cwd": cwd})
    t_finished = time.perf_counter()
    src.call("_acpmux/transfer_commit", {"sessionId": sid, "transferId": tid, "epoch": epoch,
                                         "to": {"socket": dst_sock, "sessionId": finished.get("sessionId", sid)}})
    t_end = time.perf_counter()
    ms = lambda a, b: round((b - a) * 1000, 1)
    return {
        "session_bytes": sum(int(f.get("size") or 0) for f in begin.get("files") or []),
        "files": len(begin.get("files") or []), "bytes_sent": sent, "wire_bytes": wire,
        "begin_tries": tries, "begin_ms": ms(t0, t_begun), "copy_ms": ms(t_begun, t_copied),
        "finish_ms": ms(t_copied, t_finished), "commit_ms": ms(t_finished, t_end), "total_ms": ms(t0, t_end),
        "continues": begin.get("continues"), "target_session": finished.get("sessionId", sid),
        "_t_finished": t_finished,
    }


OUTPUT_KINDS = {"agent_message_chunk", "agent_thought_chunk", "tool_call", "tool_call_update"}
# What a chat "accepts": the agent's output and a person's prompt. Bookkeeping the daemon writes on
# its own (usage_stats, titles, status) is not the chat answering anyone.
ACCEPTED_SRC = OUTPUT_KINDS | {"user_message", "turn_started"}
ACCEPTED_DST = {"user_message", "turn_started"}


def event_times(src: Rpc, dst: Rpc, sid: str, tsid: str) -> dict:
    """From the daemons' own logs (`at`, ms since the epoch, one machine's clock):
    freeze_ms        the source's last accepted event (agent output, or a prompt taken) before its
                     `transfer_out` -> the target's first prompt taken (`user_message` /
                     `turn_started`: the continuation, or the probe a person sends) after
                     `transferred_in`
    first_output_ms  the same start -> the target's first agent output (text or a tool call)"""
    out = events(src, sid, kinds=["transfer_out"])
    if not out:
        return {"freeze_ms": None, "first_output_ms": None, "freeze_note": "no transfer_out on the source"}
    seq = out[-1]["seq"]
    before = [e for e in events(src, sid, beforeSeq=seq, limit=400)
              if e.get("seq", 0) < seq and e.get("kind") in ACCEPTED_SRC]
    landed = events(dst, tsid, kinds=["transferred_in"])
    if not landed or not before:
        return {"freeze_ms": None, "first_output_ms": None, "freeze_note": "no transferred_in on the target"}
    last = before[-1]
    after = events(dst, tsid, afterSeq=landed[-1]["seq"], limit=5000)
    first = next((e for e in after if e.get("kind") in ACCEPTED_DST), None)
    first_out = next((e for e in after if e.get("kind") in OUTPUT_KINDS and e.get("dir") == "in"), None)
    return {
        "freeze_ms": None if first is None else first["at"] - last["at"],
        "first_output_ms": None if first_out is None else first_out["at"] - last["at"],
        "freeze_from": last.get("kind"), "freeze_to": None if first is None else first.get("kind"),
        "transferred_in_after_ms": landed[-1]["at"] - last["at"],
    }


# ---------------------------------------------------------------- one run


class Side:
    def __init__(self, name: str, binary: str, scratch: str, marks: str, fifo: str, steps: int, fill: int):
        self.stand = StandIn(name, marks, fifo, steps, fill)
        threading.Thread(target=self.stand.serve_forever, daemon=True).start()
        self.env = scrubbed_env(scratch, name, self.stand.url)
        self.daemon = Daemon(binary, self.env, name)
        self.rpc = self.daemon.rpc
        self.root = os.path.join(scratch, name)

    def close(self):
        self.stand.release.set()
        self.daemon.close()
        self.stand.shutdown()


def build_session(side: Side, size_mb: float, log) -> tuple[str, str, int]:
    cwd = os.path.join(side.root, "project")
    os.makedirs(cwd, exist_ok=True)
    made = side.rpc.call("session/new", {"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {
        "harness": "claude", "policy": "approve-all", "model": MODEL}}}, timeout=180)
    sid = made["sessionId"]
    turn(side.rpc, sid, f"{PREFIX}PING 0")
    i, size = 0, 0
    t0 = time.perf_counter()
    while size < size_mb * 1e6:
        i += 1
        turn(side.rpc, sid, f"{PREFIX}FILL {i}", timeout=900)
        size = tree_bytes(os.path.join(side.env["ACPMUX_HOME"], "sessions"),
                          os.path.join(side.env["HOME"], ".claude", "projects"))
        log(f"fill {i}: chat store (acpmux sessions + Claude transcript) {size / 1e6:.1f} MB ({time.perf_counter() - t0:.0f}s)")
    return sid, cwd, size


def marks_reruns(marks: str) -> int:
    try:
        lines = [l.strip() for l in open(marks) if l.strip()]
    except FileNotFoundError:
        return 0
    return len(lines) - len(set(lines))


def fifo_writer(fifo: str) -> dict:
    """Opens `fifo` for writing on a thread; `opened` is set once a reader has it open."""
    out = {"opened": threading.Event(), "fd": None}

    def run():
        out["fd"] = os.open(fifo, os.O_WRONLY)
        out["opened"].set()

    threading.Thread(target=run, daemon=True).start()
    return out


def unblock(fifo: str):
    """Let a step still blocked on the FIFO (the cut call on the source) end."""
    try:
        fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
    except OSError as e:
        if e.errno in (errno.ENXIO, errno.ENOENT):
            return
        raise
    os.close(fd)


def run_move(kind: str, args, scratch: str, log) -> dict:
    run_dir = os.path.join(scratch, kind)
    private_dir(run_dir)
    marks, fifo = os.path.join(run_dir, "marks"), os.path.join(run_dir, "fifo")
    os.mkfifo(fifo)
    fill = int(args.fill_mb * 1e6)
    src = Side("source", args.acpmux, run_dir, marks, fifo, args.steps, fill)
    dst = Side("target", args.acpmux, run_dir, marks, fifo, args.steps, fill)
    try:
        sid, _, store = build_session(src, args.size_mb, log)
        dst_cwd = os.path.join(dst.root, "project")
        os.makedirs(dst_cwd, exist_ok=True)
        before_target = dst.stand.mark_count = len(dst.stand.answered)
        interrupt = kind == "interrupt"
        if kind == "idle":
            turn(src.rpc, sid, f"{PREFIX}PING 1")
        else:
            if kind == "turn":
                src.stand.hold_after_step = 1
            else:
                src.stand.block_step = 2
            mark = src.rpc.mark()
            prompt(src.rpc, sid, f"{PREFIX}WORK 1")
            if kind == "turn":
                src.stand.wait_for(lambda: src.stand.held, 300, "held step-2 request")
            else:
                # Step 2's Bash call runs: its `cat FIFO` opened the FIFO, which is the moment this
                # blocking open for writing returns. The fd stays open (the call stays blocked)
                # until the move is done.
                writer = fifo_writer(fifo)
                if not writer["opened"].wait(300):
                    raise TimeoutError("step 2's Bash call never started")
        r = move(src.rpc, dst.rpc, sid, dst_cwd, interrupt, dst.daemon.sock)
        # The source's stale model request and blocked step end now; nothing on the source runs on.
        src.stand.release.set()
        if kind == "interrupt":
            os.close(writer["fd"])
        tsid = r.pop("target_session")
        t_fin = r.pop("_t_finished")
        if kind == "idle":
            turn(dst.rpc, tsid, f"{PREFIX}PROBE 1")
            finished = None
        else:
            done = dst.rpc.call("_acpmux/wait", {"sessions": [tsid], "until": ["ready"], "all": True,
                                                 "timeoutMs": 300000}, timeout=320)
            finished = (not done.get("timedOut")) and "work-done" in dst.stand.answered[before_target:]
        r.update(event_times(src.rpc, dst.rpc, sid, tsid))
        r.update({
            "move": kind, "cut": "interrupt" if interrupt else ("tool-boundary" if kind != "idle" else "idle"),
            "store_bytes_on_disk": store, "turn_finished": finished,
            "continuation_msgs": len(dst.stand.foreign),
            "interrupt_markers": len(dst.stand.markers),
            "rerun_tool_calls": marks_reruns(marks),
            "target_answers": dst.stand.answered[before_target:][:12],
        })
        if args.verbose:
            r["continuation_texts"] = [t[:300] for t in dst.stand.foreign]
        return r
    finally:
        unblock(fifo)
        for s in (src, dst):
            try:
                s.close()
            except Exception as e:  # teardown never hides the run's own result
                log(f"teardown {s.stand.side}: {e}")


def private_dir(path: str):
    """The daemon refuses a state root under a directory others may write (umask 002 hosts)."""
    os.makedirs(path, exist_ok=True)
    os.chmod(path, 0o700)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", required=True, help="the acpmux binary both daemons run")
    ap.add_argument("--size-mb", type=float, default=55.0, help="fill the chat's store to at least this")
    ap.add_argument("--fill-mb", type=float, default=4.0, help="text per fill turn")
    ap.add_argument("--moves", default="idle,turn,interrupt")
    ap.add_argument("--steps", type=int, default=3, help="Bash steps in the mid-turn turn")
    ap.add_argument("--keep", help="scratch directory to use and keep (default: a temp dir, removed)")
    ap.add_argument("--out", help="also append each JSON line here")
    ap.add_argument("--verbose", action="store_true", help="include the continuation texts")
    args = ap.parse_args()
    if not shutil.which("claude"):
        sys.exit("hybrid-move-bench: needs `claude` (Claude Code) on PATH")
    args.acpmux = os.path.abspath(args.acpmux)
    log = lambda s: print(f"[hmb] {s}", file=sys.stderr, flush=True)
    scratch = args.keep or tempfile.mkdtemp(prefix="hmb-", dir="/tmp")
    private_dir(scratch)
    version = subprocess.run([args.acpmux, "--version"], capture_output=True, text=True).stdout.strip()
    failed = False
    try:
        for kind in [k.strip() for k in args.moves.split(",") if k.strip()]:
            log(f"move {kind}: building a {args.size_mb:.0f} MB chat")
            try:
                r = run_move(kind, args, scratch, log)
            except Exception as e:
                failed = True
                r = {"move": kind, "error": f"{type(e).__name__}: {e}"}
            r["acpmux"] = version
            line = json.dumps(r, sort_keys=True)
            print(line, flush=True)
            if args.out:
                with open(args.out, "a") as f:
                    f.write(line + "\n")
    finally:
        if not args.keep:
            shutil.rmtree(scratch, ignore_errors=True)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
