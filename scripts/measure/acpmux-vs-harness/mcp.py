#!/usr/bin/env python3
"""MCP servers: raw Claude Code and raw Codex vs the same harnesses through acpmux.

Same MCP config on every side: K=3 stdio servers, each a copy of echo_mcp.py (one `echo` tool)
under its own name (echo0..echo2). Raw Claude Code gets them in `--mcp-config` (a JSON file),
raw Codex in `-c mcp_servers.echoN.{command,args}`. acpmux sides get them from the harness's
own config (Claude: user-scope mcpServers in $CLAUDE_CONFIG_DIR/.claude.json; Codex:
[mcp_servers.echoN] in $CODEX_HOME/config.toml), because acpmux drops the servers an ACP
client sends in `session/new` `mcpServers` (src/hub/spawn.rs: the harness's list is
agent_tools::acp_servers_for alone). The bench still sends three more in session/new
(snecho0..2, own log) and reports how many acpmux started (session_new_servers_started). Whatever
acpmux adds on its own (cmux's agent tools: `cmux mcp serve`, acpmux's own servers, in process
or not) is counted apart as "acpmux-added": the MCP server names the model is offered beyond
echo0..2, and the processes of the daemon's tree that are MCP servers (mcp-fanout.py kind_of).

The model is the stand-in of scripts/cmux-next/acpmux-overhead-bench.py (answers at once, no
network). A prompt carrying `MCPCALL_<server>_<tag>` is answered with one call of that
server's echo tool (Claude: ToolSearch first when the tool is deferred), then "ok". A call's
latency is from the stand-in sending the tool call to the harness sending its result back.

Sides: claude-raw (`claude -p --input-format stream-json`, one process per chat, the wire acpmux
uses), codex-raw (`codex app-server`, one per chat), acpmux+claude, acpmux+codex (one isolated
daemon, its own ACPMUX_HOME, per side and N, N chats on its socket).

Per side and N in --ns (default 1,5,20), N chats opened at once:
  echo_procs / echo_rss_mb / echo_cpu_pct  the echo servers alive (K*N when each chat holds its
                own), their summed RSS, their CPU over a --sample s idle window (% of one core)
  added_servers / added_procs / added_rss_mb  acpmux-added servers offered, their processes and RSS
  harness_procs / harness_rss_mb  the chats' harness processes (context for the RSS above)
  startup_ms    p50 over chats: session start to the last echo server's `tools/list`
  first_call_ms p50 over chats: the first echo call's latency (1st prompt)
  warm_call_ms  p50 of --warm more calls on chat 0
Lifecycle (own run per side, --lifecycle-chats 6 chats, ACPMUX_IDLE_CHILD_SECS=--idle-secs on
acpmux): per chat one way to end it, with well-behaved servers (exit on stdin EOF) and with
--linger servers (ignore EOF):
  end      raw: stdin closed (the harness exits); acpmux: session/close
  sigkill  SIGKILL of the harness process (acpmux: the harness_pid of hosts/<sid>.json)
  idle     acpmux only: the chat left idle until it hibernates
  -> echo processes left after 15 s (60 s + idle-secs for idle) and ms until the last one went
Crash (N=1 run): SIGKILL of echo0 mid-session, then a call of echo0 and one of echo1: was it
restarted (a new `start` in its log), and did the call error or come back.

Run (from the repo root; pins to CPUs 8-11 as the bench lanes do):
  taskset -c 8-11 python3 scripts/measure/acpmux-vs-harness/mcp.py \\
      [--acpmux ~/.local/bin/acpmux] [--sides claude-raw,codex-raw,acpmux+claude,acpmux+codex] \\
      [--ns 1,5,20] [--out .build/acpmux-vs-harness]
Writes OUT/mcp.json and OUT/mcp.md. Only processes this script started are stopped.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import importlib.util
import json
import os
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
ECHO = os.path.join(HERE, "echo_mcp.py")
_spec = importlib.util.spec_from_file_location("mcp_fanout", os.path.join(HERE, "..", "mcp-fanout.py"))
fanout = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fanout)
bench = fanout.bench  # the one acpmux-overhead-bench instance fanout patched; re-patched below

K = 3
# A model id Codex knows: against the stand-in an unknown id (the overhead bench's gpt-6.1-sol)
# gets a Responses request with no tools at all, MCP ones included (Codex 0.172, 2026-11-25).
bench.MODELS["codex"] = os.environ.get("MCP_BENCH_CODEX_MODEL", "gpt-5.1")
SERVERS = [f"echo{i}" for i in range(K)]
MARK = re.compile(r"MCPCALL_(echo\d+)_([A-Za-z0-9]+)")
MCP_NAME = re.compile(r"mcp__([A-Za-z0-9\-]+(?:_[A-Za-z0-9\-]+)*?)__[A-Za-z0-9_\-]+")

# ---------------------------------------------------------------- stand-in


class State:
    lock = threading.Lock()
    calls: dict[str, tuple] = {}       # call id -> (t sent, tag)
    results: dict[str, dict] = {}      # tag -> {ms, text}
    offered: set = set()               # MCP server names seen in any request
    codex_tools: set = set()
    missing: list = []
    issued: dict = {}


S = State()


def note_result(cid, text):
    with S.lock:
        got = S.calls.pop(cid, None)
        if got:
            t0, tag = got
            S.results[tag] = {"ms": round((time.perf_counter() - t0) * 1000.0, 1), "text": (text or "")[:300]}


def see_names(raw: str):
    names = set(MCP_NAME.findall(raw))
    if names:
        with S.lock:
            S.offered |= names


def blocks_of(m):
    c = m.get("content")
    return [b for b in (c if isinstance(c, list) else [{"type": "text", "text": c or ""}]) if isinstance(b, dict)]


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(c.get("text", "") for c in content or [] if isinstance(c, dict))


def claude_call(server, body):
    see_names(json.dumps(body.get("tools") or []) + json.dumps(body.get("system") or "") +
              json.dumps(body.get("messages") or [])[:200000])
    # Flat block sequence: Claude Code may put the next prompt in the same user message as the
    # previous tool result, so "after the marker" is by block, not by message.
    flat = [(m.get("role"), b) for m in body.get("messages") or [] for b in blocks_of(m)]
    idx = target = tag = None
    for i, (role, b) in enumerate(flat):
        if role == "user" and b.get("type") == "text" and (hit := MARK.search(b.get("text") or "")):
            idx, target, tag = i, hit.group(1), hit.group(2)
    for role, b in flat:
        if b.get("type") == "tool_result":
            note_result(b.get("tool_use_id"), text_of(b.get("content")))
    if idx is None:
        return None
    # Claude Code merges and reorders same-role blocks (a tool result lands before the prompt
    # text of the same message), so what was already done for a prompt is kept here, by its tag.
    tool = f"mcp__{target}__echo"
    names = [t.get("name") for t in body.get("tools") or []]
    if "Bash" not in names:
        return None
    with S.lock:
        done = S.issued.setdefault(tag, set())
        if "call" in done:
            return None
        if tool in names or "search" in done:
            done.add("call")
            return {"__name": tool, "__tag": tag, "text": f"hi {tag}"}
        if "ToolSearch" in names:
            done.add("search")
            return {"__name": "ToolSearch", "query": f"select:{tool}", "max_results": 1}
        S.missing = sorted(n for n in names if n)[:80]
    return None


_orig_tool_events = fanout._orig_events


def claude_events(model, usage, call):
    name = call.pop("__name", "Bash")
    tag = call.pop("__tag", None)
    events = _orig_tool_events(model, usage, call)
    for _, data in events:
        block = data.get("content_block") if isinstance(data, dict) else None
        if block and block.get("type") == "tool_use":
            block["name"] = name
            if tag:
                with S.lock:
                    S.calls[block["id"]] = (time.perf_counter(), tag)
    return events


_orig_responses = fanout._orig_responses


def codex_responses(self, body):
    tools = [t for t in body.get("tools") or [] if isinstance(t, dict)]
    flat = []
    for t in tools:  # a namespace tool holds its functions under `tools`
        flat.append(t)
        flat.extend(x for x in t.get("tools") or [] if isinstance(x, dict))
    see_names(json.dumps(tools))
    names = [t.get("name") or "" for t in flat]
    with S.lock:
        S.codex_tools |= set(names)
        for n in names:
            m = re.match(r"mcp__(.+?)__", n)
            if m:
                S.offered.add(m.group(1))
        for t in tools:
            if t.get("type") == "namespace" and str(t.get("name", "")).startswith("mcp__"):
                S.offered.add(t["name"][5:].rstrip("_"))
    items = body.get("input") if isinstance(body.get("input"), list) else []
    idx = target = tag = None
    for i, it in enumerate(items):
        if isinstance(it, dict) and it.get("role") == "user":
            hit = MARK.search(text_of(it.get("content")))
            if hit:
                idx, target, tag = i, hit.group(1), hit.group(2)
    if idx is None:
        return _orig_responses(self, body)
    after = [it for it in items[idx + 1:] if isinstance(it, dict)]
    for it in after:
        if it.get("type") == "function_call_output":
            out = it.get("output")
            note_result(it.get("call_id"), out if isinstance(out, str) else json.dumps(out))
    if (body.get("text") or {}).get("format") or any(it.get("role") == "user" for it in after):
        return _orig_responses(self, body)
    if any(it.get("type") == "function_call" for it in after):
        return _orig_responses(self, body)
    with S.lock:
        if "call" in S.issued.get(tag, set()):
            return _orig_responses(self, body)
    match = next((n for n in names if n in (f"mcp__{target}__echo", f"{target}__echo", f"{target}.echo")), None)
    ns = None
    if not match:
        nst = next((t for t in tools if t.get("type") == "namespace" and target in str(t.get("name", ""))), None)
        if nst:
            ns, match = nst.get("name"), "echo"
    if not match:
        with S.lock:
            S.missing = sorted(names)[:80]
        return _orig_responses(self, body)
    rid, iid, cid = "resp_bench_fc", "fc_" + uuid.uuid4().hex[:12], "call_" + uuid.uuid4().hex[:12]
    args = json.dumps({"text": f"hi {tag}"})
    usage = {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 1,
             "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 11}
    item = {"type": "function_call", "id": iid, "call_id": cid, "name": match, "arguments": args, "status": "completed"}
    if ns:
        item["namespace"] = ns
    events = [
        ("response.created", {"type": "response.created", "response": {"id": rid, "status": "in_progress"}}),
        ("response.output_item.added", {"type": "response.output_item.added", "output_index": 0,
                                        "item": {**item, "arguments": "", "status": "in_progress"}}),
        ("response.function_call_arguments.delta", {"type": "response.function_call_arguments.delta", "item_id": iid,
                                                    "output_index": 0, "delta": args}),
        ("response.function_call_arguments.done", {"type": "response.function_call_arguments.done", "item_id": iid,
                                                   "output_index": 0, "arguments": args}),
        ("response.output_item.done", {"type": "response.output_item.done", "output_index": 0, "item": item}),
        ("response.completed", {"type": "response.completed",
                                "response": {"id": rid, "status": "completed", "output": [item], "usage": usage}}),
    ]
    with S.lock:
        S.calls[cid] = (time.perf_counter(), tag)
        S.issued.setdefault(tag, set()).add("call")
    self.reply(200, bench.sse(events), "text/event-stream")


bench.build_call = claude_call
bench.tool_use_events = claude_events
bench.Handler.openai_responses = codex_responses

# ---------------------------------------------------------------- helpers


def p50(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.median(xs), 1) if xs else None


def events(log):
    out = []
    try:
        for line in open(log):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    except OSError:
        pass
    return out


def proc_alive(pid):
    try:
        st = open(f"/proc/{pid}/stat").read()
    except OSError:
        return False
    return st.rsplit(")", 1)[1].split()[0] != "Z"


def proc_rss_kb(pid):
    try:
        for line in open(f"/proc/{pid}/status"):
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def proc_cpu_s(pid):
    try:
        f = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
        return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK")
    except (OSError, IndexError, ValueError):
        return None


def descendants(roots):
    rows = fanout.ps_table()
    return [p for p in fanout.tree(rows, roots)], rows


def echo_args(log, name, linger):
    a = [ECHO, "--name", name, "--log", log]
    return a + (["--linger"] if linger else [])


class Chat:
    """One chat on any side: its echo log, its harness pid, its session id."""

    def __init__(self, side, k, scratch, linger=False):
        self.side, self.k, self.linger = side, k, linger
        self.cwd = os.path.realpath(os.path.join(scratch, f"w-{side.replace('+', '_')}-{k}-{uuid.uuid4().hex[:6]}"))
        os.makedirs(self.cwd, exist_ok=True)
        self.log = os.path.join(self.cwd, "echo-events.jsonl")
        # the servers a client sends in acpmux's session/new log here (see Acp.start)
        self.sn_log = os.path.join(self.cwd, "session-new-events.jsonl")
        if side.startswith("acpmux"):
            # acpmux sides get the servers from the harness's own config (one config for every
            # chat), whose servers log per chat folder: LOGDIR/<basename of cwd>.jsonl
            self.log = os.path.join(scratch, "echo-logs", os.path.basename(self.cwd) + ".jsonl")
            if linger:
                open(os.path.join(self.cwd, ".echo-linger"), "w").close()
        self.t0_wall = None
        self.proc = None
        self.io = None
        self.sid = None
        self.thread = None
        self.next = 10
        self.err = None

    def echo_pids(self, alive_only=True):
        pids = sorted({e["pid"] for e in events(self.log) if e["ev"] == "start"})
        return [p for p in pids if proc_alive(p)] if alive_only else pids

    def served_pids(self):
        """The echo servers of the harness process that served this chat's calls (not those of
        a pooled spare acpmux keeps in the same folder): the ones sharing the caller's ppid."""
        evs = events(self.log)
        ppids = {e["ppid"] for e in evs if e["ev"] == "call"}
        return sorted({e["pid"] for e in evs if e["ev"] == "start" and e["ppid"] in ppids and proc_alive(e["pid"])})

    def startup_ms(self):
        lists = {}
        for e in events(self.log):
            if e["ev"] == "tools_list" and e["name"] not in lists:
                lists[e["name"]] = e["t"]
        if len(lists) < K or self.t0_wall is None:
            return None
        return round((max(lists.values()) - self.t0_wall) * 1000.0, 1)


# ---------------------------------------------------------------- raw sides


def raw_start(chat: Chat, env, harness):
    py = sys.executable
    chat.t0_wall = time.time()
    if harness == "claude":
        cfg = {"mcpServers": {n: {"type": "stdio", "command": py, "args": echo_args(chat.log, n, chat.linger)} for n in SERVERS}}
        path = os.path.join(chat.cwd, ".bench-mcp.json")
        json.dump(cfg, open(path, "w"))
        argv = ["claude", "-p", "--model", bench.MODELS["claude"], "--input-format", "stream-json", "--output-format",
                "stream-json", "--verbose", "--include-partial-messages", "--replay-user-messages",
                "--permission-prompt-tool", "stdio", "--session-id", str(uuid.uuid4()),
                "--permission-mode", "bypassPermissions", "--mcp-config", path]
    else:
        argv = ["codex", "app-server"]
        for n in SERVERS:
            argv += ["-c", f"mcp_servers.{n}.command={json.dumps(py)}",
                     "-c", f"mcp_servers.{n}.args={json.dumps(echo_args(chat.log, n, chat.linger))}"]
    chat.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 env=env, cwd=chat.cwd, bufsize=0, start_new_session=True)
    chat.io = bench.Lines(chat.proc.stdout, chat.proc.stdin)
    io = chat.io
    if harness == "claude":
        io.send({"type": "control_request", "request_id": "boot-1", "request": {"subtype": "initialize", "hooks": {}}})
        io.wait(lambda m: m.get("type") == "control_response", timeout=120)
    else:
        io.send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "mcp-bench", "version": "1"}}})
        io.wait(lambda m: m.get("id") == 1, timeout=120)
        io.send({"jsonrpc": "2.0", "method": "initialized"})
        io.send({"jsonrpc": "2.0", "id": 2, "method": "thread/start",
                 "params": {"cwd": chat.cwd, "approvalPolicy": "never", "sandbox": "danger-full-access"}})
        _, m, _ = io.wait(lambda m: m.get("id") == 2, timeout=120)
        if "error" in m:
            raise RuntimeError(f"thread/start: {m['error']}")
        chat.thread = m["result"]["thread"]["id"]


def raw_turn(chat: Chat, text, timeout=180):
    io = chat.io
    start = io.mark()
    if chat.side == "claude-raw":
        io.send({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}})

        def done(m):
            if m.get("type") == "control_request":  # a permission ask: allow it
                req = m.get("request") or {}
                io.send({"type": "control_response", "response": {"subtype": "success", "request_id": m.get("request_id"),
                                                                  "response": {"behavior": "allow", "updatedInput": req.get("input") or {}}}})
                return False
            return m.get("type") == "result"
        io.wait(done, timeout=timeout, start=start)
    else:
        chat.next += 1
        io.send({"jsonrpc": "2.0", "id": chat.next, "method": "turn/start",
                 "params": {"threadId": chat.thread, "input": [{"type": "text", "text": text}]}})

        def done(m):
            if "method" in m and "id" in m and m.get("method", "").endswith("requestApproval"):
                io.send({"jsonrpc": "2.0", "id": m["id"], "result": {"decision": "accept"}})
                return False
            if m.get("method") == "mcpServer/elicitation/request" or (m.get("method") or "").endswith("elicitation/request"):
                io.send({"jsonrpc": "2.0", "id": m["id"], "result": {"action": "accept", "content": {}}})
                return False
            return m.get("method") == "turn/completed"
        io.wait(done, timeout=timeout, start=start)


def raw_end(chat: Chat):
    try:
        chat.proc.stdin.close()
    except OSError:
        pass


# ---------------------------------------------------------------- acpmux sides


def harness_config_env(env, scratch, tag):
    """A copy of env whose Claude and Codex configs list the K echo servers.

    acpmux drops the mcpServers a client sends in session/new (src/hub/spawn.rs builds the
    harness's list from agent_tools::acp_servers_for alone), so the one route that reaches the
    harness under acpmux is the harness's own config: Claude's user-scope mcpServers in
    $CLAUDE_CONFIG_DIR/.claude.json and Codex's [mcp_servers.*] in $CODEX_HOME/config.toml."""
    env = dict(env)
    logdir = os.path.join(scratch, "echo-logs")
    os.makedirs(logdir, exist_ok=True)
    args_of = {n: [ECHO, "--name", n, "--log-dir", logdir] for n in SERVERS}
    cdir = os.path.join(scratch, f"claude-config-{tag}")
    shutil.copytree(env["CLAUDE_CONFIG_DIR"], cdir, dirs_exist_ok=True)
    cj = os.path.join(cdir, ".claude.json")
    try:
        cfg = json.load(open(cj))
    except (OSError, ValueError):
        cfg = {}
    cfg["mcpServers"] = {n: {"type": "stdio", "command": sys.executable, "args": a} for n, a in args_of.items()}
    json.dump(cfg, open(cj, "w"))
    xdir = os.path.join(scratch, f"codex-home-{tag}")
    os.makedirs(xdir, exist_ok=True)
    toml = open(os.path.join(env["CODEX_HOME"], "config.toml")).read()
    for n, a in args_of.items():
        toml += f"\n[mcp_servers.{n}]\ncommand = {json.dumps(sys.executable)}\nargs = {json.dumps(a)}\n"
    open(os.path.join(xdir, "config.toml"), "w").write(toml)
    env["CLAUDE_CONFIG_DIR"], env["CODEX_HOME"] = cdir, xdir
    return env


class Acp:
    def __init__(self, binary, env, home, extra):
        os.makedirs(home, exist_ok=True)
        self.d = bench.Daemon(binary, env, home, extra)
        self.c = fanout.Client(self.d)
        self.cwd_of = {}

    def start(self, chat: Chat, harness):
        # also sent the ACP way, under other names, logging apart: does acpmux start them?
        servers = [{"name": f"sn{n}", "command": sys.executable, "args": echo_args(chat.sn_log, f"sn{n}", False), "env": []}
                   for n in SERVERS]
        chat.t0_wall = time.time()
        r = self.c.request("session/new", {"cwd": chat.cwd, "mcpServers": servers,
                                           "_meta": {"acpmux": {"harness": harness, "policy": "approve-all",
                                                                "model": bench.MODELS[harness]}}}, timeout=180)
        chat.sid = r["sessionId"]

    def turn(self, chat: Chat, text, timeout=180):
        self.c.turn(chat.sid, text, timeout)

    def host(self, chat: Chat):
        try:
            return json.load(open(os.path.join(self.d.home, "hosts", f"{chat.sid}.json")))
        except (OSError, ValueError):
            return {}

    def harness_pid(self, chat):
        h = self.host(chat)
        return h.get("harness_pid") or h.get("host_pid")

    def end(self, chat):
        self.c.request("session/close", {"sessionId": chat.sid}, timeout=30)

    def close(self):
        self.d.close()


# ---------------------------------------------------------------- measuring


def sample(chats, side_obj, secs, echo_logs_pids):
    """Processes, RSS and CPU over an idle window."""
    echo = [p for c in chats for p in c.echo_pids()]
    harness_roots = []
    daemon_pid = None
    if isinstance(side_obj, Acp):
        daemon_pid = side_obj.d.p.pid
        harness_roots = fanout.roots_of(side_obj.d)
    else:
        harness_roots = [c.proc.pid for c in chats if c.proc and c.proc.poll() is None]
    tree, rows = descendants(harness_roots)
    added = []
    harness = []
    extra = []  # echo servers of harnesses no chat asked for (acpmux's model probes)
    for pid in tree:
        if pid in echo:
            continue
        if any(w.endswith("echo_mcp.py") for w in rows[pid][3].split()[:2]):
            extra.append(pid)
            continue
        kind = fanout.kind_of(rows[pid][3])
        if pid == daemon_pid:
            continue
        if kind in fanout.TOOL_KINDS or kind.endswith("-mcp") or "mcp" in rows[pid][3].split()[1:3]:
            added.append(pid)
        else:
            harness.append(pid)
    watch = echo + extra + added + harness + ([daemon_pid] if daemon_pid else [])
    c0 = {p: proc_cpu_s(p) for p in watch}
    t0 = time.monotonic()
    time.sleep(secs)
    wall = time.monotonic() - t0

    def cpu(ps):
        tot = 0.0
        for p in ps:
            a, b = c0.get(p), proc_cpu_s(p)
            if a is not None and b is not None:
                tot += b - a
        return round(100.0 * tot / wall, 2)

    def rss(ps):
        return round(sum(proc_rss_kb(p) for p in ps) / 1024.0, 1)
    out = {"echo_procs": len(echo), "echo_rss_mb": rss(echo), "echo_cpu_pct": cpu(echo),
           "added_procs": len(added), "added_rss_mb": rss(added), "added_cpu_pct": cpu(added),
           "added_kinds": sorted({fanout.kind_of(rows[p][3]) for p in added}),
           "echo_extra_procs": len(extra), "echo_extra_rss_mb": rss(extra), "echo_extra_cpu_pct": cpu(extra),
           "harness_procs": len(harness), "harness_rss_mb": rss(harness), "harness_cpu_pct": cpu(harness)}
    if daemon_pid:
        out["daemon_rss_mb"] = rss([daemon_pid])
        out["daemon_cpu_pct"] = cpu([daemon_pid])
    return out


def wait_gone(pids, timeout):
    t0 = time.monotonic()
    while time.monotonic() - t0 < timeout:
        if not any(proc_alive(p) for p in pids):
            return round((time.monotonic() - t0) * 1000.0), 0
        time.sleep(0.05)
    return None, sum(1 for p in pids if proc_alive(p))


class Side:
    def __init__(self, name, args, env, scratch, extra=None):
        self.name, self.args, self.env, self.scratch = name, args, env, scratch
        self.harness = "claude" if "claude" in name else "codex"
        self.acp = None
        if name.startswith("acpmux"):
            home = os.path.join(scratch, f"acpmux-home-{name.replace('+', '_')}-{uuid.uuid4().hex[:6]}")
            # ACPMUX_HOME under /tmp keeps the socket path short
            home = tempfile.mkdtemp(prefix="am-", dir="/tmp")
            STARTED_DIRS.append(home)
            self.env = harness_config_env(env, scratch, uuid.uuid4().hex[:6])
            self.acp = Acp(args.acpmux, self.env, home, extra or {})

    def start(self, chat):
        if self.acp:
            self.acp.start(chat, self.harness)
        else:
            raw_start(chat, self.env, self.harness)

    def turn(self, chat, text):
        (self.acp.turn if self.acp else raw_turn)(chat, text)

    def harness_pid(self, chat):
        return self.acp.harness_pid(chat) if self.acp else chat.proc.pid

    def end(self, chat):
        (self.acp.end if self.acp else raw_end)(chat)

    def close(self, chats):
        for c in chats:
            if c.proc and c.proc.poll() is None:
                raw_end(c)
        if self.acp:
            try:
                for c in chats:
                    if c.sid:
                        try:
                            self.acp.end(c)
                        except Exception:
                            pass
            finally:
                roots = fanout.roots_of(self.acp.d)
                tree, _ = descendants(roots)
                self.acp.close()
                OWNED.update(tree)
        for c in chats:
            if c.proc:
                OWNED.add(c.proc.pid)
                try:
                    c.proc.wait(5)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(c.proc.pid, signal.SIGKILL)
                    except OSError:
                        pass
            OWNED.update(c.echo_pids(alive_only=False))
        reap_owned()


OWNED: set = set()
STARTED_DIRS: list = []


def reap_owned():
    time.sleep(0.5)
    for p in list(OWNED):
        if proc_alive(p):
            try:
                os.kill(p, signal.SIGKILL)
            except OSError:
                pass


def run_n(args, name, n, env, scratch):
    side = Side(name, args, env, scratch)
    chats = [Chat(name, k, scratch) for k in range(n)]
    res = {"side": name, "n": n}
    try:
        with S.lock:
            S.results.clear()
            S.offered.clear()

        def first(c):
            try:
                side.start(c)
                tag = f"F{uuid.uuid4().hex[:8]}"
                c.first_tag = tag
                side.turn(c, f"MCPCALL_echo0_{tag} call echo0 once")
            except Exception as e:
                c.err = f"{type(e).__name__}: {e}"
        with concurrent.futures.ThreadPoolExecutor(max_workers=n) as ex:
            list(ex.map(first, chats))
        errs = [c.err for c in chats if c.err]
        res["chats_failed"] = len(errs)
        if errs:
            res["errors"] = errs[:3]
        ok = [c for c in chats if not c.err]
        res["startup_ms"] = p50([c.startup_ms() for c in ok])
        res["startup_ms_all"] = [c.startup_ms() for c in ok]
        with S.lock:
            firsts = [S.results.get(getattr(c, "first_tag", ""), {}).get("ms") for c in ok]
        res["first_call_ms"] = p50(firsts)
        res["first_call_answered"] = sum(1 for x in firsts if x is not None)
        warm = []
        if ok:
            c = ok[0]
            for i in range(args.warm):
                tag = f"W{i}x{uuid.uuid4().hex[:6]}"
                side.turn(c, f"MCPCALL_echo{i % K}_{tag} again")
                with S.lock:
                    warm.append(S.results.get(tag, {}).get("ms"))
        res["warm_call_ms"] = p50(warm)
        res["warm_all"] = warm
        with S.lock:
            res["offered_servers"] = sorted(S.offered)
            res["added_servers"] = sorted(s for s in S.offered if s not in SERVERS)
            res["codex_tool_names"] = sorted(S.codex_tools)[:60] if side.harness == "codex" else None
            res["missing_tools_seen"] = S.missing
        time.sleep(args.settle)
        res.update(sample(ok, side.acp or side, args.sample, None))
        res["echo_per_chat"] = round(res["echo_procs"] / max(1, len(ok)), 2)
        if side.acp:
            res["session_new_servers_started"] = sum(1 for c in chats for e in events(c.sn_log) if e["ev"] == "start")
        if n == 1 and ok:
            res["crash"] = crash(side, ok[0])
    finally:
        side.close(chats)
    return res


def crash(side, chat):
    # the echo0 that served the chat's last call (acpmux may hold a pooled spare's too)
    pids = {e["name"]: e["pid"] for e in events(chat.log) if e["ev"] == "call"}
    victim = pids.get("echo0")
    out = {"killed_pid": victim}
    if not victim:
        out["note"] = "no echo0 pid"
        return out
    os.kill(victim, signal.SIGKILL)
    time.sleep(1.0)
    for name in ("echo0", "echo1"):
        tag = f"C{name}x{uuid.uuid4().hex[:6]}"
        t0 = time.perf_counter()
        try:
            side.turn(chat, f"MCPCALL_{name}_{tag} after crash")
            with S.lock:
                r = S.results.get(tag)
            out[name] = {"answered": r is not None, "ms": r and r["ms"], "text": r and r["text"],
                         "turn_ms": round((time.perf_counter() - t0) * 1000)}
        except Exception as e:
            out[name] = {"error": f"{type(e).__name__}: {e}"}
    t = out.get("echo0", {}).get("text") or ""
    m = re.search(r"\[echo0 pid (\d+)\]", t)
    out["echo0_recovered"] = bool(m)
    out["echo0_restarted"] = bool(m) and int(m.group(1)) != victim
    out["echo0_served_by"] = m and int(m.group(1))
    return out


def lifecycle(args, name, env, scratch):
    extra = {"ACPMUX_IDLE_CHILD_SECS": str(args.idle_secs)}
    side = Side(name, args, env, scratch, extra)
    modes = ["end", "sigkill"] + (["idle"] if side.acp else [])
    chats = []
    for linger in (False, True):
        for m in modes:
            c = Chat(name, len(chats), scratch, linger)
            c.mode = m
            chats.append(c)
    out = {}
    try:
        def go(c):
            try:
                side.start(c)
                side.turn(c, f"MCPCALL_echo0_L{uuid.uuid4().hex[:6]} lifecycle")
                c.t_last = time.monotonic()
            except Exception as e:
                c.err = f"{type(e).__name__}: {e}"
        with concurrent.futures.ThreadPoolExecutor(max_workers=len(chats)) as ex:
            list(ex.map(go, chats))
        time.sleep(1)
        # end and sigkill first, then the idle ones are left to hibernate
        for c in chats:
            key = f"{c.mode}{'_linger' if c.linger else ''}"
            if c.err:
                out[key] = {"error": c.err}
                continue
            pids = c.served_pids()
            others = [p for p in c.echo_pids() if p not in pids]
            if c.mode == "end":
                side.end(c)
            elif c.mode == "sigkill":
                hp = side.harness_pid(c)
                OWNED.add(hp)
                os.kill(hp, signal.SIGKILL)
            else:
                continue
            ms_, left = wait_gone(pids, 15)
            out[key] = {"echo_before": len(pids), "left": left, "reap_ms": ms_,
                        "spare_echo_alive": sum(1 for p in others if proc_alive(p))}
        idle = [c for c in chats if c.mode == "idle" and not c.err]
        if idle:
            pids = {id(c): c.served_pids() for c in idle}
            t0 = time.monotonic()
            deadline = t0 + args.idle_secs + 60
            gone_at = {}
            while time.monotonic() < deadline and len(gone_at) < len(idle):
                for c in idle:
                    if id(c) not in gone_at and not any(proc_alive(p) for p in pids[id(c)]):
                        gone_at[id(c)] = time.monotonic()
                time.sleep(0.25)
            for c in idle:
                key = f"idle{'_linger' if c.linger else ''}"
                g = gone_at.get(id(c))
                out[key] = {"echo_before": len(pids[id(c)]), "left": sum(1 for p in pids[id(c)] if proc_alive(p)),
                            # from the chat's last turn ending
                            "gone_after_ms": g and round((g - c.t_last) * 1000), "idle_secs": args.idle_secs,
                            "host": {k: side.acp.host(c).get(k) for k in ("host_pid", "harness_pid")}}
            # wake: a call after hibernation
            c = idle[0]
            tag = f"H{uuid.uuid4().hex[:6]}"
            t1 = time.perf_counter()
            try:
                side.turn(c, f"MCPCALL_echo0_{tag} after idle")
                with S.lock:
                    r = S.results.get(tag)
                out["idle_wake_call"] = {"answered": r is not None, "call_ms": r and r["ms"],
                                         "turn_ms": round((time.perf_counter() - t1) * 1000),
                                         "echo_restarted": len([e for e in events(c.log) if e["ev"] == "start"]) > K}
            except Exception as e:
                out["idle_wake_call"] = {"error": f"{type(e).__name__}: {e}"}
    finally:
        side.close(chats)
    return out


# ---------------------------------------------------------------- report

ROWS = [
    ("echo MCP procs, N=1/5/20", "echo_procs"),
    ("echo procs per chat (K=3)", "echo_per_chat"),
    ("echo RSS MB", "echo_rss_mb"),
    ("echo idle CPU %", "echo_cpu_pct"),
    ("echo procs outside chats (acpmux model probes)", "echo_extra_procs"),
    ("session/new mcpServers started by acpmux (of 3/chat)", "session_new_servers_started"),
    ("acpmux-added servers offered", "added_servers"),
    ("acpmux-added MCP procs", "added_procs"),
    ("acpmux-added MCP RSS MB", "added_rss_mb"),
    ("harness procs (non-MCP)", "harness_procs"),
    ("harness RSS MB", "harness_rss_mb"),
    ("daemon RSS MB", "daemon_rss_mb"),
    ("idle CPU % harness+daemon", "_hcpu"),
    ("MCP startup ms p50 (start -> 3 servers listed)", "startup_ms"),
    ("first MCP call ms p50", "first_call_ms"),
    ("warm MCP call ms p50 (chat 0)", "warm_call_ms"),
    ("chats failed", "chats_failed"),
]


def cell(r, key):
    if r is None:
        return "-"
    if "error_run" in r:
        return "run failed: " + r["error_run"][:60]
    if key == "_hcpu":
        return round((r.get("harness_cpu_pct") or 0) + (r.get("daemon_cpu_pct") or 0), 2)
    v = r.get(key)
    if key == "added_servers":
        return len(v) if v is not None else "-"
    return "-" if v is None else v


def render(data, sides, ns):
    lines = ["# MCP servers: raw harness vs acpmux", "",
             f"K={K} stdio echo servers (echo_mcp.py) per chat on every side; stand-in model; "
             f"taskset {data['meta'].get('cpus')}; load before: {data['meta'].get('load')}.", "",
             "| metric | " + " | ".join(sides) + " |", "|---|" + "---|" * len(sides)]
    for label, key in ROWS:
        cells = []
        for s in sides:
            vals = [str(cell(data["runs"].get(f"{s}/{n}"), key)) for n in ns]
            cells.append(" / ".join(vals))
        lines.append(f"| {label} (N={'/'.join(map(str, ns))}) | " + " | ".join(cells) + " |")
    # lifecycle
    for label, key in [("end: echo left / reap ms", "end"), ("end, linger servers", "end_linger"),
                       ("SIGKILL harness: echo left / reap ms", "sigkill"), ("SIGKILL, linger servers", "sigkill_linger"),
                       ("idle hibernation: echo left / gone after ms", "idle"), ("idle, linger servers", "idle_linger")]:
        cells = []
        for s in sides:
            lc = data["lifecycle"].get(s) or {}
            v = lc.get(key)
            if v is None:
                cells.append("n/a (raw harness has no idle hibernation)" if key.startswith("idle") and "raw" in s else "-")
            elif "error" in v:
                cells.append("error: " + v["error"][:60])
            else:
                ms_ = v.get("reap_ms", v.get("gone_after_ms"))
                cells.append(f"{v.get('left')} left / " + ("never reaped (15 s)" if ms_ is None else f"{ms_} ms") + f" (of {v.get('echo_before')})")
        lines.append(f"| {label} | " + " | ".join(cells) + " |")
    cells = []
    for s in sides:
        w = (data["lifecycle"].get(s) or {}).get("idle_wake_call")
        cells.append("n/a" if w is None else (f"answered={w.get('answered')} call {w.get('call_ms')} ms, turn {w.get('turn_ms')} ms, restarted={w.get('echo_restarted')}" if "error" not in w else "error: " + w["error"][:60]))
    lines.append("| MCP call after hibernation wake | " + " | ".join(cells) + " |")
    for label, sub in [("crash echo0 -> restarted?", "echo0_restarted"), ("crash echo0 -> next echo0 call", "echo0"),
                       ("crash echo0 -> echo1 call", "echo1")]:
        cells = []
        for s in sides:
            cr = (data["runs"].get(f"{s}/1") or {}).get("crash")
            if not cr:
                cells.append("-")
                continue
            v = cr.get(sub)
            if isinstance(v, dict):
                if "error" in v:
                    cells.append("turn error: " + v["error"][:60])
                elif not v.get("answered"):
                    cells.append(f"no tool result (turn {v.get('turn_ms')} ms)")
                else:
                    t = v.get("text") or ""
                    try:  # Codex hands back [{"type":"input_text","text":"Wall time ..."}, {...}]
                        t = " ".join(x.get("text", "") for x in json.loads(t)[1:])
                    except (ValueError, AttributeError, TypeError):
                        pass
                    t = t.replace("|", "/").replace("\n", " ")[:90]
                    cells.append(f"{v.get('ms')} ms: `{t}`")
            else:
                cells.append(str(v))
        lines.append(f"| {label} | " + " | ".join(cells) + " |")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--acpmux", default=os.path.expanduser("~/.local/bin/acpmux"))
    ap.add_argument("--sides", default="claude-raw,codex-raw,acpmux+claude,acpmux+codex")
    ap.add_argument("--ns", default="1,5,20")
    ap.add_argument("--warm", type=int, default=6)
    ap.add_argument("--settle", type=float, default=3)
    ap.add_argument("--sample", type=float, default=10)
    ap.add_argument("--idle-secs", type=int, default=20)
    ap.add_argument("--no-lifecycle", action="store_true")
    ap.add_argument("--out", default=".build/acpmux-vs-harness")
    args = ap.parse_args()
    sides = args.sides.split(",")
    ns = [int(x) for x in args.ns.split(",")]
    os.makedirs(args.out, exist_ok=True)
    jpath = os.path.join(args.out, "mcp.json")
    data = {"meta": {"started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "load": os.getloadavg(),
                     "cpus": sorted(os.sched_getaffinity(0)), "K": K,
                     "versions": {b: subprocess.run([b, "--version"], capture_output=True, text=True).stdout.strip()
                                  for b in ("claude", "codex")} | {"acpmux": subprocess.run([args.acpmux, "--version"], capture_output=True, text=True).stdout.strip()}},
            "runs": {}, "lifecycle": {}}
    if os.path.exists(jpath) and os.environ.get("MCP_BENCH_MERGE"):
        old = json.load(open(jpath))
        data["runs"].update(old.get("runs", {}))
        data["lifecycle"].update(old.get("lifecycle", {}))
    scratch = tempfile.mkdtemp(prefix="mcp-bench-")
    stand = bench.StandIn()
    threading.Thread(target=stand.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{stand.server_address[1]}"
    env = bench.env_for(url, scratch)
    env["ENABLE_TOOL_SEARCH"] = env.get("ENABLE_TOOL_SEARCH", "auto")

    def save():
        json.dump(data, open(jpath, "w"), indent=1)
        all_sides = [s for s in ["claude-raw", "codex-raw", "acpmux+claude", "acpmux+codex"]
                     if s in sides or any(k.startswith(s + "/") for k in data["runs"])]
        open(os.path.join(args.out, "mcp.md"), "w").write(render(data, all_sides, ns))
    try:
        for name in sides:
            for n in ns:
                print(f"== {name} N={n}", flush=True)
                t = time.monotonic()
                try:
                    r = run_n(args, name, n, env, scratch)
                except Exception as e:
                    r = {"error_run": f"{type(e).__name__}: {e}"}
                r["wall_s"] = round(time.monotonic() - t, 1)
                data["runs"][f"{name}/{n}"] = r
                print(json.dumps({k: v for k, v in r.items() if k not in ("codex_tool_names",)})[:1500], flush=True)
                save()
            if not args.no_lifecycle:
                print(f"== {name} lifecycle", flush=True)
                try:
                    data["lifecycle"][name] = lifecycle(args, name, env, scratch)
                except Exception as e:
                    data["lifecycle"][name] = {"error": f"{type(e).__name__}: {e}"}
                print(json.dumps(data["lifecycle"][name])[:1500], flush=True)
                save()
    finally:
        reap_owned()
        save()
        stand.shutdown()
        print(f"wrote {jpath} and mcp.md; scratch {scratch}")


if __name__ == "__main__":
    main()
