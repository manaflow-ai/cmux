#!/usr/bin/env python3
"""Ranks the main-thread blocking the probe recorded (scripts/measure/blocking-probe/probe.c).

Reads the probe's dumps (TSV, one per app launch: probe-<pid>.tsv) and groups every entry by its first cmux
frame: the first stack frame in cmux's own code (the app executable, a Debug build's `<name>.debug.dylib`, and
frameworks or dylibs named CmuxNext* / cmux*; never a third-party framework such as Sparkle or CEF). The probe keys each entry by its first 16 frames, so
calls from different cmux call sites are different entries, with exact counts. Frames in the app's images are
resolved with atos (against a dSYM when the build has one), so a stripped bench build and a Debug build's
split .debug.dylib name the right function and line. Prints the sites worst first by total main-thread time as Markdown and JSON, with
the owner area (plans/cmux-next/OWNERS.md) of the module the site's symbol names.

  scripts/measure/blocking-probe-report.py --app APP.app [--launches N] --out DIR dump1.tsv [dump2.tsv ...]
"""
import argparse
import collections
import glob
import json
import os
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("dumps", nargs="+")
parser.add_argument("--app", required=True, help="the .app the dumps came from")
parser.add_argument("--launches", type=int, default=0, help="launches the sweep made (to compare with the dumps)")
parser.add_argument("--out", required=True)
opts = parser.parse_args()

# cmux's own images by file name: the executable, a Debug build's .debug.dylib, and frameworks or dylibs named
# CmuxNext* / cmux* (not third-party ones such as Sparkle or CEF).
app_images = {}
CMUX_NAME = re.compile(r"^(CmuxNext|cmux|libcmux)", re.I)
for path in glob.glob(os.path.join(opts.app, "Contents/MacOS/*")):
    if os.path.isfile(path):
        app_images.setdefault(os.path.basename(path), path)
for pattern in ("Contents/Frameworks/*.dylib", "Contents/Frameworks/*.framework/Versions/A/*"):
    for path in glob.glob(os.path.join(opts.app, pattern)):
        if os.path.isfile(path) and CMUX_NAME.match(os.path.basename(path)):
            app_images.setdefault(os.path.basename(path), path)
dsyms = {os.path.basename(p): p for p in glob.glob(os.path.join(os.path.dirname(opts.app), "*.dSYM/Contents/Resources/DWARF/*"))}
MODULE = re.compile(r"^\$s(\d+)(\w+)")


def module_of(symbol):
    match = MODULE.match(symbol or "")
    return match.group(2)[:int(match.group(1))] if match else ""


def first_cmux(frames):
    """(image, offset, symbol) of the first frame in cmux's own images; else the first frame."""
    for frame in frames:
        image, offset, symbol = (frame.split("|") + ["", "", ""])[:3]
        if image in app_images:
            return image, offset, symbol
    image, offset, symbol = ((frames[0].split("|") + ["", "", ""])[:3]) if frames else ("?", "?", "?")
    return image, offset, symbol


entries, dumps = [], {"final": 0, "periodic only": 0}
overhead = collections.Counter()
bad_lines = 0
for path in opts.dumps:
    final = 0
    with open(path, errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            try:
                if line.startswith("#"):
                    key, _, value = line[1:].partition("\t")
                    if key == "final":
                        final = int(value)
                    else:
                        overhead[key] += int(value)
                    continue
                kind, count, total, longest, frames = line.split("\t")
                if kind == "selftest":  # the probe's own load check (blocking-probe.sh verifies it)
                    continue
                entries.append((kind, int(count), int(total), int(longest), [f for f in frames.split(";") if f]))
            except ValueError:
                bad_lines += 1  # a torn line: counted, never fatal
    dumps["final" if final else "periodic only"] += 1

# Resolve each app image's offsets in one atos run per image (base 0x100000000: any base works, the offsets
# are relative to the image's load address), against its dSYM when there is one.
wanted = collections.defaultdict(set)
for *_, frames in entries:
    image, offset, _ = first_cmux(frames)
    if image in app_images:
        wanted[image].add(offset)
resolved = {}
for image, offsets in wanted.items():
    offsets = sorted(offsets)
    base = 0x100000000
    run = subprocess.run(["atos", "-o", dsyms.get(image, app_images[image]), "-l", hex(base)]
                         + [hex(base + int(o, 16)) for o in offsets], capture_output=True, text=True)
    resolved.update({(image, o): name for o, name in zip(offsets, run.stdout.splitlines())})

sites = collections.defaultdict(lambda: {"count": 0, "total_ns": 0, "max_ns": 0, "kinds": collections.Counter(),
                                         "stack": "", "symbol": ""})
for kind, count, total, longest, frames in entries:
    image, offset, symbol = first_cmux(frames)
    name = resolved.get((image, offset)) or (symbol if symbol != "?" else f"{image}+{offset}")
    site = sites[name]
    site["count"] += count
    site["total_ns"] += total
    site["kinds"][kind] += count
    site["symbol"] = symbol
    if longest >= site["max_ns"]:
        site["max_ns"] = longest
        site["stack"] = ";".join(frames[:12])

mangled = [s["symbol"] for s in sites.values()]
demangled = dict(zip(mangled, subprocess.run(["swift", "demangle", "--simplified"], input="\n".join(mangled),
                                             capture_output=True, text=True).stdout.split("\n"))) if mangled else {}
owners_text = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../plans/cmux-next/OWNERS.md")).read()
owned = {m.group(1): row.split("|")[3].strip() for row in owners_text.splitlines() if row.startswith("| ")
         for m in re.finditer(r"Sources/(CmuxNext\w+)/", row)}

report = []
for name, site in sorted(sites.items(), key=lambda kv: -kv[1]["total_ns"]):
    module = module_of(site["symbol"]) or next((m for m in owned if m in name), "")
    label = name if not name.startswith("$s") else demangled.get(name) or name
    report.append({"site": label, "symbol": site["symbol"], "module": module, "owner": owned.get(module, "unowned"),
                   "count": site["count"], "total_ms": round(site["total_ns"] / 1e6, 3),
                   "max_ms": round(site["max_ns"] / 1e6, 3), "kinds": dict(site["kinds"]), "stack": site["stack"]})
os.makedirs(opts.out, exist_ok=True)
# An estimate: two clock reads (about 20 ns each) per timed call, plus the measured recording time.
overhead_ms = overhead["calls"] * 40e-6 + overhead["record_ns"] / 1e6
summary = {"sites": len(report), "launches": opts.launches, "dumps": dumps, "bad_lines": bad_lines,
           "calls_timed": overhead["calls"],
           "dropped": overhead["dropped"], "probe_overhead_ms_estimate": round(overhead_ms, 1),
           "main_thread_blocked_ms": round(sum(r["total_ms"] for r in report), 1),
           "by_owner": collections.Counter(r["owner"] for r in report),
           "by_module": collections.Counter(r["module"] or "system/other" for r in report)}
json.dump({"summary": summary, "sites": report}, open(os.path.join(opts.out, "blocking-probe.json"), "w"), indent=1)
with open(os.path.join(opts.out, "blocking-probe.md"), "w") as md:
    md.write(f"Main-thread blocking: {len(report)} sites, {summary['main_thread_blocked_ms']} ms in total. Launches "
             f"{opts.launches}, dumps {dumps['final']} at exit + {dumps['periodic only']} periodic only (a kill or a "
             f"crash: up to 10 s missing). Probe overhead, estimate: {overhead_ms:.0f} ms over {overhead['calls']} "
             f"timed calls. Dropped entries: {overhead['dropped']}. Torn dump lines skipped: {bad_lines}.\n\n"
             "Known gaps (probe.c header): pthread_rwlock_*, os_unfair_lock_lock_with_options, semaphore_wait, mach_msg "
             "(sync XPC), renamex_np, ftruncate, xattrs, readv/writev, getdirentries64, copyfile/clonefile, "
             "dispatch_async_and_wait, some $NOCANCEL forms, calls a system library makes to itself.\n\n")
    md.write("| # | total ms | max ms | calls | kinds | site | module | owner |\n|---|---|---|---|---|---|---|---|\n")
    for index, r in enumerate(report, 1):
        kinds = ", ".join(f"{k} {v}" for k, v in sorted(r["kinds"].items(), key=lambda kv: -kv[1]))
        md.write(f"| {index} | {r['total_ms']} | {r['max_ms']} | {r['count']} | {kinds} | `{r['site'][:120]}` | "
                 f"{r['module']} | {r['owner']} |\n")
print(json.dumps(summary, default=dict))
