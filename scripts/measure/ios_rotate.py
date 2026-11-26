#!/usr/bin/env python3
"""The iOS rotation bench's report (optimum ledger row 8, ios-rotate; flows.json `rotate`).

Leo, 2026-11-24: "i never only want top x changes. you all need to be working through all useful
ones end to end to end." and "and we need to be measuring dynamic possibilities too".

Reads RotateBenchUITests' attachments from a simulator step's evidence (scripts/ci/cmux-next-ios-sim.sh
`test ui=RotateBenchUITests`, any number of duress= runs): per run (`ui-duress-SLUG-attachments`, or
`ui-attachments`) and surface, the app's keyboard-pin trace (rot-trace-SURFACE: one line per display
frame with the window, the scene's orientation, the composer field and the content as drawn, and
`ev=deviceOrientation` when the app learns the phone turned), the test's marks (rot-marks-SURFACE:
`rot-mark T SURFACE METHOD.DIRECTION.ROUND`, T on the trace's clock once its `epoch=` is subtracted)
and the main-thread tracer's log (rot-latency-SURFACE: run-loop iterations of 4 ms or more, with
stacks). Per turn, from its mark to the next:

  response_ms      the mark (XCUIDevice.orientation set) to the first frame the layout moved
                   (flows.json `rotate` response); includes XCUITest's and the system's delivery
  device_ms        the mark to the app's UIDevice orientation notification (the system's part)
  app_response_ms  that notification to the first frame the layout moved (the app's part)
  settle_ms        the mark to the last frame the layout moved (flows.json settle)
  motion_ms        first move to last move
  turned           whether the scene's interface orientation changed
  dropped          frame slots missed while moving (an interval over 1.5 x the nominal)
  main_max_ms      the main thread's longest run-loop iteration from the notification to settle
                   (our code's cost of the turn; target one 120 Hz frame, 8.3 ms)
  main_busy_ms     all of its iterations of 4 ms or more in that span, summed

usage: ios_rotate.py --evidence DIR --out report.json
"""
from __future__ import annotations

import argparse
import collections
import json
import math
import re
import statistics
import sys
from pathlib import Path

SCHEMA = "cmux-mobile-bench/rotate/v1"
MARK = re.compile(r"rot-mark (\d+\.\d+) (\S+) (\w+)\.(\w+)\.(\d+)")
PAIR = re.compile(r"(\w+)=(\S+)")
MOVING = ("winw", "winh", "orient", "fy", "fb", "fx", "fw", "cb", "kb", "kbx", "kbw")
SYSTEM_IMAGES = ("libsystem", "libdispatch", "libobjc", "libswift", "dyld", "CoreFoundation", "Foundation",
                 "UIKitCore", "QuartzCore", "SwiftUI", "SwiftUICore", "GraphicsServices", "CoreGraphics",
                 "FrontBoardServices", "BaseBoard", "libc++", "AttributeGraph", "CoreText", "Metal", "IOSurface",
                 "XCTest", "libRPAC", "CoreAutoLayout", "0x")


def attachments(folder: Path, kind: str) -> dict[str, Path]:
    """rot-KIND-SURFACE attachments, by file name or through xcresulttool's manifest.json."""
    found = {}
    prefix = f"rot-{kind}-"
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


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def read_trace(path: Path):
    epoch, frames, turns = None, [], []
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("epoch="):
            epoch = float(line.split("=", 1)[1].split()[0])
            continue
        kv = dict(PAIR.findall(line))
        if "t" not in kv:
            continue
        t = float(kv["t"])
        if kv.get("ev") == "deviceOrientation":
            turns.append((t, int(kv.get("o", "0"))))
        elif "win" in kv:
            w, _, h = kv["win"].partition("x")
            f = {"t": t, "winw": num(w), "winh": num(h), "orient": num(kv.get("orient"))}
            for k in MOVING[3:]:
                f[k] = num(kv.get(k))
            frames.append(f)
    return epoch, frames, turns


def read_latency(path: Path | None):
    rows = []
    if not path:
        return rows
    for line in path.read_text(errors="replace").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("type") == "hitch":
            rows.append(row)
    return rows


def moved(a, b) -> bool:
    for k in MOVING:
        x, y = a.get(k), b.get(k)
        if (x is None) != (y is None):
            return True
        if x is not None and abs(x - y) > 0.05:
            return True
    return False


def ms(a, b):
    return None if a is None or b is None else round((b - a) * 1000, 1)


def app_frames(stacks) -> list[str]:
    """The innermost frames of ours in each sample (an image that is not a system library)."""
    out = []
    for stack in stacks or []:
        ours = [s for s in stack if not s.startswith(SYSTEM_IMAGES)]
        if ours:
            out.append(ours[0])
    return out


def analyze_step(frames, turns, hitches, epoch, nominal, lo, hi, step):
    r = {"method": step["method"], "direction": step["direction"], "round": step["round"]}
    window = [f for f in frames if lo - nominal <= f["t"] <= hi]
    first = last = None
    for a, b in zip(window, window[1:]):
        if b["t"] >= lo and moved(a, b):
            first = b["t"] if first is None else first
            last = b["t"]
    dev = next((t for t, _ in turns if lo <= t <= hi), None)
    r["response_ms"] = ms(lo, first)
    r["device_ms"] = ms(lo, dev)
    r["app_response_ms"] = None if dev is None or first is None else max(0.0, round((first - dev) * 1000, 1))
    r["settle_ms"] = ms(lo, last)
    r["motion_ms"] = ms(first, last)
    orients = {f["orient"] for f in window if f["orient"] is not None}
    r["turned"] = len(orients) > 1
    if first is not None:
        ts = [f["t"] for f in window if first - nominal <= f["t"] <= last + nominal]
        gaps = [b - a for a, b in zip(ts, ts[1:])]
        r["dropped"] = sum(max(0, round(g / nominal) - 1) for g in gaps if g > 1.5 * nominal)
        r["frame_gap_max_ms"] = round(max(gaps) * 1000, 1) if gaps else None
    else:
        r["dropped"], r["frame_gap_max_ms"] = 0, None
    span_lo = (dev if dev is not None else lo) - 0.01
    span_hi = (last if last is not None else lo + 1.0) + 0.1
    inside = [h for h in hitches if span_lo <= h["t"] / 1000 - epoch <= span_hi]
    r["main_max_ms"] = round(max((h["ms"] for h in inside), default=0.0), 1)
    r["main_busy_ms"] = round(sum(h["ms"] for h in inside), 1)
    r["main_over_8ms"] = sum(1 for h in inside if h["ms"] >= 8.3)
    r["_hitches"] = inside
    return r


def pct(xs, q):
    """Nearest rank, as the app's own summaries."""
    s = sorted(xs)
    return s[min(len(s) - 1, max(0, math.ceil(q * len(s)) - 1))]


def summarize(steps):
    out = {"n": len(steps), "turned": sum(1 for s in steps if s["turned"])}
    for k in ("response_ms", "device_ms", "app_response_ms", "settle_ms", "motion_ms", "main_max_ms", "main_busy_ms",
              "frame_gap_max_ms"):
        xs = [s[k] for s in steps if s.get(k) is not None]
        if xs:
            out[k] = {"p50": round(pct(xs, 0.5), 1), "p95": round(pct(xs, 0.95), 1), "max": round(max(xs), 1)}
    out["dropped"] = sum(s["dropped"] for s in steps)
    out["main_over_8ms"] = sum(s["main_over_8ms"] for s in steps)
    return out


def analyze_surface(trace: Path, marks_path: Path | None, latency: Path | None):
    epoch, frames, turns = read_trace(trace)
    if epoch is None or not frames:
        return {"error": "no epoch= line or no frames in the trace"}
    marks = []
    if marks_path:
        for line in marks_path.read_text(errors="replace").splitlines():
            m = MARK.search(line)
            if m:
                marks.append({"abs": float(m.group(1)), "method": m.group(3), "direction": m.group(4),
                              "round": int(m.group(5))})
    marks.sort(key=lambda m: m["abs"])
    ts = [f["t"] for f in frames]
    nominal = statistics.median([b - a for a, b in zip(ts, ts[1:])]) if len(ts) > 1 else 1 / 60
    hitches = read_latency(latency)
    steps = []
    for i, m in enumerate(marks):
        if m["method"] not in ("rot", "kb"):
            continue
        lo = m["abs"] - epoch
        hi = (marks[i + 1]["abs"] - epoch) if i + 1 < len(marks) else ts[-1]
        steps.append(analyze_step(frames, turns, hitches, epoch, nominal, lo, hi, m))
    # Our frames in the turns' longest iterations: the stack to fix when main_max_ms is over a frame.
    counter = collections.Counter()
    for s in steps:
        for h in s.pop("_hitches"):
            if h["ms"] >= 8.3:
                counter.update(app_frames(h.get("stacks")))
    out = {"trace": trace.name, "frames": len(frames), "nominal_frame_ms": round(nominal * 1000, 2),
           "latency_log": bool(latency), "steps": steps, "turns": {},
           "top_app_frames_over_8ms": [{"frame": f, "samples": n} for f, n in counter.most_common(8)]}
    for key in sorted({(s["method"], s["direction"]) for s in steps}):
        out["turns"][".".join(key)] = summarize([s for s in steps if (s["method"], s["direction"]) == key])
    out["all"] = summarize(steps) if steps else {"n": 0}
    return out


def runs(evidence: Path):
    """(label, attachments folder) per UI run in the evidence."""
    found = []
    for d in sorted(evidence.rglob("ui-duress-*-attachments")):
        found.append((d.name[len("ui-duress-"):-len("-attachments")], d))
    if not found:
        found = [("plain", d) for d in sorted(evidence.rglob("ui-attachments"))]
    return found


def cell(d, k):
    v = d.get(k)
    return "-" if not v else f"{v['p50']:g} / {v['p95']:g}"


def table(report):
    rows = ["| duress | surface | turn | n | turned | response ms p50 / p95 | app response ms p50 / p95 | "
            "settle ms p50 / p95 | main-thread max ms p50 / p95 | dropped frames |",
            "|---|---|---|---|---|---|---|---|---|---|"]
    for run, surfaces in report["runs"].items():
        label = {"off": "idle (duress=off)", "heavy": "heavy (duress=heavy)"}.get(run, run)
        for name, s in surfaces.items():
            if "error" in s:
                rows.append(f"| {label} | {name} | - | - | - | {s['error']} | | | | |")
                continue
            for turn, d in s["turns"].items():
                rows.append(f"| {label} | {name} | {turn} | {d['n']} | {d['turned']} | {cell(d, 'response_ms')} | "
                            f"{cell(d, 'app_response_ms')} | {cell(d, 'settle_ms')} | {cell(d, 'main_max_ms')} | "
                            f"{d['dropped']} |")
    return "\n".join(rows)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--evidence", type=Path, required=True, help="the unzipped evidence.zip")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--meta", action="append", default=[], help="KEY=VALUE for the report's run block")
    a = ap.parse_args()
    report = {"schema": SCHEMA, "run": dict(kv.split("=", 1) for kv in a.meta if "=" in kv), "runs": {}}
    for label, folder in runs(a.evidence):
        traces = attachments(folder, "trace")
        marks = attachments(folder, "marks")
        latency = attachments(folder, "latency")
        report["runs"][label] = {name: analyze_surface(traces[name], marks.get(name), latency.get(name))
                                 for name in sorted(traces)}
        for name in sorted(set(marks) - set(traces)):
            report["runs"][label][name] = {"error": "marks but no trace"}
    if not report["runs"]:
        print(f"ios_rotate.py: no RotateBenchUITests attachments under {a.evidence}", file=sys.stderr)
    report["table_md"] = table(report)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(report, indent=1) + "\n")
    print(report["table_md"])
    for run, surfaces in report["runs"].items():
        for name, s in surfaces.items():
            for f in s.get("top_app_frames_over_8ms", [])[:5]:
                print(f"ROTATE-STACK {run} {name} {f['samples']} {f['frame']}")
    print(f"IOS-ROTATE report={a.out} runs={len(report['runs'])}")
    return 0 if report["runs"] else 1


if __name__ == "__main__":
    sys.exit(main())
