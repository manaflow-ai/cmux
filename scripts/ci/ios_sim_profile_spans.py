#!/usr/bin/env python3
"""Main-thread long spans of one process in an xctrace Time Profiler export.

usage: ios_sim_profile_spans.py TIME_PROFILE.xml PROCESS_NAME

Reads the time-profile table (xctrace export ... schema="time-profile"),
keeps the samples of PROCESS_NAME's main thread, and groups samples less
than 3 ms apart into spans: the main thread busy without a break. Prints
the total, every span of 20 ms or more with its heaviest frames (inclusive,
the run loop's own frames left out), and the heaviest frames overall.
"""
import collections
import sys
import xml.etree.ElementTree as ET

path, process = sys.argv[1], sys.argv[2]
byid = {}
samples = []  # (time_ns, weight_ns, [frames, leaf first])


def resolve(e):
    ref = e.get("ref")
    return byid.get(ref, e) if ref else e


for _, e in ET.iterparse(path, events=("end",)):
    if e.get("id"):
        byid[e.get("id")] = e
    if e.tag != "row":
        continue
    thread = e.find("thread")
    thread = resolve(thread) if thread is not None else None
    fmt = thread.get("fmt", "") if thread is not None else ""
    if "Main Thread" not in fmt or process not in fmt:
        continue
    time = e.find("sample-time")
    time = resolve(time) if time is not None else None
    weight = e.find("weight")
    weight = resolve(weight) if weight is not None else None
    bt = e.find("backtrace")
    bt = resolve(bt) if bt is not None else None
    if time is None or bt is None:
        continue
    names = [resolve(f).get("name", "?") for f in bt.findall("frame")]
    w = int(weight.text) if weight is not None and weight.text and weight.text.isdigit() else 1_000_000
    samples.append((int(time.text), w, names))

samples.sort()
noise = ("CFRunLoop", "__CFRunLoop", "GSEventRunModal", "UIApplicationMain", "main", "start", "_UIApplicationMainPreparations",
         "-[UIApplication _run]", "static UIApplicationDelegate.main()", "dyld", "?")


def interesting(name):
    return not name.startswith(noise) and "mach_msg" not in name


spans, current = [], []
for sample in samples:
    if current and sample[0] - current[-1][0] > 3_000_000:
        spans.append(current)
        current = []
    current.append(sample)
if current:
    spans.append(current)

total = sum(w for _, w, _ in samples)
long_spans = [s for s in spans if sum(w for _, w, _ in s) >= 20_000_000]
print(f"{process} main thread: {len(samples)} samples, {total / 1e6:.0f} ms busy, {len(long_spans)} spans of 20 ms or more")
start = samples[0][0] if samples else 0
for span in sorted(long_spans, key=lambda s: -sum(w for _, w, _ in s))[:30]:
    busy = sum(w for _, w, _ in span)
    incl = collections.Counter()
    for _, w, names in span:
        for n in set(filter(interesting, names)):
            incl[n] += w
    print(f"\nspan at {(span[0][0] - start) / 1e9:.3f} s: {busy / 1e6:.1f} ms")
    for n, w in incl.most_common(12):
        print(f"  {w / 1e6:6.1f} ms  {n[:150]}")

selfw, incl = collections.Counter(), collections.Counter()
for _, w, names in samples:
    if names:
        selfw[names[0]] += w
    for n in set(names):
        incl[n] += w
print("\nheaviest frames, self:")
for n, w in selfw.most_common(25):
    print(f"  {w / 1e6:8.1f} ms  {n[:150]}")
print("\nheaviest frames, inclusive:")
for n, w in incl.most_common(40):
    print(f"  {w / 1e6:8.1f} ms  {n[:150]}")
