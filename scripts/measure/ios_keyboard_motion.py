#!/usr/bin/env python3
"""The iOS keyboard motion bench's report (scripts/measure/ios-keyboard-motion.sh).

Leo, 2026-11-21: "the 'animation' for when the built in keyboard collapses and
things shrink is not fast enough. percieved time and time to interactive are not
prioritized enough."

Reads KeyboardMotionBenchUITests' output: per surface, the app's keyboard-pin
trace (`kbm-trace SURFACE LINE` in the console, or the attached
kbm-trace-SURFACE.txt) and the test's step marks (`kbm-mark T SURFACE
METHOD.DIRECTION.ROUND`, T on the trace's clock once its `epoch=` line is
subtracted). The trace is parsed by cmux-next-ios/verify/scripts/kbd_pin_trace.py
(its keyboard reading during drags included). Per step (from its mark to the
next):

  kb_notif_ms      the keyboard notification's own duration (`dur`, will-show /
                   will-hide / will-change-frame), ms
  kb_frames_ms     the keyboard as drawn: first frame its top moves to the last
  field_ms         our motion: the focused field's bottom (fb), first move to last
  content_ms       the content behind it (cb), first move to last
  after_kb_ms      ms our motion (field or content) still moved after the keyboard
                   stopped (target 0)
  off_frames       frames, from the keyboard's first move to the end of all motion,
                   where |fb - min(kb - gap, rest)| > 1 pt (target 0); gap is the
                   field's docked gap at rest above the keyboard
  content_off_frames  the same for cb against its own docked gap and rest
  hitches          frame intervals over 1.5 x the trace's nominal interval in that
                   span; hitch_max_ms the longest interval
  tti_ms           (tti steps) keyboard hidden: will-hide to the first touch the app
                   took (the test scrolls right behind the hide); keyboard shown:
                   will-show to the first key the app took (the test types
                   right behind the show). XCUITest sends an event once the app is
                   idle, so this includes the app's own settle.
  pty_resizes      grid sizes the terminal sent its Mac during the step (rz=)

usage: ios_keyboard_motion.py --console FILE [--attachments DIR] --out report.json [--traces DIR]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "cmux-next-ios" / "verify" / "scripts"))
try:
    import kbd_pin_trace  # noqa: E402
except ImportError as error:  # pragma: no cover
    sys.exit(f"ios_keyboard_motion.py: needs cmux-next-ios/verify/scripts/kbd_pin_trace.py ({error})")

MARK = re.compile(r"kbm-mark (\d+\.\d+) (\S+) (\w+)\.(\w+)\.(\d+)")
TRACE = re.compile(r"kbm-trace (\S+) (.*)$")
NOTE = re.compile(r"kbm-notes (\S+) (.*)$")
PAIR = re.compile(r"(\w+)=(\S+)")
SCHEMA = "cmux-mobile-bench/keyboard-motion/v1"


def attached_traces(folder: Path, kind: str = "trace"):
    """kbm-trace-SURFACE.txt attachments: by file name, or through xcresulttool's manifest.json, which
    names each exported file (exportedFileName) by its suggestedHumanReadableName (the attachment's name,
    maybe with _N_UUID appended)."""
    found = {}
    prefix = f"kbm-{kind}-"
    for p in folder.rglob(f"{prefix}*.txt"):
        found[re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", p.name[len(prefix):-len(".txt")])] = p
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


def read_console(path: Path):
    marks, traces, notes = {}, {}, {}
    for line in path.read_text(errors="replace").splitlines():
        m = MARK.search(line)
        if m:
            marks.setdefault(m.group(2), []).append(
                {"abs": float(m.group(1)), "method": m.group(3), "direction": m.group(4), "round": int(m.group(5))})
            continue
        m = TRACE.search(line)
        if m:
            traces.setdefault(m.group(1), []).append(m.group(2))
            continue
        m = NOTE.search(line)
        if m and m.group(2) != "-":
            notes.setdefault(m.group(1), []).append(m.group(2))
    return marks, traces, notes


def side_channel(path: Path):
    """epoch, per-frame rz=, touch and key events: lines kbd_pin_trace.parse skips or folds."""
    epoch, rz, touches, keys = None, [], [], []
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("epoch="):
            epoch = float(line.split("=", 1)[1].split()[0])
            continue
        kv = dict(PAIR.findall(line))
        if "t" not in kv:
            continue
        t = float(kv["t"])
        if kv.get("ev") == "touchBegan":
            touches.append(t)
        elif kv.get("ev") == "keyAccepted":
            keys.append(t)
        elif "rz" in kv and "win" in kv:
            rz.append((t, int(kv["rz"])))
    return epoch, rz, touches, keys


def first_last_move(frames, key, lo, hi, eps=0.05):
    first = last = None
    prev = None
    for f in frames:
        v = f.get(key) if key != "kbtop" else kb_top(f)
        if v is None:
            prev = None
            continue
        if prev is not None and lo <= f["t"] <= hi and abs(v - prev[1]) > eps:
            first = prev[0] if first is None else first
            last = f["t"]
        prev = (f["t"], v)
    return first, last


def kb_top(f):
    return f["kb"] if f["kb"] is not None else f["winh"]


def ms(a, b):
    return None if a is None or b is None else round((b - a) * 1000, 1)


def resting(frames):
    """The field's and the content's rest (no keyboard) and docked gaps (keyboard still and up)."""
    rest_fb = [f["fb"] for f in frames if f["kb"] is None and f["fb"] is not None]
    rest_cb = [f["cb"] for f in frames if f["kb"] is None and f["cb"] is not None]
    gap_fb, gap_cb = [], []
    for a, b in zip(frames, frames[1:]):
        if a["kb"] is None or b["kb"] is None or abs(a["kb"] - b["kb"]) > 0.01 or not kbd_pin_trace.docked(b):
            continue
        if a["fb"] is not None and b["fb"] is not None and abs(a["fb"] - b["fb"]) < 0.01:
            gap_fb.append(b["kb"] - b["fb"])
        if a["cb"] is not None and b["cb"] is not None and abs(a["cb"] - b["cb"]) < 0.01:
            gap_cb.append(b["kb"] - b["cb"])
    med = lambda xs: round(statistics.median(xs), 2) if xs else None
    # The most common settled value, not the median of a moving list.
    mode = lambda xs: round(statistics.mode([round(x, 1) for x in xs]), 2) if xs else None
    return {"rest_fb": mode(rest_fb), "rest_cb": mode(rest_cb), "gap_fb": mode(gap_fb), "gap_cb": mode(gap_cb),
            "gap_fb_median": med(gap_fb)}


def off_frames(frames, key, rest, gap, lo, hi):
    if rest is None or gap is None:
        return None, None
    count, worst = 0, 0.0
    for f in frames:
        if not (lo <= f["t"] <= hi) or f.get(key) is None:
            continue
        target = min(kb_top(f) - gap, rest) if (f["kb"] is None or kbd_pin_trace.docked(f)) else rest
        off = abs(f[key] - target)
        if off > 1.0:
            count += 1
            worst = max(worst, off)
    return count, round(worst, 1)


def analyze_step(frames, events, side, nominal, rest, lo, hi, step):
    epoch, rz, touches, keys = side
    r = {"method": step["method"], "direction": step["direction"], "round": step["round"]}
    want = {"show": ("willShow",), "hide": ("willHide",), "drag": ("willHide", "willChange")}[step["direction"]]
    evs = [e for e in events if lo <= e["t"] <= hi and e["ev"] in want + ("willChange",)]
    primary = next((e for e in evs if e["ev"] in want), evs[0] if evs else None)
    r["kb_notif_ms"] = round(primary["dur"] * 1000, 1) if primary else None
    kb0, kb1 = first_last_move(frames, "kbtop", lo, hi)
    r["kb_frames_ms"] = ms(kb0, kb1)
    f0, f1 = first_last_move(frames, "fb", lo, hi)
    c0, c1 = first_last_move(frames, "cb", lo, hi)
    r["field_ms"] = ms(f0, f1)
    r["content_ms"] = ms(c0, c1)
    ours_end = max([x for x in (f1, c1) if x is not None], default=None)
    r["after_kb_ms"] = None if kb1 is None or ours_end is None else max(0.0, round((ours_end - kb1) * 1000, 1))
    span_lo = min([x for x in (kb0, f0, c0) if x is not None], default=None)
    span_hi = max([x for x in (kb1, f1, c1) if x is not None], default=None)
    if span_lo is not None:
        r["off_frames"], r["off_max_pt"] = off_frames(frames, "fb", rest["rest_fb"], rest["gap_fb"], span_lo, span_hi)
        r["content_off_frames"], r["content_off_max_pt"] = off_frames(frames, "cb", rest["rest_cb"], rest["gap_cb"], span_lo, span_hi)
        ts = [f["t"] for f in frames if span_lo - nominal <= f["t"] <= span_hi + nominal]
        gaps = [b - a for a, b in zip(ts, ts[1:])]
        r["frames"] = len(ts)
        r["hitches"] = sum(1 for g in gaps if g > 1.5 * nominal)
        r["hitch_max_ms"] = round(max(gaps) * 1000, 1) if gaps else None
    else:
        r.update({"off_frames": None, "content_off_frames": None, "frames": 0, "hitches": None, "hitch_max_ms": None})
    if step["method"] == "tti" and primary:
        later = touches if step["direction"] == "hide" else keys
        hit = next((t for t in later if t >= primary["t"] and t <= hi), None)
        r["tti_ms"] = ms(primary["t"], hit)
        r["tti_after_kb_ms"] = None if hit is None or kb1 is None else round((hit - kb1) * 1000, 1)
    if rz:
        before = [v for t, v in rz if t <= lo]
        upto = [v for t, v in rz if t <= hi]
        if upto:
            r["pty_resizes"] = upto[-1] - (before[-1] if before else upto[0])
    r["notification"] = primary["ev"] if primary else None
    return r


def summarize(steps):
    keys = ["kb_notif_ms", "kb_frames_ms", "field_ms", "content_ms", "after_kb_ms", "off_frames", "content_off_frames",
            "hitches", "hitch_max_ms", "tti_ms", "tti_after_kb_ms", "pty_resizes"]
    out = {"n": len(steps)}
    for k in keys:
        xs = [s[k] for s in steps if s.get(k) is not None]
        if not xs:
            continue
        if k in ("off_frames", "content_off_frames", "hitches", "pty_resizes"):
            out[k] = {"total": sum(xs), "max": max(xs)}
        else:
            out[k] = {"median": round(statistics.median(xs), 1), "max": round(max(xs), 1)}
    return out


def analyze_surface(name, trace_path: Path, marks):
    frames, events = kbd_pin_trace.parse(str(trace_path))
    frames = [f for f in frames if f["winw"] > 0]
    side = side_channel(trace_path)
    epoch = side[0]
    out = {"trace": trace_path.name, "frames": len(frames), "notifications": len(events)}
    if epoch is None:
        out["error"] = "the trace has no epoch= line (an app without the bench's trace hook)"
        return out
    if not frames:
        out["error"] = "no frames in the trace"
        return out
    ts = [f["t"] for f in frames]
    nominal = statistics.median([b - a for a, b in zip(ts, ts[1:])]) if len(ts) > 1 else 1 / 60
    out["nominal_frame_ms"] = round(nominal * 1000, 2)
    out["field"] = statistics.mode([f["field"] for f in frames]) if frames else "-"
    rest = resting(frames)
    out["rest"] = rest
    steps = []
    marks = sorted(marks, key=lambda m: m["abs"])
    for i, m in enumerate(marks):
        if m["method"] not in ("tap", "key", "drag", "tti"):
            continue
        lo = m["abs"] - epoch
        hi = (marks[i + 1]["abs"] - epoch) if i + 1 < len(marks) else ts[-1]
        steps.append(analyze_step(frames, events, side, nominal, rest, lo, hi, m))
    out["steps"] = steps
    out["directions"] = {}
    for direction in ("show", "hide", "drag"):
        motion = [s for s in steps if s["direction"] == direction and s["method"] != "tti"]
        if motion:
            entry = summarize(motion)
            entry["by_method"] = {meth: summarize([s for s in motion if s["method"] == meth])
                                  for meth in sorted({s["method"] for s in motion})}
            tti = [s for s in steps if s["direction"] == direction and s["method"] == "tti"]
            if tti:
                entry["tti"] = summarize(tti)
            out["directions"][direction] = entry
    return out


# The shared names (net-conditions-harness): this report's metric each one carries.
NETCOND_METRICS = (
    ("keyboard_duration_ms", "kb_frames_ms"),
    ("keyboard_notification_ms", "kb_notif_ms"),
    ("motion_duration_ms", "motion_ms"),
    ("motion_after_keyboard_ms", "after_kb_ms"),
    ("offset_frames_gt_1pt", "off_frames"),
    ("content_offset_frames_gt_1pt", "content_off_frames"),
    ("hitches", "hitches"),
    ("hitch_max_ms", "hitch_max_ms"),
    ("pty_resizes", "pty_resizes"),
)


def netcond_lines(report):
    """The mobile benches' shared line shape (scripts/measure/ios-network-conditions-report.py):
    one line per measured value; surface terminal|terminal-vim|chat|chief|search, profile none@1 (no
    network shaping), phase show|hide|drag, run the step's round, and `method` (tap|key|drag|tti) as an
    extra key. A value a step did not reach is null (a miss); a tti step carries kbd_hide_tti_ms or kbd_show_tti_ms only."""
    for name, s in report["surfaces"].items():
        if "error" in s:
            yield f"NETCOND-ERROR {name}: {s['error']}"
            continue
        for step in s["steps"]:
            # ios-input-responsiveness reads these two names (kbd_hide_tti_ms, kbd_show_tti_ms) for its items 1-2.
            pairs = ([(f"kbd_{step['direction']}_tti_ms", "tti_ms")] if step["method"] == "tti" else NETCOND_METRICS)
            for metric, key in pairs:
                if key == "motion_ms":
                    moves = [step[k] for k in ("field_ms", "content_ms") if step.get(k) is not None]
                    value = max(moves) if moves else None
                elif key == "pty_resizes" and key not in step:
                    continue
                else:
                    value = step.get(key)
                yield "NETCOND " + json.dumps({"surface": name, "profile": "none@1", "phase": step["direction"],
                                               "scale": "1x", "metric": metric, "value": value,
                                               "run": step["round"], "seed": 0, "method": step["method"]},
                                              separators=(",", ":"))


def table(report):
    rows = ["| surface | dir | n | kb notif ms | kb frames ms | field ms | content ms | after kb ms | off frames | hitches | TTI ms | PTY resizes |",
            "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    fmt = lambda d, k: "-" if k not in d else (f"{d[k]['median']:g} / {d[k]['max']:g}" if "median" in d[k] else f"{d[k]['total']}")
    for name, s in report["surfaces"].items():
        if "error" in s:
            rows.append(f"| {name} | - | - | {s['error']} |||||||||")
            continue
        for direction, d in s["directions"].items():
            tti = d.get("tti", {})
            rows.append(f"| {name} | {direction} | {d['n']} | {fmt(d, 'kb_notif_ms')} | {fmt(d, 'kb_frames_ms')} | {fmt(d, 'field_ms')} | "
                        f"{fmt(d, 'content_ms')} | {fmt(d, 'after_kb_ms')} | {fmt(d, 'off_frames')} | {fmt(d, 'hitches')} | "
                        f"{fmt(tti, 'tti_ms')} | {fmt(d, 'pty_resizes')} |")
    return "\n".join(rows)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--console", type=Path, required=True)
    ap.add_argument("--attachments", type=Path)
    ap.add_argument("--traces", type=Path, help="where to write each surface's trace")
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--meta", action="append", default=[], help="KEY=VALUE for the report's run block")
    a = ap.parse_args()
    marks, traces, notes = read_console(a.console)
    # kbm-marks-SURFACE.txt attachments: the same mark and note lines, for a console export that came back empty.
    if a.attachments and a.attachments.is_dir():
        for name, path in attached_traces(a.attachments, "marks").items():
            if name not in marks:
                m2, _, n2 = read_console(path)
                marks.setdefault(name, m2.get(name, []))
                if n2.get(name):
                    notes.setdefault(name, n2[name])
    traces_dir = a.traces or a.out.parent / "traces"
    traces_dir.mkdir(parents=True, exist_ok=True)
    found = {}
    if a.attachments and a.attachments.is_dir():
        found.update(attached_traces(a.attachments))
    for name, lines in traces.items():
        if name not in found:
            p = traces_dir / f"kbm-trace-{name}.txt"
            p.write_text("\n".join(lines) + "\n")
            found[name] = p
    report = {"schema": SCHEMA, "run": dict(kv.split("=", 1) for kv in a.meta if "=" in kv), "surfaces": {}}
    for name in sorted(set(marks) | set(found)):
        if name not in found:
            report["surfaces"][name] = {"error": "no trace in the test output"}
            continue
        if found[name].parent != traces_dir:
            (traces_dir / found[name].name).write_bytes(found[name].read_bytes())
        report["surfaces"][name] = analyze_surface(name, found[name], marks.get(name, []))
        if notes.get(name):
            report["surfaces"][name]["notes"] = notes[name]
    report["table_md"] = table(report)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(report, indent=1) + "\n")
    (a.out.parent / "netcond.txt").write_text("".join(line + "\n" for line in netcond_lines(report)))
    for line in netcond_lines(report):
        print(line)
    print(report["table_md"])
    print(f"IOS-KEYBOARD-MOTION report={a.out} surfaces={len(report['surfaces'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
