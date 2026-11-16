#!/usr/bin/env python3
"""The main thread of one launch-ready launch, from an all-processes Time Profiler trace (launch-ready.sh profile=1).

    launch-ready-profile.py TRACE RUN_JSON SIDE

RUN_JSON is the launch's LR-RUN object (its pid, window_on_screen and marks). Only the app's main-thread samples count,
from the process's first sample (its start, in dyld) to the window on screen. Prints LR-PROFILE lines:
  total     the main thread's sampled ms in that span, and the span
  phase     sampled ms per span between the launch's marks (process start, main_start, main.run,
            did_finish_launching_start, launch_snapshot_shown, the window on screen)
  self      the heaviest leaf frames
  incl      the heaviest frames with what they call
  binary    sampled ms by the leaf frame's binary
  premain   the heaviest leaf frames before main_start (exec and dyld)
  others    every other process's sampled ms in the same span before main_start, the heaviest first (a launch
            through LaunchServices can wait on another process before the app's main runs)
"""
import collections
import json
import subprocess
import sys
import xml.etree.ElementTree as ET

trace, run, side = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
pid = run.get("pid")
window = run.get("window_on_screen") or 1500.0
marks = run.get("marks", {})
xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                      '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                     capture_output=True, check=True, timeout=600).stdout
root = ET.fromstring(xml)
byid = {}


def resolve(e):
    ref = e.get("ref")
    return byid.get(ref, e) if ref is not None else e


def index(e):
    if e.get("id") is not None:
        byid[e.get("id")] = e
    for child in e:
        index(child)


index(root)
samples, others = [], []
for row in root.iter("row"):
    thread = row.find("thread")
    thread = resolve(thread) if thread is not None else None
    fmt = thread.get("fmt", "") if thread is not None else ""
    time = row.find("sample-time")
    time = resolve(time) if time is not None else None
    weight = row.find("weight")
    weight = resolve(weight) if weight is not None else None
    if "Main Thread" not in fmt or f"pid: {pid})" not in fmt:
        process = row.find("process")
        process = resolve(process) if process is not None else None
        if time is not None and (time.text or "").isdigit() and process is not None and f"({pid})" not in process.get("fmt", ""):
            w = int(weight.text) if weight is not None and (weight.text or "").isdigit() else 1_000_000
            others.append((int(time.text), w, process.get("fmt", "?")))
        continue
    backtrace = row.find("backtrace")
    backtrace = resolve(backtrace) if backtrace is not None else None
    if time is None or not (time.text or "").isdigit() or backtrace is None:
        continue
    frames = []
    for frame in backtrace.findall("frame"):
        frame = resolve(frame)
        binary = frame.find("binary")
        binary = resolve(binary) if binary is not None else None
        frames.append((frame.get("name", "?"), binary.get("name", "?") if binary is not None else "?"))
    if frames:
        w = int(weight.text) if weight is not None and (weight.text or "").isdigit() else 1_000_000
        samples.append((int(time.text), w, frames))
if not samples:
    print(f"LR-PROFILE {side} no main-thread samples for pid {pid}")
    sys.exit(0)
samples.sort()
t0, aligned = samples[0][0], "first main-thread sample"
# The process start on the trace's clock: the trace's start date (the TOC) against the probe's sysctl start. A thread
# that waits before main has no samples, so the first sample alone would hide that wait.
toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], capture_output=True, timeout=300).stdout
try:
    import datetime
    started = ET.fromstring(toc).find(".//start-date")
    trace_ms = datetime.datetime.fromisoformat(started.text.strip().replace("Z", "+00:00")).timestamp() * 1000
    if run.get("start_epoch_ms"):
        guess = int((run["start_epoch_ms"] - trace_ms) * 1e6)
        if 0 <= guess <= samples[0][0] + 50_000_000:
            t0, aligned = guess, "process start (trace start date)"
except (AttributeError, ValueError, ET.ParseError):
    pass
print(f"LR-PROFILE {side} aligned to {aligned}; first main-thread sample at {(samples[0][0] - t0) / 1e6:.1f} ms")
edges = [("start", 0.0)] + sorted(((k, v) for k, v in marks.items()
                                   if k in ("main_start", "main.run", "did_finish_launching_start", "launch_snapshot_shown")),
                                  key=lambda kv: kv[1]) + [("window_on_screen", window)]
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
