#!/usr/bin/env python3
"""Main-thread cost per display frame from an xctrace Time Profiler export (RESIZE VIDEOS suite, F1).

  xtp_frames.py diag-xtp.txt --trace diag-closetrace.json --result result.json [--from-ms 0 --to-ms 200] [--top 12]

diag-xtp.txt: `xctrace export --xpath .../table[@schema="time-profile"]` (ext_rvsuite xtp_stop). Each row is one
1 ms sample with its thread, state and backtrace (ids and refs resolved here). The recording's time 0 is the
"Starting recording" line, which xtp_start reads just before the key (result.json: xtp_start t_recording and
hid_key sent, both driver seconds), so a sample's time from the key = sample time - (sent - t_recording).
The trace (debug.motion trace_stop, no recorder) gives the display ticks and the first frame the layout moved.

Prints: the key-to-first-motion-frame time, the frame intervals of the motion (p50, p95, max, drops in the first 4
frames), then for each 8.33 ms window from --from-ms to --to-ms after the key the main thread's Running samples
and its top frames (cmux frames first), and the top frames over the whole window. Standard library only.
"""
import argparse
import json
import statistics
import sys
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict

SKIP = ("start", "main", "NSApplicationMain", "-[NSApplication run]", "_DPS", "-[NSApplication(NSEventRouting)",
        "_BlockUntilNextEventMatchingListInMode", "ReceiveNextEventCommon", "RunCurrentEventLoopInMode",
        "_CFRunLoopRunSpecificWithOptions", "__CFRunLoopRun", "CmuxNextApp.main()", "static CmuxNextApp.main()")


def load_samples(path):
    root = ET.parse(path).getroot()
    ids = {}
    for el in root.iter():
        if "id" in el.attrib:
            ids[el.attrib["id"]] = el

    def res(el):
        return ids.get(el.attrib["ref"], el) if el is not None and "ref" in el.attrib else el

    out = []
    for row in root.iter("row"):
        t = res(row.find("sample-time"))
        th = res(row.find("thread"))
        st = res(row.find("thread-state"))
        bt = res(row.find("tagged-backtrace"))
        bt = bt if bt is not None else res(row.find("backtrace"))
        frames = []
        if bt is not None:
            b = bt.find("backtrace")
            b = res(b) if b is not None else bt
            for fr in b.findall("frame"):
                fr = res(fr)
                frames.append(fr.attrib.get("name", "?"))
        out.append({"t_ms": int(t.text) / 1e6, "thread": th.attrib.get("fmt", ""), "state": st.attrib.get("fmt", "") if st is not None else "",
                    "frames": frames})
    return out


def interesting(frames):
    return [f for f in frames if not f.startswith(SKIP)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xtp")
    ap.add_argument("--trace", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--from-ms", type=float, default=-10)
    ap.add_argument("--to-ms", type=float, default=120)
    ap.add_argument("--top", type=int, default=12)
    opts = ap.parse_args()
    res = json.load(open(opts.result))
    t_rec = sent = None
    for st in res["steps"]:
        r = st.get("result") or {}
        if st.get("do") == "xtp_start":
            t_rec = r.get("t_recording")
        if st.get("do") == "hid_key" and t_rec is not None and sent is None:
            sent = r.get("sent")
    if t_rec is None or sent is None:
        sys.exit("result.json has no xtp_start / hid_key times")
    key_xtp_ms = (sent - t_rec) * 1000
    # display ticks from the trace; the key in the trace's clock from the motion's first frame
    trace = json.load(open(opts.trace))
    s = trace["samples"]
    moving = [i for i in range(1, len(s)) if s[i].get("panes") != s[i - 1].get("panes")]
    if moving:
        f0, f1 = moving[0], moving[-1]
        iv = [float(s[i]["t"]) - float(s[i - 1]["t"]) for i in range(f0, f1 + 1)]
        refresh = float(trace.get("refresh_ms") or 8.33)
        first4 = sum(max(0, round(x / refresh) - 1) for x in iv[:4])
        print(f"motion: trace frames {f0}..{f1} ({f1 - f0 + 1} frames); intervals p50 {statistics.median(iv):.2f} ms, "
              f"p95 {sorted(iv)[max(0, int(len(iv) * 0.95) - 1)]:.2f} ms, max {max(iv):.2f} ms; refreshes lost in the first 4 frames: {first4}; "
              f"all lost: {sum(max(0, round(x / refresh) - 1) for x in iv)}")
        print("  first 8 intervals:", [round(x, 2) for x in iv[:8]])
    samples = [x for x in load_samples(opts.xtp) if x["thread"].startswith("Main Thread")]
    print(f"xctrace: {len(samples)} main-thread samples; key at xctrace {key_xtp_ms:.2f} ms")
    windows = defaultdict(list)
    allc, allself = Counter(), Counter()
    for x in samples:
        dt = x["t_ms"] - key_xtp_ms
        if not (opts.from_ms <= dt < opts.to_ms) or x["state"] != "Running":
            continue
        w = int((dt - opts.from_ms) // 8.333)
        windows[w].append(x)
        fr = interesting(x["frames"])
        if fr:
            allself[fr[0]] += 1
        for f in set(fr):
            allc[f] += 1
    for w in sorted(windows):
        xs = windows[w]
        c = Counter()
        for x in xs:
            for f in set(interesting(x["frames"])):
                c[f] += 1
        lo = opts.from_ms + w * 8.333
        top = [f"{n} {f[:70]}" for f, n in c.most_common(40) if "cmux" not in f.lower() or True][:opts.top]
        cm = [f"{n} {f[:80]}" for f, n in c.most_common(80) if any(k in f for k in ("CmuxNext", "Cmux", "Terminal", "Layout", "Pane", "Screen", "Motion", "Frame", "ghostty"))][:6]
        print(f"[{lo:6.1f}..{lo + 8.333:6.1f} ms] running {len(xs):2d} ms | cmux: {'; '.join(cm)}")
    print("whole window, inclusive (Running ms under the frame), cmux-named first:")
    named = [(f, n) for f, n in allc.most_common(400) if any(k in f for k in ("CmuxNext", "Cmux", "Terminal", "Layout", "Pane", "Screen", "Motion", "Frame", "ghostty", "Action", "Close"))]
    for f, n in named[:opts.top * 2]:
        print(f"  {n:4d}  {f[:150]}")
    print("whole window, self (top frame while Running):")
    for f, n in allself.most_common(opts.top):
        print(f"  {n:4d}  {f[:150]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
