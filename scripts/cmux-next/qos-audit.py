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
           `debug.threads` with the window visible, hides the app (action showHideAllWindows), settles, reads
           it hidden, then shows the app again. --daemon-socket also reads the app's daemon `server-threads`
           in both phases (the app's UI connections are classed there: RUN-4's user-interactive echo threads).
             nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
               python3 scripts/cmux-next/qos-audit.py app --app "$NX_APP" --out "$NX_ARTIFACTS/qos"
  daemon   A headless cmux-tui (--bin) with a STRESS-shaped session (60 workspaces; the measured one 14 panes
           of 2 terminals; 10 terminals printing), lifecycle rounds (bench-lifecycle.py's create/close mix, every
           close ending its terminals) on
           a second connection while `server-threads` and the process's OS threads are sampled; the peak OS
           thread count is recorded (RUN-4) and compared with --base-peak (a run of the base commit's binary).
           --peak-only reads only the peak (for the base binary, which may predate server-threads).
           CMUX_ENABLE_FEATURES=daemonRequestQos is set unless --no-request-qos: RUN-4's classes are that
           feature's. Each unregistered OS thread is named by its id (Linux /proc, macOS proc_pidinfo).
             python3 scripts/cmux-next/qos-audit.py daemon --bin target/debug/cmux-tui --out DIR
  judge    Judges saved replies: --app-visible, --app-hidden (debug.threads JSON), --daemon (server-threads
           JSON), --daemon-os (the OS thread list this script saves), --base-peak.

Every mode writes into --out: the raw replies, `qos-findings.json` (each finding with its evidence rows),
`qos-tasks.json` (one task per finding, id `p02-threads-R-qos-<process>-<kind>-<name>`, stable across reruns:
a fixed thread never gives its id to other work), `qos-audit.md` (the table for threading-model.md "QoS audit
(MQ-15)") and prints one `QOS-AUDIT {json}` verdict line. Exit 0 when RUN-3 and RUN-4's thread parts pass,
1 when a finding is open, 2 when a read failed. Findings:

  mismatch           a declared thread whose requested QoS (the kernel's, overrides excluded) is not one its row
                     allows (app `match` false; daemon `matches` false: kernel class or Linux nice is not the
                     desired class)
  hidden-tier        hidden phase: a thread whose row has a hidden tier (Ghostty surface threads: utility) asks
                     for another
  undeclared-cmux    an app thread with a cmux name and no row (`undeclared_cmux`)
  undeclared-library an app thread in a linked library's name space with no row (`undeclared_library`)
  unregistered       a daemon OS thread no `server-threads` row names (by thread id, Linux and macOS)
  interactive-outside-closed-list
                     a cmux thread at user-interactive whose name is not in threading-model.md's "Closed
                     user-interactive list"
  automation-class   daemon mode: a connection thread (mux-conn, mux-control-dispatch) of the script's
                     automation connections that does not rest at utility (needs daemonRequestQos)
  queue-problem      a checked queue whose QoS or target differs from its row; undeclared-queue: a checked
                     queue no row declares; queue-log-overflow: queues the log could not record
  task-role          the process task role was not read (macOS)
  peak-threads       the daemon's peak OS thread count is not below --base-peak

The fixed RUN-3 (b) queue literals are the static half (threading-inventory.py); this audit reads only what
runs. Requires nothing outside the standard library.
"""
import argparse, importlib.util, json, os, platform, re, shutil, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DOC = os.path.join(REPO, "plans", "cmux-next", "threading-model.md")
TASK_PREFIX = "p02-threads-R-qos"
INTERACTIVE = "user-interactive"
UTILITY = "utility"
# The daemon's per-connection request threads (server/listen.rs, server/connection_scheduler.rs): they rest at the
# connection's class under daemonRequestQos (server/connection_qos.rs).
CONNECTION_THREADS = ("mux-conn", "mux-control-dispatch")
# Source roots searched for a thread's spawn site, by process.
SOURCE_ROOTS = {"app": ["Packages/macOS", "Packages/Shared"], "daemon": ["cmux-tui/crates"]}
SOURCE_SUFFIX = {"app": ".swift", "daemon": ".rs"}
REGISTRY_FILES = {"app": ["Packages/macOS/CmuxNext/Sources/CmuxNextCompat/Threading/ThreadRegistry+App.swift"],
                  "daemon": []}
DOC_REL = "plans/cmux-next/threading-model.md"


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


def app_findings(report, phase, closed):
    """The findings of one `debug.threads` reply (ThreadsControl.report), `phase` visible or hidden."""
    if not isinstance(report, dict) or "threads" not in report:
        raise ReadError(f"debug.threads ({phase}) gave no threads: {str(report)[:300]}")
    found = []
    for row in report["threads"]:
        name = generic_name(row.get("declared_as") or row.get("name") or row.get("label") or "")
        thread = {key: row.get(key) for key in ("tid", "name", "label", "requested_qos", "effective_pri",
                                                 "declared", "declared_tiers", "declared_hidden", "declared_as",
                                                 "origin", "library")}
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


def daemon_findings(snapshot, os_threads, phase, closed, automation_only=False):
    """The findings of one `server-threads` reply and the daemon's OS threads read next to it.

    `os_threads`: {"count": n, "threads": {tid: comm}} (threads empty when the OS does not name them).
    `automation_only`: every connection is an automation client's, so each connection thread rests at utility."""
    if not isinstance(snapshot, dict) or "threads" not in snapshot:
        raise ReadError(f"server-threads ({phase}) gave no threads: {str(snapshot)[:300]}")
    found = []
    rows = snapshot["threads"]
    for row in rows:
        name = generic_name(row.get("name"))
        evidence = {key: row.get(key) for key in ("name", "tid", "declared", "desired", "effective",
                                                   "requested_qos", "nice", "priority", "refused_changes")}
        if row.get("matches") is False:
            found.append(finding("daemon", "mismatch", name, phase,
                                 f"desired {row.get('desired')}, applied {row.get('effective')}, "
                                 f"kernel {daemon_row_qos(row)}", evidence))
        interactive = INTERACTIVE in (row.get("desired"), row.get("requested_qos"))
        if interactive and not on_closed_list([row.get("name")], closed):
            found.append(finding("daemon", "interactive-outside-closed-list", name, phase,
                                 "a daemon thread at user-interactive not in the closed list", evidence))
        if automation_only and row.get("name") in CONNECTION_THREADS and row.get("desired") != UTILITY:
            found.append(finding("daemon", "automation-class", name, phase,
                                 f"an automation connection's thread rests at {row.get('desired')}", evidence))
    registered = {row.get("tid") for row in rows if row.get("tid") is not None}
    named = os_threads.get("threads") or {}
    pid = (snapshot.get("process") or {}).get("pid")
    if named:
        # A thread that never names itself carries its process's name (the main thread's).
        process_name = next((comm for tid, comm in named.items() if int(tid) == pid), None)
        for tid, comm in sorted(named.items(), key=lambda item: int(item[0])):
            if int(tid) not in registered:
                if int(tid) == pid:
                    name = "main"
                elif comm == process_name or not comm:
                    name = "unnamed"
                else:
                    name = generic_name(comm)
                found.append(finding("daemon", "unregistered", name, phase,
                                     "an OS thread no server-threads row names", {"tid": int(tid), "comm": comm}))
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
    if name in ("main", "unnamed"):
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
    "undeclared-cmux": "Add the thread's row to threading-model.md and the thread registry, with its QoS.",
    "undeclared-library": "Add a 'declared by library' row for the thread to threading-model.md and the registry.",
    "unregistered": "Start the thread through cmux_threads::spawn (or the tokio builder) so server-threads lists it; "
                    "`main` is the process's first thread (register it at entry), `unnamed` a thread that never set "
                    "its name (find it by its stack).",
    "interactive-outside-closed-list": "Lower the thread below user-interactive, or add it to the closed list "
                                       "with the frame or echo that waits on it.",
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


def verdict(findings, reads, peak=None, base_peak=None):
    by_kind = {}
    for item in findings:
        by_kind[item["kind"]] = by_kind.get(item["kind"], 0) + 1
    app = [f for f in findings if f["process"] == "app"]
    daemon = [f for f in findings if f["process"] == "daemon"]
    return {
        "reads": reads,
        "findings": len(findings),
        "by_kind": by_kind,
        "run3_threads": None if "app-visible" not in reads else not app,
        "run4_threads": None if "daemon" not in reads else not daemon,
        "daemon_peak_threads": peak,
        "base_peak_threads": base_peak,
    }


def markdown(findings, result, context):
    lines = [f"QoS audit, {context}: {result['findings']} findings "
             f"(RUN-3 threads {fmt_pass(result['run3_threads'])}, RUN-4 threads {fmt_pass(result['run4_threads'])}"
             + (f", daemon peak {result['daemon_peak_threads']} threads" if result["daemon_peak_threads"] else "")
             + (f", base {result['base_peak_threads']}" if result["base_peak_threads"] else "") + ").", "",
             "| Task | Process | Kind | Thread | Seen | Phases |", "|---|---|---|---|---|---|"]
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


def judge(app_visible=None, app_hidden=None, daemon=None, daemon_os=None, daemon_phase="stress",
          automation_only=False, peak=None, base_peak=None, doc_text=None):
    """Findings and verdict of saved replies; `daemon` and `daemon_os` may be lists of samples."""
    if doc_text is None:
        with open(DOC) as f:
            doc_text = f.read()
    closed = closed_list(doc_text)
    findings, reads = [], []
    if app_visible is not None:
        findings += app_findings(app_visible, "visible", closed)
        reads.append("app-visible")
    if app_hidden is not None:
        findings += app_findings(app_hidden, "hidden", closed)
        reads.append("app-hidden")
    if daemon is not None:
        samples = daemon if isinstance(daemon, list) else [daemon]
        os_samples = daemon_os if isinstance(daemon_os, list) else [daemon_os or {}] * len(samples)
        if len(os_samples) != len(samples):
            raise ReadError(f"{len(samples)} server-threads samples but {len(os_samples)} OS thread lists")
        for snapshot, os_threads in zip(samples, os_samples):
            phase = snapshot.get("_phase", daemon_phase) if isinstance(snapshot, dict) else daemon_phase
            findings += daemon_findings(snapshot, os_threads or {}, phase, closed, automation_only)
        reads.append("daemon")
    if peak is not None and base_peak is not None and peak >= base_peak:
        findings.append(finding("daemon", "peak-threads", "process", "stress",
                                f"peak {peak} OS threads, base {base_peak}", None))
    findings = merge(findings)
    return findings, verdict(findings, reads, peak, base_peak)


# ----------------------------------------------------------------------------------------------------------------
# Reading a live daemon


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
        return {"count": len(named), "threads": named}
    if sys.platform == "darwin":
        sys.path.insert(0, os.path.join(REPO, "scripts", "perf-bench"))
        import power_attribution  # noqa: E402 (macOS only; loads libproc)
        named = {tid: name for tid, (_cpu, name) in power_attribution.thread_cpu(pid).items()}
        return {"count": len(named), "threads": named}
    out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout
    return {"count": max(0, len(out.strip().splitlines()) - 1), "threads": {}}


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
        return reply.get("data") or {}


def surfaces_of(tree):
    """(workspace id, pane id, surface ids) of each pane of a list-workspaces reply."""
    for workspace in tree.get("workspaces", []):
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                ids = [tab.get("surface") or tab.get("id") if isinstance(tab, dict) else tab
                       for tab in pane.get("tabs", [])]
                yield workspace["id"], pane["id"], ids


def build_daemon_stress(conn, workspaces=60, panes=14, busy=10):
    """The STRESS shape on a headless daemon: `workspaces - 1` one-terminal workspaces, then the measured one with
    `panes` panes of 2 terminals each (splits right, then down), the first `busy` printing a line every 20 ms."""
    sized = {"cols": 80, "rows": 24}
    for index in range(workspaces - 1):
        conn.must("new-workspace", name=f"bg{index}", **sized)
    measured = conn.must("new-workspace", name="measured", cols=200, rows=60)
    surface = measured["surface"]
    pane_ids = None
    for index in range(panes - 1):
        tree = conn.must("list-workspaces")
        pane_ids = [pane for _ws, pane, ids in surfaces_of(tree) if surface in ids] if pane_ids is None else pane_ids
        target = pane_ids[index // 2 % len(pane_ids)]
        made = conn.must("split", pane=target, dir="right" if index % 2 == 0 else "down", **sized)
        pane_ids.append(made.get("pane") or next(p for _w, p, ids in surfaces_of(conn.must("list-workspaces"))
                                                 if made["surface"] in ids))
    terminals = []
    for pane in pane_ids or []:
        tab = conn.must("new-tab", pane=pane, **sized)
        terminals.append(tab["surface"])
    for terminal in terminals[:busy]:
        conn.must("send", surface=terminal, text="while :; do echo qos-audit; sleep 0.02; done\n")
    return {"workspaces": workspaces, "panes": len(pane_ids or []), "busy": min(busy, len(terminals))}


def lifecycle_round(conn, pane):
    """One round of bench-lifecycle.py's create/close mix on `pane`, each close ending its terminals
    (`close-surface` keeps a terminal running, so the session would grow by one terminal per round)."""
    sized = {"cols": 80, "rows": 24}
    tab = conn.must("new-tab", pane=pane, **sized)
    conn.must("close-tabs", surfaces=[tab["surface"]], end_terminals=True)
    for direction in ("right", "down"):
        made = conn.must("split", pane=pane, dir=direction, **sized)
        target = made.get("pane") or next(p for _w, p, ids in surfaces_of(conn.must("list-workspaces"))
                                          if made["surface"] in ids)
        conn.must("close-pane", pane=target, end_terminals=True)
    workspace = conn.must("new-workspace", name="round", **sized)
    ws = next(w for w, _p, ids in surfaces_of(conn.must("list-workspaces")) if workspace["surface"] in ids)
    conn.must("close-workspace", workspace=ws, end_terminals=True)


def run_daemon(opts):
    root = tempfile.mkdtemp(prefix="qos-")
    sock = os.path.join(root, "s.sock")
    home = os.path.join(root, "home")
    state = os.path.join(root, "state")
    os.makedirs(home)
    os.makedirs(state)
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
    os.makedirs(opts.out, exist_ok=True)
    log = open(os.path.join(opts.out, "daemon.log"), "a")
    daemon = subprocess.Popen([opts.bin, "--headless", "--session", f"qos{os.getpid()}", "--socket", sock,
                               "--state", state], stdout=log, stderr=subprocess.STDOUT, env=env,
                              start_new_session=True)
    samples, os_samples, peak = [], [], 0

    def sample(conn, phase):
        if opts.peak_only:
            return
        snapshot = conn.must("server-threads")
        snapshot["_phase"] = phase
        samples.append(snapshot)
        os_samples.append(os_threads(daemon.pid))

    try:
        conn = wait_for_socket(daemon, sock)
        sample(conn, "idle")
        shape = build_daemon_stress(conn, opts.workspaces, opts.panes, opts.busy)
        print("QOS-DAEMON-STRESS " + json.dumps(shape), flush=True)
        rounds = DaemonConn(sock)
        base = conn.must("new-workspace", name="lifecycle", cols=120, rows=40)
        pane = next(p for _w, p, ids in surfaces_of(conn.must("list-workspaces")) if base["surface"] in ids)
        peak = os_threads(daemon.pid)["count"]
        for index in range(opts.rounds):
            lifecycle_round(rounds, pane)
            if index % max(1, opts.rounds // opts.samples) == 0:
                sample(conn, "stress")
            peak = max(peak, os_threads(daemon.pid)["count"])
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
    if opts.peak_only:
        result = {"daemon_peak_threads": peak, "host": platform.platform()}
        with open(os.path.join(opts.out, "qos-peak.json"), "w") as f:
            json.dump(result, f, indent=1)
        print("QOS-AUDIT-PEAK " + json.dumps(result), flush=True)
        return 0
    for name, value in (("server-threads.json", samples), ("daemon-os-threads.json", os_samples)):
        with open(os.path.join(opts.out, name), "w") as f:
            json.dump(value, f, indent=1)
    findings, result = judge(daemon=samples, daemon_os=os_samples, automation_only=opts.request_qos, peak=peak,
                             base_peak=opts.base_peak)
    result["host"] = platform.platform()
    write_outputs(opts.out, findings, result, f"daemon headless STRESS on {platform.system()}")
    return 1 if findings else 0


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


def read_threads(rpc, phase):
    reply = rpc("debug.threads", {}, timeout=30)
    if not isinstance(reply, dict) or reply.get("error") or "threads" not in reply:
        raise ReadError(f"debug.threads ({phase}): {str(reply)[:300]}")
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


def run_app(opts):
    stress = load_module("perf-stress-session.py", "perf_stress_session")
    os.makedirs(opts.out, exist_ok=True)
    app = None
    try:
        if opts.app:
            app = stress.load_activation_app()(os.path.abspath(opts.app), opts.out, 50)
            app.launch()
            rpc = app.rpc
        else:
            rpc = stress.socket_rpc(opts.socket)
        if opts.stress:
            summary = stress.Stress(rpc).build()
            print("STRESS-SESSION " + json.dumps(summary), flush=True)
        daemon_conn = DaemonConn(opts.daemon_socket) if opts.daemon_socket else None
        daemon_pid = (rpc("debug.daemon", {}, timeout=10) or {}).get("pid")
        replies, daemon_samples, daemon_os = {}, [], []

        def read_phase(phase):
            time.sleep(opts.settle)  # test script: let the phase's QoS changes land before the read
            # A phase whose windows are not as named measured another phase: no verdict from it.
            shown = main_windows_shown(rpc)
            if shown is not (phase == "visible"):
                raise ReadError(f"{phase} phase: main windows shown = {shown} (debug.window_list)")
            replies[phase] = read_threads(rpc, phase)
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
    if daemon_samples:
        with open(os.path.join(opts.out, "server-threads.json"), "w") as f:
            json.dump(daemon_samples, f, indent=1)
        with open(os.path.join(opts.out, "daemon-os-threads.json"), "w") as f:
            json.dump(daemon_os, f, indent=1)
    findings, result = judge(app_visible=replies.get("visible"), app_hidden=replies.get("hidden"),
                             daemon=daemon_samples or None, daemon_os=daemon_os or None)
    result["host"] = platform.platform()
    write_outputs(opts.out, findings, result, "app STRESS, window visible and hidden")
    return 1 if findings else 0


def run_judge(opts):
    def load(path):
        if not path:
            return None
        with open(path) as f:
            return json.load(f)
    findings, result = judge(app_visible=load(opts.app_visible), app_hidden=load(opts.app_hidden),
                             daemon=load(opts.daemon), daemon_os=load(opts.daemon_os),
                             automation_only=opts.automation_only, peak=opts.peak, base_peak=opts.base_peak)
    write_outputs(opts.out, findings, result, opts.context)
    return 1 if findings else 0


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
    daemon.add_argument("--rounds", type=int, default=40)
    daemon.add_argument("--samples", type=int, default=8, help="server-threads reads during the rounds")
    daemon.add_argument("--base-peak", type=int, help="the base binary's peak OS thread count")
    daemon.add_argument("--peak-only", action="store_true",
                        help="read no server-threads, only the peak OS thread count (a base binary without it)")
    daemon.add_argument("--no-request-qos", dest="request_qos", action="store_false",
                        help="leave the daemonRequestQos feature off (no automation-class check)")
    judge_mode = modes.add_parser("judge", help="judge saved replies")
    judge_mode.add_argument("--app-visible")
    judge_mode.add_argument("--app-hidden")
    judge_mode.add_argument("--daemon", help="server-threads JSON (one reply or a list of samples)")
    judge_mode.add_argument("--daemon-os", help="the OS thread list(s) saved next to --daemon")
    judge_mode.add_argument("--automation-only", action="store_true")
    judge_mode.add_argument("--peak", type=int)
    judge_mode.add_argument("--base-peak", type=int)
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
