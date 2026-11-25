#!/usr/bin/env python3
"""snappy-bench, iOS leg: send to paint, send to first token, layout shifts per send, chat switch.

Leo, 2026-11-25: "when you press enter, the stuff should just start playing. we dont need to
wait/get blocked by anything on rendering."

Reads SnappySendBenchUITests' attachments from a simulator step's evidence
(scripts/ci/cmux-next-ios-sim.sh `test ui=SnappySendBenchUITests`): per surface, the app's send
trace (snappy-trace-SURFACE: `t=T v=LIST off=Y rows=ID|ROLE|MINY|H;...`, one line per display frame
the chat's visible rows changed, rows in content coordinates; `t=T ev=send` when the composer's send
ran) and the test's marks (snappy-marks-SURFACE: `snap-mark T SURFACE LABEL`, the same clock).
Per send, from the app's `ev=send` (the Send tap as the app took it):

  send_paint_ms         to the first frame showing the new user row
  reserved_same_frame   the assistant's reserved row (working, thought, tool or answer) is in
                        that same frame
  first_token_ms        to the first frame showing a new answer row (markdown block)
  shifts                frames, until the next send, in which a row already on screen moved
                        both in the content and on screen by more than 1 pt, or resized; the
                        bottom row growing (the streaming answer) is not a shift
Per chat switch (local, cloud): the test's mark before the row tap to the first frame with chat
rows (an upper bound: it includes XCUITest's tap delivery).

Writes one `snappy-bench/v1` object per surface (a JSON list; `--out-dir` also writes
snappy-ios-SURFACE.json each).

usage: ios_snappy.py --evidence DIR --out report.json [--sha SHA] [--host HOST]
"""
from __future__ import annotations

import argparse
import datetime
import json
import math
import re
import sys
from pathlib import Path

SCHEMA = "snappy-bench/v1"
MARK = re.compile(r"snap-mark (\d+\.\d+) (\S+) (\S+)")
LINE = re.compile(r"t=(\d+\.\d+) (?:ev=(\S+)|v=(\d+) off=(-?\d+) rows=(.*))$")
RESERVED = {"work", "thought", "tool", "answer"}
SURFACE = {"local": ("local", False), "cloud": ("cloud", False), "duress": ("local", True)}


def attachments(folder: Path, kind: str) -> dict[str, Path]:
    """snappy-KIND-SURFACE attachments, by file name or through xcresulttool's manifest.json."""
    found = {}
    prefix = f"snappy-{kind}-"
    for p in folder.rglob(f"{prefix}*"):
        name = re.sub(r"(_\d+_[0-9A-Fa-f-]{36})?(\.txt)?$", "", p.name[len(prefix):])
        found[name] = p
    for manifest in folder.rglob("manifest.json"):
        try:
            entries = json.loads(manifest.read_text())
        except (OSError, ValueError):
            continue
        for entry in entries if isinstance(entries, list) else [entries]:
            for att in (entry.get("attachments") or []) if isinstance(entry, dict) else []:
                name = str(att.get("suggestedHumanReadableName") or att.get("name") or "")
                file = manifest.parent / str(att.get("exportedFileName") or "")
                m = re.match(rf"{prefix}(.+?)(?:_\d+_[0-9A-Fa-f-]{{36}})?(?:\.txt)?$", name)
                if m and file.is_file():
                    found[m.group(1)] = file
    return found


def read_trace(text: str):
    """(events [(t, name)], frames [(t, view, offset, {id: (role, minY, h)})])."""
    events, frames = [], []
    for raw in text.splitlines():
        m = LINE.match(raw.strip())
        if not m:
            continue
        t = float(m.group(1))
        if m.group(2):
            events.append((t, m.group(2)))
            continue
        rows = {}
        for item in filter(None, (m.group(5) or "").split(";")):
            parts = item.split("|")
            if len(parts) == 4:
                rows[parts[0]] = (parts[1], int(parts[2]), int(parts[3]))
        frames.append((t, int(m.group(3)), int(m.group(4)), rows))
    return events, frames


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, math.ceil(q / 100 * len(s)) - 1))
    return round(s[k], 1)


def shifted(before, after, off_before, off_after):
    """Rows on screen in both frames that moved on screen and in the content, or resized."""
    if not before or not after:
        return []
    bottom = max(after, key=lambda i: after[i][1])
    out = []
    for rid, (role, y, h) in after.items():
        if rid not in before:
            continue
        _, y0, h0 = before[rid]
        content = abs(y - y0) > 1
        screen = abs((y - off_after) - (y0 - off_before)) > 1
        resized = abs(h - h0) > 1 and rid != bottom
        if (content and screen) or resized:
            out.append(f"{rid[:24]} {y0}/{h0}->{y}/{h}")
    return out


def analyze(trace_text: str, marks_text: str):
    events, frames = read_trace(trace_text)
    marks = []
    for raw in marks_text.splitlines():
        m = MARK.search(raw)
        if m:
            marks.append((float(m.group(1)), m.group(3)))
    send_marks = [t for t, label in marks if label.startswith("send.")]
    sends_at = [t for t, name in events if name == "send"]
    end_marks = [t for t, label in marks if label in ("sends.end", "end")]
    sends = []
    for i, t0 in enumerate(sends_at):
        until = sends_at[i + 1] if i + 1 < len(sends_at) else (min([t for t in end_marks if t > t0] or [t0 + 4]))
        before = [f for f in frames if f[0] <= t0 and f[3]]
        if not before:
            sends.append({"error": "no chat frame before the send"})
            continue
        view = before[-1][1]
        seen = set(before[-1][3])
        after = [f for f in frames if t0 < f[0] <= until and f[1] == view]
        paint = reserved = token = None
        for t, _, _, rows in after:
            new = {rid: r for rid, r in rows.items() if rid not in seen}
            roles = {r[0] for r in new.values()}
            if paint is None and "user" in roles:
                paint = t
                reserved = t if roles & RESERVED else None
            elif paint is not None and reserved is None and roles & RESERVED:
                reserved = t
            if token is None and "answer" in roles:
                token = t
            if paint is not None and reserved is not None and token is not None:
                break
        shifts, moved = 0, []
        if paint is not None:
            span = [f for f in after if f[0] >= paint]
            for a, b in zip(span, span[1:]):
                m = shifted(a[3], b[3], a[2], b[2])
                if m:
                    shifts += 1
                    moved.extend(m[:2])
        tap = send_marks[i] if i < len(send_marks) else None
        sends.append({
            "send_paint_ms": None if paint is None else round((paint - t0) * 1000, 1),
            "tap_to_paint_ms": None if paint is None or tap is None else round((paint - tap) * 1000, 1),
            "reserved_ms": None if reserved is None else round((reserved - t0) * 1000, 1),
            "reserved_same_frame": paint is not None and reserved == paint,
            "first_token_ms": None if token is None else round((token - t0) * 1000, 1),
            "shifts": shifts,
            "moved": moved[:6],
        })
    switches = []
    for t0, label in marks:
        if not label.startswith("switch."):
            continue
        nxt = min([t for t, _ in marks if t > t0] or [t0 + 5])
        hit = next((f[0] for f in frames if t0 < f[0] <= nxt and f[3]), None)
        switches.append(None if hit is None else round((hit - t0) * 1000, 1))
    return sends, switches


def rows_of(sends, switches):
    ok = [s for s in sends if "error" not in s]
    paint = [s["send_paint_ms"] for s in ok if s["send_paint_ms"] is not None]
    token = [s["first_token_ms"] for s in ok if s["first_token_ms"] is not None]
    shifts = [s["shifts"] for s in ok if s["send_paint_ms"] is not None]
    sw = [v for v in switches if v is not None]
    return {
        "send_paint_p50_ms": pct(paint, 50),
        "send_paint_p95_ms": pct(paint, 95),
        "reserved_same_frame_share": round(sum(1 for s in ok if s["reserved_same_frame"]) / len(paint), 3) if paint else None,
        "shifts_per_send_mean": round(sum(shifts) / len(shifts), 2) if shifts else None,
        "shifts_per_send_max": max(shifts) if shifts else None,
        "send_first_token_p50_ms": pct(token, 50),
        "send_first_token_p95_ms": pct(token, 95),
        "chat_switch_paint_p95_ms": pct(sw, 95),
        "sends": len(paint),
    }


def report(evidence: Path, sha: str, host: str):
    traces = attachments(evidence, "trace")
    marks = attachments(evidence, "marks")
    at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    out = []
    for name in sorted(set(traces) | set(marks)):
        surface, duress = SURFACE.get(name, (name, False))
        obj = {"schema": SCHEMA, "at": at, "sha": sha, "host": host, "platform": "ios", "surface": surface,
               "mode": "active", "duress": "1000-turn chat" if duress else None, "bench_surface": name}
        if name not in traces:
            obj["error"] = "marks but no trace"
            out.append(obj)
            continue
        sends, switches = analyze(traces[name].read_text(errors="replace"),
                                  marks[name].read_text(errors="replace") if name in marks else "")
        obj["rows"] = rows_of(sends, switches)
        obj["per_send"] = sends
        obj["switches_ms"] = switches
        if name == "cloud":
            obj["note"] = ("mock agent over a mock lte link (history delayed); the simulator CI has no signed-in "
                           "cloud VM, so first token is not a real cloud's")
        if duress:
            obj["note"] = "local mock agent in a 1000-turn replayed chat; no chat switch measured"
        out.append(obj)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--evidence", type=Path, required=True, help="the unzipped evidence.zip (or its attachments)")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--out-dir", type=Path)
    ap.add_argument("--sha", default="")
    ap.add_argument("--host", default="")
    a = ap.parse_args()
    objs = report(a.evidence, a.sha, a.host)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(objs, indent=1) + "\n")
    if a.out_dir:
        a.out_dir.mkdir(parents=True, exist_ok=True)
        for o in objs:
            (a.out_dir / f"snappy-ios-{o['bench_surface']}.json").write_text(json.dumps(o, indent=1) + "\n")
    for o in objs:
        print(f"SNAPPY-IOS {o['bench_surface']} {json.dumps(o.get('rows') or o.get('error'), sort_keys=True)}")
    if not objs:
        print(f"ios_snappy.py: no SnappySendBenchUITests attachments under {a.evidence}", file=sys.stderr)
    return 0 if objs else 1


if __name__ == "__main__":
    sys.exit(main())
