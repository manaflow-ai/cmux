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

Then the filing (p02-threads.md task 301), in blocking-probe-filing.json, perf-lead-rows.md and at the end of the
Markdown: one MQ-11 task per cmux function on the main thread with 1 ms or more in total, one MQ-13 task per daemon
(location, kind, thread), the app_chromium total handed to the CEF helper-app program as an open number, and RUN-2's
verdict (fail: a single cmux wait of 1 ms or more; pass: the run's whole cmux main off-CPU time under the 0.5 ms
per-action bound, with a complete STRESS session, no failed session, a sweep that exited 0 and every dump complete;
otherwise unproved). The probe has no per-action time, so the per-action p99 is not measured. perf-lead-rows.md
holds perf-lead.md section 5's RUN-2 row and the daemon (MQ-13) row with sha, host and macOS from the sweep's
every-action.json.

  scripts/measure/blocking-probe-report.py --app APP.app [--launches N] [--until-mark NAME] --out DIR \
      [--sweep-json every-action.json] [--sweep-status N] [--known-sites mq13-record-sites.json \
      --known-sites-sha SHA] [--config NAME] dump1.tsv [dump2.tsv ...] [dump1.tsv.window ...]
  scripts/measure/blocking-probe-report.py --select main|daemon dump1.tsv ...   prints the app's or daemon's dumps
  scripts/measure/blocking-probe-report.py --preflight [--until-mark NAME] dump1.tsv ...   the harness's preflight
"""
import argparse
import collections
import datetime
import glob
import hashlib
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
# cmux_threads' blocking wrappers (checked::fs::read, checked::sync::wait, the sync and lock_wait locks,
# scoped_blocking_call), resolved or mangled (`12cmux_threads7checked`): each is its own frame above the std call,
# so a daemon site is the first crate frame below them, the code that called the wrapper, the location the
# wrapper's #[track_caller] records in server.blocking.
BLOCKING_WRAPPER = re.compile(r"(?<![A-Za-z])cmux_threads(?:::|\d+)(?:checked|sync|lock_wait|blocking)(?=::|\d|\W|$)")
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
        first_cmux = first_wrapper = None
        for frame in frames:
            image, offset, symbol = split_frame(frame)
            if image not in images:
                continue
            first_cmux = first_cmux or frame
            name = symbol_part(resolved.get((image, offset), "")) or symbol
            if RUST_CRATE.search(name):
                if not BLOCKING_WRAPPER.search(name):
                    return section, frame, None
                first_wrapper = first_wrapper or frame
        return section, first_wrapper or first_cmux or (frames[0] if frames else "?|?|?"), None
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
        "stack": "", "symbol": "", "vias": collections.Counter(), "by": "cmux", "origins": set(),
        "pairs": collections.defaultdict(lambda: [0, 0, 0]), "cmux_frame": False})
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
        # MQ-13 files each (site, kind, thread); RUN-2 counts single waits of 1 ms or more in cmux code.
        pair = site["pairs"][(kind, thread)]
        pair[0] += count
        pair[1] += total
        pair[2] = max(pair[2], longest)
        site["cmux_frame"] = site["cmux_frame"] or is_cmux(split_frame(frame)[0], images)
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
                   "via": demangled.get(site["via"]) or site["via"], "stack": site["stack"],
                   "cmux_frame": site["cmux_frame"],
                   "pairs": [{"kind": kind, "thread": thread, "count": c, "total_ms": round(t / 1e6, 3),
                              "max_ms": round(m / 1e6, 3)}
                             for (kind, thread), (c, t, m) in sorted(site["pairs"].items(), key=lambda kv: -kv[1][1])]}
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


# The filing (p02-threads.md task 301): each app_main function with 1 ms or more in total is one MQ-11 task, each
# daemon_request (site, kind, thread) one MQ-13 task, and the app_chromium total goes to the CEF helper-app program
# as an open number. RUN-2 is judged from the same rows. Chrome keeps the same split: a ScopedBlockingCall on the
# UI thread is a bug in the code that makes it (base/threading/thread_restrictions.h).
WAIT_MS = 1.0  # RUN-2: no single main-thread wait of 1 ms or more in cmux code; MQ-11: a site's total of 1 ms or more
PER_ACTION_MS = 0.5  # RUN-2: main off-CPU time in cmux frames per action, p99
CEF_PROGRAM = "p01-process"
CEF_DESIGN = "plans/cmux-next/cef-helper-app-DESIGN.md"
# The ` (File.swift:123)` tail of an atos line; atos names the file without its folders.
SOURCE = re.compile(r"\(([\w.+-]+\.(?:swift|rs|mm|m|cc|cpp|c|h)):(\d+)\)\s*$")
# A location in a fixed MQ-13 list, such as p02-threads-303's mq13-record-sites.json ("crates/x/src/y.rs:469:21",
# relative to cmux-tui/).
KNOWN_LOCATION = re.compile(r"^(crates/.+\.rs):(\d+)(?::\d+)?$")
# The cmux_threads BlockingKind names (blocking.rs, as server.blocking and the 303 list write them) that a probe kind
# can be: the probe sees the libc call under the checked primitive, so file-io under checked::fs is "fs", or
# "sqlite" when rusqlite makes it.
CHECKED_KINDS = {
    "file-io": {"fs", "sqlite"},
    "io": {"fs", "sqlite", "fd-read", "fd-write", "ipc-reply"},
    "socket": {"ipc-reply", "fd-read", "fd-write"},
    "socket-read": {"ipc-reply", "fd-read"},
    "socket-write": {"ipc-reply", "fd-write"},
    "lock-wait": {"lock-wait", "sqlite", "priority-inversion"},
    "sync-wait": {"condvar-wait", "recv", "join", "block-on", "lock-wait", "ipc-reply"},
    "process-spawn": {"process-spawn"},
    "sleep": {"sleep"},
    "input-wait": {"process-wait", "recv", "fd-read", "ipc-reply"},
}
HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+\d+(?:,(\d+))? @@", re.M)


def source_index(repo_root):
    """{file name: [repo paths]} of the source atos can name: Packages/ and cmux-tui/crates/."""
    try:
        listed = subprocess.run(["git", "-C", repo_root, "ls-files", "-z", "--", "Packages", "cmux-tui/crates"],
                                capture_output=True, text=True).stdout.split("\0")
    except OSError:
        listed = []
    index = collections.defaultdict(list)
    for path in listed:
        if path:
            index[os.path.basename(path)].append(path)
    return index


def source_of(row, index):
    """("File.swift:123" or "", the repo paths that file can be): exactly one path is a resolved file."""
    match = SOURCE.search(row["site"])
    if not match:
        return "", []
    candidates = index.get(match.group(1), [])
    module = row["module"]
    if module and len(candidates) > 1:
        narrowed = [path for path in candidates
                    if f"/Sources/{module}/" in path or f"/crates/{module.replace('_', '-')}/" in path]
        candidates = narrowed or candidates
    return f"{match.group(1)}:{match.group(2)}", sorted(candidates)


def task_id(queue, *parts):
    """An id from what the site is (its function, and for MQ-13 kind and thread), never its rank in this run: a
    rerun after one site is fixed keeps every other id."""
    return f"p02-threads-{queue}-{hashlib.sha1(chr(31).join(parts).encode()).hexdigest()[:8]}"


def where(rows, index):
    """(resolved files, each row's source as text, the sources with no single file)."""
    files, sources, unresolved = set(), [], []
    for row in rows:
        source, candidates = source_of(row, index)
        if len(candidates) == 1:
            files.add(candidates[0])
        elif source:
            unresolved.append({"source": source, "candidates": candidates[:8]})
        sources.append(source or row["site"][:120])
    return sorted(files), sources, unresolved


def kinds_text(kinds):
    return ", ".join(f"{kind} {count}" for kind, count in sorted(kinds.items(), key=lambda kv: -kv[1]))


def mq11_tasks(rows, index):
    """One task per cmux function on the main thread with 1 ms or more in total, worst first."""
    groups = {}
    for row in rows:
        if row["cmux_frame"] and row["total_ms"] >= WAIT_MS:
            groups.setdefault(symbol_part(row["site"]), []).append(row)
    tasks = []
    for function, members in groups.items():
        files, sources, unresolved = where(members, index)
        kinds = sum((collections.Counter(r["kinds"]) for r in members), collections.Counter())
        total = round(sum(r["total_ms"] for r in members), 3)
        longest = max(r["max_ms"] for r in members)
        tasks.append({
            "id": task_id("B11", function), "title": f"MQ-11 main-thread wait: {function[:100]}",
            "files": files,
            "change": f"Take {kinds_text(kinds)} off the main thread (threading-model.md: the main thread never "
                      f"blocks; use the async or background API, or move the work to its lane): {total} ms in "
                      f"total, longest {longest} ms, at {', '.join(sources)}.",
            "acceptance": f"blocking-probe.sh --config=bench lists no app_main site in {function[:100]} with "
                          f"{WAIT_MS:g} ms or more in total",
            "test_phase": "T3 fleet: blocking-probe.sh --config=bench", "size": "S",
            "depends_on": ["p02-threads-301"], "machine_queue": "MQ-11",
            "module": members[0]["module"], "owner": members[0]["owner"], "total_ms": total, "max_ms": longest,
            "unresolved": unresolved,
            "sites": [{key: r[key] for key in ("site", "count", "total_ms", "max_ms", "kinds", "stack")}
                      for r in members]})
    return sorted(tasks, key=lambda t: -t["total_ms"])


def thread_class(thread):
    """A thread name pattern as both lists write it: the probe's `surface-*-host` is the 303 list's `surface-N-host`."""
    return thread.replace("*", "N")


def git_output(repo_root, *args):
    """git's output, or None when git fails (a commit this checkout does not have, a shallow clone)."""
    try:
        run = subprocess.run(["git", "-C", repo_root, *args], capture_output=True, text=True)
    except OSError:
        return None
    return run.stdout if run.returncode == 0 else None


def moved_line(hunks, line):
    """Where an old line is after a diff's hunks [(old start, old count, new count)], or None when a hunk changed
    it (git blame's rule: an unchanged line keeps its identity, a changed one does not)."""
    shift = 0
    for start, old_count, new_count in hunks:
        if old_count == 0:  # an insertion after line `start`
            if line <= start:
                break
        elif line < start:
            break
        elif line < start + old_count:
            return None
        shift += new_count - old_count
    return line + shift


NO_KNOWN_LIST = ("", frozenset(), "")


def known_sites(path, list_sha, measured_sha, repo_root):
    """A fixed MQ-13 list at the measured commit: (its file name, {(repo path, line, kind, thread class)}, why no
    site can be matched, or ""). Each row's line moves from the list's commit to the measured one through git's
    diff of its file; a row whose line changed in between is left out, so that site is filed as new. Fixture rows
    (test threads) are left out."""
    if not path:
        return NO_KNOWN_LIST
    name = os.path.basename(path)
    with open(path) as f:
        rows = json.load(f)
    rows = [row for row in (rows if isinstance(rows, list) else rows.get("sites", [])) if not row.get("fixture")]
    if not list_sha:
        return name, frozenset(), f"{name}'s commit is not given (--known-sites-sha)"
    if not measured_sha:
        return name, frozenset(), "the sweep recorded no sha"
    old, new = (git_output(repo_root, "rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}")
                for sha in (list_sha, measured_sha))
    if not old or not new:
        return name, frozenset(), f"this checkout cannot resolve {list_sha if not old else measured_sha}"
    old, new = old.strip(), new.strip()
    hunks, known = {}, set()
    for row in rows:
        match = KNOWN_LOCATION.match(str(row.get("location", "")))
        if not match:
            continue
        repo_path = f"cmux-tui/{match.group(1)}"
        if repo_path not in hunks:
            diff = "" if old == new else git_output(repo_root, "diff", "-U0", "--no-renames", old, new, "--",
                                                     repo_path)
            if diff is None:
                return name, frozenset(), f"git cannot diff {old[:11]}..{new[:11]}"
            # findall gives "" for a count git leaves out: a count of 1.
            hunks[repo_path] = [(int(a), int(b or 1), int(c or 1)) for a, b, c in HUNK.findall(diff)]
        line = moved_line(hunks[repo_path], int(match.group(2)))
        if line is not None:
            known.add((repo_path, line, str(row.get("kind", "")), thread_class(str(row.get("thread", "")))))
    return name, frozenset(known), ""


def site_location(row, index):
    """(the site's repo path:line, None when atos named no single file; the location its MQ-13 id hashes: that,
    else the whole atos line)."""
    source, candidates = source_of(row, index)
    if len(candidates) == 1:
        located = f"{candidates[0]}:{source.rsplit(':', 1)[1]}"
        return located, located
    return None, row["site"]


def known_status(located, kind, thread, known):
    """("known", the list's name), ("new", None) or ("unknown", why): a site is on the list only at its own repo
    path and line, with a kind the probe's call can be and the same thread."""
    name, sites, reason = known
    if not name:
        return "new", None
    if reason:
        return "unknown", reason
    if located is None:
        return "unknown", "atos named no single repo file"
    path, line = located.rsplit(":", 1)
    kinds = CHECKED_KINDS.get(kind.split(":")[0], set())
    if any((path, int(line), checked, thread_class(thread)) in sites for checked in kinds):
        return "known", name
    return "new", None


def mq13_tasks(rows, index, known=NO_KNOWN_LIST):
    """One task per daemon (location, kind, thread pattern), worst first; a site on a known list says which."""
    tasks = []
    for row in rows:
        function = symbol_part(row["site"])
        located, location = site_location(row, index)
        files, sources, unresolved = where([row], index)
        for pair in row["pairs"]:
            status, detail = known_status(located, pair["kind"], pair["thread"], known)
            tasks.append({
                "id": task_id("B13", location, pair["kind"], pair["thread"]),
                "title": f"MQ-13 {pair['kind']} on {pair['thread']}: {function[:100]}",
                "files": files, "location": located,
                "change": f"Take the {pair['kind']} off {pair['thread']}, a request or echo thread (p02-threads.md "
                          f"section C; a cmux_threads checked primitive on a worker): {pair['count']} calls, "
                          f"{pair['total_ms']} ms in total, longest {pair['max_ms']} ms, at {sources[0]}.",
                "acceptance": f"blocking-probe.sh lists no daemon_request {pair['kind']} on {pair['thread']} in "
                              f"{function[:100]}, and the daemon's server.blocking has no site there",
                "test_phase": "T1r daemon-blocking-sweep.py suites; T3 fleet: blocking-probe.sh --config=bench",
                "size": "S", "depends_on": ["p02-threads-301"], "machine_queue": "MQ-13",
                "module": row["module"], "owner": row["owner"], "kind": pair["kind"], "thread": pair["thread"],
                "count": pair["count"], "total_ms": pair["total_ms"], "max_ms": pair["max_ms"],
                "known": status, "known_from": detail if status == "known" else None,
                "known_unknown_reason": detail if status == "unknown" else None,
                "unresolved": unresolved, "stack": row["stack"]})
    return sorted(tasks, key=lambda t: -t["total_ms"])


def chromium_handoff(rows):
    """The app_chromium total for the CEF helper-app program: an open number while it is above 0."""
    total = round(sum(r["total_ms"] for r in rows), 3)
    return {"program": CEF_PROGRAM, "design": CEF_DESIGN, "status": "open" if total > 0 else "zero",
            "total_ms": total, "sites": len(rows), "calls": sum(r["count"] for r in rows),
            "max_ms": max((r["max_ms"] for r in rows), default=0),
            "target": "RUN-2: 0 main-thread blocking; not met while total_ms is above 0 (the in-process pump, F2)",
            "top": [{key: r[key] for key in ("site", "via", "total_ms", "max_ms", "kinds")} for r in rows[:15]]}


def sweep_facts(path, status=None):
    """Host, macOS, sha, the sessions that ran and failed, the sweep's exit status and the measured actions (each
    row's repeats), from the sweep's every-action.json; only the exit status when the sweep wrote none."""
    facts = {"sweep_status": status}
    if not path or not os.path.exists(path):
        return facts
    with open(path) as f:
        data = json.load(f)
    env = data.get("env") or {}
    sessions = data.get("sessions") or []
    actions = 0
    for session in sessions:
        for row in (session.get("rows") or []) + (session.get("interactions") or []):
            if not row.get("skipped"):
                actions += max(1, int((row.get("commit_ms") or {}).get("n") or 1))
    failed = [str(f.get("name", "")) for f in data.get("failed_sessions") or []]
    facts.update({"host": env.get("host", ""), "macos": env.get("macos", ""), "machine": env.get("machine", ""),
                  "sha": env.get("sha", ""), "sessions": [s.get("name", "") for s in sessions],
                  "failed_sessions": failed, "actions": actions})
    return facts


def sessions_label(facts):
    """The sessions that ran, as perf-lead.md names them (light + STRESS)."""
    names = ["STRESS" if name == "stress" else name for name in facts.get("sessions") or []]
    return " + ".join(names) or "no session recorded"


def run2_verdict(rows, chromium, summary, facts):
    """RUN-2 for cmux's code, defined on STRESS. Any single wait of 1 ms or more fails. The probe sums each stack
    over the whole run, so it has no per-action time and the per-action p99 is not measured: the bound is proved
    only when the run's whole cmux main off-CPU time is under it (every action's time is at most that total); a
    larger total is unproved, never a pass, and so is a run without a complete STRESS session, with a failed
    session or sweep, missing dumps or dropped entries."""
    cmux = [r for r in rows if r["cmux_frame"]]
    long_sites = sorted((r for r in cmux if r["max_ms"] >= WAIT_MS), key=lambda r: -r["max_ms"])
    cmux_ms = round(sum(r["total_ms"] for r in cmux), 3)
    actions = facts.get("actions") or 0
    incomplete = []
    if summary["dumps"]["periodic only"]:
        incomplete.append(f"{summary['dumps']['periodic only']} dumps periodic only")
    if summary["dropped"]:
        incomplete.append(f"{summary['dropped']} entries dropped")
    if not summary["dumps"]["daemon"]:
        incomplete.append("no daemon dump")
    if not actions:
        incomplete.append("no sweep actions read")
    if "stress" not in (facts.get("sessions") or []):
        incomplete.append(f"no STRESS session (sessions: {sessions_label(facts)})")
    if facts.get("failed_sessions"):
        incomplete.append(f"failed sessions: {', '.join(facts['failed_sessions'])}")
    if facts.get("sweep_status"):
        incomplete.append(f"the sweep exited {facts['sweep_status']}")
    if long_sites:
        verdict = "fail"
    elif cmux_ms < PER_ACTION_MS and not incomplete:
        verdict = "pass"
    else:
        verdict = "unproved"
    return {"verdict": verdict, "waits_ge_1ms_sites": len(long_sites),
            "worst": [{key: r[key] for key in ("site", "max_ms", "total_ms")} for r in long_sites[:5]],
            "cmux_main_ms": cmux_ms, "actions": actions,
            "per_action_p99_ms": None, "per_action_p99_at_most_ms": cmux_ms,
            "no_cmux_frame_ms": round(sum(r["total_ms"] for r in rows if not r["cmux_frame"]), 3),
            "incomplete": incomplete, "app_chromium_ms": chromium["total_ms"],
            "target_met": verdict == "pass" and chromium["total_ms"] == 0}


def filing(report, summary, facts, index, known, config):
    """The run's tasks, RUN-2 and the Chromium hand-off (blocking-probe-filing.json)."""
    chromium = chromium_handoff(report["app_chromium"])
    mq13 = mq13_tasks(report["daemon_request"], index, known)
    statuses = collections.Counter(t["known"] for t in mq13)
    return {"date": datetime.date.today().isoformat(), "config": config, "facts": facts,
            "run2": run2_verdict(report["app_main"], chromium, summary, facts),
            "mq11": mq11_tasks(report["app_main"], index), "mq13": mq13, "app_chromium": chromium,
            "daemon": {"sites": len(report["daemon_request"]),
                       "blocked_ms": summary["sections"]["daemon_request"]["blocked_ms"],
                       "input_wait_ms": summary["sections"]["daemon_input_wait"]["blocked_ms"],
                       "known_list": known[0], "known_unknown_reason": known[2],
                       "known_tasks": statuses["known"], "new_tasks": statuses["new"],
                       "unknown_tasks": statuses["unknown"]}}


def run2_line(filed):
    run2 = filed["run2"]
    return (f"RUN-2 {run2['verdict']} waits_ge_1ms_sites={run2['waits_ge_1ms_sites']} "
            f"cmux_main_ms={run2['cmux_main_ms']} actions={run2['actions']} per_action_p99=not_measured "
            f"mq11_tasks={len(filed['mq11'])} mq13_tasks={len(filed['mq13'])} "
            f"app_chromium_ms={run2['app_chromium_ms']} chromium={filed['app_chromium']['status']} "
            f"target_met={str(run2['target_met']).lower()}")


def perf_lead_rows(filed):
    """perf-lead.md section 5 rows (Date | Workstream | sha | Row | Before | After), host, macOS and sha in each."""
    facts, run2, chromium, daemon = filed["facts"], filed["run2"], filed["app_chromium"], filed["daemon"]
    sessions = sessions_label(facts)
    where_run = (f"{facts.get('host') or 'host not recorded'}, macOS {facts.get('macos') or 'not recorded'}, "
                 f"{facts.get('machine') or 'arch not recorded'}, config {filed['config']}, sessions {sessions}")
    sha = facts.get("sha") or "sha not recorded"
    worst = "; ".join(f"`{w['site'][:80]}` {w['max_ms']} ms" for w in run2["worst"][:3]) or "none"
    incomplete = f" Incomplete: {', '.join(run2['incomplete'])}." if run2["incomplete"] else ""
    app = (f"| {filed['date']} | p02-threads-301 RUN-2 (blocking probe, MQ-11) | {sha} | RUN-2: main-thread waits "
           f"in cmux code, every action {sessions} | - | {run2['verdict']}: {run2['waits_ge_1ms_sites']} cmux "
           f"sites with a single wait of {WAIT_MS:g} ms or more (worst: {worst}); per-action p99 not measured (the "
           f"probe sums each stack over the run: each action's cmux main off-CPU time is at most the run's "
           f"{run2['cmux_main_ms']} ms over {run2['actions']} actions, which proves the < {PER_ACTION_MS:g} ms "
           f"bound only below it); {len(filed['mq11'])} MQ-11 tasks; no cmux frame {run2['no_cmux_frame_ms']} ms. "
           f"app_chromium OPEN: {chromium['total_ms']} ms over {chromium['sites']} sites, longest "
           f"{chromium['max_ms']} ms, to {CEF_PROGRAM} ({CEF_DESIGN}); the 0-blocking target is not met while it is "
           f"above 0.{incomplete} {where_run} |")
    if daemon["known_list"]:
        known = (f"; against {daemon['known_list']}: {daemon['known_tasks']} known, {daemon['new_tasks']} new, "
                 f"{daemon['unknown_tasks']} unknown")
        if daemon["known_unknown_reason"]:
            known += f" ({daemon['known_unknown_reason']})"
    else:
        known = ""
    daemon_row = (f"| {filed['date']} | p02-threads-301 daemon request and echo threads (blocking probe, MQ-13; not "
                  f"RUN-5's server.blocking bench) | {sha} | MQ-13 sites: the app session owner's request and echo "
                  f"threads under the same sweep | - | daemon_request {daemon['sites']} sites, "
                  f"{daemon['blocked_ms']} ms; {len(filed['mq13'])} MQ-13 tasks (location, kind, thread){known}; "
                  f"daemon_input_wait {daemon['input_wait_ms']} ms (a wait for the next input, not blocking work). "
                  f"{where_run} |")
    return [app, daemon_row]


def write_filing(out, filed):
    with open(os.path.join(out, "blocking-probe-filing.json"), "w") as f:
        json.dump(filed, f, indent=1)
    with open(os.path.join(out, "perf-lead-rows.md"), "w") as f:
        f.write("\n".join(perf_lead_rows(filed)) + "\n")


def write_filing_markdown(path, filed):
    """The filing after the sections: the RUN-2 line, the Chromium hand-off and both task lists."""
    chromium = filed["app_chromium"]
    with open(path, "a") as md:
        md.write(f"\n## Filing (p02-threads-301)\n\n`{run2_line(filed)}`\n\napp_chromium, {chromium['status']}: "
                 f"{chromium['total_ms']} ms over {chromium['sites']} sites goes to {chromium['program']} "
                 f"({chromium['design']}); {chromium['target']}.\n")
        for queue, title in (("mq11", "MQ-11: app main thread"), ("mq13", "MQ-13: daemon request and echo threads")):
            tasks = filed[queue]
            md.write(f"\n### {title}, {len(tasks)} tasks\n\n")
            if not tasks:
                md.write("None.\n")
                continue
            md.write("| id | total ms | max ms | title | files | owner |\n|---|---|---|---|---|---|\n")
            for task in tasks:
                files = ", ".join(task["files"]) or ("unresolved: " + ", ".join(u["source"] for u in task["unresolved"])
                                                     if task["unresolved"] else "no source line")
                known = (f" (on {task['known_from']})" if task.get("known_from")
                         else " (known: unknown)" if task.get("known") == "unknown" else "")
                md.write(f"| {task['id']} | {task['total_ms']} | {task['max_ms']} | `{task['title'][:110]}`{known} | "
                         f"{files} | {task['owner']} |\n")


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
    parser.add_argument("--sweep-json", metavar="PATH",
                        help="the sweep's every-action.json: host, macOS, sha and the action count for RUN-2")
    parser.add_argument("--known-sites", metavar="PATH",
                        help="a fixed MQ-13 list (location, kind and thread rows, p02-threads-303's "
                             "mq13-record-sites.json): a daemon task at one of its rows, moved to the measured sha, "
                             "is marked known_from")
    parser.add_argument("--known-sites-sha", metavar="SHA",
                        help="the commit the --known-sites list was recorded at (without it no task is marked known)")
    parser.add_argument("--sweep-status", type=int, help="the sweep's exit status (not 0: RUN-2 is incomplete)")
    parser.add_argument("--config", default="debug", help="the build configuration, for the perf-lead.md rows")
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
    repo_root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "../..")
    facts = sweep_facts(opts.sweep_json, opts.sweep_status)
    known = known_sites(opts.known_sites, opts.known_sites_sha, facts.get("sha"), repo_root)
    filed = filing(report, summary, facts, source_index(repo_root), known, opts.config)
    write_filing(opts.out, filed)
    write_filing_markdown(os.path.join(opts.out, "blocking-probe.md"), filed)
    print(run2_line(filed))
    if launch is not None and launch["windows"] == 0:
        print(f"blocking-probe: no launch window ends at {opts.until_mark}: no app sent that mark (check the name "
              "against the app's launch marks); the launch section proves nothing", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
