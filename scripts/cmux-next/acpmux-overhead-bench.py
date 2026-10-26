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
Each side's p50/p95/p99 come from scripts/perf-lab/perf_stats.py (agent_bench_report.py).

Usage:
  acpmux-overhead-bench.py --acpmux PATH [--harness claude,codex,opencode] [-n 20]
                           [--json OUT] [--md OUT]
  acpmux-overhead-bench.py --app BUNDLE --out DIR ...   (the lab story acpmux-overhead)

With --app the daemon is the bundle's own acpmux (Contents/Resources/bin/acpmux, unless --acpmux names
another), and --out writes every run's raw samples as cmux-perf-result/v1 (story acpmux-overhead, engine
none: no app runs; the bundle names the build). Per harness and side: each time, the model requests and
the request bytes; `overhead.<time>` is acpmux minus raw of the same run; each per-run series has a
`.missed_runs` count and each side an `errors` count. With --out, the build and host are read before any
harness runs (exit 2 when result-v1 cannot name them), and a run that writes no result-v1 exits non-zero after
its --json and --md reports.
"""

from __future__ import annotations

import argparse
import http.server
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the bench modules, also under `python3 -I`
import agent_bench_report as report  # noqa: E402
import bench_launch  # noqa: E402

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


# ---------------------------------------------------------------- main

METRICS = ["ready", "first", "end", "warm_first", "warm_end", "requests", "request_kb", "request_ktok"]


def measured_build(app, stated):
    """(result-v1 build, host) of the bundle on this Mac. Raises RecordError when the build cannot be named."""
    build = report.perf_result.Build(sha=bench_launch.build_sha(app),
                                     config=bench_launch.build_config(app, bench_launch.main_binary(app), stated),
                                     measure_version=bench_launch.PERF_LAB_MEASURE_VERSION)
    return build, report.perf_result.Host.from_dict(bench_launch.read_host())


def measure_first(args, measure=measured_build):
    """(build, host) of --app before any harness runs, so a bundle or host result-v1 cannot name fails the bench in
    seconds (exit 2), not after the whole run with its samples lost."""
    try:
        return measure(args.app, args.build_config)
    except (bench_launch.RecordError, report.perf_result.ResultError) as error:
        reason = error
    except SystemExit as error:  # bench_launch.main_binary: the bundle has no executable
        reason = error.code
    print(f"acpmux-overhead-bench: --out cannot record result-v1: {reason}", file=sys.stderr)
    sys.exit(2)


def record(args, paired, measured):
    """Every harness's series into one result-v1 file in --out; returns its path, or why nothing was written.
    `paired`: {harness: (its measured runs as {raw, acpmux} pairs, its failed runs per side)}; `measured`: the
    (build, host) of measure_first."""
    entries = []
    for h, (pairs, error_counts) in paired.items():
        entries += report.acpmux_series(h, pairs, error_counts)
    try:
        build, host = measured
        return str(report.write_all(args.out, entries, build, host, session=args.session, root=bench_launch.ROOT))
    except report.perf_result.ResultError as error:
        print(f"result-v1: not recorded: {error}", file=sys.stderr)
        return f"not recorded: {error}"


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


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", help="the acpmux binary (default: the --app bundle's)")
    ap.add_argument("--app", help="the measured bundle: its acpmux, and the build its result-v1 names")
    ap.add_argument("--out", help="write cmux-perf-result/v1 here (needs --app)")
    ap.add_argument("--tag")  # the story runner passes it; the bundle carries the tag
    ap.add_argument("--session", choices=["light"], default="light", help="result-v1 session (the story runner's)")
    ap.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                    help="result-v1 build config of a bench-hooks bundle that does not stamp it")
    ap.add_argument("--harness", default="claude,codex,opencode")
    ap.add_argument("-n", type=int, default=20)
    ap.add_argument("--warmup", type=int, default=2)
    ap.add_argument("--json")
    ap.add_argument("--md")
    ap.add_argument("--label", default="")
    ap.add_argument("--daemon-env", action="append", default=[], metavar="NAME=VALUE",
                    help="an environment variable for the acpmux daemon (repeatable)")
    ap.add_argument("--no-agent-tools", action="store_true",
                    help="run the daemon with ACPMUX_AGENT_TOOLS=0: no cmux MCP servers or skills, "
                         "so the numbers are acpmux's plumbing alone")
    args = ap.parse_args(argv)
    if args.app:
        args.app = os.path.realpath(args.app.rstrip("/"))
        args.acpmux = args.acpmux or os.path.join(args.app, "Contents/Resources/bin/acpmux")
    if not args.acpmux:
        ap.error("name the acpmux binary with --acpmux, or the bundle with --app")
    if args.out and not args.app:
        ap.error("--out needs --app: a result names the build it measured")
    return args


def side_summaries(rows):
    """Both sides' {metric: {p50, p95, p99, n}} and the acpmux-minus-raw p50 per metric."""
    summary = {side: report.acpmux_summary(rows[side], METRICS) for side in ("raw", "acpmux")}
    summary["delta_p50"] = {m: (round(summary["acpmux"][m]["p50"] - summary["raw"][m]["p50"], 1)
                                if summary["raw"][m]["p50"] is not None and summary["acpmux"][m]["p50"] is not None
                                else None) for m in METRICS}
    return summary


def main(argv=None):
    args = parse_args(argv)
    measured = measure_first(args) if args.out else None

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
    results, paired = {}, {}
    try:
        for h in args.harness.split(","):
            rows = {"raw": [], "acpmux": [], "errors": []}
            # Per measured run, both sides (None: that side failed); and the failed runs per side.
            pairs, error_counts = [], {"raw": 0, "acpmux": 0}
            for k in range(args.warmup + args.n):
                pair = {"raw": None, "acpmux": None}
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
                        r["request_bytes"] = b1 - b0
                        # Input tokens sent, estimated at 4 bytes per token of request JSON.
                        r["request_ktok"] = round((b1 - b0) / 4000, 1)
                    except Exception as e:  # noqa: BLE001: a bench reports and goes on
                        rows["errors"].append(f"{side} run {k}: {e}")
                        error_counts[side] += 1
                        print(f"{h} {side} run {k}: {e}", file=sys.stderr)
                        continue
                    if k >= args.warmup:
                        rows[side].append(r)
                        pair[side] = r
                if k >= args.warmup:
                    pairs.append(pair)
                print(f"{h} run {k + 1}/{args.warmup + args.n}", file=sys.stderr, flush=True)
            summary = side_summaries(rows)
            summary["errors"] = rows["errors"]
            summary["runs"] = {"raw": rows["raw"], "acpmux": rows["acpmux"]}
            results[h], paired[h] = summary, (pairs, error_counts)
    finally:
        daemon.close()
    results["_stand_in_hits"] = stand.hits
    results["_meta"] = {"label": args.label, "acpmux": args.acpmux, "n": args.n,
                        "host": socket.gethostname(), "load": os.getloadavg()}
    if args.out:
        results["_meta"]["result_v1"] = record(args, paired, measured)
    if args.json:
        with open(args.json, "w") as f:
            json.dump(results, f, indent=1)
    lines = [f"### {args.label or 'run'} ({socket.gethostname()}, n={args.n}, load {os.getloadavg()[0]:.1f})", "",
             "| harness | metric | raw p50 | raw p95 | raw p99 | acpmux p50 | acpmux p95 | acpmux p99 "
             "| acpmux - raw (p50) |",
             "|---|---|---|---|---|---|---|---|---|"]
    for h, s in results.items():
        if h.startswith("_"):
            continue
        for m in METRICS:
            raw, via = s["raw"][m], s["acpmux"][m]
            lines.append(f"| {h} | {m} | {raw['p50']} | {raw['p95']} | {raw['p99']} | {via['p50']} | {via['p95']} "
                         f"| {via['p99']} | {s['delta_p50'][m]} |")
    text = "\n".join(lines) + "\n"
    print(text)
    if args.md:
        with open(args.md, "a") as f:
            f.write(text + "\n")
    shutil.rmtree(scratch, ignore_errors=True)
    if args.out and not report.any_written({"result_v1": results["_meta"]["result_v1"]}):
        sys.exit(f"RESULT-V1 FAIL: {results['_meta']['result_v1']}")


if __name__ == "__main__":
    main()
