#!/usr/bin/env python3
"""The bytes the acpmux daemon's journal writes per hour, and their write amplification (cmuxterm-hq#11322).

macOS filed a "disk writes" resource report against the daemon: 2 GB of file-backed memory dirtied in
11,502 s, its stack `pwrite` under `cmux_journal::storage::FsFile::append`. The kernel charges a write by
the pages it dirties: a page that a sync cleaned is charged again in full by the next write into it, so a
journal that syncs often costs a page (16 KiB on arm64 macOS) per sync however few bytes it adds. Goal
chats-flat-at-any-length: those bytes per hour stay flat as chats grow and more of them are open.

One release acpmux daemon per case on a scratch home on a real disk (not tmpfs: tmpfs charges no dirtied
page), on an ACP stand-in agent (this script's --agent mode over cmux-tui/crates/acpmux/tests/fake_agent.py),
in real time (the journal batches by time, so a time-compressed run would batch more than a person's does):

  idle     CHATS chats, each one short turn, then IDLE seconds with one client attached to each chat,
           shown, as the app keeps them;
  stream   one chat whose agent streams turn after turn, an agent_message_chunk every --chunk-ms (a
           model's token stream) and tool calls with cumulative tool_call_update output, for STREAM
           seconds, with a client attached and shown that reads the events, says what it saw
           (`_acpmux/seen`) once a second and lists the chats every 2 s, as the app does;
  typing   one chat whose composer a person types into: a `_acpmux/draft_set` (a kept change) every
           --key-ms (150 ms), each answered before the next, for TYPING seconds;
  terminal no case: terminal output never reaches this journal (its only writer is acpmux's store,
           `cmux-tui/crates/acpmux/src/store/journal_store.rs`: chat event lines and chat metadata).

For each case, between the case's start and end (after the daemon is up and the chats exist):
  payload   the bytes of the records' payloads the journal took (read back from its segments);
  logical   the bytes the journal's writer thread wrote (`wchar` of /proc/<pid>/task/<tid>/io: records,
            their 20-byte headers, sync markers);
  dirtied   the bytes of pages the writer dirtied (`write_bytes`: Linux charges one 4 KiB page each time
            a clean page becomes dirty, as macOS charges a 16 KiB one);
  syncs     the sync markers it wrote (one per sync that covered records);
  and the same `write_bytes` for the whole daemon (the chats' own events/*.ndjson logs, session.json).
Write amplification is dirtied over payload. The macOS estimate splits the 4 KiB page charges into the
pages the bytes fill (logical / 4 KiB) and the pages a sync made clean that a write dirtied again (the
rest); on arm64 macOS the first are the same bytes and each of the second is a 16 KiB page.

Output: JWRITES lines per case, PERF_ROW lines journal_writes.<case>.{payload,dirtied,macos_est}_mb_per_hour
and journal_writes.<case>.amplification, and --out JSON.

  journal-writes.py --acpmux BIN [--cases idle,stream,typing] [--idle 300] [--stream 300] [--typing 120] [--out result.json]
"""

import argparse
import importlib.util
import json
import os
import socket
import struct
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FAKE_AGENT = os.path.join(ROOT, "cmux-tui/crates/acpmux/tests/fake_agent.py")
HARNESS = "bench-fake"
PAGE = 4096
MACOS_PAGE = 16384
RECORD_HEADER = 20
SEGMENT_HEADER = 56
WORDS = ("the build of acpmux on the fleet runner finished and the journal segment rolled over while the hub "
         "streamed deltas to every attached client so the coordinator checks the pull request and its reds "
         "against base then queues the next lane with its brief and stop condition").split()


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ the agent (--agent)


def run_agent():
    """fake_agent.py with one more prompt: "stream: N CHUNK_MS" streams a turn in real time."""
    spec = importlib.util.spec_from_file_location("fake_agent", FAKE_AGENT)
    fake = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fake)
    inner = fake.handle_prompt

    def handle_prompt(rid, params):
        text = fake.prompt_text(params)
        if not text.startswith("stream:"):
            return inner(rid, params)
        sid = params["sessionId"]
        n, chunk_ms = (int(x) for x in text[7:].split())
        gap = chunk_ms / 1000.0

        def chunk(t):
            fake.update(sid, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}})
            time.sleep(gap)  # bench: a model's token pace

        def prose(words):
            for i in range(words):
                chunk(WORDS[(n * 7 + i * 3) % len(WORDS)] + " ")

        prose(120)
        for call in range(3):
            tid = f"call-{n}-{call}"
            command = f"cargo test -p acpmux --lib hub::retention -- case_{n}_{call}"
            fake.update(sid, {"sessionUpdate": "tool_call", "toolCallId": tid, "title": f"Run {command}",
                              "kind": "execute", "status": "in_progress", "rawInput": {"command": command}})
            out = ""
            for step in range(4):
                time.sleep(0.5)  # bench: the command runs
                out += "".join(f"test hub::retention::case_{n}_{call}_{step}_{line} ... ok\n" for line in range(6))
                upd = {"sessionUpdate": "tool_call_update", "toolCallId": tid,
                       "content": [{"type": "content", "content": {"type": "text", "text": out}}]}
                if step == 3:
                    upd["status"] = "completed"
                fake.update(sid, upd)
            prose(40)
        fake.send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})

    fake.handle_prompt = handle_prompt
    fake.main()


# ------------------------------------------------------------------ a client


class Client:
    """One connection; a reader thread answers calls by id and counts the rest (events)."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(path)
        self.lock = threading.Lock()
        self.waiting = {}
        self.next_id = 1
        self.events = 0
        self.last_seq = 0
        self.closed = False
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        buf = b""
        try:
            while True:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    msg = json.loads(line)
                    rid = msg.get("id")
                    if rid is not None and ("result" in msg or "error" in msg) and rid in self.waiting:
                        slot = self.waiting[rid]
                        slot[1] = msg
                        slot[0].set()
                        continue
                    self.events += 1
                    seq = (msg.get("params") or {}).get("seq")
                    if isinstance(seq, int):
                        self.last_seq = max(self.last_seq, seq)
        except OSError:
            pass
        self.closed = True
        for slot in list(self.waiting.values()):
            slot[0].set()

    def call(self, method, params, timeout=600):
        with self.lock:
            rid = self.next_id
            self.next_id += 1
        slot = [threading.Event(), None]
        self.waiting[rid] = slot
        self.sock.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        if not slot[0].wait(timeout) or slot[1] is None:
            raise RuntimeError(f"{method}: no answer")
        self.waiting.pop(rid, None)
        if "error" in slot[1]:
            raise RuntimeError(f"{method}: {slot[1]['error']}")
        return slot[1]["result"]

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


# ------------------------------------------------------------------ the daemon


def load_growth():
    spec = importlib.util.spec_from_file_location("chat_disk_growth", os.path.join(HERE, "chat-disk-growth.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def daemon_class(growth):
    """chat-disk-growth.py's daemon, with this script as its agent (its config names its module's file)."""
    growth.__file__ = os.path.abspath(__file__)
    return growth.Daemon


def writer_tid(pid):
    for tid in os.listdir(f"/proc/{pid}/task"):
        try:
            comm = open(f"/proc/{pid}/task/{tid}/comm").read().strip()
        except OSError:
            continue
        if comm.startswith("cmux-journal"):
            return tid
    return None


def read_io(path):
    out = {}
    try:
        for line in open(path):
            key, _, value = line.partition(":")
            out[key.strip()] = int(value)
    except OSError:
        pass
    return out


def segments(home):
    d = os.path.join(home, "journal")
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".seg"))
    except OSError:
        return {}
    return {n: os.path.getsize(os.path.join(d, n)) for n in names}


def parse_region(path, start, end, into):
    """Records and markers in bytes [start, end) of a segment (start at an entry boundary)."""
    with open(path, "rb") as f:
        f.seek(start)
        data = f.read(end - start)
    at = 0
    while at + RECORD_HEADER <= len(data):
        _crc, length, _lsn, kind, klass, flags = struct.unpack_from("<IIQHBB", data, at)
        if at + RECORD_HEADER + length > len(data):
            break
        payload = data[at + RECORD_HEADER: at + RECORD_HEADER + length]
        if flags == 1:
            into["markers"] += 1
            into["seq"].append(None)
        else:
            into["records"] += 1
            into["payload"] += length
            label = f"kind{kind}/{'ack' if klass == 1 else 'stream'}"
            stamp = None
            if kind == 1 and len(payload) >= 4:
                idlen = struct.unpack_from("<I", payload)[0]
                try:
                    line = json.loads(payload[4 + idlen:])
                    label += f" {line.get('dir')}:{line.get('kind')}"
                    stamp = line.get("at")
                except ValueError:
                    pass
            into["seq"].append((klass == 1, label, stamp))
            row = into["by"].setdefault(label, [0, 0])
            row[0] += 1
            row[1] += length
        at += RECORD_HEADER + length
    return at


class Probe:
    def __init__(self, daemon):
        self.d = daemon
        self.pid = daemon.proc.pid
        self.tid = writer_tid(self.pid)
        if not self.tid:
            raise RuntimeError("no cmux-journal writer thread in the daemon")

    def snap(self):
        return {"t": time.monotonic(), "seg": segments(self.d.home),
                "writer": read_io(f"/proc/{self.pid}/task/{self.tid}/io"),
                "proc": read_io(f"/proc/{self.pid}/io")}

    def diff(self, a, b):
        acc = {"records": 0, "payload": 0, "markers": 0, "by": {}, "seq": []}
        jdir = os.path.join(self.d.home, "journal")
        for name, size in b["seg"].items():
            start = a["seg"].get(name, SEGMENT_HEADER)
            if size > start:
                parse_region(os.path.join(jdir, name), start, size, acc)
        secs = b["t"] - a["t"]
        w = {k: b["writer"].get(k, 0) - a["writer"].get(k, 0) for k in ("wchar", "syscw", "write_bytes")}
        p = {k: b["proc"].get(k, 0) - a["proc"].get(k, 0) for k in ("wchar", "syscw", "write_bytes")}
        return secs, acc, w, p


# ------------------------------------------------------------------ cases


def new_chat(client, d, name):
    made = client.call("session/new", {"cwd": d.root, "mcpServers": [], "_meta": {"acpmux": {"name": name}}})
    return made["sessionId"]


def attach(client, sid):
    res = client.call("_acpmux/attach", {"sessionId": sid, "limit": 50, "visible": True})
    client.last_seq = max(client.last_seq, res.get("lastSeq") or 0)


def case_idle(args, Daemon):
    d = Daemon(args, "idle")
    d.start()
    try:
        c = Client(d.sock)
        sids = []
        for i in range(args.chats):
            sid = new_chat(c, d, f"idle {i}")
            c.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": f"hello {i}"}]})
            sids.append(sid)
        viewers = []
        for sid in sids:
            v = Client(d.sock)
            attach(v, sid)
            viewers.append(v)
        time.sleep(5)  # bench: let the setup's writes settle before the window opens
        probe = Probe(d)
        a = probe.snap()
        time.sleep(args.idle)  # bench: the idle window itself
        b = probe.snap()
        for v in viewers:
            v.close()
        c.close()
        return probe.diff(a, b)
    finally:
        d.stop()


def case_stream(args, Daemon):
    d = Daemon(args, "stream")
    d.start()
    try:
        c = Client(d.sock)
        sid = new_chat(c, d, "stream")
        c.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "hello"}]})
        viewer = Client(d.sock)
        attach(viewer, sid)
        stop, seen_ms = threading.Event(), []

        def app():
            tick = 0
            while not stop.wait(1.0):
                tick += 1
                try:
                    if viewer.last_seq:
                        t0 = time.perf_counter()
                        viewer.call("_acpmux/seen", {"sessionId": sid, "seq": viewer.last_seq}, timeout=30)
                        seen_ms.append((time.perf_counter() - t0) * 1000.0)
                    if tick % 2 == 0:
                        viewer.call("_acpmux/sessions", {}, timeout=30)
                except RuntimeError as exc:
                    log(f"app: {exc}")

        time.sleep(2)  # bench: the setup settles
        probe = Probe(d)
        a = probe.snap()
        threading.Thread(target=app, daemon=True).start()
        deadline = time.monotonic() + args.stream
        turns = 0
        while time.monotonic() < deadline:
            turns += 1
            c.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": f"stream: {turns} {args.chunk_ms}"}]})
        b = probe.snap()
        stop.set()
        log(f"stream: {turns} turns, viewer saw {viewer.events} messages")
        viewer.close()
        c.close()
        out = probe.diff(a, b)
        out[1]["lat"] = {"seen": seen_ms}
        return out
    finally:
        d.stop()


def case_typing(args, Daemon):
    """A person types into one chat's composer: a `_acpmux/draft_set` per key, --key-ms apart."""
    d = Daemon(args, "typing")
    d.start()
    try:
        c = Client(d.sock)
        sid = new_chat(c, d, "typing")
        c.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": "hello"}]})
        time.sleep(2)  # bench: the setup settles
        probe = Probe(d)
        a = probe.snap()
        deadline = time.monotonic() + args.typing
        text, keys, source, key_ms = "", 0, " ".join(WORDS), []
        while time.monotonic() < deadline:
            keys += 1
            text = (text + source[keys % len(source)])[-400:]
            t0 = time.perf_counter()
            c.call("_acpmux/draft_set", {"sessionId": sid, "text": text})
            key_ms.append((time.perf_counter() - t0) * 1000.0)
            time.sleep(args.key_ms / 1000.0)  # bench: a person's typing pace
        b = probe.snap()
        log(f"typing: {keys} keys")
        c.close()
        out = probe.diff(a, b)
        out[1]["lat"] = {"draft_set": key_ms}
        return out
    finally:
        d.stop()


# ------------------------------------------------------------------ main


ROWS = []


def report_syncs(case, acc, per_h):
    """What each sync covered: the records between two markers went out in one sync (a marker follows
    each sync that covered records, before the next records it writes). Acked records per sync, and the
    first acked syncs with their records' `at` stamps, show whether a turn's acks share syncs."""
    groups, cur = [], []
    for entry in acc["seq"]:
        if entry is None:
            if cur:
                groups.append(cur)
            cur = []
        else:
            cur.append(entry)
    acked = [g for g in groups if any(e[0] for e in g)]
    acks = sum(1 for g in groups for e in g if e[0])
    print(f"JWRITES {case} syncs: {len(groups)} covered records ({len(groups) * per_h:.0f}/h), {len(acked)} "
          f"held acked records ({len(acked) * per_h:.0f}/h); {acks} acked records, "
          f"{acks / len(acked) if acked else 0:.2f} per acked sync", flush=True)
    first = next((e[2] for g in acked for e in g if e[2]), None)
    for g in acked[:24]:
        labels = ", ".join(e[1].split(" ", 1)[-1] for e in g if e[0])
        stamps = [e[2] for e in g if e[0] and e[2]]
        when = f"+{stamps[0] - first} ms" if stamps and first else "?"
        print(f"JWRITES {case} acked sync {when}: {sum(1 for e in g if not e[0])} stream + [{labels}]", flush=True)


def perf_row(name, value, unit):
    row = {"name": name, "p50": round(value, 4), "p95": round(value, 4), "unit": unit}
    ROWS.append(row)
    print("PERF_ROW " + json.dumps(row), flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--agent", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--acpmux")
    p.add_argument("--cases", default="idle,stream")
    p.add_argument("--chats", type=int, default=3)
    p.add_argument("--idle", type=float, default=300.0)
    p.add_argument("--stream", type=float, default=300.0)
    p.add_argument("--typing", type=float, default=120.0)
    p.add_argument("--key-ms", type=int, default=150)
    p.add_argument("--chunk-ms", type=int, default=30)
    p.add_argument("--root-dir", default=None, help="a folder on a real disk (default: the checkout's parent)")
    p.add_argument("--out")
    p.add_argument("--keep", action="store_true")
    args = p.parse_args()
    if args.agent:
        return run_agent()
    if not args.acpmux:
        p.error("--acpmux is required")
    if args.root_dir is None:
        args.root_dir = tempfile.mkdtemp(prefix="jwrites-", dir=os.path.dirname(ROOT))
    growth = load_growth()
    Daemon = daemon_class(growth)
    result = {}
    mb = 1048576.0
    for case in args.cases.split(","):
        log(f"case {case}")
        secs, acc, w, proc = {"idle": case_idle, "stream": case_stream, "typing": case_typing}[case](args, Daemon)
        per_h = 3600.0 / secs
        amp = w["write_bytes"] / acc["payload"] if acc["payload"] else float("inf") if w["write_bytes"] else 0.0
        redirtied = max(0, w["write_bytes"] // PAGE - -(-w["wchar"] // PAGE))
        macos = redirtied * MACOS_PAGE + w["wchar"]
        row = {"seconds": secs, "records": acc["records"], "payload": acc["payload"], "markers": acc["markers"],
               "writer": w, "process": proc, "by": acc["by"],
               "per_hour": {"payload": acc["payload"] * per_h, "logical": w["wchar"] * per_h,
                            "dirtied": w["write_bytes"] * per_h, "macos_est": macos * per_h,
                            "syncs": acc["markers"] * per_h, "writes": w["syscw"] * per_h,
                            "process_dirtied": proc["write_bytes"] * per_h},
               "amplification": amp}
        result[case] = row
        h = row["per_hour"]
        print(f"JWRITES {case} {secs:.0f} s: {acc['records']} records, payload {acc['payload']} B, "
              f"writer wchar {w['wchar']} B in {w['syscw']} writes, dirtied {w['write_bytes']} B, "
              f"{acc['markers']} syncs; process dirtied {proc['write_bytes']} B", flush=True)
        print(f"JWRITES {case} per hour: payload {h['payload'] / mb:.2f} MB, logical {h['logical'] / mb:.2f} MB, "
              f"dirtied {h['dirtied'] / mb:.2f} MB (macOS est {h['macos_est'] / mb:.2f} MB), {h['syncs']:.0f} syncs, "
              f"process dirtied {h['process_dirtied'] / mb:.2f} MB; amplification {amp:.1f}x", flush=True)
        for label, (n, size) in sorted(acc["by"].items(), key=lambda kv: -kv[1][0]):
            print(f"JWRITES {case} by {label}: {n} records {size} B ({n * per_h:.0f}/h)", flush=True)
        report_syncs(case, acc, per_h)
        for name, values in sorted(acc.get("lat", {}).items()):
            if values:
                values = sorted(values)
                pick = lambda q: values[min(len(values) - 1, int(q * len(values)))]
                print(f"JWRITES {case} latency {name}: n={len(values)} p50 {pick(0.5):.2f} ms, "
                      f"p95 {pick(0.95):.2f} ms, max {values[-1]:.2f} ms", flush=True)
                row["latency_" + name] = {"p50": pick(0.5), "p95": pick(0.95), "max": values[-1]}
        perf_row(f"journal_writes.{case}.payload_mb_per_hour", h["payload"] / mb, "MB")
        perf_row(f"journal_writes.{case}.dirtied_mb_per_hour", h["dirtied"] / mb, "MB")
        perf_row(f"journal_writes.{case}.macos_est_mb_per_hour", h["macos_est"] / mb, "MB")
        perf_row(f"journal_writes.{case}.amplification", amp, "x")
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"cases": result, "rows": ROWS}, f, indent=1)
    if not args.keep:
        import shutil
        shutil.rmtree(args.root_dir, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
