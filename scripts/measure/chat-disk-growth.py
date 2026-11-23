#!/usr/bin/env python3
"""One live acpmux chat's history bytes per simulated hour, against an empty chat's (chats flat at any length).

Goal (cmuxterm-hq goals/chats-flat-at-any-length.md): per-chat disk use is bounded. A chat's old history is
compacted or paged, never grown forever: a chat at 100k rows costs at most 1.2x an empty chat in disk growth
per hour. On huge-blue one busy live chat's `sessions/<id>/events/*.ndjson` held 1,008 MB in 126 segments after
13 days. This measures that slope on a scratch daemon, time-compressed: no real-time soak.

Two release acpmux daemons on scratch homes, both on the ACP stand-in agent
(cmux-tui/crates/acpmux/tests/fake_agent.py, run through this script's --agent mode, which adds one prompt):

  long   one chat streamed turn after turn, back to back, until it holds --rows rows;
  empty  one chat with one turn, then idle while the long one streams (the same wall time, so the same
         simulated hours).

The simulated clock: one turn every --turn-secs simulated seconds (default 30 s, a busy coordinator), so
hour h is the end of turn h * 3600 / turn-secs. No sleep makes an hour pass; turns run as fast as the daemon
takes them.

A turn ("coord: N", shaped like a coordinator's): the prompt, prose in agent_message_chunk deltas, then
TOOLS tool calls, each a tool_call and UPDATES tool_call_update records whose content is the command's whole
output so far (cumulative, as codex-acp sends it), the last one completed, each followed by prose. Rows, as a
chat shows them: the prompt, each prose run, each tool call: 2 + 2 * TOOLS = 8 per turn at TOOLS=3.
At 8 rows a turn, 100,000 rows is 12,500 turns, 104.2 simulated hours at 30 s a turn.

Samples every --sample-turns turns: bytes on disk (st_blocks) of the chat's session dir (events/, its index
files, session.json, the rest), of the daemon's other state (every other file of its home), for both daemons.
Then:
  bytes per simulated hour at steady streaming (least-squares slope after the first 10% of turns), long and
  empty, and their ratio (the empty slope floored at FLOOR_BYTES_PER_HOUR, one 4 KiB block an hour, so an
  idle chat that writes nothing is no division by 0);
  the early (first 20% of turns) and late (last 20%) slopes of the long chat: whether a turn costs more disk
  as the history behind it grows;
  whether the long chat's bytes ever went down between samples (rotation, compaction);
  at the end, `_acpmux/retention {dryRun, olderThanDays: 0}`: what the daemon's retention would do to the
  live chat now, and again after `session/close` (still skipped then, as `agent` or `attached`: the bench's
  own connection and the chat's agent are still there).

First Linux result (cmux-ci, release acpmux at f7e519b2e14, 2026-11-15): 100,000 rows = 152.1 MB of
events/*.ndjson in 19 segments, 1.46 MB per simulated hour flat from the first hour to the last (late/early
1.01x); the empty chat 32 KB, 0 B/h; ratio 374x against the 4 KiB/h floor. Nothing ever shrank it (0 falls;
retention skips it as `open`). The daemon's journal/*.seg grew 67 MB beside it, ledger/turns.jsonl 4 MB.

Hot bytes are the chat's folder minus cold-segments/ (`store/cold_segments.rs`, where sealed segments move
compressed when agents.chats.coldSegments is on); total bytes count both. --cold-segments turns that setting on
for both daemons (in their own CMUX_NEXT_CONFIG_FILE); without it the daemon's default applies.

Output: CHATDISK lines, CHATDISK-FILES lines (the files that grow, ids folded to *), PERF_ROW lines
chat_disk.hot_growth_ratio (x, target 1.2: hot bytes, the goal's row), chat_disk.growth_ratio (x, every
byte), chat_disk.long_hot_mb_per_hour, chat_disk.long_mb_at_100k (MB), chat_disk.long_mb_per_hour,
chat_disk.empty_mb_per_hour, chat_disk.late_over_early_slope, and --out JSON with every sample.
Measurement only: it signals and reads only the processes it started.

  chat-disk-growth.py --acpmux BIN [--rows 100000] [--turn-secs 30] [--sample-turns 250] [--out result.json]
"""

import argparse
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAKE_AGENT = os.path.join(ROOT, "cmux-tui/crates/acpmux/tests/fake_agent.py")
HARNESS = "bench-fake"
TOOLS = 3
UPDATES = 4
ROWS_PER_TURN = 2 + 2 * TOOLS
FLOOR_BYTES_PER_HOUR = 4096
WORDS = ("the build of acpmux on the fleet runner finished and the journal segment rolled over while the hub "
         "streamed deltas to every attached client so the coordinator checks the pull request and its reds "
         "against base then queues the next lane with its brief and stop condition").split()


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ the agent (--agent)


def prose(n, words):
    return " ".join(WORDS[(n * 7 + i * 3) % len(WORDS)] for i in range(words))


def run_agent():
    """fake_agent.py, with one more prompt: "coord: N" streams a coordinator-shaped turn."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("fake_agent", FAKE_AGENT)
    fake = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fake)
    inner = fake.handle_prompt

    def handle_prompt(rid, params):
        text = fake.prompt_text(params)
        if not text.startswith("coord:"):
            return inner(rid, params)
        sid, n = params["sessionId"], int(text[6:].strip() or 0)

        def chunk(t):
            fake.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}})
        for part in range(3):
            chunk(prose(n + part, 30) + (". " if part < 2 else ".\n"))
        for call in range(TOOLS):
            tid = f"call-{n}-{call}"
            command = f"cargo test -p acpmux --lib hub::retention -- case_{n}_{call}"
            fake.update(sid, {"sessionUpdate": "tool_call", "toolCallId": tid, "title": f"Run {command}",
                              "kind": "execute", "status": "in_progress", "rawInput": {"command": command}})
            out = ""
            for step in range(UPDATES):
                out += "".join(f"test hub::retention::case_{n}_{call}_{step}_{line} ... ok\n" for line in range(6))
                upd = {"sessionUpdate": "tool_call_update", "toolCallId": tid,
                       "content": [{"type": "content", "content": {"type": "text", "text": out}}]}
                if step == UPDATES - 1:
                    upd["status"] = "completed"
                fake.update(sid, upd)
            chunk(prose(n + call + 5, 20) + ".\n")
        fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})

    fake.handle_prompt = handle_prompt
    fake.main()


# ------------------------------------------------------------------ disk


def blocks(st):
    return st.st_blocks * 512 if hasattr(st, "st_blocks") else st.st_size


def du(path):
    total = 0
    for base, _, files in os.walk(path):
        for name in files:
            try:
                total += blocks(os.lstat(os.path.join(base, name)))
            except OSError:
                pass
    return total


# A path with its ids folded, so a file per chat or segment sums into one group (as infinite-items.py does).
FILE_ID = re.compile(r"[0-9a-f]{8,}|[0-9]+")


def file_groups(path):
    groups = {}
    for base, _, files in os.walk(path):
        for file in files:
            full = os.path.join(base, file)
            try:
                st = os.lstat(full)
            except OSError:
                continue
            key = FILE_ID.sub("*", os.path.relpath(full, path))
            groups[key] = groups.get(key, 0) + blocks(st)
    return groups


def chat_parts(chat_dir):
    """The chat's session dir by part: events/ (its .ndjson segments, the rest of events/), session.json, other."""
    parts = {"events_ndjson": 0, "events_other": 0, "session_json": 0, "cold": 0, "other": 0, "segments": 0}
    for base, _, files in os.walk(chat_dir):
        rel_base = os.path.relpath(base, chat_dir)
        for name in files:
            try:
                size = blocks(os.lstat(os.path.join(base, name)))
            except OSError:
                continue
            top = rel_base.split(os.sep)[0]
            if top == "events" and name.endswith(".ndjson"):
                parts["events_ndjson"] += size
                parts["segments"] += 1
            elif top == "events":
                parts["events_other"] += size
            elif top == "cold-segments":
                parts["cold"] += size
            elif rel_base == "." and name == "session.json":
                parts["session_json"] += size
            else:
                parts["other"] += size
    parts["total"] = sum(v for k, v in parts.items() if k != "segments")
    parts["hot"] = parts["total"] - parts["cold"]
    return parts


# ------------------------------------------------------------------ the daemon


class Acp:
    def __init__(self, path, timeout=120):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def read(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, method, params):
        rid = self.next_id
        self.next_id += 1
        self.sock.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        while True:
            msg = self.read()
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]


class Daemon:
    def __init__(self, args, name):
        self.args, self.name = args, name
        self.root = tempfile.mkdtemp(prefix=f"chatdisk-{name}-", dir=args.root_dir)
        self.home = os.path.join(self.root, "acpmux")
        self.sock = os.path.join(self.root, "a.sock")
        os.makedirs(self.home, mode=0o700)
        os.makedirs(os.path.join(self.root, "home"))
        self.proc = None
        self.sid = None
        self.chat_dir = None

    def env(self):
        home = os.path.join(self.root, "home")
        env = dict(os.environ)
        env.update(HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
                   XDG_STATE_HOME=os.path.join(home, ".local/state"), XDG_DATA_HOME=os.path.join(home, ".local/share"),
                   XDG_CACHE_HOME=os.path.join(home, ".cache"), ACPMUX_HOME=self.home, ACPMUX_SOCKET=self.sock,
                   ACPMUX_UNUSED_EXIT_SECS="0", ACPMUX_SESSION_CPU_CLASS="normal")
        if getattr(self.args, "cold_segments", False):
            settings = os.path.join(self.root, "cmux-next.json")
            with open(settings, "w") as f:
                json.dump({"agents.chats.coldSegments": True}, f)
            env.update(CMUX_NEXT_CONFIG_FILE=settings)
        return env

    def start(self):
        with open(os.path.join(self.home, "config.json"), "w") as f:
            json.dump({"harnesses": {HARNESS: {"argv": [sys.executable, os.path.abspath(__file__), "--agent"]}},
                       "defaultHarness": HARNESS, "permissionPolicy": "allow"}, f)
        os.chmod(os.path.join(self.home, "config.json"), 0o600)
        ready = os.path.join(self.root, "acpmux.out")
        with open(ready, "w") as out, open(os.path.join(self.root, "acpmux.log"), "w") as err:
            self.proc = subprocess.Popen([self.args.acpmux, "daemon", "run", "--ready-fd", "1", "--log", "warn"],
                                         stdout=out, stderr=err, stdin=subprocess.DEVNULL, env=self.env(),
                                         start_new_session=True)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"{self.name} acpmux exited {self.proc.returncode}; see {self.root}")
            if os.path.exists(self.sock) and '"ready":true' in open(ready).read().replace(" ", ""):
                return
            time.sleep(0.1)  # bench: waiting for the daemon it started to listen
        raise RuntimeError(f"{self.name} acpmux not ready within 60 s")

    def new_chat(self, acp):
        made = acp.call("session/new", {"cwd": self.root, "mcpServers": [],
                                        "_meta": {"acpmux": {"name": f"chat-disk {self.name}"}}})
        self.sid = made["sessionId"]
        return self.sid

    def find_chat_dir(self):
        if self.chat_dir:
            return self.chat_dir
        for base, dirs, _ in os.walk(self.home):
            if self.sid in dirs:
                self.chat_dir = os.path.join(base, self.sid)
                return self.chat_dir
        return None

    def sample(self):
        chat_dir = self.find_chat_dir()
        chat = chat_parts(chat_dir) if chat_dir else {"total": 0}
        home = du(self.home)
        return {"chat": chat, "home": home, "other_state": home - chat["total"]}

    def stop(self):
        if self.proc and self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.proc.wait(timeout=30)
        if not self.args.keep:
            shutil.rmtree(self.root, ignore_errors=True)


# ------------------------------------------------------------------ numbers


def slope(xs, ys):
    if len(xs) < 2:
        return 0.0
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else 0.0


ROWS = []


def perf_row(name, value, unit, target=None):
    row = {"name": name, "p50": round(value, 4), "p95": round(value, 4), "unit": unit}
    if target is not None:
        row["target"] = target
    ROWS.append(row)
    print("PERF_ROW " + json.dumps(row), flush=True)


def retention(acp, label):
    try:
        res = acp.call("_acpmux/retention", {"dryRun": True, "olderThanDays": 0})
    except (OSError, RuntimeError, ValueError) as exc:
        res = {"error": str(exc)}
    text = json.dumps(res)
    print(f"CHATDISK-RETENTION {label} {text[:1500]}", flush=True)
    return res


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--agent", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--acpmux")
    p.add_argument("--rows", type=int, default=100_000)
    p.add_argument("--turn-secs", type=float, default=30.0, help="simulated seconds per turn")
    p.add_argument("--sample-turns", type=int, default=250)
    p.add_argument("--root-dir", default=None)
    p.add_argument("--out")
    p.add_argument("--keep", action="store_true")
    p.add_argument("--cold-segments", action="store_true", help="agents.chats.coldSegments on for both daemons")
    args = p.parse_args()
    if args.agent:
        return run_agent()
    if not args.acpmux:
        p.error("--acpmux is required")
    turns = -(-args.rows // ROWS_PER_TURN)
    hours_of = lambda t: t * args.turn_secs / 3600.0
    log(f"{turns} turns of {ROWS_PER_TURN} rows, {hours_of(turns):.1f} simulated hours at {args.turn_secs:g} s a turn")

    long_d, empty_d = Daemon(args, "long"), Daemon(args, "empty")
    samples, result = [], {}
    try:
        long_d.start()
        empty_d.start()
        empty_acp = Acp(empty_d.sock)
        empty_d.new_chat(empty_acp)
        empty_acp.call("session/prompt", {"sessionId": empty_d.sid, "prompt": [{"type": "text", "text": "coord: 0"}]})
        acp = Acp(long_d.sock)
        long_d.new_chat(acp)

        def take(turn, wall):
            s = {"turn": turn, "rows": turn * ROWS_PER_TURN, "sim_hours": hours_of(turn), "wall_s": wall,
                 "long": long_d.sample(), "empty": empty_d.sample()}
            samples.append(s)
            return s

        t0 = time.monotonic()
        take(0, 0.0)
        for turn in range(1, turns + 1):
            acp.call("session/prompt", {"sessionId": long_d.sid, "prompt": [{"type": "text", "text": f"coord: {turn}"}]})
            if turn % args.sample_turns == 0 or turn == turns:
                s = take(turn, time.monotonic() - t0)
                if turn % (args.sample_turns * 8) == 0 or turn == turns:
                    log(f"turn {turn} rows {s['rows']} sim {s['sim_hours']:.1f} h long chat "
                        f"{s['long']['chat']['total'] / 1048576:.1f} MB ({s['long']['chat']['segments']} segments) "
                        f"empty chat {s['empty']['chat']['total'] / 1024:.0f} KB wall {s['wall_s']:.0f} s")
        wall = time.monotonic() - t0

        # Anything that shrinks it: rotation or compaction would show as a fall between samples.
        drops = [(a["turn"], b["turn"], a["long"]["chat"]["total"] - b["long"]["chat"]["total"])
                 for a, b in zip(samples, samples[1:]) if b["long"]["chat"]["total"] < a["long"]["chat"]["total"]]
        ret_live = retention(acp, "live")
        before_close = long_d.sample()
        try:
            acp.call("session/close", {"sessionId": long_d.sid})
        except (OSError, RuntimeError, ValueError) as exc:
            log(f"session/close: {exc}")
        ret_closed = retention(acp, "closed")
        after = long_d.sample()
        acp.close()
        empty_acp.close()
        files = file_groups(long_d.home)
        result.update(wall_s=wall, drops=drops, retention_live=ret_live, retention_closed=ret_closed,
                      before_close=before_close, after_close_dry_run=after, files=files)
    finally:
        long_d.stop()
        empty_d.stop()

    # Steady streaming: after the first 10% of turns.
    steady = [s for s in samples if s["turn"] >= turns * 0.1]
    hrs = [s["sim_hours"] for s in steady]
    long_slope = slope(hrs, [s["long"]["chat"]["total"] for s in steady])
    long_home_slope = slope(hrs, [s["long"]["home"] for s in steady])
    empty_slope = slope(hrs, [s["empty"]["chat"]["total"] for s in steady])
    empty_home_slope = slope(hrs, [s["empty"]["home"] for s in steady])
    early = [s for s in samples if s["turn"] <= turns * 0.2]
    late = [s for s in samples if s["turn"] >= turns * 0.8]
    early_slope = slope([s["sim_hours"] for s in early], [s["long"]["chat"]["total"] for s in early])
    late_slope = slope([s["sim_hours"] for s in late], [s["long"]["chat"]["total"] for s in late])
    end = samples[-1]
    denom = max(empty_slope, FLOOR_BYTES_PER_HOUR)
    ratio = long_slope / denom
    long_hot_slope = slope(hrs, [s["long"]["chat"]["hot"] for s in steady])
    empty_hot_slope = slope(hrs, [s["empty"]["chat"]["hot"] for s in steady])
    hot_ratio = long_hot_slope / max(empty_hot_slope, FLOOR_BYTES_PER_HOUR)
    mb = 1048576.0
    print(f"CHATDISK rate {args.turn_secs:g} s/turn, {ROWS_PER_TURN} rows/turn, {turns} turns = {end['rows']} rows = "
          f"{end['sim_hours']:.1f} simulated hours in {result['wall_s']:.0f} s wall", flush=True)
    print(f"CHATDISK long chat at {end['rows']} rows: {end['long']['chat']['total'] / mb:.1f} MB "
          f"(events ndjson {end['long']['chat']['events_ndjson'] / mb:.1f} MB in {end['long']['chat']['segments']} segments, "
          f"events other {end['long']['chat']['events_other'] / mb:.2f} MB, session.json "
          f"{end['long']['chat']['session_json'] / 1024:.1f} KB, other {end['long']['chat']['other'] / mb:.2f} MB); "
          f"daemon other state {end['long']['other_state'] / mb:.2f} MB", flush=True)
    print(f"CHATDISK empty chat: {end['empty']['chat']['total'] / 1024:.1f} KB; daemon other state "
          f"{end['empty']['other_state'] / 1024:.1f} KB", flush=True)
    print(f"CHATDISK slope long chat {long_slope / mb:.3f} MB/h (home {long_home_slope / mb:.3f} MB/h), early "
          f"{early_slope / mb:.3f} late {late_slope / mb:.3f} MB/h; empty chat {empty_slope:.0f} B/h (home "
          f"{empty_home_slope:.0f} B/h); ratio {ratio:.0f}x (empty floored at {FLOOR_BYTES_PER_HOUR} B/h)", flush=True)
    print(f"CHATDISK shrinks: {len(result['drops'])} falls between samples {result['drops'][:5]}; after close, dry-run "
          f"chat bytes {result['after_close_dry_run']['chat']['total'] / mb:.1f} MB", flush=True)
    for key, size in sorted(result["files"].items(), key=lambda kv: -kv[1])[:8]:
        print(f"CHATDISK-FILES {size / mb:.2f} MB {key}", flush=True)
    print(f"CHATDISK hot (all but cold-segments/, cold segments {'on' if args.cold_segments else 'default'}): "
          f"long chat {long_hot_slope / mb:.3f} MB/h, {end['long']['chat']['hot'] / mb:.2f} MB at the end; empty chat "
          f"{empty_hot_slope:.0f} B/h; ratio {hot_ratio:.1f}x", flush=True)
    perf_row("chat_disk.hot_growth_ratio", hot_ratio, "x", target=1.2)
    perf_row("chat_disk.long_hot_mb_per_hour", long_hot_slope / mb, "MB/h")
    perf_row("chat_disk.growth_ratio", ratio, "x")
    perf_row("chat_disk.long_mb_at_100k", end["long"]["chat"]["total"] / mb, "MB")
    perf_row("chat_disk.long_mb_per_hour", long_slope / mb, "MB/h")
    perf_row("chat_disk.empty_mb_per_hour", empty_slope / mb, "MB/h")
    perf_row("chat_disk.late_over_early_slope", late_slope / early_slope if early_slope else 0.0, "x")
    print("PERF_REPORT " + json.dumps({"rows": ROWS}), flush=True)
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"args": {k: v for k, v in vars(args).items()}, "samples": samples, **result,
                       "rows": ROWS}, f)
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
