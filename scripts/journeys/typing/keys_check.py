#!/usr/bin/env python3
"""Did every typed key reach the terminal's program, once, in order, and when (TYPING UNDER LOAD)?

    keys_check.py --sent result.json[:STEP] --echo echo.jsonl [--refresh-hz 120] [--out check.json]
    keys_check.py self-test

--sent: the journey's result.json; the `typist_play` step's result holds every event with `t_post` (host monotonic
seconds just before the HID post). --echo: echo.py's log (every read() of the PTY with its time). Each event's bytes
(a character, 0x7f for Backspace, ESC [ D / C for the arrows, 0x03 for Ctrl-C, 0x0d for Return, a bracketed paste)
are matched in order against the bytes the program read.

Output: {"order_ok", "lost": [...], "extra_bytes", "merged": [...], "pty_ms": {p50, p95, p99, max}, "events": [...]}
  order_ok  every event's bytes came, in the order sent, with nothing between them
  lost      events whose bytes never came (the match stops at the first missing one; the rest are listed)
  merged    two events sent more than 2 refreshes apart that came in ONE read (the second waited for the first)
  pty_ms    from t_post to the read that held the event's last byte
"""
import argparse
import json
import math
import sys
from pathlib import Path

SEQ = {"backspace": b"\x7f", "left": b"\x1b[D", "right": b"\x1b[C", "ctrl_c": b"\x03", "return": b"\r"}


def event_bytes(e):
    if e["kind"] == "char":
        return e["key"].encode()
    if e["kind"] == "paste":
        return b"\x1b[200~" + e["text"].encode() + b"\x1b[201~"
    return SEQ[e["kind"]]


def check(events, reads, refresh_hz=120.0):
    stream, owner = b"", []  # the bytes read, and for each byte the read index
    for k, r in enumerate(reads):
        b = bytes.fromhex(r["bytes"])
        stream += b
        owner += [k] * len(b)
    pos, rows, lost = 0, [], []
    for e in events:
        want = event_bytes(e)
        if lost or stream[pos:pos + len(want)] != want:
            lost.append(e["i"])
            rows.append(dict(e, got=False))
            continue
        last_read = owner[pos + len(want) - 1]
        first_read = owner[pos]
        pos += len(want)
        rows.append(dict(e, got=True, read=last_read, first_read=first_read,
                         pty_ms=round((reads[last_read]["t"] - e["t_post"]) * 1000, 2) if "t_post" in e else None))
    merged = []
    period = 1.0 / refresh_hz
    got = [r for r in rows if r.get("got")]
    for a, b in zip(got, got[1:]):
        if a["read"] == b["first_read"] and "t_post" in a and "t_post" in b and b["t_post"] - a["t_post"] > 2 * period:
            merged.append({"first": a["i"], "second": b["i"], "apart_ms": round((b["t_post"] - a["t_post"]) * 1000, 1),
                           "read": a["read"]})
    lat = sorted(r["pty_ms"] for r in got if r.get("pty_ms") is not None)

    def pct(p):
        return lat[min(len(lat) - 1, int(math.ceil(p / 100.0 * len(lat))) - 1)] if lat else None
    return {"order_ok": not lost and pos == len(stream), "lost": lost, "extra_bytes": len(stream) - pos,
            "merged": merged, "events": len(events), "received": len(got),
            "pty_ms": {"p50": pct(50), "p95": pct(95), "p99": pct(99), "max": lat[-1] if lat else None},
            "rows": rows}


def self_test():
    ev = [{"i": 0, "kind": "char", "key": "a", "t_post": 1.0}, {"i": 1, "kind": "backspace", "key": "delete", "t_post": 1.1},
          {"i": 2, "kind": "paste", "key": "v", "text": "hi", "t_post": 1.2}, {"i": 3, "kind": "char", "key": "b", "t_post": 1.5}]
    reads = [{"t": 1.004, "bytes": b"a".hex()}, {"t": 1.103, "bytes": b"\x7f".hex()},
             {"t": 1.21, "bytes": b"\x1b[200~hi\x1b[201~".hex()}, {"t": 1.503, "bytes": b"b".hex()}]
    r = check(ev, reads)
    assert r["order_ok"] and not r["lost"] and not r["merged"] and r["pty_ms"]["max"] == 10.0, r
    r = check(ev, reads[:2] + [{"t": 1.51, "bytes": (b"\x1b[200~hi\x1b[201~" + b"b").hex()}])
    assert r["order_ok"] and r["merged"] and r["merged"][0]["second"] == 3, r["merged"]
    r = check(ev, [reads[0], reads[2], reads[3]])
    assert not r["order_ok"] and r["lost"][0] == 1, r
    r = check(ev, reads + [{"t": 2.0, "bytes": b"b".hex()}])
    assert not r["order_ok"] and r["extra_bytes"] == 1, r
    print("self-test OK")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("cmd", nargs="?")
    ap.add_argument("--sent"); ap.add_argument("--echo"); ap.add_argument("--refresh-hz", type=float, default=120.0)
    ap.add_argument("--out")
    a = ap.parse_args()
    if a.cmd == "self-test":
        self_test()
        return 0
    path, _, pick = a.sent.partition(":")
    steps = [s for s in json.loads(Path(path).read_text()).get("steps", []) if s.get("do") == "typist_play" and s.get("result")]
    events = steps[int(pick) if pick else 0]["result"]["events"]
    reads = [json.loads(l) for l in Path(a.echo).read_text().splitlines() if '"bytes"' in l]
    out = check(events, reads, a.refresh_hz)
    if a.out:
        Path(a.out).write_text(json.dumps(out, indent=1))
    print(json.dumps({k: v for k, v in out.items() if k != "rows"}))
    return 0 if out["order_ok"] and not out["merged"] else 1


if __name__ == "__main__":
    sys.exit(main())
