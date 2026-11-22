#!/usr/bin/env python3
"""coord_shape_probe.py: read-only shape of coordinator chats, histograms only.

Reads acpmux session event logs (~/.acpmux/sessions/*/events/*.ndjson) and,
optionally, Claude Code transcripts (~/.claude/projects/*/*.jsonl). Prints one
JSON document (schema coord-shape.v1) holding only counts and log2 size/time
histograms. It never prints content, titles, paths, session ids or names; event
kinds are printed only when they look like protocol identifiers.

Run:  python3 -I coord_shape_probe.py > shape.json
      python3 -I coord_shape_probe.py --top 40 --claude   (also Claude JSONL)
Writes nothing, opens files read-only, streams line by line (multi-GB is fine).
"""
import argparse, json, math, os, re, sys, time
from collections import Counter, defaultdict

KIND_RE = re.compile(rb'"kind":"([^"]{1,80})"')
DIR_RE = re.compile(rb'"dir":"(in|out|mux)"')
AT_RE = re.compile(rb'"at":(\d{10,16})')
UPD_RE = re.compile(rb'"sessionUpdate":"([a-z_]{1,48})"')
TOOLKIND_RE = re.compile(rb'"kind":"(read|edit|delete|move|search|execute|think|fetch|switch_mode|other)"')
BLOCK_RE = re.compile(rb'"type":"(text|image|audio|resource|resource_link|tool_use|tool_result|thinking)"')
SAFE_ID = re.compile(r'^[A-Za-z][A-Za-z0-9_./-]{0,63}$')
SUBAGENT_HINT = re.compile(rb'"subagent|"isSidechain":true|"parentToolUseId"')
COMPACT_HINT = re.compile(rb'compact', re.I)


def log2b(n):
    return 0 if n <= 0 else int(math.log2(n)) + 1  # bucket b holds [2^(b-1), 2^b)


class Hist:
    __slots__ = ("b", "n", "sum", "max")

    def __init__(self):
        self.b, self.n, self.sum, self.max = Counter(), 0, 0, 0

    def add(self, v):
        v = int(v)
        self.b[log2b(v)] += 1
        self.n += 1
        self.sum += v
        self.max = max(self.max, v)

    def out(self):
        return {"n": self.n, "sum": self.sum, "max": self.max,
                "log2": {str(k): c for k, c in sorted(self.b.items())}}


def safe(k):
    return k if SAFE_ID.match(k) else "other"


def scan_acpmux(root, deadline):
    sess_events, sess_bytes, sess_secs, sess_turns = Hist(), Hist(), Hist(), Hist()
    sess_peak1s, sess_peak10s, sess_subagents, sess_compactions = Hist(), Hist(), Hist(), Hist()
    sess_tool_calls = Hist()
    kind_size = defaultdict(Hist)
    upd_size = defaultdict(Hist)
    tool_kinds, blocks, harness = Counter(), Counter(), Counter()
    gap_ms = Hist()
    burst = Hist()  # events landing within the same 50 ms as the previous
    global_sec = Counter()       # events per wall-clock second, all sessions
    active_min = defaultdict(set)  # minute -> set(session index)
    line_len = Hist()
    n_sessions = scanned = 0
    truncated = False
    sdir = os.path.join(root, "sessions")
    try:
        names = sorted(os.listdir(sdir))
    except OSError:
        return None
    for si, name in enumerate(names):
        if time.time() > deadline:
            truncated = True
            break
        ed = os.path.join(sdir, name, "events")
        if not os.path.isdir(ed):
            continue
        try:
            with open(os.path.join(sdir, name, "session.json"), "rb") as f:
                h = json.load(f).get("harness") or "unknown"
            harness[safe(str(h))] += 1
        except Exception:
            harness["unknown"] += 1
        n_sessions += 1
        ev = by = turns = subs = comps = tools = 0
        first = last = prev = None
        per_s, per_10s = Counter(), Counter()
        burst_run = 0
        for fn in sorted(os.listdir(ed)):
            if not fn.endswith(".ndjson"):
                continue
            try:
                f = open(os.path.join(ed, fn), "rb")
            except OSError:
                continue
            with f:
                for line in f:
                    L = len(line)
                    head = line[:512]
                    ev += 1
                    by += L
                    line_len.add(L)
                    m = KIND_RE.search(head)
                    kind = safe(m.group(1).decode("ascii", "replace")) if m else "none"
                    d = DIR_RE.search(head)
                    key = (d.group(1).decode() if d else "?") + ":" + kind
                    kind_size[key].add(L)
                    u = UPD_RE.search(line[:4096])
                    if u:
                        upd_size[u.group(1).decode()].add(L)
                        if u.group(1) == b"tool_call":
                            tools += 1
                            tk = TOOLKIND_RE.findall(line[:8192])
                            tool_kinds[tk[-1].decode() if tk else "unset"] += 1
                    if kind == "user_message" or kind == "session/prompt":
                        turns += kind == "user_message"
                    if SUBAGENT_HINT.search(head):
                        subs += 1
                    if COMPACT_HINT.search(head):
                        comps += 1
                    for b in set(BLOCK_RE.findall(line[:16384])):
                        blocks[b.decode()] += 1
                    a = AT_RE.search(head)
                    if a:
                        t = int(a.group(1))
                        if t > 10**14:  # micro/ns guard
                            t //= 1000
                        first = t if first is None else first
                        last = t
                        if prev is not None and t >= prev:
                            g = t - prev
                            gap_ms.add(g)
                            if g <= 50:
                                burst_run += 1
                            elif burst_run:
                                burst.add(burst_run + 1)
                                burst_run = 0
                        prev = t
                        s = t // 1000
                        per_s[s] += 1
                        per_10s[s // 10] += 1
                        global_sec[s] += 1
                        active_min[s // 60].add(si)
            scanned += 1
        if burst_run:
            burst.add(burst_run + 1)
        sess_events.add(ev)
        sess_bytes.add(by)
        sess_turns.add(turns)
        sess_subagents.add(subs)
        sess_compactions.add(comps)
        sess_tool_calls.add(tools)
        if first is not None:
            sess_secs.add((last - first) // 1000)
        sess_peak1s.add(max(per_s.values()) if per_s else 0)
        sess_peak10s.add(max(per_10s.values()) if per_10s else 0)
    gs = sorted(global_sec.values())
    conc = sorted(len(v) for v in active_min.values())

    def pct(a, p):
        return a[min(len(a) - 1, int(len(a) * p))] if a else 0

    return {
        "sessions": n_sessions, "files": scanned, "truncated": truncated,
        "harness": dict(harness),
        "per_session": {"events": sess_events.out(), "bytes": sess_bytes.out(),
                        "duration_s": sess_secs.out(), "user_turns": sess_turns.out(),
                        "tool_calls": sess_tool_calls.out(),
                        "subagent_events": sess_subagents.out(),
                        "compaction_events": sess_compactions.out(),
                        "peak_events_1s": sess_peak1s.out(),
                        "peak_events_10s": sess_peak10s.out()},
        "event_bytes": line_len.out(),
        "kind_bytes": {k: v.out() for k, v in sorted(kind_size.items(), key=lambda x: -x[1].n)},
        "session_update_bytes": {k: v.out() for k, v in upd_size.items()},
        "tool_call_kinds": dict(tool_kinds),
        "content_blocks": dict(blocks),
        "gap_ms": gap_ms.out(),
        "burst_len_50ms": burst.out(),
        "global_events_per_s": {"p50": pct(gs, .5), "p95": pct(gs, .95), "p99": pct(gs, .99),
                                "p999": pct(gs, .999), "max": gs[-1] if gs else 0,
                                "active_seconds": len(gs)},
        "active_sessions_per_min": {"p50": pct(conc, .5), "p95": pct(conc, .95),
                                    "max": conc[-1] if conc else 0},
    }


def scan_attachments(root):
    h = Hist()
    for dp, _, fs in os.walk(os.path.join(root, "attachments")):
        for f in fs:
            try:
                h.add(os.path.getsize(os.path.join(dp, f)))
            except OSError:
                pass
    return h.out()


TYPE_RE = re.compile(rb'"type":"([a-z_]{1,32})"')
SUBTYPE_RE = re.compile(rb'"subtype":"([a-z_]{1,48})"')


def scan_claude(root, deadline):
    files, ev_by_file, bytes_by_file = 0, Hist(), Hist()
    type_size = defaultdict(Hist)
    side = compact = 0
    for dp, _, fs in os.walk(os.path.join(root, "projects")):
        for fn in fs:
            if not fn.endswith(".jsonl") or time.time() > deadline:
                continue
            files += 1
            n = b = 0
            try:
                with open(os.path.join(dp, fn), "rb") as f:
                    for line in f:
                        n += 1
                        b += len(line)
                        head = line[:1024]
                        m = TYPE_RE.search(head)
                        st = SUBTYPE_RE.search(head)
                        k = (m.group(1).decode() if m else "none") + (":" + st.group(1).decode() if st else "")
                        type_size[k].add(len(line))
                        side += b'"isSidechain":true' in head
                        compact += b"compact_boundary" in head
            except OSError:
                continue
            ev_by_file.add(n)
            bytes_by_file.add(b)
    return {"files": files, "events": ev_by_file.out(), "bytes": bytes_by_file.out(),
            "type_bytes": {k: v.out() for k, v in type_size.items()},
            "sidechain_events": side, "compact_boundaries": compact}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--acpmux", default=os.path.expanduser("~/.acpmux"))
    ap.add_argument("--claude-root", default=os.path.expanduser("~/.claude"))
    ap.add_argument("--claude", action="store_true", help="also scan Claude Code JSONL")
    ap.add_argument("--budget-s", type=int, default=1800, help="stop scanning after this many seconds")
    a = ap.parse_args()
    t0 = time.time()
    dl = t0 + a.budget_s
    out = {"schema": "coord-shape.v1", "acpmux": scan_acpmux(a.acpmux, dl),
           "attachment_bytes": scan_attachments(a.acpmux)}
    if a.claude:
        out["claude"] = scan_claude(a.claude_root, dl)
    out["scan_s"] = round(time.time() - t0, 1)
    json.dump(out, sys.stdout, indent=1, sort_keys=True)
    print()


if __name__ == "__main__":
    main()
