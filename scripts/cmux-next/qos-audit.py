#!/usr/bin/env python3
"""QoS audit of the app and the daemon (chrome-parity p02-threads-302, machine queue MQ-15).

Reads `debug.threads` (the app, plans/cmux-next/threading-model.md) and `server-threads` (the cmux-tui daemon)
under the STRESS session, judges them against the done checks RUN-3 (threads part) and RUN-4 (threads part) of
plans/cmux-next/chrome-parity/p02-threads.md, and files each mismatch as one task (MQ-15). Chrome reads the same
facts from its thread metadata (base/threading/platform_thread_apple.mm sets each thread's QoS from its
ThreadType; chrome://tracing lists the type and priority of every thread) and keeps the high classes to a closed
set (kDisplayCritical: the UI thread, the compositor and the threads a frame waits on).

Three modes:

  app      Through the debug socket of a tagged Debug or bench app (--socket), or one it launches (--app, the
           activation-perf launcher perf-stress-session uses): builds the STRESS session
           (perf-stress-session.py; --no-stress measures the session the app has), settles, reads
           `debug.threads` and `debug.surfaces` with the window visible, hides the app (action
           showHideAllWindows), settles, reads them hidden, then shows the app again. --daemon-socket also reads
           the app's daemon `server-threads` in both phases: the app's UI connection threads are judged there.
             nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
               python3 scripts/cmux-next/qos-audit.py app --app "$NX_APP" --daemon-socket S --out "$NX_ARTIFACTS/qos"
  daemon   A headless cmux-tui (--bin) with a STRESS-shaped session (60 workspaces; the measured one 14 panes
           of 2 terminals; 10 terminals printing), then perf-10x-lifecycle's op mix (bench-lifecycle.py: new-tab
           and close-surface, new-browser-tab and close-surface, split right, down and right unsized and
           close-pane, new-workspace and close-workspace; 3 warm-up rounds and --rounds) on a second connection.
           `server-threads` and the process's OS threads are read during the rounds. A thread of this script
           counts the daemon's OS threads every millisecond from its start to the end of the rounds; the peak is
           the highest count. The whole run repeats --repeat times (default 3), each with a new daemon.
           --base-peak is the base binary's result (its qos-peak.json, or a number): the peak part passes only
           when every head run peaks below every base run. --peak-only measures only the peaks (the base binary,
           which may predate server-threads). CMUX_ENABLE_FEATURES=daemonRequestQos is set unless
           --no-request-qos: RUN-4's classes are that feature's. Each unregistered OS thread is named by its id
           (Linux /proc, macOS proc_pidinfo).
             python3 scripts/cmux-next/qos-audit.py daemon --bin target/debug/cmux-tui --base-peak BASE/qos-peak.json
  judge    Judges saved replies: --app-visible, --app-hidden (debug.threads JSON), --app-surfaces (debug.surfaces
           of the visible phase), --app-daemon and --app-daemon-os (the app's daemon, saved by app mode),
           --daemon and --daemon-os (a headless daemon, saved by daemon mode), --peak and --base-peak.

Every mode writes into --out: the raw replies, `qos-findings.json` (each finding with its evidence rows),
`qos-tasks.json` (one task per finding, id `p02-threads-R-qos-<process>-<kind>-<name>`, stable across reruns:
a fixed thread never gives its id to other work), `qos-audit.md` (the table for threading-model.md "QoS audit
(MQ-15)") and prints one `QOS-AUDIT {json}` verdict line.

The verdict has one part per check (`parts`): true when it was read and passes, false when a finding is open,
null when it was not read. RUN-3 is run3_visible, run3_hidden_workspaces (visible phase: Ghostty threads of the
surfaces that are not shown) and run3_hidden. RUN-4 is run4_daemon_threads, run4_ui_connection,
run4_automation and run4_peak. `run3_threads` and `run4_threads` are false when a part of the RUN failed, true
only when every part of it is true, else null: a partial read never passes a RUN. A mode covers these parts: app all of RUN-3, and with --daemon-socket run4_daemon_threads and
run4_ui_connection; daemon run4_daemon_threads, run4_automation and run4_peak (so --base-peak is required);
judge the parts its inputs feed. Exit 2 when a part the run covers was not read (`missing` names it) or a read
failed, else 1 when a finding is open, else 0. Findings:

  mismatch           a declared thread whose requested QoS (the kernel's, overrides excluded) is not one its row
                     allows (app `match` false; daemon `matches` false: kernel class or Linux nice is not the
                     desired class)
  hidden-tier        hidden phase: a thread whose row has a hidden tier (Ghostty surface threads: utility) asks
                     for another
  hidden-workspace-tier
                     visible phase: more threads of a by-visibility row (Ghostty renderer, io) above its hidden
                     tier than surfaces that draw (`debug.surfaces` `drawing`, the visibility ghostty_surface_
                     set_occlusion gave): a surface not shown (a background workspace, a tab behind another) has
                     a thread above utility
  undeclared-cmux    an app thread with a cmux name and no row (`undeclared_cmux`)
  undeclared-library an app thread in a linked library's name space with no row (`undeclared_library`)
  unregistered       a daemon OS thread no `server-threads` row names (by thread id, Linux and macOS; `main` is
                     the thread whose id is the pid on Linux, the lowest thread id on macOS)
  interactive-outside-closed-list
                     a cmux thread at user-interactive whose name is not in threading-model.md's "Closed
                     user-interactive list"
  ui-connection      a reader thread (mux-remote-conn, mux-ws-conn) of the person's connection whose desired or
                     kernel class is not user-interactive, or a request thread (mux-control-dispatch,
                     mux-surface-control) of it not at user-initiated; `lines`: the person's local connection
                     (no thread of its own, p01-process-203: its lines run on the sequenced pool) whose lines do
                     not run at user-interactive (`server-threads` `connections[].lines_qos`); `unseen`: the
                     app's daemon has no connection of the verified app. The person's connection is judged from
                     the facts `server-threads` gives (origin `user`, or `agent` from the verified app's
                     process), not from the class the daemon gave it.
  automation-class   a connection thread of an automation connection (every other) that does not rest at utility,
                     or (`lines`) an automation connection whose lines do not run at utility
  queue-problem      a checked queue whose QoS or target differs from its row; undeclared-queue: a checked
                     queue no row declares; queue-log-overflow: queues the log could not record
  task-role          the process task role was not read (macOS)
  peak-threads       the daemon's highest peak is not below the base's lowest

The fixed RUN-3 (b) queue literals are the static half (threading-inventory.py); this audit reads only what
runs. Requires nothing outside the standard library.
"""
import argparse, importlib.util, json, os, platform, re, shutil, signal, socket, subprocess, sys, tempfile
import threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DOC = os.path.join(REPO, "plans", "cmux-next", "threading-model.md")
TASK_PREFIX = "p02-threads-R-qos"
INTERACTIVE = "user-interactive"
USER_INITIATED = "user-initiated"
UTILITY = "utility"
# The daemon's per-connection threads (remote_entry.rs, websocket_listener.rs, server/connection_scheduler.rs):
# they rest at the connection's class under daemonRequestQos (server/connection_qos.rs `ConnectionClass::qos`).
# A local connection holds none: `server-threads` `connections` gives the class its lines run
# at. `mux-conn` stays for daemons before it.
READER_THREADS = ("mux-conn", "mux-remote-conn", "mux-ws-conn")
# The name a connection's lines are filed under (`server-threads` `connections[].lines_qos`).
LINES = "lines"
REQUEST_THREADS = ("mux-control-dispatch", "mux-surface-control")
CONNECTION_THREADS = READER_THREADS + REQUEST_THREADS
RUN3_PARTS = ("run3_visible", "run3_hidden_workspaces", "run3_hidden")
RUN4_PARTS = ("run4_daemon_threads", "run4_ui_connection", "run4_automation", "run4_peak")
# Source roots searched for a thread's spawn site, by process.
SOURCE_ROOTS = {"app": ["Packages/macOS", "Packages/Shared"], "daemon": ["cmux-tui/crates"]}
SOURCE_SUFFIX = {"app": ".swift", "daemon": ".rs"}
REGISTRY_FILES = {"app": ["Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Threading/ThreadRegistry+App.swift"],
                  "daemon": []}
DOC_REL = "plans/cmux-next/threading-model.md"
# sys/proc_info.h: PROC_PIDLISTTHREADIDS (the thread ids of a pid, 8 bytes each).
PROC_PIDLISTTHREADIDS = 28


class ReadError(RuntimeError):
    """A reply the audit needs could not be read."""


# ----------------------------------------------------------------------------------------------------------------
# Names


def generic_name(name):
    """A thread name with its per-object parts (numbers, hex pointers, uuids) as `N`, so one spawn site files once:
    `surface-12-reader` -> `surface-N-reader`, `network_thread 0x7f9c` -> `network_thread N`."""
    text = re.sub(r"0x[0-9a-fA-F]+", "N", name or "")
    text = re.sub(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", "N", text)
    text = re.sub(r"\d+", "N", text)
    return re.sub(r"N(?:[-_.]N)+", "N", text)


def slug(text):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", (text or "unnamed").lower())).strip("-") or "unnamed"


def closed_list(doc_text):
    """The name patterns of threading-model.md's "Closed user-interactive list" table: each backticked name of a
    row's first column, `<placeholder>` parts as wildcards."""
    section = re.search(r"^## Closed user-interactive list\n(.*?)(?=^## )", doc_text, re.S | re.M)
    if not section:
        raise ReadError("threading-model.md has no 'Closed user-interactive list' section")
    patterns = []
    for line in section.group(1).splitlines():
        if not line.startswith("| ") or line.startswith("| Thread or queue") or line.startswith("|---"):
            continue
        first = line.split("|")[1]
        for token in re.findall(r"`([^`]+)`", first):
            parts = re.split(r"<[^>]+>", token)
            patterns.append(re.compile(".+".join(re.escape(part) for part in parts) + r"\Z"))
    return patterns


def on_closed_list(names, patterns):
    return any(pattern.match(name) for name in names if name for pattern in patterns)


# ----------------------------------------------------------------------------------------------------------------
# Findings


def finding(process, kind, name, phase, detail, evidence):
    return {"process": process, "kind": kind, "name": name, "phases": [phase], "detail": detail,
            "evidence": [evidence] if evidence is not None else []}


def thread_evidence(row):
    return {key: row.get(key) for key in ("tid", "name", "label", "requested_qos", "effective_pri", "declared",
                                          "declared_tiers", "declared_hidden", "declared_as", "origin", "library")}


def surface_census(reply):
    """How many terminal surfaces draw now, from a `debug.surfaces` reply: the panes whose surface `drawing` is
    true (the last visibility the app gave Ghostty, ghostty_surface_set_occlusion). Every other live Ghostty
    surface (a background workspace's, a tab behind another, a warm cached terminal) is not shown."""
    if not isinstance(reply, dict) or not isinstance(reply.get("windows"), list):
        raise ReadError(f"debug.surfaces gave no windows: {str(reply)[:300]}")
    drawing = 0
    for window in reply["windows"]:
        for pane in (window.get("panes") if isinstance(window, dict) else None) or []:
            surface = pane.get("surface") if isinstance(pane, dict) else None
            if isinstance(surface, dict) and surface.get("drawing") is True:
                drawing += 1
    return {"drawing_surfaces": drawing, "live_terminals": reply.get("live_terminals")}


def hidden_workspace_findings(report, census):
    """Visible phase: each by-visibility row (more than one tier and a hidden tier: Ghostty's renderer and io,
    one thread per surface) may have at most as many threads above its hidden tier as surfaces draw. Ghostty
    names its threads without the surface (ghostty-next src/renderer/Thread.zig), so the count is the check: one
    more thread above utility than surfaces shown is a surface that is not shown and did not drop."""
    drawing = census["drawing_surfaces"]
    above = {}
    for row in report["threads"]:
        tiers, hidden = row.get("declared_tiers") or [], row.get("declared_hidden")
        if len(tiers) > 1 and hidden and row.get("requested_qos") and row["requested_qos"] != hidden:
            above.setdefault((row.get("declared_as") or row.get("name"), hidden), []).append(row)
    found = []
    for (name, hidden), rows in sorted(above.items()):
        if len(rows) > drawing:
            found.append({**finding("app", "hidden-workspace-tier", generic_name(name), "visible",
                                    f"{len(rows)} threads above {hidden} with {drawing} surfaces drawing "
                                    f"({census['live_terminals']} live terminals)", None),
                          "evidence": [thread_evidence(row) for row in rows[:8]]})
    return found


def app_findings(report, phase, closed, census=None):
    """The findings of one `debug.threads` reply (ThreadsControl.report), `phase` visible or hidden; `census`
    (surface_census of the same phase) adds the visible phase's hidden-workspace check."""
    if not isinstance(report, dict) or "threads" not in report:
        raise ReadError(f"debug.threads ({phase}) gave no threads: {str(report)[:300]}")
    found = []
    for row in report["threads"]:
        name = generic_name(row.get("declared_as") or row.get("name") or row.get("label") or "")
        thread = thread_evidence(row)
        if row.get("main"):
            name = "main"
        if row.get("match") is False:
            found.append(finding("app", "mismatch", name, phase,
                                 f"requested {row.get('requested_qos')}, row allows {row.get('declared_tiers')}",
                                 thread))
        if (phase == "hidden" and row.get("declared_hidden") and row.get("requested_qos")
                and row["requested_qos"] != row["declared_hidden"]):
            found.append(finding("app", "hidden-tier", name, phase,
                                 f"hidden: requested {row['requested_qos']}, hidden tier {row['declared_hidden']}",
                                 thread))
        if row.get("undeclared_cmux"):
            found.append(finding("app", "undeclared-cmux", generic_name(row.get("name") or row.get("label")), phase,
                                 "a cmux thread with no row", thread))
        elif row.get("undeclared_library"):
            found.append(finding("app", "undeclared-library",
                                 f"{row['undeclared_library']} {generic_name(row.get('name') or row.get('label'))}",
                                 phase, f"a {row['undeclared_library']} thread with no row", thread))
        own = row.get("origin") == "cmux" or row.get("undeclared_cmux")
        if (own and not row.get("main") and row.get("requested_qos") == INTERACTIVE
                and not on_closed_list([row.get("name"), row.get("label"), row.get("declared_as")], closed)):
            found.append(finding("app", "interactive-outside-closed-list", name, phase,
                                 "a cmux thread at user-interactive not in the closed list", thread))
    if phase == "visible" and census is not None:
        found += hidden_workspace_findings(report, census)
    for queue in report.get("queues", []):
        for made in queue.get("made") or []:
            if made.get("problem"):
                found.append(finding("app", "queue-problem", generic_name(made.get("label")), phase,
                                     made["problem"], made))
        if queue.get("declared") is False:
            found.append(finding("app", "undeclared-queue", generic_name(queue.get("name")), phase,
                                 "a checked queue no row declares", queue))
    if report.get("queues_not_recorded"):
        found.append(finding("app", "queue-log-overflow", "checked-queue-log", phase,
                             f"{report['queues_not_recorded']} checked queues not recorded", None))
    if report.get("task_role") in (None, "", "unknown"):
        found.append(finding("app", "task-role", "process", phase, "task role not read", None))
    return found


def daemon_row_qos(row):
    """What a `server-threads` row runs at now, for its finding's text: the kernel's class (macOS), else its Linux
    nice (one nice serves default, user-initiated and user-interactive, cmux-threads qos.rs `linux_nice`), else
    the class it last applied."""
    if row.get("requested_qos"):
        return row["requested_qos"]
    if row.get("nice") is not None:
        return f"nice {row['nice']}"
    return row.get("effective")


def connection_kinds(rows, lines=()):
    """{client: "person" or "automation"} of each connection a `server-threads` thread row or `connections` row
    (`lines`) names, from its facts the way server/connection_qos.rs `ConnectionClass::of` classes it: a remote
    lane is automation, origin `user` (the verified app) is the person's, origin `agent` from a verified app's
    process is the person's, every other is automation. The daemon's own `class` is not read, so a connection it
    classed wrongly is judged by what it is."""
    connections = {}
    for connection in [row.get("connection") for row in rows] + list(lines):
        if isinstance(connection, dict) and connection.get("client") is not None and connection.get("transport"):
            connections[connection["client"]] = connection
    app_pids = {c.get("peer_pid") for c in connections.values()
                if c.get("origin") == "user" and c.get("transport") == "unix" and c.get("peer_pid") is not None}
    kinds = {}
    for client, c in connections.items():
        if c.get("remote_device") or c.get("transport") == "remote":
            kinds[client] = "automation"
        elif c.get("origin") == "user" or (c.get("origin") == "agent" and c.get("peer_pid") in app_pids):
            kinds[client] = "person"
        else:
            kinds[client] = "automation"
    return kinds


def connection_qos_wanted(kind, name):
    """The class a connection thread `name` (or a connection's `lines`) of a `kind` connection rests at
    (ConnectionClass::qos)."""
    if kind == "automation":
        return UTILITY
    return INTERACTIVE if name in READER_THREADS or name == LINES else USER_INITIATED


def main_thread_id(tids, pid, mac):
    """The process's first thread: its id is the pid on Linux; on macOS thread ids come from one counter that
    only grows (pthread_threadid_np), so the first thread has the lowest id of the process."""
    if pid in tids:
        return pid
    return min(tids) if mac and tids else None


def daemon_findings(snapshot, os_threads, phase, closed, automation_only=False, seen=None):
    """The findings of one `server-threads` reply and the daemon's OS threads read next to it.

    `os_threads`: {"count": n, "threads": {tid: comm}, "platform": "linux" or "darwin"} (threads empty when the
    OS does not name them). `automation_only`: every connection is an automation client's, for rows without a
    `connection` field (a daemon before it). `seen` collects the connection kinds whose threads were judged."""
    if not isinstance(snapshot, dict) or "threads" not in snapshot:
        raise ReadError(f"server-threads ({phase}) gave no threads: {str(snapshot)[:300]}")
    seen = set() if seen is None else seen
    found = []
    rows = snapshot["threads"]
    lines = [row for row in snapshot.get("connections") or [] if isinstance(row, dict)]
    kinds = connection_kinds(rows, lines)
    for connection in lines:
        kind = kinds.get(connection.get("client"))
        if kind is None:
            continue
        seen.add(kind)
        wanted = connection_qos_wanted(kind, LINES)
        if connection.get("lines_qos") != wanted:
            found.append(finding("daemon", "ui-connection" if kind == "person" else "automation-class", LINES,
                                 phase, f"{kind} connection {connection['client']} ({connection.get('transport')}, "
                                 f"origin {connection.get('origin')}, classed {connection.get('class')}): its "
                                 f"lines run at {connection.get('lines_qos')}, not {wanted}", connection))
    for row in rows:
        name = generic_name(row.get("name"))
        evidence = {key: row.get(key) for key in ("name", "tid", "declared", "desired", "effective",
                                                   "requested_qos", "nice", "priority", "refused_changes",
                                                   "connection")}
        if row.get("matches") is False:
            found.append(finding("daemon", "mismatch", name, phase,
                                 f"desired {row.get('desired')}, applied {row.get('effective')}, "
                                 f"kernel {daemon_row_qos(row)}", evidence))
        interactive = INTERACTIVE in (row.get("desired"), row.get("requested_qos"))
        connection = row.get("connection") if isinstance(row.get("connection"), dict) else {}
        kind = kinds.get(connection.get("client"))
        if interactive and not on_closed_list([row.get("name")], closed) and not (
                kind == "person" and row.get("name") in READER_THREADS):
            found.append(finding("daemon", "interactive-outside-closed-list", name, phase,
                                 "a daemon thread at user-interactive not in the closed list", evidence))
        if row.get("name") in CONNECTION_THREADS and kind is not None:
            seen.add(kind)
            wanted = connection_qos_wanted(kind, row.get("name"))
            classes = [row.get("desired")] + ([row["requested_qos"]] if row.get("requested_qos") else [])
            if any(qos != wanted for qos in classes):
                found.append(finding("daemon", "ui-connection" if kind == "person" else "automation-class", name,
                                     phase, f"{kind} connection {connection['client']} ({connection.get('transport')}"
                                     f", origin {connection.get('origin')}, classed {connection.get('class')}): "
                                     f"desired {row.get('desired')}, kernel {daemon_row_qos(row)}, rests at "
                                     f"{wanted}", evidence))
        elif automation_only and row.get("name") in CONNECTION_THREADS and "connection" not in row:
            seen.add("automation")
            if row.get("desired") != UTILITY:
                found.append(finding("daemon", "automation-class", name, phase,
                                     f"an automation connection's thread rests at {row.get('desired')}", evidence))
    registered = {row.get("tid") for row in rows if row.get("tid") is not None}
    named = {int(tid): comm for tid, comm in (os_threads.get("threads") or {}).items()}
    pid = (snapshot.get("process") or {}).get("pid")
    if named:
        mac = os_threads.get("platform") == "darwin" or platform_is_mac(snapshot)
        main = main_thread_id(set(named), pid, mac)
        # A thread that never names itself carries its process's name on Linux (the main thread's) and no name
        # on macOS.
        process_name = named.get(main) if main is not None else None
        for tid, comm in sorted(named.items()):
            if tid not in registered:
                if tid == main:
                    name = "main"
                elif comm == process_name or not comm:
                    name = "unnamed"
                else:
                    name = generic_name(comm)
                found.append(finding("daemon", "unregistered", name, phase,
                                     "an OS thread no server-threads row names", {"tid": tid, "comm": comm}))
    elif os_threads.get("count") is not None and os_threads["count"] > len(registered):
        found.append(finding("daemon", "unregistered", "unnamed", phase,
                             f"{os_threads['count'] - len(registered)} OS threads beyond the "
                             f"{len(registered)} registered (the OS gave no names)",
                             {"os_count": os_threads["count"], "registered": len(registered)}))
    if platform_is_mac(snapshot) and not (snapshot.get("process") or {}).get("role"):
        found.append(finding("daemon", "task-role", "process", phase, "task role not read", None))
    return found


def platform_is_mac(snapshot):
    """A macOS daemon reports PRIO_DARWIN_BG; a Linux one reports null."""
    return (snapshot.get("process") or {}).get("darwin_bg") is not None


def merge(findings):
    """One finding per (process, kind, name): phases and evidence joined (at most 8 evidence rows)."""
    merged = {}
    for item in findings:
        key = (item["process"], item["kind"], item["name"])
        if key not in merged:
            merged[key] = {**item, "phases": list(item["phases"]), "evidence": list(item["evidence"]), "count": 0}
        entry = merged[key]
        entry["count"] += 1
        for phase in item["phases"]:
            if phase not in entry["phases"]:
                entry["phases"].append(phase)
        for row in item["evidence"]:
            if len(entry["evidence"]) < 8 and row not in entry["evidence"]:
                entry["evidence"].append(row)
    return sorted(merged.values(), key=lambda f: (f["process"], f["kind"], f["name"]))


# ----------------------------------------------------------------------------------------------------------------
# Tasks


def task_id(item):
    return f"{TASK_PREFIX}-{item['process']}-{item['kind']}-{slug(item['name'])}"[:120]


def spawn_sites(process, name, grep=None):
    """Files that spell the fixed part of `name` (its longest run without `N`, 4 characters or more), tests left
    out; at most 5."""
    if name in ("main", "unnamed", "unseen"):
        return []
    parts = sorted((part.strip(" -_.:") for part in re.split(r"\bN\b|N", name)), key=len, reverse=True)
    needle = next((part for part in parts if len(part) >= 4), None)
    if not needle:
        return []
    if grep is None:
        def grep(text, roots):
            out = subprocess.run(["git", "-C", REPO, "grep", "-l", "-F", "-e", text, "--", *roots],
                                 capture_output=True, text=True)
            return out.stdout.splitlines()
    files = [path for path in grep(needle, SOURCE_ROOTS[process])
             if path.endswith(SOURCE_SUFFIX[process])
             and not re.search(r"(^|/)(Tests?|tests?)(/|$)|_tests?\.rs$|Tests\.swift$", path)]
    return files[:5]


CHANGES = {
    "mismatch": "Make the thread ask for the QoS its row declares (or correct the row when the code is right), "
                "at the spawn site: one class per role, as Chromium's ThreadType.",
    "hidden-tier": "Lower the thread to its hidden tier while what it works for is hidden.",
    "hidden-workspace-tier": "Give each surface that is not shown its hidden visibility (ghostty_surface_set_"
                             "occlusion false), or make the thread follow it, so it drops to its hidden tier.",
    "undeclared-cmux": "Add the thread's row to threading-model.md and the thread registry, with its QoS.",
    "undeclared-library": "Add a 'declared by library' row for the thread to threading-model.md and the registry.",
    "unregistered": "Start the thread through cmux_threads::spawn (or the tokio builder) so server-threads lists it; "
                    "`main` is the process's first thread (register it at entry), `unnamed` a thread that never set "
                    "its name (find it by its stack).",
    "interactive-outside-closed-list": "Lower the thread below user-interactive, or add it to the closed list "
                                       "with the frame or echo that waits on it.",
    "ui-connection": "Class the verified app's connections as the person's and run their readers at the echo "
                     "class and their request threads at user-initiated (server/connection_qos.rs); `unseen`: "
                     "the app's daemon had no verified app connection.",
    "automation-class": "Make the automation connection's threads rest at utility (server/connection_qos.rs).",
    "queue-problem": "Make the queue's QoS and target equal its row.",
    "undeclared-queue": "Add the queue's row to threading-model.md and the registry.",
    "queue-log-overflow": "Raise CheckedQueueLog's capacity or merge the queues that fill it.",
    "task-role": "Read the process task role (task_policy_get TASK_CATEGORY_POLICY).",
    "peak-threads": "Lower the daemon's peak thread count under the lifecycle STRESS below the base.",
}


def tasks_for(findings, grep=None):
    tasks = []
    for item in findings:
        files = spawn_sites(item["process"], item["name"], grep) if item["kind"] not in ("task-role",) else []
        if item["kind"] in ("undeclared-cmux", "undeclared-library", "undeclared-queue", "mismatch",
                            "interactive-outside-closed-list"):
            files += [path for path in REGISTRY_FILES[item["process"]] + [DOC_REL] if path not in files]
        tasks.append({
            "id": task_id(item),
            "machine_queue": "MQ-15",
            "title": f"QoS {item['kind']}: {item['process']} {item['name']}",
            "files": files,
            "change": CHANGES[item["kind"]] + f" Seen: {item['detail']} ({', '.join(item['phases'])}).",
            "acceptance": "qos-audit.py shows no finding with this id in STRESS, window visible and hidden; "
                          "RUN-3 / RUN-4 thread parts.",
            "test_phase": "T3 fleet STRESS (qos-audit.py)",
            "evidence": item["evidence"],
        })
    return tasks


# ----------------------------------------------------------------------------------------------------------------
# Verdict and output


def part_of(item):
    """The verdict part one unmerged finding fails."""
    if item["process"] == "app":
        if item["kind"] == "hidden-workspace-tier":
            return "run3_hidden_workspaces"
        return "run3_hidden" if item["phases"] == ["hidden"] else "run3_visible"
    return {"ui-connection": "run4_ui_connection", "automation-class": "run4_automation",
            "peak-threads": "run4_peak"}.get(item["kind"], "run4_daemon_threads")


def run_verdict(parts, names):
    """False when a part of the RUN failed, else null when one was not read, else true: a partial read never
    passes a RUN."""
    values = [parts[name] for name in names]
    if False in values:
        return False
    return None if None in values else True


def verdict(findings, reads, parts, covers, peaks=None, base_peaks=None):
    by_kind = {}
    for item in findings:
        by_kind[item["kind"]] = by_kind.get(item["kind"], 0) + 1
    return {
        "reads": reads,
        "findings": len(findings),
        "by_kind": by_kind,
        "parts": parts,
        "covers": sorted(covers),
        "missing": [name for name in RUN3_PARTS + RUN4_PARTS if name in covers and parts[name] is None],
        "run3_threads": run_verdict(parts, RUN3_PARTS),
        "run4_threads": run_verdict(parts, RUN4_PARTS),
        "daemon_peak_threads": max(peaks) if peaks else None,
        "daemon_peaks": peaks or None,
        "base_peak_threads": min(base_peaks) if base_peaks else None,
        "base_peaks": base_peaks or None,
    }


def exit_code(result):
    """2 when a part the run covers was not read, 1 when a finding is open, 0 when every covered part passed."""
    if result["missing"] or not result["covers"]:
        return 2
    return 1 if result["findings"] else 0


def markdown(findings, result, context):
    peak = result["daemon_peak_threads"]
    lines = [f"QoS audit, {context}: {result['findings']} findings "
             f"(RUN-3 threads {fmt_pass(result['run3_threads'])}, RUN-4 threads {fmt_pass(result['run4_threads'])}"
             + (f", daemon peaks {result['daemon_peaks']} threads" if peak else "")
             + (f", base {result['base_peaks']}" if result["base_peaks"] else "") + ").", "",
             "Parts: " + ", ".join(f"{name} {fmt_pass(value)}" for name, value in result["parts"].items()) + ".",
             "", "| Task | Process | Kind | Thread | Seen | Phases |", "|---|---|---|---|---|---|"]
    for item in findings:
        detail = item["detail"].replace("|", "/")
        lines.append(f"| `{task_id(item)}` | {item['process']} | {item['kind']} | `{item['name']}` | {detail} "
                     f"| {', '.join(item['phases'])} |")
    return "\n".join(lines) + "\n"


def fmt_pass(value):
    return "not read" if value is None else ("pass" if value else "fail")


def write_outputs(out, findings, result, context, grep=None):
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "qos-findings.json"), "w") as f:
        json.dump(findings, f, indent=1)
    with open(os.path.join(out, "qos-tasks.json"), "w") as f:
        json.dump(tasks_for(findings, grep), f, indent=1)
    with open(os.path.join(out, "qos-audit.md"), "w") as f:
        f.write(markdown(findings, result, context))
    with open(os.path.join(out, "qos-verdict.json"), "w") as f:
        json.dump(result, f, indent=1)
    print("QOS-AUDIT " + json.dumps(result), flush=True)


def as_samples(value, name):
    """One reply or a list of them, as a list; None stays None."""
    if value is None:
        return None
    samples = value if isinstance(value, list) else [value]
    if not samples:
        raise ReadError(f"{name}: no samples")
    return samples


def as_peaks(value):
    """Peaks as a list: a number, a list of numbers, or a qos-peak.json object (its `peaks`)."""
    if value is None:
        return None
    if isinstance(value, dict):
        value = value.get("peaks")
    peaks = value if isinstance(value, list) else [value]
    if not peaks or not all(isinstance(peak, int) and peak > 0 for peak in peaks):
        raise ReadError(f"peak thread counts are not positive integers: {value!r}")
    return peaks


def judge(app_visible=None, app_hidden=None, app_surfaces=None, app_daemon=None, app_daemon_os=None,
          daemon=None, daemon_os=None, daemon_phase="stress", automation_only=False, peaks=None, base_peaks=None,
          covers=None, doc_text=None):
    """Findings and verdict of saved replies. `app_daemon` is the app's daemon (its UI connection must be in
    it), `daemon` a headless one; both may be lists of samples, with the OS thread lists read next to them.
    `covers` is the parts the run covers; by default the parts the given inputs feed."""
    if doc_text is None:
        with open(DOC) as f:
            doc_text = f.read()
    closed = closed_list(doc_text)
    peaks, base_peaks = as_peaks(peaks), as_peaks(base_peaks)
    findings, reads, seen = [], [], set()
    census = surface_census(app_surfaces) if app_surfaces is not None else None
    if app_visible is not None:
        findings += app_findings(app_visible, "visible", closed, census)
        reads.append("app-visible")
    if census is not None:
        reads.append("app-surfaces")
    if app_hidden is not None:
        findings += app_findings(app_hidden, "hidden", closed)
        reads.append("app-hidden")
    for label, value, os_value in (("app-daemon", app_daemon, app_daemon_os), ("daemon", daemon, daemon_os)):
        samples = as_samples(value, label)
        if samples is None:
            continue
        os_samples = as_samples(os_value, f"{label} OS threads") or [{}] * len(samples)
        if len(os_samples) != len(samples):
            raise ReadError(f"{len(samples)} {label} server-threads samples but {len(os_samples)} OS thread lists")
        for snapshot, os_threads in zip(samples, os_samples):
            phase = snapshot.get("_phase", daemon_phase) if isinstance(snapshot, dict) else daemon_phase
            findings += daemon_findings(snapshot, os_threads or {}, phase, closed,
                                        automation_only and label == "daemon", seen)
        reads.append(label)
    if app_daemon is not None and "person" not in seen:
        findings.append(finding("daemon", "ui-connection", "unseen", "visible",
                                "no connection of the verified app (origin user) in the app daemon's "
                                "server-threads", None))
        seen.add("person")
    if peaks is not None and base_peaks is not None and max(peaks) >= min(base_peaks):
        findings.append(finding("daemon", "peak-threads", "process", "stress",
                                f"peaks {peaks} OS threads, base {base_peaks}: the highest is not below the "
                                f"base's lowest", None))
    failed = {part_of(item) for item in findings}
    judged = {
        "run3_visible": app_visible is not None,
        "run3_hidden_workspaces": app_visible is not None and census is not None,
        "run3_hidden": app_hidden is not None,
        "run4_daemon_threads": "app-daemon" in reads or "daemon" in reads,
        "run4_ui_connection": "person" in seen,
        "run4_automation": "automation" in seen,
        "run4_peak": peaks is not None and base_peaks is not None,
    }
    parts = {name: (name not in failed) if judged[name] else None for name in RUN3_PARTS + RUN4_PARTS}
    if covers is None:
        covers = set()
        if app_visible is not None or app_hidden is not None or app_surfaces is not None:
            covers |= set(RUN3_PARTS)
        if app_daemon is not None:
            covers |= {"run4_daemon_threads", "run4_ui_connection"}
        if daemon is not None:
            covers |= {"run4_daemon_threads", "run4_automation", "run4_peak"}
        if peaks is not None or base_peaks is not None:
            covers.add("run4_peak")
    findings = merge(findings)
    return findings, verdict(findings, reads, parts, set(covers), peaks, base_peaks)


# ----------------------------------------------------------------------------------------------------------------
# Reading a live daemon


def libproc():
    import ctypes  # noqa: E402 (macOS only)
    return ctypes, ctypes.CDLL("/usr/lib/libproc.dylib")


def thread_count(pid):
    """The OS thread count of `pid` now, None once it is gone: Linux the entries of /proc/<pid>/task, macOS one
    proc_pidinfo PROC_PIDLISTTHREADIDS call (8 bytes per thread id). Cheap enough to read every millisecond."""
    task_dir = f"/proc/{pid}/task"
    if os.path.isdir(task_dir):
        try:
            return len(os.listdir(task_dir))
        except OSError:
            return None
    if sys.platform == "darwin":
        ctypes, lib = libproc()
        ids = (ctypes.c_uint64 * 8192)()
        size = lib.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDLISTTHREADIDS), ctypes.c_uint64(0),
                                ctypes.byref(ids), ctypes.c_int(ctypes.sizeof(ids)))
        return size // 8 if size > 0 else None
    return None


class PeakSampler:
    """The highest OS thread count of a process while the `with` block runs, read by a thread of this script
    every `interval` seconds (default 1 ms): the threads a create or a close starts and ends between two reads
    of server-threads count too. A thread that lives shorter than the interval can still be missed; `samples`
    says how many reads were made."""

    def __init__(self, pid, interval=0.001, count=thread_count):
        self.pid, self.interval, self.count = pid, interval, count
        self.peak, self.samples = 0, 0
        self.started = None
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, name="qos-peak-sampler", daemon=True)

    def __enter__(self):
        self.started = time.monotonic()
        self.thread.start()
        return self

    def __exit__(self, *_exc):
        self.stop.set()
        self.thread.join()

    def run(self):
        while True:
            count = self.count(self.pid)
            if count is not None:
                self.peak = max(self.peak, count)
                self.samples += 1
            if self.stop.wait(self.interval):  # test script: the sampling interval, ended by stop
                return

    def summary(self):
        elapsed = time.monotonic() - self.started if self.started else 0.0
        return {"peak": self.peak, "samples": self.samples, "seconds": round(elapsed, 3),
                "mean_interval_ms": round(elapsed * 1000 / self.samples, 3) if self.samples else None}


def os_threads(pid):
    """The daemon's OS threads by the id `server-threads` reports (Linux tid, macOS pthread_threadid_np) with their
    names: Linux /proc/<pid>/task/<tid>/comm, macOS proc_pidinfo PROC_PIDLISTTHREADIDS / PROC_PIDTHREADID64INFO
    (perf-bench power_attribution.thread_cpu), read from outside so the read adds no thread to the daemon."""
    task_dir = f"/proc/{pid}/task"
    if os.path.isdir(task_dir):
        named = {}
        for tid in os.listdir(task_dir):
            try:
                with open(os.path.join(task_dir, tid, "comm")) as f:
                    named[int(tid)] = f.read().strip()
            except OSError:  # the thread exited while it was read
                continue
        return {"count": len(named), "threads": named, "platform": "linux"}
    if sys.platform == "darwin":
        sys.path.insert(0, os.path.join(REPO, "scripts", "perf-bench"))
        import power_attribution  # noqa: E402 (macOS only; loads libproc)
        named = {tid: name for tid, (_cpu, name) in power_attribution.thread_cpu(pid).items()}
        return {"count": len(named), "threads": named, "platform": "darwin"}
    out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout
    return {"count": max(0, len(out.strip().splitlines()) - 1), "threads": {}, "platform": sys.platform}


class DaemonConn:
    """One control connection (newline JSON, `{"id", "cmd", ...}`), as bench-lifecycle.py's."""

    def __init__(self, path, timeout=60):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def call(self, cmd, **params):
        rid = self.next_id
        self.next_id += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(1 << 22)
                if not chunk:
                    raise ConnectionError("control socket closed")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            msg = json.loads(line)
            if msg.get("id") == rid and "ok" in msg:
                return msg

    def must(self, cmd, **params):
        reply = self.call(cmd, **params)
        if not reply.get("ok"):
            raise ReadError(f"{cmd} failed: {reply.get('error')!r} {reply.get('error_code', '')}")
        data = reply.get("data") or {}
        if not isinstance(data, dict):
            raise ReadError(f"{cmd} gave {str(data)[:200]}")
        return data


def surfaces_of(tree):
    """(workspace id, pane id, surface ids) of each pane of a list-workspaces reply."""
    for workspace in tree.get("workspaces", []):
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                ids = [tab.get("surface") or tab.get("id") if isinstance(tab, dict) else tab
                       for tab in pane.get("tabs", [])]
                yield workspace["id"], pane["id"], ids


def field(reply, key, cmd):
    """`reply[key]`, a ReadError when the daemon's reply lacks it."""
    if key not in reply:
        raise ReadError(f"{cmd} gave no {key}: {str(reply)[:200]}")
    return reply[key]


def pane_and_workspace(conn, surface):
    for workspace, pane, ids in surfaces_of(conn.must("list-workspaces")):
        if surface in ids:
            return pane, workspace
    raise ReadError(f"surface {surface} is in no pane")


def build_daemon_stress(conn, workspaces=60, panes=14, busy=10):
    """The STRESS shape on a headless daemon: `workspaces - 1` one-terminal workspaces, then the measured one with
    `panes` panes of 2 terminals each (splits right, then down), the first `busy` printing a line every 20 ms."""
    sized = {"cols": 80, "rows": 24}
    for index in range(workspaces - 1):
        conn.must("new-workspace", name=f"bg{index}", **sized)
    measured = conn.must("new-workspace", name="measured", cols=200, rows=60)
    surface = field(measured, "surface", "new-workspace")
    pane_ids = [pane_and_workspace(conn, surface)[0]]
    for index in range(panes - 1):
        target = pane_ids[index // 2 % len(pane_ids)]
        made = conn.must("split", pane=target, dir="right" if index % 2 == 0 else "down", **sized)
        pane_ids.append(made.get("pane") or pane_and_workspace(conn, field(made, "surface", "split"))[0])
    terminals = [field(conn.must("new-tab", pane=pane, **sized), "surface", "new-tab") for pane in pane_ids]
    for terminal in terminals[:busy]:
        conn.must("send", surface=terminal, text="while :; do echo qos-audit; sleep 0.02; done\n")
    return {"workspaces": workspaces, "panes": len(pane_ids), "busy": min(busy, len(terminals))}


def lifecycle_round(conn, pane, index):
    """One round of perf-10x-lifecycle's op mix (cmux-tui/scripts/bench-lifecycle.py, in its order) on `pane`."""
    sized = {"cols": 80, "rows": 24}
    tab = conn.must("new-tab", pane=pane, **sized)
    conn.must("close-surface", surface=field(tab, "surface", "new-tab"))
    page = conn.must("new-browser-tab", url="about:blank", pane=pane, **sized)
    conn.must("close-surface", surface=field(page, "surface", "new-browser-tab"))
    for params in ({"dir": "right", **sized}, {"dir": "down", **sized}, {"dir": "right"}):
        made = conn.must("split", pane=pane, **params)
        target = made.get("pane") or pane_and_workspace(conn, field(made, "surface", "split"))[0]
        conn.must("close-pane", pane=target, end_terminals=True)
    workspace = conn.must("new-workspace", name=f"w{index}", **sized)
    _pane, ws = pane_and_workspace(conn, field(workspace, "surface", "new-workspace"))
    conn.must("close-workspace", workspace=ws, end_terminals=True)


def daemon_environment(opts, root):
    home = os.path.join(root, "home")
    os.makedirs(home)
    os.makedirs(os.path.join(root, "state"))
    env = dict(os.environ)
    env.update(HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
               XDG_STATE_HOME=os.path.join(home, ".local/state"), XDG_DATA_HOME=os.path.join(home, ".local/share"),
               XDG_CACHE_HOME=os.path.join(home, ".cache"), CMUX_TUI_CONFIG=os.path.join(root, "config.json"),
               SHELL="/bin/sh")
    # The blocking detector records instead of panicking (a Debug daemon's default): this audit reads QoS, and a
    # blocking site goes to the MQ-13 list in --out (cmux-tui/scripts/daemon-blocking-sweep.py groups it).
    env["CMUX_DAEMON_BLOCKING"] = "record"
    env["CMUX_DAEMON_BLOCKING_REPORT"] = os.path.abspath(opts.out)
    if opts.request_qos:
        listed = [item for item in env.get("CMUX_ENABLE_FEATURES", "").split(",") if item]
        env["CMUX_ENABLE_FEATURES"] = ",".join(listed + ["daemonRequestQos"])
    return env


def daemon_run(opts, run):
    """One daemon from start to stop: the STRESS build and the lifecycle rounds under one PeakSampler; the
    server-threads samples (none with --peak-only), their OS thread lists and the sampler's summary."""
    root = tempfile.mkdtemp(prefix="qos-")
    sock = os.path.join(root, "s.sock")
    env = daemon_environment(opts, root)
    log = open(os.path.join(opts.out, "daemon.log"), "a")
    daemon = subprocess.Popen([opts.bin, "--headless", "--session", f"qos{os.getpid()}r{run}", "--socket", sock,
                               "--state", os.path.join(root, "state")], stdout=log, stderr=subprocess.STDOUT, env=env,
                              start_new_session=True)
    samples, os_samples = [], []

    def sample(conn, phase):
        if opts.peak_only:
            return
        snapshot = conn.must("server-threads")
        snapshot["_phase"] = phase
        snapshot["_run"] = run
        samples.append(snapshot)
        os_samples.append(os_threads(daemon.pid))

    try:
        with PeakSampler(daemon.pid) as sampler:
            conn = wait_for_socket(daemon, sock)
            sample(conn, "idle")
            shape = build_daemon_stress(conn, opts.workspaces, opts.panes, opts.busy)
            print(f"QOS-DAEMON-STRESS run={run} " + json.dumps(shape), flush=True)
            rounds = DaemonConn(sock)
            base = conn.must("new-workspace", name="lifecycle", cols=120, rows=40)
            pane, _ws = pane_and_workspace(conn, field(base, "surface", "new-workspace"))
            total = opts.warmup + opts.rounds
            for index in range(total):
                lifecycle_round(rounds, pane, index)
                if index >= opts.warmup and (index - opts.warmup) % max(1, opts.rounds // opts.samples) == 0:
                    sample(conn, "stress")
        peak = sampler.summary()
        print(f"QOS-DAEMON-PEAK run={run} " + json.dumps(peak), flush=True)
        time.sleep(opts.settle)  # test script: let the lifecycle's one-shot threads end before the settled read
        sample(conn, "stress-settled")
        rounds.close()
        conn.close()
    finally:
        try:
            os.killpg(daemon.pid, signal.SIGTERM)
            daemon.wait(timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            try:
                os.killpg(daemon.pid, signal.SIGKILL)
            except OSError:
                pass
        log.close()
        shutil.rmtree(root, ignore_errors=True)
    return samples, os_samples, peak


def inherited_nice_problem(nice=None, linux=None):
    """Why a Linux daemon started from here would measure the wrong classes, or None: it inherits this process's
    nice, and an unprivileged Linux thread cannot lower its nice again (cmux-threads qos.rs), so every thread
    whose class is above that nice would read as a mismatch."""
    nice = os.nice(0) if nice is None else nice
    linux = sys.platform.startswith("linux") if linux is None else linux
    if linux and nice > 0:
        return f"this audit runs at nice {nice}, which the daemon inherits: run it at nice 0 (no `nice -n`)"
    return None


def run_daemon(opts):
    os.makedirs(opts.out, exist_ok=True)
    problem = inherited_nice_problem()
    if problem:
        raise ReadError(problem)
    base_peaks = load_peaks(opts.base_peak)
    if not opts.peak_only and base_peaks is None:
        raise ReadError("daemon mode needs --base-peak (the base binary's qos-peak.json): RUN-4's peak part")
    samples, os_samples, runs = [], [], []
    for run in range(opts.repeat):
        run_samples, run_os, peak = daemon_run(opts, run)
        samples += run_samples
        os_samples += run_os
        runs.append(peak)
    peaks = [run["peak"] for run in runs]
    peak_file = {"peaks": peaks, "daemon_peak_threads": max(peaks), "daemon_peak_threads_min": min(peaks),
                 "runs": runs, "rounds": opts.rounds, "warmup": opts.warmup, "host": platform.platform()}
    with open(os.path.join(opts.out, "qos-peak.json"), "w") as f:
        json.dump(peak_file, f, indent=1)
    print("QOS-AUDIT-PEAK " + json.dumps(peak_file), flush=True)
    if opts.peak_only:
        return 0
    for name, value in (("server-threads.json", samples), ("daemon-os-threads.json", os_samples)):
        with open(os.path.join(opts.out, name), "w") as f:
            json.dump(value, f, indent=1)
    findings, result = judge(daemon=samples, daemon_os=os_samples, automation_only=opts.request_qos, peaks=peaks,
                             base_peaks=base_peaks,
                             covers={"run4_daemon_threads", "run4_automation", "run4_peak"})
    result["host"] = platform.platform()
    write_outputs(opts.out, findings, result, f"daemon headless STRESS on {platform.system()}")
    return exit_code(result)


def load_peaks(value):
    """--peak / --base-peak: a number, or the path of a qos-peak.json."""
    if value is None:
        return None
    if re.fullmatch(r"\d+", value):
        return as_peaks(int(value))
    with open(value) as f:
        return as_peaks(json.load(f))


def wait_for_socket(daemon, sock, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded poll for the daemon's socket in a test script
        if daemon.poll() is not None:
            raise ReadError(f"the daemon exited {daemon.returncode}")
        if os.path.exists(sock):
            try:
                conn = DaemonConn(sock)
                conn.must("identify")
                return conn
            except OSError:
                pass
        time.sleep(0.1)  # test script: the poll interval
    raise ReadError("the daemon socket never appeared")


# ----------------------------------------------------------------------------------------------------------------
# Reading a live app


def load_module(file_name, module_name):
    spec = importlib.util.spec_from_file_location(module_name, os.path.join(HERE, file_name))
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, HERE)
    spec.loader.exec_module(module)
    return module


def read_reply(rpc, method, phase, key):
    reply = rpc(method, {}, timeout=30)
    if not isinstance(reply, dict) or reply.get("error") or key not in reply:
        raise ReadError(f"{method} ({phase}): {str(reply)[:300]}")
    return reply


def main_windows_shown(rpc):
    """True when every main window is visible and not minimized (`debug.window_list`, as bench_idle.py's
    main_window_shown), False when one is not, None when the build lists no main window."""
    reply = rpc("debug.window_list", {}, timeout=10)
    windows = reply.get("windows") if isinstance(reply, dict) else None
    mains = [w for w in windows or [] if isinstance(w, dict) and w.get("kind") == "main"]
    if not mains:
        return None
    return all(w.get("visible") is True and w.get("miniaturized") is False for w in mains)


def show_all(rpc, hidden):
    """Show/Hide All Windows from a script, as bench_idle.py's show_all."""
    return rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": hidden}, "focus": False,
                              "origin": "script"}, timeout=30)


def build_stress(stress, rpc):
    """The STRESS session; a build that fails (perf-stress-session's StressShapeError, a refused tab, a reply
    without a field) is a read that failed, not an open finding."""
    try:
        return stress.Stress(rpc).build()
    except (RuntimeError, KeyError, TypeError, ValueError) as error:
        raise ReadError(f"STRESS build: {type(error).__name__}: {error}") from error


def run_app(opts, stress=None):
    stress = stress or load_module("perf-stress-session.py", "perf_stress_session")
    os.makedirs(opts.out, exist_ok=True)
    app = None
    replies, surfaces, daemon_samples, daemon_os = {}, {}, [], []
    try:
        if opts.app:
            app = stress.load_activation_app()(os.path.abspath(opts.app), opts.out, 50)
            app.launch()
            rpc = app.rpc
        else:
            rpc = stress.socket_rpc(opts.socket)
        if opts.stress:
            summary = build_stress(stress, rpc)
            print("STRESS-SESSION " + json.dumps(summary), flush=True)
        daemon_conn = DaemonConn(opts.daemon_socket) if opts.daemon_socket else None
        daemon_pid = (rpc("debug.daemon", {}, timeout=10) or {}).get("pid")

        def read_phase(phase):
            time.sleep(opts.settle)  # test script: let the phase's QoS changes land before the read
            # A phase whose windows are not as named measured another phase: no verdict from it.
            shown = main_windows_shown(rpc)
            if shown is not (phase == "visible"):
                raise ReadError(f"{phase} phase: main windows shown = {shown} (debug.window_list)")
            replies[phase] = read_reply(rpc, "debug.threads", phase, "threads")
            surfaces[phase] = read_reply(rpc, "debug.surfaces", phase, "windows")
            if daemon_conn:
                snapshot = daemon_conn.must("server-threads")
                snapshot["_phase"] = phase
                daemon_samples.append(snapshot)
                daemon_os.append(os_threads(int(daemon_pid)) if daemon_pid else {})

        read_phase("visible")
        hide = show_all(rpc, True)
        if isinstance(hide, dict) and hide.get("error"):
            raise ReadError(f"hide the app: {hide['error']}")
        try:
            read_phase("hidden")
        finally:
            show_all(rpc, False)
        if daemon_conn:
            daemon_conn.close()
    finally:
        if app:
            app.stop()
    for phase, reply in replies.items():
        with open(os.path.join(opts.out, f"debug-threads-{phase}.json"), "w") as f:
            json.dump(reply, f, indent=1)
    for phase, reply in surfaces.items():
        with open(os.path.join(opts.out, f"debug-surfaces-{phase}.json"), "w") as f:
            json.dump(reply, f, indent=1)
    if daemon_samples:
        with open(os.path.join(opts.out, "app-daemon-server-threads.json"), "w") as f:
            json.dump(daemon_samples, f, indent=1)
        with open(os.path.join(opts.out, "app-daemon-os-threads.json"), "w") as f:
            json.dump(daemon_os, f, indent=1)
    covers = set(RUN3_PARTS) | ({"run4_daemon_threads", "run4_ui_connection"} if opts.daemon_socket else set())
    findings, result = judge(app_visible=replies.get("visible"), app_hidden=replies.get("hidden"),
                             app_surfaces=surfaces.get("visible"), app_daemon=daemon_samples or None,
                             app_daemon_os=daemon_os or None, covers=covers)
    result["host"] = platform.platform()
    write_outputs(opts.out, findings, result, "app STRESS, window visible and hidden")
    return exit_code(result)


def run_judge(opts):
    def load(path):
        if not path:
            return None
        with open(path) as f:
            return json.load(f)
    findings, result = judge(app_visible=load(opts.app_visible), app_hidden=load(opts.app_hidden),
                             app_surfaces=load(opts.app_surfaces), app_daemon=load(opts.app_daemon),
                             app_daemon_os=load(opts.app_daemon_os), daemon=load(opts.daemon),
                             daemon_os=load(opts.daemon_os), automation_only=opts.automation_only,
                             peaks=load_peaks(opts.peak), base_peaks=load_peaks(opts.base_peak))
    write_outputs(opts.out, findings, result, opts.context)
    return exit_code(result)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    modes = parser.add_subparsers(dest="mode", required=True)
    app = modes.add_parser("app", help="debug.threads of a tagged app in STRESS, visible and hidden")
    where = app.add_mutually_exclusive_group(required=True)
    where.add_argument("--app", help="a Debug `cmux DEV <tag>.app` to launch (not running)")
    where.add_argument("--socket", help="the debug socket of a running tagged app")
    app.add_argument("--daemon-socket", help="the app daemon's control socket: also read server-threads")
    app.add_argument("--no-stress", dest="stress", action="store_false", help="measure the session the app has")
    daemon = modes.add_parser("daemon", help="server-threads of a headless daemon under lifecycle STRESS")
    daemon.add_argument("--bin", required=True, help="the cmux-tui binary")
    daemon.add_argument("--workspaces", type=int, default=60)
    daemon.add_argument("--panes", type=int, default=14)
    daemon.add_argument("--busy", type=int, default=10)
    daemon.add_argument("--rounds", type=int, default=40, help="lifecycle rounds (perf-10x-lifecycle's default)")
    daemon.add_argument("--warmup", type=int, default=3, help="rounds before the measured ones (bench-lifecycle's)")
    daemon.add_argument("--repeat", type=int, default=3, help="whole runs, each with a new daemon")
    daemon.add_argument("--samples", type=int, default=8, help="server-threads reads during the rounds")
    daemon.add_argument("--base-peak", help="the base binary's qos-peak.json (or its lowest peak)")
    daemon.add_argument("--peak-only", action="store_true",
                        help="read no server-threads, only the peaks (a base binary without it)")
    daemon.add_argument("--no-request-qos", dest="request_qos", action="store_false",
                        help="leave the daemonRequestQos feature off (connection threads then keep their "
                             "declared class, so automation-class findings show what the feature changes)")
    judge_mode = modes.add_parser("judge", help="judge saved replies")
    judge_mode.add_argument("--app-visible")
    judge_mode.add_argument("--app-hidden")
    judge_mode.add_argument("--app-surfaces", help="debug.surfaces of the visible phase")
    judge_mode.add_argument("--app-daemon", help="the app daemon's server-threads samples (app mode's)")
    judge_mode.add_argument("--app-daemon-os", help="the OS thread lists saved next to --app-daemon")
    judge_mode.add_argument("--daemon", help="a headless daemon's server-threads (one reply or a list of samples)")
    judge_mode.add_argument("--daemon-os", help="the OS thread list(s) saved next to --daemon")
    judge_mode.add_argument("--automation-only", action="store_true")
    judge_mode.add_argument("--peak", help="the head's qos-peak.json (or its highest peak)")
    judge_mode.add_argument("--base-peak", help="the base's qos-peak.json (or its lowest peak)")
    judge_mode.add_argument("--context", default="saved replies")
    for sub in (app, daemon, judge_mode):
        sub.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="qos-audit-"))
    for sub in (app, daemon):
        sub.add_argument("--settle", type=float, default=5.0, help="seconds before a phase's read")
    opts = parser.parse_args(argv)
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    try:
        return {"app": run_app, "daemon": run_daemon, "judge": run_judge}[opts.mode](opts)
    except (ReadError, OSError, ConnectionError, ValueError) as error:
        print(f"QOS-AUDIT-ERROR {error}", file=sys.stderr, flush=True)
        return 2


if __name__ == "__main__":
    sys.exit(main())
