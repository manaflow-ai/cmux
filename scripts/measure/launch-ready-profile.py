#!/usr/bin/env python3
"""The main thread of one launch-ready launch, from an all-processes Time Profiler trace (launch-ready.sh profile=1).

    launch-ready-profile.py TRACE RUN_JSON SIDE

RUN_JSON is the launch's LR-RUN object (its pid, window_on_screen and marks). Only the app's main-thread samples count,
from the process's first sample (its start, in dyld) to the first window frame committed (the window on screen when
the launch has no such mark). Prints LR-PROFILE lines:
  total     the main thread's sampled ms in that span, and the span
  phase     sampled ms per span between the launch's marks (process start, main_start, main.run,
            did_finish_launching_start, dfl.home_history, launch_snapshot_shown, first_window_flushed, the window on
            screen, first_window_frame_committed)
  self      the heaviest leaf frames
  incl      the heaviest frames with what they call
  binary    sampled ms by the leaf frame's binary
  premain   the heaviest leaf frames before main_start (exec and dyld)
  others    every other process's sampled ms in the same span before main_start, the heaviest first (a launch
            through LaunchServices can wait on another process before the app's main runs)
  after     the main thread's heaviest frames in the 500 ms after the first frame committed (what holds it
            right after the first frame)
"""
import collections
import datetime
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

PHASE_MARKS = ("main_start", "main.run", "did_finish_launching_start", "dfl.home_history", "launch_snapshot_shown",
               "first_window_flushed")


def resolve(byid, e):
    """`e`, or the element its `ref` names (xctrace writes each repeated value once, then refers to it)."""
    if e is None:
        return None
    ref = e.get("ref")
    return byid.get(ref, e) if ref is not None else e


def parse(xml, pid):
    """The pid's main-thread samples and every other process's samples, from a time-profile table export.

    Returns (samples, others): samples as (ns, weight, [(frame, binary), leaf first]) sorted by time, others as
    (ns, weight, process). A row's stack is a `<backtrace>`, or a `<tagged-backtrace>` holding one: the xctrace on the
    fleet Macs writes the second form, and reading only the first left every launch with no main-thread samples.
    """
    root = ET.fromstring(xml)
    byid = {e.get("id"): e for e in root.iter() if e.get("id") is not None}
    samples, others = [], []
    for row in root.iter("row"):
        thread = resolve(byid, row.find("thread"))
        fmt = thread.get("fmt", "") if thread is not None else ""
        time = resolve(byid, row.find("sample-time"))
        if time is None or not (time.text or "").isdigit():
            continue
        weight = resolve(byid, row.find("weight"))
        w = int(weight.text) if weight is not None and (weight.text or "").isdigit() else 1_000_000
        if "Main Thread" not in fmt or f"pid: {pid})" not in fmt:
            process = resolve(byid, row.find("process"))
            if process is not None and f"({pid})" not in process.get("fmt", ""):
                others.append((int(time.text), w, process.get("fmt", "?")))
            continue
        backtrace = resolve(byid, row.find("backtrace"))
        if backtrace is None:
            tagged = resolve(byid, row.find("tagged-backtrace"))
            backtrace = resolve(byid, tagged.find("backtrace")) if tagged is not None else None
        if backtrace is None:
            continue
        frames = []
        for frame in backtrace.findall("frame"):
            frame = resolve(byid, frame)
            binary = resolve(byid, frame.find("binary"))
            frames.append((frame.get("name", "?"), binary.get("name", "?") if binary is not None else "?"))
        if frames:
            samples.append((int(time.text), w, frames))
    samples.sort(key=lambda s: s[0])
    return samples, others


def main():
    trace, run, side = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
    pid = run.get("pid")
    marks = run.get("marks", {})
    on_screen = run.get("window_on_screen") or 1500.0
    committed = marks.get("first_window_frame_committed")
    window = max(on_screen, committed or 0.0)
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                          '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                         capture_output=True, check=True, timeout=600).stdout
    samples, others = parse(xml, pid)
    if not samples:
        print(f"LR-PROFILE {side} no main-thread samples for pid {pid}")
        sys.exit(0)
    t0, aligned = samples[0][0], "first main-thread sample"
    # The process start on the trace's clock: the trace's start date (the TOC) against the probe's sysctl start. A
    # thread that waits before main has no samples, so the first sample alone would hide that wait.
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], capture_output=True, timeout=300).stdout
    try:
        started = ET.fromstring(toc).find(".//start-date")
        trace_ms = datetime.datetime.fromisoformat(started.text.strip().replace("Z", "+00:00")).timestamp() * 1000
        if run.get("start_epoch_ms"):
            guess = int((run["start_epoch_ms"] - trace_ms) * 1e6)
            if 0 <= guess <= samples[0][0] + 50_000_000:
                t0, aligned = guess, "process start (trace start date)"
    except (AttributeError, ValueError, ET.ParseError):
        pass
    print(f"LR-PROFILE {side} aligned to {aligned}; first main-thread sample at {(samples[0][0] - t0) / 1e6:.1f} ms")
    ends = [(k, v) for k, v in marks.items() if k in PHASE_MARKS] + [("window_on_screen", on_screen)]
    if committed is not None:
        ends.append(("first_window_frame_committed", committed))
    edges = [("start", 0.0)] + sorted(ends, key=lambda kv: kv[1])
    phase = collections.Counter()
    selfw, incl, binary = collections.Counter(), collections.Counter(), collections.Counter()
    total = 0
    for ns, w, frames in samples:
        ms = (ns - t0) / 1e6
        if ms > window:
            break
        total += w
        for (a, _), (b, end) in zip(edges, edges[1:]):
            if ms <= end:
                phase[f"{a}..{b}"] += w
                break
        selfw[frames[0][0]] += w
        binary[frames[0][1]] += w
        for name in {name for name, _ in frames}:
            incl[name] += w
    print(f"LR-PROFILE {side} total {total / 1e6:.1f} ms sampled on the main thread, 0..{window:.0f} ms")
    for (a, _), (b, _) in zip(edges, edges[1:]):
        print(f"LR-PROFILE {side} phase {a}..{b} {phase[f'{a}..{b}'] / 1e6:.1f} ms")
    for name, w in selfw.most_common(25):
        print(f"LR-PROFILE {side} self {w / 1e6:7.1f} ms {name[:150]}")
    for name, w in incl.most_common(60):
        print(f"LR-PROFILE {side} incl {w / 1e6:7.1f} ms {name[:150]}")
    for name, w in binary.most_common(12):
        print(f"LR-PROFILE {side} binary {w / 1e6:7.1f} ms {name}")
    main_start = marks.get("main_start")
    if main_start is not None:
        premain = collections.Counter()
        for ns, w, frames in samples:
            if (ns - t0) / 1e6 <= main_start:
                premain[f"{frames[0][0]} ({frames[0][1]})"] += w
        for name, w in premain.most_common(15):
            print(f"LR-PROFILE {side} premain {w / 1e6:7.1f} ms {name[:150]}")
        busy = collections.Counter()
        for ns, w, fmt in others:
            if 0 <= (ns - t0) / 1e6 <= main_start:
                busy[fmt] += w / 1e6
        for name, ms in busy.most_common(12):
            print(f"LR-PROFILE {side} others {ms:7.1f} ms {name[:120]}")
    if committed is not None:
        after, after_total = collections.Counter(), 0
        for ns, w, frames in samples:
            if committed < (ns - t0) / 1e6 <= committed + 500:
                after_total += w
                for name in {name for name, _ in frames}:
                    after[name] += w
        print(f"LR-PROFILE {side} after {after_total / 1e6:7.1f} ms sampled, first frame to +500 ms")
        for name, w in after.most_common(40):
            print(f"LR-PROFILE {side} after {w / 1e6:7.1f} ms {name[:150]}")


if __name__ == "__main__":
    main()
