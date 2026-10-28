#!/usr/bin/env python3
"""Leak harness: closing or deleting anything returns the app to its resource baseline (cleanup.md, Lawrence
2026-10-28: "make sure we clean up resources as well when we delete stuff"). Run it yourself on a fleet Mac; it is
no CI job and no CI gate.

For each kind (terminal, tab, pane, screen, workspace, window, chromium, webkit, page, chat, profile, chief, ssh) and
each N in --counts (default 1,50,500) it:
  1. settles and samples the BASELINE;
  2. creates N items of the kind through the same actions a person or a script uses (action.run, origin script), and
     USES each one: a terminal runs `sleep <marker> &` (a background job in its own process group) and, for the first
     --servers of them, a TCP listener on a free port (a dev server); a browser tab loads a local page; a chat opens on
     the mock agent; a profile opens a tab in its own profile;
  3. samples the PEAK, closes every item through its own close action (closeTab, closePane, screen.close,
     closeWorkspace, closeWindow, browserProfile.delete, home.deleteChief), waits up to --settle seconds for the
     process count to return, then --quiet more seconds, and samples AFTER;
  4. compares AFTER with BASELINE against the stated tolerances (TOLERANCES below) and prints one LEAK line per
     resource that grew past its tolerance.
Then `--churn N` presses Cmd-T then Cmd-W N times at key-repeat speed (--churn-interval, default 33 ms: the macOS
fastest key repeat) through debug.key, and compares again.

What a sample reads (all from outside the app, plus its debug.* endpoints):
  processes   every process of the tag (TagTeardown's rule: the bundle, its daemons' hosts and holders, their
              direct children), counted per kind (bench_memory.kind_of), plus the ORPHANS: any process whose
              command line carries this run's marker (a background job or server a closed terminal left behind; once
              its shell exits it is re-parented to launchd, so lineage alone misses it), plus ZOMBIES (state Z) whose
              parent is a tag process;
  fds         open descriptors per process (proc_pidinfo PROC_PIDLISTFDS), summed per kind;
  threads     per process (proc_taskinfo.pti_threadnum), summed per kind;
  memory      resident size and physical footprint per process (proc_pid_rusage), summed per kind;
  gpu         the app's IOSurface region count and bytes (vmmap -summary), debug.memory's terminal surfaces and
              hidden non-volatile IOSurface bytes; with --vmmap also the dirty bytes of "App-Specific Tag 14"
              (VM tag 253, VM_MEMORY_APPLICATION_SPECIFIC_1 + 13: Chromium's PartitionAlloc PageTag, which owns the
              app's malloc while CEF runs in-process; base/allocator/partition_allocator/.../page_allocator_constants.h);
  app model   debug.memory's tabs, workspaces and consumers; debug.observations' armed observations;
              snapshot.get's workspaces, screens, panes and tabs;
  daemon      its terminal hosts and holders (in processes), and the files and bytes of the tag's state folder
              (~/Library/Application Support/cmux/tags/<tag>), its acpmux home and the per-user temp folder's
              cmux files.
Live Swift objects of the main types are checked by the weak-reference tests of each owner (Tests/*/...Release*), not
here: the app's malloc is PartitionAlloc's, which `heap` cannot walk.

--resource-bench runs the resource-minimum bench instead (resource-minimum.md): 1, 10 and 100 terminals idle hidden
(tabs of a workspace that is not shown), idle visible (panes of shown windows, 12 per window) and busy (hidden, each
printing 50 lines a second), and samples footprint, threads, processes, CPU and wakeups over --measure seconds, and
disk, per state.

Output: LEAK-HARNESS-ROW lines (one per kind, N and resource: baseline, peak, after, growth, tolerance, verdict),
LEAK lines for each failure, RESOURCE-ROW lines for the bench, and the JSON report (--out DIR/leak-harness.json).
With --story ID it also writes result-v1 (BenchApp.record) for the perf-lab story. Exit 0 when nothing leaked, 1 on a
leak, 2 when the harness could not run (no GUI session, the app did not launch).

Run on the fleet (an exclusive measure step: it launches an app):
  scripts/measure/split-spring.sh --suite=leak [--config=<artifact sha256 on a scratch ref>] -- --counts 1,50,500
or on a host that runs the app already: leak-harness.py --app PATH [--counts 1,50] [--kinds terminal,workspace]
"""
import argparse, ctypes, json, os, re, shutil, socket, subprocess, sys, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

KINDS = ("terminal", "tab", "pane", "screen", "workspace", "window", "chromium", "webkit", "page", "chat", "profile",
         "chief", "ssh")
# Kinds whose N is bounded by what one window can hold or what one fleet step can make in its time; the row says so.
CAPS = {"pane": 64, "window": 50, "screen": 100, "profile": 50, "chief": 20}

# Tolerances of AFTER against BASELINE (cleanup.md: the app returns to its baseline; the exceptions are the bounded
# reopen history and caches with an explicit budget). `fixed` is allowed for any N (allocator high-water, a spare
# renderer, a lazily made pool), `per_item` scales with N (a closed-history entry per item, bounded by the history's
# own cap). A growth beyond fixed + per_item * N is a LEAK.
TOLERANCES = {
    "orphans": (0, 0),                     # processes that carry this run's marker: none may outlive the close
    "zombies": (0, 0),
    "processes.app": (0, 0),
    "processes.terminal": (0, 0),          # terminal hosts, holders and their shells
    "processes.helpers": (2, 0),           # Chromium and WebKit helpers: the spare renderer and the GPU process
    "processes.daemon": (0, 0),
    "fds.app": (32, 0.05),
    "fds.daemon": (16, 0.02),
    "threads.app": (8, 0),
    "threads.daemon": (4, 0),
    "footprint_mb.app": (48, 0.064),       # 48 MB + 64 KB per item: the closed history and allocator slack
    "footprint_mb.daemon": (16, 0.032),
    "footprint_mb.helpers": (64, 0),
    "iosurfaces.app": (8, 0),
    "terminal_surfaces": (0, 0),
    "observations_armed": (8, 0),
    "model.tabs": (0, 0),
    "model.panes": (0, 0),
    "model.screens": (0, 0),
    "model.workspaces": (0, 0),
    "model.windows": (0, 0),
    "disk_mb.state": (1, 0.004),           # journal and closed-history rows: 4 KB per item
    "disk_files.tmp": (0, 0),
}

MB = 1048576.0


def now():
    return time.monotonic()


# ---------------------------------------------------------------- pure parts (self-test runs them on any OS)

def tolerance(resource, count):
    fixed, per_item = TOLERANCES.get(resource, (0, 0))
    return fixed + per_item * count


def compare(baseline, after, count):
    """[(resource, before, after, growth, allowed, ok)] over the resources both samples have."""
    rows = []
    for resource in TOLERANCES:
        before, end = baseline.get(resource), after.get(resource)
        if before is None or end is None:
            continue
        growth = round(end - before, 3)
        allowed = round(tolerance(resource, count), 3)
        rows.append((resource, before, end, growth, allowed, growth <= allowed))
    return rows


def group_of(kind):
    """The resource group of a bench_memory process kind: the app, its daemons (cmux-tui, acpmux), its web helpers
    (Chromium and WebKit), or a terminal's processes (hosts, holders, login, shells and their children)."""
    if kind == "app":
        return "app"
    if kind.startswith("tui-daemon") or kind.startswith("acpmux"):
        return "daemon"
    if kind.startswith("cef-") or kind.startswith("webkit-") or "Helper" in kind:
        return "helpers"
    return "terminal"


def flatten(sample):
    """The resources TOLERANCES names, from a sample."""
    flat = {"orphans": len(sample.get("orphans") or []), "zombies": len(sample.get("zombies") or [])}
    for group, entry in (sample.get("groups") or {}).items():
        flat[f"processes.{group}"] = entry.get("count", 0)
        for key in ("fds", "threads", "footprint_mb"):
            if entry.get(key) is not None:
                flat[f"{key}.{group}"] = entry[key]
    for key in ("iosurfaces.app", "terminal_surfaces", "observations_armed", "disk_mb.state", "disk_files.tmp"):
        if sample.get(key) is not None:
            flat[key] = sample[key]
    for key, value in (sample.get("model") or {}).items():
        flat[f"model.{key}"] = value
    return flat


def parse_vmmap_summary(text):
    """{region name: {"regions": n, "dirty_mb": x, "virtual_mb": y}} from `vmmap -summary` (its REGION TYPE table:
    name, virtual, resident, dirty, swapped, volatile, nonvol, empty, region count)."""
    def mb(token):
        match = re.fullmatch(r"([\d.]+)([KMGT]?)", token)
        if not match:
            return None
        return float(match.group(1)) * {"": 1 / MB, "K": 1 / 1024, "M": 1, "G": 1024, "T": 1048576}[match.group(2)]
    rows = {}
    for line in text.splitlines():
        tokens = line.split()
        # name (may hold spaces), then 7 sizes (virtual, resident, dirty, swapped, volatile, nonvol, empty), then
        # the region count
        if len(tokens) >= 9 and tokens[-1].isdigit() and all(mb(t) is not None for t in tokens[-8:-1]):
            rows[" ".join(tokens[:-8])] = {"virtual_mb": mb(tokens[-8]), "resident_mb": mb(tokens[-7]),
                                           "dirty_mb": mb(tokens[-6]), "regions": int(tokens[-1])}
    return rows


def marker_pids(table, marker):
    """PIDs of `table` ((pid, ppid, stat, command)) whose command carries `marker`."""
    return [pid for pid, _ppid, _stat, command in table if marker in command]


def zombies_of(table, parents):
    return [pid for pid, ppid, stat, _command in table if stat.startswith("Z") and ppid in parents]


def model_counts(topology):
    """Windows, workspaces, screens, panes and tabs of a snapshot.get topology."""
    workspaces = [w for w in topology.get("workspaces") or [] if w.get("id")]
    screens = [s for w in workspaces for s in w.get("screens") or []]
    panes = [p for s in screens for p in s.get("panes") or []]
    return {"windows": len(topology.get("windows") or []), "workspaces": len(workspaces), "screens": len(screens),
            "panes": len(panes), "tabs": sum(len(p.get("tabs") or []) for p in panes)}


def self_test():
    assert tolerance("footprint_mb.app", 500) == 48 + 32
    rows = compare({"orphans": 0, "fds.app": 100}, {"orphans": 2, "fds.app": 120}, 1)
    assert rows[0][0] == "orphans" and not rows[0][5]
    assert rows[1][5]  # 20 <= 32
    flat = flatten({"orphans": [5], "zombies": [], "groups": {"app": {"count": 1, "fds": 9, "threads": 3,
                                                                       "footprint_mb": 10.0}},
                    "model": {"tabs": 2}, "terminal_surfaces": 1})
    assert flat["orphans"] == 1 and flat["fds.app"] == 9 and flat["model.tabs"] == 2
    summary = ("REGION TYPE                        SIZE    SIZE    SIZE    SIZE  VOLATILE  NONVOL    EMPTY   COUNT\n"
               "IOSurface                         81.2M   80.1M   80.1M      0K        0K   12.0M       0K      64\n"
               "App-Specific Tag 14              512.0M  360.2M  354.1M      0K        0K      0K       0K     211\n")
    parsed = parse_vmmap_summary(summary)
    assert parsed["IOSurface"]["regions"] == 64, parsed
    assert abs(parsed["App-Specific Tag 14"]["dirty_mb"] - 354.1) < 0.01, parsed
    table = [(10, 1, "S", "sleep 7 leakmark-x"), (11, 9, "Z", "(sh)"), (12, 9, "S", "zsh")]
    assert marker_pids(table, "leakmark-x") == [10] and zombies_of(table, {9}) == [11]
    topo = {"windows": [{"key": "w"}], "workspaces": [{"id": "a", "screens": [{"panes": [{"tabs": [{}, {}]}]}]}]}
    assert model_counts(topo) == {"windows": 1, "workspaces": 1, "screens": 1, "panes": 1, "tabs": 2}
    print("leak-harness: self-test passed")


# ---------------------------------------------------------------- macOS reads

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib") if sys.platform == "darwin" else None
PROC_PIDLISTFDS = 1
PROC_FDINFO_SIZE = 8


def fd_count(pid):
    """Open descriptors of `pid` (proc_pidinfo PROC_PIDLISTFDS), or None once it is gone."""
    if _libproc is None:
        return None
    size = 4096 * PROC_FDINFO_SIZE
    while True:
        buf = ctypes.create_string_buffer(size)
        got = _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDLISTFDS), ctypes.c_uint64(0), buf,
                                    ctypes.c_int(size))
        if got <= 0:
            return None
        if got < size:
            return got // PROC_FDINFO_SIZE
        size *= 4


PROC_PIDTASKINFO = 4
TASKINFO_SIZE = 96
TASKINFO_THREADNUM_OFFSET = 84


def thread_count(pid):
    """Threads of `pid` (proc_taskinfo.pti_threadnum), or None once it is gone."""
    if _libproc is None:
        return None
    buf = ctypes.create_string_buffer(TASKINFO_SIZE)
    if _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDTASKINFO), ctypes.c_uint64(0), buf,
                             ctypes.c_int(TASKINFO_SIZE)) != TASKINFO_SIZE:
        return None
    return int.from_bytes(buf.raw[TASKINFO_THREADNUM_OFFSET:TASKINFO_THREADNUM_OFFSET + 4], "little", signed=True)


def process_rows():
    out = subprocess.run(["ps", "-axo", "pid=,ppid=,stat=,command="], capture_output=True, text=True,
                         env=dict(os.environ, LC_ALL="C")).stdout
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 3)
        if len(parts) >= 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2], parts[3] if len(parts) > 3 else ""))
    return rows


def folder_usage(path):
    files = size = 0
    for root, _dirs, names in os.walk(path):
        for name in names:
            try:
                info = os.lstat(os.path.join(root, name))
            except OSError:
                continue
            files += 1
            size += info.st_size
    return files, size


def vmmap_summary(pid):
    try:
        run = subprocess.run(["vmmap", "-summary", str(pid)], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"error": str(error)[:200]}
    if run.returncode != 0:
        return {"error": run.stderr.strip()[:200]}
    return parse_vmmap_summary(run.stdout)


# ---------------------------------------------------------------- the run

class Harness:
    def __init__(self, opts, bench, bm, st, teardown):
        self.opts, self.bench, self.bm, self.st, self.teardown = opts, bench, bm, st, teardown
        self.rpc = bench.rpc
        self.stress = st.Stress(self.rpc, log=self.log, allow_chat_fallback=True)
        self.marker = f"leakmark{uuid.uuid4().hex[:10]}"
        self.report = {"marker": self.marker, "tolerances": TOLERANCES, "rows": [], "leaks": [], "errors": [],
                       "not_run": [], "resource_bench": []}
        self.app_pid = bench.process.pid
        self.tmp_baseline = None

    def log(self, line):
        print(line, flush=True)

    def error(self, what):
        self.report["errors"].append(what[:400])
        self.log(f"LEAK-HARNESS-ERROR {what[:400]}")

    def action(self, name, args=None, target=None, timeout=60):
        return self.stress.action(name, args, target=target, focus=False, timeout=timeout)

    def topology(self):
        return self.stress.topology()

    # ---- samples

    def sample(self, label, vmmap=False):
        table = process_rows()
        tag = {pid: cmd for pid, cmd in self.teardown.processes()}
        groups = {}
        for pid, cmd in tag.items():
            kind = self.bm.kind_of(cmd, self.bench.app) if pid != self.app_pid else "app"
            group = group_of(kind)
            entry = groups.setdefault(group, {"count": 0, "fds": 0, "threads": 0, "footprint_mb": 0.0, "rss_mb": 0.0,
                                              "kinds": {}})
            entry["count"] += 1
            entry["kinds"][kind] = entry["kinds"].get(kind, 0) + 1
            usage = self.bm.usage(pid)
            if usage:
                entry["footprint_mb"] = round(entry["footprint_mb"] + usage[1] / MB, 1)
                entry["rss_mb"] = round(entry["rss_mb"] + usage[0] / MB, 1)
            entry["threads"] += thread_count(pid) or 0
            entry["fds"] += fd_count(pid) or 0
        sample = {"label": label, "time": round(time.time(), 1), "groups": groups,
                  "orphans": [(pid, cmd[:120]) for pid, _p, _s, cmd in table
                              if self.marker in cmd and pid not in tag and "leak-harness" not in cmd],
                  "zombies": zombies_of(table, set(tag))}
        memory = self.rpc("debug.memory", timeout=60)
        if isinstance(memory, dict) and not memory.get("error"):
            terminal = memory.get("terminal") or {}
            sample["terminal_surfaces"] = terminal.get("surfaces")
            sample["hidden_iosurface_mb"] = round((terminal.get("hidden_nonvolatile_iosurface_bytes") or 0) / MB, 1)
            sample["consumers"] = len(memory.get("consumers") or [])
            sample["memory_tabs"] = len(memory.get("tabs") or [])
        observations = self.rpc("debug.observations", timeout=30)
        if isinstance(observations, dict) and isinstance(observations.get("totals"), dict):
            sample["observations_armed"] = observations["totals"].get("armed")
        sample["model"] = model_counts(self.topology())
        state = self.bench.state_root()
        files, size = folder_usage(state) if os.path.isdir(state) else (0, 0)
        sample["disk_mb.state"], sample["disk_files.state"] = round(size / MB, 2), files
        tmp = os.environ.get("TMPDIR") or "/tmp"
        sample["disk_files.tmp"] = sum(1 for name in os.listdir(tmp) if "cmux" in name.lower()) if os.path.isdir(tmp) else 0
        if vmmap or self.opts.vmmap:
            summary = vmmap_summary(self.app_pid)
            sample["vmmap"] = summary
            surfaces = summary.get("IOSurface") if isinstance(summary, dict) else None
            if isinstance(surfaces, dict):
                sample["iosurfaces.app"] = surfaces.get("regions")
        return sample

    def settle_until(self, baseline_flat, seconds):
        """Waits up to `seconds` for the tag's process count and the orphans to come back to the baseline."""
        deadline = now() + seconds
        while now() < deadline:
            table = process_rows()
            orphans = marker_pids(table, self.marker)
            if not [p for p in orphans if p != os.getpid()]:
                count = len(self.teardown.processes())
                base = sum(v for k, v in baseline_flat.items() if k.startswith("processes."))
                if count <= base:
                    return round(seconds - (deadline - now()), 1)
            time.sleep(0.5)  # harness: polling the process table
        return None

    # ---- use

    def use_terminal(self, tab, index):
        """A background job in its own process group (`&` in an interactive shell with job control) and, for the
        first --servers terminals, a listening TCP server (a dev server). Each carries this run's marker in its argv,
        so the process table names it after its shell is gone and it is re-parented to launchd."""
        text = f"sh -c 'sleep 86400; : {self.marker}-job-{index}' &\r"
        if index < self.opts.servers:
            text += (f"python3 -c 'import socket,time;s=socket.socket();s.bind((\"127.0.0.1\",0));s.listen();"
                     f"time.sleep(86400)' {self.marker}-server-{index} &\r")
        self.action("terminal.sendText", {"text": text}, target=f"tab:{tab}")

    # ---- kinds: each returns the ids it made; close(kind, ids) closes them

    def scratch_workspace(self):
        workspace = self.stress.new_workspace()
        if not workspace:
            raise RuntimeError("no scratch workspace")
        self.stress.show(workspace)
        return workspace

    def first_pane(self, workspace):
        panes = self.stress.panes(self.stress.workspace(workspace))
        return panes[0]["id"]

    def make(self, kind, count, workspace):
        made = []
        deadline = now() + self.opts.kind_seconds
        pane = self.first_pane(workspace)
        for index in range(count):
            if now() > deadline:
                self.error(f"{kind}: made {len(made)} of {count} in --kind-seconds {self.opts.kind_seconds}")
                break
            if kind in ("terminal", "chromium", "webkit", "page", "chat"):
                before = {t.get("id") for t in self.stress.tabs(workspace, pane)}
                self.stress.add_tab(workspace, pane, kind)
                new = [t.get("id") for t in self.stress.tabs(workspace, pane) if t.get("id") not in before]
                made += new
                if kind == "terminal" and new:
                    self.use_terminal(new[0], index)
            elif kind == "tab":
                before = {t.get("id") for t in self.stress.tabs(workspace, pane)}
                tabs = self.stress.tabs(workspace, pane)
                self.action("newTab.default", target=f"tab:{tabs[-1]['id']}" if tabs else f"pane:{pane}")
                self.st.wait(lambda: len(self.stress.tabs(workspace, pane)) > len(before), 20, step=0.05)
                new = [t.get("id") for t in self.stress.tabs(workspace, pane) if t.get("id") not in before]
                made += new
            elif kind == "pane":
                source = made[-1] if made else pane
                new = self.stress.split(workspace, source, "splitRight")
                if not new:
                    self.error(f"pane: split {index} made no pane (layout cap)")
                    break
                made.append(new)
                tabs = self.stress.tabs(workspace, new)
                if tabs:
                    self.use_terminal(tabs[0]["id"], index)
            elif kind == "screen":
                before = {s.get("id") for s in (self.stress.workspace(workspace) or {}).get("screens") or []}
                self.action("screen.new", target=f"workspace:{workspace}")
                self.st.wait(lambda: len((self.stress.workspace(workspace) or {}).get("screens") or []) > len(before),
                             20, step=0.05)
                made += [s["id"] for s in (self.stress.workspace(workspace) or {}).get("screens") or []
                         if s.get("id") not in before]
            elif kind == "workspace":
                new = self.stress.new_workspace()
                if new:
                    made.append(new)
                    panes = self.stress.panes(self.stress.workspace(new))
                    tabs = panes[0].get("tabs") if panes else []
                    if tabs:
                        self.use_terminal(tabs[0]["id"], index)
            elif kind == "window":
                before = {w.get("key") for w in self.topology().get("windows") or []}
                self.action("newWindow")
                self.st.wait(lambda: len(self.topology().get("windows") or []) > len(before), 20, step=0.05)
                made += [w["key"] for w in self.topology().get("windows") or [] if w.get("key") not in before]
            elif kind == "profile":
                name = f"{self.marker}-p{index}"
                reply = self.action("browserProfile.new", {"name": name})
                if isinstance(reply, dict) and reply.get("error"):
                    self.error(f"profile: {str(reply['error'])[:200]}")
                    break
                tabs = self.stress.tabs(workspace, pane)
                self.action("browserProfile.newTab", {"browserProfile": name, "url": self.stress.pages.url()},
                            target=f"tab:{tabs[-1]['id']}" if tabs else f"pane:{pane}")
                made.append(name)
            elif kind == "chief":
                reply = self.rpc("action.run", {"action": "home.newChief", "args": {"name": f"{self.marker}-c{index}"},
                                                "origin": "script", "focus": False, "wait": True}, timeout=60)
                chief = (reply or {}).get("result", {}).get("id") if isinstance(reply, dict) else None
                if not chief:
                    self.error(f"chief: home.newChief gave no id: {json.dumps(reply)[:200]}")
                    break
                made.append(chief)
            elif kind == "ssh":
                if not self.opts.ssh_host:
                    break
                reply = self.action("remote.connect", {"host": self.opts.ssh_host})
                made.append(json.dumps(reply)[:80])
        return made

    def close(self, kind, made, workspace):
        for item in made:
            if kind in ("terminal", "tab", "chromium", "webkit", "page", "chat"):
                self.action("closeTab", {"confirm": True}, target=f"tab:{item}")
            elif kind == "pane":
                self.action("closePane", {"confirm": True}, target=f"pane:{item}")
            elif kind == "screen":
                self.action("screen.close", {"confirm": True}, target=f"screen:{item}")
            elif kind == "workspace":
                self.action("closeWorkspace", {"confirm": True}, target=f"workspace:{item}")
            elif kind == "window":
                self.action("closeWindow", {"confirm": True}, target=f"window:{item}")
            elif kind == "profile":
                self.action("browserProfile.delete", {"browserProfile": item, "confirm": True})
            elif kind == "chief":
                self.rpc("action.run", {"action": "home.deleteChief", "args": {"chief": item, "confirm": True},
                                        "origin": "script", "focus": False, "wait": True}, timeout=60)
        if kind == "profile":
            # the tabs the profiles opened live in the scratch workspace's first pane
            pane = self.first_pane(workspace)
            for tab in self.stress.tabs(workspace, pane)[1:]:
                self.action("closeTab", {"confirm": True}, target=f"tab:{tab['id']}")

    def run_kind(self, kind, count):
        cap = CAPS.get(kind)
        asked = count
        if cap and count > cap:
            count = cap
            self.report["not_run"].append(f"{kind} N={asked}: capped at {cap} (layout or step time)")
        if kind == "ssh" and not self.opts.ssh_host:
            self.report["not_run"].append("ssh: no --ssh-host (fleet minis have no SSH target for the app)")
            return
        workspace = self.scratch_workspace()
        self.quiet()
        baseline = self.sample(f"{kind}-{count}-baseline", vmmap=True)
        started = now()
        try:
            made = self.make(kind, count, workspace)
        except Exception as error:  # noqa: BLE001 - a kind that cannot run is a row, not the end of the run
            self.error(f"{kind} N={count}: create: {error}")
            made = []
        created_s = round(now() - started, 1)
        time.sleep(self.opts.use_seconds)  # harness: pages load, shells start their jobs
        peak = self.sample(f"{kind}-{count}-peak")
        started = now()
        try:
            self.close(kind, made, workspace)
        except Exception as error:  # noqa: BLE001
            self.error(f"{kind} N={count}: close: {error}")
        # the scratch workspace itself (made before the baseline) stays until the after sample
        settled = self.settle_until(flatten(baseline), self.opts.settle)
        self.quiet()
        after = self.sample(f"{kind}-{count}-after", vmmap=True)
        closed_s = round(now() - started, 1)
        rows = compare(flatten(baseline), flatten(after), len(made))
        record = {"kind": kind, "asked": asked, "count": len(made), "created_s": created_s, "closed_s": closed_s,
                  "settled_s": settled, "baseline": baseline, "peak": peak, "after": after,
                  "rows": [dict(zip(("resource", "before", "after", "growth", "allowed", "ok"), r)) for r in rows],
                  "peak_flat": flatten(peak)}
        self.report["rows"].append(record)
        for resource, before, end, growth, allowed, ok in rows:
            self.log(f"LEAK-HARNESS-ROW kind={kind} n={len(made)} resource={resource} baseline={before} "
                     f"peak={record['peak_flat'].get(resource)} after={end} growth={growth} allowed={allowed} "
                     f"{'ok' if ok else 'LEAK'}")
            if not ok:
                line = f"{kind} n={len(made)} {resource}: {before} -> {end} (+{growth}, allowed {allowed})"
                self.report["leaks"].append(line)
                self.log(f"LEAK {line}")
        if after.get("orphans"):
            self.log(f"LEAK-ORPHANS kind={kind} {after['orphans'][:5]}")
            self.end_orphans()
        self.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}")

    def end_orphans(self):
        """Ends the processes this run started that outlived their terminal (by exact PID and marker), so the next
        kind starts clean."""
        for pid, _ppid, _stat, command in process_rows():
            if self.marker in command and pid != os.getpid() and "leak-harness" not in command:
                try:
                    os.kill(pid, 9)  # a process this harness started (its marker is in the argv)
                except OSError:
                    pass

    def quiet(self):
        time.sleep(self.opts.quiet)  # harness: deferred work (hibernation, release slices) runs before a sample

    def churn(self, presses):
        workspace = self.scratch_workspace()
        self.bench.activate()
        self.quiet()
        baseline = self.sample(f"churn-{presses}-baseline", vmmap=True)
        for _ in range(presses):
            self.rpc("debug.key", {"key": "t", "modifiers": ["cmd"]}, timeout=10)
            time.sleep(self.opts.churn_interval / 1000)  # harness: key repeat pace
            self.rpc("debug.key", {"key": "w", "modifiers": ["cmd"]}, timeout=10)
            time.sleep(self.opts.churn_interval / 1000)
        self.settle_until(flatten(baseline), self.opts.settle)
        self.quiet()
        after = self.sample(f"churn-{presses}-after", vmmap=True)
        rows = compare(flatten(baseline), flatten(after), presses)
        self.report["rows"].append({"kind": "churn", "count": presses, "baseline": baseline, "after": after,
                                    "rows": [dict(zip(("resource", "before", "after", "growth", "allowed", "ok"), r))
                                             for r in rows]})
        for resource, before, end, growth, allowed, ok in rows:
            self.log(f"LEAK-HARNESS-ROW kind=churn n={presses} resource={resource} baseline={before} after={end} "
                     f"growth={growth} allowed={allowed} {'ok' if ok else 'LEAK'}")
            if not ok:
                self.report["leaks"].append(f"churn n={presses} {resource}: {before} -> {end}")
        self.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}")

    # ---- resource bench (resource-minimum.md)

    def usage_sample(self, measure):
        """Per process kind of the tag: count, footprint MB, threads, and CPU % and wakeups/s over `measure` s."""
        pids = {pid: cmd for pid, cmd in self.teardown.processes()}
        start = {pid: self.bm.usage(pid) for pid in pids}
        time.sleep(measure)  # harness: the measured idle window, read from outside (no wakeups added)
        kinds, total = {}, {"footprint_mb": 0.0, "threads": 0, "processes": 0, "cpu_pct": 0.0, "wakeups_per_s": 0.0}
        for pid, cmd in pids.items():
            got = self.bm.usage(pid)
            if got is None:
                continue
            kind = "app" if pid == self.app_pid else self.bm.kind_of(cmd, self.bench.app)
            entry = kinds.setdefault(kind, {"count": 0, "footprint_mb": 0.0, "threads": 0, "cpu_pct": 0.0,
                                            "wakeups_per_s": 0.0})
            threads = thread_count(pid) or 0
            entry["count"] += 1
            entry["footprint_mb"] = round(entry["footprint_mb"] + got[1] / MB, 1)
            entry["threads"] += threads
            if start.get(pid):
                entry["cpu_pct"] = round(entry["cpu_pct"] + 100 * (got[3] - start[pid][3]) / 1e9 / measure, 3)
                entry["wakeups_per_s"] = round(entry["wakeups_per_s"] + (got[4] - start[pid][4]) / measure, 2)
        for entry in kinds.values():
            for key in total:
                total[key] = round(total[key] + entry.get(key if key != "processes" else "count", 0), 3)
        return {"kinds": kinds, "total": total}

    def resource_state(self, state, count):
        workspace = self.scratch_workspace()
        self.quiet()
        base = self.usage_sample(self.opts.measure)
        tabs = []
        if state == "visible":
            windows = []
            remaining = count
            first = True
            while remaining > 0:
                target_ws = workspace if first else self.scratch_window_workspace(windows)
                first = False
                pane = self.first_pane(target_ws)
                panes = [pane]
                for verb, times in (("splitRight", 3),):
                    for _ in range(min(times, remaining - 1)):
                        new = self.stress.split(target_ws, panes[-1], verb)
                        if new:
                            panes.append(new)
                columns = list(panes)
                for column in columns:
                    for _ in range(2):
                        if len(panes) >= min(12, remaining):
                            break
                        new = self.stress.split(target_ws, column, "splitDown")
                        if new:
                            panes.append(new)
                for p in panes[:remaining]:
                    tabs += [t["id"] for t in self.stress.tabs(target_ws, p)[:1]]
                remaining -= len(panes)
        else:
            hidden = self.stress.new_workspace()
            pane = self.first_pane(hidden)
            tabs.append(self.stress.tabs(hidden, pane)[0]["id"])
            for _ in range(count - 1):
                self.stress.add_tab(hidden, pane, "terminal")
            tabs = [t["id"] for t in self.stress.tabs(hidden, pane)]
            self.stress.show(workspace)
        if state == "busy":
            for tab in tabs:
                self.action("terminal.sendText", {"text": "while :; do echo busy $RANDOM; sleep 0.02; done\r"},
                            target=f"tab:{tab}")
        time.sleep(self.opts.use_seconds)  # harness: shells start
        self.quiet()
        measured = self.usage_sample(self.opts.measure)
        app_vm = vmmap_summary(self.app_pid)
        state_files, state_bytes = folder_usage(self.bench.state_root())
        row = {"state": state, "terminals": count, "base": base, "sample": measured,
               "tag14_dirty_mb": (app_vm.get("App-Specific Tag 14") or {}).get("dirty_mb") if isinstance(app_vm, dict) else None,
               "iosurface_regions": (app_vm.get("IOSurface") or {}).get("regions") if isinstance(app_vm, dict) else None,
               "disk_state_mb": round(state_bytes / MB, 2), "disk_state_files": state_files}
        per = {}
        for kind, entry in measured["kinds"].items():
            before = base["kinds"].get(kind, {})
            per[kind] = {"footprint_mb": round(entry["footprint_mb"] - before.get("footprint_mb", 0), 1),
                         "threads": entry["threads"] - before.get("threads", 0),
                         "count": entry["count"] - before.get("count", 0),
                         "cpu_pct": entry.get("cpu_pct"), "wakeups_per_s": entry.get("wakeups_per_s")}
        row["delta_by_kind"] = per
        self.report["resource_bench"].append(row)
        total, before = measured["total"], base["total"]
        self.log(f"RESOURCE-ROW state={state} terminals={count} total_footprint_mb={total['footprint_mb']} "
                 f"delta_mb={round(total['footprint_mb'] - before['footprint_mb'], 1)} "
                 f"threads={total['threads']} processes={total['processes']} cpu_pct={total['cpu_pct']} "
                 f"wakeups_per_s={total['wakeups_per_s']} "
                 f"tag14_dirty_mb={row['tag14_dirty_mb']} iosurfaces={row['iosurface_regions']} "
                 f"disk_state_mb={row['disk_state_mb']} by_kind={json.dumps(per, separators=(',', ':'))}")
        # end the state: every workspace and window it made
        for w in [w for w in self.stress.workspaces() if w["id"] != workspace]:
            if w["id"] in self.initial_workspaces:
                continue
            self.action("closeWorkspace", {"confirm": True}, target=f"workspace:{w['id']}")
        for key in [w.get("key") for w in self.topology().get("windows") or []][1:]:
            self.action("closeWindow", {"confirm": True}, target=f"window:{key}")
        self.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}")
        self.quiet()

    def scratch_window_workspace(self, windows):
        before = {w.get("key") for w in self.topology().get("windows") or []}
        self.action("newWindow")
        self.st.wait(lambda: len(self.topology().get("windows") or []) > len(before), 20, step=0.05)
        window = next(w for w in self.topology().get("windows") or [] if w.get("key") not in before)
        windows.append(window["key"])
        return window["workspace"]

    def run(self):
        self.initial_workspaces = {w["id"] for w in self.stress.workspaces()}
        self.quiet()
        self.report["start"] = self.sample("start", vmmap=True)
        if self.opts.resource_bench:
            for count in self.opts.counts:
                for state in self.opts.states:
                    try:
                        self.resource_state(state, count)
                    except Exception as error:  # noqa: BLE001
                        self.error(f"resource {state} {count}: {error}")
        else:
            for count in self.opts.counts:
                for kind in self.opts.kinds:
                    try:
                        self.run_kind(kind, count)
                    except Exception as error:  # noqa: BLE001
                        self.error(f"{kind} N={count}: {error}")
            if self.opts.churn:
                try:
                    self.churn(self.opts.churn)
                except Exception as error:  # noqa: BLE001
                    self.error(f"churn: {error}")
        self.quiet()
        self.report["end"] = self.sample("end", vmmap=True)
        rows = compare(flatten(self.report["start"]), flatten(self.report["end"]),
                       sum(r.get("count", 0) for r in self.report["rows"]))
        self.report["drift"] = [dict(zip(("resource", "before", "after", "growth", "allowed", "ok"), r)) for r in rows]
        for resource, before, end, growth, allowed, ok in rows:
            self.log(f"LEAK-HARNESS-DRIFT resource={resource} start={before} end={end} growth={growth} "
                     f"{'ok' if ok else 'LEAK'}")

    def record(self, story):
        """result-v1 into the perf-lab story: per kind and N, the growth of each resource after the close (story
        leak-cleanup), and per state and count the resource bench's totals (story resource-minimum)."""
        def unit_of(resource, value):
            return ("bytes", value * MB) if "_mb" in resource else ("count", value)
        for row in self.report["rows"]:
            for entry in row["rows"]:
                unit, value = unit_of(entry["resource"], entry["growth"])
                metric = f"leak.{row['kind']}.{row['count']}.{entry['resource']}".replace("_", "-")
                try:
                    self.bench.record(story, metric, unit, [value], "lower", "none")
                except Exception as error:  # noqa: BLE001
                    self.error(f"record {metric}: {error}")
                    return
        for row in self.report["resource_bench"]:
            total = row["sample"]["total"]
            for name, value, unit in (("footprint", total["footprint_mb"] * MB, "bytes"),
                                      ("threads", total["threads"], "count"),
                                      ("processes", total["processes"], "count"),
                                      ("cpu", total["cpu_pct"], "percent"),
                                      ("wakeups", total["wakeups_per_s"], "per_s"),
                                      ("disk", row["disk_state_mb"] * MB, "bytes")):
                try:
                    self.bench.record(story, f"resource.{row['state']}.{row['terminals']}.{name}", unit, [value],
                                      "lower", "none")
                except Exception as error:  # noqa: BLE001
                    self.error(f"record resource: {error}")
                    return


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app")
    parser.add_argument("--tag")
    parser.add_argument("--out", default=".")
    parser.add_argument("--json")
    parser.add_argument("--story")
    parser.add_argument("--counts", default="1,50,500")
    parser.add_argument("--kinds", default=",".join(k for k in KINDS if k != "ssh"))
    parser.add_argument("--states", default="hidden,visible,busy")
    parser.add_argument("--resource-bench", action="store_true")
    parser.add_argument("--churn", type=int, default=300, help="Cmd-T then Cmd-W presses; 0: none")
    parser.add_argument("--churn-interval", type=float, default=33.0, help="ms between presses")
    parser.add_argument("--servers", type=int, default=5, help="terminals per kind that also run a listening server")
    parser.add_argument("--settle", type=float, default=30.0, help="seconds to wait for processes to end after a close")
    parser.add_argument("--quiet", type=float, default=8.0, help="seconds of quiet before each sample")
    parser.add_argument("--use-seconds", type=float, default=5.0)
    parser.add_argument("--measure", type=float, default=10.0, help="resource bench CPU and wakeup window, seconds")
    parser.add_argument("--kind-seconds", type=float, default=900.0, help="time limit to make one kind's N items")
    parser.add_argument("--vmmap", action="store_true", help="vmmap the app at every sample, not only the ends")
    parser.add_argument("--ssh-host")
    parser.add_argument("--self-test", action="store_true")
    opts, _unknown = parser.parse_known_args(argv)
    opts.counts = [int(c) for c in str(opts.counts).split(",") if c]
    opts.kinds = [k for k in opts.kinds.split(",") if k]
    opts.states = [s for s in opts.states.split(",") if s]
    unknown = [k for k in opts.kinds if k not in KINDS]
    if unknown:
        parser.error(f"unknown kinds {unknown}; known: {', '.join(KINDS)}")
    if opts.resource_bench and opts.counts == [1, 50, 500]:
        opts.counts = [1, 10, 100]
    return opts


def main(argv):
    opts = parse_args(argv)
    if opts.self_test:
        self_test()
        return 0
    if sys.platform != "darwin" or not opts.app:
        print("leak-harness: macOS with --app only (a fleet Mac: scripts/measure/split-spring.sh --suite=leak)",
              file=sys.stderr)
        return 2
    import importlib.util
    from bench_launch import BenchApp, LaunchError, shipping_env  # noqa: E402
    import bench_memory as bm  # noqa: E402
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    st = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(st)
    os.makedirs(opts.out, exist_ok=True)
    bench = BenchApp(opts.app, out=opts.out, env=shipping_env(draw=False))
    report = {"argv": argv, "app": os.path.basename(opts.app)}
    code = 0
    try:
        try:
            bench.launch()
        except LaunchError as error:
            print(f"leak-harness: the app did not launch: {error}", file=sys.stderr)
            return 2
        harness = Harness(opts, bench, bm, st, bench.teardown)
        try:
            harness.run()
            if opts.story:
                harness.record(opts.story)
        finally:
            harness.stress.close()
            harness.end_orphans()
            report.update(harness.report)
        code = 1 if report.get("leaks") else 0
    finally:
        bench.stop()
        path = opts.json or os.path.join(opts.out, "leak-harness.json")
        with open(path, "w") as handle:
            json.dump(report, handle, indent=1, default=str)
        print(f"leak-harness: report {path}; {len(report.get('leaks') or [])} leaks, "
              f"{len(report.get('errors') or [])} errors, not run: {report.get('not_run')}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
