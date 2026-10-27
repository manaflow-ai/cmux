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
                     recv, poll, select, waitpid, a mach receive without a send), listed apart: an idle wait is
                     not blocking work, as Chrome's message pump waits outside any ScopedBlockingCall

Each section's summary also counts its calls by kind without the call's name (by_kind: file-io, process-spawn,
xpc-reply, mach-receive, library-load, system-call, system-query, ...).

With --until-mark NAME, a fifth section, listed first:

  launch             the app's main thread before the launch mark NAME, cmux's calls and Chromium's ("by"), from
                     the probe's launch window dumps (<dump>.window, "#window NAME"), each site with the number of
                     launches it was hit in: Q5's raw list (plans/cmux-next/chrome-parity/p08-startup.md). A
                     launch whose app never sent the mark has no window and is counted as missing, never as clean

  scripts/measure/blocking-probe-report.py --app APP.app [--launches N] [--until-mark NAME] --out DIR \
      dump1.tsv [dump2.tsv ...] [dump1.tsv.window ...]
  scripts/measure/blocking-probe-report.py --select main|daemon dump1.tsv ...   prints the app's or daemon's dumps
  scripts/measure/blocking-probe-report.py --preflight [--until-mark NAME] dump1.tsv ...   the harness's preflight
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
LAUNCH = "launch"
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
# The preflight app's one main-thread call of each cross-process and loader kind (blocking-probe.sh cross_process).
PREFLIGHT_CROSS_PROCESS = ("xpc-reply:xpc_connection_send_message_with_reply_sync", "mach-receive:mach_msg",
                           "library-load:dlopen", "system-query:getpwuid_r", "process-spawn:fork")
MACH_RECEIVE = "mach-receive:"


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


def is_window(header):
    """A launch window dump (the probe's <dump>.window, CMUX_BLOCKING_PROBE_UNTIL_MARK), not a process's dump."""
    return header is not None and "window" in header


def split_windows(paths):
    """(the processes' dumps, the launch window dumps)."""
    windows = [path for path in paths if is_window(dump_header(path))]
    return [path for path in paths if path not in windows], windows


def select(paths, want):
    """The dumps of the app (want "main": #threads is main) or of the daemon (want "daemon": any other); never a
    launch window dump."""
    picked = []
    for path in paths:
        header = dump_header(path)
        if header is not None and not is_window(header) \
                and (header.get("threads", "main") != "main") == (want == "daemon"):
            picked.append(path)
    return picked


def rows_of(path):
    """(kind, thread) of every row of a dump."""
    with open(path, errors="replace") as f:
        return [tuple(line.split("\t")[:2]) for line in f if not line.startswith("#") and "\t" in line]


def preflight_window(apps, windows, until_mark):
    """The launch window's problems: the preflight app spawns its chain, makes LaunchMarkSink's fcntls and writes on
    the probe's mark descriptor, sends the mark, then checks access("/") and makes its cross-process calls; its one
    window holds the spawn and neither the access, the cross-process calls nor the self-test (queued for the main run loop), nor a write or fcntl: the probe made that
    descriptor, so calls on it are not the app's."""
    if len(windows) != 1:
        return [f"{len(windows)} launch window dumps, want 1: the probe did not see the app's {until_mark} mark on "
                "CMUX_NEXT_LAUNCH_MARKS_FD"]
    problems = []
    header, rows = dump_header(windows[0]), rows_of(windows[0])
    if header.get("window") != until_mark:
        problems.append(f"the launch window ends at {header.get('window')!r}, want {until_mark!r}")
    if ("process-spawn:posix_spawn", "main") not in rows:
        problems.append("the launch window lacks the app's spawn, made before the mark")
    if any(kind in ("file-io:access", "selftest", *PREFLIGHT_CROSS_PROCESS) for kind, _ in rows):
        problems.append("the launch window holds calls made after the mark (access, the cross-process calls or the "
                        "self-test)")
    if any(kind in ("io:write", "file-io:fcntl") for kind, _ in rows):
        problems.append("the launch window holds a write or fcntl: the probe recorded calls on its own mark "
                        "descriptor")
    if apps and ("file-io:access", "main") not in rows_of(apps[0]):
        problems.append("the app's dump lacks its access after the mark: the dump left out calls after the window")
    return problems


def preflight_cross_process(path):
    """The app dump's problems with the cross-process and loader kinds: one main-thread row of each, and its 5 ms
    mach receive the only mach receive (the main run loop's idle wait and the receives inside the XPC send and
    getpwuid_r are not)."""
    problems = []
    with open(path, errors="replace") as f:
        main = [fields for fields in (line.split("\t") for line in f if not line.startswith("#"))
                if len(fields) > 2 and fields[1] == "main"]
    main_kinds = {fields[0] for fields in main}
    for kind in PREFLIGHT_CROSS_PROCESS:
        if kind not in main_kinds:
            problems.append(f"the app's dump lacks its main-thread {kind}: the probe does not interpose it")
    receives = sum(int(fields[2]) for fields in main if fields[0].startswith(MACH_RECEIVE) and fields[2].isdigit())
    if receives > 1:
        problems.append(f"{receives} main-thread mach receives, want 1: the run loop's idle wait or a receive inside "
                        "the XPC send or getpwuid_r was recorded")
    return problems


def preflight(paths, until_mark=None):
    """The problems in blocking-probe.sh's preflight dumps (app -> inert hop -> owner, and with until_mark the app's
    launch window); empty when the probe works."""
    problems = []
    paths, windows = split_windows(paths)
    apps, daemons = select(paths, "main"), select(paths, "daemon")
    if len(paths) != 2 or len(apps) != 1 or len(daemons) != 1:
        problems.append(f"{len(paths)} dumps ({len(apps)} app, {len(daemons)} owner), want 2: the app's and the "
                        "owner's; the hop, with only one of the two wanted arguments, must stay inert")
    if until_mark:
        problems.extend(preflight_window(apps, windows, until_mark))
    elif windows:
        problems.append(f"{len(windows)} launch window dumps without a launch window asked for")
    for path in apps[:1]:
        if dump_header(path).get("final") != "1" or ("selftest", "main") not in rows_of(path):
            problems.append("the app's dump has no main-thread self-test row at exit: the probe did not load or "
                            "did not interpose")
        problems.extend(preflight_cross_process(path))
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


def parse_dump(path):
    """(header {key: text}, rows (kind, thread, count, total_ns, max_ns, frames) without self-test rows, torn
    lines). A header value the caller reads as a number is checked there."""
    header, rows, bad_lines = {}, [], 0
    with open(path, errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("#"):
                key, _, value = line[1:].partition("\t")
                header[key] = value
                continue
            try:
                fields = line.split("\t")
                if len(fields) == 5:  # a dump from before the thread column: the main thread
                    fields.insert(1, "main")
                kind, thread, count, total, longest, frames = fields
                if kind == "selftest":  # the probe's own load check (blocking-probe.sh verifies it)
                    continue
                rows.append((kind, thread, int(count), int(total), int(longest), [f for f in frames.split(";") if f]))
            except ValueError:
                bad_lines += 1  # a torn line: counted, never fatal
    return header, rows, bad_lines


def read_dumps(paths):
    """Entries (scope "app" or "daemon", ..., origin: the dump's index) per dump, the dump counts and the probe's
    overhead counters."""
    entries, dumps = [], {"final": 0, "periodic only": 0, "daemon": 0}
    overhead = collections.Counter()
    bad_lines = 0
    for origin, path in enumerate(paths):
        header, rows, torn = parse_dump(path)
        final = 0
        for key, value in header.items():
            try:
                if key == "final":
                    final = int(value)
                elif key not in ("threads", "process"):
                    overhead[key] += int(value)
            except ValueError:
                torn += 1
        bad_lines += torn
        daemon = header.get("threads", "main") != "main"
        entries.extend(("daemon" if daemon else "app", *row, origin) for row in rows)
        dumps["final" if final else "periodic only"] += 1
        dumps["daemon"] += daemon
    return entries, dumps, overhead, bad_lines


def read_windows(paths, apps, until_mark, first_origin):
    """Entries (scope "launch") of the launch window dumps that end at until_mark, and what the launch section
    covers: windows, the app dumps without one (their app never sent the mark: missing, never clean) and when
    the mark came."""
    entries, mark_ms, other, bad_lines = [], [], [], 0
    for origin, path in enumerate(paths, first_origin):
        header, rows, torn = parse_dump(path)
        bad_lines += torn
        if header.get("window") != until_mark:
            other.append(os.path.basename(path))
            continue
        try:
            mark_ms.append(int(header.get("window_ms", "")))
        except ValueError:
            bad_lines += 1
        entries.extend((LAUNCH, *row, origin) for row in rows if row[1] == "main")
    used = {os.path.basename(path) for path in paths} - set(other)
    missing = sorted(os.path.basename(app) for app in apps if os.path.basename(app) + ".window" not in used)
    mark_ms.sort()
    info = {"mark": until_mark, "windows": len(used), "app_dumps": len(apps), "missing": missing,
            "other_marks": other,
            "mark_ms": {"p50": mark_ms[len(mark_ms) // 2], "max": mark_ms[-1]} if mark_ms else {}}
    return entries, info, bad_lines


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


def build(entries, images, dsyms, owned, sections=SECTIONS):
    wanted = collections.defaultdict(set)
    for _, _, _, _, _, _, frames, _ in entries:
        for frame in frames:
            image, offset, _ = split_frame(frame)
            if image in images:
                wanted[image].add(offset)
    resolved = atos(images, dsyms, wanted)
    sites = {section: collections.defaultdict(lambda: {
        "count": 0, "total_ns": 0, "max_ns": 0, "kinds": collections.Counter(), "threads": collections.Counter(),
        "stack": "", "symbol": "", "vias": collections.Counter(), "by": "cmux", "origins": set()})
        for section in sections}
    for scope, kind, thread, count, total, longest, frames, origin in entries:
        section, frame, via = classify(scope == "daemon", kind, frames, images, resolved)
        name = frame_name(frame, resolved)
        if section == "app_chromium":
            image, offset, _ = split_frame(frame)
            name = f"{name} [{image}+{offset}]"
        by = "chromium" if section == "app_chromium" else "cmux"
        if scope == LAUNCH:
            section = LAUNCH
        site = sites[section][name]
        site["by"] = by
        site["origins"].add(origin)
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
    for section in sections:
        rows = []
        for name, site in sorted(sites[section].items(), key=lambda kv: -kv[1]["total_ns"]):
            module = module_of(site["symbol"], name, owned)
            label = demangled.get(name) or name if name.startswith("$s") else name
            row = {"site": label, "symbol": site["symbol"], "module": module,
                   "owner": owned.get(module, "unowned"), "count": site["count"],
                   "total_ms": round(site["total_ns"] / 1e6, 3), "max_ms": round(site["max_ns"] / 1e6, 3),
                   "kinds": dict(site["kinds"]), "threads": dict(site["threads"]),
                   "via": demangled.get(site["via"]) or site["via"], "stack": site["stack"]}
            if section == LAUNCH:
                # Who makes the call, and in how many launches (one window each): any launch counts.
                row.update({"by": site["by"], "launches": len(site["origins"])})
            rows.append(row)
        report[section] = rows
    return report


def kind_family(kind):
    """The kind without its call (`xpc-reply:xpc_connection_send_message_with_reply_sync` -> `xpc-reply`)."""
    return kind.split(":", 1)[0]


def section_summary(rows):
    by_kind = collections.Counter()
    for r in rows:
        for kind, count in r["kinds"].items():
            by_kind[kind_family(kind)] += count
    return {"sites": len(rows), "blocked_ms": round(sum(r["total_ms"] for r in rows), 1),
            "by_owner": dict(collections.Counter(r["owner"] for r in rows)),
            "by_module": dict(collections.Counter(r["module"] or "system/other" for r in rows)),
            "by_thread": dict(sum((collections.Counter(r["threads"]) for r in rows), collections.Counter())),
            "by_kind": dict(by_kind)}


def write_launch(md, launch, rows, info):
    """The launch section: the app's main-thread calls before the mark, in every launch that sent it."""
    timing = (f", the mark at p50 {launch['mark_ms']['p50']} ms, max {launch['mark_ms']['max']} ms after the probe "
              "loaded") if launch["mark_ms"] else ""
    md.write(f"\n## {LAUNCH}: App main thread before the {launch['mark']} mark (cmux's and Chromium's calls)\n\n"
             f"{launch['windows']} launch windows of {launch['app_dumps']} app dumps{timing}. {info['sites']} sites, "
             f"{info['blocked_ms']} ms in total.")
    if launch["missing"]:
        md.write(f" Missing (the app never sent the mark, so its launch is not proved): "
                 f"{', '.join(launch['missing'])}.")
    if launch["other_marks"]:
        md.write(f" Windows of another mark, left out: {', '.join(launch['other_marks'])}.")
    md.write("\n\n")
    if not rows:
        md.write("None recorded.\n")
        return
    md.write("| # | total ms | max ms | calls | launches | by | kinds | site | via | module | owner |\n"
             "|---|---|---|---|---|---|---|---|---|---|---|\n")
    for index, r in enumerate(rows, 1):
        kinds = ", ".join(f"{k} {v}" for k, v in sorted(r["kinds"].items(), key=lambda kv: -kv[1]))
        via = f"`{r['via'][:80]}`" if r["via"] else ""
        md.write(f"| {index} | {r['total_ms']} | {r['max_ms']} | {r['count']} | {r['launches']} | {r['by']} | "
                 f"{kinds} | `{r['site'][:120]}` | {via} | {r['module']} | {r['owner']} |\n")


def write_markdown(path, summary, report, overhead_ms):
    dumps = summary["dumps"]
    with open(path, "w") as md:
        md.write(f"Blocking probe: launches {summary['launches']}, dumps {dumps['final']} at exit + "
                 f"{dumps['periodic only']} periodic only (a kill or a crash: up to 10 s missing), "
                 f"{dumps['daemon']} of them from the daemon. Probe overhead, estimate: {overhead_ms:.0f} ms over "
                 f"{summary['calls_timed']} timed calls. Dropped entries: {summary['dropped']}. Torn dump lines "
                 f"skipped: {summary['bad_lines']}.\n\n"
                 "Known gaps (probe.c header): pthread_rwlock_*, os_unfair_lock_lock_with_options, semaphore_wait, "
                 "mach_msg_overwrite, __ulock_wait, kevent, renamex_np, ftruncate, xattrs, readv/writev, "
                 "getdirentries64, copyfile/clonefile, dispatch_async_and_wait, vfork, other getpw*/getgr* lookups, "
                 "some $NOCANCEL forms, calls a system library makes to itself. An xpc-reply, SecItem (system-call), "
                 "getpwuid (system-query) or dlopen (library-load) row holds its whole call, the mach receives inside "
                 "it not counted again; the main run loop's idle wait is never a mach-receive. A daemon thread's wait for its next input (input-wait:*) is in "
                 "daemon_input_wait, a recv or poll that waits for another process's reply inside a request too; a "
                 "worker's condition or semaphore wait for its next job stays in daemon_request (read the kinds "
                 "column).\n")
        if LAUNCH in report:
            write_launch(md, summary[LAUNCH], report[LAUNCH], summary["sections"][LAUNCH])
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
    parser.add_argument("--until-mark", metavar="NAME",
                        help="add the launch section: the app's main-thread calls before the launch mark NAME, from "
                             "the launch window dumps (<dump>.window) among the dumps")
    opts = parser.parse_args()
    if opts.select:
        for path in select(opts.dumps, opts.select):
            print(path)
        return 0
    if opts.preflight:
        problems = preflight(opts.dumps, opts.until_mark)
        for problem in problems:
            print(f"blocking-probe: preflight: {problem}", file=sys.stderr)
        return 1 if problems else 0
    if not opts.app or not opts.out:
        parser.error("a report needs --app and --out")

    images = app_images_of(opts.app)
    dsyms = {os.path.basename(p): p
             for p in glob.glob(os.path.join(os.path.dirname(opts.app), "*.dSYM/Contents/Resources/DWARF/*"))}
    owned = owners(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.."))
    paths, windows = split_windows(opts.dumps)
    entries, dumps, overhead, bad_lines = read_dumps(paths)
    sections, launch = SECTIONS, None
    if opts.until_mark:
        window_entries, launch, torn = read_windows(windows, select(paths, "main"), opts.until_mark, len(paths))
        entries += window_entries
        bad_lines += torn
        sections = (LAUNCH, *SECTIONS)
    report = build(entries, images, dsyms, owned, sections)

    # An estimate: two clock reads (about 20 ns each) per timed call, plus the measured recording time.
    overhead_ms = overhead["calls"] * 40e-6 + overhead["record_ns"] / 1e6
    summary = {"launches": opts.launches, "dumps": dumps, "bad_lines": bad_lines, "calls_timed": overhead["calls"],
               "dropped": overhead["dropped"], "probe_overhead_ms_estimate": round(overhead_ms, 1),
               "sections": {section: section_summary(report[section]) for section in sections}}
    if launch is not None:
        summary[LAUNCH] = launch
    os.makedirs(opts.out, exist_ok=True)
    with open(os.path.join(opts.out, "blocking-probe.json"), "w") as f:
        json.dump({"summary": summary, "sections": report}, f, indent=1)
    write_markdown(os.path.join(opts.out, "blocking-probe.md"), summary, report, overhead_ms)
    print(json.dumps(summary))
    if launch is not None and launch["windows"] == 0:
        print(f"blocking-probe: no launch window ends at {opts.until_mark}: no app sent that mark (check the name "
              "against the app's launch marks); the launch section proves nothing", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
