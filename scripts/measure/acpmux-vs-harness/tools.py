#!/usr/bin/env python3
"""Tool-server bench: the built-in tool execution path of Claude Code and Codex, raw vs through acpmux.

Not MCP: the harness's own shell tool (Claude `Bash`, Codex `exec_command`), file read (Claude
`Read`; Codex has no read tool, so `cat` through exec_command) and edit (Claude `Edit`; Codex
`apply_patch`). A local stand-in model answers each chat with a scripted list of tool calls, so every
number is the client side: the harness (and acpmux), the tool's process and its sandbox; never a model.

Four sides: claude-raw, codex-raw (both driven as acpmux drives them: `claude -p --input-format
stream-json`, `codex app-server`), acpmux+claude, acpmux+codex (an isolated acpmux daemon, session/new,
session/prompt). Permission and approval requests are answered "allow" on every side.

Measured per side (one chat each unless noted):
  first_ms         the first shell call of a chat (`echo ok`): ms from the stand-in sending the call to
                   the next model request carrying its result; p50 over 7 chats
  later_ms         shell calls 2..100 of one chat (p50 / p95 over 99 calls)
  procs_per_call   new processes under the harness tree per `/bin/true` call, seen by a tight /proc sampler
                   (a lower bound: a process gone before the sampler read it is missed)
  shell_kind       `echo $$` twice: same pid = one persistent shell, else a fresh process per call
  ancestry         the process chain of a shell call, up to the tree root (sandbox helpers show here)
  left_after_turn  processes under the tree after the turn ended + 1 s that were not there before it
  read_ms / edit_ms  file read and edit calls, p50 / p95 over 20
  parallel10_s     10 `sleep 0.3` calls issued in ONE model reply: ms until all results are back
                   (300 = fully parallel, 3000+ = serialised); p50 over 5 turns
  rss_growth_mb    tree RSS after 100 shell calls minus after the 20th (+1 s settle; the tree has settled by then)

Usage (pinned to cores 4-7, as the other benches):
  taskset -c 4-7 python3 scripts/measure/acpmux-vs-harness/tools.py --acpmux ~/.local/bin/acpmux \
      [--sides claude-raw,codex-raw,acpmux+claude,acpmux+codex] [--json OUT.json] [--md OUT.md]
Output defaults to .build/acpmux-vs-harness/tools.{json,md} under the repo root.
Reuses scripts/cmux-next/acpmux-overhead-bench.py (stand-in, env_for, Daemon, Lines).
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
spec = importlib.util.spec_from_file_location("acpmux_overhead_bench", os.path.join(ROOT, "scripts", "cmux-next", "acpmux-overhead-bench.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)
Lines = bench.Lines

MARK_RE = re.compile(r"TB_RUN_([a-z0-9]+)")
# A model id Codex knows tools for (an unknown id lists none); Claude takes any.
bench.MODELS["codex"] = "gpt-5.5"
PAGE = os.sysconf("SC_PAGE_SIZE")

# ---------------------------------------------------------------- /proc


def proc_rows(light=False):
    """pid -> (ppid, rss_bytes, comm, state) for every process; light skips statm (rss 0): a faster scan."""
    rows = {}
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            with open(f"/proc/{d}/stat") as f:
                s = f.read()
            r = s.rindex(")")
            comm = s[s.index("(") + 1:r]
            rest = s[r + 2:].split()
            rss = 0
            if not light:
                with open(f"/proc/{d}/statm") as f:
                    rss = int(f.read().split()[1]) * PAGE
            rows[int(d)] = (int(rest[1]), rss, comm, rest[0])
        except (OSError, ValueError, IndexError):
            pass
    return rows


def descend(rows, roots):
    seen = [r for r in roots if r in rows]
    i = 0
    while i < len(seen):
        seen.extend(p for p, v in rows.items() if v[0] == seen[i] and p not in seen)
        i += 1
    return seen


def cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return f.read().replace(b"\0", b" ").decode("utf-8", "replace").strip()[:160]
    except OSError:
        return ""


def tree_rss(roots):
    rows = proc_rows()
    t = descend(rows, roots())
    return sum(rows[p][1] for p in t) / 1e6, len(t)


class Sampler(threading.Thread):
    """Distinct processes started under the tree since the baseline, polled as fast as /proc lists go:
    only pids above the last one handed out at the start are read (new processes get higher pids), each once."""

    def __init__(self, roots, base):
        super().__init__(daemon=True)
        self.roots, self.base, self.stop_ev = roots, set(base), threading.Event()
        self.floor = int(open("/proc/loadavg").read().split()[4])  # the last pid handed out
        self.seen: dict[int, str] = {}
        self.scans = 0

    def run(self):
        member = set(descend(proc_rows(light=True), self.roots()))
        cache: set[int] = set()
        while not self.stop_ev.is_set():
            self.scans += 1
            fresh = sorted(int(d) for d in os.listdir("/proc") if d.isdigit() and int(d) > self.floor and int(d) not in cache)
            for p in fresh:
                try:
                    with open(f"/proc/{p}/stat") as f:
                        st = f.read()
                except OSError:
                    continue  # gone before it was read: missed
                cache.add(p)
                r = st.rindex(")")
                ppid = int(st[r + 2:].split()[1])
                if ppid in member:
                    member.add(p)
                    self.seen[p] = st[st.index("(") + 1:r] + " | " + cmdline(p)

    def finish(self):
        self.stop_ev.set()
        self.join(5)
        return self.seen


# ---------------------------------------------------------------- scripted stand-in

ANCESTRY = ('p=$$; while [ "$p" -gt 1 ]; do printf "%s:%s\\n" "$p" "$(tr "\\0\\n" "  " </proc/$p/cmdline | cut -c1-70)"; '
            'p=$(awk \'{print $4}\' /proc/$p/stat); done')


class Run:
    def __init__(self, steps, hooks=None):
        self.steps = steps          # list of groups; a group is a list of ops (parallel calls)
        self.hooks = hooks or {}    # step index -> fn(run), called before that step is sent; len(steps) = end
        self.idx = 0
        self.pending: dict[str, tuple[float, dict]] = {}
        self.sent_at = 0.0
        self.rows: list[dict] = []   # one per group: {kind, n, ms, results, errors}
        self.done = threading.Event()
        self.error = None


def op_call(kind_harness, op):
    """(tool name, input) of an op for a harness. Ops: sh cmd | read path | edit path old new."""
    k = op["op"]
    if kind_harness == "claude":
        if k == "sh":
            return "Bash", {"command": op["cmd"], "description": "bench"}
        if k == "read":
            return "Read", {"file_path": op["path"]}
        return "Edit", {"file_path": op["path"], "old_string": op["old"], "new_string": op["new"]}
    if k == "sh":
        return "exec_command", {"cmd": op["cmd"], "yield_time_ms": 10000}
    if k == "read":
        return "exec_command", {"cmd": "cat " + op["path"], "yield_time_ms": 10000}
    rel = os.path.basename(op["path"])
    return "apply_patch", f"*** Begin Patch\n*** Update File: {rel}\n@@\n-{op['old']} line\n+{op['new']} line\n*** End Patch\n"


class Script:
    """The stand-in's tool script: runs by marker; steps advance when the previous group's results arrive."""

    def __init__(self):
        self.runs: dict[str, Run] = {}
        self.lock = threading.Lock()

    def step(self, harness, marker, result_ids: dict[str, dict], t_arrive):
        """The next group of (id, name, input) calls, or None (finish with text)."""
        run = self.runs.get(marker)
        if run is None:
            return None
        with self.lock:
            if run.pending:
                if not set(run.pending) <= set(result_ids):
                    run.error = f"partial results: have {sorted(result_ids)} want {sorted(run.pending)}"
                    run.done.set()
                    return None
                group = run.rows[-1]
                group["ms"] = round((t_arrive - run.sent_at) * 1000.0, 2)
                group["results"] = [str(result_ids[i].get("text", ""))[:600] for i in run.pending]
                group["errors"] = sum(1 for i in run.pending if result_ids[i].get("is_error"))
                if group["errors"]:
                    group["err_text"] = [str(result_ids[i].get("text"))[:200] for i in run.pending if result_ids[i].get("is_error")][:1]
                run.pending = {}
            hook = run.hooks.get(run.idx)
        if hook:
            hook(run)
        with self.lock:
            if run.idx >= len(run.steps):
                run.done.set()
                return None
            ops = run.steps[run.idx]
            run.idx += 1
            calls = []
            for op in ops:
                name, inp = op_call(harness, op)
                cid = ("toolu_tb_" if harness == "claude" else "call_tb_") + uuid.uuid4().hex[:12]
                calls.append((cid, name, inp))
            run.rows.append({"kind": ops[0]["op"], "n": len(ops), "ms": None})
            for cid, _, _ in calls:
                run.pending[cid] = (0.0, {})
            run.sent_at = time.perf_counter()
            return calls


SCRIPT = Script()


def claude_results(body):
    out, last = {}, None
    for m in body.get("messages") or []:
        c = m.get("content")
        if m.get("role") != "user" or not isinstance(c, list):
            continue
        for b in c:
            if isinstance(b, dict) and b.get("type") == "tool_result":
                inner = b.get("content")
                text = inner if isinstance(inner, str) else "".join(x.get("text", "") for x in inner or [] if isinstance(x, dict))
                out[b.get("tool_use_id")] = {"text": text, "is_error": bool(b.get("is_error"))}
    for m in body.get("messages") or []:
        if m.get("role") != "user":
            continue
        c = m.get("content")
        for b in c if isinstance(c, list) else [{"type": "text", "text": c or ""}]:
            if isinstance(b, dict) and b.get("type") == "text":
                hit = MARK_RE.findall(b.get("text") or "")
                if hit:
                    last = hit[-1]
    return last, out


def responses_results(body):
    out, last = {}, None
    items = body.get("input") if isinstance(body.get("input"), list) else []
    for it in items:
        if not isinstance(it, dict):
            continue
        if it.get("type") in ("function_call_output", "custom_tool_call_output"):
            o = it.get("output")
            text = o if isinstance(o, str) else json.dumps(o)
            out[it.get("call_id")] = {"text": text, "is_error": text.startswith(("apply_patch verification failed", "failed"))}
        elif it.get("role") == "user":
            c = it.get("content")
            for x in c if isinstance(c, list) else [{"text": c or ""}]:
                if isinstance(x, dict):
                    hit = MARK_RE.findall(x.get("text") or "")
                    if hit:
                        last = hit[-1]
    return last, out


_orig_anthropic = bench.Handler.anthropic
_orig_responses = bench.Handler.openai_responses
_orig_post = bench.Handler.do_POST


def do_post(self):
    self.t_arrive = time.perf_counter()
    return _orig_post(self)


def anthropic(self, body):
    names = [t.get("name") for t in body.get("tools") or []]
    if "Bash" not in names or not body.get("stream"):
        return _orig_anthropic(self, body)
    marker, results = claude_results(body)
    calls = SCRIPT.step("claude", marker, results, self.t_arrive) if marker else None
    if not calls:
        return _orig_anthropic(self, body)
    model = body.get("model", "claude-bench")
    usage = {"input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
    events = [("message_start", {"type": "message_start", "message": {"id": "msg_bench", "type": "message", "role": "assistant", "model": model,
                                                                      "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}})]
    for i, (cid, name, inp) in enumerate(calls):
        events += [
            ("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "tool_use", "id": cid, "name": name, "input": {}}}),
            ("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "input_json_delta", "partial_json": json.dumps(inp)}}),
            ("content_block_stop", {"type": "content_block_stop", "index": i})]
    events += [("message_delta", {"type": "message_delta", "delta": {"stop_reason": "tool_use", "stop_sequence": None}, "usage": {"output_tokens": 1}}),
               ("message_stop", {"type": "message_stop"})]
    payload = bench.sse(events)
    SCRIPT.runs[marker].sent_at = time.perf_counter()
    self.reply(200, payload, "text/event-stream")


def responses(self, body):
    if (body.get("text") or {}).get("format") or not body.get("tools"):
        return _orig_responses(self, body)
    marker, results = responses_results(body)
    calls = SCRIPT.step("codex", marker, results, self.t_arrive) if marker else None
    if not calls:
        return _orig_responses(self, body)
    usage = {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 1,
             "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 11}
    events = [("response.created", {"type": "response.created", "response": {"id": "resp_tb", "status": "in_progress"}})]
    items = []
    for i, (cid, name, inp) in enumerate(calls):
        if name == "apply_patch":
            item = {"type": "custom_tool_call", "id": "ctc_" + cid, "call_id": cid, "name": name, "input": inp, "status": "completed"}
            events += [("response.output_item.added", {"type": "response.output_item.added", "output_index": i, "item": {**item, "input": "", "status": "in_progress"}}),
                       ("response.output_item.done", {"type": "response.output_item.done", "output_index": i, "item": item})]
        else:
            args = json.dumps(inp)
            item = {"type": "function_call", "id": "fc_" + cid, "call_id": cid, "name": name, "arguments": args, "status": "completed"}
            events += [("response.output_item.added", {"type": "response.output_item.added", "output_index": i, "item": {**item, "arguments": "", "status": "in_progress"}}),
                       ("response.function_call_arguments.delta", {"type": "response.function_call_arguments.delta", "item_id": item["id"], "output_index": i, "delta": args}),
                       ("response.function_call_arguments.done", {"type": "response.function_call_arguments.done", "item_id": item["id"], "output_index": i, "arguments": args}),
                       ("response.output_item.done", {"type": "response.output_item.done", "output_index": i, "item": item})]
        items.append(item)
    events.append(("response.completed", {"type": "response.completed", "response": {"id": "resp_tb", "status": "completed", "output": items, "usage": usage}}))
    payload = bench.sse(events)
    SCRIPT.runs[marker].sent_at = time.perf_counter()
    self.reply(200, payload, "text/event-stream")


bench.Handler.do_POST = do_post
bench.Handler.anthropic = anthropic
bench.Handler.openai_responses = responses

# ---------------------------------------------------------------- chats (one per side kind)


class Chat:
    harness = ""

    def roots(self):
        raise NotImplementedError

    def prompt(self, text, timeout=600):
        raise NotImplementedError

    def close(self):
        pass


def allow_loop(io, stop_ev, handle):
    def run():
        i = 0
        while not stop_ev.is_set():
            try:
                _, m, i = io.wait(lambda m: handle(m) is not None, timeout=0.5, start=i)
            except TimeoutError:
                continue
            except RuntimeError:
                return
    threading.Thread(target=run, daemon=True).start()


class RawClaudeChat(Chat):
    harness = "claude"

    def __init__(self, env, cwd):
        argv = ["claude", "-p", "--model", bench.MODELS["claude"], "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--replay-user-messages", "--permission-prompt-tool", "stdio",
                "--session-id", str(uuid.uuid4()), "--permission-mode", "default"]
        self.p = bench.spawn(argv, env, cwd)
        self.io = Lines(self.p.stdout, self.p.stdin)
        self.stop_ev = threading.Event()
        self.io.send({"type": "control_request", "request_id": "boot-1", "request": {"subtype": "initialize", "hooks": {}}})
        _, _, self.i = self.io.wait(lambda m: m.get("type") == "control_response")

        def handle(m):
            if m.get("type") == "control_request" and m.get("request", {}).get("subtype") == "can_use_tool":
                self.io.send({"type": "control_response", "response": {"subtype": "success", "request_id": m["request_id"],
                                                                        "response": {"behavior": "allow", "updatedInput": m["request"].get("input", {})}}})
                return True
        allow_loop(self.io, self.stop_ev, handle)

    def roots(self):
        return [self.p.pid]

    def prompt(self, text, timeout=600):
        start = self.io.mark()
        self.io.send({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}})
        self.io.wait(lambda m: m.get("type") == "result", timeout=timeout, start=start)

    def close(self):
        self.stop_ev.set()
        bench.stop(self.p)


class RawCodexChat(Chat):
    harness = "codex"

    def __init__(self, env, cwd):
        self.p = bench.spawn(["codex", "app-server"], env, cwd)
        self.io = Lines(self.p.stdout, self.p.stdin)
        self.stop_ev = threading.Event()
        self.io.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "acpmux-bench", "version": "1"}}})
        self.io.wait(lambda m: m.get("id") == 1)
        self.io.send({"jsonrpc": "2.0", "method": "initialized"})
        self.io.send({"jsonrpc": "2.0", "id": 2, "method": "thread/start", "params": {"cwd": cwd}})
        _, m, _ = self.io.wait(lambda m: m.get("id") == 2)
        if "error" in m:
            raise RuntimeError(f"thread/start: {m['error']}")
        self.thread = m["result"]["thread"]["id"]
        self.rid = 10

        def handle(m):
            if m.get("method") and m.get("id") is not None:  # a server request: an approval
                self.io.send({"jsonrpc": "2.0", "id": m["id"], "result": {"decision": "accept"}})
                return True
        allow_loop(self.io, self.stop_ev, handle)

    def roots(self):
        return [self.p.pid]

    def prompt(self, text, timeout=600):
        self.rid += 1
        start = self.io.mark()
        self.io.send({"jsonrpc": "2.0", "id": self.rid, "method": "turn/start",
                      "params": {"threadId": self.thread, "input": [{"type": "text", "text": text}]}})
        self.io.wait(lambda m: m.get("method") == "turn/completed", timeout=timeout, start=start)

    def close(self):
        self.stop_ev.set()
        bench.stop(self.p)


class AcpChat(Chat):
    def __init__(self, daemon, harness, cwd):
        self.d, self.harness, self.stop_ev = daemon, harness, threading.Event()
        _, r = daemon.request("session/new", {"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {
            "harness": harness, "policy": "approve-all", "model": bench.MODELS[harness]}}})
        self.sid = r["sessionId"]

        def handle(m):
            if m.get("method") == "session/request_permission" and m.get("id") is not None:
                opts = m.get("params", {}).get("options", [])
                pick = next((o for o in opts if str(o.get("kind", "")).startswith("allow")), opts[0] if opts else {})
                self.d.io.send({"jsonrpc": "2.0", "id": m["id"], "result": {"outcome": {"outcome": "selected", "optionId": pick.get("optionId")}}})
                return True
        allow_loop(self.d.io, self.stop_ev, handle)

    def roots(self):
        rows = proc_rows()
        roots = []
        path = os.path.join(self.d.home, "hosts", f"{self.sid}.json")
        if os.path.exists(path):
            try:
                rec = json.load(open(path))
                roots += [p for p in (rec.get("host_pid"), rec.get("harness_pid")) if p and p in rows]
            except (OSError, ValueError):
                pass
        return roots or [self.d.p.pid]  # the session's own host and harness; the daemon (shared, and its warm pool) only until they exist

    def daemon_rss_mb(self):
        return round(proc_rows().get(self.d.p.pid, (0, 0))[1] / 1e6, 1)

    def prompt(self, text, timeout=600):
        self.d.next += 1
        rid, start = self.d.next, self.d.io.mark()
        self.d.io.send({"jsonrpc": "2.0", "id": rid, "method": "session/prompt",
                        "params": {"sessionId": self.sid, "prompt": [{"type": "text", "text": text}]}})
        _, m, _ = self.d.io.wait(lambda m: m.get("id") == rid, timeout=timeout, start=start)
        if "error" in m:
            raise RuntimeError(f"session/prompt: {m['error']}")

    def close(self):
        self.stop_ev.set()
        try:
            self.d.request("session/close", {"sessionId": self.sid}, timeout=20)
        except Exception:
            pass


# ---------------------------------------------------------------- measurement


def pct(xs, q):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    return round(xs[min(len(xs) - 1, int(q * len(xs)))], 2)


def run_turn(chat, steps, hooks=None, timeout=600):
    marker = uuid.uuid4().hex[:10]
    run = Run(steps, hooks)
    SCRIPT.runs[marker] = run
    try:
        chat.prompt(f"TB_RUN_{marker}: run the tool script.", timeout)
    finally:
        run.done.wait(5)
    return run


def sh(cmd):
    return [{"op": "sh", "cmd": cmd}]


def measure_side(side, mk_chat, scratch, args):
    out = {"errors": []}
    work = os.path.join(scratch, side.replace("+", "_"), "work")
    os.makedirs(work)
    target = os.path.join(work, "f.txt")
    with open(target, "w") as f:
        f.write("AAA line\nsecond line\n")
    for k in range(args.rw):  # one file per read: acpmux answers a repeat read of an unchanged file from its dedupe stub
        with open(os.path.join(work, f"r{k}.txt"), "w") as f:
            f.write(f"file {k}\n" * 50)

    def fresh():
        return mk_chat(work)

    # 1. first calls: n small chats, 3 `echo ok` each
    firsts, seconds = [], []
    for _ in range(args.first_chats):
        c = fresh()
        try:
            r = run_turn(c, [sh("echo ok")] * 3)
            if len(r.rows) == 3 and all(x["ms"] is not None for x in r.rows):
                firsts.append(r.rows[0]["ms"])
                seconds += [r.rows[1]["ms"], r.rows[2]["ms"]]
            else:
                out["errors"].append(f"first-chat: {r.error or r.rows}")
        except Exception as e:  # noqa: BLE001
            out["errors"].append(f"first-chat: {e}")
        finally:
            c.close()
    out["first_ms"] = {"p50": pct(firsts, 0.5), "min": pct(firsts, 0), "max": pct(firsts, 1), "n": len(firsts)}

    # 2. one chat, N shell calls: later-call latency and RSS growth
    c = fresh()
    try:
        rss = {}

        def at(tag):
            def hook(run):
                if tag == "end":
                    time.sleep(1.0)
                rss[tag] = tree_rss(c.roots)
            return hook
        n = args.calls
        r = run_turn(c, [sh("echo ok")] * n, {20: at("five"), n: at("end")})
        ms_ = [x["ms"] for x in r.rows if x["ms"] is not None]
        out["first_in_long_chat_ms"] = ms_[0] if ms_ else None
        out["later_ms"] = {"p50": pct(ms_[1:], 0.5), "p95": pct(ms_[1:], 0.95), "n": len(ms_) - 1}
        if "five" in rss and "end" in rss:
            out["rss_growth_mb"] = round(rss["end"][0] - rss["five"][0], 1)
            out["rss_mb_five"], out["rss_mb_end"] = round(rss["five"][0], 1), round(rss["end"][0], 1)
            out["daemon_rss_mb"] = c.daemon_rss_mb() if hasattr(c, "daemon_rss_mb") else None
            out["tree_procs_five"], out["tree_procs_end"] = rss["five"][1], rss["end"][1]
        if r.error or len(r.rows) < n:
            out["errors"].append(f"long chat: {r.error or f'{len(r.rows)}/{n} calls'}")
    except Exception as e:  # noqa: BLE001
        out["errors"].append(f"long chat: {e}")
    finally:
        c.close()

    # 3. one chat: ancestry, spawn counts, read, edit, parallel; then what is left after the turn
    c = fresh()
    try:
        base = {}
        samp = {}

        def baseline(run):
            rows = proc_rows()
            base["pids"] = set(descend(rows, c.roots()))

        def observe(run):  # the next call is `sleep 1.5`: snapshot its tree while it runs
            def snap():
                time.sleep(0.5)
                rows = proc_rows()
                t = descend(rows, c.roots())
                base["during"] = [f"{rows[p][2]} | {cmdline(p)}" for p in t if p not in base["pids"]]
            threading.Thread(target=snap, daemon=True).start()

        def lastpid():
            return int(open("/proc/loadavg").read().split()[4])

        def samp_start(run):
            t0 = lastpid()
            time.sleep(1.0)
            samp["idle_rate"] = lastpid() - t0
            idle = Sampler(c.roots, base["pids"])  # a control: what the tree starts with no call running
            idle.start()
            time.sleep(1.0)
            samp["idle_seen"] = len(idle.finish())
            samp["pid0"] = lastpid()
            samp["t0"] = time.perf_counter()
            samp["s"] = Sampler(c.roots, base["pids"])
            samp["s"].start()
            time.sleep(0.05)

        def samp_stop(run):
            samp["seen"] = samp["s"].finish()
            samp["scans"] = samp["s"].scans
            samp["dur"] = time.perf_counter() - samp["t0"]
            samp["pid_delta"] = lastpid() - samp["pid0"] - samp["idle_rate"] * (time.perf_counter() - samp["t0"])

        def left_hook(run):
            time.sleep(1.0)
            rows = proc_rows()
            t = descend(rows, c.roots())
            base["left"] = [f"{rows[p][2]}({rows[p][3]}) | {cmdline(p)}" for p in t if p not in base["pids"]]

        edit = lambda old, new: [{"op": "edit", "path": target, "old": old, "new": new}]  # noqa: E731
        nrw = args.rw
        steps = [sh("echo $$"), sh("echo $$"), sh(ANCESTRY), sh("sleep 1.5"),
                 *([sh("/bin/true")] * 20),
                 *[[{"op": "read", "path": os.path.join(work, f"r{k}.txt")}] for k in range(nrw)],
                 *[edit("AAA", "BBB") if k % 2 == 0 else edit("BBB", "AAA") for k in range(nrw)],
                 *([[{"op": "sh", "cmd": "sleep 0.3"}] * 10] * args.par_turns)]
        hooks = {1: baseline, 3: observe, 4: samp_start, 24: samp_stop, len(steps): left_hook}
        r = run_turn(c, steps, hooks)
        rows = r.rows
        if r.error or len(rows) < len(steps):
            out["errors"].append(f"tool chat: {r.error or f'{len(rows)}/{len(steps)} steps'}")
        res = lambda k: (rows[k].get("results") or [""])[0].strip() if k < len(rows) else ""  # noqa: E731
        out["shell_pids"] = [res(0).splitlines()[-1:] , res(1).splitlines()[-1:]]
        out["shell_kind"] = "persistent shell (same pid)" if res(0) and res(0) == res(1) else "fresh process per call"
        anc = res(2)
        anc = anc.split("Output:", 1)[-1]
        chain = [x for x in anc.splitlines() if re.match(r"^\d+:", x)]
        out["ancestry"] = chain[:next((i for i, x in enumerate(chain) if "tools.py" in x), len(chain))]
        out["tree_during_sleep"] = base.get("during")
        seen = samp.get("seen", {})
        out["procs_per_call"] = round(len(seen) / 20.0, 2)
        out["pid_counter_per_call"] = round(samp.get("pid_delta", 0) / 20.0, 1)
        out["idle_procs_per_s"] = samp.get("idle_seen")
        out["sampler_scan_ms"] = round(samp.get("dur", 0) * 1000 / max(1, samp.get("scans", 1)), 1)
        out["spawned_seen"] = sorted(set(v.split(" | ")[0] for v in seen.values()))
        out["spawned_sample"] = list(seen.values())[:12]
        out["left_after_turn"] = len(base.get("left", []))
        out["left_detail"] = base.get("left", [])[:12]
        out["true_ms"] = {"p50": pct([x["ms"] for x in rows[4:24]], 0.5)}
        rd, ed = rows[24:24 + nrw], rows[24 + nrw:24 + 2 * nrw]
        out["read_ms"] = {"p50": pct([x["ms"] for x in rd], 0.5), "p95": pct([x["ms"] for x in rd], 0.95), "n": len(rd),
                          "errors": sum(x.get("errors", 0) for x in rd), "sample": res(24)[:80],
                          "err_text": [e for x in rd for e in x.get("err_text", [])][:2]}
        out["edit_ms"] = {"p50": pct([x["ms"] for x in ed], 0.5), "p95": pct([x["ms"] for x in ed], 0.95), "n": len(ed),
                          "errors": sum(x.get("errors", 0) for x in ed), "err_text": [e for x in ed for e in x.get("err_text", [])][:2], "sample": (ed[0].get("results") or [""])[0][:160] if ed else ""}
        par = rows[24 + 2 * nrw:]
        out["parallel10_ms"] = {"p50": pct([x["ms"] for x in par], 0.5), "all": [x["ms"] for x in par],
                                "errors": sum(x.get("errors", 0) for x in par)}
    except Exception as e:  # noqa: BLE001
        out["errors"].append(f"tool chat: {e}")
    finally:
        c.close()
    return out


def fmt(v, unit=""):
    return "n/a" if v is None else f"{v}{unit}"


def render(results, meta):
    sides = [s for s in results]
    head = "| metric | " + " | ".join(sides) + " |\n|---|" + "---|" * len(sides) + "\n"

    def row(name, f):
        cells = []
        for s in sides:
            try:
                cells.append(str(f(results[s])))
            except Exception:  # noqa: BLE001
                cells.append("n/a")
        return f"| {name} | " + " | ".join(cells) + " |\n"
    t = f"### Tool servers: raw vs acpmux ({meta['host']}, cpus 4-7, load {meta['load'][0]:.1f}, n calls {meta['calls']})\n\n" + head
    t += row("shell call, first in chat (ms p50, n=chats)", lambda r: f"{r['first_ms']['p50']} (n={r['first_ms']['n']})")
    t += row("shell call, later (ms p50 / p95)", lambda r: f"{r['later_ms']['p50']} / {r['later_ms']['p95']}")
    t += row("shell kind", lambda r: r["shell_kind"])
    t += row("new procs per `/bin/true` call (sampled, lower bound)", lambda r: r["procs_per_call"])
    t += row("pid-counter delta per call (VM-wide, idle-rate subtracted; noisy)", lambda r: r["pid_counter_per_call"])
    t += row("background procs started per s with no call (control)", lambda r: r["idle_procs_per_s"])
    t += row("procs seen", lambda r: ", ".join(r["spawned_seen"]) or "none seen")
    t += row("procs left after turn (+1 s)", lambda r: r["left_after_turn"])
    t += row("file read call (ms p50 / p95)", lambda r: f"{r['read_ms']['p50']} / {r['read_ms']['p95']}" + (f" ({r['read_ms']['errors']} err)" if r['read_ms']['errors'] else ""))
    t += row("file edit call (ms p50 / p95)", lambda r: f"{r['edit_ms']['p50']} / {r['edit_ms']['p95']}" + (f" ({r['edit_ms']['errors']} err)" if r['edit_ms']['errors'] else ""))
    t += row("10 parallel `sleep 0.3` in one reply (ms p50)", lambda r: r["parallel10_ms"]["p50"])
    t += row("tree RSS after 20th call (MB)", lambda r: r["rss_mb_five"])
    t += row("tree RSS growth after 100 calls (MB)", lambda r: r["rss_growth_mb"])
    t += row("acpmux daemon RSS, shared (MB)", lambda r: r["daemon_rss_mb"] if r.get("daemon_rss_mb") is not None else "-")
    t += row("tree procs (20th call -> 100th)", lambda r: f"{r['tree_procs_five']} -> {r['tree_procs_end']}")
    t += row("errors", lambda r: "; ".join(r["errors"]) or "none")
    t += "\nAncestry of one shell call (leaf first):\n"
    for s in sides:
        t += f"\n{s}:\n```\n" + "\n".join(results[s].get("ancestry") or ["n/a"]) + "\n```\n"
    t += "\nProcesses under the tree while `sleep 1.5` ran (not there before):\n"
    for s in sides:
        t += f"\n{s}: " + "; ".join(results[s].get("tree_during_sleep") or ["n/a"]) + "\n"
    return t


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", required=True)
    ap.add_argument("--sides", default="claude-raw,codex-raw,acpmux+claude,acpmux+codex")
    ap.add_argument("--calls", type=int, default=100, help="shell calls in the long chat")
    ap.add_argument("--first-chats", type=int, default=7)
    ap.add_argument("--rw", type=int, default=20, help="read and edit calls")
    ap.add_argument("--par-turns", type=int, default=5)
    ap.add_argument("--json", default=os.path.join(ROOT, ".build", "acpmux-vs-harness", "tools.json"))
    ap.add_argument("--md", default=os.path.join(ROOT, ".build", "acpmux-vs-harness", "tools.md"))
    args = ap.parse_args()

    stand = bench.StandIn()
    threading.Thread(target=stand.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{stand.server_address[1]}"
    scratch = tempfile.mkdtemp(prefix="atb-", dir="/tmp")  # short: a unix socket path is capped near 108 bytes
    env = bench.env_for(url, scratch)
    cfg = os.path.join(scratch, "codex-home", "config.toml")
    text = open(cfg).read().replace('sandbox_mode = "read-only"', 'sandbox_mode = "workspace-write"')
    open(cfg, "w").write(text)
    home = os.path.join(scratch, "acpmux-home")
    os.makedirs(home)
    os.chmod(home, 0o700)
    daemon = bench.Daemon(os.path.abspath(args.acpmux), env, home, {})
    makers = {
        "claude-raw": lambda cwd: RawClaudeChat(env, cwd),
        "codex-raw": lambda cwd: RawCodexChat(env, cwd),
        "acpmux+claude": lambda cwd: AcpChat(daemon, "claude", cwd),
        "acpmux+codex": lambda cwd: AcpChat(daemon, "codex", cwd),
    }
    results = {}
    try:
        for side in args.sides.split(","):
            print(f"== {side}", file=sys.stderr, flush=True)
            results[side] = measure_side(side, makers[side], scratch, args)
            print(json.dumps({k: v for k, v in results[side].items() if k in ("first_ms", "later_ms", "errors")}), file=sys.stderr, flush=True)
    finally:
        daemon.close()
        shutil.rmtree(scratch, ignore_errors=True)
    meta = {"host": socket.gethostname(), "load": os.getloadavg(), "calls": args.calls, "acpmux": args.acpmux}
    os.makedirs(os.path.dirname(args.json), exist_ok=True)
    with open(args.json, "w") as f:
        json.dump({"meta": meta, "sides": results}, f, indent=1)
    md = render(results, meta)
    with open(args.md, "w") as f:
        f.write(md)
    print(md)


if __name__ == "__main__":
    main()
