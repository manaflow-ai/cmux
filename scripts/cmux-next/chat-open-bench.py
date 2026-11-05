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
  click      a mouse click on the sidebar row of a chat never shown in this app's life (its workspace made in
             the background, so the click makes its pane): judged from pixels, not the page's mark
  click_again  a click back onto the row of a chat shown before and left (its page kept)

The click cases read the window as the window server composited it, frame after frame, from the click
(`debug.new_tab frame_strip` with gesture `mouse`, `above` so the Chromium page is in it: read through
ScreenCaptureKit when the process lacks the Screen Recording grant, as on a fleet step, since the window list
then leaves the page out; each record's `capture` says which) until the pane
stops changing, and report click to first content frame, click to final frame, whether those are the same
frame, and how far the transcript's rows moved after the page first drew them (`layout_watch`, started at the
click): chat_open_frames.py (Leo, 2026-11-03: the final view on the first frame, never "text first and the
real view a second later"; a cold local chat at its final frame in under 300 ms). They run first in each
condition, while the sidebar is short, so every row is on screen.

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
The templates are cached on the worker (chat_open_seed_cache.py: keyed by the seed inputs, the
template generator's sources and acpmux's store schema), so the arms of an A/B seed a 10,000-turn
chat once; every run still copies them into a fresh store under fresh ids. --no-seed-cache seeds again.

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
import chat_open_frames as cof  # noqa: E402
from chat_open_summary import cell, invalid_reason, summarize  # noqa: E402
import chat_open_seed_cache as seed_cache  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--turns", type=int, default=3000)
parser.add_argument("--small-turns", type=int, default=30)
parser.add_argument("--subagents", type=int, default=0, help="subagents in the subagent chat (default: --runs + 1)")
parser.add_argument("--bloat", default="20 400 5", help="calls, updates per call, KiB per update")
parser.add_argument("--sessions", type=int, default=1500)
parser.add_argument("--conditions", default="idle,load,load_utility,load_nice")
parser.add_argument("--cases", default="click,click_again,sidebar,reopen,subagent,big,bloated,restore")
parser.add_argument("--strip-ms", type=float, default=2500, help="click cases: how long the frame strip records after the click")
parser.add_argument("--strip-tolerance", type=float, default=0.001,
                    help="click cases: the share of the content area's pixels that may differ for two frames to count as one "
                         "picture; under frame_strip's 0.002, since a near-empty terminal and a blank pane differ by about 0.0017")
parser.add_argument("--keep-frames", type=int, default=1,
                    help="click cases: the first N opens of each case keep their before, first-content and final frames in the JSON (base64 PNG)")
parser.add_argument("--settle-frames", type=int, default=10,
                    help="click cases: frames equal to the last that make the pane settled (the final frame starts them)")
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
parser.add_argument("--no-seed-cache", action="store_true",
                    help="seed every template on the daemon again, neither reading nor writing the worker's seed cache")
parser.add_argument("--capture-check", action="store_true",
                    help="only say whether this process (and so the app it launches) may read the screen "
                         "(screen_capture_check.py) into --json, then exit: nothing is launched (scripts/measure/chat-open.sh "
                         "with --app=PATH builds nothing)")
parser.add_argument("--json")
parser.add_argument("--md")
opts = parser.parse_args()
if opts.capture_check:
    sys.exit(subprocess.run([sys.executable, os.path.join(HERE, "screen_capture_check.py"), "--embed-png",
                             *(["--json", opts.json] if opts.json else [])]).returncode)
APP = os.path.realpath(opts.app.rstrip("/"))
CONDITIONS = [c.strip() for c in opts.conditions.split(",") if c.strip()]
CASES = [c.strip() for c in opts.cases.split(",") if c.strip()]
CLICK_CASES = ("click", "click_again")
# The click cases go first in a condition: each makes a sidebar row, and a row below the sidebar's fold can't be clicked.
CASES = [c for c in CASES if c in CLICK_CASES] + [c for c in CASES if c not in CLICK_CASES]
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


def seed_templates(root):
    """The template chats, from the worker's seed cache (chat_open_seed_cache.py) when it has them,
    else written by acpmux on a seeding daemon and cached. Each entry is keyed by its own inputs and
    the sources that shape it, so the arms of an A/B (different app builds, the same templates)
    seed once. The templates, how long getting them took and each entry's cache result."""
    started = time.monotonic()
    specs = {"small": {"turns": opts.small_turns}, "subagent": {"subagents": SUBAGENTS}}
    if "big" in CASES:
        specs["big"] = {"turns": opts.turns}
    if "bloated" in CASES:
        specs["bloated"] = {"bloat": opts.bloat}
    specs["store"] = {}  # the answered and closed chats seed_store copies, made last as before
    cache_root = None if opts.no_seed_cache else seed_cache.default_root()
    got, keys, result = {}, {}, {}
    if cache_root:
        digest = seed_cache.source_digest(icl.bundled_acpmux(APP))
        for name, inputs in specs.items():
            keys[name] = seed_cache.entry_key(name, inputs, digest)
            got[name] = seed_cache.get(cache_root, keys[name])
            result[name] = "hit" if got[name] else "miss"
    else:
        result = {name: "off" for name in specs}
    missing = [name for name in specs if not got.get(name)]
    if missing:
        peer = icl.PeerDaemon(APP, root, AGENT)
        peer.start()
        try:
            def chat(first, more):
                session = peer.new_chat(first)
                if not session:
                    raise SystemExit("chat-open: the seeding daemon made no chat")
                for text in more:
                    sent = peer.acpmux("send", session, text, timeout=120)
                    if sent.returncode != 0:
                        raise SystemExit(f"chat-open: send {text!r}: {(sent.stdout + sent.stderr).strip()[-2000:]}")
                return icl.read_chat(peer.home, session)

            makers = {
                "small": lambda: {"small": chat("turn: 0", [f"turn: {i}" for i in range(1, opts.small_turns)])},
                "subagent": lambda: {"subagent": chat("turn: 0", ["turn: 1", f"subagents: {SUBAGENTS}"])},
                "big": lambda: {"big": chat("turn: 0", [f"turn: {i}" for i in range(1, opts.turns)])},
                "bloated": lambda: {"bloated": chat("turn: 0", [f"bloat: {opts.bloat}", "turn: 1"])},
                "store": lambda: dict(zip(("answered", "closed"), peer.templates())),
            }
            for name in missing:
                made_at = time.monotonic()
                got[name] = makers[name]()
                if cache_root:
                    seed_cache.put(cache_root, keys[name], specs[name], got[name], time.monotonic() - made_at)
        finally:
            peer.stop()
    if cache_root:
        seed_cache.prune(cache_root, keep=tuple(keys.values()))
    templates = {}
    for entry in got.values():
        templates.update(entry)
    return templates, time.monotonic() - started, result


def seed(root):
    """Templates written by acpmux on the seeding daemon (or the worker's seed cache), then the
    app's store: --sessions short chats for the list and fresh copies of each shape for every cold
    open, under fresh ids in a fresh store every run."""
    templates, seeded_s, cache_result = seed_templates(root)
    small, sub = templates["small"], templates["subagent"]
    big, bloated = templates.get("big"), templates.get("bloated")
    answered, closed = templates["answered"], templates["closed"]
    stored_at = time.monotonic()
    home = os.path.join(root, "acpmux")
    filler = icl.seed_store(home, opts.sessions, 0.6, answered, closed)
    per = {}
    for condition in CONDITIONS:
        per[condition] = {
            "sidebar": [copy_chat(home, small, f"Sidebar {condition} {i}") for i in range(opts.runs)],
            "reopen": [copy_chat(home, small, f"Reopen {condition} {i}") for i in range(opts.runs)],
            "click": [copy_chat(home, small, f"Click {condition} {i}") for i in range(opts.runs)],
            "click_again": [copy_chat(home, small, f"Click again {condition} {i}") for i in range(opts.runs)],
            "subagent": [copy_chat(home, sub, f"Subagents {condition} {i}") for i in range(opts.runs)],
            "big": [copy_chat(home, big, f"Big {condition} {i}") for i in range(opts.runs)] if big else [],
            "bloated": [copy_chat(home, bloated, f"Bloated {condition} {i}") for i in range(opts.runs)] if bloated else [],
        }
    sizes = {name: sum(len(v) for v in t["events"].values()) for name, t in
             (("small", small), ("subagent", sub), ("big", big), ("bloated", bloated)) if t}
    return home, per, {"seed_s": round(seeded_s, 1), "store_s": round(time.monotonic() - stored_at, 1),
                       "seed_cache": cache_result, "filler": filler, "template_bytes": sizes,
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
    for key in ("error", "timed_out", "invalid_reason"):
        if record.get(key):
            parts.append(f"{key}={str(record[key])[:200]}")
    if not record.get("first_content_ms"):
        reply = record.get("open_reply")
        shown = reply.pop("shown", None) if isinstance(reply, dict) else None
        probe = reply.pop("probe", None) if isinstance(reply, dict) else None
        parts.append(f"open_reply={json.dumps(reply, default=str)[:200]}")
        if shown:
            parts.append(f"shown={json.dumps(shown, default=str)[:200]}")
            reply["shown"] = shown
        if probe:  # a subagent click that matched nothing: what the page shows (click_subagent)
            parts.append(f"probe={json.dumps(probe, default=str)[:2000]}")
            reply["probe"] = probe
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


# A subagent's line, by what opens it: its finished transcript line (SubagentDoneLine.tsx), then its running-tray
# line (AgentLine.tsx). Enabled ones only: a line with nothing to open is disabled and its click opens nothing.
SUBAGENT_LINES = ("button.cv-subagent-done:not([disabled])", "button.acpmux-agent-line__button:not([disabled])")
NO_MATCH = "no visible element matches"


def subagent_task(k):
    """What chat_open_agent.py asks subagent `k` to do; a line that names a subagent by its task first shows this."""
    return f"Audit area {k}: crashes, edge cases, slow paths"


def click_subagent(run):
    """Clicks a subagent line the chat shows, newest first. The click needs the line in the page,
    and which of the chat's subagent lines it renders depends on the build: a fixed name per open
    failed with "no visible element matches" for "Auditor 0" at one base and "Auditor 1" at
    another (2026-10-31). A click that matches nothing returns that error at once and does
    nothing, so the next candidate is tried. The reply is the app's (its `clicked` and any `error` as
    they came), with what it clicked under `subagent`. Each open is its own copy of the chat with its own
    subagents, so the same name in two opens opens two subagents.

    By text, each subagent's name, then its task: a build that names a line by its task (the tray and a
    finished line read "Audit area 3: ..." since 2026-11-04) shows no element whose text is the name alone.
    Then by structure (`SUBAGENT_LINES`). When nothing matches, `probe` lists which of those selectors match
    anything, so a failed run says what the page shows."""
    reply = None
    texts = [text for k in range(SUBAGENTS - 1, -1, -1) for text in (f"Auditor {k}", subagent_task(k))]
    for text in texts:
        reply = run.rpc("debug.agent_pane", {"action": "click", "text": text}) or {}
        if reply.get("error") != NO_MATCH:
            return {**reply, "subagent": text}
    for selector in SUBAGENT_LINES:
        reply = run.rpc("debug.agent_pane", {"action": "click", "selector": selector}) or {}
        if reply.get("error") != NO_MATCH:
            return {**reply, "subagent": selector}
    return {**reply, "probe": subagent_probe(run)}


# What a failed subagent click looks for, to say what the page shows instead (`probe` in the open's reply).
PROBE_SELECTORS = ("button.cv-subagent-done", "button.acpmux-agent-line__button", ".acpmux-summary-agent__name",
                   ".acpmux-tray-pull__tab", "[data-tray-status]", ".cv-tool")


def subagent_probe(run):
    """Per `PROBE_SELECTORS`, whether the page shows one (a `hover`, which moves the pointer and clicks nothing)."""
    found = {}
    for selector in PROBE_SELECTORS:
        reply = run.rpc("debug.agent_pane", {"action": "hover", "selector": selector}) or {}
        found[selector] = reply.get("error") or "shown"
    state = run.rpc("debug.agent_pane", {"action": "chat_state"}) or {}
    found["chat_state"] = json.dumps(state, default=str)[:1500]  # the summary card and what the page says it shows
    return found


def workspace_id(row):
    """The workspace id of a `debug.sidebar_rows` row: its key reads `workspace(<id>)` (SidebarRowKey's description);
    None for a row that is not a workspace (a section, a group, an item)."""
    key = str((row or {}).get("key") or "")
    return key[len("workspace("):-1] if key.startswith("workspace(") and key.endswith(")") else None


def sidebar_rows(run):
    return [row for window in (run.rpc("debug.sidebar_rows") or {}).get("windows") or [] for row in window.get("rows") or []]


def shown_workspace(run):
    """The id of the workspace the window shows (its selected sidebar row). A launch can show Home or another layout
    item, with no workspace row selected: then a new workspace (a terminal, no chat) is made and shown, bounded."""
    def selected():
        return next((workspace_id(row) for row in sidebar_rows(run) if row.get("selected") and workspace_id(row)), None)

    found = selected()
    if found:
        return found
    run.app.action("workspace.newAtBottom", focus=True)
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        found = selected()
        if found:
            return found
        time.sleep(0.1)  # test script: the new workspace is not shown yet
    say("chat-open: no workspace row is selected, even after a new workspace; rows:",
        json.dumps([[row.get("key"), row.get("selected")] for row in sidebar_rows(run)][:20]))
    return None


def background_row(run, session):
    """Opens `session` in a new workspace without showing it (no focus: its pane is made when it shows) and
    waits, bounded, for the workspace's sidebar row; (its workspace id, row, error). The id is the row's (`row` of
    debug.mouse and goToWorkspace take it), which holds the open's key and may qualify it by machine."""
    key = str(uuid.uuid4())
    opened = run.app.action("agent.openSessionWorkspace", wait=False, session=session, key=key)
    if opened.get("error"):
        return None, None, f"open: {opened}"
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        row = next((r for r in sidebar_rows(run) if key in (workspace_id(r) or "") and r.get("in_list")), None)
        if row and row.get("selected"):
            return workspace_id(row), row, "the background open showed its workspace: the click would measure nothing"
        if row:
            return workspace_id(row), row, None
        time.sleep(0.05)  # test script: the workspace is not listed yet
    return key, None, "the workspace's sidebar row never appeared"


def watch_layout(run, out, stop_at):
    """From the click until `stop_at` (monotonic): asks the shown chat's page for its `layout_watch` once a page
    shows one (before the click the shown workspace has none, so the ask fails at once and is asked again).
    One watch runs; the thread ends with it or at `stop_at`."""
    started = time.monotonic()
    while time.monotonic() < stop_at:
        asked = time.monotonic()
        asked_wall = time.time()
        reply = run.rpc("debug.agent_pane", {"action": "layout_watch", "ms": max(100, opts.strip_ms - 200)}, timeout=20)
        if isinstance(reply, dict) and not reply.get("error") and "frames" in reply:
            out["watch"], out["watch_asked"], out["watch_asked_wall"] = reply, asked, asked_wall
            return
        out["watch_error"] = reply
        errors = out.setdefault("watch_errors", [])
        text = json.dumps(reply, default=str)[:300]
        if not errors or errors[-1]["error"] != text:  # each distinct answer once, with when it was asked and how long it took
            errors.append({"asked_ms": round((asked - started) * 1000), "took_ms": round((time.monotonic() - asked) * 1000), "error": text})
        time.sleep(0.033)  # test script: no page shows the chat yet (a few asks a frame would load the main actor)


def frame_pictures(folder, frames, record, width=640, names=None):
    """The frame before the click, the first-content frame, the final frame and the last frame of a strip, each as
    a PNG at most `width` px wide in base64 (sips; macOS), keyed by name: pixel evidence of what the click drew, in
    the one file a fleet step returns. A frame that could not be read is left out."""
    import base64
    rows = [f for f in frames or [] if f.get("file")]
    picks = {name: next((f for f in rows if f["ms"] == ms), None) for name, ms in names.items()} if names else {
             "before": next((f for f in reversed(rows) if isinstance(f["ms"], (int, float)) and f["ms"] <= 0), None),
             "first_content": next((f for f in rows if f["ms"] == record.get("first_content_ms")), None),
             "final": next((f for f in rows if f["ms"] == record.get("final_frame_ms")), None),
             "last": rows[-1] if rows else None}
    out = {}
    for name, row in picks.items():
        source = os.path.join(folder, row["file"]) if row else None
        if not source or not os.path.exists(source):
            continue
        small = os.path.join(folder, f"small-{name}.png")
        done = subprocess.run(["sips", "-Z", str(width), source, "--out", small], capture_output=True, timeout=30)
        path = small if done.returncode == 0 and os.path.exists(small) else source
        with open(path, "rb") as handle:
            out[name] = {"ms": row["ms"], "png_base64": base64.b64encode(handle.read()).decode()}
    return out


def frame_click(run, key, label, keep=False):
    """Clicks the sidebar row of workspace `key` inside a frame strip and judges the frames (chat_open_frames)."""
    import threading
    out = {}
    # The page's debug hook may take up to 5 s to come (DebugAgentPane.script): the watch may ask that long past the strip.
    stop_at = time.monotonic() + opts.strip_ms / 1000 + 6
    watcher = threading.Thread(target=watch_layout, args=(run, out, stop_at), daemon=True)
    folder = os.path.join(tempfile.gettempdir(), f"chat-open-click-{os.getpid()}", label)
    params = {"action": "frame_strip", "gesture": "mouse", "mouse": {"row": key, "action": "click"}, "above": True,
              "duration_ms": opts.strip_ms, "dir": folder, "tolerance": opts.strip_tolerance}
    watcher.start()
    # frame_strip clicks 120 ms after it starts recording (DebugFrameStrip's lead), or once ScreenCaptureKit's first
    # frame is in when that is later: the click's monotonic time, corrected from the reply's lead_ms.
    asked = time.monotonic()
    asked_wall = time.time()
    clicked = asked + 0.12
    strip = run.rpc("debug.new_tab", params, timeout=opts.strip_ms / 1000 + 60) or {}
    if isinstance(strip.get("lead_ms"), (int, float)):
        clicked = asked + strip["lead_ms"] / 1000
    watcher.join(timeout=max(0.0, stop_at - time.monotonic()) + 20)
    if strip.get("error"):
        shutil.rmtree(folder, ignore_errors=True)
        return {"error": f"frame_strip: {strip.get('error')}", "click": strip.get("key")}
    record = cof.final_frame(strip.get("frames"), settle_frames=opts.settle_frames, tolerance=opts.strip_tolerance)
    if keep:
        record["pictures"] = frame_pictures(folder, strip.get("frames"), record)
        # The same moment through the screen (screencapture, this script's own capture), to check the app's frames
        # show the chat's page pixels: a capture without them shows the pane empty.
        screen = os.path.join(folder, "screen.png")
        shot = subprocess.run(["screencapture", "-x", "-t", "png", screen], capture_output=True, text=True, timeout=30)
        if shot.returncode == 0 and os.path.exists(screen):
            record["pictures"].update(frame_pictures(folder, [{"ms": "screen", "file": "screen.png"}], {}, names={"screen": "screen"}))
        else:
            record["screen_error"] = f"screencapture exited {shot.returncode}: {(shot.stderr or shot.stdout).strip()[:300]}"
    shutil.rmtree(folder, ignore_errors=True)  # the PNGs: the numbers per frame, and the kept pictures, are the evidence
    # How the frames were read: screencapturekit has the Chromium page's pixels without the Screen Recording grant;
    # window_list without the grant shows the pane empty (cmuxterm-hq#6338).
    record.update({"capture": strip.get("capture"), "capture_error": strip.get("capture_error")})
    record.update({"click": strip.get("key"), "frame_count": strip.get("frame_count"),
                   "mean_interval_ms": strip.get("mean_interval_ms"), "strip_settled_ms": strip.get("settled_ms"),
                   "strip_first_change_ms": strip.get("first_change_ms"), "spans": strip.get("spans"),
                   "frames": [[f.get("ms"), round(f.get("content_vs_before") or 0, 4), round(f.get("content_vs_final") or 0, 4),
                               round(f.get("flatness") or 0, 4), bool(f.get("blank"))] for f in strip.get("frames") or []],
                   "frames_columns": ["ms", "content_vs_before", "content_vs_final", "flatness", "blank"],
                   "layout_watch": out.get("watch"), "drift": cof.row_drift(out.get("watch")),
                   "watch_asked_ms": round((out["watch_asked"] - clicked) * 1000) if out.get("watch_asked") else None,
                   "watch_started_ms": cof.watch_started_ms(out.get("watch"), out.get("watch_asked"), clicked,
                                                            asked_wall + (clicked - asked))})
    record["transcript_ms"] = cof.transcript_ms(out.get("watch"), record["watch_started_ms"], opts.strip_ms)
    record["layout_watch_errors"] = out.get("watch_errors")  # the asks before one answered too: why the watch started late
    if not out.get("watch"):
        record["layout_watch_error"] = out.get("watch_error")
    # Rows the page added after its first paint are a second view: the first frame was not the final one.
    if (record.get("drift") or {}).get("rows_appeared_later"):
        record["first_is_final"] = False
    return record


def measure_click(run, case, session, base, label, index=0):
    """One click case: the chat's workspace made in the background (`click`), or shown once and left
    (`click_again`), then a click on its row from the workspace `base`, which shows no chat."""
    key, row, error = background_row(run, session)
    if error:
        return {"error": error, "row": row}
    if case == "click_again":
        run.app.action("goToWorkspace", focus=True, workspace=key)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            ready = run.rpc("debug.agent_pane", {"action": "readiness"}) or {}
            if (ready.get("body_text_length") or 0) > 0:
                break
            time.sleep(0.3)  # test script: waiting for the chat to show
        time.sleep(1.5)  # test script: let the page's own reads finish before it is left
        run.app.action("goToWorkspace", focus=True, workspace=base)
        time.sleep(1)  # test script: the page hands its tail over as it leaves
    else:
        time.sleep(0.5)  # test script: the new row settles (its own motion is not the chat's)
        # Still not selected right before the click, after the settle (a late auto-select would leave the click
        # nothing to change; cmux#33845).
        if next((r.get("selected") for r in sidebar_rows(run) if workspace_id(r) == key), False):
            return {"error": "the chat's workspace was shown before the click: the click would measure nothing", "row": row}
    record = frame_click(run, key, label, keep=index < opts.keep_frames)
    record["workspace"] = key
    # Back to the workspace with no chat, so the next click starts from the same picture.
    run.app.action("goToWorkspace", focus=True, workspace=base)
    time.sleep(0.5)  # test script: the switch back settles
    return record


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


def write_results(results):
    """Prints the table and writes --json and --md; the table. main calls it before teardown."""
    table = markdown(results)
    print("CHAT-OPEN-TABLE-BEGIN\n" + table + "\nCHAT-OPEN-TABLE-END", flush=True)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        with open(opts.json, "w") as handle:
            json.dump(results, handle, indent=1)
    if opts.md:
        with open(opts.md, "w") as handle:
            handle.write(table + "\n")
    return table


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
            base = shown_workspace(run)
            for case in [c for c in CASES if c != "restore"]:
                if case in ("big", "bloated") and not sessions[condition][case]:
                    continue
                records = []
                for index in range(opts.runs):
                    if case in CLICK_CASES:
                        record = measure_click(run, case, sessions[condition][case][index], base, f"{condition}-{case}-{index}", index) \
                            if base else {"error": "no shown workspace to click from"}
                        records.append(record)
                        say(f"chat-open: {condition} {case} {index}: first_content_frame_ms={record.get('first_content_ms')} "
                            f"final_frame_ms={record.get('final_frame_ms')} first_is_final={record.get('first_is_final')} "
                            f"between={record.get('between_frames')} blank={record.get('blank_frames')} "
                            f"transcript_ms={record.get('transcript_ms')} watch_started_ms={record.get('watch_started_ms')} "
                            f"drift={json.dumps(record.get('drift'))}" + (f" error={str(record['error'])[:300]}" if record.get("error") else ""))
                        continue
                    record = measure_case(run, case, sessions[condition], index)
                    record["invalid_reason"] = invalid_reason(record)
                    records.append(record)
                    say(f"chat-open: {condition} {case} {index}: first_content_ms={record.get('first_content_ms')} "
                        f"empty={record.get('longest_empty_ms')} flashes={record.get('flashes')}{why(record)}")
                results["raw"].setdefault(condition, {})[case] = records
                results["cases"].setdefault(condition, {})[case] = (cof.summarize if case in CLICK_CASES else summarize)(records)
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
                    record["invalid_reason"] = invalid_reason(record)
                    records.append(record)
                    say(f"chat-open: {condition} restore {index}: first_content_ms={record.get('first_content_ms')} "
                        f"first_image_ms={record.get('first_image_ms')} saved_pictures={pictures}{why(record)}")
                results["raw"].setdefault(condition, {})["restore"] = records
                results["cases"].setdefault(condition, {})["restore"] = summarize(records)
            load.stop()
            time.sleep(3)  # test script: the machine settles between conditions
    finally:
        load.stop()
        try:
            table = write_results(results)  # before teardown: a teardown that stalls never loses the run
        except Exception as error:  # noqa: BLE001 - a report that fails must not hide the run's own error
            say(f"chat-open: writing the results failed: {error!r}")
            table = None
        teardown = time.monotonic()
        if run:
            run.end()
        if opts.record_launch and os.path.isdir(frames_root):
            os.makedirs(os.path.dirname(os.path.abspath(opts.launch_frames)), exist_ok=True)
            # make_archive adds the suffix itself: the path it returns is the one written.
            archive = shutil.make_archive(os.path.abspath(opts.launch_frames).removesuffix(".tar.gz"), "gztar", frames_root)
            say(f"chat-open: launch frames in {archive}")
        shutil.rmtree(root, ignore_errors=True)
        say(f"chat-open: teardown {time.monotonic() - teardown:.1f} s")
    if table is None:
        raise SystemExit("chat-open: no results written")
    failed = [f"{condition} {case}" for condition, cases in results["cases"].items()
              for case, summary in cases.items() if not summary.get("complete")]
    if failed:
        raise SystemExit("chat-open: incomplete measurements (an open with no first content or no empty time): "
                         + ", ".join(failed))


def markdown(results):
    lines = [f"chat-open-bench on {results['host']} ({results['model']}, {results['ncpu']} CPUs); "
             f"median of {opts.runs} opens, milliseconds from the action to the first frame of chat content; "
             f"a cell reads FAILED when an open of its case timed out, errored, or showed no content or no empty time "
             f"(no median over the rest); click rows are from pixels: click to first content frame and to final frame "
             f"(the first of {opts.settle_frames}+ frames equal to the last), how many clicks drew the final frame first, "
             f"frames between, blank frames, and the most px a transcript row moved after first paint",
             "", "| case | " + " | ".join(CONDITIONS) + " |", "|---|" + "---|" * len(CONDITIONS)]
    for case in CASES:
        cells = []
        for condition in CONDITIONS:
            s = results["cases"].get(condition, {}).get(case)
            if not s:
                cells.append("–")
                continue
            cells.append(cof.cell(s) if case in CLICK_CASES else cell(s, case))
        lines.append(f"| {case} | " + " | ".join(cells) + " |")
    lines += ["", "load average per condition: " + ", ".join(f"{c} {v}" for c, v in results.get("load_avg", {}).items())]
    return "\n".join(lines)


if __name__ == "__main__":
    main()
