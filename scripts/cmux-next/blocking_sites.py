"""The blocking detector's sites as a sweep reads them (p02-threads 300 and 307, MQ-10): the app's switches per mode,
its trap lines in the app's stderr and its fault lines in the unified log, the `debug.blocking` replies grouped by
(fileID, kind, context), one task per module in the design-result task shape, and a trap run's verdict.

every-action-sweep.py (RUN-1) and lifecycle-sweep.py (RUN-12) share it; each names its own tasks (``SWEEPS``), so a
site found by both is filed once per sweep and a rerun of one never renames the other's tasks. Stdlib only; no app.
"""
import functools, os, re, signal, subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))

# The app's environment per --blocking-report mode (BlockingViolationTable reads CMUX_BLOCKING_TRAP once at launch; the
# pool switch is task 005's). Record says 0 outright, so a Debug default flipped to trap (task 021) still records.
BLOCKING_ENV = {"record": {"CMUX_BLOCKING_TRAP": "0", "CMUX_BLOCKING_TRAP_POOL": "0"},
                "trap": {"CMUX_BLOCKING_TRAP": "1", "CMUX_BLOCKING_TRAP_POOL": "1"}}
# The detector's trap messages (BlockingViolationTable.trap's fatalError, CmuxNextCompat/Threading), as the app's
# stderr has them in OUT/app.log: "...: Fatal error: blocking <kind> on the main thread at <Module/File.swift>:<line>:
# move it ..." (recordedSite) and "... on the cooperative pool or a GCD root queue at <Module/File.swift>:<line>: run it
# ..." (recordedOffMainSite). "Fatal error:" keeps out the record mode's log line of the same words. The words between
# "on" and "at" name the context.
BLOCKING_TRAP_LINE = re.compile(r"Fatal error: blocking (?P<kind>[\w-]+) on (?P<where>[^:\n]+?) at (?P<file>[^\s:]+):(?P<line>\d+):")
# The violation contexts debug.blocking reports (BlockingContext's raw values; lane and dedicated may block). RUN-1 and
# RUN-12 (plans/cmux-next/chrome-parity/p02-threads.md section 5) fail on a site of any context or kind.
BLOCKING_CONTEXTS = ("main", "pool", "cpu-lane")
# The detector's fault lines in the unified log (BlockingViolationTable.drain, Debug builds: subsystem
# com.cmuxterm.app.next, category blocking), one per new site of a launch, in either mode. The words after the kind
# name the context; a `.cpu` lane line names the seam's kind, and debug.blocking files that site as `wrong-lane`.
BLOCKING_LOG_PREDICATE = 'subsystem == "com.cmuxterm.app.next" AND category == "blocking"'
BLOCKING_FAULT_LINE = re.compile(r"^blocking (?P<kind>[\w-]+) (?P<where>on the main thread|on the cooperative pool or a GCD "
                                 r"root queue|in a \.cpu lane item|on a sync primitive in a BackgroundWork lane item) at "
                                 r"(?P<file>[^\s:]+):(?P<line>\d+):")
FAULT_CONTEXTS = {"on the main thread": "main", "on the cooperative pool or a GCD root queue": "pool",
                  "in a .cpu lane item": "cpu-lane", "on a sync primitive in a BackgroundWork lane item": "lane-sync"}
# Each sweep's site tasks: their id part, the run that accepts them, the command that reruns it, the task that made the
# sweep, and the key of its verdict in the blocking section.
SWEEPS = {
    "every-action": {"run": "RUN-1", "command": "every-action-sweep.py --blocking-report=trap", "task": "p02-threads-300",
                     "key": "run1"},
    "lifecycle": {"run": "RUN-12", "command": "lifecycle-sweep.py --blocking-report=trap", "task": "p02-threads-307",
                  "key": "run12"},
}


def blocking_fault(message):
    """One fault line's site, {kind, context, location}, or None for any other message of the category."""
    m = BLOCKING_FAULT_LINE.match(message or "")
    if not m:
        return None
    context = FAULT_CONTEXTS[m["where"]]
    return {"kind": "wrong-lane" if context == "cpu-lane" else m["kind"], "context": context,
            "location": f"{m['file']}:{m['line']}"}



def blocking_traps(log_path, start=0):
    """The detector's traps in the app log from byte `start` on: one {kind, context, location} per BLOCKING_TRAP_LINE."""
    try:
        with open(log_path, errors="replace") as f:
            f.seek(start)
            text = f.read()
    except OSError:
        return []
    return [{"kind": m["kind"], "context": "main" if m["where"].strip() == "the main thread" else
             ("pool" if "pool" in m["where"] else m["where"].strip()), "location": f"{m['file']}:{m['line']}"}
            for m in BLOCKING_TRAP_LINE.finditer(text)]


def blocking_site_groups(reads, traps=()):
    """The sites of every read debug.blocking reply, one group per (fileID, kind, context) (MQ-10): its lines, count,
    and the sessions it was seen in. A site without `context` is main (the detector before task 005 checks only main).
    A trap from app.log is a site of session "trap": the launch stopped there (or while it quit), so no read has it."""
    groups = {}

    def add(location, kind, context, count, session, max_ms=None):
        location = str(location or "?")
        file_id, _, line = location.rpartition(":")
        file_id = file_id if line.isdigit() else location
        key = (file_id, str(kind or "?"), str(context or "main"))
        group = groups.setdefault(key, {"file_id": key[0], "kind": key[1], "context": key[2],
                                        "module": key[0].split("/", 1)[0], "lines": set(), "count": 0,
                                        "sessions": set(), "max_ms": None})
        if line.isdigit():
            group["lines"].add(int(line))
        group["count"] += count
        group["sessions"].add(session)
        if isinstance(max_ms, (int, float)):
            group["max_ms"] = max(group["max_ms"] or 0, max_ms)

    for read in reads:
        reply = read.get("reply")
        if blocking_read_problem(reply, None):
            continue
        for site in reply.get("sites") or []:
            add(site.get("location"), site.get("kind"), site.get("context"), int(site.get("count") or 0),
                str(read.get("session")), site.get("max_ms"))
    for trap in traps:
        add(trap.get("location"), trap.get("kind"), trap.get("context"), 1, "trap")
    return [dict(g, lines=sorted(g["lines"]), sessions=sorted(g["sessions"]))
            for _, g in sorted(groups.items(), key=lambda kv: (kv[1]["module"], kv[0]))]


@functools.lru_cache(maxsize=None)
def swift_source_index(root=ROOT):
    """(module folder, file name) -> the repo's paths Packages/**/Sources/<Module>/**/<File>.swift. A site's location
    is Swift's #fileID, `Module/File.swift`, without the folders inside the module, in any package the detector
    links (CmuxNext and the Shared packages). From `git ls-files`, or a walk of Packages without git."""
    try:
        listed = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", "Packages/*.swift"], capture_output=True,
                                timeout=60, check=True).stdout.decode(errors="replace").split("\0")
    except (OSError, subprocess.SubprocessError):
        listed = []
        for folder, dirs, names in os.walk(os.path.join(root, "Packages")):
            dirs[:] = [d for d in dirs if not d.startswith(".")]  # .build and other caches
            listed += [os.path.relpath(os.path.join(folder, n), root) for n in names if n.endswith(".swift")]
    index = {}
    for path in listed:
        parts = path.split("/")
        if "Sources" in parts and parts.index("Sources") + 2 < len(parts):
            index.setdefault((parts[parts.index("Sources") + 1], parts[-1]), []).append(path)
    return index


def blocking_source_paths(file_id, index):
    """The repo files a #fileID `Module/File.swift` can be: one when it resolves, none or several when it does not."""
    module, slash, name = file_id.partition("/")
    return sorted(index.get((module, os.path.basename(name)), [])) if slash else []


def blocking_task_id(module, sweep="every-action"):
    """A site task's id, from its sweep and module only: a rerun after some modules were fixed, and lifecycle-sweep
    (task 307) filing its own sites, never give a filed id to other work."""
    return f"p02-threads-R-{sweep}-{module}"


def blocking_tasks(groups, index=None, sweep="every-action"):
    """One task per module of the site groups (MQ-10, blocking_task_id), in the design-result task shape, to fix with
    the MQ-1 recipe (task 060) and rerun with traps. `files` are the real paths of the sites' #fileIDs
    (swift_source_index); a fileID with no single match is `unresolved`, with its candidates, and the change says so."""
    index = swift_source_index() if index is None else index
    modules = {}
    for group in groups:
        modules.setdefault(group["module"], []).append(dict(group, paths=blocking_source_paths(group["file_id"], index)))
    tasks = []
    for module, items in sorted(modules.items()):
        sites = [f"{g['file_id']}:{','.join(map(str, g['lines'])) or '?'} {g['kind']} ({g['context']}, {g['count']}x)"
                 for g in items]
        unresolved = {g["file_id"]: g["paths"] for g in items if len(g["paths"]) != 1}
        change = ("MQ-1 recipe (task 060) for each site: the seam, and the call moved off its context (main, pool or "
                  "the wrong lane) in the same commit. Sites: " + "; ".join(sites))
        if unresolved:
            change += (". Unresolved fileIDs (no single Packages/**/Sources/<Module>/**/<File>): "
                       + "; ".join(f"{f} ({', '.join(c) if c else 'no file'})" for f, c in sorted(unresolved.items())))
        tasks.append({"id": blocking_task_id(module, sweep), "title": f"runtime blocking sites in {module} ({len(items)} groups)",
                      "files": sorted({p for g in items for p in g["paths"]}), "unresolved": unresolved,
                      "change": change,
                      "acceptance": f"{SWEEPS[sweep]['command']} ({SWEEPS[sweep]['run']}) reports none of these sites "
                                    "and 0 traps; a red-first test per changed user-reachable path.",
                      "test_phase": "T1; T2", "size": "S" if len(items) <= 3 else "M",
                      "depends_on": [SWEEPS[sweep]["task"]],
                      "machine_queue": "MQ-10", "sites": items})
    return tasks


def blocking_read_problem(reply, mode):
    """Why a debug.blocking reply cannot count as a launch's sites, or None: an error, a build without the detector
    (a bench build answers compiled_in false with no sites, which is not "no blocking"), or, when `mode` is "trap",
    a detector whose main or pool mode is not trap (RUN-1 needs both)."""
    if not isinstance(reply, dict):
        return f"no reply ({reply!r})"
    if reply.get("error"):
        return str(reply["error"])[:240]
    if reply.get("compiled_in") is not True:
        return "the build has no blocking detector (compiled_in is not true)"
    if mode == "trap" and (reply.get("mode"), reply.get("pool_mode")) != ("trap", "trap"):
        return f"the detector ran in mode {reply.get('mode')!r}, pool_mode {reply.get('pool_mode')!r}, not trap"
    return None


def blocking_section(mode, reads, traps, partial=False, last_quit=None, index=None, sweep="every-action"):
    """The report's `blocking` section: the reads (`unread`: the launches whose reply cannot count), the traps, the
    site groups and their tasks, and the trap run's verdict under its sweep's key (``SWEEPS``: `run1` for RUN-1,
    `run12` for RUN-12; problems, empty when clean). A record run has no verdict (its sites are its output).
    `last_quit`: why the last launch's quit was not checked, or None."""
    groups = blocking_site_groups(reads, traps)
    overflow = sum(int((r.get("reply") or {}).get("overflow") or 0) for r in reads if isinstance(r.get("reply"), dict))
    unread = [f"{r.get('session')} launch {r.get('launch')}: {why}" for r in reads
              if (why := blocking_read_problem(r.get("reply"), mode))]
    section = {"mode": mode, "reads": reads, "unread": unread, "traps": traps, "groups": groups,
               "tasks": blocking_tasks(groups, index, sweep), "sites": sum(len(g["lines"]) or 1 for g in groups),
               "overflow": overflow, "last_quit": last_quit,
               "contexts": {c: sum(1 for g in groups if g["context"] == c) for c in
                            sorted(set(BLOCKING_CONTEXTS) | {g["context"] for g in groups})},
               "kinds": {k: sum(1 for g in groups if g["kind"] == k) for k in sorted({g["kind"] for g in groups})}}
    if mode != "trap":
        return section
    problems = []
    if not reads:
        problems.append("no launch was read")
    problems += [f"{r.get('session')} launch {r.get('launch')} exited on SIGTRAP" for r in reads
                 if r.get("exit") == -signal.SIGTRAP]
    problems += [f"{r.get('session')} launch {r.get('launch')} trapped while it quit (SIGTRAP)" for r in reads
                 if r.get("quit_exit") == -signal.SIGTRAP and r.get("exit") != -signal.SIGTRAP]
    if last_quit:
        problems.append(f"{last_quit}: its quit is not checked")
    problems += [f"not read: {why}" for why in unread]
    if traps:
        problems.append(f"{len(traps)} trap(s): " + ", ".join(f"{t['location']} {t['kind']}" for t in traps[:10]))
    read_groups = [g for g in groups if g["sessions"] != ["trap"]]
    if read_groups:
        problems.append(f"{len(read_groups)} site group(s): "
                        + ", ".join(f"{g['file_id']} {g['kind']}" for g in read_groups[:10]))
    if overflow:
        problems.append(f"overflow {overflow}")
    section[SWEEPS[sweep]["key"]] = {"clean": not problems, "problems": problems, "whole_catalog": not partial}
    return section
