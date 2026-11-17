#!/usr/bin/env python3
"""Bench: an open chat's sealed segments go cold (`store/cold_segments.rs`), local vs cold MB/h and page-back cost.

Sibling of chat-disk-growth.py (same daemon, agent, turns and clock). Here one release acpmux daemon runs with the
setting agents.chats.coldSegments on at agents.chats.coldSegmentsLevel --level (3 by default), written to its own
settings file (CMUX_NEXT_CONFIG_FILE); --off runs the same chat with the setting off, the "before": every byte
local, the same page-back walk from the open segment's first seq. With it on, each sealed segment (512 KiB, COLD_ROLL_BYTES) of the live
chat moves to
<session>/cold-segments/NNNNNN.zst (zstd frames of ~128 KiB raw, cut at line ends), its chunk index goes in the
chat's one index events/segments.cold.idx (older builds: events/NNNNNN.cold.idx per segment), which stays local,
and only the open segment plus that index stay on the hot path.

1. Disk: every --sample-turns turns, the chat dir split into local bytes (all but cold-segments/) and cold bytes;
   least-squares slopes after the first 10% of turns: chat_disk.local_mb_per_hour, chat_disk.cold_mb_per_hour; the
   compression ratio (raw bytes over compressed, from the indexes) chat_disk.cold_ratio.
2. Page-back: from beforeSeq = the oldest local record's seq, `_acpmux/events {beforeSeq, limit: 400, maxBytes 1 MiB,
   kinds: [transcript]}` page after page back to seq 1, timed from the request's send to the reply's last byte.
   Cold cache: every file of the chat dir synced and dropped from the page cache (posix_fadvise DONTNEED) before each
   page; warm: the same walk again. Then the daemon stops, raw copies of the moved segments (decoded from each
   archive into ACPMUX_COLD_SEGMENTS_KEEP, out of the home, as it went cold) go back to events/, the archives go, and
   the daemon starts again with the setting off: the same pages all
   local, cold cache and warm. Every page must equal its all-local twin (asserted).
3. RAM: the daemon's VmRSS sampled every 2 ms during each walk (max, and its rise over the walk's start), and VmHWM.

  chat-cold-segments.py --acpmux BIN [--rows 100000] [--level 3] [--off] [--turn-secs 30] [--sample-turns 250] [--out result.json]
Measurement only: it signals and reads only the processes it started.
"""

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("chat_disk_growth", os.path.join(HERE, "chat-disk-growth.py"))
base = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(base)

COLD_DIR = "cold-segments"
INDEX_FILE = "segments.cold.idx"


def cold_entries(events):
    """Each cold segment's index entry in `events`, as (NNNNNN, doc): the chat's one index, and the per-segment files
    an older build wrote."""
    out = {}
    try:
        names = sorted(os.listdir(events))
    except OSError:
        return []
    for name in names:
        try:
            if name == INDEX_FILE:
                with open(os.path.join(events, name)) as f:
                    for seg, doc in json.load(f)["segments"].items():
                        out.setdefault(f"{int(seg):06d}", doc)
            elif name.endswith(".cold.idx") and len(name) == 6 + len(".cold.idx"):
                with open(os.path.join(events, name)) as f:
                    out.setdefault(name[:6], json.load(f))
        except (OSError, ValueError, KeyError):
            pass
    return sorted(out.items())
PAGE_LIMIT = 400
PAGE_BYTES = 1024 * 1024
MB = 1048576.0


class ColdDaemon(base.Daemon):
    def __init__(self, args, name):
        super().__init__(args, name)
        self.cold = True
        self.kept = os.path.join(self.root, "kept")

    def env(self):
        env = super().env()
        settings = os.path.join(self.root, "cmux-next.json")
        with open(settings, "w") as f:
            json.dump({"agents.chats.coldSegments": self.cold, "agents.chats.coldSegmentsLevel": self.args.level}, f)
        env.update(CMUX_NEXT_CONFIG_FILE=settings)
        if self.cold:
            env.update(ACPMUX_COLD_SEGMENTS_KEEP=self.kept)
        return env

    def halt(self):
        """Stops the daemon it started, keeping its home (Daemon.stop removes it unless --keep)."""
        keep, self.args.keep = self.args.keep, True
        try:
            self.stop()
        finally:
            self.args.keep = keep
        self.proc = None


def split(chat_dir):
    local = cold = 0
    raw = comp = 0
    for root, _, files in os.walk(chat_dir):
        top = os.path.relpath(root, chat_dir).split(os.sep)[0]
        for name in files:
            path = os.path.join(root, name)
            try:
                size = base.blocks(os.lstat(path))
            except OSError:
                continue
            if top == COLD_DIR:
                cold += size
            else:
                local += size
    for _, doc in cold_entries(os.path.join(chat_dir, "events")):
        raw += doc.get("rawLen", 0)
        comp += doc.get("compLen", 0)
    return {"local": local, "cold": cold, "raw": raw, "comp": comp}


def ndjson(chat_dir):
    events = os.path.join(chat_dir, "events")
    return sorted(int(n[:-7]) for n in os.listdir(events) if n.endswith(".ndjson") and n[:-7].isdigit())


def first_seq(path):
    with open(path, "rb") as f:
        for line in f:
            if line.strip():
                return json.loads(line)["seq"]
    return None


def drop_cache(chat_dir):
    for root, _, files in os.walk(chat_dir):
        for name in files:
            try:
                fd = os.open(os.path.join(root, name), os.O_RDONLY)
            except OSError:
                continue
            try:
                os.fsync(fd)
                os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
            except OSError:
                pass
            finally:
                os.close(fd)


def rss_kb(pid, key="VmRSS"):
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith(key + ":"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


class RssSampler(threading.Thread):
    def __init__(self, pid):
        super().__init__(daemon=True)
        self.pid, self.stop_flag, self.peak = pid, threading.Event(), 0
        self.start_kb = rss_kb(pid)

    def run(self):
        while not self.stop_flag.is_set():
            self.peak = max(self.peak, rss_kb(self.pid))
            time.sleep(0.002)  # bench: RSS sampling interval

    def done(self):
        self.stop_flag.set()
        self.join()
        peak = max(self.peak, rss_kb(self.pid))
        return {"start_kb": self.start_kb, "peak_kb": peak, "rise_kb": peak - self.start_kb,
                "hwm_kb": rss_kb(self.pid, "VmHWM")}


def timed_call(acp, method, params):
    """acp.call, timed from the send to the reply line's last byte (before its JSON parse)."""
    rid = acp.next_id
    acp.next_id += 1
    t0 = time.perf_counter()
    acp.sock.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
    while True:
        while b"\n" not in acp.buf:
            chunk = acp.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("socket closed")
            acp.buf += chunk
        line, acp.buf = acp.buf.split(b"\n", 1)
        t1 = time.perf_counter()
        msg = json.loads(line)
        if msg.get("id") == rid and ("result" in msg or "error" in msg):
            if "error" in msg:
                raise RuntimeError(f"{method}: {msg['error']}")
            return msg["result"], (t1 - t0) * 1000.0, len(line)


def walk(acp, daemon, sid, start_before, cold_cache, max_pages):
    sampler = RssSampler(daemon.proc.pid)
    sampler.start()
    pages, before = [], start_before
    try:
        while before > 1 and len(pages) < max_pages:
            if cold_cache:
                drop_cache(daemon.chat_dir)
            res, ms, size = timed_call(acp, "_acpmux/events", {"sessionId": sid, "beforeSeq": before, "limit": PAGE_LIMIT,
                                                               "maxBytes": PAGE_BYTES, "kinds": ["transcript"]})
            events = res.get("events") or []
            pages.append({"before": before, "ms": ms, "bytes": size, "n": len(events), "digest": hashlib.sha256(json.dumps(events, sort_keys=True).encode()).hexdigest(),
                          "head": json.dumps(events[:2])[:600],
                          "has_more": res.get("hasMore")})
            if not events:
                break
            before = min(e["seq"] for e in events)
    finally:
        rss = sampler.done()
    return pages, rss


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return 0.0
    k = (len(xs) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def stats(pages):
    ms = [p["ms"] for p in pages]
    return {"pages": len(pages), "p50_ms": round(pct(ms, 50), 2), "p95_ms": round(pct(ms, 95), 2),
            "max_ms": round(max(ms) if ms else 0, 2), "records": sum(p["n"] for p in pages),
            "mean_kb": round(sum(p["bytes"] for p in pages) / max(1, len(pages)) / 1024, 1)}


def main_off(args, turns, hours_of):
    """The before: the same chat with the setting off, every byte local; the page-back walk from the open
    segment's first seq, as the cold run walks."""
    d = ColdDaemon(args, "off")
    d.cold = False
    samples = []
    try:
        d.start()
        acp = base.Acp(d.sock)
        sid = d.new_chat(acp)
        t0 = time.monotonic()

        def take(turn):
            d.find_chat_dir()
            s = {"turn": turn, "sim_hours": hours_of(turn), **(split(d.chat_dir) if d.chat_dir else {})}
            samples.append(s)
            return s

        take(0)
        for turn in range(1, turns + 1):
            acp.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": f"coord: {turn}"}]})
            if turn % args.sample_turns == 0 or turn == turns:
                take(turn)
        wall = time.monotonic() - t0
        end = take(turns)
        segs = ndjson(d.chat_dir)
        assert not os.path.exists(os.path.join(d.chat_dir, COLD_DIR)), "the setting is off: nothing goes cold"
        oldest_local = first_seq(os.path.join(d.chat_dir, "events", f"{segs[-1]:06d}.ndjson"))
        acp.close()
        d.halt()
        d.start()
        acp = base.Acp(d.sock)
        local_cold, rss_lc = walk(acp, d, sid, oldest_local, True, args.max_pages)
        local_warm, rss_lw = walk(acp, d, sid, oldest_local, False, args.max_pages)
        acp.close()
    finally:
        d.stop()
    steady = [s for s in samples if s["turn"] >= turns * 0.1]
    hrs = [s["sim_hours"] for s in steady]
    local_slope = base.slope(hrs, [s["local"] for s in steady])
    print(f"CHATCOLD off: {turns} turns, {end['sim_hours']:.1f} simulated hours in {wall:.0f} s wall; {len(segs)} segments",
          flush=True)
    print(f"CHATCOLD off end: local {end['local'] / MB:.2f} MB, cold {end['cold'] / MB:.2f} MB", flush=True)
    print(f"CHATCOLD off slopes: local {local_slope / MB:.3f} MB/h", flush=True)
    base.perf_row("chat_disk.off.local_mb", end["local"] / MB, "MB")
    base.perf_row("chat_disk.off.local_mb_per_hour", local_slope / MB, "MB/h")
    for name, (pages, rss) in {"local_cold_cache": (local_cold, rss_lc), "local_warm": (local_warm, rss_lw)}.items():
        st = stats(pages)
        print(f"CHATCOLD off walk {name}: {json.dumps(st)} rss {json.dumps(rss)}", flush=True)
        row = {"name": f"chat_cold.off.page_back.{name}", "p50": st["p50_ms"], "p95": st["p95_ms"], "max": st["max_ms"],
               "unit": "ms"}
        base.ROWS.append(row)
        print("PERF_ROW " + json.dumps(row), flush=True)
    print("PERF_REPORT " + json.dumps({"rows": base.ROWS}), flush=True)
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"args": vars(args), "samples": samples, "rows": base.ROWS}, f)
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--agent", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--acpmux")
    p.add_argument("--rows", type=int, default=100_000)
    p.add_argument("--turn-secs", type=float, default=30.0)
    p.add_argument("--sample-turns", type=int, default=250)
    p.add_argument("--level", type=int, default=3)
    p.add_argument("--off", action="store_true", help="the setting off: the before")
    p.add_argument("--max-pages", type=int, default=100_000)
    p.add_argument("--root-dir", default=None)
    p.add_argument("--out")
    p.add_argument("--keep", action="store_true")
    args = p.parse_args()
    if args.agent:
        return base.run_agent()
    if not args.acpmux:
        p.error("--acpmux is required")
    turns = -(-args.rows // base.ROWS_PER_TURN)
    hours_of = lambda t: t * args.turn_secs / 3600.0
    base.log(f"{turns} turns, {hours_of(turns):.1f} simulated hours, cold segments at zstd {args.level}")

    if args.off:
        return main_off(args, turns, hours_of)
    d = ColdDaemon(args, "cold")
    samples, out = [], {}
    try:
        d.start()
        acp = base.Acp(d.sock)
        sid = d.new_chat(acp)
        t0 = time.monotonic()

        mover_wait = [0.0]

        def settle_movers(limit):
            """Waits for the daemon's mover to finish every sealed segment. A segment seals every
            ~5.5 simulated hours, real hours in a live chat, and its move takes seconds; the bench
            streams those hours in seconds, so without this a sample would count the mover's lag
            as local bytes."""
            started = time.monotonic()
            while d.chat_dir and len(ndjson(d.chat_dir)) > 1 and time.monotonic() - started < limit:
                time.sleep(0.2)  # bench: waiting for the daemon's mover thread
            mover_wait[0] += time.monotonic() - started

        def take(turn):
            d.find_chat_dir()
            settle_movers(120)
            s = {"turn": turn, "sim_hours": hours_of(turn), **(split(d.chat_dir) if d.chat_dir else {})}
            samples.append(s)
            return s

        take(0)
        for turn in range(1, turns + 1):
            acp.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "text", "text": f"coord: {turn}"}]})
            if turn % args.sample_turns == 0 or turn == turns:
                s = take(turn)
                if turn % (args.sample_turns * 8) == 0 or turn == turns:
                    base.log(f"turn {turn} sim {s['sim_hours']:.1f} h local {s['local'] / MB:.1f} MB cold "
                             f"{s['cold'] / MB:.1f} MB (raw {s['raw'] / MB:.1f} MB)")
        wall = time.monotonic() - t0 - mover_wait[0]
        settle_movers(600)
        local_segs = ndjson(d.chat_dir)
        assert len(local_segs) == 1, f"sealed segments still local: {local_segs}"
        end = take(turns)
        idx = []
        for seg, doc in cold_entries(os.path.join(d.chat_dir, "events")):
            idx.append({"seg": seg, "raw": doc["rawLen"], "comp": doc["compLen"], "chunks": len(doc["chunks"]),
                        "ms": doc["compressMs"]})
        oldest_local = first_seq(os.path.join(d.chat_dir, "events", f"{local_segs[0]:06d}.ndjson"))
        base.log(f"open segment {local_segs[0]:06d} starts at seq {oldest_local}; {len(idx)} cold segments")

        # A fresh daemon for each store, so the two walks' RSS start from the same place (the
        # streaming daemon's heap is not the paging's).
        acp.close()
        d.halt()
        d.start()
        acp = base.Acp(d.sock)
        cold_cold, rss_cc = walk(acp, d, sid, oldest_local, True, args.max_pages)
        cold_warm, rss_cw = walk(acp, d, sid, oldest_local, False, args.max_pages)
        rss_idle = rss_kb(d.proc.pid)
        acp.close()
        d.halt()

        # All local: the originals back in events/, the archives gone, no flag.
        kept = os.path.join(d.kept, sid)
        for name in sorted(os.listdir(kept)):
            shutil.move(os.path.join(kept, name), os.path.join(d.chat_dir, "events", name))
        for e in idx:
            legacy = os.path.join(d.chat_dir, "events", f"{e['seg']}.cold.idx")
            if os.path.exists(legacy):
                os.remove(legacy)
            os.remove(os.path.join(d.chat_dir, COLD_DIR, f"{e['seg']}.zst"))
        one = os.path.join(d.chat_dir, "events", INDEX_FILE)
        if os.path.exists(one):
            os.remove(one)
        os.rmdir(os.path.join(d.chat_dir, COLD_DIR))
        d.cold = False
        d.start()
        acp = base.Acp(d.sock)
        local_cold, rss_lc = walk(acp, d, sid, oldest_local, True, args.max_pages)
        local_warm, rss_lw = walk(acp, d, sid, oldest_local, False, args.max_pages)
        acp.close()

        # Every cold page equals its all-local twin.
        mismatched = 0
        for a, b in zip(cold_cold, local_warm):
            if a["before"] != b["before"] or a["digest"] != b["digest"]:
                mismatched += 1
        for a, b in zip(cold_warm, local_cold):
            if a["before"] != b["before"] or a["digest"] != b["digest"]:
                mismatched += 1
        same_len = len(cold_cold) == len(local_warm) == len(cold_warm) == len(local_cold)
        out.update(wall_s=wall, samples=samples, idx=idx, oldest_local=oldest_local, mismatched=mismatched,
                   pages=len(cold_cold), rss_idle_kb=rss_idle,
                   walks={"cold_store_cold_cache": (stats(cold_cold), rss_cc), "cold_store_warm": (stats(cold_warm), rss_cw),
                          "local_cold_cache": (stats(local_cold), rss_lc), "local_warm": (stats(local_warm), rss_lw)})
        failures = []
        if not same_len:
            failures.append(f"walk lengths differ: {len(cold_cold)} {len(cold_warm)} {len(local_cold)} {len(local_warm)}")
        if mismatched:
            failures.append(f"{mismatched} paged-back pages differ from the all-local ones")
            for a, b in zip(cold_cold, local_warm):
                if a["digest"] != b["digest"]:
                    print(f"CHATCOLD-DIFF before {a['before']}/{b['before']}: {a['head']} "
                          f"!= {b['head']}", flush=True)
                    break
        if len(cold_cold) < 50:
            failures.append(f"only {len(cold_cold)} pages")
        out["failures"] = failures
    finally:
        d.stop()

    steady = [s for s in samples if s["turn"] >= turns * 0.1]
    hrs = [s["sim_hours"] for s in steady]
    local_slope = base.slope(hrs, [s["local"] for s in steady])
    cold_slope = base.slope(hrs, [s["cold"] for s in steady])
    raw_slope = base.slope(hrs, [s["local"] + s["raw"] - s["comp"] for s in steady])
    ratio = end["raw"] / end["comp"] if end["comp"] else 0.0
    peak_local = max(s["local"] for s in samples)
    print(f"CHATCOLD {turns} turns, {end['sim_hours']:.1f} simulated hours in {out['wall_s']:.0f} s wall; zstd {args.level}, "
          f"~128 KiB chunks", flush=True)
    print(f"CHATCOLD end: local {end['local'] / MB:.2f} MB (peak {peak_local / MB:.2f}), cold {end['cold'] / MB:.2f} MB "
          f"holding {end['raw'] / MB:.1f} MB raw in {len(out['idx'])} segments: ratio {ratio:.2f}x", flush=True)
    print(f"CHATCOLD slopes: local {local_slope / MB:.3f} MB/h, cold {cold_slope / MB:.3f} MB/h, all-local equivalent "
          f"{raw_slope / MB:.3f} MB/h", flush=True)
    secs = [e["ms"] for e in out["idx"]]
    print(f"CHATCOLD compress per 8 MiB segment: p50 {pct(secs, 50):.0f} ms max {max(secs) if secs else 0} ms", flush=True)
    for name, (st, rss) in out["walks"].items():
        print(f"CHATCOLD walk {name}: {json.dumps(st)} rss {json.dumps(rss)}", flush=True)
    print(f"CHATCOLD equality: {out['pages']} pages from seq {out['oldest_local']} back, {out['mismatched']} differ", flush=True)
    base.perf_row("chat_disk.local_mb_per_hour", local_slope / MB, "MB/h")
    base.perf_row("chat_disk.cold_mb_per_hour", cold_slope / MB, "MB/h")
    base.perf_row("chat_disk.cold_ratio", ratio, "x")
    for name, (st, rss) in out["walks"].items():
        row = {"name": f"chat_cold.page_back.{name}", "p50": st["p50_ms"], "p95": st["p95_ms"], "max": st["max_ms"],
               "unit": "ms"}
        base.ROWS.append(row)
        print("PERF_ROW " + json.dumps(row), flush=True)
        base.perf_row(f"chat_cold.rss_peak_mb.{name}", rss["peak_kb"] / 1024.0, "MB")
        base.perf_row(f"chat_cold.rss_rise_mb.{name}", rss["rise_kb"] / 1024.0, "MB")
    print("PERF_REPORT " + json.dumps({"rows": base.ROWS}), flush=True)
    if args.out:
        with open(args.out, "w") as f:
            json.dump({"args": vars(args), **{k: v for k, v in out.items()}, "rows": base.ROWS}, f)
    for failure in out["failures"]:
        print(f"CHATCOLD FAIL {failure}", flush=True)
    return 1 if out["failures"] else 0


if __name__ == "__main__":
    sys.exit(main() or 0)
