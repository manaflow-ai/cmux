#!/usr/bin/env python3
"""The other ways a laptop goes away, each as its own run with real processes.

Every scenario starts a store, an Auto machine and (mostly) a laptop as separate processes with
their own homes, a temp root and a port of their own, and the scripted agent. Each states what
a person would expect, then checks the store's invariants:

- the chat's event seqs are 1..N with no gap and no repeat;
- every prompt (`user` event) is started at most once and ended at most once, a cut and
  continued turn included, and at the end of a scenario exactly once each;
- the chat's epoch never goes down.

The first nine are the ways a person loses and gets back a chat. The ones marked (extra) in
`--list` were added for faults found while reading the code; two of those are races, which fail
only in some runs (`short_nap_mid_turn`, `wake_while_cloud_works`), as does `no_network`.

  python3 tests/scenarios.py              all of them, one after another (about 8 min)
  python3 tests/scenarios.py NAME [NAME]  some of them (a name given twice runs twice)
  python3 tests/scenarios.py -j 4         four at a time
  python3 tests/scenarios.py --list
  python3 tests/scenarios.py -v NAME      with every step printed

It prints PASS or FAIL per scenario with one line of reason and keeps the logs of a failed one
(AUTO_TEST_KEEP=1 keeps every run's logs; AUTO_SCN_DIR says where the temp roots go). In a kept
root: test.log is the scenario's steps, laptop.log, cloud.log and store.log are the processes'
output, store/ is the store's data. AUTO_DEBUG=1 stamps the processes' lines with the clock that
is the second column of test.log.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, HERE)
from autodemo.client import Client, Offline, Refused  # noqa: E402

AUTO = [sys.executable, os.path.join(HERE, "auto")]
LEASE = 4.0
VM = "demo-vm"
VM_HOLDER = "vm:" + VM
LAPTOP = "device:laptop"
FIRST_PORT = 17740  # one store port per scenario, 17740..17759, and 17760 for the gate; never 17717 or 17718


class Failed(Exception):
    pass


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def short(value, limit=160):
    text = value if isinstance(value, str) else repr(value)
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


# A whole-table `ps` takes seconds on a busy Mac (2 to 10 s were seen here), which is longer
# than the times these scenarios measure. On macOS the kernel is asked directly.
_libproc = None
if sys.platform == "darwin":
    try:
        import ctypes
        import ctypes.util
        import struct
        _libproc = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib")
    except (OSError, ImportError):
        _libproc = None


def ps_table():
    """{pid: (ppid, stat)} of every process, from `ps` (where there is no libproc)."""
    try:
        out = subprocess.run(["ps", "-axo", "pid=,ppid=,stat="], capture_output=True,
                             text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    table = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            try:
                table[int(parts[0])] = (int(parts[1]), parts[2])
            except ValueError:
                pass
    return table


def children_of(pid):
    buf = (ctypes.c_int * 1024)()
    n = _libproc.proc_listchildpids(pid, buf, ctypes.sizeof(buf))
    return [buf[i] for i in range(max(0, min(n, 1024)))]


def tree_of(pid):
    """`pid` and every process under it."""
    if _libproc is None:
        children = {}
        for p, (parent, _stat) in ps_table().items():
            children.setdefault(parent, []).append(p)
        kids = lambda p: children.get(p, [])  # noqa: E731
    else:
        kids = children_of
    found, todo = [], [pid]
    while todo:
        p = todo.pop()
        found.append(p)
        todo.extend(k for k in kids(p) if k not in found)
    return found


def is_stopped(pid):
    """Whether the process is stopped (SIGSTOP). None when there is no such process."""
    if _libproc is not None:
        buf = ctypes.create_string_buffer(136)  # struct proc_bsdinfo: flags, status, ...
        if _libproc.proc_pidinfo(pid, 3, ctypes.c_uint64(0), buf, 136) <= 0:
            return None
        return struct.unpack_from("II", buf.raw)[1] == 4  # SSTOP
    try:
        out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    return ("T" in out) if out.strip() else None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def ours(pids):
    """Those of `pids` that are alive and run this demo's code (never a reused pid)."""
    pids = [str(p) for p in pids]
    if not pids:
        return []
    try:
        out = subprocess.run(["ps", "-o", "pid=,stat=,command=", "-p", ",".join(pids)], capture_output=True,
                             text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    found = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and HERE in parts[2] and "Z" not in parts[1]:
            found.append(int(parts[0]))
    return found


def port_open(port):
    try:
        with socket.create_connection(("127.0.0.1", port), 0.3):
            return True
    except OSError:
        return False


class Gate:
    """A TCP relay in front of the store, for one device's network. While `silent`, it accepts
    connections and never answers them and passes nothing on: a network that drops everything
    (`/away` in the chat fails every call at once, which a dead network does not)."""

    def __init__(self, port, target_port):
        self.port, self.target_port = port, target_port
        self.silent = False
        self.closed = False
        self.socks = []
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", port))
        self.listener.listen(64)
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while not self.closed:
            try:
                conn, _addr = self.listener.accept()
            except OSError:
                return
            self.socks.append(conn)
            threading.Thread(target=self._relay, args=(conn,), daemon=True).start()

    def _relay(self, conn):
        import select
        up = None
        try:
            if self.silent:
                return  # held open, never answered
            up = socket.create_connection(("127.0.0.1", self.target_port), 5)
            self.socks.append(up)
            while not self.closed:
                ready, _w, _x = select.select([conn, up], [], [], 0.05)
                if self.silent:
                    return
                for sock in ready:
                    data = sock.recv(65536)
                    if not data:
                        conn.close()
                        up.close()
                        return
                    (up if sock is conn else conn).sendall(data)
        except (OSError, ValueError):
            for sock in (conn, up):
                try:
                    if sock is not None:
                        sock.close()
                except OSError:
                    pass

    def close(self):
        self.closed = True
        for sock in [self.listener] + list(self.socks):
            try:
                sock.close()
            except OSError:
                pass


class World:
    """One scenario's processes, folders and checks."""

    def __init__(self, name, port, verbose=False):
        base = os.environ.get("AUTO_SCN_DIR")
        if base:
            os.makedirs(base, exist_ok=True)
        self.name = name
        self.port = port
        self.verbose = verbose
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="auto-scn-%s-" % name, dir=base or None))
        self.proj = os.path.join(self.root, "laptop", "proj")
        self.work = os.path.join(self.root, "cloud", "work")
        self.data = os.path.join(self.root, "store")
        os.makedirs(self.proj)
        with open(os.path.join(self.proj, "README.md"), "w") as f:
            f.write("a project\n")
        self.url = "http://127.0.0.1:%d" % port
        self.c = Client(self.url, "t")
        self.t0 = time.time()
        self.procs = []
        self.laptop = None
        self.gate = None
        self.lease = LEASE
        self.seen_pids = set()
        self.epochs = {}
        self.epoch_drops = []
        self.watching = True
        self.timing = {"lease_ms": int(LEASE * 1000), "renew_ms": 888, "self_stop_ms": 3111}
        self.summary = ""
        self.flags = []
        self._base = dict(os.environ, AUTO_STORE_URL=self.url, AUTO_STORE_TOKEN="t", AUTO_PLAIN="1",
                          PYTHONUNBUFFERED="1", AUTO_AGENT_CMD="fake")
        self.watcher = threading.Thread(target=self._watch, daemon=True)
        self.watcher.start()

    # ---- the log of this run ----

    def step(self, text):
        # The second column is the wall clock as AUTO_DEBUG=1 stamps the processes' own lines.
        line = "%6.1fs  %6.1f  %s" % (time.time() - self.t0, time.time() % 1000, text)
        with open(os.path.join(self.root, "test.log"), "a") as f:
            f.write(line + "\n")
        if self.verbose:
            print("    " + line, flush=True)

    # ---- processes ----

    def env(self, role):
        env = dict(self._base, AUTO_HOME=os.path.join(self.root, role, "home"), AUTO_FAKE_HOST=role,
                   AUTO_CLAUDE_CONFIG_DIR=os.path.join(self.root, role, "agent-config"),
                   AUTO_DEVICE=LAPTOP if role == "laptop" else "device:" + role)
        if role == "laptop" and self.gate is not None:
            env["AUTO_STORE_URL"] = "http://127.0.0.1:%d" % self.gate.port
        return env

    def start_gate(self, port):
        """Puts the laptop's network behind a gate that can go silent."""
        if port_open(port):
            raise Failed("port %d is in use before the gate started" % port)
        self.gate = Gate(port, self.port)
        return self.gate

    def spawn(self, role, args, **kw):
        out = open(os.path.join(self.root, role + ".log"), "a")
        proc = subprocess.Popen(AUTO + args, env=self.env(role), stdout=out, stderr=subprocess.STDOUT, **kw)
        out.close()
        self.procs.append(proc)
        self.seen_pids.add(proc.pid)
        return proc

    def start_store(self):
        if port_open(self.port):
            raise Failed("port %d is in use before the store started" % self.port)
        proc = self.spawn("store", ["serve", "--host", "127.0.0.1", "--port", str(self.port), "--token", "t",
                                    "--lease", str(self.lease), "--data", self.data])
        status = self.until("the store answers", lambda: self.c.status(), 20)
        self.timing = status["timing"]
        return proc

    def start_machine(self):
        proc = self.spawn("cloud", ["machine", "--name", VM, "--work", self.work])
        self.until("the machine asked for work", lambda: (self.c.status()["machine"] or {}).get("awake"), 20)
        return proc

    def start_laptop(self, message=None, chat="c1"):
        args = ["chat", chat, "-C", self.proj] + (["-m", message] if message else [])
        self.laptop = self.spawn("laptop", args, stdin=subprocess.PIPE)
        return self.laptop

    def type(self, text):
        self.step("laptop types: " + text)
        self.laptop.stdin.write(text.encode() + b"\n")
        self.laptop.stdin.flush()

    def phone(self, args):
        done = subprocess.run(AUTO + args, env=self.env("phone"), capture_output=True, text=True, timeout=40)
        self.step("phone: auto %s -> exit %d: %s" % (" ".join(args), done.returncode,
                                                     short(done.stdout + done.stderr)))
        return done

    def freeze(self, proc):
        pids = tree_of(proc.pid)
        for pid in pids:
            try:
                os.kill(pid, signal.SIGSTOP)
            except (ProcessLookupError, PermissionError):
                pass
        self.step("froze %d process(es) under pid %d" % (len(pids), proc.pid))
        return pids

    def thaw(self, pids):
        for pid in pids:
            try:
                os.kill(pid, signal.SIGCONT)
            except (ProcessLookupError, PermissionError):
                pass
        self.step("woke %d process(es)" % len(pids))

    def kill_tree(self, proc):
        pids = tree_of(proc.pid)
        self.seen_pids.update(pids)
        for pid in pids:
            for sig in (signal.SIGCONT, signal.SIGKILL):
                try:
                    os.kill(pid, sig)
                except (ProcessLookupError, PermissionError):
                    pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        self.step("killed %d process(es) under pid %d" % (len(pids), proc.pid))

    def agents_under(self, proc):
        """[(pid, stopped)] of the agent processes a holder runs now."""
        out = []
        for pid in tree_of(proc.pid):
            stopped = is_stopped(pid) if pid != proc.pid else None
            if stopped is not None:
                out.append((pid, stopped))
        return out

    def _watch(self):
        """Remembers every process started here (to kill at the end) and every chat's epoch."""
        c = Client(self.url, "t")
        n = 0
        while self.watching:
            if n % (2 if _libproc is not None else 20) == 0:
                for proc in list(self.procs):
                    if proc.poll() is None:
                        self.seen_pids.update(tree_of(proc.pid))
            n += 1
            try:
                for view in c.chats():
                    was = self.epochs.get(view["id"])
                    if was is not None and view["epoch"] < was:
                        self.epoch_drops.append("%s epoch went from %d to %d" % (view["id"], was, view["epoch"]))
                    self.epochs[view["id"]] = view["epoch"]
            except (Offline, Refused, OSError, ValueError, KeyError):
                pass
            time.sleep(0.15)

    def cleanup(self):
        """Kills every process this scenario started, frozen or not. Returns what is left."""
        self.watching = False
        if self.gate is not None:
            self.gate.close()
        pids = set()
        for proc in self.procs:
            if proc.poll() is None:
                pids.add(proc.pid)
                try:
                    pids.update(tree_of(proc.pid))
                except Exception:
                    pass
        # An agent whose holder died has no parent left: found by what was seen earlier.
        try:
            pids.update(ours([pid for pid in self.seen_pids if pid not in pids and alive(pid)]))
        except Exception:
            pass
        for pid in pids:
            for sig in (signal.SIGCONT, signal.SIGKILL):
                try:
                    os.kill(pid, sig)
                except (ProcessLookupError, PermissionError):
                    pass
        for proc in self.procs:
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
            if proc.stdin:
                try:
                    proc.stdin.close()
                except OSError:
                    pass
        end = time.time() + 5
        while port_open(self.port) and time.time() < end:
            time.sleep(0.1)
        left = []
        if port_open(self.port):
            left.append("port %d still answers" % self.port)
        still = ours(pids)
        if still:
            left.append("processes still alive: %s" % still)
        return left

    # ---- exact times, for the question "did both run at once?" ----

    def track_agents(self, proc):
        """Watches the agent processes under `proc` every 10 ms. The answer's `last_running` is
        the last moment one of them was seen running, `stopped_at` the first moment all were
        seen stopped (or gone) after that."""
        pids = [pid for pid, _stopped in self.agents_under(proc)]
        track = {"pids": pids, "last_running": None, "stopped_at": None, "on": True}

        def loop():
            while track["on"] and self.watching:
                now = time.time()
                states = [is_stopped(pid) for pid in pids]
                if any(state is False for state in states):
                    track["last_running"], track["stopped_at"] = now, None
                elif track["stopped_at"] is None:
                    track["stopped_at"] = now
                time.sleep(0.01)
        threading.Thread(target=loop, daemon=True).start()
        return track

    def track_holder(self, chat="c1"):
        """Watches for the chat leaving its holder. The answer's `moved_at` is a time by which
        the store had given the chat away (the first time it was seen, or the store's own time
        of that change when nothing else changed since)."""
        start = self.view(chat)
        track = {"from": start["holder"], "moved_at": None, "to": None, "on": True}
        c = Client(self.url, "t")

        def loop():
            while track["on"] and self.watching and track["moved_at"] is None:
                try:
                    view = c.chat(chat)
                except (Offline, Refused, OSError, ValueError):
                    time.sleep(0.05)
                    continue
                seen = time.time()
                if view["epoch"] != start["epoch"]:
                    track["to"] = view["holder"]
                    track["moved_at"] = min(seen, view["updated_at"] / 1000.0)
                time.sleep(0.03)
        threading.Thread(target=loop, daemon=True).start()
        return track

    # ---- waiting ----

    def until(self, what, check, timeout=40.0, every=0.1):
        end = time.time() + timeout
        last = None
        while True:
            try:
                last = check()
            except (Offline, Refused, OSError, KeyError, IndexError, ValueError) as error:
                last = None
                self._last_error = repr(error)
            if last:
                self.step("ok: " + what)
                return last
            if time.time() >= end:
                break
            time.sleep(every)
        raise Failed("timed out after %ds waiting for: %s [%s]" % (timeout, what, self.brief()))

    def holds(self, what, check, seconds, every=0.2):
        """`check` stays true for `seconds`."""
        end = time.time() + seconds
        while time.time() < end:
            try:
                good = check()
            except (Offline, Refused, OSError, KeyError, IndexError, ValueError) as error:
                raise Failed("%s: could not check (%r)" % (what, error))
            if not good:
                raise Failed("did not hold for %.0fs: %s [%s]" % (seconds, what, self.brief()))
            time.sleep(every)
        self.step("ok, held for %.0fs: %s" % (seconds, what))

    def expect(self, good, what):
        """`what` says what is wrong when `good` is false; the scenario stops there."""
        if not good:
            raise Failed("%s [%s]" % (what, self.brief()))
        self.step("ok, not so: " + short(what, 110))

    def flag(self, good, what):
        """As `expect`, but the scenario goes on to its end and fails then: the rest of the
        journey is still tried."""
        if good:
            self.step("ok, not so: " + short(what, 110))
        else:
            self.step("NOT OK (the scenario goes on): " + what)
            self.flags.append(what)

    def brief(self, chat=None):
        try:
            views = self.c.chats()
        except (Offline, Refused, OSError, ValueError):
            return "the store does not answer"
        out = []
        for v in views:
            if chat and v["id"] != chat:
                continue
            out.append("%s: holder=%s state=%s epoch=%d needs_run=%s seq=%d copy_seq=%d inbox=%d/%d keep=%s standby=%s"
                       % (v["id"], v["holder"], v["state"], v["epoch"], v["needs_run"], v["last_seq"],
                          v["snapshot_seq"], v["inbox_acked"], v["inbox_n"], v["keep_in_cloud"], v["standby"]))
        return "; ".join(out) or "no chats"

    # ---- what the store and the folders say ----

    def view(self, chat="c1"):
        return self.c.chat(chat)

    def events(self, chat="c1"):
        return self.c.events(chat, 0)["events"]

    def kinds(self, kind, chat="c1"):
        return [e for e in self.events(chat) if e["kind"] == kind]

    def prompt_id(self, text, chat="c1"):
        ids = [e["id"] for e in self.events(chat) if e["kind"] == "user" and e.get("text") == text]
        return ids[0] if ids else None

    def ended(self, text, chat="c1"):
        """The turn_end events of the prompt with this text."""
        pid = self.prompt_id(text, chat)
        return [e for e in self.events(chat) if e["kind"] == "turn_end" and e.get("id") == pid] if pid else []

    def log_of(self, role, since=0):
        return read(os.path.join(self.root, role + ".log"))[since:]

    def log_mark(self, role):
        return len(read(os.path.join(self.root, role + ".log")))

    def in_proj(self, name):
        return read(os.path.join(self.proj, name))

    def in_work(self, name, chat="c1"):
        return read(os.path.join(self.work, chat, name))

    def in_tool(self, host, folder, count=1, chat="c1"):
        """The agent on `host` is in its long tool call (the count-th of the chat), and the
        store's copy has it. Returns the tool event."""
        def check():
            tools = [e for e in self.events(chat) if e["kind"] == "tool" and "sleep" in e.get("label", "")]
            if len(tools) < count:
                return None
            v = self.view(chat)
            if v["snapshot_seq"] < tools[-1]["seq"]:
                return None
            if ("started on " + host) not in read(os.path.join(folder, "step1.txt")):
                return None
            return tools[-1]
        return check

    def cloud_idle(self, chat="c1"):
        v = self.view(chat)
        return (v["holder"] == VM_HOLDER and v["state"] == "cloud" and not v["needs_run"]
                and v["snapshot_seq"] == v["last_seq"] and v["inbox_n"] == v["inbox_acked"])

    def settled_on(self, holder, chat="c1"):
        v = self.view(chat)
        return (v["holder"] == holder and not v["needs_run"] and v["snapshot_seq"] == v["last_seq"]
                and v["inbox_n"] == v["inbox_acked"])

    def home_with_own_copy(self, chat="c1"):
        """The laptop holds the chat and the store's newest copy is one the laptop made."""
        v = self.view(chat)
        if v["holder"] != LAPTOP or v["snapshot_seq"] != v["last_seq"]:
            return False
        return self.c.snapshot(chat)["manifest"].get("cwd") == self.proj

    def laptop_journal(self, chat="c1"):
        path = os.path.join(self.root, "laptop", "home", "chats", chat, "events.jsonl")
        return [json.loads(line) for line in read(path).splitlines() if line.strip()]

    def laptop_has_the_log(self, chat="c1"):
        """The laptop's own record of the chat is the store's, event for event."""
        mine = [(e["seq"], e["kind"], e.get("id")) for e in self.laptop_journal(chat)]
        theirs = [(e["seq"], e["kind"], e.get("id")) for e in self.events(chat)]
        return bool(theirs) and mine == theirs

    # ---- the invariants ----

    def invariants(self, settled=True):
        problems = list(self.epoch_drops)
        try:
            views = self.c.chats()
        except (Offline, Refused, OSError, ValueError) as error:
            return problems + ["the store did not answer at the end (%r)" % error]
        for v in views:
            cid = v["id"]
            disk = [json.loads(line) for line in
                    read(os.path.join(self.data, "events", cid + ".jsonl")).splitlines() if line.strip()]
            try:
                api = self.events(cid)
            except (Offline, Refused, OSError, ValueError):
                api = None
            for name, evs in (("the store's log file", disk), ("the events route", api)):
                if evs is None:
                    problems.append("%s: %s could not be read" % (cid, name))
                    continue
                seqs = [e.get("seq") for e in evs]
                if seqs != list(range(1, len(seqs) + 1)):
                    problems.append("%s: seqs in %s are not 1..N: %s" % (cid, name, short(seqs, 120)))
            if len(disk) != v["last_seq"]:
                problems.append("%s: the log has %d events but last_seq is %d" % (cid, len(disk), v["last_seq"]))
            users, texts, starts, ends = {}, {}, {}, {}
            for e in disk:
                kind, pid = e.get("kind"), e.get("id")
                if kind == "user":
                    if pid in users:
                        problems.append("%s: prompt %r is in the log twice (seq %d and %d)"
                                        % (cid, e.get("text"), users[pid]["seq"], e["seq"]))
                    elif e.get("text") in texts:
                        problems.append("%s: prompt %r is in the log under two ids (seq %d and %d)"
                                        % (cid, e.get("text"), texts[e.get("text")]["seq"], e["seq"]))
                    users.setdefault(pid, e)
                    texts.setdefault(e.get("text"), e)
                elif kind == "turn_start":
                    if pid not in users:
                        problems.append("%s: turn_start (seq %d) for a prompt that is not in the log" % (cid, e["seq"]))
                    starts.setdefault(pid, []).append(e)
                elif kind == "turn_end":
                    if pid not in starts:
                        problems.append("%s: turn_end (seq %d) with no turn_start before it" % (cid, e["seq"]))
                    ends.setdefault(pid, []).append(e)
            for pid, user in users.items():
                ns, ne = len(starts.get(pid, [])), len(ends.get(pid, []))
                label = "%s: prompt %r" % (cid, short(user.get("text", ""), 40))
                if ns > 1:
                    problems.append("%s was started %d times (seqs %s)" % (label, ns, [e["seq"] for e in starts[pid]]))
                if ne > 1:
                    problems.append("%s was ended %d times (seqs %s, by %s)"
                                    % (label, ne, [e["seq"] for e in ends[pid]], [e["by"] for e in ends[pid]]))
                if settled and ns == 0:
                    problems.append("%s never started" % label)
                elif settled and ne == 0:
                    problems.append("%s started but never ended" % label)
                elif settled and ne == 1 and not ends[pid][0].get("ok"):
                    problems.append("%s failed: %s" % (label, short(ends[pid][0].get("error") or "", 100)))
        return problems

    def ended_by(self, chat="c1"):
        return [e["by"] for e in self.events(chat) if e["kind"] == "turn_end"]


# ---- the scenarios ----

def takeover_mid_turn(w, slow=8):
    """The common start: the laptop is frozen (a closed lid) in the middle of a `slow:N` tool,
    the machine takes the chat and finishes the turn. Returns (the frozen pids, the prompt)."""
    first = "do the long job slow:%d" % slow
    w.start_laptop(first)
    w.until("the laptop is in its long tool call and the store's copy has it", w.in_tool("laptop", w.proj))
    time.sleep(1.0)
    w.step("-- the lid closes in the middle of the tool --")
    frozen = w.freeze(w.laptop)
    w.until("the store gave the chat to the machine", lambda: w.view()["holder"] == VM_HOLDER, 4 * LEASE)
    w.until("the machine finished the cut turn",
            lambda: "finished on cloud" in w.in_work("step2.txt") and len(w.ended(first)) == 1)
    w.until("the machine is idle with its copy stored", w.cloud_idle)
    return frozen, first


def stops_before_the_cloud(w, cut, what):
    """The laptop loses the store in the middle of a turn (`cut()` does it). Its agent must be
    stopped by the time the store gives the chat to the machine, about the self-stop time after
    the cut. Returns (seconds until the stop, the agents' track, when the chat was given away)."""
    self_stop, renew = w.timing["self_stop_ms"] / 1000.0, w.timing["renew_ms"] / 1000.0
    agents = w.track_agents(w.laptop)
    w.expect(len(agents["pids"]) == 1, "the laptop runs one agent: %r" % agents["pids"])
    holder = w.track_holder()
    w.until("the laptop's agent is running", lambda: agents["last_running"], 5)
    cut_at = time.time()
    cut()
    w.until("the store gave the chat to the machine",
            lambda: holder["moved_at"] and w.view()["holder"] == VM_HOLDER, 4 * LEASE)
    w.until("the laptop stopped its agent", lambda: agents["stopped_at"], 8 * LEASE, 0.02)
    took, given = agents["stopped_at"] - cut_at, holder["moved_at"] - cut_at
    overlap = agents["last_running"] - holder["moved_at"]
    times = "given away %.2fs after %s, agent stopped %.2fs after it; self-stop time %.1fs, lease %.1fs" % (
        given, what, took, self_stop, LEASE)
    w.step(times)
    w.flag(overlap <= 0, "the laptop's agent was still running %.2fs after the store gave the chat to the machine (%s)"
           % (overlap, times))
    w.expect(took >= self_stop - renew - 0.5, "the laptop stopped its agent long before the self-stop time (%s)" % times)
    if overlap <= 0:
        w.flag(took <= self_stop + renew + 1.0, "the laptop was late to stop its agent (%s)" % times)
    return took, agents, max(holder["moved_at"], agents["last_running"])


def no_network(w):
    """`/away` mid-turn: the laptop stops its agent itself, the machine finishes the turn, `/back`
    brings the chat home with the machine's files."""
    w.start_store()
    w.start_machine()
    first = "do the long job slow:12"
    w.start_laptop(first)
    w.until("the laptop is in its long tool call and the store's copy has it", w.in_tool("laptop", w.proj))
    tool_at = time.time()
    time.sleep(1.0)
    self_stop = w.timing["self_stop_ms"] / 1000.0
    took, agents, given_at = stops_before_the_cloud(w, lambda: w.type("/away"), "/away")
    w.expect("acting out a laptop with no network" in w.log_of("laptop"), "the laptop did not say it acts out no network")
    w.until("the laptop says its agent is stopped", lambda: "the agent is stopped" in w.log_of("laptop"), 5)
    w.until("the machine finished the turn",
            lambda: "finished on cloud" in w.in_work("step2.txt") and len(w.ended(first)) == 1)
    w.expect("started on laptop" in w.in_work("step1.txt"), "the folder did not travel: step1.txt on the machine is %r"
             % w.in_work("step1.txt"))
    w.expect("1 earlier" in w.in_work("resumed.txt"), "the session did not travel: resumed.txt is %r" % w.in_work("resumed.txt"))
    # Past the moment the laptop's own tool would have ended had it kept running.
    wait = tool_at + 12 + 2.5 - time.time()
    if wait > 0:
        time.sleep(wait)
    w.expect(not os.path.exists(os.path.join(w.proj, "step2.txt")),
             "the laptop's agent ran on with no network and wrote step2.txt itself: %r" % w.in_proj("step2.txt"))
    w.expect(agents["stopped_at"] and agents["last_running"] <= given_at,
             "the laptop's agent ran again while the machine had the chat")
    w.until("the machine is idle with its copy stored", w.cloud_idle)
    w.expect(w.view()["holder"] == VM_HOLDER, "the chat left the machine while the laptop had no network")
    w.type("/back")
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop has the machine's files",
            lambda: "finished on cloud" in w.in_proj("step2.txt") and "resumed on cloud" in w.in_proj("resumed.txt"))
    w.until("the laptop says the chat is back", lambda: "the chat is back on this machine" in w.log_of("laptop"), 10)
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    w.expect(w.in_proj("step2.txt") == "finished on cloud\n", "step2.txt on the laptop is %r" % w.in_proj("step2.txt"))
    w.expect(w.ended_by() == [VM_HOLDER], "turns ended on %s" % w.ended_by())
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.holds("the chat stays home", lambda: w.view()["holder"] == LAPTOP, 1.5 * LEASE)
    w.summary = "agent stopped %.1fs after /away (self-stop %.1fs); turn ended on the machine; home at epoch %d" % (
        took, self_stop, w.view()["epoch"])


def quit_mid_turn(w):
    """The laptop process is killed mid-turn; the machine finishes; `auto chat c1` later brings
    the chat home and a new prompt runs on the laptop."""
    w.start_store()
    w.start_machine()
    first = "do the long job slow:12"
    w.start_laptop(first)
    w.until("the laptop is in its long tool call and the store's copy has it", w.in_tool("laptop", w.proj))
    time.sleep(1.0)
    w.step("-- the laptop process is killed --")
    w.kill_tree(w.laptop)
    w.until("the store gave the chat to the machine", lambda: w.view()["holder"] == VM_HOLDER, 4 * LEASE)
    w.until("the machine finished the turn",
            lambda: "finished on cloud" in w.in_work("step2.txt") and len(w.ended(first)) == 1)
    w.until("the machine is idle with its copy stored", w.cloud_idle)
    w.expect(not os.path.exists(os.path.join(w.proj, "step2.txt")), "step2.txt is on the laptop with the laptop dead")
    w.holds("the chat stays on the machine while the laptop is gone", lambda: w.view()["holder"] == VM_HOLDER, 2 * LEASE)
    w.step("-- auto chat c1 again, in the same folder --")
    mark = w.log_mark("laptop")
    w.start_laptop()
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop has the machine's files",
            lambda: "finished on cloud" in w.in_proj("step2.txt") and "resumed on cloud" in w.in_proj("resumed.txt"))
    w.until("the laptop says the chat is back", lambda: "the chat is back on this machine" in w.log_of("laptop", mark), 10)
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    last = "one more after the quit"
    w.type(last)
    w.until("the new prompt ran on the laptop", lambda: "laptop: " + last in w.in_proj("notes.txt"))
    w.until("the store has the laptop's turn", lambda: len(w.ended(last)) == 1 and w.settled_on(LAPTOP))
    w.expect(w.ended_by() == [VM_HOLDER, LAPTOP], "turns ended on %s" % w.ended_by())
    said = [e["text"] for e in w.kinds("text")]
    w.expect(any("Noted on laptop. I remember 2 earlier" in t for t in said),
             "the laptop's agent did not have the whole history: %s" % short(said[-2:]))
    w.expect(w.in_proj("step2.txt") == "finished on cloud\n", "step2.txt on the laptop is %r" % w.in_proj("step2.txt"))
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.summary = "turns ended on machine, laptop; epoch %d" % w.view()["epoch"]


def idle_laptop_closes(w):
    """A lid closed on an idle chat parks it; a phone message starts it on the machine; the
    laptop wakes and gets the result."""
    w.start_store()
    w.start_machine()
    first = "a first note"
    w.start_laptop(first)

    def idle_at_home():
        v = w.view()
        return (v["holder"] == LAPTOP and not v["needs_run"] and len(w.ended(first)) == 1
                and v["snapshot_seq"] == v["last_seq"] and "laptop: " + first in w.in_proj("notes.txt"))
    w.until("the laptop ran its first prompt and is idle with a copy stored", idle_at_home)
    time.sleep(1.0)
    w.step("-- the lid closes with nothing to do --")
    mark = w.log_mark("cloud")
    frozen = w.freeze(w.laptop)
    w.until("the chat is parked", lambda: w.view()["state"] == "parked", 4 * LEASE)
    w.holds("nothing runs in the Cloud: the chat stays parked",
            lambda: w.view()["holder"] == "parked" and not os.path.exists(os.path.join(w.work, "c1")), 2.5 * LEASE)
    w.expect("c1" not in w.log_of("cloud", mark), "the machine did something with a parked chat: %s"
             % short(w.log_of("cloud", mark)))
    message = "a note from the phone"
    sent = w.phone(["send", "c1", message])
    w.expect(sent.returncode == 0, "auto send failed: %s" % short(sent.stdout + sent.stderr))
    w.expect("resuming" in sent.stdout, "auto send did not say the Cloud is starting: %r" % sent.stdout.strip())
    w.until("the machine has the chat", lambda: w.view()["holder"] == VM_HOLDER, 10)
    w.until("the machine ran the phone's message",
            lambda: "cloud: " + message in w.in_work("notes.txt") and len(w.ended(message)) == 1)
    w.expect("laptop: " + first in w.in_work("notes.txt"), "the folder did not travel: notes.txt on the machine is %r"
             % w.in_work("notes.txt"))
    w.until("the machine is idle with its copy stored", w.cloud_idle)
    w.step("-- the lid opens --")
    w.thaw(frozen)
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop has the result", lambda: "cloud: " + message in w.in_proj("notes.txt"))
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    w.expect(w.in_proj("notes.txt") == "laptop: %s\ncloud: %s\n" % (first, message),
             "notes.txt on the laptop is %r" % w.in_proj("notes.txt"))
    w.expect(w.ended_by() == [LAPTOP, VM_HOLDER], "turns ended on %s" % w.ended_by())
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.summary = "parked, then started by the phone; home at epoch %d" % w.view()["epoch"]


def keep_in_cloud(w):
    """`auto keep c1 on` after a takeover: the laptop wakes but the chat stays on the machine,
    which runs what is typed on the laptop; `keep off` brings it home."""
    w.start_store()
    w.start_machine()
    frozen, _first = takeover_mid_turn(w)
    kept = w.phone(["keep", "c1", "on"])
    w.expect(kept.returncode == 0 and "keep in Cloud: on" in kept.stdout, "auto keep on said: %s"
             % short(kept.stdout + kept.stderr))
    w.step("-- the lid opens --")
    w.thaw(frozen)
    w.until("the laptop knows the Cloud has the chat", lambda: "the Cloud took this chat" in w.log_of("laptop"), 15)
    w.until("the store sees the laptop standing by", lambda: w.view()["standby"] == LAPTOP, 10)
    w.holds("the chat stays on the machine with the laptop back", lambda: w.view()["holder"] == VM_HOLDER, 2.5 * LEASE)
    typed = "typed on the laptop while kept"
    w.type(typed)
    w.until("the machine ran what was typed on the laptop",
            lambda: "cloud: " + typed in w.in_work("notes.txt") and len(w.ended(typed)) == 1)
    w.expect(w.ended(typed)[0]["by"] == VM_HOLDER, "the prompt's turn ended on %s" % w.ended(typed)[0]["by"])
    w.expect("laptop: " + typed not in w.in_proj("notes.txt"), "the laptop ran the prompt itself")
    w.until("the laptop shows the machine's answer",
            lambda: "Noted on cloud" in w.log_of("laptop") and "(done on cloud:%s)" % VM in w.log_of("laptop"), 15)
    w.until("the machine is idle with its copy stored", w.cloud_idle)
    w.holds("still on the machine, idle", lambda: w.view()["holder"] == VM_HOLDER, 1.5 * LEASE)
    kept = w.phone(["keep", "c1", "off"])
    w.expect(kept.returncode == 0 and "keep in Cloud: off" in kept.stdout, "auto keep off said: %s"
             % short(kept.stdout + kept.stderr))
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop has the machine's files",
            lambda: "finished on cloud" in w.in_proj("step2.txt") and "cloud: " + typed in w.in_proj("notes.txt"))
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    w.expect(w.ended_by() == [VM_HOLDER, VM_HOLDER], "turns ended on %s" % w.ended_by())
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.summary = "stayed on the machine with the laptop awake, came home after keep off; epoch %d" % w.view()["epoch"]


def auto_off(w):
    """`auto off` is refused while the machine holds the chat; once home with the laptop's own
    copy stored, `/off` works and a frozen laptop no longer loses the chat."""
    w.start_store()
    w.start_machine()
    frozen, _first = takeover_mid_turn(w)
    off = w.phone(["off", "c1"])
    said = (off.stdout + off.stderr).strip()
    w.expect(off.returncode != 0, "auto off worked while the machine holds the chat: %r" % said)
    w.expect("Cloud" in said and "Traceback" not in said and len(said.splitlines()) == 1,
             "auto off's refusal is not a clear message: %r" % short(said))
    v = w.view()
    w.expect(v["auto"] and v["holder"] == VM_HOLDER, "the refused auto off changed the chat")
    w.step("-- the lid opens --")
    w.thaw(frozen)
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.type("/off")
    w.until("the laptop says Auto is off", lambda: "Auto is off: the chat runs only here" in w.log_of("laptop"), 10)
    v = w.view()
    w.expect(not v["auto"] and v["state"] == "off", "the store does not say Auto is off")
    cloud_mark = w.log_mark("cloud")
    after = "a job after off slow:8"
    w.type(after)
    w.until("the laptop runs the next prompt itself, in its tool",
            lambda: "started on laptop" in w.in_proj("step1.txt") and "sleep 8" in w.log_of("laptop").split("Auto is off:")[-1])
    time.sleep(1.0)
    w.step("-- the lid closes again, Auto off --")
    frozen = w.freeze(w.laptop)

    def still_off():
        v = w.view()
        return not v["auto"] and v["state"] == "off" and not v["holder"].startswith("vm:")
    w.holds("the frozen laptop does not lose the chat to the machine", still_off, 3 * LEASE)
    w.expect("c1" not in w.log_of("cloud", cloud_mark), "the machine did something with a chat that has Auto off: %s"
             % short(w.log_of("cloud", cloud_mark)))
    w.thaw(frozen)
    shown = lambda: w.log_of("laptop").split("Auto is off:")[-1]  # noqa: E731
    w.until("the laptop finished its own turn after waking",
            lambda: w.in_proj("step2.txt") == "finished on laptop\n" and "(done on laptop)" in shown(), 30)
    w.expect(still_off(), "the chat is not off any more")
    w.expect("c1" not in w.log_of("cloud", cloud_mark), "the machine did something with a chat that has Auto off")
    w.expect(w.ended_by() == [VM_HOLDER], "turns in the store ended on %s" % w.ended_by())
    w.flag("Starting the long job on laptop" in shown() and "The long job finished on laptop" in shown(),
           "with Auto off the chat does not show what the agent says: after /off the laptop showed only %r"
           % short(shown(), 200))
    w.summary = "refused with %r; off at epoch %d; the frozen laptop kept the chat" % (short(said, 60), w.view()["epoch"])


def phone_new(w):
    """`auto new TEXT --detach` with no laptop: the machine creates the chat and runs the prompt."""
    w.start_store()
    w.start_machine()
    text = "note this"
    new = w.phone(["new", text, "--detach"])
    w.expect(new.returncode == 0 and new.stdout.startswith("chat "), "auto new said: %s" % short(new.stdout + new.stderr))
    chat = new.stdout.split()[1].rstrip(":")
    w.until("the machine ran the prompt", lambda: "cloud: " + text in w.in_work("notes.txt", chat))

    def in_events():
        events = w.events(chat)
        users = [e for e in events if e["kind"] == "user" and e.get("text") == text]
        texts = [e for e in events if e["kind"] == "text" and "Noted on cloud" in e.get("text", "")]
        ends = [e for e in events if e["kind"] == "turn_end" and e.get("ok") and e["by"] == VM_HOLDER]
        return len(users) == 1 and len(texts) == 1 and len(ends) == 1
    w.until("the result is in the store's events", in_events)
    w.until("the machine is idle with its copy stored", lambda: w.cloud_idle(chat))
    ls = w.phone(["ls"])
    rows = [line for line in ls.stdout.splitlines() if line.startswith(chat)]
    w.expect(ls.returncode == 0 and len(rows) == 1, "auto ls does not show the chat: %s" % short(ls.stdout + ls.stderr))
    w.expect(text in rows[0] and "in the Cloud (%s), idle" % VM in rows[0], "auto ls shows: %r" % rows[0])
    w.holds("the chat stays on the machine, idle, run once",
            lambda: w.cloud_idle(chat) and w.in_work("notes.txt", chat) == "cloud: %s\n" % text, 1.5 * LEASE)
    w.summary = "chat %s ran on the machine; ls: %s" % (chat, short(" ".join(rows[0].split()), 70))


def store_restart(w):
    """The store is killed mid-chat and started again on the same data and port: the laptop
    keeps the chat, the next prompt runs, the log has nothing twice."""
    w.start_store()
    w.start_machine()
    first = "a first note"
    w.start_laptop(first)
    w.until("the first prompt ran", lambda: len(w.ended(first)) == 1 and w.view()["snapshot_seq"] == w.view()["last_seq"])
    second = "the second job slow:6"
    w.type(second)
    w.until("the laptop is in its long tool call and the store's copy has it", w.in_tool("laptop", w.proj))
    time.sleep(0.5)
    before = w.view()
    events_before = w.events()
    w.step("-- the store is killed --")
    w.kill_tree(w.procs[0])
    w.expect(not port_open(w.port), "the store still answers after it was killed")
    w.spawn("store", ["serve", "--host", "127.0.0.1", "--port", str(w.port), "--token", "t",
                      "--lease", str(LEASE), "--data", w.data])
    w.until("the store answers again", lambda: w.c.status(), 20)
    after = w.view()
    w.expect(after["holder"] == LAPTOP and after["epoch"] == before["epoch"] and after["auto"],
             "the chat's holder did not come back: before %s epoch %d" % (before["holder"], before["epoch"]))
    w.expect(after["last_seq"] >= before["last_seq"] and after["snapshot"] >= before["snapshot"]
             and after["title"] == before["title"],
             "the store lost state: seq %d -> %d, copy #%d -> #%d" % (before["last_seq"], after["last_seq"],
                                                                     before["snapshot"], after["snapshot"]))
    w.expect(w.events()[:len(events_before)] == events_before, "the events before the restart changed")
    w.until("the store knows its machine again", lambda: (w.c.status()["machine"] or {}).get("name") == VM, 10)
    w.until("the turn that was running finished on the laptop",
            lambda: w.in_proj("step2.txt") == "finished on laptop\n" and len(w.ended(second)) == 1, 30)
    third = "a note after the restart"
    w.type(third)
    w.until("the new prompt ran on the laptop",
            lambda: "laptop: " + third in w.in_proj("notes.txt") and len(w.ended(third)) == 1)
    w.until("the laptop is idle with its copy stored", lambda: w.settled_on(LAPTOP))
    v = w.view()
    w.expect(v["holder"] == LAPTOP and v["epoch"] == before["epoch"],
             "the laptop did not keep the chat: epoch %d -> %d" % (before["epoch"], v["epoch"]))
    w.expect(w.ended_by() == [LAPTOP] * 3, "turns ended on %s" % w.ended_by())
    w.expect(not os.path.exists(os.path.join(w.work, "c1")), "the machine took the chat during the restart")
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.summary = "the laptop kept the chat at epoch %d; %d events, none twice" % (v["epoch"], v["last_seq"])


def machine_restart(w):
    """The machine process is killed in the middle of a turn and started again: it picks the
    chat up, finishes the cut turn once, and the chat goes home when the laptop is back."""
    w.start_store()
    machine = w.start_machine()
    frozen, _first = takeover_mid_turn(w)
    second = "the second job slow:12"
    sent = w.phone(["send", "c1", second])
    w.expect(sent.returncode == 0, "auto send failed: %s" % short(sent.stdout + sent.stderr))
    w.until("the machine is in the long tool call of the phone's job, and the store's copy has it",
            w.in_tool("cloud", os.path.join(w.work, "c1"), count=2))
    time.sleep(1.0)
    w.expect(not w.ended(second) and w.agents_under(machine), "the machine is not in the middle of the turn")
    stamp = os.path.getmtime(os.path.join(w.work, "c1", "step2.txt"))
    w.step("-- the machine process is killed in the middle of the turn --")
    w.kill_tree(machine)
    time.sleep(1.0)
    w.expect(w.view()["holder"] == VM_HOLDER, "the chat left the machine")
    mark = w.log_mark("cloud")
    w.spawn("cloud", ["machine", "--name", VM, "--work", w.work])
    w.until("the machine finished the cut turn", lambda: len(w.ended(second)) >= 1, 12 * LEASE)
    w.expect(w.ended(second)[0]["by"] == VM_HOLDER and w.ended(second)[0].get("ok"),
             "the cut turn ended: %s" % short(w.ended(second)[0]))
    w.expect(os.path.getmtime(os.path.join(w.work, "c1", "step2.txt")) > stamp and "finished on cloud" in w.in_work("step2.txt"),
             "the machine did not finish the job: step2.txt was not written again")
    w.until("the machine is idle with its copy stored", w.cloud_idle)
    w.holds("the cut turn was finished exactly once",
            lambda: len(w.ended(second)) == 1 and len(w.kinds("turn_start")) == 2 and w.view()["holder"] == VM_HOLDER,
            2 * LEASE)
    w.step("machine log after its restart: " + short(w.log_of("cloud", mark), 300))
    w.step("-- the lid opens --")
    w.thaw(frozen)
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop has the machine's files",
            lambda: "finished on cloud" in w.in_proj("step2.txt") and "started on cloud" in w.in_proj("step1.txt"))
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    w.expect(w.ended_by() == [VM_HOLDER, VM_HOLDER], "turns ended on %s" % w.ended_by())
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.summary = "the machine continued its cut turn once after the restart; home at epoch %d" % w.view()["epoch"]


def two_messages_queue(w):
    """Two prompts typed quickly, the lid closes during the first: both run, in order, once."""
    w.start_store()
    w.start_machine()
    w.start_laptop()
    w.until("the laptop holds the chat", lambda: w.view()["holder"] == LAPTOP)
    first, second = "the first job slow:8", "the second note"
    w.type(first)
    w.type(second)

    def both_in_store():
        tool = w.in_tool("laptop", w.proj)()
        if not tool or not w.prompt_id(second):
            return None
        return w.view()["snapshot_seq"] >= max(e["seq"] for e in w.events() if e["kind"] in ("user", "tool"))
    w.until("the store has both prompts, and the first is in its tool", both_in_store)
    w.expect(not w.ended(first) and not [e for e in w.kinds("turn_start") if e["id"] == w.prompt_id(second)],
             "the second prompt started before the first ended")
    time.sleep(1.0)
    w.step("-- the lid closes during the first prompt --")
    frozen = w.freeze(w.laptop)
    w.until("the store gave the chat to the machine", lambda: w.view()["holder"] == VM_HOLDER, 4 * LEASE)
    w.until("the machine finished the first prompt",
            lambda: "finished on cloud" in w.in_work("step2.txt") and len(w.ended(first)) == 1)
    w.until("the machine ran the second prompt",
            lambda: "cloud: " + second in w.in_work("notes.txt") and len(w.ended(second)) == 1)
    w.until("the machine is idle with its copy stored", w.cloud_idle)
    events = w.events()
    p1, p2 = w.prompt_id(first), w.prompt_id(second)
    order = [(e["kind"], {p1: "first", p2: "second"}.get(e.get("id"))) for e in events
             if e["kind"] in ("turn_start", "turn_end")]
    w.expect(order == [("turn_start", "first"), ("turn_end", "first"), ("turn_start", "second"), ("turn_end", "second")],
             "the turns did not run in order, once each: %s" % order)
    w.step("-- the lid opens --")
    w.thaw(frozen)
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop has the machine's files",
            lambda: "finished on cloud" in w.in_proj("step2.txt") and "cloud: " + second in w.in_proj("notes.txt"))
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    w.holds("nothing runs a second time at home",
            lambda: len(w.kinds("turn_end")) == 2 and len(w.kinds("turn_start")) == 2 and len(w.kinds("user")) == 2
            and w.view()["holder"] == LAPTOP, 2 * LEASE)
    w.expect(w.in_proj("notes.txt") == "cloud: %s\n" % second, "notes.txt on the laptop is %r" % w.in_proj("notes.txt"))
    w.expect(w.in_proj("step2.txt") == "finished on cloud\n", "step2.txt on the laptop is %r" % w.in_proj("step2.txt"))
    w.expect(w.ended_by() == [VM_HOLDER, VM_HOLDER], "turns ended on %s" % w.ended_by())
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.summary = "both prompts ran on the machine in order, once each; home at epoch %d" % w.view()["epoch"]


def silent_network(w):
    """(extra) The laptop's network goes silent mid-turn: calls get no answer at all, where
    `/away` fails them at once. The laptop must still stop its agent before the Cloud runs the chat."""
    w.start_store()
    w.start_machine()
    gate = w.start_gate(GATE_PORT)
    first = "do the long job slow:25"
    w.start_laptop(first)
    w.until("the laptop is in its long tool call and the store's copy has it", w.in_tool("laptop", w.proj))
    time.sleep(1.0)

    def cut():
        w.step("-- the laptop's network goes silent --")
        gate.silent = True
    took, agents, given_at = stops_before_the_cloud(w, cut, "the network went silent")
    w.until("the machine finished the turn",
            lambda: "finished on cloud" in w.in_work("step2.txt") and len(w.ended(first)) == 1)
    w.until("the machine is idle with its copy stored", w.cloud_idle)
    w.expect(not os.path.exists(os.path.join(w.proj, "step2.txt")), "the laptop's agent wrote step2.txt itself")
    w.expect(agents["stopped_at"] and agents["last_running"] <= given_at,
             "the laptop's agent ran again while the machine had the chat")
    w.step("-- the network is back --")
    gate.silent = False
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop has the machine's files",
            lambda: w.in_proj("step2.txt") == "finished on cloud\n" and "resumed on cloud" in w.in_proj("resumed.txt"))
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    w.expect(w.ended_by() == [VM_HOLDER], "turns ended on %s" % w.ended_by())
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.summary = "agent stopped %.1fs after the network went silent, before the machine had the chat" % took


def store_down_past_lease(w):
    """(extra) The store is down for longer than a lease while the laptop works. The laptop never
    went away, so it keeps its chat and finishes its turn itself."""
    w.start_store()
    w.start_machine()
    first = "do the long job slow:14"
    w.start_laptop(first)
    w.until("the laptop is in its long tool call and the store's copy has it", w.in_tool("laptop", w.proj))
    time.sleep(0.5)
    before = w.view()
    w.step("-- the store is killed, and stays down for %.0fs --" % (1.5 * LEASE))
    w.kill_tree(w.procs[0])
    time.sleep(1.5 * LEASE)
    w.spawn("store", ["serve", "--host", "127.0.0.1", "--port", str(w.port), "--token", "t",
                      "--lease", str(LEASE), "--data", w.data])
    w.until("the store answers again", lambda: w.c.status(), 20)
    w.holds("the laptop, which was there all along, keeps the chat",
            lambda: w.view()["holder"] == LAPTOP and w.view()["epoch"] == before["epoch"], 2 * LEASE)
    w.until("the laptop finished its own turn",
            lambda: w.in_proj("step2.txt") == "finished on laptop\n" and len(w.ended(first)) == 1, 40)
    w.until("the laptop is idle with its copy stored", lambda: w.settled_on(LAPTOP))
    w.expect(w.ended_by() == [LAPTOP], "turns ended on %s" % w.ended_by())
    w.expect(not os.path.exists(os.path.join(w.work, "c1")), "the machine took the chat")
    w.summary = "the laptop kept the chat at epoch %d through a %.0fs outage" % (w.view()["epoch"], 1.5 * LEASE)


def first_note_at_home(w, first="a first note"):
    """The common start of the small ones: the laptop ran one prompt and is idle, copy stored."""
    w.start_laptop(first)
    w.until("the laptop ran its first prompt and is idle with a copy stored",
            lambda: w.settled_on(LAPTOP) and len(w.ended(first)) == 1 and "laptop: " + first in w.in_proj("notes.txt"))
    return first


def off_then_reopen(w):
    """(extra) `/off`, then the chat is left and opened again with `auto chat c1`: it still runs
    prompts on the laptop."""
    w.start_store()
    w.start_machine()
    first_note_at_home(w)
    w.type("/off")
    w.until("the laptop says Auto is off", lambda: "Auto is off: the chat runs only here" in w.log_of("laptop"), 10)
    second = "a note after off"
    w.type(second)
    w.until("a prompt runs on the laptop with Auto off", lambda: "laptop: " + second in w.in_proj("notes.txt"), 20)
    w.until("the turn is done", lambda: "(done on laptop)" in w.log_of("laptop").split("Auto is off:")[-1], 10)
    w.type("/quit")
    w.until("the laptop left the chat", lambda: w.laptop.poll() is not None, 20)
    w.step("-- auto chat c1 again --")
    mark = w.log_mark("laptop")
    w.start_laptop()
    w.until("the opened chat shows its history", lambda: second in w.log_of("laptop", mark), 15)
    third = "a note after opening it again"
    w.type(third)
    w.until("a prompt runs in the chat that was opened again", lambda: "laptop: " + third in w.in_proj("notes.txt"), 20)
    v = w.view()
    w.expect(not v["auto"] and v["state"] == "off", "the store does not say Auto is off")
    w.summary = "three prompts ran on the laptop, two of them with Auto off"


def off_from_phone_while_asleep(w):
    """(extra) `auto off c1` from the phone while the lid is closed on an idle chat: the laptop
    wakes with Auto off and the chat still runs prompts there."""
    w.start_store()
    w.start_machine()
    first_note_at_home(w)
    time.sleep(0.5)
    frozen = w.freeze(w.laptop)
    off = w.phone(["off", "c1"])
    w.expect(off.returncode == 0 and "Auto is off for c1" in off.stdout, "auto off said: %s" % short(off.stdout + off.stderr))
    w.holds("the chat is off and stays off the machine",
            lambda: w.view()["state"] == "off" and not w.view()["holder"].startswith("vm:"), 1.5 * LEASE)
    w.step("-- the lid opens --")
    w.thaw(frozen)
    w.until("the laptop says Auto is off", lambda: "Auto is off for this chat" in w.log_of("laptop"), 15)
    second = "a note after waking"
    w.type(second)
    w.until("a prompt runs on the laptop after it woke with Auto off",
            lambda: "laptop: " + second in w.in_proj("notes.txt"), 20)
    w.summary = "woke with Auto off and ran the next prompt"


def phone_says_no_clearly(w):
    """(extra) `auto send`, `auto keep` and `auto off` for a chat that is not there, and
    `auto send` to a chat with Auto off, fail with one clear line, not a Python traceback."""
    w.start_store()
    w.start_machine()
    first_note_at_home(w)
    w.type("/off")
    w.until("the laptop says Auto is off", lambda: "Auto is off: the chat runs only here" in w.log_of("laptop"), 10)
    bad = []
    for args in (["send", "c1", "hello from the phone"], ["send", "nosuchchat", "hello"],
                 ["keep", "nosuchchat", "on"], ["off", "nosuchchat"]):
        done = w.phone(args)
        said = (done.stdout + done.stderr).strip()
        if done.returncode == 0 or "Traceback" in said or len(said.splitlines()) != 1:
            bad.append("`auto %s` exit %d: %s" % (" ".join(args[:2]), done.returncode,
                                                 short(said.splitlines()[-1] if said else "", 90)
                                                 + (" (after a %d-line traceback)" % (len(said.splitlines()) - 1)
                                                    if "Traceback" in said else "")))
    w.expect(not bad, "no clear refusal from: " + "; ".join(bad))
    w.summary = "four refusals, one line each"


def phone_chat_comes_to_laptop(w):
    """(extra) A chat started from the phone is opened on a laptop with `auto chat ID`: it comes
    to the laptop with the machine's files, and the next prompt runs there."""
    w.start_store()
    w.start_machine()
    text = "note this"
    new = w.phone(["new", text, "--detach"])
    w.expect(new.returncode == 0 and new.stdout.startswith("chat "), "auto new said: %s" % short(new.stdout + new.stderr))
    chat = new.stdout.split()[1].rstrip(":")
    w.until("the machine ran the prompt and is idle", lambda: len(w.ended(text, chat)) == 1 and w.cloud_idle(chat))
    w.start_laptop(chat=chat)
    w.until("the chat came to the laptop", lambda: w.view(chat)["holder"] == LAPTOP)
    w.until("the laptop has the machine's files", lambda: w.in_proj("notes.txt") == "cloud: %s\n" % text)
    w.until("the laptop stored a copy of its own", lambda: w.home_with_own_copy(chat))
    last = "one more on the laptop"
    w.type(last)
    w.until("the next prompt ran on the laptop",
            lambda: "laptop: " + last in w.in_proj("notes.txt") and len(w.ended(last, chat)) == 1)
    said = [e["text"] for e in w.kinds("text", chat)]
    w.expect(any("Noted on laptop. I remember 1 earlier" in t for t in said),
             "the laptop's agent did not have the history: %s" % short(said[-2:]))
    w.expect(w.ended_by(chat) == [VM_HOLDER, LAPTOP], "turns ended on %s" % w.ended_by(chat))
    w.until("the laptop is idle with its copy stored", lambda: w.settled_on(LAPTOP, chat))
    w.until("the laptop's record of the chat is the store's", lambda: w.laptop_has_the_log(chat), 10)
    w.summary = "chat %s came to the laptop at epoch %d" % (chat, w.view(chat)["epoch"])


def quit_and_reopen_at_once(w):
    """(extra) The laptop process is killed mid-turn and `auto chat c1` is run again before the
    lease runs out: the laptop keeps the chat and finishes the cut turn itself, once."""
    w.lease = 15.0  # room to start the process again, however busy this Mac is
    w.start_store()
    w.start_machine()
    first = "do the long job slow:12"
    w.start_laptop(first)
    w.until("the laptop is in its long tool call and the store's copy has it", w.in_tool("laptop", w.proj))
    time.sleep(1.0)
    before = w.view()
    w.step("-- the laptop process is killed, and started again at once --")
    w.kill_tree(w.laptop)
    w.start_laptop()
    w.until("the laptop finished the cut turn itself",
            lambda: w.in_proj("step2.txt") == "finished on laptop\n" and len(w.ended(first)) == 1, 30)
    v = w.view()
    w.expect(v["holder"] == LAPTOP and v["epoch"] == before["epoch"], "the laptop did not keep the chat")
    w.expect("resumed on laptop with 1 earlier" in w.in_proj("resumed.txt"), "resumed.txt is %r" % w.in_proj("resumed.txt"))
    w.until("the laptop is idle with its copy stored", lambda: w.settled_on(LAPTOP))
    w.holds("the cut turn ran once, on the laptop",
            lambda: len(w.kinds("turn_end")) == 1 and len(w.kinds("turn_start")) == 1
            and not os.path.exists(os.path.join(w.work, "c1")), 5)
    w.expect(w.ended_by() == [LAPTOP], "turns ended on %s" % w.ended_by())
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.summary = "the laptop kept the chat at epoch %d and continued its turn once" % v["epoch"]


def short_nap_mid_turn(w):
    """(extra) The lid closes for a few seconds mid-turn, less than the lease: the laptop keeps
    the chat and its turn finishes there."""
    w.lease = 10.0
    w.start_store()
    w.start_machine()
    first = "do the long job slow:8"
    w.start_laptop(first)
    w.until("the laptop is in its long tool call and the store's copy has it", w.in_tool("laptop", w.proj))
    before = w.view()
    agents = w.track_agents(w.laptop)
    w.step("-- the lid closes for 3 s --")
    frozen = w.freeze(w.laptop)
    time.sleep(3.0)
    w.thaw(frozen)
    try:
        w.until("the turn finished on the laptop after the nap",
                lambda: w.in_proj("step2.txt") == "finished on laptop\n" and len(w.ended(first)) == 1, 25)
    except Failed as failed:
        states = [(pid, is_stopped(pid)) for pid in agents["pids"]]
        if any(stopped for _pid, stopped in states):
            raise Failed("the laptop left its agent stopped (SIGSTOP) after a 3 s nap, and the turn never ends: "
                         "agent (pid, stopped) %s; the laptop says %r [%s]"
                         % (states, short(w.log_of("laptop").strip().splitlines()[-1], 80), w.brief()))
        raise failed
    v = w.view()
    w.expect(v["holder"] == LAPTOP and v["epoch"] == before["epoch"], "the laptop did not keep the chat through a 3 s nap")
    w.expect(w.ended_by() == [LAPTOP], "turns ended on %s" % w.ended_by())
    w.expect(not os.path.exists(os.path.join(w.work, "c1")), "the machine took the chat")
    w.until("the laptop is idle with its copy stored", lambda: w.settled_on(LAPTOP))
    w.summary = "kept the chat at epoch %d; the turn finished on the laptop" % v["epoch"]


def wake_stops_agent(w):
    """(extra) The laptop wakes after the machine took its chat: its own agent, which wakes with
    it, is stopped at once (the README says within a quarter second) and what it wrote is kept
    aside."""
    w.start_store()
    w.start_machine()
    frozen, _first = takeover_mid_turn(w, slow=60)  # the laptop's own tool is still running when it wakes
    agents = w.track_agents(w.laptop)
    w.step("-- the lid opens --")
    woke_at = time.time()
    w.thaw(frozen)
    w.until("the laptop's agent is stopped or gone", lambda: agents["stopped_at"] and time.time() - woke_at > 0.3, 20, 0.02)
    ran = max(0.0, (agents["last_running"] or woke_at) - woke_at)
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop has the machine's files", lambda: w.in_proj("step2.txt") == "finished on cloud\n")
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    w.expect(w.ended_by() == [VM_HOLDER], "turns ended on %s" % w.ended_by())
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.flag(ran <= 1.0, "the laptop's own agent ran for %.2fs after the lid opened, with the chat on the machine "
           "(the README says it is stopped within a quarter second)" % ran)
    w.summary = "the woken agent ran for %.2fs before the laptop stopped it" % ran


def wake_while_cloud_works(w, slow="3"):
    """(extra) The lid opens while the machine is in the middle of a turn: the turn ends on the
    machine, once, and the chat comes home after it with everything the machine did."""
    w.start_store()
    w.start_machine()
    frozen, _first = takeover_mid_turn(w)
    second = "the second job slow:%s" % slow
    sent = w.phone(["send", "c1", second])
    w.expect(sent.returncode == 0, "auto send failed: %s" % short(sent.stdout + sent.stderr))
    w.step("-- the lid opens while the machine works --")
    w.thaw(frozen)
    w.until("the machine's turn ended, or the chat left the machine",
            lambda: w.ended(second) or (w.view()["holder"] != VM_HOLDER and w.prompt_id(second)), 40, 0.05)
    ends = w.ended(second)
    events = w.events()
    done_on_machine = [e for e in events if e["kind"] == "text" and e["by"] == VM_HOLDER
                       and "The long job finished on cloud" in e.get("text", "")]
    lost = "" if done_on_machine else (
        ": the machine's own log shows the job finishing there (%r), but the store never got those events"
        % short([line for line in w.log_of("cloud").splitlines() if "done on" in line or "finished" in line][-2:], 150))
    w.expect(ends or w.view()["holder"] == VM_HOLDER,
             "the store gave the chat to the laptop in the middle of the machine's turn, before the turn's end was "
             "stored%s" % lost)
    w.until("the chat is back on the laptop", lambda: w.view()["holder"] == LAPTOP)
    w.until("the laptop stored a copy of its own", w.home_with_own_copy)
    w.holds("the job ran once", lambda: len(w.ended(second)) == 1 and len(w.kinds("turn_start")) == 2, 1.5 * LEASE)
    w.expect(w.ended_by() == [VM_HOLDER, VM_HOLDER], "turns ended on %s" % w.ended_by())
    w.expect(w.in_proj("step2.txt") == "finished on cloud\n" and w.in_proj("step1.txt") == "started on cloud\n",
             "the laptop's folder is not the machine's: step1.txt %r, step2.txt %r" % (w.in_proj("step1.txt"), w.in_proj("step2.txt")))
    w.until("the laptop's record of the chat is the store's", w.laptop_has_the_log, 10)
    w.summary = "the turn ended on the machine with the laptop awake; home at epoch %d" % w.view()["epoch"]


def off_from_phone_awake(w):
    """(extra) `auto off c1` from the phone with the laptop awake and holding the chat: the
    laptop says so and goes on running the chat itself."""
    w.start_store()
    w.start_machine()
    first_note_at_home(w)
    off = w.phone(["off", "c1"])
    w.expect(off.returncode == 0 and "Auto is off for c1" in off.stdout, "auto off said: %s" % short(off.stdout + off.stderr))
    w.until("the laptop says Auto is off", lambda: "Auto is off for this chat" in w.log_of("laptop"), 15)
    second = "a note after off"
    w.type(second)
    w.until("a prompt runs on the laptop with Auto off", lambda: "laptop: " + second in w.in_proj("notes.txt"), 20)
    frozen = w.freeze(w.laptop)
    w.holds("the frozen laptop does not lose the chat to the machine",
            lambda: w.view()["state"] == "off" and not w.view()["holder"].startswith("vm:"), 2 * LEASE)
    w.thaw(frozen)
    third = "one more after waking"
    w.type(third)
    w.until("a prompt runs on the laptop after it woke", lambda: "laptop: " + third in w.in_proj("notes.txt"), 20)
    w.expect(not os.path.exists(os.path.join(w.work, "c1")), "the machine took the chat")
    w.summary = "Auto off from the phone; the laptop ran two more prompts itself"


SCENARIOS = [no_network, quit_mid_turn, idle_laptop_closes, keep_in_cloud, auto_off, phone_new,
             store_restart, machine_restart, two_messages_queue,
             # Not in the list of nine: found while reading the code.
             silent_network, store_down_past_lease, off_then_reopen, off_from_phone_while_asleep,
             phone_chat_comes_to_laptop, quit_and_reopen_at_once, phone_says_no_clearly,
             short_nap_mid_turn, wake_stops_agent, wake_while_cloud_works, off_from_phone_awake]
GATE_PORT = 17760  # silent_network's relay; the stores use 17740..17759


# ---- the runner ----

def run_one(fn, verbose=False):
    port = FIRST_PORT + SCENARIOS.index(fn)
    w = World(fn.__name__, port, verbose)
    began = time.time()
    reason, finished = None, False
    try:
        try:
            fn(w)
            finished = True
            problems = w.invariants(settled=True)
            if problems:
                reason = "invariant: " + "; ".join(problems[:3])
            if w.flags:
                reason = "; ".join(w.flags[:2]) + (" | also, " + reason if reason else " | the rest of the scenario passed")
        except Failed as failed:
            reason = str(failed)
            if w.flags:
                reason = "; ".join(w.flags[:2]) + " | and then: " + reason
        except AssertionError as failed:
            reason = "assert: %s" % failed
        except (Offline, Refused) as error:
            reason = "the store: %r" % error
        except Exception as error:  # a bug in the scenario itself is a failure too
            import traceback
            w.step(traceback.format_exc())
            reason = "error in the scenario: %r" % error
        if reason and not finished:
            try:
                problems = w.invariants(settled=False)
            except Exception as error:
                problems = ["the invariants could not be checked: %r" % error]
            if problems:
                reason += " | also, invariant: " + "; ".join(problems[:2])
        if reason:
            w.step("FAILED: " + reason)
            try:
                with open(os.path.join(w.root, "final.json"), "w") as f:
                    json.dump({"status": w.c.status(), "chats": w.c.chats()}, f, indent=1)
            except Exception:
                pass
    finally:
        left = w.cleanup()
    took = time.time() - began
    if left and not reason:
        reason = "cleanup: " + "; ".join(left)
    if reason:
        print("FAIL  %-20s %5.1fs  %s" % (fn.__name__, took, reason), flush=True)
        print("      logs kept in %s" % w.root, flush=True)
        return False
    print("PASS  %-20s %5.1fs  %s" % (fn.__name__, took, w.summary), flush=True)
    if os.environ.get("AUTO_TEST_KEEP"):
        print("      logs kept in %s" % w.root, flush=True)
    else:
        shutil.rmtree(w.root, ignore_errors=True)
    return True


def run_parallel(names, jobs):
    """Each scenario as a process of its own, `jobs` at a time."""
    todo, running, results = list(names), [], {}
    try:
        while todo or running:
            while todo and len(running) < jobs:
                name = todo.pop(0)
                running.append((name, subprocess.Popen([sys.executable, os.path.realpath(__file__), name],
                                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)))
            for item in list(running):
                name, proc = item
                if proc.poll() is not None:
                    out = proc.stdout.read()
                    sys.stdout.write("".join(line for line in out.splitlines(True)
                                             if line.strip() and "of 1 passed" not in line))
                    sys.stdout.flush()
                    results[name] = proc.returncode == 0
                    running.remove(item)
            time.sleep(0.2)
    finally:
        # Stopped early: each child kills its own processes on SIGTERM.
        for _name, proc in running:
            proc.terminate()
        for _name, proc in running:
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()
    return [results.get(name, False) for name in names]


def main(argv):
    def stop(_signum, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, stop)
    by_name = dict((fn.__name__, fn) for fn in SCENARIOS)
    verbose, jobs, names = False, 1, []
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == "--list":
            for fn in SCENARIOS:
                print("%-20s %s" % (fn.__name__, " ".join((fn.__doc__ or "").split())))
            return 0
        if arg == "-v":
            verbose = True
        elif arg == "-j":
            jobs = int(args.pop(0))
        elif arg in by_name:
            names.append(arg)
        else:
            sys.exit("no scenario %r; there are: %s" % (arg, ", ".join(by_name)))
    names = names or [fn.__name__ for fn in SCENARIOS]
    if jobs > 1 and len(names) > 1 and len(set(names)) == len(names):  # a scenario has one port
        results = run_parallel(names, jobs)
    else:
        results = [run_one(by_name[name], verbose) for name in names]
    print("\n%d of %d passed" % (sum(results), len(results)), flush=True)
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
