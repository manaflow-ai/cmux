#!/usr/bin/env python3
"""Split main-thread time into framework work and our own work (Lawrence 2026-10-21: would moving the
sidebar, drag and drop and columns to immediate mode fix the perf issues?).

Immediate mode removes the framework's retained-tree diffing and layout passes; it does not remove
work our own code does per state change (observation fan-out, models rebuilt for every row, the hover
card). This tool reads a profile of the main thread and attributes each sample to one bucket:

  framework.swiftui_diff   SwiftUI / SwiftUICore / AttributeGraph (graph update, body diffing)
  framework.appkit_layout  AppKit layout passes (layout, _layoutSubtree*, updateConstraints, intrinsic size)
  framework.draw           drawing: AppKit display, CoreGraphics, CoreText, CoreAnimation render prep
  framework.ca_commit      CoreAnimation transaction commit
  framework.other          other AppKit / Foundation work reached without our code below it (event dispatch)
  ours.<kind>              our code (the app binary or its debug dylib, Swift Observation): kind by the
                           first match in the stack of hover_card, json, observation_fanout, model_rebuild,
                           row_configure, else other
  idle                     the main thread waiting (mach_msg, kevent, psynch waits)

Attribution: walk the stack from the leaf toward the root; the first frame that belongs to one of our
binaries makes it ours, the first frame of a framework module makes it that framework bucket (a malloc
called by our mapping is ours; a layout pass our code asked for is the framework's).

Input: a `/usr/bin/sample` text report or an xctrace .trace (Time Profiler). Output: JSON with the
samples per bucket and shares of the busy (non-idle) main thread.

  perf-profile-split.py FILE [FILE ...] [--json OUT]
"""
import argparse, json, os, re, subprocess, sys

OUR_MODULE = re.compile(r"(^cmux|CmuxNext|\.debug\.dylib$|^libswiftObservation|^Observation$)", re.I)
FRAMEWORK = [
    ("framework.swiftui_diff", re.compile(r"^(SwiftUI|SwiftUICore|AttributeGraph)$")),
    ("framework.draw", re.compile(r"^(CoreGraphics|CoreText|libRIP\.A\.dylib|ImageIO|CoreImage|Metal|libFontParser\.dylib)$")),
    ("framework.quartz", re.compile(r"^(QuartzCore)$")),
    ("framework.appkit", re.compile(r"^(AppKit|UIFoundation|Foundation|CoreFoundation|HIToolbox|libdispatch\.dylib)$")),
]
LAYOUT_SYMBOL = re.compile(r"layout|Layout|updateConstraints|intrinsicContentSize|_layoutSubtree|fittingSize|sizeThatFits")
DRAW_SYMBOL = re.compile(r"display|drawRect|draw\(|_drawRect|recursiveDisplay|renderInContext")
COMMIT_SYMBOL = re.compile(r"CA::Transaction::commit|CA::Context::commit|CA::Layer::layout_and_display")
# The app's entry frames sit under every sample: they do not make a sample ours.
ENTRY = re.compile(r"^(main|start|CmuxNextApp\.main|static CmuxNextApp\.main|closure #\d+ in CmuxNextApp\.main|__debug_main_executable_dylib_entry_point|.*\$main)")
IDLE_LEAF = re.compile(r"mach_msg|__psynch_cvwait|kevent|__semwait|__ulock_wait|__workq_kernreturn")
OUR_KIND = [
    ("hover_card", re.compile(r"HoverCard|hoverCard", re.I)),
    ("json", re.compile(r"JSONDecoder|JSONEncoder|JSONSerialization|_JSON")),
    ("observation_fanout", re.compile(r"withObservationTracking|ObservationRegistrar|ObservationTracking|willSet|access<|\.apply\(|Store\.apply|didChange")),
    ("model_rebuild", re.compile(r"Mapping|Layout\.make|SidebarLayout|\.make\(|Snapshot|rebuild|liveSections|sections\.getter")),
    ("row_configure", re.compile(r"configure|RowView|CellView|TabCell")),
]


def classify(stack):
    """stack: [(symbol, module)] leaf first. Returns the bucket name."""
    if not stack:
        return "idle"
    if IDLE_LEAF.search(stack[0][0] or ""):
        return "idle"
    ours = lambda s, m: OUR_MODULE.search(m or "") and not ENTRY.match(s or "")  # noqa: E731
    for i, (sym, mod) in enumerate(stack):
        mod = mod or ""
        if ours(sym, mod):
            text = " ".join(s or "" for s, m in stack if ours(s, m))
            for kind, pattern in OUR_KIND:
                if pattern.search(text):
                    return "ours." + kind
            return "ours.other"
        for bucket, pattern in FRAMEWORK:
            if pattern.search(mod):
                above = " ".join(s or "" for s, _ in stack[i:i + 40])
                if bucket == "framework.quartz":
                    if COMMIT_SYMBOL.search(above) and not LAYOUT_SYMBOL.search(sym or ""):
                        return "framework.ca_commit"
                    return "framework.draw"
                if bucket == "framework.appkit":
                    if LAYOUT_SYMBOL.search(sym or ""):
                        return "framework.appkit_layout"
                    if DRAW_SYMBOL.search(sym or ""):
                        return "framework.draw"
                    continue  # event dispatch and run loop frames: keep walking toward the root
                return bucket
    # Only AppKit/Foundation dispatch frames: the framework's own work with none of ours below it.
    if any(LAYOUT_SYMBOL.search(s or "") for s, _ in stack[:60]):
        return "framework.appkit_layout"
    return "framework.other"


LINE = re.compile(r"^(?P<prefix>[ +!:|]*)(?P<count>\d+) (?P<sym>.+?)(?:  \(in (?P<mod>[^)]+)\))?(?: \+ \d+)?(?:  \[[^\]]*\])?(?:  [^ ].*)?$")


def stacks_from_sample(text):
    """Yields (self samples, stack leaf-first) for every node of the main thread's call graph in a
    /usr/bin/sample report (self samples: the node's count less its children's)."""
    body = text.split("Call graph:", 1)
    if len(body) < 2:
        return
    nodes, in_main = [], False
    for raw in body[1].splitlines():
        if re.match(r"^\s{4}\d+ Thread_", raw):
            if in_main:
                break
            in_main = "main-thread" in raw or "Main Thread" in raw
            continue
        if not in_main:
            continue
        if not raw.strip() or raw.strip().startswith(("Total number", "Sort by")):
            break
        m = LINE.match(raw)
        if m:
            nodes.append((len(m.group("prefix")), int(m.group("count")), m.group("sym").strip(), (m.group("mod") or "").strip()))
    chain = []  # [(indent, sym, mod, count, children_total)]
    out = []

    def pop():
        indent, sym, mod, count, kids = chain.pop()
        if count - kids > 0:
            out.append((count - kids, [(sym, mod)] + [(c[1], c[2]) for c in reversed(chain)]))

    for indent, count, sym, mod in nodes:
        while chain and chain[-1][0] >= indent:
            pop()
        if chain:
            chain[-1] = chain[-1][:4] + (chain[-1][4] + count,)
        chain.append((indent, sym, mod, count, 0))
    while chain:
        pop()
    yield from out


def stacks_from_trace(trace):
    import xml.etree.ElementTree as ET
    toc = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], capture_output=True, text=True).stdout
    schema = "time-profile" if 'schema="time-profile"' in toc else "time-sample"
    xml = subprocess.run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                          f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'], capture_output=True, text=True).stdout
    root = ET.fromstring(xml)
    ids = {}

    def resolve(el):
        ref = el.get("ref")
        if ref is not None:
            return ids.get(ref, el)
        if el.get("id") is not None:
            ids[el.get("id")] = el
        for child in el:
            resolve(child)
        return el

    for row in root.iter("row"):
        thread = bt = None
        for child in row:
            node = resolve(child)
            if child.tag == "thread":
                thread = node
            elif child.tag in ("backtrace", "tagged-backtrace"):
                bt = node
        if thread is None or bt is None or "Main Thread" not in (thread.get("fmt") or ""):
            continue
        bt = bt if bt.tag == "backtrace" else next(iter(bt.iter("backtrace")), bt)
        stack = []
        for f in bt.iter("frame"):
            f = resolve(f)
            binary = next(iter(f.iter("binary")), None)
            binary = resolve(binary) if binary is not None else None
            stack.append((f.get("name") or "?", binary.get("name") if binary is not None else ""))
        yield 1, stack


def deciding_frame(stack):
    """The frame `classify` decided on (the first owned frame from the leaf), for the report's top lists."""
    for sym, mod in stack:
        if OUR_MODULE.search(mod or "") and not ENTRY.match(sym or ""):
            return f"{sym} ({mod})"
        if any(p.search(mod or "") for _, p in FRAMEWORK):
            return f"{sym} ({mod})"
    return f"{stack[0][0]} ({stack[0][1]})" if stack else "?"


def split(path):
    if path.endswith(".trace") or os.path.isdir(path):
        stacks = stacks_from_trace(path)
    else:
        stacks = stacks_from_sample(open(path, errors="replace").read())
    buckets, tops = {}, {}
    for count, stack in stacks:
        b = classify(stack)
        buckets[b] = buckets.get(b, 0) + count
        if b != "idle":
            key = deciding_frame(stack)[:140]
            tops.setdefault(b, {})[key] = tops.setdefault(b, {}).get(key, 0) + count
    result = summarize(buckets)
    result["top_frames"] = {b: sorted(t.items(), key=lambda kv: -kv[1])[:6] for b, t in tops.items()}
    return result


def summarize(buckets):
    busy = sum(v for k, v in buckets.items() if k != "idle")
    fw = sum(v for k, v in buckets.items() if k.startswith("framework."))
    ours = sum(v for k, v in buckets.items() if k.startswith("ours."))
    share = lambda v: round(100.0 * v / busy, 1) if busy else None  # noqa: E731
    return {"samples": buckets, "busy_samples": busy, "framework_pct": share(fw), "ours_pct": share(ours),
            "busy_pct": {k: share(v) for k, v in sorted(buckets.items()) if k != "idle"}}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json")
    opts = ap.parse_args()
    result = {}
    for f in opts.files:
        try:
            result[f] = split(f)
        except Exception as exc:
            result[f] = {"error": repr(exc)}
        print(os.path.basename(f.rstrip("/")), json.dumps(result[f]), flush=True)
    if opts.json:
        json.dump(result, open(opts.json, "w"), indent=1)


if __name__ == "__main__":
    main()
