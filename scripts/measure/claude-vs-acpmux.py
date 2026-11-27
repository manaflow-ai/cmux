#!/usr/bin/env python3
"""Claude Code in a terminal against Claude Code through acpmux (cmux NEXT's agent chats), real model (cmux#57487).

Austin, 2026-11-25: "can we benchmark acpmux against claude code harness. some people said claude code is much
faster on the terminal than in acpmux for the cmux next GUI".

Same model, effort, prompt and folder on every arm; each run is a new session (its first turn, `cold`) and a second
prompt in it (`warm`). The prompt makes one Bash call and then streams a paragraph, so every stage shows.

Arms (`--arms`, default stdio,acpmux):
  stdio   Claude Code itself on the wire acpmux drives (`-p --input-format stream-json`, the launcher the harness
          profile runs), no acpmux: the floor for everything but the TUI's own drawing.
  acpmux  `acpmux new` + `acpmux send` on the harness profile (`--harness`, default claude-sr2), headless. Times are
          the daemon's own event stamps (`~/.acpmux/sessions/<id>/events`), the earliest a client can draw.
  tui     The interactive TUI in a pseudo-terminal (`--tui-cmd`, default the launcher with
          --dangerously-skip-permissions), timed from its transcript's entry stamps (no per-token stamps there).
          `sr2 claude` runs its TUI only in a cmux terminal: run this arm from one.
  gui     A cmux NEXT chat in a running app (`--app-socket`, a dev build's control socket): debug.agent_pane
          new_chat + send_prompt, the page polled (`query`) for the first tool card and the first answer text.
  mcp     The cause found in cmux#57487, alone: a new chat's `cmux mcp serve` answering its first `tools/list`,
          which Claude Code waits for before its first turn (`--mcp-runs`).

Metrics per turn (ms unless noted; `cold`/`warm` label):
  spawn            new session to ready (stdio: initialize answered; acpmux: `acpmux new` returned; tui: first screen
                   quiet; gui: chat has a session)
  start_wait       prompt handed to Claude Code to its turn starting (`command_lifecycle` queued -> started)
  first_token      prompt to the first streamed delta (stdio, acpmux); first visible output (gui)
  first_block      prompt to the first whole content block (every arm; the TUI's only first-output mark)
  first_tool       prompt to the tool call (its block opening; tui: its entry)
  tool_rt          tool call complete to its result
  model_after_tool tool result to the next first token: the model alone
  throughput       characters of the final text per second from the tool result to its last delta (higher is better)
  total            prompt to the turn's end
  cpu_s, rss_mb    CPU seconds over both turns and peak resident MB of the harness's process tree
  daemon_cpu_s     acpmux: the daemon's CPU seconds over both turns (shared with every other chat on the Mac)

Output: a Markdown table (median and p90 per arm and metric), one `CLAUDE-VS-ACPMUX {json}` line (every sample;
`scripts/bench/benches/claude_vs_acpmux.py` ingests it) and, with `--guard`, exit 1 when a guarded p50 is over its
limit (GUARDS below).

  python3 scripts/measure/claude-vs-acpmux.py --runs 5
  python3 scripts/measure/claude-vs-acpmux.py --arms mcp --mcp-runs 8 --guard
  python3 scripts/measure/claude-vs-acpmux.py --arms gui --app-socket "$HOME/.local/state/cmux-next-dev-TAG/cmux.sock" \
      --acpmux-bin "/path/to/cmux NEXT DEV TAG.app/Contents/Resources/bin/acpmux"
"""
from __future__ import annotations

import argparse
import datetime as dt
import glob
import json
import os
import pty
import re
import select
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

PROMPT = ("Use the Bash tool to run `echo bench-ok`. Then, with no other tool, write one paragraph of about 120 words "
          "about tide pools.")
WARM_PROMPT = "Use the Bash tool to run `echo bench-two`. Then reply with one short sentence."
# p50 limits (ms) a run must stay under with --guard: what acpmux adds over Claude Code's own wire.
GUARDS = {
    ("mcp", "cold", "first_list"): 400,
    ("acpmux", "cold", "start_wait"): 400,
    ("acpmux", "warm", "start_wait"): 100,
    ("acpmux", "warm", "tool_rt_over_stdio"): 150,
}
LINE = "CLAUDE-VS-ACPMUX"


def now() -> float:
    return time.time()


def pct(values: list[float], q: float) -> float | None:
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    if len(vals) == 1:
        return vals[0]
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return vals[lo] + (vals[hi] - vals[lo]) * (k - lo)


def iso(stamp: str) -> float:
    return dt.datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


def clean_env() -> dict[str, str]:
    env = dict(os.environ)
    env.pop("BUN_OPTIONS", None)  # a parent's preload breaks bun subcommands; each launcher sets its own
    return env


# ---- process tree sampling ---------------------------------------------------------------------------------------

def _ps() -> dict[int, tuple[int, int, float]]:
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,rss=,time="], capture_output=True, text=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        pid, ppid, rss, cpu = parts[:4]
        secs = 0.0
        for chunk in cpu.replace("-", ":").split(":"):
            secs = secs * 60 + float(chunk)
        table[int(pid)] = (int(ppid), int(rss), secs)
    return table


class Sampler:
    """CPU seconds and peak RSS of `roots` and their descendants (and of `extra` pids alone) while it runs."""

    def __init__(self, roots, extra=()):
        self.roots, self.extra = roots, list(extra)
        self.first: dict[int, float] = {}
        self.last: dict[int, float] = {}
        self.peak_kb = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def tree(self, table):
        roots = set(self.roots() if callable(self.roots) else self.roots)
        pids, frontier = set(roots), list(roots)
        while frontier:
            parent = frontier.pop()
            for pid, (ppid, _, _) in table.items():
                if ppid == parent and pid not in pids:
                    pids.add(pid)
                    frontier.append(pid)
        return (pids | set(self.extra)) & set(table)

    def _loop(self):
        while not self._stop.is_set():
            self.sample()
            self._stop.wait(0.25)

    def sample(self):
        table = _ps()
        pids = self.tree(table)
        self.peak_kb = max(self.peak_kb, sum(table[p][1] for p in pids))
        for pid in pids:
            self.first.setdefault(pid, table[pid][2])
            self.last[pid] = table[pid][2]

    def __enter__(self):
        self.sample()
        self._thread.start()
        return self

    def __exit__(self, *exc):
        self._stop.set()
        self._thread.join()
        self.sample()

    def result(self):
        cpu = sum(self.last[p] - self.first.get(p, self.last[p]) for p in self.last)
        return {"cpu_s": round(cpu, 2), "rss_mb": round(self.peak_kb / 1024, 1)}


# ---- stream-json turn reading (stdio arm, and acpmux's recorded copy of the same lines) --------------------------

class Turn:
    """Marks of one turn from Claude Code's stream-json lines, each with its arrival time."""

    def __init__(self, sent: float):
        self.sent = sent
        self.m: dict[str, float] = {}
        self.text_first = self.text_last = None
        self.text_chars = 0
        self.tool_done = None

    def mark(self, key, at):
        self.m.setdefault(key, at)

    def feed(self, e: dict, at: float) -> bool:
        kind = e.get("type")
        if kind == "command_lifecycle":
            self.mark("lc_" + str(e.get("state")), at)
        elif kind == "stream_event":
            ev = e.get("event") or {}
            et = ev.get("type")
            if et == "content_block_delta":
                if "tool_result" in self.m:
                    self.mark("token_after_tool", at)
                self.mark("first_token", at)
                delta = ev.get("delta") or {}
                if delta.get("type") == "text_delta" and "tool_result" in self.m and delta.get("text"):
                    self.text_first = self.text_first or at
                    self.text_last = at
                    self.text_chars += len(delta.get("text") or "")
            elif et == "content_block_start" and (ev.get("content_block") or {}).get("type") == "tool_use":
                self.mark("first_tool", at)
        elif kind == "assistant":
            self.mark("first_block", at)
            content = (e.get("message") or {}).get("content") or []
            if any(isinstance(c, dict) and c.get("type") == "tool_use" for c in content):
                self.tool_done = self.tool_done or at
        elif kind == "user":
            content = (e.get("message") or {}).get("content") or []
            if isinstance(content, list) and any(isinstance(c, dict) and c.get("type") == "tool_result"
                                                 for c in content):
                self.mark("tool_result", at)
        elif kind == "result":
            self.mark("result", at)
            return True
        return False

    def metrics(self) -> dict:
        m, s = self.m, self.sent
        out = {}

        def ms(a, b):
            return round((a - b) * 1000) if a is not None and b is not None else None

        out["start_wait"] = ms(m.get("lc_started"), m.get("lc_queued"))
        out["first_token"] = ms(m.get("first_token"), s)
        out["first_block"] = ms(m.get("first_block"), s)
        out["first_tool"] = ms(m.get("first_tool"), s)
        out["tool_rt"] = ms(m.get("tool_result"), self.tool_done)
        out["model_after_tool"] = ms(m.get("token_after_tool"), m.get("tool_result"))
        out["total"] = ms(m.get("result"), s)
        # Characters of the final text per second from the tool result to its last delta: the answer as the
        # client gets it (a route that sends the whole answer at once still counts its wait).
        start = m.get("tool_result")
        if start and self.text_last and self.text_last > start and self.text_chars:
            out["throughput"] = round(self.text_chars / (self.text_last - start))
        return out


# ---- arms --------------------------------------------------------------------------------------------------------

def arm_stdio(a, run: int) -> list[dict]:
    cmd = [a.claude, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
           "--include-partial-messages", "--model", a.model, "--effort", a.effort, "--dangerously-skip-permissions"]
    t0 = now()
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            cwd=a.cwd, env=clean_env(), text=True, bufsize=1)

    def write(obj):
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()

    write({"type": "control_request", "request_id": "init-1", "request": {"subtype": "initialize"}})
    ready = None
    for line in proc.stdout:
        if '"control_response"' in line:
            ready = now()
            break
    rows = []
    with Sampler([proc.pid]) as sampler:
        for label, text in (("cold", PROMPT), ("warm", WARM_PROMPT)):
            turn = Turn(now())
            write({"type": "user", "uuid": str(uuid.uuid4()),
                   "message": {"role": "user", "content": [{"type": "text", "text": text}]}})
            for line in proc.stdout:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("type") == "control_request":  # nothing to gate here: allow
                    write({"type": "control_response", "response": {"subtype": "success",
                                                                    "request_id": e.get("request_id"),
                                                                    "response": {}}})
                if turn.feed(e, now()):
                    break
            row = turn.metrics()
            if label == "cold":
                row["spawn"] = round((ready - t0) * 1000) if ready else None
            rows.append({"arm": "stdio", "turn": label, "run": run, **row})
    rows[-1].update(sampler.result())
    proc.stdin.close()
    proc.terminate()
    return rows


def _events(acpmux_home: Path, sid: str) -> list[dict]:
    files = sorted(glob.glob(str(acpmux_home / "sessions" / sid / "events" / "*.ndjson")))
    out = []
    for f in files:
        for line in open(f, encoding="utf-8"):
            try:
                out.append(json.loads(line))
            except ValueError:
                pass
    return out


def _acp_turns(events: list[dict]) -> list[Turn]:
    """Each turn of a session from the daemon's events: its `claude.*` lines are the stream-json lines acpmux read."""
    turns, turn = [], None
    for e in events:
        kind, at, msg = e.get("kind", ""), e.get("at", 0) / 1000, e.get("msg") or {}
        if kind == "turn_started":
            turn = Turn(at)
            turns.append(turn)
            continue
        if turn is None:
            continue
        if kind == "claude.stdin" and msg.get("type") == "user":
            turn.mark("to_harness", at)
        elif kind == "tool_call":
            turn.mark("first_tool", at)
        elif kind == "agent_message_chunk" and "tool_result" in turn.m:
            # The recorded stream lines leave text bodies out; the ACP chunk the client gets carries it.
            text = (((msg.get("params") or {}).get("update") or {}).get("content") or {}).get("text") or ""
            turn.text_first = turn.text_first or at
            turn.text_last = at
            turn.text_chars += len(text)
        elif kind.startswith("claude.") and isinstance(msg, dict) and msg.get("type"):
            turn.feed(msg, at)
        elif kind == "turn_end":
            turn.mark("result", at)
    return turns


def _daemon_pid(home: Path) -> int | None:
    try:
        return int((home / "daemon.pid").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return None


def arm_acpmux(a, run: int) -> list[dict]:
    env = clean_env()
    name = f"bench-acpmux-{os.getpid()}-{run}-{int(now())}"
    home = Path(a.acpmux_home)
    t0 = now()
    made = subprocess.run([a.acpmux_bin, "new", "-m", a.harness, "-e", a.effort, "--cwd", a.cwd, "--policy",
                           "approve-all", "--no-parent", "-d", "--json", "-n", name, "--tag", "priority=interactive",
                           "--tag", "bench=claude-vs-acpmux"], capture_output=True, text=True, env=env)
    spawn = round((now() - t0) * 1000)
    try:
        sid = json.loads(made.stdout)["sessionId"]
    except (ValueError, KeyError):
        raise RuntimeError(f"acpmux new failed: {made.stderr[-400:]}")
    def harness_pids():
        # Claude Code's argv carries `--name <session>` after a long system prompt; pgrep -f misses it there.
        out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True).stdout
        return [int(line.split(None, 1)[0]) for line in out.splitlines()
                if f"--name {name}" in line and "acpmux" not in line.split(None, 2)[1]]
    try:
        daemon = Sampler([], extra=[p for p in [_daemon_pid(home)] if p])
        with Sampler(harness_pids) as sampler, daemon:
            for text in (PROMPT, WARM_PROMPT):
                subprocess.run([a.acpmux_bin, "send", "--wait", "-q", name, text], capture_output=True, env=env,
                               timeout=600)
        turns = _acp_turns(_events(home, sid))
        rows = []
        for label, turn in zip(("cold", "warm"), turns):
            row = turn.metrics()
            if label == "cold":
                row["spawn"] = spawn
            rows.append({"arm": "acpmux", "turn": label, "run": run, **row})
        if rows:
            rows[-1].update(sampler.result())
            # The daemon is shared with every other chat on the Mac: its CPU over the two turns, apart.
            rows[-1]["daemon_cpu_s"] = daemon.result()["cpu_s"]
        return rows
    finally:
        subprocess.run([a.acpmux_bin, "archive", name], capture_output=True, env=env)


def _transcripts(cwd: str) -> set[str]:
    slug = re.sub(r"[^A-Za-z0-9]", "-", os.path.realpath(cwd))
    roots = [os.environ.get("CLAUDE_CONFIG_DIR", ""), str(Path.home() / ".claude")]
    roots += glob.glob(str(Path.home() / ".subrouter" / "*" / "claude" / "*"))
    found = set()
    for root in filter(None, roots):
        found.update(glob.glob(os.path.join(root, "projects", slug, "*.jsonl")))
    return found


def _transcript_turns(path: str) -> list[dict]:
    turns, cur = [], None
    for line in open(path, encoding="utf-8"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        stamp = e.get("timestamp")
        if not stamp:
            continue
        at, kind = iso(stamp), e.get("type")
        content = (e.get("message") or {}).get("content")
        kinds = [c.get("type") for c in content if isinstance(c, dict)] if isinstance(content, list) else []
        if kind == "user" and (isinstance(content, str) or "text" in kinds) and "tool_result" not in kinds:
            cur = {"sent": at}
            turns.append(cur)
        elif cur is None:
            continue
        elif kind == "assistant":
            cur.setdefault("first_block", at)
            if "tool_use" in kinds:
                cur.setdefault("tool", at)
            if (e.get("message") or {}).get("stop_reason") == "end_turn":
                cur["end"] = at
        elif kind == "user" and "tool_result" in kinds:
            cur.setdefault("tool_result", at)
    return turns


def arm_tui(a, run: int) -> list[dict]:
    before = _transcripts(a.cwd)
    cmd = a.tui_cmd or [a.claude, "--dangerously-skip-permissions", "--model", a.model, "--effort", a.effort]
    t0 = now()
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(a.cwd)
        os.execvpe(cmd[0], cmd, clean_env())
    last_out, got = [now()], [0]

    def drain():
        while True:
            try:
                r, _, _ = select.select([fd], [], [], 0.5)
                if r:
                    chunk = os.read(fd, 65536)
                    if not chunk:
                        return
                    got[0] += len(chunk)
                    last_out[0] = now()
            except OSError:
                return

    threading.Thread(target=drain, daemon=True).start()
    while now() - t0 < 60 and not (got[0] > 2000 and now() - last_out[0] > 0.8):
        time.sleep(0.05)
    spawn = round((last_out[0] - t0) * 1000)
    rows, sent = [], []
    with Sampler([pid]) as sampler:
        for text in (PROMPT, WARM_PROMPT):
            os.write(fd, text.encode())
            time.sleep(0.3)
            sent.append(now())
            os.write(fd, b"\r")
            deadline = now() + 600
            while now() < deadline:
                new = _transcripts(a.cwd) - before
                turns = _transcript_turns(max(new, key=os.path.getmtime)) if new else []
                if len(turns) >= len(sent) and "end" in turns[len(sent) - 1]:
                    break
                time.sleep(0.2)
    new = _transcripts(a.cwd) - before
    turns = _transcript_turns(max(new, key=os.path.getmtime)) if new else []
    for label, t in zip(("cold", "warm"), turns):
        def ms(x, y):
            return round((t[x] - t[y]) * 1000) if x in t and y in t else None
        row = {"arm": "tui", "turn": label, "run": run, "first_block": ms("first_block", "sent"),
               "first_tool": ms("tool", "sent"), "tool_rt": ms("tool_result", "tool"), "total": ms("end", "sent")}
        if label == "cold":
            row["spawn"] = spawn
        rows.append(row)
    if rows:
        rows[-1].update(sampler.result())
    try:
        os.kill(pid, 15)
        os.waitpid(pid, 0)
    except OSError:
        pass
    return rows


class App:
    """The cmux app's control socket: one JSON-RPC line per request."""

    def __init__(self, path: str):
        self.path = path

    def rpc(self, method: str, params: dict, timeout: float = 30):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(self.path)
            s.sendall((json.dumps({"id": 1, "method": method, "params": params}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf or b"{}")
        return reply.get("result", reply)


def arm_gui(a, run: int) -> list[dict]:
    if not a.app_socket:
        raise RuntimeError("the gui arm needs --app-socket (a dev build's control socket)")
    app = App(a.app_socket)
    pane = a.pane
    t0 = now()
    app.rpc("debug.agent_pane", {"action": "new_chat", "pane": pane, "harness": a.harness, "cwd": a.cwd}, 60)
    rows = []
    sid = None
    for label, text in (("cold", PROMPT), ("warm", WARM_PROMPT)):
        sent = now()
        app.rpc("debug.agent_pane", {"action": "send_prompt", "pane": pane, "text": text}, 60)
        marks = {}
        deadline = now() + 600
        while now() < deadline:
            state = app.rpc("debug.agent_pane", {"action": "chat_state", "pane": pane}, 10) or {}
            sid = sid or state.get("sessionId")
            if sid and "spawn" not in marks and label == "cold":
                marks["spawn"] = now()
            seen = app.rpc("debug.agent_pane", {"action": "query", "pane": pane, "selector": a.tool_selector}, 10)
            if seen and (seen.get("count") or seen.get("found")) and "first_tool" not in marks:
                marks["first_tool"] = now()
            said = app.rpc("debug.agent_pane", {"action": "query", "pane": pane, "selector": a.text_selector}, 10)
            n = (said or {}).get("count") or 0
            if n > (1 if label == "warm" else 0) and "first_token" not in marks:
                marks["first_token"] = now()
            if state.get("status") in ("ready", "idle") and "first_token" in marks and now() - sent > 1:
                marks["total"] = now()
                break
            time.sleep(0.02)
        row = {"arm": "gui", "turn": label, "run": run}
        for k in ("first_tool", "first_token", "total"):
            row[k] = round((marks[k] - sent) * 1000) if k in marks else None
        if label == "cold" and "spawn" in marks:
            row["spawn"] = round((marks["spawn"] - t0) * 1000)
        rows.append(row)
    if sid and a.acpmux_home:  # the daemon's stamps for the same turns: what the page added on top
        for row, turn in zip(rows, _acp_turns(_events(Path(a.acpmux_home), sid))):
            m = turn.metrics()
            row["start_wait"] = m.get("start_wait")
            row["daemon_first_token"] = m.get("first_token")
    return rows


def arm_mcp(a, run: int) -> list[dict]:
    """A new chat's `cmux mcp serve`, started as acpmux's gateway starts it, to its first `tools/list` answer."""
    env = clean_env()
    name = f"bench-mcp-{os.getpid()}-{run}-{int(now())}"
    made = subprocess.run([a.acpmux_bin, "new", "-m", a.harness, "-e", a.effort, "--cwd", a.cwd, "--policy",
                           "approve-all", "--no-parent", "-d", "--json", "-n", name,
                           "--tag", "bench=claude-vs-acpmux"], capture_output=True, text=True, env=env)
    try:
        sid = json.loads(made.stdout)["sessionId"]
        launch = json.loads((Path(a.acpmux_home) / "run" / "mcp" / f"{sid}.gateway.json").read_text())["launch"]
        child_env = clean_env()
        child_env.update({k: v for k, v in launch["env"]})
        t0 = now()
        proc = subprocess.Popen([launch["command"], *launch["args"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=child_env, text=True, bufsize=1,
                                cwd=launch.get("cwd") or None)
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "claude-code", "version": "bench"}}}) + "\n")
        proc.stdin.flush()
        proc.stdout.readline()
        t1 = now()
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}) + "\n")
        proc.stdin.flush()
        proc.stdout.readline()
        t2 = now()
        proc.terminate()
        return [{"arm": "mcp", "turn": "cold", "run": run, "initialize": round((t1 - t0) * 1000),
                 "first_list": round((t2 - t1) * 1000)}]
    finally:
        subprocess.run([a.acpmux_bin, "archive", name], capture_output=True, env=env)


ARMS = {"stdio": arm_stdio, "acpmux": arm_acpmux, "tui": arm_tui, "gui": arm_gui, "mcp": arm_mcp}
METRICS = ["spawn", "start_wait", "first_token", "daemon_first_token", "first_block", "first_tool", "tool_rt",
           "model_after_tool", "throughput", "total", "cpu_s", "rss_mb", "daemon_cpu_s", "initialize", "first_list"]


def summarize(rows: list[dict]) -> dict:
    out: dict = {}
    for r in rows:
        for metric in METRICS:
            if r.get(metric) is not None:
                out.setdefault((r["arm"], r["turn"], metric), []).append(r[metric])
    return out


def guard(summary: dict) -> list[str]:
    failed = []
    for (arm, turn, metric), limit in GUARDS.items():
        if metric == "tool_rt_over_stdio":
            a, b = pct(summary.get((arm, turn, "tool_rt"), []), .5), pct(summary.get(("stdio", turn, "tool_rt"), []), .5)
            value = a - b if a is not None and b is not None else None
        else:
            value = pct(summary.get((arm, turn, metric), []), .5)
        if value is not None and value > limit:
            failed.append(f"{arm} {turn} {metric} p50 {value:.0f} ms > {limit} ms")
    return failed


def table(summary: dict, arms: list[str]) -> str:
    lines = ["| turn | metric | " + " | ".join(f"{arm} p50 / p90" for arm in arms) + " |",
             "|---|---|" + "---|" * len(arms)]
    for turn in ("cold", "warm"):
        for metric in METRICS:
            cells = []
            for arm in arms:
                vals = summary.get((arm, turn, metric))
                cells.append(f"{pct(vals, .5):.0f} / {pct(vals, .9):.0f}" if vals else "")
            if any(cells):
                lines.append(f"| {turn} | {metric} | " + " | ".join(cells) + " |")
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--arms", default="stdio,acpmux")
    p.add_argument("--runs", type=int, default=5)
    p.add_argument("--mcp-runs", type=int, default=8)
    p.add_argument("--model", default="claude-opus-5-5")
    p.add_argument("--effort", default="medium")
    p.add_argument("--harness", default="claude-sr2", help="acpmux harness profile (acpmux and gui arms)")
    p.add_argument("--claude", default=str(Path.home() / ".local/bin/claude-sr2"),
                   help="the Claude Code launcher the harness profile runs (stdio and tui arms)")
    p.add_argument("--tui-cmd", nargs="+", help="the TUI command (default: --claude with the same model and effort)")
    p.add_argument("--cwd", default=None, help="the folder every arm runs in (default: a new empty one)")
    p.add_argument("--acpmux-bin", default=shutil.which("acpmux") or "acpmux")
    p.add_argument("--acpmux-home", default=os.environ.get("ACPMUX_HOME") or str(Path.home() / ".acpmux"))
    p.add_argument("--app-socket", help="gui arm: the app's control socket")
    p.add_argument("--pane", default="focused", help="gui arm: the pane to open chats in")
    p.add_argument("--tool-selector", default="[data-tool-call-id], .acpmux-tool-call")
    p.add_argument("--text-selector", default="[data-role=assistant] .markdown, .acpmux-agent-message")
    p.add_argument("--guard", action="store_true", help="exit 1 when a guarded p50 is over its limit")
    p.add_argument("--json", help="write every row here too")
    a = p.parse_args()
    a.cwd = a.cwd or tempfile.mkdtemp(prefix="claude-vs-acpmux-")
    arms = [x for x in a.arms.split(",") if x]
    rows, errors = [], []
    for run in range(1, (a.mcp_runs if arms == ["mcp"] else a.runs) + 1):
        for arm in arms:
            if arm == "mcp" and run > a.mcp_runs:
                continue
            try:
                got = ARMS[arm](a, run)
                rows.extend(got)
                print(f"# run {run} {arm}: " + "; ".join(
                    f"{r['turn']} " + " ".join(f"{k}={r[k]}" for k in METRICS if r.get(k) is not None) for r in got),
                    file=sys.stderr, flush=True)
            except Exception as e:  # one failed run is reported, the rest still count
                errors.append(f"run {run} {arm}: {e}")
                print(f"# run {run} {arm} failed: {e}", file=sys.stderr, flush=True)
    summary = summarize(rows)
    print(table(summary, arms))
    env = {"model": a.model, "effort": a.effort, "harness": a.harness, "cwd": a.cwd, "host": socket.gethostname(),
           "load": os.getloadavg()[0], "prompt": PROMPT}
    print(f"{LINE} " + json.dumps({"bench": "claude-vs-acpmux", "rows": rows, "errors": errors, "env": env}))
    if a.json:
        Path(a.json).write_text(json.dumps({"rows": rows, "errors": errors, "env": env}, indent=1))
    failed = guard(summary) if a.guard else []
    for f in failed:
        print(f"GUARD FAILED: {f}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
