#!/usr/bin/env python3
"""Restore fuzz (fuzz catalog row f) and its chaos modes (row h), on a fleet capture slot.

    restore-fuzz-slot.sh JOB OUT -- --seed S [--chaos none|hog|cpu|fd] [--targets app,daemon,acpmux]

restore-fuzz-slot.sh leases an exclusive slot, launches build JOB in it and runs this file on the mini
(stock /usr/bin/python3, standard library only) against the slot's control socket. Each iteration:

  1. Starts from a fresh fuzz state: closes the fz-* workspaces, makes 1 to 3 new ones.
  2. Plays 1 to 6 seeded random actions (new workspace, split, new tab, close tab, close workspace,
     rename, write a line) through the tag's own daemon (the bundled `cmux` CLI). After each answer
     it reads the daemon's topology: that is the last CONFIRMED topology. An action that answered ok
     and did not change the topology as it says is a silent loss.
  3. Kills one process of THIS slot's build with SIGKILL, at a seeded point: between two actions
     (after a seeded pause) or while an action is in flight (after 0-250 ms). The target is the app
     (the pid the slot's socket names), its cmux-tui daemon (run from its bundle, its session) or its
     acpmux daemon (run from its bundle). Never another process.
  4. Relaunches what is needed (the app as a person does: `open -g -n -a` with its own launch
     variables; a killed daemon or acpmux is the app's to restart), and waits for restore to settle.
  5. The oracle: the restored daemon topology equals the last confirmed one (with an action in flight:
     the confirmed one, or the confirmed one plus exactly that action, and the action's effect when it
     answered ok before the kill); every confirmed terminal is there and still shows its marker line;
     no workspace or tab twice; the app shows the same workspaces and tabs as the daemon.

Chaos (row h), on top of the same oracle: `hog` runs the Austin's-day memory hog (hog.py, the smoke
gate's) for the whole run; `cpu` runs one busy process per core at user-interactive QoS; `fd` relaunches
the app with RLIMIT_NOFILE 256 (exec of its executable with the slot's variables instead of `open`);
`slowdisk` relaunches it under `taskpolicy -d throttle` (macOS's per-process disk I/O throttle). The
limit and the throttle reach the daemon only when the new app starts a new one (a daemon kill).
Under chaos an action may fail, but only with an answer (a typed error) within its bound, never a hang
or an ok without its effect.

Output in OUT: iterations.jsonl (one line per iteration: seed, actions, kill, timings, verdict),
violations.json (each with the iteration seed, its actions and the shrink attempts) and journey.log.
The last lines of stdout are the oracle's: `RESTORE-FUZZ VIOLATION ...` per violation and one
`RESTORE-FUZZ SUMMARY ...`. Exit 0 when no violation, 1 with one, 75 when nothing was judged.
"""
import argparse
import ctypes
import json
import os
import plistlib
import random
import re
import resource
import signal
import socket
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_names  # noqa: E402  (shipped beside this file by the slot script)

ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
ap.add_argument("--socket", required=True, help="the slot app's control socket")
ap.add_argument("--out", required=True)
ap.add_argument("--max-seconds", type=float, default=480, help="stop starting iterations after this")
ap.add_argument("--seed", type=int, default=None, help="the run's seed (default: from the clock, printed)")
ap.add_argument("--iterations", type=int, default=0, help="at most this many (0: until --max-seconds)")
ap.add_argument("--targets", default="app,daemon,acpmux")
ap.add_argument("--chaos", default="none", choices=["none", "hog", "cpu", "fd", "slowdisk"])
ap.add_argument("--hog-swap-gb", type=float, default=15.0)
ap.add_argument("--replay", help="a violations.json: replay its first violation's iteration seed and shrink it")
# Passed by the slot runner for restore-journey.py; unused here.
ap.add_argument("--fake-agent")
ap.add_argument("--src")
opts = ap.parse_args()
os.makedirs(opts.out, exist_ok=True)
LOG = open(os.path.join(opts.out, "journey.log"), "a")
T0 = time.time()
ACTION_BOUND = 10.0  # seconds an action may take before it is a stall (row h: a hang)
SETTLE_BOUND = 60.0  # seconds from the kill to a settled restore
MAX_WS, MAX_TABS = 5, 4


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(time.strftime("%H:%M:%S ") + line + "\n")
    LOG.flush()


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        if os.getppid() == 1:
            sys.exit("restore-fuzz: parent gone; stopping")
        got = predicate()
        if got:
            return got
        time.sleep(step)
    return None


def rpc(method, params=None, timeout=20):
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


def ps_table():
    out = subprocess.run(["ps", "axo", "pid=,ppid=,args="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


class App:
    """The slot's app: identity from its socket, its daemon and acpmux by its bundle path."""

    def __init__(self):
        self.refresh()
        self.bundle = self.info.get("app_bundle_path")
        self.cli_path = self.info.get("app_cli_path") or os.path.join(self.bundle, "Contents/Resources/bin/cmux")
        self.tag = self.info.get("tag")
        self.bundle_id = self.info.get("bundle_id") or ""
        self.env = self.environment(self.pid)
        self.check_target()
        try:
            names = build_names.of_app(self.bundle)
        except ValueError:
            names = {}
        self.sessions = [s for s in (names.get("session"), f"cmux-app-{self.tag}") if s]
        say(f"app pid {self.pid} tag {self.tag} bundle {self.bundle} sessions {self.sessions}")

    def refresh(self):
        info = rpc("system.identify")
        if not isinstance(info, dict) or "error" in info or not info.get("pid"):
            sys.exit(f"no app answers on {opts.socket}: {info}")
        self.info, self.pid = info, int(info["pid"])

    def check_target(self):
        """Only a capture slot's tagged DEV build, never a person's cmux."""
        problems = []
        if not self.tag:
            problems.append("no tag")
        if ".debug" not in self.bundle_id:
            problems.append(f"bundle id {self.bundle_id!r} is not a DEV build's")
        if not self.bundle or self.bundle.startswith("/Applications/"):
            problems.append(f"bundle {self.bundle!r} is an installed app")
        if "capslot" not in self.bundle_id and not self.env.get("CMUX_CAPTURE_SLOT"):
            problems.append("not a capture slot's app")
        if problems:
            sys.exit("restore-fuzz refuses this app: " + "; ".join(problems))

    @staticmethod
    def environment(pid):
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
        env = {}
        for word in out.split():
            key, sep, value = word.partition("=")
            if sep and (key.startswith("CMUX_") or key in ("HOME", "TMPDIR")):
                env[key] = value
        return env

    def alive(self, pid=None):
        try:
            os.kill(pid or self.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def mine(self, args):
        return args.startswith(self.bundle + "/")

    def daemon_pids(self):
        return [pid for pid, _, args in ps_table() if self.mine(args) and "--headless" in args
                and any(f"--session {s} " in args + " " for s in self.sessions)]

    def daemon_socket(self):
        for _, _, args in ps_table():
            if self.mine(args) and "--headless" in args and any(f"--session {s} " in args + " " for s in self.sessions):
                found = re.search(r"--socket (\S+)", args)
                if found:
                    return found.group(1)
        return None

    def acpmux_pids(self):
        """acpmux daemons run from this bundle (`.../acpmux daemon run ...`)."""
        return [pid for pid, _, args in ps_table() if self.mine(args)
                and re.search(r"/acpmux(\s|$)", args.split(" daemon")[0] + " ") and " daemon" in args]

    def relaunch(self):
        if os.path.exists(opts.socket):
            try:
                os.unlink(opts.socket)
            except OSError:
                pass
        if opts.chaos in ("fd", "slowdisk"):
            # exec of the executable itself, so the limit or the I/O policy is the app's and its children's
            # (LaunchServices would not keep either). slowdisk: taskpolicy -d throttle, macOS's own per-process
            # disk I/O throttle (inherited by the daemon the app starts); no host setting changes.
            with open(os.path.join(self.bundle, "Contents", "Info.plist"), "rb") as f:
                exe = plistlib.load(f).get("CFBundleExecutable")
            env = dict(os.environ, **self.env)

            def lower():
                resource.setrlimit(resource.RLIMIT_NOFILE, (256, 256))
                os.setsid()
            argv = [os.path.join(self.bundle, "Contents", "MacOS", exe)]
            if opts.chaos == "slowdisk":
                argv = ["/usr/sbin/taskpolicy", "-d", "throttle", *argv]
            subprocess.Popen(argv, env=env, preexec_fn=lower if opts.chaos == "fd" else os.setsid,
                             stdin=subprocess.DEVNULL, stdout=open(os.path.join(opts.out, "app-fd.out"), "a"),
                             stderr=subprocess.STDOUT)
        else:
            args = ["/usr/bin/open", "-g", "-n", "-a", self.bundle]
            for key, value in self.env.items():
                args += ["--env", f"{key}={value}"]
            subprocess.run(args, check=True)
        up = wait(lambda: os.path.exists(opts.socket) and isinstance(rpc("system.identify", timeout=3), dict)
                  and rpc("system.identify", timeout=3).get("pid"), 60, 0.5)
        if not up:
            return False
        self.refresh()
        say(f"  relaunched: pid {self.pid}")
        return True


def cli(*args, timeout=ACTION_BOUND):
    """The bundled `cmux --json` on the tag's daemon: (answer, seconds)."""
    started = time.time()
    sock = APP.daemon_socket()
    if not sock:
        return {"error": "no daemon socket"}, time.time() - started
    env = {"HOME": APP.env.get("HOME", os.environ["HOME"]), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}
    try:
        r = subprocess.run([APP.cli_path, "--socket", sock, "--json", *args], capture_output=True, text=True,
                           timeout=timeout, env=env)
        try:
            answer = json.loads(r.stdout)
        except ValueError:
            answer = {"error": (r.stdout + r.stderr).strip()[:400] or f"exit {r.returncode}"}
    except subprocess.TimeoutExpired:
        answer = {"error": f"no answer within {timeout} s", "stall": True}
    return answer, time.time() - started


def value(answer):
    return answer.get("value", answer) if isinstance(answer, dict) else {}


def listed(answer, key):
    v = value(answer)
    if isinstance(v, list):
        return v
    if isinstance(v, dict):
        got = v.get(key, v.get("items"))
        return got if isinstance(got, list) else []
    return []


def first(d, *keys):
    for key in keys:
        if isinstance(d, dict) and d.get(key) is not None:
            return d.get(key)
    return None


SEEN_SHAPE = []
FZ_IDS = set()  # workspace ids the fuzz made (from the create answers): names alone may not show in the list
CREATES = []    # (name, id, answer) of creates that answered without an error, for the evidence


def created(name, answer):
    """Records a workspace create's answer; its workspace id or None."""
    v = value(answer) if isinstance(answer, dict) else {}
    wid = first(v, "workspace_id", "id") if isinstance(v, dict) else None
    if not CREATES or len(CREATES) < 3:
        say(f"  workspace create {name} answer: {json.dumps(answer)[:500]}")
    if "error" not in answer:
        CREATES.append((name, wid, json.dumps(answer)[:300]))
        if wid:
            FZ_IDS.add(wid)
    else:
        say(f"  workspace create failed: {json.dumps(answer)[:300]}")
    return wid


def daemon_state():
    """The daemon's fz-* topology: {ws_id: {"name", "tabs": {tab_id: terminal_id}, "panes": n}}, or None."""
    wsl, _ = cli("workspace", "list")
    if not SEEN_SHAPE:
        SEEN_SHAPE.append(1)
        say(f"  first workspace list answer: {json.dumps(wsl)[:600]}")
    if "error" in wsl:
        say(f"  workspace list failed: {json.dumps(wsl)[:300]}")
        return None
    out = {}
    for ws in listed(wsl, "workspaces"):
        name = first(ws, "name", "title") or ""
        wid = first(ws, "id", "workspace_id")
        if not str(name).startswith("fz-") and wid not in FZ_IDS:
            continue
        tabs, _ = cli("tab", "list", "--workspace", wid)
        panes, _ = cli("pane", "list", "--workspace", wid)
        if "error" in tabs or "error" in panes:
            return None
        out[wid] = {"name": name,
                    "tabs": {first(t, "id", "tab_id"): first(t, "terminal_id", "terminal") for t in listed(tabs, "tabs")},
                    "panes": sorted(first(p, "id", "pane_id") for p in listed(panes, "panes"))}
    return out


def app_state():
    """The app's fz-* workspaces as it shows them: {name: sorted tab ids}."""
    snap = rpc("snapshot.get")
    topo = snap.get("topology") if isinstance(snap, dict) else None
    if not isinstance(topo, dict):
        return None
    out = {}
    for ws in topo.get("workspaces", []):
        if (ws.get("name") or "").startswith("fz-") or ws.get("id") in FZ_IDS:
            out.setdefault(ws["name"], []).extend(t.get("id") for s in ws.get("screens", []) for p in s.get("panes", [])
                                                  for t in p.get("tabs", []))
    return {k: sorted(v) for k, v in out.items()}, bool(topo.get("loaded"))


def canon(state):
    """Comparable form: {name: (sorted tab ids, pane count)}."""
    return {w["name"]: (sorted(w["tabs"]), len(w["panes"])) for w in (state or {}).values()}


MARKS = {}  # terminal id -> marker line it printed


def mark(terminal):
    if terminal and terminal not in MARKS:
        MARKS[terminal] = f"FZM-{terminal[-8:]}"
        cli("terminal", terminal, "write", "--text", f"echo {MARKS[terminal]}\n")


def screen_has(terminal, text):
    got, _ = cli("terminal", terminal, "screen", "read")
    return text in json.dumps(got)


# ---- actions -----------------------------------------------------------------------------------

class Run:
    def __init__(self, seed):
        self.seed, self.rng, self.n = seed, random.Random(seed), 0

    def name(self):
        self.n += 1
        return f"fz-{self.seed % 100000:05d}-{self.n}"


def pick_action(run, state):
    """One action the current state allows: (kind, params)."""
    wss = list(state.items())
    kinds = ["write", "rename"]
    if len(wss) < MAX_WS:
        kinds += ["ws_create"] * 2
    roomy = [(wid, w) for wid, w in wss if len(w["tabs"]) < MAX_TABS]
    if roomy:
        kinds += ["split"] * 3 + ["tab_new"] * 2
    if any(len(w["tabs"]) > 1 for _, w in wss):
        kinds += ["tab_close"] * 2
    if len(wss) > 1:
        kinds += ["ws_close"]
    kind = run.rng.choice(kinds)
    if kind == "ws_create":
        return kind, {"name": run.name()}
    if kind in ("split", "tab_new"):
        wid, w = run.rng.choice(roomy)
        return kind, {"ws": wid, "pane": run.rng.choice(w["panes"]), "dir": run.rng.choice(["right", "down"])}
    if kind == "tab_close":
        wid, w = run.rng.choice([(i, w) for i, w in wss if len(w["tabs"]) > 1])
        return kind, {"ws": wid, "tab": run.rng.choice(sorted(w["tabs"]))}
    if kind == "ws_close":
        return kind, {"ws": run.rng.choice(wss)[0]}
    wid, w = run.rng.choice(wss)
    if kind == "rename":
        return kind, {"ws": wid, "name": run.name()}
    return kind, {"ws": wid, "terminal": run.rng.choice([t for t in w["tabs"].values() if t] or [None])}


def do_action(kind, p):
    """Runs one action on the daemon: (answer, seconds)."""
    if kind == "ws_create":
        answer, took = cli("workspace", "create", "--name", p["name"])
        created(p["name"], answer)
        mark(value(answer).get("terminal_id") if isinstance(value(answer), dict) else None)
    elif kind == "split":
        answer, took = cli("pane", p["pane"], "split", f"--{p['dir']}")
        mark(value(answer).get("terminal_id") if isinstance(value(answer), dict) else None)
    elif kind == "tab_new":
        answer, took = cli("tab", "create", "terminal", "--workspace", p["ws"], "--pane", p["pane"])
        mark(value(answer).get("terminal_id") if isinstance(value(answer), dict) else None)
    elif kind == "tab_close":
        answer, took = cli("tab", p["tab"], "close")
    elif kind == "ws_close":
        answer, took = cli("workspace", p["ws"], "close")
    elif kind == "rename":
        answer, took = cli("workspace", p["ws"], "rename", "--name", p["name"])
    else:
        if not p.get("terminal"):
            return {"ok": True, "skipped": "no terminal"}, 0.0
        answer, took = cli("terminal", p["terminal"], "write", "--text", "echo fz-write\n")
    return answer, took


def effect_ok(kind, p, before, after, answer):
    """Did an action that answered ok change the topology as it says? (reason or None)"""
    b, a = canon(before), canon(after)
    if kind == "ws_create":
        return None if p["name"] in a and len(a) == len(b) + 1 else f"ws_create {p['name']} answered ok but is not listed"
    name = (before or {}).get(p.get("ws"), {}).get("name")
    if kind in ("split", "tab_new"):
        got = len(a.get(name, ([], 0))[0]) - len(b.get(name, ([], 0))[0])
        return None if got == 1 else f"{kind} in {name} answered ok but the tab count changed by {got}"
    if kind == "tab_close":
        tabs = a.get(name, ([], 0))[0]
        return None if p["tab"] not in tabs else f"tab_close {p['tab']} answered ok but the tab is still listed"
    if kind == "ws_close":
        return None if name not in a else f"ws_close {name} answered ok but it is still listed"
    if kind == "rename":
        return None if p["name"] in a and name not in a else f"rename {name} -> {p['name']} answered ok but names are {sorted(a)}"
    return None if a == b else "write changed the topology"


def allowed_after(kind, p, confirmed, restored):
    """With an action in flight at the kill: is `restored` the confirmed state plus exactly that action?"""
    c, r = canon(confirmed), canon(restored)
    name = (confirmed or {}).get(p.get("ws"), {}).get("name")
    if kind == "ws_create":
        extra = {k: v for k, v in r.items() if k not in c}
        rest = {k: v for k, v in r.items() if k in c}
        return rest == c and list(extra) == [p["name"]]
    if kind in ("split", "tab_new"):
        if {k: v for k, v in r.items() if k != name} != {k: v for k, v in c.items() if k != name} or name not in r:
            return False
        return set(c[name][0]) < set(r[name][0]) and len(r[name][0]) == len(c[name][0]) + 1
    if kind == "tab_close":
        if {k: v for k, v in r.items() if k != name} != {k: v for k, v in c.items() if k != name} or name not in r:
            return False
        return sorted(t for t in c[name][0] if t != p["tab"]) == r[name][0]
    if kind == "ws_close":
        return r == {k: v for k, v in c.items() if k != name}
    if kind == "rename":
        moved = dict(c)
        if name in moved:
            moved[p["name"]] = moved.pop(name)
        return r == moved
    return r == c


# ---- kill and restore --------------------------------------------------------------------------

def kill(target):
    """SIGKILL the target's pids (only this slot's build); the pids killed."""
    if target == "app":
        answer = rpc("system.identify", timeout=5)
        if not (isinstance(answer, dict) and int(answer.get("pid") or 0) == APP.pid and APP.alive()):
            return []
        pids = [APP.pid]
    elif target == "daemon":
        pids = APP.daemon_pids()
    else:
        pids = APP.acpmux_pids()
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    return pids


def restore(target, killed_at, old_daemons):
    """Brings the build back after the kill and waits for it to settle; (state, timings, problem)."""
    timings = {}
    if target == "app":
        if not wait(lambda: not APP.alive(), 10, 0.1):
            return None, timings, "the killed app pid is still alive"
        if not APP.relaunch():
            return None, timings, "the relaunched app never answered on its socket"
        timings["app_answers_s"] = round(time.time() - killed_at, 2)
    elif target == "daemon":
        if not wait(lambda: (lambda pids: pids and not set(pids) & set(old_daemons))(APP.daemon_pids()), SETTLE_BOUND, 0.25):
            return None, timings, f"no new daemon within {SETTLE_BOUND:.0f} s of the kill (app alive: {APP.alive()})"
        timings["new_daemon_s"] = round(time.time() - killed_at, 2)
    prev = [None]

    def stable():
        snap = app_state()
        if not snap or not snap[1]:
            return None
        state = daemon_state()
        if state is None:
            return None
        if prev[0] is not None and canon(prev[0]) == canon(state):
            return state
        prev[0] = state
        return None
    state = wait(stable, SETTLE_BOUND, 0.5)
    timings["settled_s"] = round(time.time() - killed_at, 2)
    if state is None:
        return None, timings, f"restore did not settle within {SETTLE_BOUND:.0f} s (app answers: {APP.alive()})"
    return state, timings, None


def judge(state, expected, inflight):
    """The oracle after a restore: a list of problems (empty = pass)."""
    problems = []
    ok_exact = canon(state) == canon(expected)
    if inflight:
        kind, p, answered_ok = inflight
        ok_after = allowed_after(kind, p, expected, state)
        if answered_ok and not ok_after and not (kind == "write" and ok_exact):
            problems.append(f"{kind} answered ok before the kill, but its effect is not in the restored topology")
        elif not answered_ok and not (ok_exact or ok_after):
            problems.append(f"restored topology is neither the confirmed one nor the confirmed one plus the in-flight {kind}")
    elif not ok_exact:
        problems.append("restored topology differs from the last confirmed one")
    if problems:
        problems.append(f"confirmed {json.dumps(canon(expected), sort_keys=True)[:600]} restored {json.dumps(canon(state), sort_keys=True)[:600]}")
    names = [w["name"] for w in state.values()]
    if len(names) != len(set(names)):
        problems.append(f"a workspace name is listed twice: {sorted(names)}")
    tabs = [t for w in state.values() for t in w["tabs"]]
    if len(tabs) != len(set(tabs)):
        problems.append("a tab is listed twice")
    terms = [t for w in state.values() for t in w["tabs"].values() if t]
    if len(terms) != len(set(terms)):
        problems.append("a terminal is listed twice")
    # No lost terminal: every confirmed terminal that is still listed shows its marker line.
    want = {t for w in expected.values() for t in w["tabs"].values() if t}
    for terminal in sorted(want & set(terms)):
        if terminal in MARKS and not wait(lambda: screen_has(terminal, MARKS[terminal]), 10, 0.5):
            problems.append(f"terminal {terminal} is listed but no longer shows its line {MARKS[terminal]}")
    # The app shows what the daemon has.
    app = wait(lambda: (lambda s: s and s[0] == {w["name"]: sorted(w["tabs"]) for w in state.values()} and s)(app_state()), 15, 0.5)
    if not app:
        problems.append(f"the app does not show the daemon's fz workspaces: app {json.dumps((app_state() or [None])[0])[:300]}")
    return problems


# ---- one iteration -----------------------------------------------------------------------------

def fresh(run):
    for wid in list((daemon_state() or {})):
        cli("workspace", wid, "close")
    wait(lambda: daemon_state() == {}, 20, 0.5)
    names = []
    for _ in range(run.rng.randint(1, 3)):
        names.append(run.name())
        answer, _ = cli("workspace", "create", "--name", names[-1])
        created(names[-1], answer)
        mark(value(answer).get("terminal_id") if isinstance(value(answer), dict) else None)
    state = daemon_state()
    listed_names = {w["name"] for w in (state or {}).values()}
    missing = [n for n in names if n not in listed_names]
    if state is not None and missing:
        wsl, _ = cli("workspace", "list")
        say(f"  SUSPECT: create of {missing} answered ok but the list names {sorted(listed_names)}; "
            f"list: {json.dumps(wsl)[:600]}")
    return state


def iteration(seed, targets, keep=None):
    """One seeded iteration; `keep`: only these action indexes (shrinking). A record dict."""
    run = Run(seed)
    rec = {"seed": seed, "chaos": opts.chaos, "actions": [], "problems": []}
    confirmed = fresh(run)
    if not confirmed:
        rec["problems"].append(f"no fz workspace in the daemon topology at the start ({confirmed!r}); "
                               f"creates that answered ok: {CREATES[-3:]}")
        rec["verdict"] = "not run"
        return rec
    count = run.rng.randint(1, 6)
    target = run.rng.choice(targets)
    inflight_kill = run.rng.random() < 0.4
    pause = run.rng.uniform(0, 1.5) if not inflight_kill else run.rng.uniform(0, 0.25)
    plan = []
    state = confirmed
    for index in range(count):
        kind, p = pick_action(run, state)
        last = index == count - 1
        if keep is not None and index not in keep and not last:
            continue
        plan.append((kind, p))
        if last and inflight_kill:
            break
        answer, took = do_action(kind, p)
        after = daemon_state()
        entry = {"i": index, "kind": kind, "params": p, "s": round(took, 3), "ok": "error" not in answer}
        if "error" in answer:
            entry["error"] = str(answer.get("error"))[:200]
            if answer.get("stall"):
                rec["problems"].append(f"{kind} gave no answer within {ACTION_BOUND:.0f} s")
        elif after is not None:
            silent = effect_ok(kind, p, state, after, answer)
            if silent:
                rec["problems"].append("silent loss: " + silent)
        rec["actions"].append(entry)
        if after is not None:
            state = confirmed = after
    rec.update(target=target, point="in flight" if inflight_kill else "between", pause_s=round(pause, 3))
    old_daemons = APP.daemon_pids()
    inflight = None
    if inflight_kill and plan:
        kind, p = plan[-1]
        box = {}

        def go():
            box["answer"], box["s"] = do_action(kind, p)
            box["at"] = time.time()
        th = threading.Thread(target=go, daemon=True)
        th.start()
        time.sleep(pause)
        killed_at = time.time()
        pids = kill(target)
        th.join(ACTION_BOUND + 5)
        answered_ok = "at" in box and box["at"] <= killed_at and "error" not in box.get("answer", {"error": 1})
        inflight = (kind, p, answered_ok)
        rec["actions"].append({"i": count - 1, "kind": kind, "params": p, "inflight": True, "answered_ok_before_kill": answered_ok,
                               "answer": str(box.get("answer"))[:200]})
    else:
        time.sleep(pause)
        killed_at = time.time()
        pids = kill(target)
    rec["killed"] = pids
    if not pids:
        rec["verdict"] = "not run"
        rec["problems"].append(f"no {target} process of this build to kill")
        return rec
    say(f"  iter seed {seed}: {len(rec['actions'])} actions, SIGKILL {target} {pids} ({rec['point']})")
    state, timings, problem = restore(target, killed_at, old_daemons)
    rec["timings"] = timings
    if problem:
        rec["problems"].append(problem)
    else:
        rec["problems"] += judge(state, confirmed, inflight)
    rec["verdict"] = "fail" if rec["problems"] else "pass"
    return rec


def shrink(rec, targets, deadline):
    """Drops actions one at a time while the iteration still fails; the attempts and the smallest failing kept set."""
    n = len(rec["actions"])
    keep = list(range(n))
    attempts = []
    for drop in range(n - 1):
        if time.time() > deadline:
            break
        trial = [i for i in keep if i != drop]
        again = iteration(rec["seed"], targets, keep=set(trial))
        attempts.append({"keep": trial, "verdict": again["verdict"], "problems": again["problems"][:2]})
        if again["verdict"] == "fail":
            keep = trial
    return {"keep": keep, "attempts": attempts}


# ---- chaos -------------------------------------------------------------------------------------

CHAOS_PROCS = []


def start_chaos():
    if opts.chaos == "hog":
        hog = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hog.py")
        CHAOS_PROCS.append(subprocess.Popen(
            ["/usr/bin/python3", hog, "--swap-gb", str(opts.hog_swap_gb), "--deadline", str(int(T0 + opts.max_seconds + 60)),
             "--log", os.path.join(opts.out, "hog.jsonl")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        say(f"chaos hog: pid {CHAOS_PROCS[-1].pid}, --swap-gb {opts.hog_swap_gb}")
        time.sleep(20)  # let it reach pressure before the first iteration
    elif opts.chaos == "cpu":
        burn = ("import ctypes,time\n"
                "ctypes.CDLL(None).pthread_set_qos_class_self_np(0x21,0)\n"  # QOS_CLASS_USER_INTERACTIVE
                f"end=time.time()+{opts.max_seconds + 60}\n"
                "while time.time()<end: pass\n")
        for _ in range(os.cpu_count() or 8):
            CHAOS_PROCS.append(subprocess.Popen(["/usr/bin/python3", "-c", burn]))
        say(f"chaos cpu: {len(CHAOS_PROCS)} busy processes at user-interactive QoS")
    elif opts.chaos == "fd":
        say("chaos fd: every app relaunch runs with RLIMIT_NOFILE 256")
    elif opts.chaos == "slowdisk":
        say("chaos slowdisk: every app relaunch runs under taskpolicy -d throttle (disk I/O throttled)")


def stop_chaos():
    for proc in CHAOS_PROCS:
        try:
            proc.terminate()
            proc.wait(10)
        except (OSError, subprocess.TimeoutExpired):
            proc.kill()


# ---- main --------------------------------------------------------------------------------------

def main():
    global APP
    APP = App()
    targets = [t for t in opts.targets.split(",") if t in ("app", "daemon", "acpmux")]
    if "acpmux" in targets and not APP.acpmux_pids():
        say("no acpmux daemon of this build runs now; acpmux kills are judged only when one runs")
    seed = opts.seed if opts.seed is not None else int(time.time() * 1000) % (1 << 31)
    say(f"restore-fuzz seed {seed} chaos {opts.chaos} targets {targets}")
    master = random.Random(seed)
    deadline = T0 + opts.max_seconds
    records, violations = [], []
    start_chaos()
    try:
        if opts.replay:
            with open(opts.replay) as f:
                seeds = [json.load(f)[0]["record"]["seed"]]
        else:
            seeds = None
        i = 0
        while time.time() < deadline - 60 and (not opts.iterations or i < opts.iterations):
            it_seed = seeds[0] if seeds else master.randrange(1 << 31)
            rec = iteration(it_seed, targets)
            rec["iteration"] = i
            records.append(rec)
            with open(os.path.join(opts.out, "iterations.jsonl"), "a") as f:
                f.write(json.dumps(rec, default=str) + "\n")
            say(f"  -> {rec['verdict']} {rec.get('timings', {})} {'; '.join(rec['problems'])[:400]}")
            if rec["verdict"] == "fail":
                small = shrink(rec, targets, deadline - 30) if (seeds or len(violations) < 2) else None
                violations.append({"record": rec, "shrink": small})
                with open(os.path.join(opts.out, "violations.json"), "w") as f:
                    json.dump(violations, f, indent=1, default=str)
            i += 1
            if seeds:
                break
            if len(records) >= 3 and all(r["verdict"] == "not run" for r in records[-3:]):
                say("three iterations in a row did not run; stopping")
                break
    finally:
        stop_chaos()
    judged = [r for r in records if r["verdict"] in ("pass", "fail")]
    kills = {}
    for r in judged:
        kills[r["target"]] = kills.get(r["target"], 0) + 1
    settle = sorted(r["timings"]["settled_s"] for r in judged if r.get("timings", {}).get("settled_s") is not None)
    for v in violations:
        r = v["record"]
        say(f"RESTORE-FUZZ VIOLATION seed={r['seed']} iter={r['iteration']} chaos={opts.chaos} target={r.get('target')} "
            f"point={r.get('point')} keep={(v.get('shrink') or {}).get('keep')} what={r['problems'][0][:300]}")
    p = lambda q: settle[min(len(settle) - 1, int(q * len(settle)))] if settle else None
    say(f"RESTORE-FUZZ SUMMARY seed={seed} chaos={opts.chaos} iterations={len(records)} judged={len(judged)} "
        f"not_run={len(records) - len(judged)} kills={json.dumps(kills, sort_keys=True)} violations={len(violations)} "
        f"settle_s p50={p(0.5)} p95={p(0.95)} max={settle[-1] if settle else None}")
    sys.exit(1 if violations else (0 if judged else 75))


if __name__ == "__main__":
    main()
