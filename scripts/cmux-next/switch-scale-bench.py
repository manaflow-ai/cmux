#!/usr/bin/env python3
"""Switch at scale, app level (Lawrence 2026-10-28: "need to make sure changing spaces and screens, when there's a lot
of workspaces, groups, tabs, terminals, panes etc, is extremely fast"; /Users/lawrence/fun/wt/handoff/switch-scale.md).

The in-process half is SwitchScaleBench.swift (story swift-switch-scale). This half drives a running bench-config app
over its control socket, at 10 and 1,000 workspaces of the switch-at-scale fixture
(scripts/perf-lab/corpus/stories/switch_scale.py), and times every switch a person makes.

Bounded live realization (the full fixture has 159,505 tabs and 79,696 terminals at 1,000 workspaces; a Mac runs about
511 PTYs and every terminal is a daemon process):
  * real: all N workspaces (`ss-NNNN`), all spaces (rooms, `room create`) with each workspace pinned to its space
    (`room pin`), all groups (`workspace group create --room`, members added by `workspace group add`), 3 windows (each
    in its fixture space, showing its fixture workspace; the fixture's second display does not exist on a capture slot,
    so all 3 windows are on display 0).
  * HOT SET, full fixture shape: the first 2 workspaces of spaces 0 and 1 and the workspaces of windows 1 and 2. Every
    screen, every pane (the fixture's split tree, by `pane split` with even ratios) and every Chromium, WebKit and agent
    chat tab; terminal tabs up to --hot-terminals in all (a pane's first tab is always there; terminal tabs past the cap
    are not made and are counted). Every terminal prints `seq 1 10000` (10k lines of scrollback); the fixture's busy
    terminals then print a line every 20 ms. The hot workspaces stay out of groups and go to the top of their space's
    sidebar (palette.moveWorkspaceToTop), so Cmd-1/2 and Ctrl-Cmd-]/[ reach them. Tab order inside a pane follows the
    create order (kinds and counts are the fixture's).
  * every other workspace: one screen and no tab (`workspace create --empty`, as sidebar-stress-bench.py's create_plain).
The exact counts made are in results.json `realized`.

Switch kinds (--kinds; each --switches times, alternating forward and back between two hot targets):
  space              Cmd-Opt-] / Cmd-Opt-[ (space.next / space.previous) in window 0
  space_swipe        a horizontal two-finger swipe over the sidebar (debug.mouse scroll, dx, began/changed/ended)
  screen             screen.next / screen.previous (no default key: action.run; Cmd-Shift-]/[ is nextSurface, a tab key)
  workspace_click    a click on the sidebar row (debug.mouse)
  workspace_digit    Cmd-1 / Cmd-2 (selectWorkspaceByNumber)
  workspace_next     Ctrl-Cmd-] / Ctrl-Cmd-[ (nextSidebarTab / prevSidebarTab)
  workspace_palette  Cmd-P (goToWorkspace), the workspace's name, Return (timed from the Return)
  tab                Cmd-Shift-] / Cmd-Shift-[ (nextSurface / prevSurface) in the focused pane
  pane               Cmd-Opt-Right / Cmd-Opt-Left (focusRight / focusLeft)
  window             selectNextWindow / selectPreviousWindow (no default key: action.run; Cmd-` is the system's)
  home               home.show (no default key: action.run), back with Ctrl-Cmd-` (workspace.selectLastUsed)
  memory             1,000 Ctrl-Cmd-] steps through window 0's sidebar; the app's phys_footprint every 100

Per switch (even switches are "clean": no request until the switch window ends; odd ones are "sampled"):
  input_to_commit  the app's own timer row (debug.workspace_switch / debug.tab_switch / debug.pane_focus):
                   input_ms (the event's age at the intent; none for action.run) + commit_ms (to the Core Animation
                   commit that carries the new content); late_vsyncs is the frames it missed
  input_to_present clean: the input latency tracker's slot for the input (`debug.input` reset before, `slots` after;
                   builds with that action): the event to the presented frame after it, the largest slot of the switch
  content_seen     sampled: first debug.surfaces sample that shows the new target (an upper bound: sample period)
  main_busy        clean: the main run loop's busy ms in the frames of the switch window (debug.frames main_ms) less
                   the idle frames' median busy ms per frame; turn_ms is the timer's commit_ms
  blank            sampled: debug.surfaces every ~16 ms; a visible pane is blank when the app says so (`blank`) or a
                   terminal shows neither a held last frame nor replayed content (the restore bench's rule);
                   blank_frames = blank ms / refresh period
  keys_live        sampled: a marker typed with debug.key right after the input; ms until the focused terminal's
                   viewport text shows it (only when the focused pane is a terminal); lost = no echo 2.5 s after the
                   last key (the sample stops at 4 s); in a busy terminal (output every 20 ms) the echo scrolls out of
                   the viewport between samples, so such a switch is counted in keys_not_measured_busy, not lost
  missed           clean: frame intervals over 1.5 refresh periods in the switch window (debug.frames)

Writes OUT/results.json (p50/p99 per kind x size, every raw row) and result-v1 rows (story switch-scale, metrics
switch_scale.<kind>.<size>.<metric>) with BenchApp.record.

  On a GUI host with a launched app (perf-lab runner):
    switch-scale-bench.py --app APP --tag TAG --out DIR [--workspaces 10,1000] [--switches 200] [--kinds ...]
  Against an app a capture slot launched (one size per launch):
    switch-scale-bench.py --app CLONE --tag TAG --socket SOCK --out DIR --workspaces 1000 --kinds space,screen
  From the fleet VM, one capture-slot lease per call (staged build JOB, the lease released in every case):
    switch-scale-bench.py --slot-job JOB --out DIR -- --workspaces 1000 --kinds space,screen --switches 200
Stdlib only.
"""
import argparse
import concurrent.futures
import importlib.util
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FIXTURE = os.path.join(ROOT, "scripts", "perf-lab", "corpus", "stories", "switch_scale.py")
STORY = "switch-scale"
ALL_KINDS = ("space", "space_swipe", "screen", "workspace_click", "workspace_digit", "workspace_next",
             "workspace_palette", "tab", "pane", "window", "home", "memory")
BUSY_LOOP = 'while :; do echo "$RANDOM $RANDOM switch-scale busy line $(date +%s)"; sleep 0.02; done'
WINDOW_FRAME = (40, 40, 1600, 1000)


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def pct(values, q):
    vals = sorted(v for v in values if isinstance(v, (int, float)))
    if not vals:
        return None
    k = (len(vals) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(vals) - 1)
    return round(vals[lo] + (vals[hi] - vals[lo]) * (k - lo), 2)


def block(values):
    vals = [v for v in values if isinstance(v, (int, float))]
    return {"n": len(vals), "p50": pct(vals, 0.5), "p99": pct(vals, 0.99), "max": pct(vals, 1.0)}


def pick(obj, *keys):
    """The first of `keys` anywhere in `obj` (dicts and lists, depth first) with a string or number value."""
    if isinstance(obj, dict):
        for key in keys:
            if isinstance(obj.get(key), (str, int)) and obj.get(key) != "":
                return obj[key]
        for value in obj.values():
            found = pick(value, *keys)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = pick(value, *keys)
            if found is not None:
                return found
    return None


# ================================================================== the fleet VM side: one capture-slot lease
def slot_main(opts, rest):
    """Leases a capture slot (capture-host, never cmux16), stages build JOB there once per host, launches it in the
    slot, copies this script with its imports and runs it against the slot's socket; copies the results back and
    releases the lease in every case (release stops every process of the slot by exact PID)."""
    job = opts.slot_job
    if not re.fullmatch(r"[A-Za-z0-9._-]+", job):
        sys.exit(f"bad job id {job!r}")
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    tools = os.path.expanduser("~/.local/share/cmux/hq-tools/current/build-fleet")
    env = dict(os.environ)
    env["PATH"] = tools + os.pathsep + env.get("PATH", "")
    env.setdefault("CAPTURE_HOST_EXCLUDE", "cmux16")
    if "cmux16" not in env["CAPTURE_HOST_EXCLUDE"]:
        env["CAPTURE_HOST_EXCLUDE"] += ",cmux16"
    if opts.slot_hosts:
        env["CAPTURE_HOST_SLOT_HOSTS"] = opts.slot_hosts
    log = open(os.path.join(out, "slot.log"), "a")

    def say(text):
        line = time.strftime("%H:%M:%S ") + text
        print(line, flush=True)
        log.write(line + "\n")
        log.flush()

    def ssh(host, command, timeout=600, check=False):
        done = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", host, command],
                              capture_output=True, text=True, timeout=timeout)
        if check and done.returncode != 0:
            raise RuntimeError(f"ssh {host}: exit {done.returncode}: {(done.stdout + done.stderr)[-400:]}")
        return done

    acquired = time.time()
    lease_out = open(os.path.join(out, "lease.txt"), "w")
    lease_err = open(os.path.join(out, "lease.err"), "w")
    holder = subprocess.Popen(["capture-host", "acquire", "--slot"], stdout=lease_out, stderr=lease_err, env=env,
                              start_new_session=True)
    state = {"lease": None, "host": None, "run": None}

    def release(*_):
        if state["host"] and state["run"]:
            try:
                ssh(state["host"], f"rm -rf {shlex.quote(state['run'])}", timeout=60)
            except Exception:  # the release below still runs
                pass
        if state["lease"]:
            subprocess.run(["capture-host", "release", state["lease"]], env=env, capture_output=True, timeout=120)
            say(f"released {state['lease']}")
            state["lease"] = None
        if holder.poll() is None:
            holder.terminate()

    signal.signal(signal.SIGTERM, lambda *_: (release(), sys.exit(143)))
    signal.signal(signal.SIGINT, lambda *_: (release(), sys.exit(130)))
    status = 1
    try:
        for _ in range(150):
            text = open(os.path.join(out, "lease.txt")).read()
            match = re.search(r"slot-[A-Za-z0-9._-]+", text)
            if match:
                state["lease"] = match.group(0)
                info = subprocess.run(["capture-host", "slot-info", state["lease"]], env=env, capture_output=True, text=True)
                if info.returncode == 0:
                    break
            if holder.poll() is not None and not match:
                sys.exit("capture-host acquire ended: " + open(os.path.join(out, "lease.err")).read()[-600:])
            time.sleep(2)
        if not state["lease"]:
            sys.exit("no capture slot")
        info = subprocess.run(["capture-host", "slot-info", state["lease"]], env=env, capture_output=True, text=True).stdout
        host = re.search(r"host=(\S+)", info).group(1)
        slot = re.search(r"slot=(\S+)", info).group(1)
        state["host"] = host
        say(f"lease {state['lease']} host {host} slot {slot}")
        stage = f"/Users/Shared/cmux-capture/bench-restore/{job}"
        run = f"{stage}/ss-{time.strftime('%H%M%S')}-{os.getpid()}"
        state["run"] = run
        ssh(host, f"mkdir -p '{stage}' '{run}'", check=True)
        staged = ssh(host, f"find '{stage}' -maxdepth 1 -name '*.app' | head -1").stdout.strip()
        if not staged and opts.slot_artifact:
            # The build's zip from this VM (the controller's artifact reads time out under load).
            subprocess.run(["scp", "-q", opts.slot_artifact, f"{host}:{run}/app.zip"], check=True, timeout=900)
            ssh(host, f"""set -e; tmp=$(mktemp -d '{stage}/unzip.XXXXXX'); ditto -x -k '{run}/app.zip' "$tmp"
              for a in "$tmp"/*.app; do [ -e '{stage}/'"$(basename "$a")" ] || mv "$a" '{stage}/'; done; rm -rf "$tmp" '{run}/app.zip'""",
                check=True, timeout=900)
        elif not staged:
            for attempt in range(3):
                done = ssh(host, f"""export PATH=$HOME/.local/bin:$PATH; set -e; tmp=$(mktemp -d '{stage}/unzip.XXXXXX')
                  trap 'rm -rf "$tmp"' EXIT; cmux-ci artifact '{job}' "$tmp/app.zip" >/dev/null; ditto -x -k "$tmp/app.zip" "$tmp"
                  for a in "$tmp"/*.app; do [ -e '{stage}/'"$(basename "$a")" ] || mv "$a" '{stage}/'; done""", timeout=900)
                if done.returncode == 0:
                    break
                say(f"artifact download on {host} failed (try {attempt + 1}): {(done.stdout + done.stderr)[-300:]}")
                time.sleep(20)
        if not ssh(host, f"find '{stage}' -maxdepth 1 -name '*.app' | head -1").stdout.strip():
            sys.exit(f"build {job} is not staged on {host} (artifact download failed; --slot-artifact ZIP stages it from here)")
        # This script and what it imports, from this checkout's working tree.
        bundle = os.path.join(tempfile.mkdtemp(prefix="ss-slot-"), "repo.tgz")
        with tarfile.open(bundle, "w:gz") as tar:
            for rel in ("scripts/cmux-next", "scripts/perf-lab", "scripts/perf-bench"):
                base = os.path.join(ROOT, rel)
                for folder, dirs, files in os.walk(base):
                    dirs[:] = [d for d in dirs if d not in ("__pycache__", "node_modules", "tests", ".git")]
                    for name in files:
                        if name.endswith((".py", ".json", ".sh")):
                            path = os.path.join(folder, name)
                            tar.add(path, arcname=os.path.relpath(path, ROOT))
        subprocess.run(["scp", "-q", bundle, f"{host}:{run}/repo.tgz"], check=True, timeout=300)
        ssh(host, f"mkdir -p '{run}/repo' && tar -xzf '{run}/repo.tgz' -C '{run}/repo'", check=True)
        app = ssh(host, f"ls -d '{stage}'/*.app | head -1", check=True).stdout.strip()
        launched = subprocess.run(["capture-host", "launch", state["lease"], app, "ss", "--"], env=env,
                                  capture_output=True, text=True, timeout=300)
        open(os.path.join(out, "launch.txt"), "w").write(launched.stdout + launched.stderr)
        say("launch: " + launched.stdout.strip()[-400:])
        printed = (re.search(r"socket=(\S+)", launched.stdout) or [None, None])[1]
        clone = (re.search(r" app=(.*\.app)\s*$", launched.stdout, re.M) or [None, None])[1]
        name = os.path.basename(app)[:-4]
        build_tag = name[len("cmux DEV "):] if name.startswith("cmux DEV ") else name
        keyed = None
        if clone:
            keyed = ssh(host, f"cd '{run}/repo' && python3 -I scripts/cmux-next/build_names.py socket {shlex.quote(clone)}").stdout.strip() or None
        sock = None
        for _ in range(60):
            for candidate in [c for c in (keyed, f"/tmp/cmux-debug-{build_tag}-capslot{slot}.sock", printed) if c and c != "none"]:
                probe = ssh(host, "python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(2); "
                                  f"s.connect(sys.argv[1])' {shlex.quote(candidate)}", timeout=30)
                if probe.returncode == 0:
                    sock = candidate
                    break
            if sock:
                break
            time.sleep(1)
        if not sock:
            sys.exit("the app never opened its control socket")
        host_info = ssh(host, "sw_vers -productVersion; sysctl -n hw.model; system_profiler SPDisplaysDataType 2>/dev/null "
                              "| grep -E 'Resolution|Refresh|Hz' | head -4").stdout
        open(os.path.join(out, "host-info.txt"), "w").write(host_info)
        left = int(opts.lease_seconds - (time.time() - acquired) - 45)
        if left < 120:
            sys.exit(f"only {left} s left on the lease; not starting the bench")
        tag = re.sub(r"[^a-z0-9]+", "-", os.path.basename(clone or app)[len("cmux DEV "):-4].lower()).strip("-")
        command = (f"cd '{run}/repo' && python3 -I scripts/cmux-next/switch-scale-bench.py --socket {shlex.quote(sock)} "
                   f"--app {shlex.quote(clone or app)} --tag {shlex.quote(tag)} --out '{run}/out' "
                   f"--max-seconds {left - 40} " + " ".join(shlex.quote(a) for a in rest))
        say("bench: " + command)
        with open(os.path.join(out, "bench.txt"), "a") as sink:
            proc = subprocess.Popen(["ssh", "-o", "BatchMode=yes", host, command], stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)
            for line in proc.stdout:
                sys.stdout.write(line)
                sink.write(line)
            status = proc.wait()
        subprocess.run(["scp", "-q", "-r", f"{host}:{run}/out/.", out + "/"], timeout=600)
        say(f"results in {out} (bench exit {status})")
    finally:
        release()
    return status


# ================================================================== the Mac side
class Bench:
    def __init__(self, opts):
        self.opts = opts
        self.out = os.path.abspath(opts.out)
        os.makedirs(self.out, exist_ok=True)
        self.started = time.time()
        self.log_file = open(os.path.join(self.out, "bench.log"), "a")
        self.results = {"story": STORY, "args": vars(opts), "sizes": {}, "log": [], "not_measured": []}
        self.socket = opts.socket
        self.bench_app = None
        self.fixture = load("switch_scale_fixture", FIXTURE)
        self.pages = None
        self.lock = threading.Lock()
        self.term_tab = {}
        self.key_slots = None  # debug.input slots: None untried, False absent, True present

    # ---------------------------------------------------------------- plumbing
    def say(self, text):
        line = time.strftime("%H:%M:%S ") + str(text)
        print(line, flush=True)
        self.log_file.write(line + "\n")
        self.log_file.flush()
        with self.lock:
            self.results["log"].append(str(text)[:600])

    def missing(self, size, kind, why):
        self.say(f"NOT MEASURED {size} {kind}: {why}")
        self.results["not_measured"].append({"size": size, "kind": kind, "why": why})

    def time_left(self):
        return self.opts.max_seconds - (time.time() - self.started)

    def rpc(self, method, params=None, timeout=30):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(self.socket)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
        except (OSError, ValueError) as error:
            return {"error": str(error)}
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}

    @staticmethod
    def failed(reply):
        return not isinstance(reply, dict) or "error" in reply

    def action(self, name, args=None, target=None, focus=True, timeout=60):
        params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
        if target:
            params["target"] = target
        return self.rpc("action.run", params, timeout=timeout)

    def key(self, key, modifiers=(), window=None, target=None):
        params = {"key": key, "modifiers": list(modifiers)}
        if window is None and target is None:
            window = getattr(self, "w0", None)  # typed keys go to the measured window, not the first one
        if window:
            params["window"] = window
        if target:
            params["target"] = target
        return self.rpc("debug.key", params, timeout=10)

    def cli(self, *args, timeout=60):
        """The bundle's cmux CLI against the app's own daemon (its --socket, as bench-restore.py's cli_call), else
        routed through the app's socket. Returns the JSON value or {"error": ...}."""
        env = {"HOME": self.env_home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
        route = ["--socket", self.daemon_socket] if self.daemon_socket else ["--app-socket", self.socket]
        for attempt in range(6):
            try:
                done = subprocess.run([self.cli_path, *route, "--json", *args], capture_output=True, text=True,
                                      timeout=timeout, env=env, stdin=subprocess.DEVNULL)
            except subprocess.TimeoutExpired:
                return {"error": f"timeout: {' '.join(args)[:120]}"}
            try:
                answer = json.loads(done.stdout)
            except ValueError:
                answer = {"error": (done.stdout + done.stderr).strip()[:300] or f"exit {done.returncode}"}
            if done.returncode != 0 and isinstance(answer, dict) and "error" not in answer:
                answer = {"error": answer}
            text = json.dumps(answer)[:2000] if isinstance(answer, dict) and "error" in answer else ""
            # Two creates at once race on the workspace order (the daemon refuses the second): run it again.
            if text and any(k in text for k in ("live sibling", "revision", "conflict")) and attempt < 5:
                time.sleep(0.05 * (attempt + 1))
                continue
            break
        verb = " ".join(a for a in args[:3] if not re.match(r"(ws|pane|tab|term|scr|room|wsg|grp)_|^[0-9a-f-]{20,}", a))
        with self.lock:
            replies = self.results.setdefault("first_replies", {})
            if verb not in replies:
                replies[verb] = json.dumps(answer)[:1500]
        return answer.get("value", answer) if isinstance(answer, dict) else {"value": answer}

    def topology(self):
        reply = self.rpc("snapshot.get", timeout=60)
        return (reply.get("topology") or reply) if isinstance(reply, dict) else {}

    def windows_report(self):
        reply = self.rpc("debug.windows")
        return reply.get("windows") or [] if isinstance(reply, dict) else []

    # ---------------------------------------------------------------- app
    def attach(self):
        """The app: a capture slot's (--socket) or one this bench launches (BenchApp, the bench env, no activation)."""
        bench_launch = load("bench_launch", os.path.join(HERE, "bench_launch.py"))
        self.bench_launch = bench_launch
        if self.socket:
            self.bench_app = bench_launch.BenchApp(self.opts.app, out=self.out, teardown=False, perf_session="stress",
                                                   build_config="bench")
            self.bench_app.socket = self.socket
            self.bench_app.features = bench_launch.features_snapshot(self.rpc("features.list", timeout=10))
            self.fix_feature_sources()
        else:
            self.bench_app = bench_launch.BenchApp(self.opts.app, out=self.out, window=WINDOW_FRAME, screen="0",
                                                   log_name="app.log", teardown=True, perf_session="stress")
            self.bench_app.launch(timeout=180)
            self.socket = self.bench_app.socket
            self.fix_feature_sources()
        self.connect()

    def fix_feature_sources(self):
        """A build whose features.list names a source result-v1 does not know (5aad318: `build`, a state the build
        fixes) would have every row refused: such a source is written as `default`, and results.json keeps the
        build's own words (`feature_sources_mapped`)."""
        snapshot = self.bench_app.features if self.bench_app else None
        if not snapshot:
            return
        known = ("policy", "env", "local", "remote", "study", "default")
        mapped = {}
        for name, value in (snapshot[0] or {}).items():
            if isinstance(value, dict) and value.get("source") not in known and value.get("source") is not None:
                mapped[name] = value["source"]
                value["source"] = "default"
        if mapped:
            self.results["feature_sources_mapped"] = mapped

    def connect(self):
        info = self.rpc("system.identify")
        if self.failed(info):
            sys.exit(f"no app answers on {self.socket}: {info}")
        self.pid = int(info.get("pid"))
        self.bundle = info.get("app_bundle_path") or self.opts.app
        self.cli_path = info.get("app_cli_path") or os.path.join(self.bundle, "Contents/Resources/bin/cmux")
        env = self.process_env(self.pid)
        self.env_home = env.get("HOME", os.environ.get("HOME", "/tmp"))
        self.daemon_socket = self.find_daemon_socket()
        self.launch_workspaces = set()
        for w in self.topology().get("workspaces") or []:
            self.launch_workspaces |= {x for x in (w.get("id"), w.get("key")) if x}
        caps = self.rpc("debug.capabilities")
        self.methods = set(caps.get("methods") or []) if isinstance(caps, dict) else set()
        self.results["app"] = {"identify": info, "daemon_socket": self.daemon_socket, "methods": sorted(self.methods)[:400]}
        self.say(f"app pid {self.pid} {info.get('bundle_id')} config {info.get('build_configuration')} daemon {self.daemon_socket}")

    @staticmethod
    def process_env(pid):
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
        env = {}
        for word in out.split():
            key, sep, val = word.partition("=")
            if sep and (key.startswith("CMUX_") or key in ("HOME", "TMPDIR")):
                env[key] = val
        return env

    def find_daemon_socket(self):
        table = subprocess.run(["ps", "axo", "args="], capture_output=True, text=True).stdout
        for line in table.splitlines():
            if line.startswith(self.bundle + "/") and "--headless" in line:
                match = re.search(r"--socket (\S+)", line)
                if match:
                    return match.group(1)
        return None

    def host_block(self):
        def out(*cmd):
            try:
                return subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout.strip()
            except (OSError, subprocess.TimeoutExpired):
                return ""
        hz = None
        try:
            hz = self.bench_launch.main_display_hz()
        except Exception as error:  # a host without the CoreGraphics read: the frames' refresh period stands in
            self.say(f"display Hz: {error}")
        return {"host": os.uname().nodename, "macos": out("/usr/bin/sw_vers", "-productVersion"),
                "macos_build": out("/usr/bin/sw_vers", "-buildVersion"), "model": out("/usr/sbin/sysctl", "-n", "hw.model"),
                "cpu": out("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"), "display_hz": hz}

    # ---------------------------------------------------------------- realization
    def parallel(self, jobs, workers=8):
        with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
            return list(pool.map(lambda job: job(), jobs))

    def realize(self, size):
        fx = self.fixture.build(size)
        t0 = time.monotonic()
        made = {"workspaces": 0, "rooms": 0, "groups": 0, "pins": 0, "group_members": 0, "screens": 0, "panes": 0,
                "terminals": 0, "terminals_skipped": 0, "chromium": 0, "webkit": 0, "chats": 0, "chats_refused": 0,
                "busy": 0, "errors": []}

        def err(what, reply):
            if len(made["errors"]) < 40:
                made["errors"].append(f"{what}: {str(reply)[:200]}")

        for key, value in {"layout.minimumPaneWidth": 80, "layout.minimumPaneHeight": 32}.items():
            self.rpc("settings.set", {"path": key, "value": value})
        # Spaces: `default` is space 0.
        rooms = ["default"]
        for k in range(1, fx["spaces"]):
            reply = self.cli("room", "create", "--name", f"ss-space-{k}")
            room = pick(reply, "room_id", "profile_id", "id")
            if not room or self.failed(reply):
                listed = self.cli("room", "list")
                room = next((pick(r, "id", "room_id", "profile_id") for r in (pick_list(listed) or [])
                             if isinstance(r, dict) and r.get("name") == f"ss-space-{k}"), None)
            if not room:
                err("room create", reply)
                room = f"ss-space-{k}"
            rooms.append(room)
        made["rooms"] = len(rooms)
        hot = []
        for space in (0, 1):
            hot += [i for i in range(size) if i % fx["spaces"] == space][:2]
        hot += [w["workspace"] for w in fx["windows"][1:]]
        hot = list(dict.fromkeys(hot))
        self.say(f"size {size}: {fx['spaces']} spaces, {len(fx['groups'])} groups, hot {hot}")
        # Workspaces.
        ws_ids = [None] * size
        info = {}

        def create(i):
            args = ["workspace", "create", "--name", f"ss-{i:04d}"] + ([] if i in hot else ["--empty"])
            reply = self.cli(*args)
            ws_ids[i] = pick(reply, "workspace_id", "workspace")
            if i in hot:
                info[i] = {"pane": pick(reply, "pane_id", "pane"), "terminal": pick(reply, "terminal_id", "terminal"),
                           "screen": pick(reply, "screen_id", "screen")}
                self.note_tab(reply)
            if not ws_ids[i]:
                err(f"workspace create {i}", reply)
        self.parallel([lambda i=i: create(i) for i in range(size)], workers=2)
        made["workspaces"] = sum(1 for w in ws_ids if w)
        self.say(f"created {made['workspaces']} workspaces in {time.monotonic() - t0:.1f} s")
        # Pins: every workspace to its space.

        def pin(i):
            if not ws_ids[i]:
                return
            reply = self.cli("room", rooms[fx["workspaces"][i]["space"]], "pin", "--workspace", ws_ids[i])
            if self.failed(reply):
                err(f"pin {i}", reply)
            else:
                with self.lock:
                    made["pins"] += 1
        self.parallel([lambda i=i: pin(i) for i in range(size)], workers=4)
        # Groups, in their space; the hot workspaces stay loose.
        group_ids = []
        for g, group in enumerate(fx["groups"]):
            reply = self.cli("workspace", "group", "create", "--name", f"ss-g{g:02d}", "--room", rooms[group["space"]])
            gid = pick(reply, "group_id", "workspace_group_id", "id")
            if self.failed(reply):
                err(f"group create {g}", reply)
            group_ids.append(gid or f"ss-g{g:02d}")
        made["groups"] = sum(1 for g in group_ids if g)

        def member(i):
            group = fx["workspaces"][i]["group"]
            if group is None or i in hot or not ws_ids[i]:
                return
            reply = self.cli("workspace", "group", group_ids[group], "add", "--workspace", ws_ids[i])
            if self.failed(reply):
                err(f"group add {i}", reply)
            else:
                with self.lock:
                    made["group_members"] += 1
        self.parallel([lambda i=i: member(i) for i in range(size)], workers=4)
        self.say(f"pinned {made['pins']}, {made['groups']} groups with {made['group_members']} members "
                 f"({time.monotonic() - t0:.1f} s)")
        # The hot set's shape.
        if self.pages is None:
            stress = load("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
            self.pages = stress.Pages()
        budget = {"terminals": self.opts.hot_terminals}
        # Each hot pane's first terminal is there whatever the cap: count them first.
        mandatory = sum(len(self.fixture.leaves(s["tree"])) for i in hot for s in fx["workspaces"][i]["screens"])
        budget["extra"] = max(0, self.opts.hot_terminals - mandatory)
        hot_made = {}
        chats = []
        terminals = []  # (terminal id, busy)

        def split(pane, direction, ratio):
            reply = self.cli("pane", pane, "split", "--right" if direction == "right" else "--down",
                             "--ratio", f"{ratio:.4f}")
            new = pick(reply, "pane_id", "pane")
            if not new:
                err("split", reply)
            self.note_tab(reply)
            return new, pick(reply, "terminal_id", "terminal")

        def build_node(pane, first_terminal, node, out):
            if "tabs" in node:
                out.append((pane, first_terminal))
                return
            children = node["children"]
            regions = [(pane, first_terminal)]
            for j in range(1, len(children)):
                remaining = len(children) - j + 1
                new = split(regions[-1][0], node["split"], 1.0 / remaining)
                if not new[0]:
                    break
                regions.append(new)
            for (region, term), child in zip(regions, children):
                build_node(region, term, child, out)

        def build_workspace(i):
            ws = fx["workspaces"][i]
            record = {"id": ws_ids[i], "screens": []}
            for s, screen in enumerate(ws["screens"]):
                if s == 0:
                    first, term, sid = info[i]["pane"], info[i]["terminal"], info[i]["screen"]
                else:
                    reply = self.cli("workspace", ws_ids[i], "screen", "create", "--name", f"s{s}")
                    first, term, sid = (pick(reply, "pane_id", "pane"), pick(reply, "terminal_id", "terminal"),
                                        pick(reply, "screen_id", "screen"))
                    self.note_tab(reply)
                    if not first:
                        err(f"screen create {i}/{s}", reply)
                        continue
                with self.lock:
                    made["screens"] += 1
                leaves_made = []
                build_node(first, term, screen["tree"], leaves_made)
                spec_leaves = self.fixture.leaves(screen["tree"])
                with self.lock:
                    made["panes"] += len(leaves_made)
                # The panes of a screen fill at once (each pane's tabs in order).
                filled = self.parallel([lambda k=k, pane=pane, term=term, leaf=leaf: {
                    "id": pane, "tabs": self.fill(i, s, pane, term, leaf, ws["busy"], k, budget, made, chats, terminals, err)}
                    for k, ((pane, term), leaf) in enumerate(zip(leaves_made, spec_leaves))], workers=6)
                panes = list(filled)
                if 0 <= screen["focused_pane"] < len(panes):
                    self.cli("pane", panes[screen["focused_pane"]]["id"], "focus")
                record["screens"].append({"id": sid, "panes": panes})
            active = ws["active_screen"]
            if active < len(record["screens"]) and record["screens"][active]["id"]:
                self.cli("screen", record["screens"][active]["id"], "focus")
            hot_made[i] = record
        self.parallel([lambda i=i: build_workspace(i) for i in hot], workers=len(hot))
        # Scrollback and the busy loops.

        def feed(term, busy):
            text = "seq 1 10000\n" + (BUSY_LOOP + "\n" if busy else "")
            reply = self.cli("terminal", term, "write", "--text", text)
            if self.failed(reply):
                err("terminal write", reply)
        self.parallel([lambda t=t, b=b: feed(t, b) for t, b in terminals])
        made["busy"] = sum(1 for _, b in terminals if b)
        # Agent chats (an app action: no daemon op makes one), one per chat tab of the fixture. --no-chats leaves them
        # out: on build 5aad318 an agent pane's view freed during a switch aborts the app in the CEF fork's
        # CmuxParentViewTracker (objc_storeWeak on a deallocating view).
        made["chats_left_out"] = len(chats) if self.opts.no_chats else 0
        for pane in ([] if self.opts.no_chats else chats):
            reply = self.action("palette.newAgentChat", target=f"pane:{pane}", focus=False, timeout=20)
            if self.failed(reply):
                made["chats_refused"] += 1
                if made["chats_refused"] <= 3:
                    err("palette.newAgentChat", reply)
            else:
                made["chats"] += 1
        made["seconds"] = round(time.monotonic() - t0, 1)
        self.say(f"realized: {json.dumps({k: v for k, v in made.items() if k != 'errors'})}")
        if made["errors"]:
            self.say(f"realize errors (first): {made['errors'][:6]}")
        return fx, rooms, ws_ids, hot, hot_made, made

    def fill(self, i, s, pane, term, leaf, busy, pane_index, budget, made, chats, terminals, err):
        """`pane`'s fixture tabs: its first terminal (`term`) stands for the leaf's first terminal tab; a leaf with
        no terminal closes it after its other tabs are made."""
        kinds = leaf["tabs"]
        tabs = []
        busy_tabs = {t for (bs, bp, t) in busy if bs == s and bp == pane_index}
        first_terminal = next((t for t, k in enumerate(kinds) if k == "terminal"), None)
        for t, kind in enumerate(kinds):
            if kind == "terminal":
                if t == first_terminal and term:
                    tabs.append({"kind": kind, "terminal": term})
                    with self.lock:
                        made["terminals"] += 1
                    terminals.append((term, t in busy_tabs))
                    continue
                with self.lock:
                    allowed = budget["extra"] > 0
                    if allowed:
                        budget["extra"] -= 1
                if not allowed:
                    with self.lock:
                        made["terminals_skipped"] += 1
                    continue
                reply = self.cli("pane", pane, "tab", "create", "terminal")
                new = pick(reply, "terminal_id", "terminal")
                if not new:
                    err("tab create terminal", reply)
                    continue
                with self.lock:
                    made["terminals"] += 1
                terminals.append((new, t in busy_tabs))
                tabs.append({"kind": kind, "tab": pick(reply, "tab_id", "tab"), "terminal": new})
            elif kind in ("chromium", "webkit"):
                reply = self.cli("browser", "open", "--url", self.pages.url(), "--engine", kind, "--pane", pane)
                if self.failed(reply):
                    err(f"browser open {kind}", reply)
                    continue
                with self.lock:
                    made[kind] += 1
                tabs.append({"kind": kind, "tab": pick(reply, "tab_id", "tab", "browser_id")})
            else:
                with self.lock:
                    chats.append(pane)
                tabs.append({"kind": "chat"})
        if first_terminal is None and term:
            tab = self.term_tab.get(term) or self.terminal_tab(pane, term)
            reply = self.cli("tab", tab, "close") if tab else {"error": f"no tab id for terminal {term}"}
            if self.failed(reply):
                err("close first terminal", reply)
        chosen = tabs[leaf["selected"]] if leaf["selected"] < len(tabs) else None
        if chosen and chosen.get("tab"):
            self.cli("tab", chosen["tab"], "focus")
        return tabs

    def note_tab(self, reply):
        """The tab id of the terminal a create, split or screen reply made (closing it needs the tab_ id)."""
        term, tab = pick(reply, "terminal_id", "terminal"), pick(reply, "tab_id", "tab", "surface_id")
        if term and tab and str(tab).startswith("tab_"):
            with self.lock:
                self.term_tab[term] = tab

    def terminal_tab(self, pane, term):
        reply = self.cli("pane", pane, "show")
        for tab in pick_list(reply) or []:
            if isinstance(tab, dict) and term in json.dumps(tab):
                return pick(tab, "tab_id", "id")
        return None

    # ---------------------------------------------------------------- windows and placement
    def place(self, fx, rooms, ws_ids, hot, made):
        """Window 0 shows its fixture workspace; windows 1 and 2 are new windows, each in its fixture space showing its
        fixture workspace. The workspaces that new windows bring are closed. Returns [window ids]."""
        topo = self.topology()
        by_name = {w.get("name"): w for w in topo.get("workspaces") or []}
        self.app_ws = {i: (by_name.get(f"ss-{i:04d}") or {}).get("id") or ws_ids[i] for i in range(len(ws_ids))}
        # debug.windows names a window's workspace by its app key; topology and the CLI by public id: all to the name.
        self.names = {}
        for w in topo.get("workspaces") or []:
            for alias in (w.get("id"), w.get("key")):
                if alias:
                    self.names[alias] = w.get("name")
        for i, wid in enumerate(ws_ids):
            if wid:
                self.names.setdefault(wid, f"ss-{i:04d}")
        missing = sum(1 for i in range(len(ws_ids)) if f"ss-{i:04d}" not in by_name)
        if missing:
            self.say(f"topology lists {len(ws_ids) - missing} of the {len(ws_ids)} ss-* workspaces")
        windows = [w.get("id") for w in topo.get("windows") or []]
        state_windows = [w.get("id") for w in self.windows_report()]
        self.say(f"topology windows {windows}, debug.windows {state_windows}")
        first = state_windows[0] if state_windows else None
        win_ids = [first]
        self.show_in(first, fx["windows"][0]["space"], self.app_ws[fx["windows"][0]["workspace"]])
        for w in fx["windows"][1:]:
            before = {x.get("id") for x in self.windows_report()}
            # Opened in its space (space.newWindow): moving a new window's first workspace out of view freed an agent
            # view and aborted build 5aad318 (CEF CmuxParentViewTracker), so the window never changes space.
            reply = self.action("space.newWindow", {"space": rooms[w["space"]]})
            new = None
            for _ in range(60):
                new = next((x.get("id") for x in self.windows_report() if x.get("id") not in before and x.get("open", True)), None)
                if new:
                    break
                time.sleep(0.25)
            if not new:
                self.say(f"newWindow made no window: {reply}")
                break
            time.sleep(1.0)
            self.rpc("debug.window.focus", {"window": new})
            self.action("goToWorkspace", {"workspace": self.app_ws[w["workspace"]]})
            for _ in range(20):
                if self.window_workspace(new) == self.name_of(self.app_ws[w["workspace"]]):
                    break
                time.sleep(0.25)
            else:
                self.say(f"window {new} shows {self.window_workspace(new)}, not ss-{w['workspace']:04d}")
            win_ids.append(new)
        # Workspaces the new windows made (not ss-*, not there at launch, which keeps Home): closed.
        for w in self.topology().get("workspaces") or []:
            if (not str(w.get("name") or "").startswith("ss-") and w.get("id")
                    and w.get("id") not in self.launch_workspaces and w.get("key") not in self.launch_workspaces):
                self.action("closeWorkspace", target=f"workspace:{w['id']}", focus=False)
        # The hot workspaces go to the top of their space's sidebar, the second first.
        for i in reversed(hot):
            self.action("palette.moveWorkspaceToTop", target={"kind": "workspace", "id": self.app_ws[i]}, focus=False)
        time.sleep(2)
        made["windows"] = len(win_ids)
        # Each hot workspace in window 0: a terminal pane gets the keyboard (a click on it), so keys can be timed;
        # the panes blank at rest (after a settle) are kept apart from the blank frames of a switch.
        self.rest_blank, rest = set(), {}
        w0 = win_ids[0]
        number = self.window_number(w0)
        for i in hot:
            self.rpc("debug.window.focus", {"window": w0})
            self.action("goToWorkspace", {"workspace": self.app_ws[i]})
            time.sleep(1.5)
            panes = self.visible_panes(self.surfaces(), number)
            term = next((p for p in panes if p.get("kind") == "terminal" and not self.pane_blank(p)), None) \
                or next((p for p in panes if p.get("kind") == "terminal"), None)
            if term:
                self.rpc("debug.mouse", {"action": "click", "pane": term.get("pane"), "window": w0})
            time.sleep(1.5)
            panes = self.visible_panes(self.surfaces(), number)
            blank = [p for p in panes if self.pane_blank(p)]
            self.rest_blank |= {p.get("pane") for p in blank}
            rest[f"ss-{i:04d}"] = {"visible": len(panes), "terminal_focused": bool(term),
                                   "focused_kind": next((p.get("kind") for p in panes if p.get("focused")), None),
                                   "blank_at_rest": [{k: p.get(k) for k in ("kind", "content_reason", "presence", "phase",
                                                                            "content_installed", "content_in_window",
                                                                            "frame_held", "foreign_pages")}
                                                     | {"surface": {k: (p.get("surface") or {}).get(k) for k in
                                                                    ("exists", "replay_applied", "drawing", "paused")}}
                                                     for p in blank]}
        made["rest"] = rest
        self.say(f"rest: {json.dumps({k: (v['visible'], v['focused_kind'], len(v['blank_at_rest'])) for k, v in rest.items()})}")
        return win_ids

    def show_in(self, window, space, workspace):
        """Window `window` in space index `space` (space.selectByNumber, the active window), showing `workspace`."""
        self.rpc("debug.window.focus", {"window": window})
        self.action("space.selectByNumber", {"index": space + 1})
        time.sleep(0.5)
        reply = self.action("goToWorkspace", {"workspace": workspace})
        for _ in range(40):
            if self.window_workspace(window) == self.name_of(workspace):
                return True
            time.sleep(0.25)
        self.say(f"window {window} does not show {workspace} (space {space}): {reply}")
        return False

    def name_of(self, ws):
        return self.names.get(ws, ws) if ws else ws

    def window_workspace(self, window):
        """The name (ss-NNNN) of the workspace window `window` shows."""
        for w in self.windows_report():
            if w.get("id") == window:
                return self.name_of(w.get("selected"))
        return None

    def window_page(self, window):
        for w in self.windows_report():
            if w.get("id") == window:
                return w.get("shown_page") or w.get("page")
        return None

    # ---------------------------------------------------------------- probes
    def surfaces(self, text=False):
        reply = self.rpc("debug.surfaces", {"text": True} if text else {}, timeout=10)
        return reply if isinstance(reply, dict) and "error" not in reply else {}

    @staticmethod
    def visible_panes(report, window_number=None):
        panes = []
        for window in report.get("windows") or []:
            if window_number is not None and str(window.get("window")) != str(window_number):
                continue
            panes += [p for p in window.get("panes") or [] if p.get("visible")]
        return panes

    @staticmethod
    def pane_blank(pane):
        if pane.get("window_drawable") is False:
            return False
        if pane.get("blank"):
            return True
        if pane.get("kind") == "terminal":
            surface = pane.get("surface") or {}
            return not (pane.get("frame_held") or surface.get("replay_applied"))
        return False

    @staticmethod
    def typed_text(text):
        """A terminal's text with the busy lines and line breaks taken out: in a busy terminal the tty echoes each typed
        key where the cursor is, so the loop's next line lands between two keys of the marker."""
        text = re.sub(r"\d+ \d+ switch-scale busy line \d+", "", text or "")
        return re.sub(r"\s+", "", text)

    def frames(self, action, raw=False):
        return self.rpc("debug.frames", {"action": action, "raw": raw}) or {}

    def timers(self, action):
        out = {}
        for method in ("debug.workspace_switch", "debug.tab_switch", "debug.pane_focus"):
            if self.methods and method not in self.methods:
                continue
            reply = self.rpc(method, {"action": action})
            if isinstance(reply, dict) and "error" not in reply:
                out[method] = reply.get("switches") or reply.get("moves") or []
        return out

    def input_slots(self):
        """The input latency tracker's closed slots since the last `debug.input reset` (builds with the `slots` action;
        v2.2.4 also opens one for a debug.key key to a window that is not key): event to the presented frame, per
        input. None when the build has no such action (then never asked again)."""
        reply = self.rpc("debug.input", {"action": "slots"}, timeout=10)
        if self.failed(reply) or not isinstance(reply.get("slots"), list):
            if self.key_slots is None:
                self.key_slots = False
                self.say(f"debug.input slots: not in this build ({str(reply)[:160]})")
            return None
        self.key_slots = True
        return [{k: s.get(k) for k in ("kind", "target", "entrypoint", "total_ms", "stages_ms")}
                for s in reply["slots"] if isinstance(s, dict)]

    def idle_baseline(self):
        self.frames("start")
        time.sleep(1.5)
        stats = self.frames("stop", raw=True)
        busy = stats.get("main_ms") or []
        return {"main_per_frame_ms": pct(busy, 0.5) or 0.0, "refresh_ms": stats.get("refresh_ms") or 16.67,
                "frames": stats.get("frames")}

    # ---------------------------------------------------------------- one switch
    def one_switch(self, send, expect, sampled, baseline, window_number=None, marker=None, quiet_s=0.3, settle_s=0.6,
                   keys_wait_s=2.5):
        """Sends one switch (`send()`, the input itself), then either waits quietly (clean: frames only) or samples
        the window's panes while the send runs and after (sampled). The marker is typed right after the input, as a
        person types after a switch. `expect(report)` says whether a debug.surfaces report shows the new target."""
        row = {"sampled": sampled}
        if not sampled:
            if self.key_slots is not False:
                self.rpc("debug.input", {"action": "reset"}, timeout=10)
            self.frames("start")
            t0 = time.monotonic()
            reply = send()
            row["send_ms"] = round((time.monotonic() - t0) * 1000, 2)
            if self.failed(reply):
                row["send_error"] = str(reply)[:200]
            time.sleep(quiet_s)
            stats = self.frames("stop", raw=True)
            busy = stats.get("main_ms") or []
            row["frames"] = stats.get("frames")
            row["missed"] = stats.get("missed")
            row["max_frame_ms"] = stats.get("max_ms")
            row["main_busy_ms"] = round(max(0.0, sum(busy) - baseline["main_per_frame_ms"] * len(busy)), 2)
            row["main_max_frame_ms"] = stats.get("main_max_ms")
            row["view_layouts"] = stats.get("view_layouts")
            if self.key_slots is not False:
                slots = self.input_slots()
                if slots is not None:
                    row["input_slots"] = slots
                    totals = [s["total_ms"] for s in slots if isinstance(s.get("total_ms"), (int, float))]
                    if totals:
                        row["input_to_present_ms"] = round(max(totals), 2)
            row["seen"] = bool(expect(self.surfaces()))
            return row
        sent = {}

        def sender():
            reply = send()
            sent["at"] = time.monotonic()
            if self.failed(reply):
                sent["error"] = str(reply)[:200]
            if marker:
                for ch in marker:
                    self.key(ch)
                sent["typed"] = time.monotonic()
        t0 = time.monotonic()
        thread = threading.Thread(target=sender, daemon=True)
        thread.start()
        blank_ms, blank_samples, samples, last = 0.0, 0, 0, None
        seen_at = echo_at = None
        focused_kind = None
        last_focused = None
        blank_kinds = {}
        while True:
            now = time.monotonic()
            if now - t0 > 4.0 or ("at" in sent and now - sent["at"] > settle_s and not thread.is_alive()
                                  and (not marker or echo_at or focused_kind != "terminal"
                                       or now - sent.get("typed", now) > keys_wait_s)):
                break
            report = self.surfaces(text=bool(marker) and "typed" in sent)
            t = time.monotonic()
            samples += 1
            panes = self.visible_panes(report, window_number)
            new_blank = [p for p in panes if self.pane_blank(p) and p.get("pane") not in self.rest_blank]
            if new_blank:
                if blank_samples == 0:
                    row["blank_detail"] = [{k: (json.dumps(v)[:400] if isinstance(v, (dict, list)) else v)
                                            for k, v in p.items() if k != "text"} for p in new_blank[:3]]
                blank_samples += 1
                for p in new_blank:
                    blank_kinds[p.get("kind")] = blank_kinds.get(p.get("kind"), 0) + 1
                if last is not None:
                    blank_ms += (t - last) * 1000
            last = t
            if seen_at is None and "at" in sent and expect(report):
                seen_at = t
            focused = next((p for p in panes if p.get("focused")), None)
            if focused:
                focused_kind = focused.get("kind")
                if marker and "typed" in sent:
                    last_focused = focused
            if marker and echo_at is None and focused and marker in self.typed_text(focused.get("text")):
                echo_at = t
            if (seen_at and not new_blank and not thread.is_alive()
                    and (not marker or echo_at or (focused_kind and focused_kind != "terminal"))):
                break
            time.sleep(0.012)
        thread.join(timeout=10)
        span = (last - t0) * 1000 if last else 0
        row.update({"samples": samples, "blank_samples": blank_samples, "blank_ms": round(blank_ms, 1),
                    "sample_period_ms": round(span / samples, 1) if samples else None,
                    "blank_kinds": blank_kinds,
                    "send_ms": round((sent["at"] - t0) * 1000, 1) if "at" in sent else None,
                    "content_seen_ms": round((seen_at - t0) * 1000, 1) if seen_at else None,
                    "focused_kind": focused_kind})
        if "error" in sent:
            row["send_error"] = sent["error"]
        if marker:
            row["keys_live_ms"] = round((echo_at - t0) * 1000, 1) if echo_at else None
            if not echo_at and last_focused:
                # What the focused terminal showed when the wait ended: where the marker went.
                row["keys_lost_view"] = {"pane": last_focused.get("pane"), "terminal": last_focused.get("terminal_id"),
                                         "tail": (last_focused.get("text") or "")[-240:]}
                # A busy terminal prints 50 lines a second: the echo leaves the viewport before the next sample (300-450
                # ms apart during a workspace switch), so its keys are not measured here, not lost.
                row["keys_busy_terminal"] = "switch-scale busy line" in (last_focused.get("text") or "")
            self.key("u", ["control"])
        return row
    # ---------------------------------------------------------------- kinds
    def run_kind(self, size, kind, plan, baseline, n, window_number=None, typing=True):
        """`plan` is (prepare(), [ (send, expect) forward, (send, expect) back ]) ; n switches alternate them."""
        prepare, steps, timer_names = plan
        if prepare:
            problem = prepare()
            if problem:
                self.missing(size, kind, problem)
                return None
        # Panes blank before the first switch (any window) are the rest state, not a switch's blank frames.
        time.sleep(0.5)
        before = {p.get("pane") for p in self.visible_panes(self.surfaces()) if self.pane_blank(p)}
        self.rest_blank |= before
        self.timers("start")
        sampler = None
        if self.opts.sample:
            path = os.path.join(self.out, f"sample-{kind}-{size}.txt")
            sampler = subprocess.Popen(["/usr/bin/sample", str(self.pid), "6", "1", "-mayDie", "-file", path],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(0.5)
        rows = []
        deadline_ok = True
        for i in range(n):
            if self.time_left() < 25:
                deadline_ok = False
                break
            step = steps[i % len(steps)]
            send, expect = step[0], step[1]
            if len(step) > 2 and step[2]:
                step[2]()  # before the input: state reads, the palette opened and its query typed
            sampled = i % 2 == 1
            marker = None
            if sampled and typing:
                marker = "qz" + "".join(chr(ord("a") + (i // 26 ** p) % 26) for p in range(3))
            row = self.one_switch(send, expect, sampled, baseline, window_number=window_number, marker=marker)
            row["i"] = i
            rows.append(row)
            time.sleep(0.05)
        timer_rows = self.timers("stop")
        if sampler:
            sampler.wait(timeout=60)
        if not deadline_ok:
            self.say(f"{kind} {size}: time is short, {len(rows)} of {n} switches")
        return self.summarize(size, kind, rows, timer_rows, baseline, timer_names)

    def summarize(self, size, kind, rows, timer_rows, baseline, timer_names):
        refresh = baseline["refresh_ms"] or 16.67
        clean = [r for r in rows if not r["sampled"]]
        sampled = [r for r in rows if r["sampled"]]
        commits, turn, late = [], [], []
        timer_used = None
        for name in timer_names:
            got = timer_rows.get(name) or []
            if got:
                timer_used = name
                for t in got:
                    if isinstance(t.get("commit_ms"), (int, float)):
                        commits.append(t["commit_ms"] + (t.get("input_ms") or 0))
                        turn.append(t["commit_ms"])
                        late.append(t.get("late_vsyncs"))
                break
        no_input_age = timer_used is not None and not any(
            "input_ms" in t for t in timer_rows.get(timer_used) or [])
        out = {
            "switches": len(rows), "clean": len(clean), "sampled": len(sampled), "refresh_ms": round(refresh, 3),
            "timer": timer_used, "timer_rows": len(commits), "timer_no_input_age": no_input_age,
            "input_to_commit_ms": block(commits), "turn_ms": block(turn), "late_vsyncs": block(late),
            "input_to_present_ms": block([r.get("input_to_present_ms") for r in clean]),
            "input_slots_missing": sum(1 for r in clean if "input_slots" in r and not r.get("input_to_present_ms")),
            "content_seen_ms": block([r.get("content_seen_ms") for r in sampled]),
            "main_busy_ms": block([r.get("main_busy_ms") for r in clean]),
            "main_max_frame_ms": block([r.get("main_max_frame_ms") for r in clean]),
            "missed_frames": block([r.get("missed") for r in clean]),
            "missed_frames_total": sum(r.get("missed") or 0 for r in clean),
            "blank_frames": block([round((r.get("blank_ms") or 0) / refresh, 2) for r in sampled]),
            "blank_frames_total": round(sum((r.get("blank_ms") or 0) for r in sampled) / refresh, 1),
            "switches_with_blank": sum(1 for r in sampled if r.get("blank_samples")),
            "keys_live_ms": block([r.get("keys_live_ms") for r in sampled if r.get("focused_kind") == "terminal"]),
            "sample_period_ms": block([r.get("sample_period_ms") for r in sampled]),
            "rest_blank_panes": len(self.rest_blank),
            "keys_lost": sum(1 for r in sampled if r.get("focused_kind") == "terminal" and r.get("keys_live_ms") is None
                             and not r.get("keys_busy_terminal")),
            "keys_not_measured_busy": sum(1 for r in sampled if r.get("keys_busy_terminal")),
            "not_seen": sum(1 for r in rows if r.get("sampled") and r.get("content_seen_ms") is None)
            + sum(1 for r in clean if r.get("seen") is False),
            "send_errors": sum(1 for r in rows if r.get("send_error")),
            "first_send_error": next((r["send_error"] for r in rows if r.get("send_error")), None),
            "rows": rows, "timer_samples": timer_rows.get(timer_used) if timer_used else [],
        }
        self.say(f"{kind} {size}: n {len(rows)} input->commit p50/p99 {out['input_to_commit_ms']['p50']}/"
                 f"{out['input_to_commit_ms']['p99']} ({timer_used}) seen {out['content_seen_ms']['p50']}/"
                 f"{out['content_seen_ms']['p99']} main {out['main_busy_ms']['p50']}/{out['main_busy_ms']['p99']} "
                 f"blank {out['blank_frames_total']} keys {out['keys_live_ms']['p50']}/{out['keys_live_ms']['p99']} "
                 f"not_seen {out['not_seen']} errors {out['send_errors']} {out['first_send_error'] or ''}")
        return out

    def plans(self, size, fx, hot, win_ids):
        """Each kind's (prepare, steps, timer names). Targets: window 0's two hot workspaces of space 0 (A, B), the
        space-1 hot workspace that window 0 shows in space 1 (C)."""
        w0 = win_ids[0]
        spaces = fx["spaces"]
        space0 = [i for i in hot if i % spaces == 0]
        space1 = [i for i in hot if i % spaces == 1]
        a, b = self.app_ws[space0[0]], self.app_ws[space0[1] if len(space0) > 1 else space0[0]]
        c = self.app_ws[space1[-1]]
        WS = ("debug.workspace_switch",)

        def shows(ws):
            return lambda report: self.window_workspace(w0) == self.name_of(ws)

        def go(ws):
            def prepare():
                self.rpc("debug.window.focus", {"window": w0})
                self.action("goToWorkspace", {"workspace": ws})
                time.sleep(0.6)
                return None if self.window_workspace(w0) == self.name_of(ws) else f"window 0 does not show {self.name_of(ws)}"
            return prepare

        plans = {}

        def space_prepare():
            self.rpc("debug.window.focus", {"window": w0})
            self.action("space.selectByNumber", {"index": 2})
            time.sleep(0.5)
            self.action("goToWorkspace", {"workspace": c})
            time.sleep(0.5)
            self.action("space.selectByNumber", {"index": 1})
            time.sleep(0.5)
            self.action("goToWorkspace", {"workspace": a})
            time.sleep(0.6)
            return None if self.window_workspace(w0) == self.name_of(a) else "window 0 is not on space 0's hot workspace"
        plans["space"] = (space_prepare, [
            (lambda: self.key("]", ["command", "option"], window=w0), shows(c)),
            (lambda: self.key("[", ["command", "option"], window=w0), shows(a))], WS)

        def swipe(direction):
            def send():
                rows = self.sidebar_rows()
                x = (rows[0]["window_frame"]["x"] + 60) if rows else 120
                y = 300
                reply = None
                for phase, dx in (("began", 0.0), *[("changed", direction * 40.0)] * 8, ("ended", 0.0)):
                    reply = self.rpc("debug.mouse", {"action": "scroll", "x": x, "y": y, "dx": dx, "dy": 0.0,
                                                     "phase": phase, "window": w0})
                return reply
            return send
        plans["space_swipe"] = (space_prepare, [(swipe(-1), shows(c)), (swipe(1), shows(a))], WS)

        def screen_prepare():
            problem = go(a)()
            if problem:
                return problem
            self.screen_before = self.pane_keys(w0)
            return None

        def screen_changed(report):
            keys = {p.get("pane") for p in self.visible_panes(report, self.window_number(w0))}
            return bool(keys) and keys != getattr(self, "screen_before", set())

        def screen_pre():
            self.screen_before = self.pane_keys(w0)
        plans["screen"] = (screen_prepare, [(lambda: self.action("screen.next"), screen_changed, screen_pre),
                                            (lambda: self.action("screen.previous"), screen_changed, screen_pre)],
                           ("debug.workspace_switch", "debug.tab_switch"))

        def click(ws):
            def send():
                row = self.sidebar_row(ws)
                if not row:
                    return {"error": f"no sidebar row for {ws}"}
                f = row["window_frame"]
                return self.rpc("debug.mouse", {"action": "click", "x": f["x"] + 60, "y": f["y"] + f["height"] / 2,
                                                "window": w0})
            return send
        plans["workspace_click"] = (go(a), [(click(b), shows(b)), (click(a), shows(a))], WS)
        plans["workspace_digit"] = (lambda: self.digit_prepare(w0, a, b), [
            (lambda: self.key(self.digits.get(b, "2"), ["command"], window=w0), shows(b)),
            (lambda: self.key(self.digits.get(a, "1"), ["command"], window=w0), shows(a))], WS)
        plans["workspace_next"] = (go(a), [
            (lambda: self.key("]", ["control", "command"], window=w0),
             lambda r: self.window_workspace(w0) not in (self.name_of(a), None)),
            (lambda: self.key("[", ["control", "command"], window=w0), shows(a))], WS)

        def palette_query(ws):
            def pre():
                self.key("p", ["command"], window=w0)
                time.sleep(0.25)
                for ch in self.name_of(ws):
                    self.key(ch, target="palette")
                time.sleep(0.3)
            return pre
        enter = lambda: self.key("return", target="palette")  # noqa: E731
        plans["workspace_palette"] = (go(a), [(enter, shows(b), palette_query(b)), (enter, shows(a), palette_query(a))], WS)

        def focused_tab():
            pane = next((p for p in self.visible_panes(self.surfaces(), self.window_number(w0)) if p.get("focused")), {})
            return pane.get("pane"), pane.get("selected_tab")

        def tab_changed(report):
            pane = next((p for p in self.visible_panes(report, self.window_number(w0)) if p.get("focused")), {})
            return pane.get("selected_tab") not in (None, getattr(self, "tab_before", None))

        def tab_pre():
            self.tab_before = focused_tab()[1]
        plans["tab"] = (go(a), [(lambda: self.key("]", ["command", "shift"], window=w0), tab_changed, tab_pre),
                                (lambda: self.key("[", ["command", "shift"], window=w0), tab_changed, tab_pre)],
                        ("debug.tab_switch",))

        def pane_changed(report):
            pane = next((p for p in self.visible_panes(report, self.window_number(w0)) if p.get("focused")), {})
            return pane.get("pane") not in (None, getattr(self, "pane_before", None))

        def pane_pre():
            self.pane_before = focused_tab()[0]
        plans["pane"] = (go(a), [(lambda: self.key("right", ["command", "option"], window=w0), pane_changed, pane_pre),
                                 (lambda: self.key("left", ["command", "option"], window=w0), pane_changed, pane_pre)],
                         ("debug.pane_focus",))

        def front_changed(_report):
            order = (self.rpc("debug.windows") or {}).get("z_order") or []
            return bool(order) and order[0] != getattr(self, "front_before", None)

        def window_pre():
            self.front_before = ((self.rpc("debug.windows") or {}).get("z_order") or [None])[0]
        plans["window"] = ((lambda: None if len(win_ids) > 1 else "fewer than 2 windows"),
                           [(lambda: self.action("selectNextWindow"), front_changed, window_pre),
                            (lambda: self.action("selectPreviousWindow"), front_changed, window_pre)], WS)

        def home_back():
            reply = self.key("`", ["control", "command"], window=w0)
            if getattr(self, "home_back_action", False):
                reply = self.action("goToWorkspace", {"workspace": a})
            return reply

        def at_home():
            shown = self.window_workspace(w0)
            return self.window_page(w0) == "home" or (shown is not None and not str(shown).startswith("ss-"))

        def home_prepare():
            problem = go(a)()
            if problem:
                return problem
            reply = self.action("home.show")
            time.sleep(0.8)
            if not at_home():
                return f"home.show does not show Home in window 0 ({str(reply)[:160]}, shows {self.window_workspace(w0)})"
            self.home_name = self.window_workspace(w0)
            self.key("`", ["control", "command"], window=w0)
            time.sleep(0.8)
            if at_home() or self.window_workspace(w0) != self.name_of(a):
                self.home_back_action = True
                self.say("home: Ctrl-Cmd-` does not leave Home; back is goToWorkspace (action.run)")
                self.action("goToWorkspace", {"workspace": a})
                time.sleep(0.6)
            return None
        plans["home"] = (home_prepare, [(lambda: self.action("home.show"), lambda r: at_home()),
                                        (home_back, lambda r: not at_home() and self.window_workspace(w0) == self.name_of(a))],
                         WS)
        return plans

    def window_number(self, window_id):
        """debug.surfaces keys windows by NSWindow number; debug.layers names both."""
        layers = self.rpc("debug.layers") or {}
        for w in (layers.get("windows") or []) if isinstance(layers, dict) else []:
            if w.get("id") == window_id and isinstance(w.get("window_number"), (int, float)):
                return int(w["window_number"])
        return None

    def pane_keys(self, window_id):
        return {p.get("pane") for p in self.visible_panes(self.surfaces(), self.window_number(window_id))}

    def sidebar_rows(self):
        windows = (self.rpc("debug.sidebar_rows") or {}).get("windows") or []
        return [r for r in (windows[0].get("rows") if windows else []) or [] if str(r.get("key", "")).startswith("workspace(")]

    def sidebar_row(self, ws):
        name = self.name_of(ws)
        rows = self.sidebar_rows()
        return next((r for r in rows if r.get("title") == name or ws in str(r.get("key"))), None)

    def digit_prepare(self, w0, a, b):
        """Which Cmd-digit shows `a` and `b` (the hot workspaces are moved to the top: usually 1 and 2)."""
        self.digits = {}
        for d in "123456789":
            self.key(d, ["command"], window=w0)
            time.sleep(0.4)
            shown = self.window_workspace(w0)
            for ws in (a, b):
                if shown == self.name_of(ws) and ws not in self.digits:
                    self.digits[ws] = d
            if len(self.digits) == 2:
                return None
        return f"Cmd-1..9 reach {sorted(self.digits.values())} of the two hot workspaces"

    # ---------------------------------------------------------------- memory
    def run_memory(self, size, w0, a, steps=1000, every=100):
        usage = load("bench_idle", os.path.join(HERE, "bench_idle.py")).usage
        self.rpc("debug.window.focus", {"window": w0})
        self.action("goToWorkspace", {"workspace": a})
        time.sleep(1)
        points = []

        def point(step):
            got = usage(self.pid)
            report = self.surfaces()
            points.append({"step": step, "footprint_mb": round(got[2] / 1048576, 1) if got else None,
                           "live_terminals": report.get("live_terminals"), "parked_workspaces": report.get("parked_workspaces"),
                           "t": round(time.time() - self.started, 1)})
            self.say(f"memory {size} step {step}: {points[-1]}")
        point(0)
        done = 0
        for step in range(1, steps + 1):
            if self.time_left() < 20:
                break
            self.key("]", ["control", "command"], window=w0)
            done = step
            time.sleep(0.03)
            if step % every == 0:
                time.sleep(0.5)
                point(step)
        mbs = [p["footprint_mb"] for p in points if p["footprint_mb"] is not None]
        return {"steps": done, "points": points, "start_mb": mbs[0] if mbs else None, "end_mb": mbs[-1] if mbs else None,
                "growth_mb": round(mbs[-1] - mbs[0], 1) if len(mbs) > 1 else None}

    # ---------------------------------------------------------------- one size
    def run_size(self, size):
        entry = {"size": size, "kinds": {}}
        fx, rooms, ws_ids, hot, hot_made, made = self.realize(size)
        entry["fixture"] = self.fixture.summary(fx)
        entry["realized"] = made
        entry["hot"] = hot
        entry["hot_shape"] = {str(i): {"screens": len(r["screens"]), "panes": sum(len(s["panes"]) for s in r["screens"]),
                                       "tabs": sum(len(p["tabs"]) for s in r["screens"] for p in s["panes"])}
                              for i, r in hot_made.items()}
        win_ids = self.place(fx, rooms, ws_ids, hot, made)
        self.w0 = win_ids[0]
        entry["windows"] = win_ids
        surf = self.surfaces()
        entry["after_place"] = {"live_terminals": surf.get("live_terminals"), "blank_panes": surf.get("blank_panes"),
                                "parked": surf.get("parked_workspaces"), "windows": len(surf.get("windows") or [])}
        self.say(f"placed {len(win_ids)} windows; surfaces {entry['after_place']}")
        self.results["sizes"][str(size)] = entry
        self.save()
        baseline = self.idle_baseline()
        entry["idle_baseline"] = baseline
        self.say(f"idle baseline {baseline}")
        plans = self.plans(size, fx, hot, win_ids)
        kinds = [k for k in self.opts.kinds.split(",") if k]
        for kind in kinds:
            if self.time_left() < 40:
                self.missing(size, kind, "out of lease time before this kind")
                continue
            try:
                if kind == "memory":
                    space0 = [i for i in hot if i % fx["spaces"] == 0]
                    entry["kinds"][kind] = self.run_memory(size, win_ids[0], self.app_ws[space0[0]],
                                                           steps=self.opts.memory_steps)
                elif kind in plans:
                    got = self.run_kind(size, kind, plans[kind], baseline, self.opts.switches,
                                        window_number=self.window_number(win_ids[0]) if kind != "window" else None,
                                        typing=kind not in ("window", "workspace_palette"))
                    if got is not None:
                        entry["kinds"][kind] = got
                else:
                    self.missing(size, kind, "unknown kind")
            except Exception as error:  # one kind's failure never ends the run: the others still measure
                self.missing(size, kind, f"{type(error).__name__}: {error}")
            self.save()
        entry["hangs"] = self.rpc("debug.hangs", {})
        return entry

    def save(self):
        with open(os.path.join(self.out, "results.json"), "w") as f:
            json.dump(self.results, f, indent=1, default=str)

    def record(self):
        """result-v1 rows: switch_scale.<kind>.<size>.<metric> with every raw sample."""
        written = []
        if not self.bench_app or self.bench_app.features is None:
            self.say("result-v1: no features.list snapshot, no rows written")
            return written
        for size, entry in self.results["sizes"].items():
            for kind, got in (entry.get("kinds") or {}).items():
                if kind == "memory":
                    samples = [round(p["footprint_mb"] * 1048576) for p in got.get("points") or []
                               if p.get("footprint_mb") is not None]
                    if samples:
                        self.write_row(written, f"switch_scale.memory.{size}.footprint", "bytes", samples)
                    continue
                rows = got.get("rows") or []
                timer = got.get("timer_samples") or []
                metrics = {
                    "input_to_commit": [t["commit_ms"] + (t.get("input_ms") or 0) for t in timer
                                        if isinstance(t.get("commit_ms"), (int, float))],
                    "input_to_present": [r["input_to_present_ms"] for r in rows if r.get("input_to_present_ms") is not None],
                    "content_seen": [r["content_seen_ms"] for r in rows if r.get("content_seen_ms") is not None],
                    "main_busy": [r["main_busy_ms"] for r in rows if r.get("main_busy_ms") is not None],
                    "blank_frames": [round((r.get("blank_ms") or 0) / (got.get("refresh_ms") or 16.67), 2)
                                     for r in rows if r.get("sampled")],
                    "keys_live": [r["keys_live_ms"] for r in rows if r.get("keys_live_ms") is not None],
                    "missed_frames": [r["missed"] for r in rows if r.get("missed") is not None],
                }
                for metric, samples in metrics.items():
                    unit = "count" if metric in ("blank_frames", "missed_frames") else "ms"
                    if samples:
                        self.write_row(written, f"switch_scale.{kind}.{size}.{metric}", unit, samples)
        self.results["result_v1"] = written
        return written

    def write_row(self, written, metric, unit, samples):
        try:
            path = self.bench_app.record(STORY, metric, unit, samples, "lower", "chromium")
            written.append(os.path.relpath(str(path), self.out))
        except Exception as error:  # a row the writer refuses is named; the others still go
            self.say(f"result-v1 {metric}: {type(error).__name__}: {error}")

    def table(self):
        lines = ["kind | size | input->commit p50/p99 ms | input->present (slots) p50/p99 | content seen p50/p99 | main busy p50/p99 | blank frames | "
                 "missed frames | keys live p50/p99 | n"]
        for size, entry in self.results["sizes"].items():
            for kind, got in (entry.get("kinds") or {}).items():
                if kind == "memory":
                    lines.append(f"memory | {size} | footprint {got.get('start_mb')} -> {got.get('end_mb')} MB over "
                                 f"{got.get('steps')} switches")
                    continue
                f = lambda b: f"{b['p50']}/{b['p99']}"  # noqa: E731
                lines.append(f"{kind} | {size} | {f(got['input_to_commit_ms'])} ({got['timer'] or 'no timer'}) | "
                             f"{f(got.get('input_to_present_ms') or {'p50': None, 'p99': None})} | "
                             f"{f(got['content_seen_ms'])} | {f(got['main_busy_ms'])} | {got['blank_frames_total']} "
                             f"({got['switches_with_blank']} sw) | {got['missed_frames_total']} | {f(got['keys_live_ms'])} | "
                             f"{got['switches']}")
        return "\n".join(lines)

    def main(self):
        self.attach()
        self.results["host"] = self.host_block()
        self.say(f"host {self.results['host']}")
        sizes = [int(s) for s in self.opts.workspaces.split(",") if s.strip()]
        if self.opts.socket and len(sizes) > 1:
            self.say(f"a slot app runs one size per launch: {sizes[0]} only")
            sizes = sizes[:1]
        try:
            for index, size in enumerate(sizes):
                if index and not self.opts.socket:
                    self.bench_app.stop()
                    self.bench_app.launch(timeout=180)
                    self.socket = self.bench_app.socket
                    self.connect()
                self.run_size(size)
                self.save()
            self.record()
            self.results["table"] = self.table()
            self.say("\n" + self.results["table"])
        finally:
            self.save()
            if self.pages:
                self.pages.close()
            if not self.opts.socket and self.bench_app and self.opts.stop:
                self.bench_app.stop()
        return 0


def pick_list(obj):
    """The first list of dicts anywhere in `obj`."""
    if isinstance(obj, list) and obj and all(isinstance(x, dict) for x in obj):
        return obj
    if isinstance(obj, dict):
        for value in obj.values():
            found = pick_list(value)
            if found:
                return found
    return None


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    rest = []
    if "--" in argv:
        cut = argv.index("--")
        argv, rest = argv[:cut], argv[cut + 1:]
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--app", help="the tagged bench app (with --socket: the slot's clone)")
    parser.add_argument("--tag")
    parser.add_argument("--out", required=True)
    parser.add_argument("--socket", help="an app a capture slot launched: measure it, launch nothing")
    parser.add_argument("--workspaces", default="10,1000")
    parser.add_argument("--switches", type=int, default=200)
    parser.add_argument("--kinds", default=",".join(ALL_KINDS))
    parser.add_argument("--hot-terminals", type=int, default=300)
    parser.add_argument("--memory-steps", type=int, default=1000)
    parser.add_argument("--max-seconds", type=float, default=3600.0)
    parser.add_argument("--stop", action="store_true", help="quit the launched app at the end")
    parser.add_argument("--no-chats", action="store_true",
                        help="leave the hot set's agent chat tabs out (build 5aad318 aborts when one is freed in a switch)")
    parser.add_argument("--build-sha", help="the build's commit, for result-v1 when the bundle names none (CMUX_CI_SHA)")
    parser.add_argument("--sample", action="store_true",
                        help="`sample` the app for the first seconds of each kind (OUT/sample-<kind>-<size>.txt); "
                             "the sampler slows the app, so a sampled run is a profile, not a number")
    parser.add_argument("--slot-job", help="from the fleet VM: lease a capture slot and run there on build JOB")
    parser.add_argument("--slot-artifact", help="the build's app zip on this machine, staged by scp when the host lacks it")
    parser.add_argument("--slot-hosts", help="capture hosts to lease from (spaces), never cmux16")
    parser.add_argument("--lease-seconds", type=int, default=600)
    opts = parser.parse_args(argv)
    if opts.slot_job:
        return slot_main(opts, rest)
    if not opts.app:
        parser.error("--app is required")
    if opts.build_sha:
        os.environ["CMUX_CI_SHA"] = opts.build_sha
    return Bench(opts).main()


if __name__ == "__main__":
    sys.exit(main())
