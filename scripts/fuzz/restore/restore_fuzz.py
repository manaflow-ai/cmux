#!/usr/bin/env python3
"""Restore fuzz (fuzz catalog row f) and its chaos modes (row h), on a fleet capture slot.

    RJ_DRIVER=scripts/fuzz/restore/restore_fuzz.py RJ_DRIVER_FILES=scripts/cmux-next/austins-day/hog.py \
      scripts/cmux-next/restore-journey-slot.sh JOB OUT -- --seed S [--chaos none|hog|cpu|fd|slowdisk] [--targets ...]

restore-journey-slot.sh leases an exclusive slot, launches build JOB in it and runs this file on the mini
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
     the confirmed one, or the confirmed one plus exactly that action; an ok answer is the daemon's commit, so
     an action that answered ok must land, whenever the answer came); every confirmed terminal is there (same
     terminal id) and still shows its marker line; no workspace, tab or terminal twice (counted in the raw
     lists); the app shows the same workspaces and tabs as the daemon. An ok action must change only what it
     says (the other fz workspaces and the pane count included).

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
ap.add_argument("--chaos", default="none", choices=["none", "hog", "cpu", "fd", "fdsoft", "slowdisk", "exec", "diskfull"])
ap.add_argument("--visible", action="store_true", help="judge the visible state (debug.daemon, debug.surfaces) "
                "from each kill to the settle: no blank pane, every window shows content or the connecting view")
ap.add_argument("--disk-image-mb", type=int, default=512, help="diskfull: size of the image mounted at the daemon's state dir")
ap.add_argument("--disk-margin-mb", type=int, default=2, help="diskfull: free space left on that image")
ap.add_argument("--disk-recover-every", type=int, default=8, help="diskfull: every Nth iteration runs with the filler removed")
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
    """Prints and logs one line; a closed stdout (the ssh that started this run ended) never stops the caller."""
    line = " ".join(str(p) for p in parts)
    try:
        print(line, flush=True)
    except (OSError, ValueError):
        pass
    try:
        LOG.write(time.strftime("%H:%M:%S ") + line + "\n")
        LOG.flush()
    except (OSError, ValueError):
        pass


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
        self.full_env = self.environment(self.pid, every=True)  # for an exec relaunch: the whole launch environment
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
        if not (self.bundle or "").endswith(".app") or not os.path.isabs(self.bundle or ""):
            problems.append(f"bundle {self.bundle!r} is not an absolute .app path")
        if "capslot" not in self.bundle_id and not self.env.get("CMUX_CAPTURE_SLOT"):
            problems.append("not a capture slot's app")
        if problems:
            sys.exit("restore-fuzz refuses this app: " + "; ".join(problems))

    @staticmethod
    def environment(pid, every=False):
        """The app's launch variables from `ps eww` (same user): CMUX_*, HOME and TMPDIR, or (every) each KEY=VALUE word."""
        out = subprocess.run(["ps", "eww", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout
        env = {}
        for word in out.split():
            key, sep, value = word.partition("=")
            if not sep:
                continue
            if key.startswith("CMUX_") or key in ("HOME", "TMPDIR") or (every and re.fullmatch(r"[A-Z_][A-Z0-9_]*", key)):
                env[key] = value
        return env

    def exec_env(self):
        """The environment of an exec relaunch: this process's, then the app's whole launch environment, then its
        CMUX_/HOME/TMPDIR values (the same keys win; dict merges, never keyword arguments, so a key may repeat)."""
        env = dict(os.environ)
        env.update(self.full_env)
        env.update(self.env)
        return env

    def state_outside_slot(self):
        """A daemon of this build whose state dir (CMUX_TUI_STATE_DIR) or chief home is not under the slot's HOME, or
        None. An exec relaunch that lost part of the slot environment (2026-10-31, C4) made the next daemon keep its
        state in the mini account's home: a false restore loss, and writes outside the slot."""
        home = (self.env.get("HOME") or "").rstrip("/") + "/"
        for pid in self.daemon_pids():
            env = self.environment(pid, every=True)
            for key in ("CMUX_TUI_STATE_DIR", "CMUX_CHIEF_HOME"):
                if env.get(key) and not env[key].startswith(home):
                    return f"daemon {pid} {key}={env[key]} is not under the slot HOME {home}"
        return None

    child = None  # the Popen of an app this run started itself (fd, slowdisk): reaped, so a killed one is not a zombie

    def alive(self, pid=None):
        pid = pid or self.pid
        if self.child is not None and self.child.pid == pid:
            return self.child.poll() is None
        try:
            os.kill(pid, 0)
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
        if opts.chaos in ("fd", "fdsoft", "slowdisk", "exec"):
            # exec of the executable itself, so the limit or the I/O policy is the app's and its children's
            # (LaunchServices would not keep either). slowdisk: taskpolicy -d throttle, macOS's own per-process
            # disk I/O throttle (inherited by the daemon the app starts); no host setting changes.
            with open(os.path.join(self.bundle, "Contents", "Info.plist"), "rb") as f:
                exe = plistlib.load(f).get("CFBundleExecutable")
            env = self.exec_env()

            def lower():
                # fd: soft and hard 256 (the app cannot raise it); fdsoft: soft 256 with the hard limit kept, as
                # launchd gives a GUI app by default (the app may raise its own soft limit).
                hard = 256 if opts.chaos == "fd" else resource.getrlimit(resource.RLIMIT_NOFILE)[1]
                resource.setrlimit(resource.RLIMIT_NOFILE, (256, hard))
                os.setsid()
            argv = [os.path.join(self.bundle, "Contents", "MacOS", exe)]
            if opts.chaos == "slowdisk":
                argv = ["/usr/sbin/taskpolicy", "-d", "throttle", *argv]
            if self.child is not None:
                self.child.poll()
            self.child = subprocess.Popen(argv, env=env, preexec_fn=lower if opts.chaos in ("fd", "fdsoft") else os.setsid,
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
        if self.info.get("app_bundle_path") != self.bundle or (self.info.get("bundle_id") or "") != self.bundle_id:
            sys.exit(f"restore-fuzz: the relaunched app is not the slot build: {self.info.get('app_bundle_path')} "
                     f"{self.info.get('bundle_id')}")
        say(f"  relaunched: pid {self.pid}")
        return True


ENV_KEYS = ("HOME", "TMPDIR", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "USER", "LOGNAME", "PATH")
STATE_KEYS = ("CMUX_TUI_STATE_DIR", "CMUX_CHIEF_HOME", "CMUX_SOCKET_PATH", "CMUX_NEXT_CONFIG_FILE", "CMUX_CAPTURE_SLOT",
              "CMUX_CAPTURE_SHELL_HOME", "CMUX_TAG", "CMUX_BUNDLE_ID")


def proc_env(pid):
    """A process's argv (no environment) and the values of the state-path keys only (for the C4 check). Other
    CMUX_* keys are listed by name only: their values can hold a token and never go to OUT."""
    argv = subprocess.run(["ps", "-o", "args=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    env, names = {}, []
    for key, val in App.environment(pid, every=True).items():
        if key in ENV_KEYS or key in STATE_KEYS:
            env[key] = val
        elif key.startswith("CMUX_"):
            names.append(key)
    return {"pid": pid, "argv": argv[:600], "env": env, "other_cmux_keys": sorted(names)}


def host_rows():
    """This build's terminal hosts: launchd children with a bare `cmux-tui` argv that name their owner
    (`--bootstrap-stdio ... --owner <bundle id>:`, host_exe.rs). Read-only: pid, ppid, start time, argv."""
    owner = f"--owner {APP.bundle_id}:"
    out = subprocess.run(["ps", "axo", "pid=,ppid=,lstart=,args="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        if "--bootstrap-stdio" not in line or owner not in line:
            continue
        parts = line.split(None, 7)  # pid ppid + lstart's five words + args
        if len(parts) == 8 and parts[0].isdigit():
            rows.append({"pid": int(parts[0]), "ppid": int(parts[1]), "lstart": " ".join(parts[2:7]), "argv": parts[7][:600]})
    return rows


def log_hosts(label):
    """Terminal hosts of this build vs the terminals the daemon lists (session registry), to OUT/hosts.jsonl.
    A note for the terminal-host leak owner, not an oracle verdict."""
    hosts = host_rows()
    listed_answer, _ = cli("terminal", "list")
    terms = sorted({first(t, "id", "terminal_id") for t in listed(listed_answer, "terminals") if isinstance(t, dict)} - {None})
    # A host's argv names its owner and session, not its terminal id, so hosts are compared by count only.
    shown = sum(len(w["tabs"]) for w in (daemon_state() or {}).values())
    now = time.time()
    recent = sum(n for t, n in CLOSES if now - t <= REAP_GRACE)
    excess = len(terms) - shown - recent
    EXCESS_MAX[0] = max(EXCESS_MAX[0], len(terms) - shown)
    EXCESS_MAX[1] = max(EXCESS_MAX[1], excess)
    row = {"t": round(time.time() - T0, 2), "label": label, "hosts": len(hosts), "terminals_listed": len(terms),
           "hosts_minus_listed": len(hosts) - len(terms), "fz_tabs_shown": shown,
           "closed_last_30s": recent, "listed_minus_shown_minus_recent": excess, "sample_hosts": hosts[:3],
           "terminal_ids": terms[:200]}
    with open(os.path.join(opts.out, "hosts.jsonl"), "a") as f:
        f.write(json.dumps(row) + "\n")
    HOSTS_MAX[0] = max(HOSTS_MAX[0], len(hosts))
    return row


HOSTS_MAX = [0]
CLOSES = []          # (time of an ok close answer, terminals that close took off the topology)
EXCESS_MAX = [0, 0]  # max of listed - shown fz tabs; max of listed - shown - closed in the last 30 s
REAP_GRACE = 30.0    # the daemon's --terminal-reap-grace-seconds in a slot app


def note_close(answer, terminals):
    if isinstance(answer, (dict, list)) and "error" not in answer and terminals:
        CLOSES.append((time.time(), terminals))


def log_daemon_env(label):
    rows = {"app": proc_env(APP.pid), "daemons": [proc_env(pid) for pid in APP.daemon_pids()]}
    with open(os.path.join(opts.out, "daemon-env.jsonl"), "a") as f:
        f.write(json.dumps({"t": round(time.time() - T0, 2), "label": label, **rows}) + "\n")


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
    if isinstance(answer, dict) and "error" in answer and ACTION_ERRORS[0]:
        ERRORS.append({"cmd": " ".join(args[:2]), "error": str(answer.get("error"))[:300], "typed": typed_error(answer),
                       "stall": bool(answer.get("stall"))})
    return answer, time.time() - started


ERRORS = []  # error answers to the iteration's own actions and creates (not the harness's list reads)
ACTION_ERRORS = [False]  # set while do_action()/fresh() create calls run


def may_degrade(rec, errors):
    """A not-run iteration is "degraded" only when the full disk refused it with answers and nothing else went
    wrong: its one problem is the not-run reason, every error is a real answer (no stall), and there is one."""
    only_reason = (len(rec.get("problems", [])) == 1
                   and rec["problems"][0].startswith(("no fz workspace in the daemon topology at the start",
                                                      "the daemon topology could not be read after")))
    return rec.get("verdict") == "not run" and only_reason and bool(errors) and not any(e.get("stall") for e in errors)


def not_run_outcome(rec, errors):
    """The final verdict of a not-run iteration: "fail" when it saw a hang (a stalled answer) or any problem besides
    the not-run reason (a silent loss, a duplicate, an action with no answer); "degraded" for a pure answered
    refusal (may_degrade); otherwise "not run"."""
    if rec.get("verdict") != "not run":
        return rec.get("verdict")
    if any(e.get("stall") for e in errors):
        return "fail"
    reasons = ("no fz workspace in the daemon topology at the start", "the daemon topology could not be read after",
               "no app process of this build to kill", "no daemon process of this build to kill",
               "no acpmux process of this build to kill", "no recovery check: no time left in the lease")
    if any(not p.startswith(reasons) for p in rec.get("problems", [])):
        return "fail"
    return "degraded" if may_degrade(rec, errors) else "not run"


def kill_counts(records):
    kills = {}
    for r in records:
        if r.get("target") and r["verdict"] in ("pass", "fail", "degraded"):
            kills[r["target"]] = kills.get(r["target"], 0) + 1
    return kills


def typed_error(answer):
    """Is an error answer a typed one (a JSON error object with a code), not a bare string or a stall?"""
    if answer.get("stall"):
        return False
    err = answer.get("error")
    if isinstance(err, dict):
        return bool(err.get("code"))
    try:
        return bool(json.loads(err).get("code"))
    except (TypeError, ValueError, AttributeError):
        return False


def value(answer):
    """The answer's payload: `value` of an envelope, or the answer itself (a list answer is bare)."""
    if isinstance(answer, dict):
        return answer.get("value", answer)
    return answer if isinstance(answer, list) else {}


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
        if wid in out:  # the same workspace id listed twice: kept as evidence, never folded away
            out[wid]["dup_ws"] = out[wid].get("dup_ws", 0) + 1
            continue
        tabs, _ = cli("tab", "list", "--workspace", wid)
        panes, _ = cli("pane", "list", "--workspace", wid)
        if "error" in tabs or "error" in panes:
            return None
        raw = [(first(t, "id", "tab_id"), first(t, "terminal_id", "terminal")) for t in listed(tabs, "tabs")]
        out[wid] = {"name": name, "tabs": dict(raw), "raw_tabs": [t for t, _ in raw], "raw_terms": [x for _, x in raw if x],
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
        wid, w = run.rng.choice(wss)
        return kind, {"ws": wid, "tabs": len(w["tabs"])}
    wid, w = run.rng.choice(wss)
    if kind == "rename":
        return kind, {"ws": wid, "name": run.name()}
    return kind, {"ws": wid, "terminal": run.rng.choice([t for t in w["tabs"].values() if t] or [None])}


def do_action(kind, p):
    """Runs one action on the daemon: (answer, seconds)."""
    ACTION_ERRORS[0] = True
    try:
        return _do_action(kind, p)
    finally:
        ACTION_ERRORS[0] = False


def _do_action(kind, p):
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
        note_close(answer, 1)
    elif kind == "ws_close":
        answer, took = cli("workspace", p["ws"], "close")
        note_close(answer, p.get("tabs", 1))
    elif kind == "rename":
        answer, took = cli("workspace", p["ws"], "rename", "--name", p["name"])
    else:
        if not p.get("terminal"):
            return {"ok": True, "skipped": "no terminal"}, 0.0
        answer, took = cli("terminal", p["terminal"], "write", "--text", "echo fz-write\n")
    return answer, took


def effect_ok(kind, p, before, after, answer):
    """Did an action that answered ok change the topology exactly as it says, and nothing else? (reason or None)"""
    if allowed_after(kind, p, before, after):
        return None
    return (f"{kind} {json.dumps(p, sort_keys=True)[:160]} answered ok, but the topology is not the one before plus "
            f"exactly that action: before {json.dumps(canon(before), sort_keys=True)[:400]} "
            f"after {json.dumps(canon(after), sort_keys=True)[:400]}")


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
        panes = c[name][1] + (1 if kind == "split" else 0)  # a split makes a pane; a new tab joins one
        return set(c[name][0]) < set(r[name][0]) and len(r[name][0]) == len(c[name][0]) + 1 and r[name][1] == panes
    if kind == "tab_close":
        if {k: v for k, v in r.items() if k != name} != {k: v for k, v in c.items() if k != name} or name not in r:
            return False
        # The pane goes with its last tab.
        return sorted(t for t in c[name][0] if t != p["tab"]) == r[name][0] and r[name][1] in (c[name][1], c[name][1] - 1)
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


EVIDENCE_N = [0]


def report_of_build(path):
    """Is this crash report (.ips: JSON header line, then a JSON body with procPath; .crash: a `Path:` line) one of a
    process run from this slot's bundle?"""
    try:
        with open(path, "r", errors="replace") as f:
            head = f.read(1 << 20)
    except OSError:
        return False
    prefix = APP.bundle + "/"
    found = re.search(r'"procPath"\s*:\s*"((?:[^"\\]|\\.)*)"', head)
    if found:
        try:
            return json.loads('"' + found.group(1) + '"').startswith(prefix)
        except ValueError:
            return False
    found = re.search(r"^Path:\s+(.*)$", head, re.M)
    return bool(found) and found.group(1).strip().startswith(prefix)


def evidence(tag):
    """On a failed restore: what ran, what the daemon and the app showed, and any crash report of the build since
    the run began, copied into OUT/evidence-<tag>/ (read on the mini before the lease ends and its slot is reset)."""
    EVIDENCE_N[0] += 1
    folder = os.path.join(opts.out, f"evidence-{EVIDENCE_N[0]:03d}-{tag}")
    os.makedirs(folder)  # a new folder per failure: a shrink or replay of the same seed never overwrites the first
    rows = [f"{pid} {ppid} {args[:300]}" for pid, ppid, args in ps_table() if APP.mine(args)]
    snap = {"bundle_processes": rows, "app_alive": APP.alive(), "app_pid": APP.pid,
            "daemon_state": daemon_state(), "app_state": (app_state() or [None])[0]}
    time.sleep(30)
    snap["daemon_state_30s_later"] = daemon_state()
    snap["app_state_30s_later"] = (app_state() or [None])[0]
    snap["daemon_pids"] = APP.daemon_pids()
    with open(os.path.join(folder, "state.json"), "w") as f:
        json.dump(snap, f, indent=1, default=str)
    copied = []
    for home in {os.path.expanduser("~"), APP.env.get("HOME", "")}:
        reports = os.path.join(home, "Library", "Logs", "DiagnosticReports") if home else ""
        try:
            names = os.listdir(reports)
        except OSError:
            continue
        for name in names:
            full = os.path.join(reports, name)
            try:
                if os.path.getmtime(full) < T0 or not name.endswith((".ips", ".crash")) or not report_of_build(full):
                    continue
                with open(full, "rb") as src, open(os.path.join(folder, name), "wb") as dst:
                    dst.write(src.read(4 << 20))
                copied.append(name)
            except OSError:
                pass
    say(f"  evidence {tag}: {len(rows)} bundle processes, app alive {snap['app_alive']}, crash reports {copied}")
    return copied


def safe_evidence(tag):
    """evidence(), but a failure to collect never hides the problem it records (review low item at 5dcb6b7929d)."""
    try:
        return evidence(tag)
    except Exception as error:  # noqa: BLE001 - evidence is best effort; the iteration's problem stands
        say(f"  evidence {tag} failed: {type(error).__name__}: {error}")
        return []


# ---- visible state during a restore (the rule of restore-journey.py RecoverySampler) ---------------

VISIBLE_GAP = 1.0      # s without an answer from debug.daemon or debug.surfaces after the kill
VISIBLE_DEAD = 1.0     # s a shown terminal may be disconnected for good


def visible_problems(state, surfaces):
    """(hard, dead) of one sample: a window that shows neither content nor the connecting view, a blank pane;
    a shown terminal that is not connected, restoring, or disconnected and reconnecting."""
    hard, dead = [], []
    for window in (state or {}).get("windows") or []:
        if window.get("shows") not in ("content", "connecting"):
            hard.append(f"window {window.get('id')} shows {window.get('shows')}")
    if isinstance(surfaces, dict) and "error" not in surfaces:
        if surfaces.get("blank_panes"):
            hard.append(f"{surfaces.get('blank_panes')} blank pane(s)")
        for window in surfaces.get("windows") or []:
            for pane in window.get("panes") or []:
                if pane.get("kind") != "terminal" or pane.get("presence") != "visible":
                    continue
                link = str(pane.get("link"))
                if link in ("connected", "restoring") or (link.startswith("disconnected:") and link.endswith(":reconnecting")):
                    continue
                dead.append(f"pane {pane.get('pane')} {link}")
    return hard, dead


def judge_visible(samples, killed, end, need_answers=True):
    """Problems of a kill-to-settle window of samples [(at, debug.daemon, debug.surfaces)]. need_answers: like
    RecoverySampler, at least one answer of each call after the kill (an app that never answers shows nothing)."""
    problems, dead_since = [], None
    if need_answers:
        if not any(st for at, st, _ in samples if at >= killed):
            problems.append("debug.daemon never answered after the kill")
        if not any(isinstance(su, dict) and "error" not in su for at, _, su in samples if at >= killed):
            problems.append("debug.surfaces never answered after the kill")
    for at, state, surfaces in samples:
        hard, dead = visible_problems(state, surfaces)
        problems += [f"{at:.2f} s: {h}" for h in hard]
        if dead:
            dead_since = at if dead_since is None else dead_since
            if at - dead_since > VISIBLE_DEAD:
                problems.append(f"{at:.2f} s: {', '.join(dead)} since {dead_since:.2f} s")
                dead_since = at  # report each further second once
        else:
            dead_since = None
    for name, answered in (("debug.daemon", lambda st, su: bool(st)),
                           ("debug.surfaces", lambda st, su: isinstance(su, dict) and "error" not in su)):
        last, worst = killed, 0.0
        for at, state, surfaces in samples:
            if at >= killed and answered(state, surfaces):
                worst, last = max(worst, at - last), at
        worst = max(worst, end - last)
        if worst > VISIBLE_GAP:
            problems.append(f"{name} did not answer for {worst:.2f} s")
    return problems


class VisibleSampler:
    """Samples debug.daemon and debug.surfaces every 250 ms from the kill to the settle."""

    def __init__(self):
        self.samples, self.stop, self.t0 = [], threading.Event(), time.time()

        def run():
            while not self.stop.is_set():
                at = time.time() - self.t0
                st = rpc("debug.daemon", timeout=VISIBLE_GAP)
                su = rpc("debug.surfaces", timeout=VISIBLE_GAP)
                self.samples.append((at, st if isinstance(st, dict) and "error" not in st else None, su))
                self.stop.wait(0.25)
        self.thread = threading.Thread(target=run, daemon=True)
        self.thread.start()

    def finish(self, target):
        self.stop.set()
        self.thread.join(2 * VISIBLE_GAP + 2)
        end = time.time() - self.t0
        # The app's own kill: no app answers until the relaunch; judge from the first answer of the new app.
        killed = 0.0
        if target == "app":
            first = next((at for at, st, _ in self.samples if st), None)
            killed = first if first is not None else 0.0  # no answer at all: judged from the kill (never a pass)
        seen = {}
        for _, st, su in self.samples:
            shows = ",".join(sorted({w.get("shows", "?") for w in (st or {}).get("windows") or []})) or "no answer"
            links = set()
            for window in (su or {}).get("windows") or [] if isinstance(su, dict) else []:
                links |= {str(p.get("link")).split(":")[0] for p in window.get("panes") or []
                          if p.get("kind") == "terminal" and p.get("presence") == "visible"}
            key = f"{(st or {}).get('connection', 'no answer')}/{shows}/{'+'.join(sorted(links)) or '-'}"
            seen[key] = seen.get(key, 0) + 1
        self.seen = seen
        return judge_visible(self.samples, killed, end), len(self.samples)


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


def duplicates(state):
    """Problems for a workspace, tab or terminal listed twice, counted in the raw lists."""
    problems = []
    names = [w["name"] for w in state.values()]
    if len(names) != len(set(names)):
        problems.append(f"a workspace name is listed twice: {sorted(names)}")
    if any(w.get("dup_ws") for w in state.values()):
        problems.append("a workspace id is listed twice")
    tabs = [t for w in state.values() for t in w.get("raw_tabs", list(w["tabs"]))]
    if len(tabs) != len(set(tabs)):
        problems.append("a tab is listed twice")
    terms = [t for w in state.values() for t in w.get("raw_terms", list(w["tabs"].values())) if t]
    if len(terms) != len(set(terms)):
        problems.append("a terminal is listed twice")
    return problems


def judge(state, expected, inflight):
    """The oracle after a restore: a list of problems (empty = pass)."""
    problems = []
    ok_exact = canon(state) == canon(expected)
    if inflight:
        kind, p, answered_ok = inflight
        ok_after = allowed_after(kind, p, expected, state)
        if answered_ok and not ok_after and not (kind == "write" and ok_exact):
            problems.append(f"{kind} answered ok, but its effect is not in the restored topology")
        elif not answered_ok and not (ok_exact or ok_after):
            problems.append(f"restored topology is neither the confirmed one nor the confirmed one plus the in-flight {kind}")
    elif not ok_exact:
        problems.append("restored topology differs from the last confirmed one")
    if problems:
        problems.append(f"confirmed {json.dumps(canon(expected), sort_keys=True)[:600]} restored {json.dumps(canon(state), sort_keys=True)[:600]}")
    problems += duplicates(state)
    terms = [t for w in state.values() for t in w.get("raw_terms", list(w["tabs"].values())) if t]
    # No lost terminal: every confirmed terminal is listed again (same id: a tab that comes back with a new,
    # empty terminal lost its terminal), and shows its marker line.
    want = {t for w in expected.values() for t in w["tabs"].values() if t}
    if inflight and inflight[0] in ("tab_close", "ws_close") and allowed_after(inflight[0], inflight[1], expected, state):
        kind, p = inflight[0], inflight[1]
        gone = expected.get(p["ws"], {}).get("tabs", {})
        want -= {gone.get(p["tab"])} if kind == "tab_close" else set(gone.values())
    for terminal in sorted(want - set(terms)):
        problems.append(f"confirmed terminal {terminal} is not in the restored topology")
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
    fz_before = daemon_state() or {}
    for wid in list(fz_before):
        answer, _ = cli("workspace", wid, "close")
        note_close(answer, len(fz_before.get(wid, {}).get("tabs", {})))
    wait(lambda: daemon_state() == {}, 20, 0.5)
    names = []
    for _ in range(run.rng.randint(1, 3)):
        name = run.name()
        ACTION_ERRORS[0] = True
        try:
            answer, _ = cli("workspace", "create", "--name", name)
        finally:
            ACTION_ERRORS[0] = False
        if created(name, answer):
            names.append(name)
        mark(value(answer).get("terminal_id") if isinstance(value(answer), dict) else None)
    state = daemon_state()
    listed_names = {w["name"] for w in (state or {}).values()}
    missing = [n for n in names if n not in listed_names]
    if state is not None and missing:
        wsl, _ = cli("workspace", "list")
        say(f"  SUSPECT: create of {missing} answered ok but the list names {sorted(listed_names)}; "
            f"list: {json.dumps(wsl)[:600]}")
    return state


def iteration(seed, targets, keep=None, label="i"):
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
        if after is None:
            # The confirmed topology is unknown now: judging against the old one would be a false red.
            rec["problems"].append(f"the daemon topology could not be read after {kind}")
            rec["verdict"] = "not run"
            return rec
        rec["problems"] += [f"after {kind}: {d}" for d in duplicates(after)]
        state = confirmed = after
    rec.update(target=target, point="in flight" if inflight_kill else "between", pause_s=round(pause, 3))
    old_daemons = APP.daemon_pids()
    inflight = None
    if inflight_kill and plan:
        kind, p = plan[-1]
        box = {}

        def go():
            started = time.time()
            box["answer"], box["s"] = do_action(kind, p)
            box["answered_at"] = started + box["s"]  # the action's own answer, before the marker write
        th = threading.Thread(target=go, daemon=True)
        th.start()
        time.sleep(pause)
        killed_at = time.time()
        pids = kill(target)
        th.join(ACTION_BOUND + 5)
        # An ok answer is the daemon's commit (only the daemon answers the CLI), so it must land whenever it
        # came: before the kill, or after it from a daemon that the kill did not touch (app, acpmux).
        answered_ok = "answered_at" in box and isinstance(box.get("answer"), (dict, list)) and "error" not in box["answer"]
        inflight = (kind, p, answered_ok)
        rec["actions"].append({"i": count - 1, "kind": kind, "params": p, "inflight": True, "answered_ok": answered_ok,
                               "answered_after_kill_s": round(box["answered_at"] - killed_at, 3) if "answered_at" in box else None,
                               "answer": str(box.get("answer"))[:200]})
    else:
        time.sleep(pause)
        killed_at = time.time()
        pids = kill(target)
    rec["killed"] = pids
    log_daemon_env(f"before-kill-{target}")
    if not pids:
        rec["verdict"] = "not run"
        rec["problems"].append(f"no {target} process of this build to kill")
        return rec
    say(f"  iter seed {seed}: {len(rec['actions'])} actions, SIGKILL {target} {pids} ({rec['point']})")
    sampler = VisibleSampler() if opts.visible else None
    state, timings, problem = restore(target, killed_at, old_daemons)
    if sampler:
        seen, n = sampler.finish(target)
        rec["visible_samples"] = n
        rec["visible_states"] = getattr(sampler, "seen", {})
        if seen and not (DISK.get("volume") and DISK.get("phase") == "full" and problem):
            rec["problems"].append(f"no designed visible state during the restore: {'; '.join(seen[:4])}")
        elif seen:
            rec["visible_problems_full"] = seen[:4]
    rec["timings"] = timings
    log_daemon_env(f"after-restore-{target}")
    rec["hosts_after_restore"] = log_hosts(f"after-restore-{target}")["hosts"]
    outside = APP.state_outside_slot()
    if outside:
        say(f"RESTORE-FUZZ SUMMARY seed=none chaos={opts.chaos} iterations=0 judged=0 not_run=0 violations=0 chaos_lost=0 "
            f"harness_invalid=1 ({outside})")
        sys.exit(75)
    if problem:
        rec["problems"].append(problem)
        rec["crash_reports"] = safe_evidence(f"{label}-{seed}")
        if DISK.get("volume") and DISK.get("phase") == "full":
            rec["full_disk_problem"] = rec["problems"].pop()
            rec_rec = recover_after_space(target, old_daemons)
            state = rec_rec.pop("state")
            rec["recovery"] = rec_rec
            if str(rec_rec.get("problem", "")).startswith("not checked"):
                rec["problems"].append("no recovery check: no time left in the lease")
                rec["verdict"] = "not run"
                return rec
            if not rec_rec["recovered"]:
                rec["problems"].append(
                    f"no recovery by itself after the space came back ({rec_rec['problem']}); Restart offered: "
                    f"{rec_rec['offers_restart']}; after Restart: "
                    f"{'recovered' if rec_rec.get('recovered_after_restart') else rec_rec.get('restart_problem')}")
            else:
                # Recovered by itself: nothing confirmed may be lost, and the full-disk stretch must have been visible.
                rec["problems"] += judge(state, confirmed, inflight)
                rec["problems"] += [f"not visible on the full disk: {v}" for v in rec.get("visible_problems_full", [])]
                rec["problems"] += [f"not visible during recovery: {v}" for v in rec_rec["visible_problems"]]
                if not rec["problems"]:
                    rec["verdict"] = "degraded"
                    return rec
    else:
        rec["problems"] += judge(state, confirmed, inflight)
        if rec["problems"]:
            rec["crash_reports"] = safe_evidence(f"{label}-{seed}")
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
        again = iteration(rec["seed"], targets, keep=set(trial), label=f"shrink{drop}")
        attempts.append({"keep": trial, "verdict": again["verdict"], "problems": again["problems"][:2]})
        if again["verdict"] == "fail":
            keep = trial
    return {"keep": keep, "attempts": attempts}


# ---- chaos: nearly full disk ----------------------------------------------------------------------

def parse_procargs2(blob):
    """KERN_PROCARGS2 bytes -> (argv, env), values exact (spaces kept): int argc, exec path, NUL padding, argv, env."""
    import struct
    argc = struct.unpack_from("i", blob, 0)[0]
    rest = blob[4:]
    end = rest.find(b"\0")
    # The exec path, then NUL padding, then argv (psutil's rule). An empty argv[0] cannot be told from the padding;
    # the harness reads only env values, and a cmux-tui daemon's argv[0] is its path, so that case does not apply.
    pos = end
    while pos < len(rest) and rest[pos] == 0:
        pos += 1
    words = rest[pos:].split(b"\0")
    argv = [w.decode(errors="replace") for w in words[:argc]]
    env = {}
    for w in words[argc:]:
        if not w:
            break
        key, sep, val = w.decode(errors="replace").partition("=")
        if sep:
            env[key] = val
    return argv, env


def proc_args_exact(pid):
    """(argv, env) of a same-user process through sysctl KERN_PROCARGS2 (exact values), or None."""
    try:
        libc = ctypes.CDLL(None)
        libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                                ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        mib = (ctypes.c_int * 3)(1, 49, int(pid))  # CTL_KERN, KERN_PROCARGS2
        size = ctypes.c_size_t(0)
        if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not size.value:
            return None
        buf = ctypes.create_string_buffer(size.value)
        if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
            return None
        return parse_procargs2(buf.raw[:size.value])
    except (OSError, AttributeError, ValueError):
        return None


def filler_bytes(free_bytes, margin_mb):
    return max(0, free_bytes - margin_mb * (1 << 20))


HOST_RESERVE = 30 << 30  # the host keeps at least this much free after the image is made


def disk_plan(host_free, image_mb, state_bytes):
    """None when the diskfull setup may run, else the reason it may not."""
    if host_free - image_mb * (1 << 20) < HOST_RESERVE:
        return f"the host would keep {host_free >> 30} GB minus the image, below its {HOST_RESERVE >> 30} GB reserve"
    if state_bytes > image_mb * (1 << 20) // 4:
        return f"the state dir holds {state_bytes >> 20} MB, more than a quarter of the {image_mb} MB image"
    return None


def check_state_dir(state_dir, home):
    """None when the daemon's state dir is a real path under the slot HOME, else the reason."""
    if not state_dir or not home:
        return f"no state dir ({state_dir!r}) or no slot HOME ({home!r})"
    if not os.path.abspath(state_dir).startswith(home.rstrip("/") + "/"):
        return f"state dir {state_dir} is not under the slot HOME {home}"
    return None


class HarnessInvalid(Exception):
    """The harness cannot keep its own safety rule (no verdict, never PASS)."""


class DiskVolume:
    """A bounded HFS+ image mounted at the daemon's state dir: filling it fills only the image, never the host."""

    def __init__(self, image, mountpoint, size_mb):
        self.image, self.mountpoint, self.size_mb, self.mounted = image, mountpoint, size_mb, False
        self.filler = os.path.join(mountpoint, ".fz-filler")

    def create_cmd(self):
        return ["/usr/bin/hdiutil", "create", "-size", f"{self.size_mb}m", "-fs", "HFS+", "-volname", "fzdisk",
                "-type", "UDIF", self.image]

    def attach_cmd(self):
        return ["/usr/bin/hdiutil", "attach", "-nobrowse", "-noautoopen", "-mountpoint", self.mountpoint, self.image]

    def detach_cmd(self, force=False):
        return ["/usr/bin/hdiutil", "detach", *(["-force"] if force else []), self.mountpoint]

    def free(self):
        st = os.statvfs(self.mountpoint)
        return st.f_bavail * st.f_frsize

    def fill(self, margin_mb):
        """Writes the filler until the image has margin_mb free; the free bytes after. Only on the mounted image:
        if the mount is gone, statvfs would be the host disk's, so it refuses (HarnessInvalid)."""
        if not os.path.ismount(self.mountpoint) or self.free() > self.size_mb * (1 << 20):
            raise HarnessInvalid(f"{self.mountpoint} is not the mounted {self.size_mb} MB image; refusing to fill")
        want = filler_bytes(self.free(), margin_mb)
        chunk = b"\0" * (8 << 20)
        with open(self.filler, "ab") as f:
            while want > 0:
                n = min(want, len(chunk))
                try:
                    f.write(chunk[:n])
                    f.flush()
                except OSError:
                    break
                want -= n
            os.fsync(f.fileno())
        return self.free()

    def trim(self, margin_mb):
        """Shrinks the filler so the image has at least margin_mb free again (after a fill to margin 0)."""
        need = margin_mb * (1 << 20) - self.free()
        if need > 0 and os.path.exists(self.filler):
            os.truncate(self.filler, max(0, os.path.getsize(self.filler) - need))
        return self.free()

    def unfill(self):
        try:
            os.remove(self.filler)
        except FileNotFoundError:
            pass
        return self.free()

    def detach(self):
        for force in (False, True, True):
            if not self.mounted:
                return True
            if subprocess.run(self.detach_cmd(force), capture_output=True, text=True, timeout=60).returncode == 0:
                self.mounted = False
                return True
            time.sleep(2)
        return False


DISK = {}  # "volume": DiskVolume, "state_dir": path, "phase": "full" | "free"


def daemon_state_dir():
    """The exact CMUX_TUI_STATE_DIR of this build's daemon (KERN_PROCARGS2), or None."""
    for pid in APP.daemon_pids():
        got = proc_args_exact(pid)
        if got and got[1].get("CMUX_TUI_STATE_DIR"):
            return got[1]["CMUX_TUI_STATE_DIR"]
    return None


def bundle_pids(exclude=()):
    """Every process run from this slot's bundle (the app, its daemon, acpmux, helpers), by its ps row: no rpc, so
    an app that hangs on a full disk is found too."""
    return [pid for pid, _, args in ps_table() if APP.mine(args) and pid != os.getpid() and pid not in exclude]


def stop_build_processes(exclude=()):
    """SIGKILL every process of this slot's bundle and poll (locally: never wait(), which exits once the parent is
    gone) until they end; True when all ended within 20 s."""
    pids = bundle_pids(exclude)
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    end = time.time() + 20
    while time.time() < end:
        if not any(APP.alive(p) for p in pids):
            return True
        time.sleep(0.2)
    return False


def tree_bytes(path):
    total = 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(root, name)).st_size
            except OSError:
                pass
    return total


def stale_images_present():
    """Is an fzdisk image mounted in the slot HOME, or a moved .fz-orig state dir left there (read only)?"""
    if not APP.env.get("HOME"):
        return False
    home = APP.env["HOME"].rstrip("/") + "/"
    out = subprocess.run(["/sbin/mount"], capture_output=True, text=True).stdout
    if any(re.match(r"^/dev/disk\S+ on (.+) \(hfs", line) and line.split(" on ", 1)[1].startswith(home)
           and "fz" in line for line in out.splitlines()):
        return True
    for root, dirs, _ in os.walk(home):
        if any(d.endswith(".fz-orig") for d in dirs):
            return True
        if root.count(os.sep) - home.count(os.sep) > 8:
            dirs[:] = []
    return False


def detach_stale_images():
    """Detaches fzdisk images an earlier run of this harness left mounted under this slot's HOME (a run whose
    driver ended before its teardown). Only volumes named fzdisk mounted inside the slot HOME."""
    if not APP.env.get("HOME"):
        say("  diskfull: no slot HOME; the stale-image repair does nothing (fail closed)")
        return []
    home = APP.env["HOME"].rstrip("/") + "/"
    out = subprocess.run(["/sbin/mount"], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        m = re.match(r"^(/dev/disk\S+) on (.+) \(hfs", line)
        if not m or not m.group(2).startswith(home):
            continue
        info = subprocess.run(["/usr/sbin/diskutil", "info", m.group(1)], capture_output=True, text=True).stdout
        if re.search(r"Volume Name:\s+fzdisk\s*$", info, re.M):
            found.append(m.group(2))
    for mountpoint in found:
        done = subprocess.run(["/usr/bin/hdiutil", "detach", "-force", mountpoint], capture_output=True, text=True)
        say(f"  diskfull: stale fzdisk image at {mountpoint}: detach exit {done.returncode}")
        if done.returncode == 0:
            restore_moved_state(mountpoint, mountpoint + ".fz-orig")
    # A moved state dir with no mount (an earlier teardown that stopped after the detach), and stale image files.
    for root, dirs, _ in os.walk(home):
        for name in list(dirs):
            if name.endswith(".fz-orig"):
                state = os.path.join(root, name[: -len(".fz-orig")])
                if restore_moved_state(state, os.path.join(root, name)):
                    found.append(state)
                dirs.remove(name)
        if root.count(os.sep) - home.count(os.sep) > 8:
            dirs[:] = []
    tmp = APP.env.get("TMPDIR") or ""
    if tmp:
        for name in os.listdir(tmp) if os.path.isdir(tmp) else []:
            if name.startswith("fz-disk-") and name.endswith(".dmg"):
                try:
                    os.remove(os.path.join(tmp, name))
                    say(f"  diskfull: removed stale image file {name}")
                except OSError:
                    pass
    return found


def setup_diskfull():
    """Moves the daemon's state dir onto a bounded image at the same path, then fills it. None, or the reason it
    could not (the run is then harness-invalid: NOVERDICT)."""
    state = daemon_state_dir()
    why = check_state_dir(state, APP.env.get("HOME", ""))
    if why:
        return why
    st = os.statvfs(state)
    why = disk_plan(st.f_bavail * st.f_frsize, opts.disk_image_mb, tree_bytes(state))
    if why:
        return why
    # Never in OUT (the copy back would carry it); in the slot's own TMPDIR, removed at teardown.
    image_dir = APP.env.get("TMPDIR") or os.path.dirname(opts.out.rstrip("/"))
    vol = DiskVolume(os.path.join(image_dir, f"fz-disk-{os.getpid()}.dmg"), state, opts.disk_image_mb)
    made = subprocess.run(vol.create_cmd(), capture_output=True, text=True, timeout=120)
    if made.returncode:
        return f"hdiutil create failed: {made.stderr.strip()[:200]}"
    if not stop_build_processes():
        return "the build's processes did not end"
    orig = state + ".fz-orig"
    DISK.update(volume=vol, state_dir=state, orig=orig)  # recorded BEFORE the rename: teardown can always undo it
    os.rename(state, orig)
    os.makedirs(state)
    attached = subprocess.run(vol.attach_cmd(), capture_output=True, text=True, timeout=120)
    if attached.returncode:
        return f"hdiutil attach failed: {attached.stderr.strip()[:200]}"  # teardown puts the state dir back
    vol.mounted = True
    copied = subprocess.run(["/bin/cp", "-a", orig + "/.", state + "/"], capture_output=True, text=True, timeout=120)
    if copied.returncode:
        say(f"  diskfull: cp of the state dir reported: {copied.stderr.strip()[:300]}")
    if not APP.relaunch():
        return "the app did not answer after the state dir moved onto the image"
    if not wait(lambda: daemon_state() is not None, 60, 0.5):
        return "the daemon did not answer after the state dir moved onto the image"
    DISK["phase"] = "full"
    try:
        left = vol.fill(opts.disk_margin_mb)
    except HarnessInvalid as error:
        return str(error)
    say(f"  diskfull: {state} is a {opts.disk_image_mb} MB image; free after fill: {left >> 10} KB")
    return None


def disk_phase(i):
    """Before iteration i: every Nth iteration runs with the filler removed (recovery), the others full."""
    vol = DISK.get("volume")
    if not vol:
        return None
    want = "free" if opts.disk_recover_every and i % opts.disk_recover_every == opts.disk_recover_every - 1 else "full"
    if want != DISK.get("phase"):
        free = vol.unfill() if want == "free" else vol.fill(opts.disk_margin_mb)
        DISK["phase"] = want
        say(f"  diskfull: phase {want}, {free >> 10} KB free")
    return {"phase": want, "free_kb": vol.free() >> 10}


def recover_after_space(target, old_daemons):
    """diskfull: the restore failed on a full disk. Free the space (no other action) and see whether the build comes
    back by itself within 60 s, with the visible state sampled. The person's way out must not need a restart."""
    vol = DISK["volume"]
    freed_at = time.time()
    free = vol.unfill()
    DISK["phase"] = "free"
    say(f"  diskfull: restore failed on a full disk; space freed ({free >> 10} KB), waiting for the build to recover")
    if target == "app":
        # The relaunch that failed may still run (it never answered): stop the app's processes first (not the daemon
        # or acpmux: the person's case is an app restart), so the recovery relaunch is the only app instance.
        stop_build_processes(exclude=set(APP.daemon_pids()) | set(APP.acpmux_pids()))
    if time.time() > T0 + opts.max_seconds - SETTLE_BOUND:
        return {"recovered": False, "state": None, "problem": "not checked: no time left in the lease",
                "visible_problems": [], "visible_states": {}, "samples": 0, "offers_restart": None}
    sampler = VisibleSampler()
    state, timings, problem = restore(target, freed_at, old_daemons)
    seen, n = sampler.finish(target)
    last = rpc("debug.daemon", timeout=3)
    offered = isinstance(last, dict) and ((last.get("recovery") or {}).get("offers_restart") is True)
    out = {"recovered": problem is None, "state": state, "debug_daemon_last": last if isinstance(last, dict) else None,
           "offers_restart": offered, "after_free_s": timings.get("settled_s"), "problem": problem,
           "visible_problems": seen[:4], "visible_states": getattr(sampler, "seen", {}), "samples": n}
    if problem is not None and time.time() > T0 + opts.max_seconds - SETTLE_BOUND - 60:
        out["restart"] = "not tried: no time left in the lease"
    elif problem is not None:
        # The person's way out: press Restart cmux-tui (the button's path, as restore-journey's daemon-stop does).
        pressed = rpc("debug.daemon", {"action": "restart"}, timeout=10)
        pressed_at = time.time()
        if target == "app" and not isinstance(pressed, dict):
            stop_build_processes()  # no app answered the press: one fresh instance only
        state2, timings2, problem2 = restore(target, pressed_at, old_daemons)
        out.update(restart_pressed=pressed if isinstance(pressed, dict) else str(pressed)[:200],
                   recovered_after_restart=problem2 is None, after_restart_s=timings2.get("settled_s"),
                   restart_problem=problem2)
        if problem2 is None:
            out["state"] = state2
    say(f"  diskfull: recovery {'OK' if problem is None else 'FAILED'} "
        f"{json.dumps({k: v for k, v in out.items() if k != 'state'})[:400]}")
    return out


def app_view():
    """{"readable": both topologies were read, "app": workspace ids the app shows, "daemon": workspace ids the daemon
    lists, "notices": toasts + dialogs shown, "texts": their text, "raw": the raw answers}. An unreadable view never
    counts as "no ghost": the probe makes it "not run"."""
    snap = rpc("snapshot.get")
    topo = snap.get("topology") if isinstance(snap, dict) else None
    app_ids = {w.get("id") for w in (topo or {}).get("workspaces", []) if isinstance(w, dict) and w.get("id")}
    wsl, _ = cli("workspace", "list")
    daemon_read = isinstance(value(wsl), list) or (isinstance(wsl, dict) and "error" not in wsl)
    daemon_ids = {first(w, "id", "workspace_id") for w in listed(wsl, "workspaces")} - {None}
    toast = rpc("debug.toast", {})
    dialog = rpc("debug.dialog", {})
    items = []
    if isinstance(toast, dict):
        items += list(toast.get("refusals") or [])
        for window in toast.get("windows") or []:
            items += list(window.get("toasts") or [])
    if isinstance(dialog, dict):
        items += list(dialog.get("dialogs") or [])
    texts, count = [json.dumps(item)[:300] for item in items], len(items)
    return {"readable": isinstance(topo, dict) and daemon_read, "app": app_ids, "daemon": daemon_ids,
            "notices": count, "texts": texts,
            "raw": {"toast": json.dumps(toast)[:600], "dialog": json.dumps(dialog)[:600]}}


CREATE_REFUSAL_WORDS = re.compile(r"workspace|disk|space|create|storage", re.I)
DISK_FULL = re.compile(r"disk is full|no space left|ENOSPC|SQLITE_FULL|disk full", re.I)


def new_refusal_texts(before, after):
    """Notice texts that are new after the create and are about it (a workspace create or the full disk); a toast
    for another cause, or an old refusal still in the history, does not count."""
    old = {}
    for t in before.get("texts") or []:
        old[t] = old.get(t, 0) + 1
    fresh = []
    for t in after.get("texts") or []:  # a multiset difference: the same refusal shown again is new
        if old.get(t):
            old[t] -= 1
        elif CREATE_REFUSAL_WORDS.search(t):
            fresh.append(t)
    return fresh


def judge_app_create(before, after, relaunched):
    """Problems of the app-path create under a full disk: a workspace the app shows and the daemon does not (a ghost),
    now or after a relaunch (a saved record); a refusal with no new toast or dialog about it for the person."""
    problems = []
    for label, view in (("after the create", after), ("after the relaunch", relaunched)):
        ghost = (view["app"] - view["daemon"]) - (before["app"] - before["daemon"])
        if ghost:
            problems.append(f"{label}: ghost workspace(s) {sorted(ghost)} in the app, not in the daemon")
    made = after["daemon"] - before["daemon"]
    if not made and not new_refusal_texts(before, after):
        problems.append("the create was refused, but no visible refusal (no new toast or dialog about it) for the person")
    return problems


def disk_full_refusal(answer):
    """Is a CLI create answer the daemon's typed disk-full refusal (not a dead socket, a stall or bad output)?"""
    return (isinstance(answer, dict) and "error" in answer and typed_error(answer)
            and bool(DISK_FULL.search(json.dumps(answer.get("error")))))


PROBE_SETTLE = 5.0  # seconds from the action to the after view (the refusal toast shows)
PROBE_BOUND = 240  # seconds the probe may take at most: fills, CLI creates, the action, a relaunch and 3 view reads


def probe_record(verdict, problems, **extra):
    rec = {"probe": "app_create", "verdict": verdict, "problems": problems}
    for key, view in extra.items():
        rec[key] = {k: sorted(v) if isinstance(v, set) else v for k, v in view.items()} if isinstance(view, dict) else view
    with open(os.path.join(opts.out, "app-create-probe.json"), "w") as f:
        json.dump(rec, f, indent=1, default=str)
    say(f"  app create probe: {verdict} {'; '.join(problems)[:300]}")
    return rec


def app_create_probe():
    """The person's create (New Workspace, debug.toast perform "newTab" as origin user) on the full disk, judged by
    judge_app_create. Runs once per diskfull run, before the iterations. A fail only when every view was read and the
    daemon really refused a CLI create for the full disk just before; otherwise "not run". Leaves the image at
    --disk-margin-mb free again."""
    vol = DISK["volume"]
    try:
        return run_app_create_probe(vol)
    finally:
        vol.trim(opts.disk_margin_mb)


def run_app_create_probe(vol):
    if time.time() > T0 + opts.max_seconds - PROBE_BOUND:
        return probe_record("not run", ["no time left in the lease for the probe"])
    # First make sure the daemon refuses a create for the full disk now: fill again (margin 0 on the second try)
    # until a CLI create answers a typed disk-full error. A create that still works is closed again.
    refused = None
    for margin in (opts.disk_margin_mb, 0, 0):
        vol.fill(margin)
        answer, _ = cli("workspace", "create", "--name", "fz-probe-check")
        if disk_full_refusal(answer):
            refused = answer
            break
        made = value(answer).get("workspace_id") if isinstance(value(answer), dict) else None
        if made:
            cli("workspace", made, "close")
    if refused is None:
        return probe_record("not run", ["the daemon gave no typed disk-full refusal of a CLI create on the full disk"])
    before = app_view()
    if not before["readable"]:
        return probe_record("not run", ["the app or daemon topology could not be read before the create"], before=before)
    # The person's New Workspace: action id "newTab", titled "New Workspace" (CmuxNextActions WorkspaceActionCatalog).
    # As a person runs it (debug.toast perform: origin user), so it gets the refusal a person gets.
    answer = rpc("debug.toast", {"perform": "newTab"}, timeout=20)
    err = answer.get("error") if isinstance(answer, dict) else None
    if err is not None and not isinstance(err, dict):
        # rpc() gives a bare string for a socket timeout, a closed socket or bad output: the app hung or went away.
        return probe_record("fail", [f"the app gave no answer to New Workspace on the full disk: {str(err)[:200]}"],
                            before=before, action_answer=json.dumps(answer)[:400])
    if isinstance(answer, dict) and answer.get("performed") is False:
        return probe_record("not run", [f"the action did not run: {json.dumps(answer)[:200]}"])
    if isinstance(err, dict) and err.get("code") == "not_found":
        return probe_record("not run", [f"the action is unknown: {json.dumps(answer)[:200]}"])
    time.sleep(PROBE_SETTLE)
    after = app_view()
    if not after["readable"]:
        return probe_record("not run", ["the app or daemon topology could not be read after the create"],
                            before=before, after=after)
    made = after["daemon"] - before["daemon"]
    if made:
        for ws_id in made:
            cli("workspace", ws_id, "close")
        return probe_record("not run", ["the app's create was not refused (the CLI create just before was): "
                                        "no refusal to judge"], action_answer=json.dumps(answer)[:400])
    stop_build_processes(exclude=set(APP.daemon_pids()) | set(APP.acpmux_pids()))
    relaunched_ok = APP.relaunch()
    loaded = relaunched_ok and wait(lambda: app_state() and app_state()[1], 30, 0.5)
    relaunched = app_view() if loaded else None
    if not relaunched_ok:
        return probe_record("fail", ["the app did not answer after the relaunch"], before=before, after=after)
    if not relaunched or not relaunched["readable"]:
        return probe_record("not run", ["the topology could not be read after the relaunch: the saved-record check "
                                        "was not done"], before=before, after=after)
    problems = judge_app_create(before, after, relaunched)
    return probe_record("fail" if problems else "pass", problems, action_answer=json.dumps(answer)[:400],
                        before=before, after=after, relaunched=relaunched,
                        new_refusals=new_refusal_texts(before, after))


def teardown_diskfull():
    """Detaches the image, puts the original state dir back, removes the image file. Signals are ignored meanwhile
    and each step runs even if one before it failed; nothing here uses wait() or needs stdout."""
    vol = DISK.pop("volume", None)
    if not vol:
        return
    old = {sig: signal.signal(sig, signal.SIG_IGN) for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    try:
        try:
            stop_build_processes()
        except Exception as error:  # noqa: BLE001 - the restore below must still run
            say(f"  diskfull: stopping the build failed: {error}")
        mounted = os.path.ismount(vol.mountpoint)
        if mounted:
            try:
                vol.mounted = True
                mounted = not vol.detach()
            except Exception as error:  # noqa: BLE001
                say(f"  diskfull: detach failed: {error}")
        if mounted:
            say(f"  diskfull: WARNING the image is still mounted at {vol.mountpoint}; the next run detaches it")
        else:
            say(f"  diskfull: image detached from {vol.mountpoint}")
            restore_moved_state(vol.mountpoint, DISK.get("orig"))
        try:
            os.remove(vol.image)
        except OSError:
            pass
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)


def restore_moved_state(state, orig):
    """Puts <state>.fz-orig back at <state> when <state> is not a mount (an empty dir, or a dir that holds only what
    a daemon wrote into the bare mount point after a forced detach: kept beside as <state>.fz-stray)."""
    if not orig or not os.path.isdir(orig) or os.path.ismount(state):
        return False
    try:
        if os.path.isdir(state):
            try:
                os.rmdir(state)
            except OSError:
                os.rename(state, state + f".fz-stray-{int(time.time())}")
        os.rename(orig, state)
        say("  diskfull: original state dir restored")
        return True
    except OSError as error:
        say(f"  diskfull: WARNING could not restore {orig}: {error}")
        return False


# ---- chaos -------------------------------------------------------------------------------------

CHAOS_PROCS = []
PROBE = []  # the diskfull app-path create probe record


def start_chaos():
    if opts.chaos == "hog":
        hog = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hog.py")
        if not os.path.isfile(hog):
            say("RESTORE-FUZZ SUMMARY seed=none chaos=hog iterations=0 judged=0 not_run=0 violations=0 "
                "chaos_lost=1 (hog.py was not shipped: RJ_DRIVER_FILES)")
            sys.exit(75)
        CHAOS_PROCS.append(subprocess.Popen(
            ["/usr/bin/python3", hog, "--swap-gb", str(opts.hog_swap_gb), "--deadline", str(int(T0 + opts.max_seconds)),
             "--log", os.path.join(opts.out, "hog.jsonl")], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        say(f"chaos hog: pid {CHAOS_PROCS[-1].pid}, --swap-gb {opts.hog_swap_gb}")
        time.sleep(20)  # let it reach pressure before the first iteration
    elif opts.chaos == "cpu":
        burn = ("import ctypes,time\n"
                "ctypes.CDLL(None).pthread_set_qos_class_self_np(0x21,0)\n"  # QOS_CLASS_USER_INTERACTIVE
                f"end={T0 + opts.max_seconds}\n"
                "while time.time()<end: pass\n")
        for _ in range(os.cpu_count() or 8):
            CHAOS_PROCS.append(subprocess.Popen(["/usr/bin/python3", "-c", burn]))
        say(f"chaos cpu: {len(CHAOS_PROCS)} busy processes at user-interactive QoS")
    elif opts.chaos in ("fd", "fdsoft"):
        say(f"chaos {opts.chaos}: every app relaunch runs with RLIMIT_NOFILE soft 256"
            + (", hard 256" if opts.chaos == "fd" else ", hard unchanged"))
    elif opts.chaos == "exec":
        say("chaos exec (control): every app relaunch execs the executable as fd/slowdisk do, with no limit and no throttle")
    elif opts.chaos == "slowdisk":
        say("chaos slowdisk: every app relaunch runs under taskpolicy -d throttle (disk I/O throttled)")
    elif opts.chaos == "diskfull":
        why = setup_diskfull()
        if not why:
            try:
                PROBE.append(app_create_probe())
            except HarnessInvalid as error:
                why = str(error)
        if why:
            teardown_diskfull()
            say(f"RESTORE-FUZZ SUMMARY seed=none chaos=diskfull iterations=0 judged=0 not_run=0 violations=0 "
                f"chaos_lost=0 harness_invalid=1 ({why})")
            sys.exit(75)


def stop_chaos():
    for proc in CHAOS_PROCS:
        try:
            proc.terminate()
            proc.wait(10)
        except (OSError, subprocess.TimeoutExpired):
            proc.kill()


# ---- main --------------------------------------------------------------------------------------

def _end_on_signal(signum, _frame):
    """SIGTERM/SIGHUP (the slot script or its ssh ended): leave through main()'s finally, which detaches the image."""
    raise SystemExit(f"restore-fuzz: signal {signum}")


def main():
    global APP
    signal.signal(signal.SIGTERM, _end_on_signal)
    signal.signal(signal.SIGHUP, _end_on_signal)
    APP = App()
    if stale_images_present():
        # The build runs on a stale image: stop it first, then detach and put the state dir back, then start again.
        stop_build_processes()
        detach_stale_images()
        if not APP.relaunch():
            say("RESTORE-FUZZ SUMMARY seed=none chaos=none iterations=0 judged=0 not_run=0 violations=0 chaos_lost=0 "
                "harness_invalid=1 (the app did not come back after a stale image was detached)")
            sys.exit(75)
    targets = [t for t in opts.targets.split(",") if t in ("app", "daemon", "acpmux")]
    if "acpmux" in targets and not APP.acpmux_pids():
        say("no acpmux daemon of this build runs now; acpmux kills are judged only when one runs")
    seed = opts.seed if opts.seed is not None else int(time.time() * 1000) % (1 << 31)
    say(f"restore-fuzz seed {seed} chaos {opts.chaos} targets {targets}")
    log_daemon_env("start")
    log_hosts("start")
    master = random.Random(seed)
    deadline = T0 + opts.max_seconds
    records, violations = [], []
    chaos_lost = [0]
    try:
        start_chaos()  # inside the try: a stop during the diskfull setup still detaches the image
        if opts.replay:
            with open(opts.replay) as f:
                seeds = [json.load(f)[0]["record"]["seed"]]
        else:
            seeds = None
        i = 0
        # An iteration may need: actions, a settle (SETTLE_BOUND), and under diskfull a recovery wait and a Restart
        # wait (2 more SETTLE_BOUNDs) plus the evidence re-read (30 s). Start one only if it can end inside the lease.
        need = 60 + (SETTLE_BOUND + 60 + 40 if opts.chaos == "diskfull" else 0)
        while time.time() < deadline - need and (not opts.iterations or i < opts.iterations):
            dead = [proc.pid for proc in CHAOS_PROCS if proc.poll() is not None]
            if dead:
                chaos_lost[0] = 1
                say(f"chaos process(es) {dead} ended early; stopping (the iterations after this would not be under chaos)")
                break
            it_seed = seeds[0] if seeds else master.randrange(1 << 31)
            try:
                phase = disk_phase(i)
            except HarnessInvalid as error:
                say(f"RESTORE-FUZZ SUMMARY seed={seed} chaos={opts.chaos} iterations={len(records)} judged=0 not_run=0 "
                    f"violations=0 chaos_lost=0 harness_invalid=1 ({error})")
                sys.exit(75)
            ERRORS.clear()
            rec = iteration(it_seed, targets, label=f"iter{i}")
            if phase:
                rec["disk"] = phase
                # h1 class: after refused work, the app must still show exactly what the daemon has.
                state_now = daemon_state()
                shown = app_state()
                if state_now is not None and shown and shown[0] != {w["name"]: sorted(w["tabs"]) for w in state_now.values()}:
                    rec["app_daemon_differ"] = {"app": shown[0], "daemon": canon(state_now)}
                rec["errors"] = list(ERRORS[:20])
                rec["errors_untyped"] = sum(1 for e in ERRORS if not e["typed"])
                # A full disk may refuse work: that is degraded, not "not run", when it refused with an answer.
                if phase["phase"] == "full":
                    rec["verdict"] = not_run_outcome(rec, ERRORS)
                # Recovery: with the filler removed, the iteration must run (its creates must work again).
                if phase["phase"] == "free" and rec["verdict"] == "not run":
                    rec["problems"].append("no recovery: with free space again, the iteration could not run")
                    rec["verdict"] = "fail"
            if rec["verdict"] == "not run" and not phase:
                rec["verdict"] = "fail" if not_run_outcome(rec, ERRORS) == "fail" else "not run"
            rec["iteration"] = i
            records.append(rec)
            with open(os.path.join(opts.out, "iterations.jsonl"), "a") as f:
                f.write(json.dumps(rec, default=str) + "\n")
            say(f"  -> {rec['verdict']} {rec.get('timings', {})} {'; '.join(rec['problems'])[:400]}")
            if rec["verdict"] == "fail":
                small = (shrink(rec, targets, deadline - 30)
                         if (seeds or len(violations) < 2) and opts.chaos != "diskfull" else None)
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
        # A chaos process that ended before the last iteration finished means that iteration ran without chaos.
        if any(proc.poll() is not None for proc in CHAOS_PROCS):
            chaos_lost[0] = 1
            say("a chaos process ended before the run did; the last iterations may have run without chaos")
        stop_chaos()
        teardown_diskfull()
    # A degraded iteration is judged too: on a full disk it refused or stalled visibly, recovered by itself, lost nothing.
    judged = [r for r in records if r["verdict"] in ("pass", "fail", "degraded")]
    degraded = [r for r in records if r["verdict"] == "degraded"]
    kills = kill_counts(records)
    settle = sorted(r["timings"]["settled_s"] for r in judged if r.get("timings", {}).get("settled_s") is not None)
    for p in PROBE:
        if p["verdict"] == "fail":
            violations.append({"record": {"seed": seed, "iteration": "probe", "target": "app-create", "point": "full disk",
                                          "problems": p["problems"]}, "shrink": None})
    if any(p["verdict"] == "fail" for p in PROBE):
        with open(os.path.join(opts.out, "violations.json"), "w") as f:
            json.dump(violations, f, indent=1, default=str)
    for v in violations:
        r = v["record"]
        say(f"RESTORE-FUZZ VIOLATION seed={r['seed']} iter={r['iteration']} chaos={opts.chaos} target={r.get('target')} "
            f"point={r.get('point')} keep={(v.get('shrink') or {}).get('keep')} what={r['problems'][0][:300]}")
    p = lambda q: settle[min(len(settle) - 1, int(q * len(settle)))] if settle else None
    say(f"RESTORE-FUZZ SUMMARY seed={seed} chaos={opts.chaos} iterations={len(records)} judged={len(judged)} "
        f"not_run={len(records) - len(judged)} kills={json.dumps(kills, sort_keys=True)} violations={len(violations)} "
        f"chaos_lost={chaos_lost[0]} degraded={len(degraded)} app_create_probe={PROBE[0]['verdict'] if PROBE else 'none'} app_daemon_differ={sum(1 for r in records if r.get('app_daemon_differ'))} errors_untyped={sum(r.get('errors_untyped', 0) for r in records)} "
        f"hosts_max={HOSTS_MAX[0]} listed_minus_shown_max={EXCESS_MAX[0]} "
        f"listed_minus_shown_minus_closed30s_max={EXCESS_MAX[1]} "
        f"settle_s p50={p(0.5)} p95={p(0.95)} max={settle[-1] if settle else None}")
    sys.exit(1 if violations else (0 if judged and not chaos_lost[0] else 75))


if __name__ == "__main__":
    main()
