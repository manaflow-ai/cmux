#!/usr/bin/env python3
"""The main thread of one launch-ready launch, from an all-processes Time Profiler trace (launch-ready.sh profile=1).

    launch-ready-profile.py TRACE RUN_JSON SIDE
    launch-ready-profile.py --samples SAMPLES_JSON_GZ [--dsym PATH]

RUN_JSON is the launch's LR-RUN object (its pid, window_on_screen and marks). Only the app's main-thread samples count,
from the process's first sample (its start, in dyld) to the first window frame committed (the window on screen when
the launch has no such mark). Prints LR-PROFILE lines:
  total     the main thread's sampled ms in that span, and the span
  phase     sampled ms per span between the launch's marks (process start, main_start, main.run,
            did_finish_launching_start, dfl.home_history, launch_snapshot_shown, first_window_flushed, the window on
            screen, first_window_frame_committed)
  span      per span of 5 ms or more, its heaviest leaf frames (`self`) and frames with what they call (`incl`)
  busy      the stretch of back-to-back main-thread samples that ends nearest the first frame: where it starts and
            ends and which spans it covers (a main thread with no gap from a mark to the frame is one stretch)
  self      the heaviest leaf frames
  incl      the heaviest frames with what they call
  binary    sampled ms by the leaf frame's binary
  premain   the heaviest leaf frames before main_start (exec and dyld)
  others    every other process's sampled ms in the same span before main_start, the heaviest first (a launch
            through LaunchServices can wait on another process before the app's main runs)
  after     the main thread's heaviest frames in the 500 ms after the first frame committed (what holds it
            right after the first frame)

A nightly's executable is stripped, so its frames are bare addresses in the trace. Beside the trace the first form
writes SIDE-LABEL.samples.json.gz (the main thread's samples to 600 ms after the frame, each frame's address and its
image's load address and UUID); launch-ready.sh keeps it in report.tgz. The second form prints the same lines from
that file, and with --dsym (the build's cmux.app.dSYM or CmuxNextApp.framework.dSYM, a folder holding them, or a DWARF
file) names the app's frames, the stub's and the framework's: atos on a
Mac, else llvm-nm's symbol table ($LLVM_NM), demangled by swift-demangle ($SWIFT_DEMANGLE) when one is found.
"""
import bisect
import collections
import datetime
import gzip
import json
import os
import pathlib
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

PHASE_MARKS = ("main_start", "main.run", "did_finish_launching_start", "dfl.home_history", "launch_snapshot_shown",
               "first_window_flushed")
# Two samples further apart than this are a gap in the main thread's work (the profiler samples every 1 ms).
BUSY_GAP_NS = 3_000_000


def resolve(byid, e):
    """`e`, or the element its `ref` names (xctrace writes each repeated value once, then refers to it)."""
    if e is None:
        return None
    ref = e.get("ref")
    return byid.get(ref, e) if ref is not None else e


def parse(xml, pid):
    """The pid's main-thread samples, every other process's samples, and the images the samples' frames name.

    Returns (samples, others, images): samples as (ns, weight, [(frame, binary, address), leaf first]) sorted by time,
    others as (ns, weight, process), images as {binary: {"load": address, "uuid": UUID}}. A row's stack is a
    `<backtrace>`, or a `<tagged-backtrace>` holding one: the xctrace on the fleet Macs writes the second form, and
    reading only the first left every launch with no main-thread samples.
    """
    root = ET.fromstring(xml)
    byid = {e.get("id"): e for e in root.iter() if e.get("id") is not None}
    samples, others, images = [], [], {}
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
            name = binary.get("name", "?") if binary is not None else "?"
            if binary is not None and binary.get("load-addr") and name not in images:
                images[name] = {"load": binary.get("load-addr"), "uuid": binary.get("UUID", "")}
            frames.append((frame.get("name", "?"), name, frame.get("addr", "")))
        if frames:
            samples.append((int(time.text), w, frames))
    samples.sort(key=lambda s: s[0])
    return samples, others, images


def save(path, samples, t0, until_ms, images, run, side):
    """The main thread's samples from t0 to until_ms, for --samples: each frame once, each sample its frames' indexes."""
    index, frames, rows = {}, [], []
    for ns, w, stack in samples:
        if (ns - t0) / 1e6 > until_ms:
            break
        ids = []
        for frame in stack:
            if frame not in index:
                index[frame] = len(frames)
                frames.append(list(frame))
            ids.append(index[frame])
        rows.append([ns - t0, w, ids])
    with gzip.open(path, "wt") as f:
        json.dump({"side": side, "run": run, "images": images, "frames": frames, "samples": rows}, f)


class Symbols:
    """Names for one image's addresses from its dSYM: atos when there is one, else llvm-nm's symbol table."""

    def __init__(self, path, load):
        self.path, self.load, self.names = path, load, {}
        self.atos = shutil.which("atos")
        self.starts, self.symbols = [], []
        if not self.atos:
            nm = os.environ.get("LLVM_NM") or shutil.which("llvm-nm") or "llvm-nm"
            out = subprocess.run([nm, "-n", "--defined-only", str(path)], capture_output=True, check=True).stdout
            out = out.decode(errors="replace")  # a symbol table holds names that are not UTF-8
            for line in out.splitlines():
                parts = line.split(" ", 2)
                if len(parts) == 3 and parts[1] in ("t", "T"):
                    self.starts.append(int(parts[0], 16))
                    self.symbols.append(parts[2][1:] if parts[2].startswith("_") else parts[2])  # Mach-O's own "_"
        # The image's link address (__TEXT's vmaddr): 0x100000000 for an executable, 0 for a framework's dylib.
        self.base = 0x100000000 if not self.starts or self.starts[0] >= 0x100000000 else 0

    def resolve(self, addrs):
        """Names for addrs (ints, runtime addresses) that fall in this image; the others are left out."""
        todo = sorted({a for a in addrs if a not in self.names})
        if not todo:
            return
        if self.atos:
            cmd = [self.atos, "-o", str(self.path), "-l", hex(self.load)] + [hex(a) for a in todo]
            out = subprocess.run(cmd, capture_output=True, text=True).stdout.splitlines()
            for a, name in zip(todo, out):
                if not name.startswith("0x"):
                    self.names[a] = name.split(" (in ")[0]
            return
        mangled = {}
        for a in todo:
            i = bisect.bisect_right(self.starts, a - self.load + self.base) - 1
            if i >= 0 and i + 1 < len(self.starts):
                mangled[a] = self.symbols[i]
        demangle = os.environ.get("SWIFT_DEMANGLE") or shutil.which("swift-demangle")
        names = dict(mangled)
        if demangle and mangled:
            keys = list(mangled)
            text = "\n".join(mangled[k] for k in keys)
            out = subprocess.run([demangle, "--simplified", "--compact"], input=text, capture_output=True, text=True)
            lines = out.stdout.splitlines()
            if out.returncode == 0 and len(lines) == len(keys):
                names = dict(zip(keys, lines))
        self.names.update(names)


# The app's own images: the stub executable and, since cmux#44204, the framework that holds all of the app's code.
APP_IMAGES = ("cmux", "CmuxNextApp")


def dwarf_files(dsym, images):
    """{image: DWARF file} for the app images dsym holds. dsym is one .dSYM bundle (cmux.app.dSYM,
    CmuxNextApp.framework.dSYM), a folder of them (a build's Release folder, the nightly's dSYM artifact), or one
    DWARF file named for its image."""
    path, found = pathlib.Path(dsym), {}
    for image in (i for i in APP_IMAGES if i in images):
        if path.suffix == ".dSYM":
            bundles = [path]
        elif path.is_dir():
            bundles = [path / f"{image}{ext}.dSYM" for ext in (".app", ".framework", "")]
        else:
            if path.name == image:
                found[image] = path
            continue
        for bundle in bundles:
            dwarf = bundle / "Contents" / "Resources" / "DWARF" / image
            if dwarf.exists():
                found[image] = dwarf
                break
    if not found and path.suffix == ".dSYM":  # a bundle not on this disk: the image its name says (cmux.app.dSYM)
        image = path.name.split(".")[0]
        if image in images:
            found[image] = path / "Contents" / "Resources" / "DWARF" / image
    return found


def symbolicate(samples, images, dsym):
    """samples with the app images' bare-address frames named from dsym (the stub's and the framework's)."""
    tables = []
    for image, path in dwarf_files(dsym, images).items():
        load = int(images[image]["load"], 16)
        symbols = Symbols(path, load)
        top = load + (symbols.starts[-1] - symbols.base if symbols.starts else 0x10000000)
        tables.append((image, load, top, symbols))
    if not tables:
        return samples

    def owner(name, binary, addr):
        if not addr or not name.startswith("0x"):
            return None
        at = int(addr, 16)
        for table in tables:
            image, load, top, _ = table
            if binary == image or (binary == "?" and load <= at < top):
                return table
        return None

    # A caller's frame holds its return address, the instruction after the call: look up the one before it.
    wanted = collections.defaultdict(set)
    for _, _, frames in samples:
        for depth, (name, binary, addr) in enumerate(frames):
            table = owner(name, binary, addr)
            if table:
                wanted[table[0]].add(int(addr, 16) - (1 if depth else 0))
    for image, _, _, symbols in tables:
        symbols.resolve(wanted[image])
    out = []
    for ns, w, frames in samples:
        named = []
        for depth, (name, binary, addr) in enumerate(frames):
            table = owner(name, binary, addr)
            if table:
                name, binary = table[3].names.get(int(addr, 16) - (1 if depth else 0), name), table[0]
            named.append((name, binary, addr))
        out.append((ns, w, named))
    return out


def edges_of(marks, on_screen, committed):
    ends = [(k, v) for k, v in marks.items() if k in PHASE_MARKS] + [("window_on_screen", on_screen)]
    if committed is not None:
        ends.append(("first_window_frame_committed", committed))
    return [("start", 0.0)] + sorted(ends, key=lambda kv: kv[1])


def report(side, samples, t0, marks, on_screen, committed, others=()):
    """The LR-PROFILE lines for one launch's main-thread samples, t0 being the process start on their clock."""
    window = max(on_screen, committed or 0.0)
    edges = edges_of(marks, on_screen, committed)
    spans = list(zip(edges, edges[1:]))
    phase = collections.Counter()
    span_self, span_incl = collections.defaultdict(collections.Counter), collections.defaultdict(collections.Counter)
    selfw, incl, binary = collections.Counter(), collections.Counter(), collections.Counter()
    total = 0
    for ns, w, frames in samples:
        ms = (ns - t0) / 1e6
        if ms > window:
            break
        total += w
        for (a, _), (b, end) in spans:
            if ms <= end:
                key = f"{a}..{b}"
                phase[key] += w
                span_self[key][frames[0][0]] += w
                for name in {f[0] for f in frames}:
                    span_incl[key][name] += w
                break
        selfw[frames[0][0]] += w
        binary[frames[0][1]] += w
        for name in {f[0] for f in frames}:
            incl[name] += w
    print(f"LR-PROFILE {side} total {total / 1e6:.1f} ms sampled on the main thread, 0..{window:.0f} ms")
    for (a, start), (b, end) in spans:
        print(f"LR-PROFILE {side} phase {a}..{b} {phase[f'{a}..{b}'] / 1e6:.1f} ms of {end - start:.0f} ms wall")
    for (a, _), (b, _) in spans:
        key = f"{a}..{b}"
        if phase[key] < 5_000_000:
            continue
        for name, w in span_self[key].most_common(15):
            print(f"LR-PROFILE {side} span {key} self {w / 1e6:7.1f} ms {name[:150]}")
        for name, w in span_incl[key].most_common(30):
            print(f"LR-PROFILE {side} span {key} incl {w / 1e6:7.1f} ms {name[:150]}")
    busy(side, samples, t0, edges, committed if committed is not None else on_screen)
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
        busy_others = collections.Counter()
        for ns, w, fmt in others:
            if 0 <= (ns - t0) / 1e6 <= main_start:
                busy_others[fmt] += w / 1e6
        for name, ms in busy_others.most_common(12):
            print(f"LR-PROFILE {side} others {ms:7.1f} ms {name[:120]}")
    if committed is not None:
        after, after_total = collections.Counter(), 0
        for ns, w, frames in samples:
            if committed < (ns - t0) / 1e6 <= committed + 500:
                after_total += w
                for name in {f[0] for f in frames}:
                    after[name] += w
        print(f"LR-PROFILE {side} after {after_total / 1e6:7.1f} ms sampled, first frame to +500 ms")
        for name, w in after.most_common(40):
            print(f"LR-PROFILE {side} after {w / 1e6:7.1f} ms {name[:150]}")


def busy(side, samples, t0, edges, frame_ms):
    """The stretch of back-to-back samples that ends nearest frame_ms, at or before it, and the spans it covers."""
    stretch, best = [], []
    for ns, w, _ in samples:
        if (ns - t0) / 1e6 > frame_ms:
            break
        if stretch and ns - stretch[-1][0] > BUSY_GAP_NS:
            stretch = []
        stretch.append((ns, w))
        best = stretch
    if not best:
        return
    start, end = (best[0][0] - t0) / 1e6, (best[-1][0] - t0) / 1e6
    sampled = sum(w for _, w in best) / 1e6
    covered = [f"{a}..{b} {max(0.0, min(e, end) - max(s, start)):.0f}"
               for (a, s), (b, e) in zip(edges, edges[1:]) if min(e, end) > max(s, start)]
    print(f"LR-PROFILE {side} busy {start:.1f}..{end:.1f} ms, {end - start:.0f} ms wall, {sampled:.1f} ms sampled, "
          f"ends {frame_ms - end:.1f} ms before the frame; spans (ms): {', '.join(covered)}")


def from_samples(path, dsym):
    with gzip.open(path, "rt") as f:
        saved = json.load(f)
    frames = [tuple(f) for f in saved["frames"]]
    samples = [(ns, w, [frames[i] for i in ids]) for ns, w, ids in saved["samples"]]
    if dsym:
        samples = symbolicate(samples, saved["images"], dsym)
    run = saved["run"]
    marks = run.get("marks", {})
    for image in APP_IMAGES:
        if saved["images"].get(image):
            print(f"LR-PROFILE {saved['side']} {image} image {saved['images'][image]['uuid']} at {saved['images'][image]['load']}")
    report(saved["side"], samples, 0, marks, run.get("window_on_screen") or 1500.0, marks.get("first_window_frame_committed"))


def main():
    if sys.argv[1:2] == ["--samples"]:
        dsym = sys.argv[4] if sys.argv[3:4] == ["--dsym"] else None
        from_samples(sys.argv[2], dsym)
        return
    trace, run, side = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
    pid = run.get("pid")
    marks = run.get("marks", {})
    on_screen = run.get("window_on_screen") or 1500.0
    committed = marks.get("first_window_frame_committed")
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                          '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]'],
                         capture_output=True, check=True, timeout=600).stdout
    samples, others, images = parse(xml, pid)
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
    saved = trace[:-len(".trace")] + ".samples.json.gz" if trace.endswith(".trace") else trace + ".samples.json.gz"
    save(saved, samples, t0, max(on_screen, committed or 0.0) + 600, images, run, side)
    print(f"LR-PROFILE {side} samples {os.path.basename(saved)} (launch-ready-profile.py --samples FILE --dsym DSYM)")
    report(side, samples, t0, marks, on_screen, committed, others)


if __name__ == "__main__":
    main()
