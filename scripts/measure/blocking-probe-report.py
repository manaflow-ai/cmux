#!/usr/bin/env python3
"""Ranks the blocking the probe recorded (scripts/measure/blocking-probe/probe.c), in four sections.

Reads the probe's dumps (TSV, one per process: probe-<run>-<pid>.tsv) and groups every entry by its first cmux
frame, the first stack frame in cmux's own code: the app executable, a Debug build's `<name>.debug.dylib`,
frameworks or dylibs named CmuxNext* / cmux* (the CEF shim libcmux_cef_shim.dylib too) and the daemon binaries in
Contents/Resources/bin; never a third-party framework such as Sparkle. The probe keys each entry by its first 16
frames, so calls from different call sites are different entries, with exact counts. Frames in the app's images
are resolved with atos (against a dSYM when the build has one), so a stripped bench build and a Debug build's
split .debug.dylib name the right function and line. The sections, each worst first by total time, as Markdown
and JSON, with the owner area (plans/cmux-next/OWNERS.md) of the module the site's symbol names:

  app_main           the app's main thread (a dump whose #threads header is "main"), where cmux's code makes the
                     call, its CEF shim (cmux's own C++) included
  app_chromium       the app's main thread, where Chromium's code (Chromium Embedded Framework) makes it: the first
                     frame of cmux or Chromium from the top is Chromium's; "via" is the cmux caller below it with
                     the most time
  daemon_request     the daemon's watched request and echo threads (a dump with any other #threads header); the
                     site is the first frame in a cmux crate, past the statically linked Rust std
  daemon_input_wait  the same threads' waits for their next input (kind input-wait:*: a socket, pipe or PTY read,
                     recv, poll, select, waitpid), listed apart: an idle wait is not blocking work, as Chrome's
                     message pump waits outside any ScopedBlockingCall

  scripts/measure/blocking-probe-report.py --app APP.app [--launches N] --out DIR dump1.tsv [dump2.tsv ...]
  scripts/measure/blocking-probe-report.py --select main|daemon dump1.tsv ...   prints the app's or daemon's dumps
  scripts/measure/blocking-probe-report.py --preflight dump1.tsv ...            blocking-probe.sh's preflight check
"""
import argparse
import collections
import glob
import json
import os
import re
import subprocess
import sys

SECTIONS = ("app_main", "app_chromium", "daemon_request", "daemon_input_wait")
SECTION_TITLES = {
    "app_main": "App main thread (cmux's own calls)",
    "app_chromium": "App main thread, made by Chromium (the CEF helper-app program's queue)",
    "daemon_request": "Daemon request and echo threads",
    "daemon_input_wait": "Daemon request and echo threads waiting for their next input (not blocking work)",
}
INPUT_WAIT = "input-wait:"
# cmux's own images by file name: the executable, a Debug build's .debug.dylib, frameworks or dylibs named
# CmuxNext* / cmux*, and the daemon binaries (not third-party ones such as Sparkle).
CMUX_NAME = re.compile(r"^(CmuxNext|cmux|libcmux|acpmux)", re.I)
# Chromium's image (CEFRuntimeLayout.frameworkName). The CEF shim beside it is cmux's own code (CEFShim/src), also
# when the runtime is a download outside the bundle and so not among the app's images.
CHROMIUM_IMAGES = {"Chromium Embedded Framework"}
CEF_SHIM = "libcmux_cef_shim.dylib"
SWIFT_MODULE = re.compile(r"^\$s(\d+)(\w+)")
# A Rust symbol in one of cmux's crates (resolved `cmux_tui_core::server::...`, `<cmux_x::Y as std::io::Read>`,
# or mangled `_ZN13cmux_tui_core...`); Rust std, core and third-party crates are not.
RUST_CRATE = re.compile(r"(?<![A-Za-z])((?:cmux|acpmux)\w*?)(?:::|\d|$)")
# The preflight program's watched thread pattern (blocking-probe.sh).
PREFLIGHT_THREAD = "probe-test-*-host"


def app_images_of(app):
    images = {}
    for path in glob.glob(os.path.join(app, "Contents/MacOS/*")):
        if os.path.isfile(path):
            images.setdefault(os.path.basename(path), path)
    for pattern in ("Contents/Frameworks/*.dylib", "Contents/Frameworks/*.framework/Versions/A/*",
                    "Contents/Resources/bin/*"):
        for path in glob.glob(os.path.join(app, pattern)):
            name = os.path.basename(path)
            if os.path.isfile(path) and CMUX_NAME.match(name):
                images.setdefault(name, path)
    return images


def is_cmux(image, images):
    return image in images or image == CEF_SHIM


def split_frame(frame):
    image, offset, symbol = (frame.split("|") + ["", "", ""])[:3]
    return image, offset, symbol


def dump_header(path):
    """The dump's header ({key: value}), or None when the file cannot be read (an unmatched glob)."""
    header = {}
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if not line.startswith("#"):
                    break
                key, _, value = line[1:].rstrip("\n").partition("\t")
                header[key] = value
    except OSError:
        return None
    return header


def select(paths, want):
    """The dumps of the app (want "main": #threads is main) or of the daemon (want "daemon": any other)."""
    picked = []
    for path in paths:
        header = dump_header(path)
        if header is not None and (header.get("threads", "main") != "main") == (want == "daemon"):
            picked.append(path)
    return picked


def rows_of(path):
    """(kind, thread) of every row of a dump."""
    with open(path, errors="replace") as f:
        return [tuple(line.split("\t")[:2]) for line in f if not line.startswith("#") and "\t" in line]


def preflight(paths):
    """The problems in blocking-probe.sh's preflight dumps (app -> inert hop -> owner); empty when the probe works."""
    problems = []
    apps, daemons = select(paths, "main"), select(paths, "daemon")
    if len(paths) != 2 or len(apps) != 1 or len(daemons) != 1:
        problems.append(f"{len(paths)} dumps ({len(apps)} app, {len(daemons)} owner), want 2: the app's and the "
                        "owner's; the hop, with only one of the two wanted arguments, must stay inert")
    for path in apps[:1]:
        if dump_header(path).get("final") != "1" or ("selftest", "main") not in rows_of(path):
            problems.append("the app's dump has no main-thread self-test row at exit: the probe did not load or "
                            "did not interpose")
    for path in daemons[:1]:
        threads, rows = dump_header(path).get("threads"), rows_of(path)
        if threads != PREFLIGHT_THREAD:
            problems.append(f"the owner watches {threads!r}, want {PREFLIGHT_THREAD!r}: the spawn did not carry "
                            "CMUX_PROBE_THREADS")
        if not any(kind == "selftest" for kind, _ in rows):
            problems.append("the owner's dump has no self-test row")
        if ("file-io:stat", PREFLIGHT_THREAD) not in rows:
            problems.append("no stat from probe-test-1-host: the thread pattern does not match it")
        if ("input-wait:read", PREFLIGHT_THREAD) not in rows:
            problems.append("probe-test-1-host's pipe read is not an input-wait:read")
        if any(kind == "file-io:access" for kind, _ in rows):
            problems.append("probe-test-1-wait, which the pattern does not name, was recorded")
    return problems


def read_dumps(paths):
    """Entries (section-less) per dump, the dump counts and the probe's overhead counters."""
    entries, dumps = [], {"final": 0, "periodic only": 0, "daemon": 0}
    overhead = collections.Counter()
    bad_lines = 0
    for path in paths:
        final, watching = 0, "main"
        rows = []
        with open(path, errors="replace") as f:
            for line in f:
                line = line.rstrip("\n")
                try:
                    if line.startswith("#"):
                        key, _, value = line[1:].partition("\t")
                        if key == "final":
                            final = int(value)
                        elif key == "threads":
                            watching = value
                        elif key != "process":
                            overhead[key] += int(value)
                        continue
                    fields = line.split("\t")
                    if len(fields) == 5:  # a dump from before the thread column: the main thread
                        fields.insert(1, "main")
                    kind, thread, count, total, longest, frames = fields
                    if kind == "selftest":  # the probe's own load check (blocking-probe.sh verifies it)
                        continue
                    rows.append((kind, thread, int(count), int(total), int(longest),
                                 [f for f in frames.split(";") if f]))
                except ValueError:
                    bad_lines += 1  # a torn line: counted, never fatal
        daemon = watching != "main"
        entries.extend((daemon, *row) for row in rows)
        dumps["final" if final else "periodic only"] += 1
        dumps["daemon"] += daemon
    return entries, dumps, overhead, bad_lines


def atos(images, dsyms, wanted):
    """{(image, offset): name} for every offset, one atos run per image and chunk (base 0x100000000: any base
    works, the offsets are relative to the image's load address). Without atos (not macOS) nothing resolves."""
    resolved = {}
    base = 0x100000000
    for image, offsets in wanted.items():
        offsets = sorted(offsets)
        for start in range(0, len(offsets), 2000):
            chunk = offsets[start:start + 2000]
            try:
                run = subprocess.run(["atos", "-o", dsyms.get(image, images[image]), "-l", hex(base)]
                                     + [hex(base + int(o, 16)) for o in chunk], capture_output=True, text=True)
            except OSError:
                return resolved
            resolved.update({(image, o): name for o, name in zip(chunk, run.stdout.splitlines())})
    return resolved


def symbol_part(name):
    """An atos line without its ` (in image) (file:line)` tail."""
    return name.split(" (in ")[0]


def classify(daemon, kind, frames, images, resolved):
    """(section, site frame, via frame): the frame that names the site and, for Chromium, cmux's frame below."""
    if daemon:
        section = "daemon_input_wait" if kind.startswith(INPUT_WAIT) else "daemon_request"
        first_cmux = None
        for frame in frames:
            image, offset, symbol = split_frame(frame)
            if image not in images:
                continue
            first_cmux = first_cmux or frame
            if RUST_CRATE.search(symbol_part(resolved.get((image, offset), "")) or symbol):
                return section, frame, None
        return section, first_cmux or (frames[0] if frames else "?|?|?"), None
    for index, frame in enumerate(frames):
        image, _, _ = split_frame(frame)
        if image in CHROMIUM_IMAGES:
            via = next((f for f in frames[index + 1:] if is_cmux(split_frame(f)[0], images)), None)
            return "app_chromium", frame, via
        if is_cmux(image, images):
            return "app_main", frame, None
    return "app_main", frames[0] if frames else "?|?|?", None


def frame_name(frame, resolved):
    image, offset, symbol = split_frame(frame)
    name = resolved.get((image, offset))
    if name:
        return name
    return symbol if symbol not in ("", "?") else f"{image}+{offset}"


def module_of(symbol, name, owned):
    match = SWIFT_MODULE.match(symbol or "")
    if match:
        return match.group(2)[:int(match.group(1))]
    crate = RUST_CRATE.search(symbol_part(name)) or RUST_CRATE.search(symbol or "")
    if crate:
        return crate.group(1)
    return next((m for m in owned if m in name), "")


def owners(repo_root):
    """Module or crate name -> owner, from OWNERS.md's path column (Sources/<Module>/, cmux-tui/crates/<crate>/)."""
    text = open(os.path.join(repo_root, "plans/cmux-next/OWNERS.md")).read()
    owned = {}
    for row in text.splitlines():
        if not row.startswith("| "):
            continue
        cells = row.split("|")
        if len(cells) < 4:
            continue
        for match in re.finditer(r"Sources/(CmuxNext\w+)/", row):
            owned.setdefault(match.group(1), cells[3].strip())
        for match in re.finditer(r"cmux-tui/crates/([\w-]+)/", row):
            owned.setdefault(match.group(1).replace("-", "_"), cells[3].strip())
    return owned


def demangle(symbols):
    if not symbols:
        return {}
    try:
        run = subprocess.run(["swift", "demangle", "--simplified"], input="\n".join(symbols),
                             capture_output=True, text=True)
    except OSError:
        return {}
    return dict(zip(symbols, run.stdout.split("\n")))


def build(entries, images, dsyms, owned):
    wanted = collections.defaultdict(set)
    for _, _, _, _, _, _, frames in entries:
        for frame in frames:
            image, offset, _ = split_frame(frame)
            if image in images:
                wanted[image].add(offset)
    resolved = atos(images, dsyms, wanted)
    sites = {section: collections.defaultdict(lambda: {
        "count": 0, "total_ns": 0, "max_ns": 0, "kinds": collections.Counter(), "threads": collections.Counter(),
        "stack": "", "symbol": "", "vias": collections.Counter()}) for section in SECTIONS}
    for daemon, kind, thread, count, total, longest, frames in entries:
        section, frame, via = classify(daemon, kind, frames, images, resolved)
        name = frame_name(frame, resolved)
        if section == "app_chromium":
            image, offset, _ = split_frame(frame)
            name = f"{name} [{image}+{offset}]"
        site = sites[section][name]
        site["count"] += count
        site["total_ns"] += total
        site["kinds"][kind] += count
        site["threads"][thread] += count
        site["symbol"] = split_frame(frame)[2]
        if via:
            site["vias"][frame_name(via, resolved)] += total
        if longest >= site["max_ns"]:
            site["max_ns"] = longest
            site["stack"] = ";".join(frames[:12])
    for section in sites.values():
        for site in section.values():
            # The cmux caller with the most time under this Chromium site, not whichever entry came last.
            site["via"] = site["vias"].most_common(1)[0][0] if site["vias"] else ""
    demangled = demangle([s["symbol"] for section in sites.values() for s in section.values()
                          if s["symbol"].startswith("$s")]
                         + [s["via"] for section in sites.values() for s in section.values()
                            if s["via"].startswith("$s")])
    report = {}
    for section in SECTIONS:
        rows = []
        for name, site in sorted(sites[section].items(), key=lambda kv: -kv[1]["total_ns"]):
            module = module_of(site["symbol"], name, owned)
            label = demangled.get(name) or name if name.startswith("$s") else name
            rows.append({"site": label, "symbol": site["symbol"], "module": module,
                         "owner": owned.get(module, "unowned"), "count": site["count"],
                         "total_ms": round(site["total_ns"] / 1e6, 3), "max_ms": round(site["max_ns"] / 1e6, 3),
                         "kinds": dict(site["kinds"]), "threads": dict(site["threads"]),
                         "via": demangled.get(site["via"]) or site["via"], "stack": site["stack"]})
        report[section] = rows
    return report


def section_summary(rows):
    return {"sites": len(rows), "blocked_ms": round(sum(r["total_ms"] for r in rows), 1),
            "by_owner": dict(collections.Counter(r["owner"] for r in rows)),
            "by_module": dict(collections.Counter(r["module"] or "system/other" for r in rows)),
            "by_thread": dict(sum((collections.Counter(r["threads"]) for r in rows), collections.Counter()))}


def write_markdown(path, summary, report, overhead_ms):
    dumps = summary["dumps"]
    with open(path, "w") as md:
        md.write(f"Blocking probe: launches {summary['launches']}, dumps {dumps['final']} at exit + "
                 f"{dumps['periodic only']} periodic only (a kill or a crash: up to 10 s missing), "
                 f"{dumps['daemon']} of them from the daemon. Probe overhead, estimate: {overhead_ms:.0f} ms over "
                 f"{summary['calls_timed']} timed calls. Dropped entries: {summary['dropped']}. Torn dump lines "
                 f"skipped: {summary['bad_lines']}.\n\n"
                 "Known gaps (probe.c header): pthread_rwlock_*, os_unfair_lock_lock_with_options, semaphore_wait, "
                 "mach_msg (sync XPC), __ulock_wait, kevent, renamex_np, ftruncate, xattrs, readv/writev, "
                 "getdirentries64, copyfile/clonefile, dispatch_async_and_wait, some $NOCANCEL forms, calls a system "
                 "library makes to itself. A daemon thread's wait for its next input (input-wait:*) is in "
                 "daemon_input_wait, a recv or poll that waits for another process's reply inside a request too; a "
                 "worker's condition or semaphore wait for its next job stays in daemon_request (read the kinds "
                 "column).\n")
        for section in SECTIONS:
            rows = report[section]
            info = summary["sections"][section]
            md.write(f"\n## {section}: {SECTION_TITLES[section]}\n\n{info['sites']} sites, {info['blocked_ms']} ms "
                     "in total.\n\n")
            if not rows:
                md.write("None recorded.\n")
                continue
            md.write("| # | total ms | max ms | calls | kinds | threads | site | via | module | owner |\n"
                     "|---|---|---|---|---|---|---|---|---|---|\n")
            for index, r in enumerate(rows, 1):
                kinds = ", ".join(f"{k} {v}" for k, v in sorted(r["kinds"].items(), key=lambda kv: -kv[1]))
                threads = ", ".join(f"{k} {v}" for k, v in sorted(r["threads"].items(), key=lambda kv: -kv[1]))
                via = f"`{r['via'][:80]}`" if r["via"] else ""
                md.write(f"| {index} | {r['total_ms']} | {r['max_ms']} | {r['count']} | {kinds} | {threads} | "
                         f"`{r['site'][:120]}` | {via} | {r['module']} | {r['owner']} |\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("dumps", nargs="+")
    parser.add_argument("--app", help="the .app the dumps came from (a report)")
    parser.add_argument("--launches", type=int, default=0, help="launches the sweep made (to compare with the dumps)")
    parser.add_argument("--out", help="the report's folder")
    parser.add_argument("--select", choices=("main", "daemon"), help="print the app's or the daemon's dumps")
    parser.add_argument("--preflight", action="store_true", help="check blocking-probe.sh's preflight dumps")
    opts = parser.parse_args()
    if opts.select:
        for path in select(opts.dumps, opts.select):
            print(path)
        return 0
    if opts.preflight:
        problems = preflight(opts.dumps)
        for problem in problems:
            print(f"blocking-probe: preflight: {problem}", file=sys.stderr)
        return 1 if problems else 0
    if not opts.app or not opts.out:
        parser.error("a report needs --app and --out")

    images = app_images_of(opts.app)
    dsyms = {os.path.basename(p): p
             for p in glob.glob(os.path.join(os.path.dirname(opts.app), "*.dSYM/Contents/Resources/DWARF/*"))}
    owned = owners(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.."))
    entries, dumps, overhead, bad_lines = read_dumps(opts.dumps)
    report = build(entries, images, dsyms, owned)

    # An estimate: two clock reads (about 20 ns each) per timed call, plus the measured recording time.
    overhead_ms = overhead["calls"] * 40e-6 + overhead["record_ns"] / 1e6
    summary = {"launches": opts.launches, "dumps": dumps, "bad_lines": bad_lines, "calls_timed": overhead["calls"],
               "dropped": overhead["dropped"], "probe_overhead_ms_estimate": round(overhead_ms, 1),
               "sections": {section: section_summary(report[section]) for section in SECTIONS}}
    os.makedirs(opts.out, exist_ok=True)
    with open(os.path.join(opts.out, "blocking-probe.json"), "w") as f:
        json.dump({"summary": summary, "sections": report}, f, indent=1)
    write_markdown(os.path.join(opts.out, "blocking-probe.md"), summary, report, overhead_ms)
    print(json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
