#!/usr/bin/env python3
"""Click to first content for agent chats in cmux NEXT, idle and under load (Leo, 2026-10-29:
"i also like the way it just loads in the subagent stuff instantly :(" / "as in i want ours to load
fast too :(" / "but i also wonder how much of this is simply putting the desktop at higher priority?").

Four opens, each timed by the app's own chat-open trace (`debug.chat_open_trace`: from the action
to the first frame the pane shows the chat's content, with every surface the pane showed between):

  sidebar    a chat never opened in this app's life, opened in a new workspace and shown
             (`agent.openSessionWorkspace`, then `workspace.selectLast`: the action alone makes the
             workspace and never shows it, so a sidebar click's open is the two)
  reopen     a chat this app showed before, opened again in a new workspace
  subagent   a click on a subagent's line in its chat's transcript (`debug.agent_pane click`),
             which opens the subagent's pane (`chat.subagentPane`)
  big        a chat of --turns turns (thousands), never opened before
  bloated    a chat whose log is mostly repeated tool_call_update records (--bloat calls x
             updates x KiB, every update re-sending the whole output), as long Codex and Claude
             Code commands leave acpmux's log today (one 152 MB log on Leo's Mac: 27,564 updates
             for 223 calls)
  restore    the app quit and launched again on the same state: the restored chat's pane, timed
             from the process start (a launch trace, CMUX_CHAT_OPEN_TRACE_LAUNCH=1)

each under four conditions, so the share that is CPU priority separates from the share that is the
app's own path:

  idle           nothing else runs
  load           an agent-like load at default priority: CPU spinners on every core, disk writers,
                 metadata walks and readers (the load of the QoS lane's probe, bench.sh)
  load_utility   the same load at utility QoS, CPU and disk (`taskpolicy -c utility -d utility`:
                 the tier acpmux gives agent hosts)
  load_nice      the same load at nice 20: the app's UI raised relative to it by priority alone
                 (an unprivileged script cannot raise the app itself; this is the same gap)

The chats come from a seeding daemon (idle_cost_load.PeerDaemon) on chat_open_agent.py: one
template of each shape, written by acpmux itself, copied into the app's store under fresh ids, so
every cold open is a chat no page of this app has read. --sessions more short chats fill the
store's list, as a long-used daemon's does.

Every number is from this app's own clock; the per-open record keeps each trace's marks, the
surfaces it showed (`frames`: a flash is a return to an empty surface after content), the page's
own timing and the new page's acpmux wire log (`acp_log`: which requests the open waited on).

Runs on a fleet mini through scripts/measure/chat-open.sh, never on an interactive Mac:
  chat-open-bench.py --app BUNDLE [--runs 3] [--turns 3000] [--sessions 1500]
                     [--conditions idle,load,load_utility,load_nice] [--cases sidebar,reopen,subagent,big,restore]
                     [--json FILE] [--md FILE]
The table is also printed between CHAT-OPEN-TABLE-BEGIN and -END. A fleet step returns ONE file (`cmux-ci run
--artifact` takes a single path; a second one replaces the first), so ask for artifacts/chat-open.json: it has
every open's marks, frames, page timing and wire log, and the table can be rebuilt from it.
Kills only the processes it started (the app it launched through bench_memory, the seeding daemon,
and the load's own process groups).
"""
import argparse
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_memory as bm  # noqa: E402
import idle_cost_load as icl  # noqa: E402
from bench_power import wipe_state  # noqa: E402  (the tagged app's saved state under the real ~/Library)
from chat_open_summary import cell, summarize  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--turns", type=int, default=3000)
parser.add_argument("--small-turns", type=int, default=30)
parser.add_argument("--subagents", type=int, default=0, help="subagents in the subagent chat (default: --runs + 1)")
parser.add_argument("--bloat", default="20 400 5", help="calls, updates per call, KiB per update")
parser.add_argument("--sessions", type=int, default=1500)
parser.add_argument("--conditions", default="idle,load,load_utility,load_nice")
parser.add_argument("--cases", default="sidebar,reopen,subagent,big,bloated,restore")
parser.add_argument("--settle", type=float, default=6, help="seconds a load runs before the first open under it")
parser.add_argument("--config", default="{}", help="cmux.json for the app (JSON); workspaces.newPlacement stays bottom")
parser.add_argument("--record-launch", type=float, default=0,
                    help="restore: record each relaunch's windows for SECONDS from the first frame (the app's "
                         "--record-launch) into --launch-frames, and list the pictures the quit saved")
parser.add_argument("--launch-frames", default="artifacts/launch-frames.tar.gz",
                    help="with --record-launch: the archive of every relaunch's recorded frames (.tar.gz is added when missing)")
parser.add_argument("--backdrop", choices=["opaque", "frosted", "glass", "glass-clear"], default="opaque",
                    help="the window material (appearance.backgroundBlur at 85%% opacity; opaque leaves the default): "
                         "a page over a translucent window is clear, which a saved picture must keep")
parser.add_argument("--tag", default="chatopen", help="the tag the app was built with (its state folder)")
parser.add_argument("--json")
parser.add_argument("--md")
opts = parser.parse_args()
APP = os.path.realpath(opts.app.rstrip("/"))
CONDITIONS = [c.strip() for c in opts.conditions.split(",") if c.strip()]
CASES = [c.strip() for c in opts.cases.split(",") if c.strip()]
SUBAGENTS = opts.subagents or opts.runs + 1
# A new workspace goes last, so `workspace.selectLast` shows the one an open just made (the default
# placement is the top of the list). Over --config: another placement would show the wrong workspace.
# The tagged build's state folder (scripts/measure/chat-open.sh builds --tag, default "chatopen").
TAG_DIR = os.path.join("tags", opts.tag)
BACKDROP = {} if opts.backdrop == "opaque" else {"appearance": {"backgroundBlur": opts.backdrop, "backgroundOpacity": 0.85}}
CONFIG = bm.merged(bm.merged(json.loads(opts.config), BACKDROP), {"workspaces": {"newPlacement": "bottom"}})
AGENT = os.path.join(HERE, "chat_open_agent.py")
NCPU = os.cpu_count() or 8
# How often an open asks again to show its workspace before the app lists it (open_workspace).
SHOW_POLL_S = 0.005


def say(*parts):
    print(" ".join(str(p) for p in parts), flush=True)


# ---------------------------------------------------------------------------------------------
# The load. Same shape as the QoS lane's probe (bench.sh), so their numbers and these compare.

SPIN_C = r"""#include <pthread.h>
static void*t(void*a){volatile unsigned long x=0;for(;;)x++;return 0;}
int main(){pthread_t th;for(int i=0;i<3;i++)pthread_create(&th,0,t,0);t(0);return 0;}
"""


class Load:
    PREFIX = {"load": [], "load_utility": ["taskpolicy", "-c", "utility", "-d", "utility"],
              "load_nice": ["nice", "-n", "20"]}

    def __init__(self, root):
        self.root = os.path.join(root, "load")
        os.makedirs(os.path.join(self.root, "tree"), exist_ok=True)
        source = os.path.join(self.root, "spin.c")
        with open(source, "w") as handle:
            handle.write(SPIN_C)
        self.spin = os.path.join(self.root, "spin")
        subprocess.run(["cc", "-O2", "-o", self.spin, source], check=True)
        for i in range(400):
            with open(os.path.join(self.root, "tree", f"f{i}"), "wb") as handle:
                handle.write(os.urandom(65536))
        self.groups: list[subprocess.Popen] = []

    def start(self, condition):
        prefix = self.PREFIX[condition]
        work = [[self.spin]] * (NCPU // 4 + 1)
        work += [["/bin/sh", "-c", f"while :; do dd if=/dev/zero of={self.root}/w$$ bs=1m count=256 2>/dev/null; "
                  f"rm -f {self.root}/w$$; done"]] * 2
        work += [["/bin/sh", "-c", "while :; do find /System/Library /usr -type f -size +1k >/dev/null 2>&1; done"]] * 2
        work += [["/bin/sh", "-c", f"while :; do cat {self.root}/tree/f* | shasum >/dev/null; done"]] * 2
        for argv in work:
            # Each in a process group of its own, so stop() ends exactly what this started.
            self.groups.append(subprocess.Popen(prefix + argv, start_new_session=True,
                                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    def stop(self):
        for child in self.groups:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for child in self.groups:
            child.wait()
        self.groups = []
        for name in os.listdir(self.root):
            if name.startswith("w"):
                os.remove(os.path.join(self.root, name))


def load_average():
    return subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.strip()


# ---------------------------------------------------------------------------------------------
# The chats.

def copy_chat(home, template, title):
    """`template` (icl.read_chat) under a fresh id in the store at `home`; the new id."""
    session = str(uuid.uuid4())
    swap = lambda data: data.replace(template["id"].encode(), session.encode())  # noqa: E731
    meta = json.loads(swap(template["meta"]))
    now = int(time.time() * 1000)
    meta.update({"id": session, "name": title, "title": title, "updatedAt": now, "status": "idle"})
    folder = os.path.join(home, "sessions", session)
    icl.private_dir(folder)
    icl.private_dir(os.path.join(folder, "events"))
    icl.private_write(os.path.join(folder, "session.json"), json.dumps(meta, indent=2).encode())
    for name, data in template["events"].items():
        icl.private_write(os.path.join(folder, "events", name), swap(data))
    return session


def seed(root):
    """Templates written by acpmux on the seeding daemon, then the app's store: --sessions short
    chats for the list and fresh copies of each shape for every cold open."""
    peer = icl.PeerDaemon(APP, root, AGENT)
    peer.start()
    try:
        started = time.monotonic()

        def chat(first, more):
            session = peer.new_chat(first)
            if not session:
                raise SystemExit("chat-open: the seeding daemon made no chat")
            for text in more:
                sent = peer.acpmux("send", session, text, timeout=120)
                if sent.returncode != 0:
                    raise SystemExit(f"chat-open: send {text!r}: {(sent.stdout + sent.stderr).strip()[-2000:]}")
            return icl.read_chat(peer.home, session)

        small = chat("turn: 0", [f"turn: {i}" for i in range(1, opts.small_turns)])
        sub = chat("turn: 0", ["turn: 1", f"subagents: {SUBAGENTS}"])
        big = chat("turn: 0", [f"turn: {i}" for i in range(1, opts.turns)]) if "big" in CASES else None
        bloated = chat("turn: 0", [f"bloat: {opts.bloat}", "turn: 1"]) if "bloated" in CASES else None
        answered, closed = peer.templates()
        seeded_s = time.monotonic() - started
    finally:
        peer.stop()
    home = os.path.join(root, "acpmux")
    filler = icl.seed_store(home, opts.sessions, 0.6, answered, closed)
    per = {}
    for condition in CONDITIONS:
        per[condition] = {
            "sidebar": [copy_chat(home, small, f"Sidebar {condition} {i}") for i in range(opts.runs)],
            "reopen": [copy_chat(home, small, f"Reopen {condition} {i}") for i in range(opts.runs)],
            "subagent": [copy_chat(home, sub, f"Subagents {condition} {i}") for i in range(opts.runs)],
            "big": [copy_chat(home, big, f"Big {condition} {i}") for i in range(opts.runs)] if big else [],
            "bloated": [copy_chat(home, bloated, f"Bloated {condition} {i}") for i in range(opts.runs)] if bloated else [],
        }
    sizes = {name: sum(len(v) for v in t["events"].values()) for name, t in
             (("small", small), ("subagent", sub), ("big", big), ("bloated", bloated)) if t}
    return home, per, {"seed_s": round(seeded_s, 1), "filler": filler, "template_bytes": sizes,
                       "turns": opts.turns, "small_turns": opts.small_turns, "subagents": SUBAGENTS}


# ---------------------------------------------------------------------------------------------
# The app.

class Run:
    """One launched app on a state that outlives its launches (HOME, config, acpmux store)."""

    def __init__(self, root, acpmux_home):
        self.root = root
        self.env = {"ACPMUX_HOME": acpmux_home}
        self.pid = None
        self.sock = None
        self.scratch = None

    def launch(self, trace_launch=False, record=None):
        env = dict(self.env)
        if self.scratch is None:
            self.pid, self.sock, self.scratch = bm.launch(APP, CONFIG, env)
            self.env["HOME"] = os.path.join(self.scratch, "home")
            self.env["TMPDIR"] = os.path.join(self.scratch, "tmp") + "/"
            self.env["CMUX_NEXT_CONFIG_FILE"] = os.path.join(self.scratch, "cmux.json")
        else:
            # The argument, not CMUX_CHAT_OPEN_TRACE_LAUNCH: the app unsets every inherited CMUX*
            # variable but the CMUX_NEXT_* knobs at launch (LaunchIdentity.inheritedKeys), before
            # the trace reads it, so a launch trace armed by the variable never ran.
            args = ["--chat-open-trace-launch"] if trace_launch else []
            if record:
                # The app's own launch recorder (DebugWindowRecord): every window from its first frame,
                # into a folder that must exist.
                os.makedirs(record, exist_ok=True)
                args += ["--record-launch", record, "--record-launch-seconds", str(opts.record_launch)]
            self.pid, self.sock = relaunch(self.scratch, env, args)
        self.app = bm.App(APP, self.sock)
        deadline = time.monotonic() + 60
        while not self.app.ping() and time.monotonic() < deadline:
            time.sleep(0.5)  # test script: the app's socket answers once it runs

    def rpc(self, method, params=None, timeout=40):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(timeout)
                conn.connect(self.sock)
                conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = conn.recv(1 << 20)
                    if not chunk:
                        break
                    buf += chunk
            answer = json.loads(buf or b"{}")
        except (OSError, ValueError) as error:
            return {"error": f"{method}: {error}"}
        return {"error": answer["error"]} if answer.get("error") else answer.get("result")

    def quit(self):
        """Quits as a person does (state saved), then makes sure every process of the bundle ended."""
        self.rpc("action.run", {"action": "quitKeepSessions", "origin": "script"})
        if self.pid and not bm.wait_gone(self.pid, 30):
            bm.end_bundle(APP)
        bm.end_bundle(APP)  # the bundle's daemons and helpers: this run's only (bm.launch checked)

    def saved_pictures(self):
        """The agent pages' pictures the last quit saved for this launch's first frame (AgentPaneLaunchImages).

        In the build's folder under Application Support (SidebarSnapshotFile.buildDirectory), which
        Foundation resolves from the account's own home, not the scratch HOME; both are read."""
        import pwd
        homes = [os.path.join(self.scratch or "", "home"), pwd.getpwuid(os.getuid()).pw_dir]
        found = []
        for home in homes:
            for folder, _dirs, files in os.walk(os.path.join(home, "Library", "Application Support", "cmux")):
                if os.path.basename(folder) == "agent-pane-images" and TAG_DIR in folder:
                    found += sorted(files)
        return found

    def end(self):
        bm.end_bundle(APP)
        if self.scratch:
            shutil.rmtree(self.scratch, ignore_errors=True)


def recorded(folder):
    """Whether the app's launch recorder finished in `folder`: every window it recorded wrote frames.json."""
    windows = [os.path.join(folder, name) for name in os.listdir(folder) if name.startswith("window-")] if os.path.isdir(folder) else []
    return bool(windows) and all(os.path.exists(os.path.join(window, "frames.json")) for window in windows)


def relaunch(scratch, env, args=()):
    """bench_memory.launch's direct launch, on an existing scratch state."""
    import plistlib
    with open(os.path.join(APP, "Contents", "Info.plist"), "rb") as handle:
        binary = os.path.join(APP, "Contents/MacOS", plistlib.load(handle)["CFBundleExecutable"])
    full = {"USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900"}
    full.update(env)
    with open(os.path.join(scratch, "app.log"), "a") as log:
        subprocess.Popen([binary, *args], env=full, stdout=log, stderr=log, stdin=subprocess.DEVNULL, start_new_session=True)
    home = full["HOME"]
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        pid = next((p for p, _, cmd in bm.process_table() if bm.is_binary(cmd, binary)), None)
        path = bm.control_socket(APP, pid, [os.path.join(home, ".local", "state", "cmux"), "/tmp", full["TMPDIR"]]) if pid else None
        if path:
            return pid, path
        time.sleep(0.5)  # test script: waiting for the relaunched app's socket
    raise SystemExit("chat-open: the relaunched app opened no socket in 90 s" + bm.tail(os.path.join(scratch, "app.log")))


def flashes(frames):
    """Returns to an empty surface (cover, a page with nothing painted) after the chat showed."""
    shown, count = False, 0
    for _ms, surface in frames or []:
        if surface in ("page", "cover_leaving", "image"):
            shown = True
        elif surface in ("cover", "page_empty") and shown:
            count += 1
            shown = False
    return count


def first_of(frames, names):
    return next((ms for ms, surface in frames or [] if surface in names), None)


def traced(run, open_fn):
    """Arms a trace, opens, waits for the chat's content; the trace and what the new page waited on."""
    armed = run.rpc("debug.chat_open_trace", {"action": "arm"})
    if not armed or armed.get("error"):
        return {"error": f"arm: {armed}"}
    began = time.monotonic()
    opened = open_fn()
    trace = run.rpc("debug.chat_open_trace", {"action": "wait", "timeout_ms": 15000, "settle_ms": 600,
                                              "page_timing": True}, timeout=40) or {}
    trace["open_reply"] = opened
    # The script's own requests on the trace's clock (ms after arming; the app's wall clock at arming
    # is `armed_wall`): open_sent to open_replied is the open's handler, open_replied to show_replied
    # the wait for the app to list the workspace, show_replied to pane_made the show.
    armed_wall = trace.get("armed_wall")
    wall = opened.pop("wall", None) if isinstance(opened, dict) else None
    if isinstance(armed_wall, (int, float)) and wall:
        trace["wall_ms"] = {name: round((at - armed_wall) * 1000, 1) for name, at in wall.items()}
    trace["script_ms"] = round((time.monotonic() - began) * 1000, 1)
    trace["flashes"] = flashes(trace.get("frames"))
    trace["first_image_ms"] = first_of(trace.get("frames"), ("image",))
    log = run.rpc("debug.agent_pane", {"action": "acp_log", "limit": 40})
    trace["acp_log"] = log
    trace["readiness"] = run.rpc("debug.agent_pane", {"action": "readiness"})
    return trace


def open_workspace(run, session):
    """Opens `session` in a new workspace and shows it as soon as the app has that workspace, as a
    person's open does (Open Chat shows its workspace in the window; a Chief subagent's row reveals
    it once made). The action makes the workspace and selects its tab but never switches to it (it
    is the Chief's background spawn), so alone it left every open off screen: no agent pane was made
    and no trace bound.

    The open names its own workspace key and answers once its handler ran (`wait` False); the show
    (`goToWorkspace` on that key) is asked again every SHOW_POLL_S until the control layer knows the
    workspace (`not_found` before), so the show follows the app's create, not the open's reply,
    which waits for the daemon's creates. `wall` keeps the times; `show_tries` how often it asked."""
    key = str(uuid.uuid4())
    wall = {"open_sent": time.time()}
    opened = run.app.action("agent.openSessionWorkspace", focus=True, wait=False, session=session, key=key)
    wall["open_replied"] = time.time()
    if opened.get("error"):
        return {**opened, "wall": wall}
    deadline = time.monotonic() + 15
    tries = 0
    while True:
        tries += 1
        reply = run.app.action("goToWorkspace", focus=True, workspace=key)
        if not reply.get("error") or "not_found" not in json.dumps(reply.get("error")) or time.monotonic() > deadline:
            break
        time.sleep(SHOW_POLL_S)  # test script: the workspace is not listed yet
    wall["show_replied"] = time.time()
    return {**opened, "key": key, "shown": {"via": "goToWorkspace", "reply": reply, "show_tries": tries}, "wall": wall}


def settle_open(run, session):
    """Opens `session` (unmeasured) and waits for it to show: a parent chat, or a chat read once."""
    opened = open_workspace(run, session)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        ready = run.rpc("debug.agent_pane", {"action": "readiness"}) or {}
        if (ready.get("body_text_length") or 0) > 0 and (ready.get("transcript_rows") or ready.get("rows") or 1):
            break
        time.sleep(0.3)  # test script: waiting for the chat to show
    time.sleep(1.5)  # test script: let the page's own reads (its tail hand-off) finish
    return opened


def why(record):
    """What an open's log line says beyond its times, so a run with no artifact (a failed step returns
    none) still shows why an open had no first content."""
    parts = []
    for key in ("error", "timed_out"):
        if record.get(key):
            parts.append(f"{key}={str(record[key])[:200]}")
    if not record.get("first_content_ms"):
        reply = record.get("open_reply")
        shown = reply.pop("shown", None) if isinstance(reply, dict) else None
        parts.append(f"open_reply={json.dumps(reply, default=str)[:200]}")
        if shown:
            parts.append(f"shown={json.dumps(shown, default=str)[:200]}")
            reply["shown"] = shown
        # Frames are [ms, surface] pairs (flashes, first_of).
        surfaces = sorted({str(f[1]) for f in record.get("frames") or [] if isinstance(f, (list, tuple)) and len(f) > 1})
        # `order` lists the marks that ran; `marks_ms` names every mark, null for one that did not.
        parts.append(f"surfaces={surfaces} frame_count={record.get('frame_count')} marks={record.get('order')}")
        ready = record.get("readiness") or {}
        if isinstance(ready, dict):
            parts.append("readiness=" + json.dumps({k: ready.get(k) for k in ("error", "pane", "body_text_length",
                                                                                "transcript_rows")},
                                                   default=str)[:200])
    return (" " + " ".join(parts)) if parts else ""


def click_subagent(run):
    """Clicks a subagent line the chat shows, newest first. The click needs the line in the page,
    and which of the chat's subagent lines it renders depends on the build: a fixed name per open
    failed with "no visible element matches" for "Auditor 0" at one base and "Auditor 1" at
    another (2026-10-31). A click that matches nothing returns that error at once and does
    nothing, so the next name is tried. The reply is the app's (its `clicked` and any `error` as
    they came), with the subagent it named under `subagent`. Each open is its own copy of the chat with its own
    subagents, so the same name in two opens opens two subagents."""
    reply = None
    for k in range(SUBAGENTS - 1, -1, -1):
        reply = run.rpc("debug.agent_pane", {"action": "click", "text": f"Auditor {k}"}) or {}
        if reply.get("error") != "no visible element matches":
            return {**reply, "subagent": f"Auditor {k}"}
    return reply


def measure_case(run, case, sessions, index):
    session = sessions[case][index] if case != "reopen" else sessions["reopen"][index]
    if case in ("sidebar", "big", "bloated"):
        return traced(run, lambda: open_workspace(run, session))
    if case == "reopen":
        settle_open(run, session)
        run.app.action("workspace.newAtBottom", focus=True)  # leave it: a chat this app read, not shown now
        time.sleep(1)  # test script: the page hands its tail over as it leaves
        return traced(run, lambda: open_workspace(run, session))
    if case == "subagent":
        settle_open(run, session)
        return traced(run, lambda: click_subagent(run))
    raise ValueError(case)


def main():
    root = tempfile.mkdtemp(prefix="chat-open-")
    results = {"host": socket.gethostname(), "ncpu": NCPU, "app": APP,
               "model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
               "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "cases": {}, "raw": {}}
    signal.signal(signal.SIGTERM, bm.interrupted)
    load = Load(root)
    run = None
    frames_root = os.path.join(root, "launch-frames")
    try:
        say("chat-open: seeding")
        home, sessions, seeded = seed(root)
        results["seed"] = seeded
        say("chat-open: seeded", json.dumps(seeded))
        for condition in CONDITIONS:
            # Every condition starts from the same state: a fresh app with no saved workspaces, so
            # a later condition's opens (and its restore) don't carry the earlier ones' workspaces.
            # The wipe also keeps a worker's earlier run of this tag from restoring into this one.
            if run:
                run.end()
            wipe_state(APP)
            run = Run(root, home)
            run.launch()
            time.sleep(5)  # test script: let launch work end before the first measured open
            if condition != "idle":
                load.start(condition)
                time.sleep(opts.settle)  # test script: the load reaches steady state
            results.setdefault("load_avg", {})[condition] = load_average()
            for case in [c for c in CASES if c != "restore"]:
                if case in ("big", "bloated") and not sessions[condition][case]:
                    continue
                records = []
                for index in range(opts.runs):
                    record = measure_case(run, case, sessions[condition], index)
                    records.append(record)
                    say(f"chat-open: {condition} {case} {index}: first_content_ms={record.get('first_content_ms')} "
                        f"empty={record.get('longest_empty_ms')} flashes={record.get('flashes')}{why(record)}")
                results["raw"].setdefault(condition, {})[case] = records
                results["cases"].setdefault(condition, {})[case] = summarize(records)
            if "restore" in CASES:
                records = []
                for index in range(opts.runs):
                    # The shown workspace is the last chat opened (a big one when it ran): it restores.
                    run.quit()
                    record_dir = os.path.join(frames_root, f"{condition}-restore-{index}") if opts.record_launch else None
                    pictures = run.saved_pictures()
                    run.launch(trace_launch=True, record=record_dir)
                    record = run.rpc("debug.chat_open_trace", {"action": "wait", "timeout_ms": 15000,
                                                               "settle_ms": 600, "page_timing": True}, timeout=40) or {}
                    record["flashes"] = flashes(record.get("frames"))
                    record["first_image_ms"] = first_of(record.get("frames"), ("image",))
                    record["acp_log"] = run.rpc("debug.agent_pane", {"action": "acp_log", "limit": 40})
                    record["saved_pictures"] = pictures
                    if record_dir:
                        # The recording runs on the app's clock from its first window frame and writes
                        # frames.json when it ends: the next quit waits for that (bounded), not a guess.
                        done = time.monotonic() + opts.record_launch + 30
                        while time.monotonic() < done and not recorded(record_dir):
                            time.sleep(0.5)  # test script: waiting for the app's recorder to finish
                        if not recorded(record_dir):
                            say(f"chat-open: {condition} restore {index}: the launch recording wrote no frames.json")
                    records.append(record)
                    say(f"chat-open: {condition} restore {index}: first_content_ms={record.get('first_content_ms')} "
                        f"first_image_ms={record.get('first_image_ms')} saved_pictures={pictures}{why(record)}")
                results["raw"].setdefault(condition, {})["restore"] = records
                results["cases"].setdefault(condition, {})["restore"] = summarize(records)
            load.stop()
            time.sleep(3)  # test script: the machine settles between conditions
    finally:
        load.stop()
        if run:
            run.end()
        if opts.record_launch and os.path.isdir(frames_root):
            os.makedirs(os.path.dirname(os.path.abspath(opts.launch_frames)), exist_ok=True)
            # make_archive adds the suffix itself: the path it returns is the one written.
            archive = shutil.make_archive(os.path.abspath(opts.launch_frames).removesuffix(".tar.gz"), "gztar", frames_root)
            say(f"chat-open: launch frames in {archive}")
        shutil.rmtree(root, ignore_errors=True)
    table = markdown(results)
    print("CHAT-OPEN-TABLE-BEGIN\n" + table + "\nCHAT-OPEN-TABLE-END", flush=True)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        with open(opts.json, "w") as handle:
            json.dump(results, handle, indent=1)
    if opts.md:
        with open(opts.md, "w") as handle:
            handle.write(table + "\n")
    failed = [f"{condition} {case}" for condition, cases in results["cases"].items()
              for case, summary in cases.items() if not summary.get("complete")]
    if failed:
        raise SystemExit("chat-open: incomplete measurements (an open with no first content or no empty time): "
                         + ", ".join(failed))


def markdown(results):
    lines = [f"chat-open-bench on {results['host']} ({results['model']}, {results['ncpu']} CPUs); "
             f"median of {opts.runs} opens, milliseconds from the action to the first frame of chat content; "
             f"a cell reads FAILED when an open of its case timed out, errored, or showed no content or no empty time "
             f"(no median over the rest)",
             "", "| case | " + " | ".join(CONDITIONS) + " |", "|---|" + "---|" * len(CONDITIONS)]
    for case in CASES:
        cells = []
        for condition in CONDITIONS:
            s = results["cases"].get(condition, {}).get(case)
            if not s:
                cells.append("–")
                continue
            cells.append(cell(s, case))
        lines.append(f"| {case} | " + " | ".join(cells) + " |")
    lines += ["", "load average per condition: " + ", ".join(f"{c} {v}" for c, v in results.get("load_avg", {}).items())]
    return "\n".join(lines)


if __name__ == "__main__":
    main()
