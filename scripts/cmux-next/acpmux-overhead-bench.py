#!/usr/bin/env python3
"""acpmux overhead bench: each harness raw vs through acpmux, same model, same prompt.

A local stand-in model answers every request at once with "ok" (Anthropic
Messages for Claude Code, OpenAI Responses for Codex, OpenAI chat completions
for OpenCode), so a timing difference is the client side only: acpmux, or the
harness itself, never the model. Each run alternates raw and acpmux so machine
load hits both sides alike.

Raw drives the harness the way acpmux does, on the same wire:
  claude: `claude -p --input-format stream-json ...` (acpmux's claude_stdio args)
  codex:  `codex app-server` JSON-RPC (acpmux bridges it in process)
  opencode: `opencode acp` (ACP)
acpmux: an isolated daemon (its own ACPMUX_HOME) on the binary given with
--acpmux; session/new, then session/prompt over its socket.

Per run, milliseconds from the moment the client starts the session:
  ready   raw: the harness answered its handshake; acpmux: session/new answered
  first   the first answer text arrived (time to first token)
  end     the turn ended (prompt answered)
  warm_first / warm_end  a second prompt on the same session, from its send

--mode prewarm: the new chat typing prewarm (webviews newChatPrewarm.ts) instead. Both sides run
through acpmux, each run in a fresh folder, from the moment the person presses Enter (session/new):
  cold       session/new, then the prompt (today's Enter in a new chat with no hint)
  prewarmed  `_acpmux/prewarm` {harness, cwd, wait} first (the typing; not timed into Enter), then
             the same session/new and prompt; `pool_hit` 1 when session/new took the warm session
  ready / first / end  ms from Enter to session/new's answer, the first answer text, the turn's end
  warm_start           ms the hint took to have a ready session (the typing time it needs)
Then the idle cost of typing in 5 new chats in 5 folders and sending none: ready warm sessions
left and their RSS (`abandoned_ready`, `abandoned_rss_mb`).

--mode hibernate: an idle chat's hibernation (acpmux hub/idle.rs). n chats per harness, each attached
(the chat on screen), one turn each, then all left idle for --idle-wait seconds (default 135: the
2 min default and a margin). Per chat:
  procs / rss_mb   the agent's processes (its host, harness and MCP servers) and their RSS after the turn
  left             how many of those still run after the idle wait (0: hibernated)
  first            ms from the next prompt's send to its first answer text (a wake when hibernated);
                   every other chat first says `_acpmux/typing` on and waits 1 s (`typed` 1), as a
                   person typing does
  warm_first       the same for a prompt right after, the agent awake

Usage:
  acpmux-overhead-bench.py --acpmux PATH [--harness claude,codex,opencode] [-n 20]
                           [--mode overhead|prewarm|hibernate] [--json OUT] [--md OUT]
"""

from __future__ import annotations

import argparse
import http.server
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
import uuid

# ---------------------------------------------------------------- stand-in model


class StandIn(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.hits: dict[str, int] = {}
        self.lock = threading.Lock()
        # Model requests and their body bytes, for each run's share (`Counter`).
        self.requests = 0
        self.bytes = 0

    def hit(self, tag: str, size: int = 0):
        with self.lock:
            self.hits[tag] = self.hits.get(tag, 0) + 1
            if tag.startswith("POST "):
                self.requests += 1
                self.bytes += size

    def counts(self):
        with self.lock:
            return self.requests, self.bytes


def sse(events):
    out = []
    for name, data in events:
        if name:
            out.append(f"event: {name}\n")
        out.append(f"data: {data if isinstance(data, str) else json.dumps(data)}\n\n")
    return "".join(out).encode()


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
        self.server.hit("GET " + self.path.split("?")[0])
        if self.path.startswith("/v1/models"):
            return self.reply(200, json.dumps({"object": "list", "data": [{"id": "bench", "object": "model"}]}).encode())
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
        self.server.hit("POST " + path, len(raw))
        # ACPMUX_BENCH_LOG=FILE: one line per model request (what each side asks the model).
        if os.environ.get("ACPMUX_BENCH_LOG"):
            with self.server.lock, open(os.environ["ACPMUX_BENCH_LOG"], "a") as f:
                f.write(json.dumps({"at": time.time(), "path": path, "ua": self.headers.get("user-agent"), "enc": self.headers.get("content-encoding"),
                                    "body": raw[:400000].decode("utf-8", "replace")}) + "\n")
        if path.endswith("/messages/count_tokens"):
            return self.reply(200, b'{"input_tokens": 10}')
        if path.endswith("/messages"):
            return self.anthropic(body)
        if path.endswith("/responses"):
            return self.openai_responses(body)
        if path.endswith("/chat/completions"):
            return self.chat(body)
        self.reply(404, b"{}")

    def anthropic(self, body):
        model = body.get("model", "claude-bench")
        usage = {"input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
        if not body.get("stream"):
            msg = {"id": "msg_bench", "type": "message", "role": "assistant", "model": model,
                   "content": [{"type": "text", "text": "ok"}], "stop_reason": "end_turn",
                   "stop_sequence": None, "usage": usage}
            return self.reply(200, json.dumps(msg).encode())
        events = [
            ("message_start", {"type": "message_start", "message": {"id": "msg_bench", "type": "message", "role": "assistant",
                                                                     "model": model, "content": [], "stop_reason": None,
                                                                     "stop_sequence": None, "usage": usage}}),
            ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
            ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "ok"}}),
            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                               "usage": {"output_tokens": 1}}),
            ("message_stop", {"type": "message_stop"}),
        ]
        self.reply(200, sse(events), "text/event-stream")

    def openai_responses(self, body):
        rid, iid = "resp_bench", "msg_bench"
        usage = {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 1,
                 "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 11}
        item = {"type": "message", "id": iid, "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": "ok", "annotations": []}]}
        events = [
            ("response.created", {"type": "response.created", "response": {"id": rid, "status": "in_progress"}}),
            ("response.output_item.added", {"type": "response.output_item.added", "output_index": 0,
                                            "item": {**item, "status": "in_progress", "content": []}}),
            ("response.content_part.added", {"type": "response.content_part.added", "item_id": iid, "output_index": 0,
                                             "content_index": 0, "part": {"type": "output_text", "text": "", "annotations": []}}),
            ("response.output_text.delta", {"type": "response.output_text.delta", "item_id": iid, "output_index": 0,
                                            "content_index": 0, "delta": "ok"}),
            ("response.output_text.done", {"type": "response.output_text.done", "item_id": iid, "output_index": 0,
                                           "content_index": 0, "text": "ok"}),
            ("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item}),
            ("response.completed", {"type": "response.completed",
                                    "response": {"id": rid, "status": "completed", "output": [item], "usage": usage}}),
        ]
        self.reply(200, sse(events), "text/event-stream")

    def chat(self, body):
        model = body.get("model", "bench")
        base = {"id": "chatcmpl-bench", "object": "chat.completion.chunk", "created": int(time.time()), "model": model}
        if not body.get("stream"):
            msg = {**base, "object": "chat.completion",
                   "choices": [{"index": 0, "message": {"role": "assistant", "content": "ok"}, "finish_reason": "stop"}],
                   "usage": {"prompt_tokens": 10, "completion_tokens": 1, "total_tokens": 11}}
            return self.reply(200, json.dumps(msg).encode())
        events = [
            (None, {**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": "ok"}, "finish_reason": None}]}),
            (None, {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
                    "usage": {"prompt_tokens": 10, "completion_tokens": 1, "total_tokens": 11}}),
            (None, "[DONE]"),
        ]
        self.reply(200, sse(events), "text/event-stream")


# ---------------------------------------------------------------- line pipes


class Lines:
    """Newline-delimited JSON over a pipe or socket, read on a thread, timestamped."""

    def __init__(self, reader, writer):
        self.writer = writer
        self.lock = threading.Condition()
        self.items: list[tuple[float, dict]] = []
        self.closed = False
        threading.Thread(target=self._pump, args=(reader,), daemon=True).start()

    def _pump(self, reader):
        for line in reader:
            t = time.perf_counter()
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            with self.lock:
                self.items.append((t, msg))
                self.lock.notify_all()
        with self.lock:
            self.closed = True
            self.lock.notify_all()

    def send(self, msg: dict):
        self.writer.write((json.dumps(msg) + "\n").encode())
        self.writer.flush()

    def wait(self, pred, timeout=60.0, start=0) -> tuple[float, dict, int]:
        """The first message from index `start` that `pred` accepts: (time, msg, next index)."""
        deadline = time.monotonic() + timeout
        i = start
        with self.lock:
            while True:
                while i < len(self.items):
                    t, m = self.items[i]
                    i += 1
                    if pred(m):
                        return t, m, i
                if self.closed:
                    raise RuntimeError("closed before the awaited message")
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError("timed out waiting")
                self.lock.wait(left)

    def mark(self) -> int:
        with self.lock:
            return len(self.items)


class SockFile:
    def __init__(self, sock):
        self.sock = sock

    def write(self, b):
        self.sock.sendall(b)

    def flush(self):
        pass


def ms(a, b):
    return round((b - a) * 1000.0, 2)


# ---------------------------------------------------------------- raw drivers


def spawn(argv, env, cwd):
    return subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            env=env, cwd=cwd, bufsize=0)


def stop(p):
    try:
        p.stdin.close()
    except OSError:
        pass
    try:
        p.terminate()
        p.wait(5)
    except Exception:
        p.kill()


# The model each harness runs, on both sides: acpmux gets it as `_meta.acpmux.model`, raw
# as its own flag or config. A real model id, so each harness builds the prompt it builds for
# a real chat (the stand-in answers any id).
MODELS = {"claude": "claude-opus-5-5", "codex": "gpt-6.1-sol", "opencode": "bench/m"}


def raw_claude(env, cwd):
    t0 = time.perf_counter()
    argv = ["claude", "-p", "--model", MODELS["claude"], "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
            "--session-id", str(uuid.uuid4()), "--permission-mode", "default"]
    p = spawn(argv, env, cwd)
    io = Lines(p.stdout, p.stdin)
    try:
        io.send({"type": "control_request", "request_id": "boot-1",
                 "request": {"subtype": "initialize", "hooks": {}}})
        t_ready, _, i = io.wait(lambda m: m.get("type") == "control_response")
        out = {"ready": ms(t0, t_ready)}

        def turn(start, text):
            ts = time.perf_counter()
            io.send({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}})
            tf, _, j = io.wait(lambda m: m.get("type") == "stream_event"
                               and m.get("event", {}).get("type") == "content_block_delta", start=start)
            te, _, j = io.wait(lambda m: m.get("type") == "result", start=j)
            return ts, tf, te, j

        _, tf, te, i = turn(i, "Reply with ok.")
        out["first"], out["end"] = ms(t0, tf), ms(t0, te)
        ts, tf, te, i = turn(i, "Again: reply with ok.")
        out["warm_first"], out["warm_end"] = ms(ts, tf), ms(ts, te)
        return out
    finally:
        stop(p)


def raw_codex(env, cwd):
    t0 = time.perf_counter()
    p = spawn(["codex", "app-server"], env, cwd)
    io = Lines(p.stdout, p.stdin)
    try:
        io.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"clientInfo": {"name": "acpmux-bench", "version": "1"}}})
        io.wait(lambda m: m.get("id") == 1)
        io.send({"jsonrpc": "2.0", "method": "initialized"})
        io.send({"jsonrpc": "2.0", "id": 2, "method": "thread/start", "params": {"cwd": cwd}})
        t_ready, m, i = io.wait(lambda m: m.get("id") == 2)
        if "error" in m:
            raise RuntimeError(f"thread/start: {m['error']}")
        thread = m["result"]["thread"]["id"]
        out = {"ready": ms(t0, t_ready)}

        def turn(start, rid, text):
            ts = time.perf_counter()
            io.send({"jsonrpc": "2.0", "id": rid, "method": "turn/start",
                     "params": {"threadId": thread, "input": [{"type": "text", "text": text}]}})
            tf, _, j = io.wait(lambda m: m.get("method") == "item/agentMessage/delta", start=start)
            te, _, j = io.wait(lambda m: m.get("method") == "turn/completed", start=j)
            return ts, tf, te, j

        _, tf, te, i = turn(i, 3, "Reply with ok.")
        out["first"], out["end"] = ms(t0, tf), ms(t0, te)
        ts, tf, te, i = turn(i, 4, "Again: reply with ok.")
        out["warm_first"], out["warm_end"] = ms(ts, tf), ms(ts, te)
        return out
    finally:
        stop(p)


def acp_turn(io, start, rid, session, text):
    ts = time.perf_counter()
    io.send({"jsonrpc": "2.0", "id": rid, "method": "session/prompt",
             "params": {"sessionId": session, "prompt": [{"type": "text", "text": text}]}})
    tf, _, j = io.wait(lambda m: m.get("method") == "session/update"
                       and m.get("params", {}).get("sessionId") == session
                       and m["params"].get("update", {}).get("sessionUpdate") == "agent_message_chunk", start=start)
    te, m, j = io.wait(lambda m: m.get("id") == rid, start=start)
    if "error" in m:
        raise RuntimeError(f"session/prompt: {m['error']}")
    return ts, tf, max(te, tf), j


def raw_opencode(env, cwd):
    t0 = time.perf_counter()
    p = spawn(["opencode", "acp"], env, cwd)
    io = Lines(p.stdout, p.stdin)
    try:
        io.send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": {"protocolVersion": 1, "clientCapabilities": {}}})
        io.wait(lambda m: m.get("id") == 1)
        io.send({"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": {"cwd": cwd, "mcpServers": []}})
        t_ready, m, i = io.wait(lambda m: m.get("id") == 2)
        if "error" in m:
            raise RuntimeError(f"session/new: {m['error']}")
        sid = m["result"]["sessionId"]
        out = {"ready": ms(t0, t_ready)}
        _, tf, te, i = acp_turn(io, i, 3, sid, "Reply with ok.")
        out["first"], out["end"] = ms(t0, tf), ms(t0, te)
        ts, tf, te, i = acp_turn(io, i, 4, sid, "Again: reply with ok.")
        out["warm_first"], out["warm_end"] = ms(ts, tf), ms(ts, te)
        return out
    finally:
        stop(p)


RAW = {"claude": raw_claude, "codex": raw_codex, "opencode": raw_opencode}

# ---------------------------------------------------------------- acpmux driver


class Daemon:
    def __init__(self, binary, env, home, extra_env=None):
        self.home = home
        self.sock_path = os.path.join(home, "acpmux.sock")
        denv = dict(env, ACPMUX_HOME=home, ACPMUX_SOCKET=self.sock_path, **(extra_env or {}))
        self.log = open(os.path.join(home, "daemon.log"), "wb")
        self.p = subprocess.Popen([binary, "daemon", "run"], env=denv, stdout=self.log, stderr=self.log,
                                  stdin=subprocess.DEVNULL)
        deadline = time.monotonic() + 30
        while not os.path.exists(self.sock_path):
            if self.p.poll() is not None or time.monotonic() > deadline:
                raise RuntimeError(f"acpmux daemon did not start; see {home}/daemon.log")
            time.sleep(0.02)
        s = socket.socket(socket.AF_UNIX)
        s.connect(self.sock_path)
        self.s = s
        self.io = Lines(s.makefile("rb"), SockFile(s))
        self.next = 100

    def request(self, method, params, timeout=60.0):
        self.next += 1
        rid = self.next
        start = self.io.mark()
        self.io.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        t, m, _ = self.io.wait(lambda m: m.get("id") == rid, timeout, start)
        if "error" in m:
            raise RuntimeError(f"{method}: {m['error']}")
        return t, m["result"]

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass
        self.p.terminate()
        try:
            self.p.wait(10)
        except subprocess.TimeoutExpired:
            self.p.kill()


def via_acpmux(daemon: Daemon, harness, cwd):
    t0 = time.perf_counter()
    t_ready, r = daemon.request("session/new", {"cwd": cwd, "mcpServers": [],
                                                 "_meta": {"acpmux": {"harness": harness, "policy": "approve-all",
                                                                      "model": MODELS[harness]}}})
    sid = r["sessionId"]
    out = {"ready": ms(t0, t_ready)}
    io = daemon.io
    try:
        daemon.next += 1
        _, tf, te, _ = acp_turn(io, io.mark(), daemon.next, sid, "Reply with ok.")
        out["first"], out["end"] = ms(t0, tf), ms(t0, te)
        daemon.next += 1
        ts, tf, te, _ = acp_turn(io, io.mark(), daemon.next, sid, "Again: reply with ok.")
        out["warm_first"], out["warm_end"] = ms(ts, tf), ms(ts, te)
        return out
    finally:
        try:
            daemon.request("session/close", {"sessionId": sid}, timeout=20)
        except Exception:
            pass


def pool_entries(daemon: Daemon, cwd=None):
    _, status = daemon.request("_acpmux/status", {})
    pool = status.get("pool") or {}
    entries = [e for e in pool.get("entries", []) if cwd is None or e.get("cwd") == cwd]
    return entries, pool.get("rssBytes", 0)


def via_acpmux_enter(daemon: Daemon, harness, cwd, prewarm):
    """One new chat's Enter in `cwd`, after the typing hint when `prewarm`."""
    out = {}
    if prewarm:
        t0 = time.perf_counter()
        _, r = daemon.request("_acpmux/prewarm", {"harness": harness, "cwd": cwd, "wait": True}, timeout=180)
        out["warm_start"] = ms(t0, time.perf_counter())
        entries, _ = pool_entries(daemon, cwd)
        if not any(e.get("state") == "ready" for e in entries):
            raise RuntimeError(f"the hint pooled nothing: {r}")
    # Enter: the pane's session/new for a new chat names the harness and the folder only.
    t0 = time.perf_counter()
    t_ready, r = daemon.request("session/new", {"cwd": cwd, "mcpServers": [],
                                                 "_meta": {"acpmux": {"harness": harness}}}, timeout=180)
    sid = r["sessionId"]
    out["ready"] = ms(t0, t_ready)
    if prewarm:
        entries, _ = pool_entries(daemon, cwd)
        out["pool_hit"] = 0 if any(e.get("state") == "ready" for e in entries) else 1
    io = daemon.io
    try:
        daemon.next += 1
        _, tf, te, _ = acp_turn(io, io.mark(), daemon.next, sid, "Reply with ok.")
        out["first"], out["end"] = ms(t0, tf), ms(t0, te)
        return out
    finally:
        try:
            daemon.request("session/close", {"sessionId": sid}, timeout=20)
        except Exception:
            pass


def abandoned_cost(daemon: Daemon, harness, scratch, folders=5):
    """Typing in `folders` new chats in different folders, sending none: what stays warm."""
    for i in range(folders):
        cwd = os.path.realpath(os.path.join(scratch, f"abandon-{harness}-{i}"))
        os.makedirs(cwd, exist_ok=True)
        daemon.request("_acpmux/prewarm", {"harness": harness, "cwd": cwd, "wait": True}, timeout=180)
    rss = 0
    deadline = time.monotonic() + 5
    while True:
        entries, rss = pool_entries(daemon)
        ready = [e for e in entries if e.get("harness") == harness and e.get("state") == "ready"]
        if rss or time.monotonic() > deadline:
            break
        time.sleep(0.2)
    return {"abandoned_ready": len(ready), "abandoned_rss_mb": round(rss / (1 << 20), 1)}


def proc_table():
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,rss="], capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 3 and all(x.isdigit() for x in f):
            rows[int(f[0])] = (int(f[1]), int(f[2]))
    return rows


def agent_procs(home, session):
    """The pids of `session`'s agent: its host (`hosts/<id>.json`) or the daemon's child, and everything
    under it (the harness and its MCP servers)."""
    rows = proc_table()
    path = os.path.join(home, "hosts", f"{session}.json")
    if not os.path.exists(path):
        # Not hosted: its harness is the daemon's child, and nothing names which one is this
        # session's. Counted as unknown, never as another session's processes.
        return None, 0
    rec = json.load(open(path))
    roots = [p for p in (rec.get("host_pid"), rec.get("harness_pid")) if p]
    tree = list(dict.fromkeys(roots))
    i = 0
    while i < len(tree):
        tree.extend(pid for pid, (ppid, _) in rows.items() if ppid == tree[i] and pid not in tree)
        i += 1
    return [p for p in tree if p in rows], sum(rows[p][1] for p in tree if p in rows)


def alive(pid):
    out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(out) and not out.startswith("Z")


def hibernate_main(args, daemon: Daemon, scratch):
    results = {}
    chats = []
    for h in args.harness.split(","):
        for k in range(args.n):
            cwd = os.path.realpath(os.path.join(scratch, f"hib-{h}-{k}"))
            os.makedirs(cwd, exist_ok=True)
            _, r = daemon.request("session/new", {"cwd": cwd, "mcpServers": [],
                                                   "_meta": {"acpmux": {"harness": h, "policy": "approve-all",
                                                                        "model": MODELS[h]}}}, timeout=180)
            sid = r["sessionId"]
            daemon.next += 1
            acp_turn(daemon.io, daemon.io.mark(), daemon.next, sid, "Reply with ok.")
            pids, rss = agent_procs(daemon.home, sid)
            chats.append({"harness": h, "sid": sid, "pids": pids or [], "procs": None if pids is None else len(pids),
                          "rss_mb": round(rss / 1024, 1),
                          "typed": k % 2})
    print(f"hibernate: {len(chats)} chats idle for {args.idle_wait} s", file=sys.stderr, flush=True)
    time.sleep(args.idle_wait)
    for c in chats:
        pids = c.pop("pids")
        c["left"] = sum(1 for p in pids if alive(p)) if c["procs"] is not None else None
    for c in chats:
        if c["typed"]:
            daemon.request("_acpmux/typing", {"sessionId": c["sid"], "on": True})
            time.sleep(1.0)
        daemon.next += 1
        ts, tf, _, _ = acp_turn(daemon.io, daemon.io.mark(), daemon.next, c["sid"], "Again: reply with ok.")
        c["first"] = ms(ts, tf)
        daemon.next += 1
        ts, tf, _, _ = acp_turn(daemon.io, daemon.io.mark(), daemon.next, c["sid"], "Once more: reply with ok.")
        c["warm_first"] = ms(ts, tf)
    for h in args.harness.split(","):
        rows = [c for c in chats if c["harness"] == h]
        results[h] = {"runs": rows}
    log = open(os.path.join(daemon.home, "daemon.log"), errors="replace").read()
    results["_log"] = [line for line in log.splitlines() if "hibernated" in line or "woke" in line or "wake failed" in line][-40:]
    results["_meta"] = {"label": args.label, "acpmux": args.acpmux, "n": args.n, "mode": "hibernate",
                        "idle_wait": args.idle_wait, "host": socket.gethostname(), "load": os.getloadavg()}
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=1)
    lines = [f"### {args.label or 'run'} hibernate ({socket.gethostname()}, n={args.n}, idle {args.idle_wait} s, "
             f"load {os.getloadavg()[0]:.1f})", "",
             "| harness | typed first | agent procs after the turn | RSS MB | still running after idle | "
             "next prompt to first text (ms) | awake prompt to first text (ms) |", "|---|---|---|---|---|---|---|"]
    for c in chats:
        lines.append(f"| {c['harness']} | {'yes' if c['typed'] else 'no'} | {c['procs']} | {c['rss_mb']} | {c['left']} | "
                     f"{c['first']} | {c['warm_first']} |")
    text = "\n".join(lines) + "\n"
    print(text)
    for line in results["_log"]:
        print("LOG " + line)
    if args.md:
        with open(args.md, "a") as f:
            f.write(text + "\n")


# ---------------------------------------------------------------- main

PREWARM_METRICS = ["ready", "first", "end", "warm_start", "pool_hit"]
METRICS = ["ready", "first", "end", "warm_first", "warm_end", "requests", "request_kb", "request_ktok"]


def pct(xs, q):
    xs = sorted(xs)
    if not xs:
        return None
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return round(xs[lo] + (xs[hi] - xs[lo]) * (k - lo), 1)


def env_for(stand_url, scratch):
    env = dict(os.environ)
    for k in list(env):
        # CLAUDECODE (this script run from a Claude Code session) makes acpmux drop the
        # stand-in's ANTHROPIC_* keys for its children (config::scrub_nested_claude_env).
        if k.startswith(("ANTHROPIC_", "OPENAI_", "CLAUDE_CODE_", "CMUX_", "ACPMUX_", "CODEX_")) or k == "CLAUDECODE":
            env.pop(k)
    codex_home = os.path.join(scratch, "codex-home")
    os.makedirs(codex_home, exist_ok=True)
    with open(os.path.join(codex_home, "config.toml"), "w") as f:
        f.write(f'''model = "{MODELS['codex']}"
model_provider = "bench"
approval_policy = "never"
sandbox_mode = "read-only"
[model_providers.bench]
name = "bench"
base_url = "{stand_url}/v1"
wire_api = "responses"
env_key = "BENCH_API_KEY"
''')
    oc = os.path.join(scratch, "opencode.json")
    with open(oc, "w") as f:
        json.dump({"$schema": "https://opencode.ai/config.json", "model": "bench/m", "small_model": "bench/m",
                   "autoupdate": False, "share": "disabled",
                   "provider": {"bench": {"npm": "@ai-sdk/openai-compatible", "name": "bench",
                                          "options": {"baseURL": f"{stand_url}/v1", "apiKey": "x"},
                                          "models": {"m": {"name": "m"}}}}}, f)
    # A scratch HOME: the person's own ~/.acpx, ~/.config/cmux and logins stay out of both sides.
    home = os.path.join(scratch, "home")
    os.makedirs(home, exist_ok=True)
    env["HOME"] = home
    claude_dir = os.path.join(scratch, "claude-config")
    os.makedirs(claude_dir, exist_ok=True)
    env.update({
        "ANTHROPIC_BASE_URL": stand_url, "ANTHROPIC_API_KEY": "sk-ant-bench-placeholder",
        "CLAUDE_CONFIG_DIR": claude_dir, "DISABLE_AUTOUPDATER": "1", "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "ANTHROPIC_MODEL": "claude-bench", "ANTHROPIC_SMALL_FAST_MODEL": "claude-bench",
        "CODEX_HOME": codex_home, "BENCH_API_KEY": "x",
        "OPENCODE_CONFIG": oc, "OPENCODE_DISABLE_AUTOUPDATE": "1", "OPENCODE_DISABLE_LSP_DOWNLOAD": "1",
        "XDG_CONFIG_HOME": os.path.join(scratch, "xdg-config"),
        "XDG_DATA_HOME": os.path.join(scratch, "xdg-data"), "XDG_STATE_HOME": os.path.join(scratch, "xdg-state"),
    })
    return env


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", required=True)
    ap.add_argument("--harness", default="claude,codex,opencode")
    ap.add_argument("-n", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--mode", choices=["overhead", "prewarm", "hibernate"], default="overhead")
    ap.add_argument("--idle-wait", type=int, default=135, help="--mode hibernate: seconds the chats sit idle")
    ap.add_argument("--json")
    ap.add_argument("--md")
    ap.add_argument("--label", default="")
    ap.add_argument("--daemon-env", action="append", default=[], metavar="NAME=VALUE",
                    help="an environment variable for the acpmux daemon (repeatable)")
    ap.add_argument("--no-agent-tools", action="store_true",
                    help="run the daemon with ACPMUX_AGENT_TOOLS=0: no cmux MCP servers or skills, "
                         "so the numbers are acpmux's plumbing alone")
    args = ap.parse_args()

    stand = StandIn()
    threading.Thread(target=stand.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{stand.server_address[1]}"
    scratch = tempfile.mkdtemp(prefix="acpmux-bench-")
    cwd = os.path.join(scratch, "work")
    os.makedirs(cwd)
    env = env_for(url, scratch)
    home = os.path.join(scratch, "acpmux-home")
    os.makedirs(home)
    extra = dict(kv.split("=", 1) for kv in args.daemon_env)
    if args.no_agent_tools:
        extra["ACPMUX_AGENT_TOOLS"] = "0"
    daemon = Daemon(os.path.abspath(args.acpmux), env, home, extra)
    if args.mode in ("prewarm", "hibernate"):
        try:
            return (prewarm_main if args.mode == "prewarm" else hibernate_main)(args, daemon, scratch)
        finally:
            daemon.close()
            shutil.rmtree(scratch, ignore_errors=True)
    results = {}
    try:
        for h in args.harness.split(","):
            rows = {"raw": [], "acpmux": [], "errors": []}
            for k in range(args.warmup + args.n):
                # Alternate the order so neither side always runs second.
                order = [("raw", lambda: RAW[h](env, cwd)), ("acpmux", lambda: via_acpmux(daemon, h, cwd))]
                if k % 2:
                    order.reverse()
                for side, fn in order:
                    n0, b0 = stand.counts()
                    try:
                        r = fn()
                        n1, b1 = stand.counts()
                        # Model requests and KB this run sent (the turn, and any side request
                        # such as a title, made before the run ended).
                        r["requests"], r["request_kb"] = n1 - n0, round((b1 - b0) / 1024, 1)
                        # Input tokens sent, estimated at 4 bytes per token of request JSON.
                        r["request_ktok"] = round((b1 - b0) / 4000, 1)
                    except Exception as e:  # noqa: BLE001: a bench reports and goes on
                        rows["errors"].append(f"{side} run {k}: {e}")
                        print(f"{h} {side} run {k}: {e}", file=sys.stderr)
                        continue
                    if k >= args.warmup:
                        rows[side].append(r)
                print(f"{h} run {k + 1}/{args.warmup + args.n}", file=sys.stderr, flush=True)
            summary = {}
            for side in ("raw", "acpmux"):
                summary[side] = {m: {"p50": pct([r[m] for r in rows[side]], 0.5),
                                     "p95": pct([r[m] for r in rows[side]], 0.95),
                                     "n": len(rows[side])} for m in METRICS}
            summary["delta_p50"] = {m: (round(summary["acpmux"][m]["p50"] - summary["raw"][m]["p50"], 1)
                                        if summary["raw"][m]["p50"] is not None and summary["acpmux"][m]["p50"] is not None
                                        else None) for m in METRICS}
            summary["errors"] = rows["errors"]
            summary["runs"] = {"raw": rows["raw"], "acpmux": rows["acpmux"]}
            results[h] = summary
    finally:
        daemon.close()
    results["_stand_in_hits"] = stand.hits
    results["_meta"] = {"label": args.label, "acpmux": args.acpmux, "n": args.n,
                        "host": socket.gethostname(), "load": os.getloadavg()}
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=1)
    lines = [f"### {args.label or 'run'} ({socket.gethostname()}, n={args.n}, load {os.getloadavg()[0]:.1f})", "",
             "| harness | metric | raw p50 | raw p95 | acpmux p50 | acpmux p95 | acpmux - raw (p50) |",
             "|---|---|---|---|---|---|---|"]
    for h, s in results.items():
        if h.startswith("_"):
            continue
        for m in METRICS:
            lines.append(f"| {h} | {m} | {s['raw'][m]['p50']} | {s['raw'][m]['p95']} | {s['acpmux'][m]['p50']} | "
                         f"{s['acpmux'][m]['p95']} | {s['delta_p50'][m]} |")
    text = "\n".join(lines) + "\n"
    print(text)
    if args.md:
        with open(args.md, "a") as f:
            f.write(text + "\n")
    shutil.rmtree(scratch, ignore_errors=True)


def prewarm_main(args, daemon: Daemon, scratch):
    results = {}
    for h in args.harness.split(","):
        rows = {"cold": [], "prewarmed": [], "errors": []}
        for k in range(args.warmup + args.n):
            order = ["cold", "prewarmed"]
            if k % 2:
                order.reverse()
            for side in order:
                # A fresh folder per run: no earlier session or hint there.
                cwd = os.path.realpath(os.path.join(scratch, f"enter-{h}-{side}-{k}"))
                os.makedirs(cwd, exist_ok=True)
                try:
                    r = via_acpmux_enter(daemon, h, cwd, side == "prewarmed")
                except Exception as e:  # noqa: BLE001: a bench reports and goes on
                    rows["errors"].append(f"{side} run {k}: {e}")
                    print(f"{h} {side} run {k}: {e}", file=sys.stderr)
                    continue
                if k >= args.warmup:
                    rows[side].append(r)
            print(f"{h} run {k + 1}/{args.warmup + args.n}", file=sys.stderr, flush=True)
        summary = {side: {m: {"p50": pct([r[m] for r in rows[side] if m in r], 0.5),
                              "p95": pct([r[m] for r in rows[side] if m in r], 0.95),
                              "n": len([r for r in rows[side] if m in r])} for m in PREWARM_METRICS}
                   for side in ("cold", "prewarmed")}
        try:
            summary["abandoned"] = abandoned_cost(daemon, h, scratch)
        except Exception as e:  # noqa: BLE001
            summary["abandoned"] = {"error": str(e)}
        summary["errors"] = rows["errors"]
        summary["runs"] = rows
        results[h] = summary
    results["_meta"] = {"label": args.label, "acpmux": args.acpmux, "n": args.n, "mode": "prewarm",
                        "host": socket.gethostname(), "load": os.getloadavg()}
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=1)
    lines = [f"### {args.label or 'run'} prewarm ({socket.gethostname()}, n={args.n}, load {os.getloadavg()[0]:.1f})",
             "", "| harness | metric | cold p50 | cold p95 | prewarmed p50 | prewarmed p95 |", "|---|---|---|---|---|---|"]
    for h, s in results.items():
        if h.startswith("_"):
            continue
        for m in PREWARM_METRICS:
            lines.append(f"| {h} | {m} | {s['cold'][m]['p50']} | {s['cold'][m]['p95']} | "
                         f"{s['prewarmed'][m]['p50']} | {s['prewarmed'][m]['p95']} |")
        a = s["abandoned"]
        lines.append(f"| {h} | typed in 5 folders, sent none | ready {a.get('abandoned_ready')} | "
                     f"{a.get('abandoned_rss_mb')} MB | {a.get('error', '')} | |")
    text = "\n".join(lines) + "\n"
    print(text)
    if args.md:
        with open(args.md, "a") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
