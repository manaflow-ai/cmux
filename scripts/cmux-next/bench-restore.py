#!/usr/bin/env python3
"""Restore bench: what the person sees in the first seconds after cmux NEXT relaunches with a saved
session (Lawrence 2026-10-27: three visible terminals empty with "Restoring..." under ~60 workspaces).

Run it on the GUI host where a tagged build already runs in a capture slot (bench-restore-slot.sh
does the whole slot run from the fleet VM). It seeds a session, quits the app through its own quit
(sessions kept), relaunches it with the same launch environment and samples the visible panes over
the control socket from the moment the socket answers.

  scripts/cmux-next/bench-restore.py --socket SOCK --out DIR [--workspaces 1,60,600]
      [--modes warm,restart,cold] [--runs 3] [--slow-ms 150] [--max-seconds 500]

Seeded session (all names `rr-*`): one shown workspace `rr-shown` of three terminal panes, as in the
screenshot: a local shell (`local`), and two shells that answer slowly (`remote-a`, `remote-b`:
restore_slow_remote.py, a remote shell DELAY_MS away, as an ssh tab to a far host). Each prints its
own marker lines. Then N-1 hidden workspaces `rr-bg-<i>` of one terminal each. `rr-shown` is the
shown one at quit.

Modes (what ended before the relaunch):
  warm     only the app quit (Quit, keep sessions): daemon and terminal hosts run on;
  restart  the app quit, then its cmux-tui daemon was killed (SIGKILL): the relaunched app starts a
           new daemon that adopts the running terminal hosts (an update's daemon handoff, a daemon crash);
  cold     the app quit, then every process of its bundle was killed (daemon, hosts, shells), as a
           reboot or logout does.

Per run (times are ms since the relaunched process started, PROC_PIDTBSDINFO):
  first_frame        launch mark first_window_frame_committed
  sidebar_rows       launch mark sidebar_rows_shown
  socket             the first control-socket answer (samples start here)
  per pane: content  first sample whose pane shows content (a held last frame or a replayed screen)
            marker   first sample whose viewport text shows the pane's marker (its last screen)
            live     first sample whose attach is live (link connected, replay applied)
            pill     first sample whose banner says Restoring (and whether content was under it)
  blank_samples      samples where a visible pane showed neither a held frame nor content, with the
                     ms they cover (blank_ms) and frames at 60 Hz (blank_frames, from blank_ms)
  first_frame_content  the last-frame picture was up by the first frame (terminal.launch_frame_shown
                     <= first_window_frame_committed), or the first frame already had live content
  typed              keys typed into the focused pane right after the socket answered (during restore):
                     ms from the type to their echo in the app's view, and ms after that pane was live
  live_terminals     terminal views attached when settled (hidden workspaces must not attach)

Samples come every ~25 ms while restore runs (`debug.surfaces`, text on), so a state shorter than
that can be missed; frames before the socket answers are judged from the launch marks only.
Writes DIR/runs.jsonl (one line per run) and DIR/summary.json (p50/p95/max per metric).
Stdlib only (stock /usr/bin/python3). Never touches an app other than the slot's tagged build.
"""
import argparse
import ctypes
import json
import os
import plistlib
import re
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_names  # noqa: E402

ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
ap.add_argument("--socket", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--workspaces", default="60", help="comma list of session sizes (workspaces in all)")
ap.add_argument("--modes", default="warm,restart,cold")
ap.add_argument("--runs", type=int, default=3)
ap.add_argument("--slow-ms", type=int, default=150, help="the slow remote's one-way delay")
ap.add_argument("--sample-seconds", type=float, default=12.0, help="how long a launch is sampled at most")
ap.add_argument("--max-seconds", type=float, default=520.0, help="stop starting runs after this long")
ap.add_argument("--activate", action="store_true", help="relaunch activated (a key window), as a person's Dock click")
ap.add_argument("--allow-non-slot", action="store_true")
ap.add_argument("--snapshots", action="store_true", help="three window snapshots after restore settles (DIR/window-*.png)")
ap.add_argument("--relaunch-delay", type=float, default=0.5, help="seconds between the old app's end and the reopen")
ap.add_argument("--sample-app", action="store_true",
                help="`sample` the relaunched app process for its first 3 s (DIR/app-sample-MODE-nN-RUN.txt)")
ap.add_argument("--sample-daemon", action="store_true",
                help="in restart and cold launches, `sample` the new daemon for 6 s (DIR/daemon-sample-MODE-nN-RUN.txt)")
opts = ap.parse_args()
os.makedirs(opts.out, exist_ok=True)
STARTED = time.time()
NONCE = os.urandom(3).hex()
LOG = open(os.path.join(opts.out, "bench.log"), "a")
SLOW_REMOTE = os.path.join(HERE, "restore_slow_remote.py")


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(time.strftime("%H:%M:%S ") + line + "\n")
    LOG.flush()


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if os.getppid() == 1:
            sys.exit("bench-restore: parent gone")
        got = predicate()
        if got:
            return got
        time.sleep(step)
    return None


# ---- process start (PROC_PIDTBSDINFO) -------------------------------------------------------

class ProcBSDInfo(ctypes.Structure):
    _fields_ = [("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32), ("pbi_xstatus", ctypes.c_uint32),
                ("pbi_pid", ctypes.c_uint32), ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
                ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32), ("pbi_rgid", ctypes.c_uint32),
                ("pbi_svuid", ctypes.c_uint32), ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
                ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32), ("pbi_nfiles", ctypes.c_uint32),
                ("pbi_pgid", ctypes.c_uint32), ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
                ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32), ("pbi_start_tvsec", ctypes.c_uint64),
                ("pbi_start_tvusec", ctypes.c_uint64)]


def process_start(pid):
    """Wall-clock seconds when the kernel started `pid`, or None."""
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    except OSError:
        return None
    info = ProcBSDInfo()
    size = libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info))  # PROC_PIDTBSDINFO
    if size != ctypes.sizeof(info):
        return None
    return info.pbi_start_tvsec + info.pbi_start_tvusec / 1e6


# ---- the app: identity, environment, quit, relaunch ----------------------------------------

class App:
    def __init__(self):
        self.refresh()
        self.bundle = self.info.get("app_bundle_path")
        self.cli = self.info.get("app_cli_path") or os.path.join(self.bundle, "Contents/Resources/bin/cmux")
        self.tag = self.info.get("tag")
        self.bundle_id = self.info.get("bundle_id") or ""
        self.env = self.environment(self.pid)
        problems = []
        if not self.tag:
            problems.append("no tag")
        if ".debug" not in self.bundle_id:
            problems.append(f"bundle id {self.bundle_id!r} is not a DEV build's")
        if not self.bundle or self.bundle.startswith("/Applications/"):
            problems.append(f"bundle {self.bundle!r} is an installed app")
        if not opts.allow_non_slot and "capslot" not in self.bundle_id and not self.env.get("CMUX_CAPTURE_SLOT"):
            problems.append("not a capture slot's app")
        if problems:
            sys.exit("bench-restore refuses this app: " + "; ".join(problems))
        say(f"app pid {self.pid} tag {self.tag} id {self.bundle_id} config {self.info.get('build_configuration')}")

    def refresh(self):
        info = rpc("system.identify")
        if not isinstance(info, dict) or "error" in info or not info.get("pid"):
            sys.exit(f"no app answers on {opts.socket}: {info}")
        self.info, self.pid = info, int(info["pid"])

    @staticmethod
    def environment(pid):
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
        env = {}
        for word in out.split():
            key, sep, val = word.partition("=")
            if sep and (key.startswith("CMUX_") or key in ("HOME", "TMPDIR")):
                env[key] = val
        return env

    def alive(self, pid=None):
        try:
            os.kill(pid or self.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def sessions(self):
        names = None
        try:
            names = build_names.of_app(self.bundle)
        except ValueError:
            pass
        return [s for s in ((names or {}).get("session"), f"cmux-app-{self.tag}") if s]

    def procs(self):
        table = subprocess.run(["ps", "axo", "pid=,ppid=,args="], capture_output=True, text=True).stdout
        rows = []
        for line in table.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
                rows.append((int(parts[0]), int(parts[1]), parts[2]))
        return rows

    def daemon_pids(self):
        return [pid for pid, _, args in self.procs() if args.startswith(self.bundle + "/") and "--headless" in args
                and any(f"--session {s} " in args + " " for s in self.sessions())]

    def daemon_socket(self):
        for _, _, args in self.procs():
            if args.startswith(self.bundle + "/") and "--headless" in args and any(f"--session {s} " in args + " " for s in self.sessions()):
                m = re.search(r"--socket (\S+)", args)
                if m:
                    return m.group(1)
        return None

    def cli_call(self, *args, timeout=60):
        sock = self.daemon_socket()
        if not sock:
            return {"error": "no daemon socket"}
        env = {"HOME": self.env.get("HOME", os.environ["HOME"]), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
        r = subprocess.run([self.cli, "--socket", sock, "--json", *args], capture_output=True, text=True, timeout=timeout, env=env)
        try:
            answer = json.loads(r.stdout)
        except ValueError:
            answer = {"error": (r.stdout + r.stderr).strip()[:300]}
        return answer.get("value", answer) if isinstance(answer, dict) else {}

    def quit_keep_sessions(self):
        rpc("action.run", {"action": "quitKeepSessions"}, timeout=30)
        ended = wait(lambda: not self.alive(), 60, 0.1)
        say(f"  quit: pid {self.pid} {'exited' if ended else 'STILL RUNNING'}")
        return bool(ended)

    def kill_daemon(self):
        pids = self.daemon_pids()
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        wait(lambda: not any(self.alive(p) for p in pids), 10, 0.1)
        say(f"  restart: killed daemon {pids}")
        return pids

    def power_off(self):
        procs = self.procs()
        roots = {pid for pid, _, args in procs if args.startswith(self.bundle + "/") and pid != os.getpid()}
        if self.bundle_id:
            owner = f"--owner {self.bundle_id}:"
            roots |= {pid for pid, _, args in procs if "--bootstrap-stdio" in args and owner in args}
        doomed, grew = set(roots), True
        while grew:
            more = {pid for pid, ppid, _ in procs if ppid in doomed and pid not in doomed and pid != os.getpid()}
            doomed |= more
            grew = bool(more)
        for pid in doomed:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        wait(lambda: not any(self.alive(p) for p in doomed), 20, 0.1)
        say(f"  cold: killed {len(doomed)} processes of the bundle")
        return len(doomed)

    def relaunch(self):
        """Opens the app again as a Dock click does; returns the wall time of the open."""
        if os.path.exists(opts.socket):
            os.unlink(opts.socket)
        args = ["/usr/bin/open", "-n", "-a", self.bundle] if opts.activate else ["/usr/bin/open", "-g", "-n", "-a", self.bundle]
        for key, val in self.env.items():
            if opts.activate and key == "CMUX_NEXT_NO_ACTIVATE":
                continue
            args += ["--env", f"{key}={val}"]
        opened = time.time()
        subprocess.run(args, check=True)
        return opened


# ---- seeding ------------------------------------------------------------------------------------

PANES = ("local", "remote-a", "remote-b")


def marker(pane):
    return f"rr-{pane}-{NONCE}"


def write(app, term, text):
    return app.cli_call("terminal", term, "write", "--text", text)


def seed(app, workspaces):
    topo = (rpc("snapshot.get") or {}).get("topology") or {}
    for ws in topo.get("workspaces", []):
        if (ws.get("name") or "").startswith("rr-"):
            app.cli_call("workspace", ws["id"], "close")
    shown = app.cli_call("workspace", "create", "--name", "rr-shown")
    terms = {"local": shown.get("terminal_id")}
    right = app.cli_call("pane", shown.get("pane_id", ""), "split", "--right")
    terms["remote-a"] = right.get("terminal_id")
    down = app.cli_call("pane", right.get("pane_id", ""), "split", "--down")
    terms["remote-b"] = down.get("terminal_id")
    if not all(terms.values()):
        sys.exit(f"seeding the shown workspace failed: {terms}")
    slow = f"python3 {shlex.quote(SLOW_REMOTE)} {opts.slow_ms} 'remote$ '"
    for pane in ("remote-a", "remote-b"):
        write(app, terms[pane], f"exec {slow}\n")
    time.sleep(1.5)
    for pane, term in terms.items():
        # A full screen of the pane's own lines: its last screen is unmistakable in the view's text.
        write(app, term, f"for i in $(seq 1 40); do echo {marker(pane)}-$i; done\n")
    for i in range(1, workspaces):
        ws = app.cli_call("workspace", "create", "--name", f"rr-bg-{i}")
        if ws.get("terminal_id"):
            write(app, ws["terminal_id"], f"echo rr-bg-{i}-{NONCE}\n")
    app.cli_call("workspace", shown["workspace_id"], "focus")
    app.cli_call("pane", shown["pane_id"], "focus")
    ok = wait(lambda: all(marker(p) + "-40" in (pane_text(p) or "") for p in PANES), 30, 0.5)
    say(f"  seeded {workspaces} workspaces; shown panes {'show their markers' if ok else 'DID NOT show their markers'}")
    return shown["workspace_id"], terms


def shown_panes():
    """The panes of the shown workspace's window, by which marker their terminal shows (None: none yet)."""
    report = rpc("debug.surfaces", {"text": True}, timeout=10)
    if not isinstance(report, dict) or "error" in report:
        return report, []
    panes = []
    for window in report.get("windows", []):
        for pane in window.get("panes", []):
            if pane.get("visible"):
                panes.append(pane)
    return report, panes


TERM_OF_PANE = {}


def pane_text(name):
    _, panes = shown_panes()
    for pane in panes:
        if marker(name) in (pane.get("text") or ""):
            return pane.get("text")
    return None


# ---- one measured launch ------------------------------------------------------------------------

def classify(pane):
    """Which seeded pane this is: by its marker, else by its remembered pane key."""
    text = pane.get("text") or ""
    for name in PANES:
        if marker(name) in text:
            TERM_OF_PANE[pane.get("pane")] = name
            return name
    return TERM_OF_PANE.get(pane.get("pane"))


def sample_new_daemon(app, old, path, seconds=6):
    """Waits up to 10 s for a daemon of the app's session that is not in `old`, then `sample`s it."""
    deadline = time.time() + 10
    while time.time() < deadline:
        new = [p for p in app.daemon_pids() if p not in old]
        if new:
            subprocess.run(["/usr/bin/sample", str(new[0]), str(seconds), "-mayDie", "-file", path],
                           capture_output=True, timeout=seconds + 30)
            return
        time.sleep(0.02)


def sample_new_app(app, old_pid, path, seconds=3):
    """Waits up to 5 s for a new process of the app's executable (not `old_pid`), then `sample`s it at once."""
    exe = os.path.join(app.bundle, "Contents", "MacOS")
    deadline = time.time() + 5
    while time.time() < deadline:
        for pid, _, args in app.procs():
            if pid != old_pid and args.startswith(exe + "/"):
                subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "1", "-mayDie", "-file", path],
                               capture_output=True, timeout=seconds + 30)
                return
        time.sleep(0.002)


# Front to back: one line per on-screen window at layer 0 (owner, pid, x, y, w, h).
WINDOW_ORDER_JXA = """
ObjC.import('CoreGraphics');
const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
list.filter(w => w.kCGWindowLayer === 0).map(w => [w.kCGWindowOwnerName, w.kCGWindowOwnerPID, w.kCGWindowBounds.X,
  w.kCGWindowBounds.Y, w.kCGWindowBounds.Width, w.kCGWindowBounds.Height].join(' ')).join('\\n');
"""


def saved_frames(app):
    """The terminal frames the last quit saved (`terminal-launch-frames` beside the build's sidebar snapshot), by name and size."""
    home = app.env.get("HOME", os.environ["HOME"])
    root = os.path.join(home, "Library", "Application Support")
    found = []
    for base, dirs, files in os.walk(root):
        if os.path.basename(base) == "terminal-launch-frames":
            found += [[os.path.join(base, f), os.path.getsize(os.path.join(base, f))] for f in sorted(files)]
        if base.count(os.sep) - root.count(os.sep) >= 3:
            dirs[:] = []
    return found


def measure(app, mode, workspaces, run):
    if not app.quit_keep_sessions():
        return None
    frames_saved = saved_frames(app)
    if mode == "restart":
        app.kill_daemon()
    elif mode == "cold":
        app.power_off()
    time.sleep(opts.relaunch_delay)
    sampler = None
    if opts.sample_daemon and mode in ("restart", "cold"):
        path = os.path.join(opts.out, f"daemon-sample-{mode}-n{workspaces}-{run}.txt")
        sampler = threading.Thread(target=sample_new_daemon, args=(app, set(app.daemon_pids()), path), daemon=True)
        sampler.start()
    app_sampler = None
    if opts.sample_app:
        path = os.path.join(opts.out, f"app-sample-{mode}-n{workspaces}-{run}.txt")
        app_sampler = threading.Thread(target=sample_new_app, args=(app, app.pid, path), daemon=True)
        app_sampler.start()
    opened = app.relaunch()
    pid = None
    socket_at = None
    deadline = opened + 60
    while time.time() < deadline:
        answer = rpc("system.identify", timeout=1)
        if isinstance(answer, dict) and answer.get("pid"):
            pid, socket_at = int(answer["pid"]), time.time()
            break
        time.sleep(0.005)
    if not pid:
        say("  the relaunched app never answered")
        return {"mode": mode, "workspaces": workspaces, "run": run, "error": "no socket"}
    app.refresh()
    start = process_start(pid) or opened

    def ms(t):
        return round((t - start) * 1000, 1)

    # Keys typed at once, during restore, into whatever pane has the keyboard (the focused shown pane).
    typed_text = f"echo rr-typed-{NONCE}-{run}"
    typed_at = time.time()
    for ch in typed_text:
        rpc("debug.key", {"key": ch, "modifiers": []}, timeout=5)
    rpc("debug.key", {"key": "return", "modifiers": []}, timeout=5)
    typed_done = time.time()
    typed_echo = f"rr-typed-{NONCE}-{run}"

    first = {name: {} for name in PANES}
    blank_samples = blank_ms = samples = 0
    pill_over_blank = 0
    last_t = None
    focused_name = None
    echo_at = None
    end = socket_at + opts.sample_seconds
    report = {}
    trace = []
    while time.time() < end:
        t = time.time()
        report, panes = shown_panes()
        samples += 1
        any_blank = False
        for pane in panes:
            name = classify(pane)
            if name is None:
                # A visible pane that shows no marker yet: no content (blank, or a held frame).
                pass
            held = bool(pane.get("frame_held"))
            surface = pane.get("surface") or {}
            replayed = bool(surface.get("replay_applied"))
            text = pane.get("text") or ""
            has_content = held or (replayed and text.strip() != "")
            if not has_content:
                any_blank = True
            status = pane.get("status_text") or ""
            if "Restoring" in status and not has_content:
                pill_over_blank += 1
            if name is None:
                continue
            row = first[name]
            if has_content and "content" not in row:
                row["content"] = ms(t)
                row["content_by"] = "held_frame" if held and not replayed else "screen"
            if marker(name) in text and "marker" not in row:
                row["marker"] = ms(t)
            if pane.get("link") == "connected" and replayed and pane.get("attach") in ("live", None) and "live" not in row:
                row["live"] = ms(t)
                row["attach_at_live"] = pane.get("attach")
            if "Restoring" in status and "pill" not in row:
                row["pill"] = ms(t)
                row["pill_over_content"] = has_content
            row["last_link"] = pane.get("link")
            row["last_attach"] = pane.get("attach")
            if pane.get("focused"):
                focused_name = name
            if typed_echo in text and echo_at is None:
                echo_at = t
        trace.append([ms(t)] + [[classify(p), int(bool(p.get("frame_held"))), p.get("last_frame_holds"),
                                  int(bool((p.get("surface") or {}).get("replay_applied"))), p.get("link"), p.get("attach"),
                                  p.get("status_text"), p.get("phase"), p.get("snapshots"),
                                  {k: (p.get("surface") or {}).get(k) for k in ("drawing", "rendering_suspended", "paused", "in_window",
                                                                              "hidden", "layer_size", "grid", "drawn_grid")},
                                  {"frames": ((p.get("surface") or {}).get("render_counters") or {}).get("frames"),
                                   "occluded": p.get("window_occluded"), "drawable": p.get("window_drawable"),
                                   "content_visible": p.get("content_visible"), "presence": p.get("presence")}] for p in panes])
        if any_blank or not panes:
            blank_samples += 1
            if last_t is not None:
                blank_ms += (t - last_t) * 1000
        last_t = t
        done = all("live" in first[n] and "marker" in first[n] for n in PANES) and echo_at is not None
        if done:
            break
        time.sleep(0.02)
    if opts.snapshots:
        # The window server's on-screen windows, front to back: whether another app's window covers ours.
        order = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", WINDOW_ORDER_JXA], capture_output=True, text=True, timeout=60)
        with open(os.path.join(opts.out, f"order-{mode}-n{workspaces}-{run}.txt"), "w") as f:
            f.write(order.stdout + order.stderr)
        for i in range(3):
            path = os.path.join(opts.out, f"window-{mode}-n{workspaces}-{run}-{i}.png")
            rpc("debug.window_snapshot", {"path": path}, timeout=20)
            time.sleep(1.0)
    timings = rpc("debug.timings", timeout=10) or {}
    marks = timings.get("launch_ms_since_process_start") or {}
    first_frame = marks.get("first_window_frame_committed")
    launch_frame = marks.get("terminal.launch_frame_shown")
    live_terminals = None
    settled = wait(lambda: (lambda r: r if isinstance(r, dict) and "live_terminals" in r else None)(rpc("debug.surfaces", timeout=10)), 5, 0.5)
    if settled:
        live_terminals = settled.get("live_terminals")
    focused_live = first.get(focused_name or "local", {}).get("live")
    row = {
        "mode": mode, "workspaces": workspaces, "run": run, "pid": pid,
        "open_to_start_ms": round((start - opened) * 1000, 1),
        "socket": ms(socket_at), "first_frame": first_frame, "sidebar_rows": marks.get("sidebar_rows_shown"),
        "first_terminal_frame": marks.get("first_terminal_frame"), "launch_frame_shown": launch_frame,
        "launch_frame_missed": marks.get("terminal.launch_frame_missed"),
        "first_frame_content": bool(launch_frame is not None and first_frame is not None and launch_frame <= first_frame + 0.5),
        "panes": first, "samples": samples, "blank_samples": blank_samples, "blank_ms": round(blank_ms, 1),
        "blank_frames_60hz": int(round(blank_ms / (1000 / 60))), "pill_over_blank_samples": pill_over_blank,
        "typed": {"sent_ms": ms(typed_at), "sent_end_ms": ms(typed_done), "focused": focused_name,
                  "echo_ms": ms(echo_at) if echo_at else None,
                  "echo_after_live_ms": round(ms(echo_at) - focused_live, 1) if echo_at and focused_live else None},
        "live_terminals": live_terminals, "blank_panes_settled": (settled or {}).get("blank_panes"),
        "marks": marks,
        "trace": trace,
        "frames_saved": frames_saved,
        "launch_clock": timings.get("launch_clock"), "launch_counters": timings.get("launch_counters"),
        "startup": rpc("debug.startup", timeout=10),
    }
    if sampler:
        sampler.join(timeout=40)
    if app_sampler:
        app_sampler.join(timeout=40)
    say(f"  {mode} n={workspaces} run {run}: first frame {first_frame} ms, socket {row['socket']} ms, "
        + ", ".join(f"{n} content {first[n].get('content')} live {first[n].get('live')} pill {first[n].get('pill')}" for n in PANES)
        + f"; blank {blank_samples}/{samples} samples ({row['blank_ms']} ms); typed echo {row['typed']['echo_ms']}"
        + f" (+{row['typed']['echo_after_live_ms']} after live); live terminals {live_terminals}")
    return row


def percentile(values, q):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return round(vals[lo] + (vals[hi] - vals[lo]) * (k - lo), 1)


def summarize(rows):
    groups = {}
    for row in rows:
        if not row or row.get("error"):
            continue
        groups.setdefault(f"{row['mode']}-n{row['workspaces']}", []).append(row)
    out = {}
    for key, runs in groups.items():
        metrics = {"first_frame": [r["first_frame"] for r in runs], "sidebar_rows": [r["sidebar_rows"] for r in runs],
                   "socket": [r["socket"] for r in runs], "blank_ms": [r["blank_ms"] for r in runs],
                   "blank_frames_60hz": [r["blank_frames_60hz"] for r in runs],
                   "typed_echo_after_live": [r["typed"]["echo_after_live_ms"] for r in runs],
                   "live_terminals": [r["live_terminals"] for r in runs]}
        for name in PANES:
            for what in ("content", "marker", "live", "pill"):
                metrics[f"{name}.{what}"] = [r["panes"][name].get(what) for r in runs]
        out[key] = {"runs": len(runs),
                    "first_frame_content_runs": sum(1 for r in runs if r["first_frame_content"]),
                    "typed_lost_runs": sum(1 for r in runs if r["typed"]["echo_ms"] is None),
                    **{m: {"p50": percentile(v, 0.5), "p95": percentile(v, 0.95), "max": percentile(v, 1.0),
                           "missing": sum(1 for x in v if x is None)} for m, v in metrics.items()}}
    return out


def main():
    app = App()
    rows = []
    out_rows = open(os.path.join(opts.out, "runs.jsonl"), "a")
    for size in [int(s) for s in opts.workspaces.split(",") if s.strip()]:
        if time.time() - STARTED > opts.max_seconds:
            say(f"time is up before n={size}")
            break
        say(f"seeding {size} workspaces")
        seed(app, size)
        for mode in [m.strip() for m in opts.modes.split(",") if m.strip()]:
            for run in range(1, opts.runs + 1):
                if time.time() - STARTED > opts.max_seconds:
                    break
                row = measure(app, mode, size, run)
                if row is None:
                    break
                rows.append(row)
                out_rows.write(json.dumps(row) + "\n")
                out_rows.flush()
                # Let the restored session settle before the next quit (a quit mid-restore saves less).
                wait(lambda: all(marker(p) in (pane_text(p) or "") for p in PANES), 20, 0.5)
                time.sleep(1.0)
    summary = summarize(rows)
    with open(os.path.join(opts.out, "summary.json"), "w") as f:
        json.dump(summary, f, indent=1, sort_keys=True)
    say(json.dumps(summary, indent=1, sort_keys=True))
    return 0 if rows else 1


if __name__ == "__main__":
    sys.exit(main())
