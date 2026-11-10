#!/usr/bin/env python3
"""busy_holder: the bench load arm `oversub` (FABLE-COMMON.md "Load arm rule", coordinator order f24, 2026-11-10).

Lawrence's Mac runs all day at a load average of about 250 on 18 cores: about 14 runnable CPU-bound threads per
core (claude, codex, node, bun, cargo, rustc), all at the default priority. A bench "load" arm with a host load
under 15 is a quiet machine next to that. This tool puts N CPU-bound threads at the DEFAULT priority and QoS beside
the app under test, for a short time, and takes them away again. It is the ONE busy loop of the bench owners.

  busy_holder.py start --owner TASK --watch-pid $$ [--threads 250] [--procs 25] [--max-seconds 240]
        prints the holder's PID on stdout (one line) and a JSON line on stderr; the load runs when it returns.
  busy_holder.py stop PID          stops that holder (only a PID that is a busy_holder with a state file and its
                                   token on its command line), waits until it is gone, prints its summary as JSON.
  busy_holder.py status [PID]      the holder's threads as `ps -M` shows them (count, running, priority, CPU);
                                   with no PID: every live holder of this user (`live 0` = nothing is left).
  busy_holder.py cooldown [--below 8] [--max-seconds 420]
        waits until the 1-minute load average is below the limit (the hold keeps gui.lock until then).
  busy_holder.py selftest          proves the safety rules below with 4 threads for at most 10 s each, in a temp
                                   folder that stands in for ~/perf-lead (about 30 s; prints SELFTEST PASS|FAIL).
  busy_holder.py probe [--n 60] [--work-ms 2] [--classes ...] [--label TEXT]
        the scheduling delay that ONE thread of each QoS class gets now (timer wake delay, the wall time of a short
        CPU burst and of a long one, a socket round trip to a server process of that class). Run it quiet and under
        `start`: the difference is the time a thread of that class waits for a core. Needs no root.

Shape. `--threads N` is the count of busy threads; `--procs P` spreads them over P processes (default 1: one
process with N threads). The macOS scheduler shares a QoS band between thread groups (about one per process) before
it shares it between threads, so 1 process with 250 threads and 250 processes with 1 thread are different loads;
his Mac has many processes. Say the shape next to each number: threads, processes, cores, threads per core, the
1-minute load at the start and at the end (the summary of `stop` has all of them).

What this load does NOT copy from his Mac: disk reads and writes, memory pressure, page cache traffic, process
starts and exits, timers and wakeups of real programs, GPU work. It is CPU run-queue pressure only.

SAFETY (each one is enforced here, not left to the caller):
  1. It ends itself after --max-seconds (default 240, hard limit 600) whatever happens: the supervisor's deadline,
     a kernel alarm in the supervisor and in every worker process, a CPU-time limit (RLIMIT_CPU) in every worker,
     and every worker thread reads the deadline between two short pieces of work.
  2. It ends when the process that started it is gone (--watch-pid, default: the caller's parent). A worker ends
     when its supervisor is gone.
  3. It runs only on a bench host and only inside the caller's own gui.lock hold: the marker file
     ~/perf-lead/tools/GUI-HOST must exist (aws-m4pro-7 and -8 have it; no build host and no laptop has it), and
     ~/perf-lead/gui.lock/owner must start with --owner. The supervisor reads the lock each second and ends the
     load when the lock is gone or belongs to another owner.
  4. `stop` signals only a PID that it can prove is a busy_holder supervisor (state file + token on the command
     line); workers are the supervisor's own children.
  5. It refuses to start at a changed nice value (nice != 0): the load must be what a program started from a
     terminal is. The workers are new threads at the default QoS class.

PRIORITY TRAP (measured 2026-11-10, macOS 26.7): a process that ssh started has a QoS ceiling of utility. Each of
its threads runs at scheduler priority 20 for every QoS class (background: 4), and a zsh login shell starts a `&`
job at nice 5. On a person's Mac a default thread has 31 and the app's main thread 46 or 47. So start the load,
the app and the bench driver through LaunchServices (`open -W -n -g <a background-only bundle whose executable is a
copy of /bin/bash> --args job.sh`; `open` does not pass the environment: write it to a file). `start` and `status`
print the scheduler priority of the supervisor (`sched_pri`): 31 is right, 20 means the ssh ceiling.
The caller's duty: stop it before the job ends, run `cooldown` inside the same hold, then check `status` = live 0.

A bench tool: never a CI gate, job, step or perf-gate row. Python 3.9 standard library only.
"""
from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
import random
import resource
import signal
import socket
import subprocess
import sys
import threading
import time
import uuid

HARD_LIMIT_S = 600
DEFAULT_MAX_S = 240
MAX_THREADS = 512
TEST_MAX_THREADS = 8
TEST_MAX_S = 30
PIECE_MS = 4.0  # one piece of work between two reads of the deadline, on a quiet core

QOS = {"user-interactive": 0x21, "user-initiated": 0x19, "default": 0x15, "utility": 0x11, "background": 0x09}
QOS_NAME = {v: k for k, v in QOS.items()}
QOS_NAME[0] = "unspecified"


def perf_lead_root() -> str:
    """~/perf-lead, or the test folder (BUSY_HOLDER_TEST_ROOT: only for a load of at most 8 threads and 30 s)."""
    return os.environ.get("BUSY_HOLDER_TEST_ROOT") or os.path.join(os.path.expanduser("~"), "perf-lead")


def state_dir() -> str:
    d = os.path.join(os.environ.get("BUSY_HOLDER_STATE_DIR") or "/tmp", "busy-holder-%d" % os.getuid())
    os.makedirs(d, mode=0o700, exist_ok=True)
    return d


def state_path(pid: int) -> str:
    return os.path.join(state_dir(), "%d.json" % pid)


def read_state(pid: int):
    try:
        with open(state_path(pid)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_state(pid: int, state: dict) -> None:
    tmp = state_path(pid) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, state_path(pid))


def load1() -> float:
    return round(os.getloadavg()[0], 2)


def lock_refusal(owner: str):
    """None when this host is a bench host and gui.lock is the owner's; else the reason."""
    root = perf_lead_root()
    if not os.path.exists(os.path.join(root, "tools", "GUI-HOST")):
        return "not a bench host: %s/tools/GUI-HOST does not exist (never a build host, never a laptop)" % root
    try:
        with open(os.path.join(root, "gui.lock", "owner")) as f:
            words = f.read().split()
    except OSError:
        return "no gui.lock hold: %s/gui.lock/owner does not exist" % root
    if not words or words[0] != owner:
        return "gui.lock belongs to %r, not to %r" % (words[0] if words else "", owner)
    return None


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def command_of(pid: int) -> str:
    try:
        return subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True,
                              timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def is_ours(pid: int, token: str) -> bool:
    cmd = command_of(pid)
    return bool(token) and "busy_holder" in cmd and token in cmd


# ---- QoS (macOS; on another system every call is a no-op and the class reads "unspecified") ----

def _libsystem():
    if sys.platform != "darwin":
        return None
    try:
        return ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib", use_errno=True)
    except OSError:
        return None


def sched_pri(pid: int):
    """The scheduler priority of the process's first thread (`ps -o pri=`): 31 is a default thread of a program that
    a person started; 20 is the ceiling of a process that ssh started. None when ps does not say."""
    try:
        out = subprocess.run(["ps", "-o", "pri=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout.strip()
        return int(out)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def current_qos() -> str:
    lib = _libsystem()
    if lib is None:
        return "unspecified"
    lib.pthread_self.restype = ctypes.c_void_p
    cls, rel = ctypes.c_uint(0), ctypes.c_int(0)
    if lib.pthread_get_qos_class_np(ctypes.c_void_p(lib.pthread_self()), ctypes.byref(cls), ctypes.byref(rel)) != 0:
        return "unknown"
    return QOS_NAME.get(cls.value, hex(cls.value))


def set_qos(name: str) -> bool:
    """Set the calling thread's QoS class. False when the system has no QoS or refuses."""
    lib = _libsystem()
    if lib is None or name not in QOS:
        return False
    return lib.pthread_set_qos_class_self_np(ctypes.c_uint(QOS[name]), ctypes.c_int(0)) == 0


# ---- the work: PBKDF2 runs in C with the interpreter lock released, so N threads are N runnable threads ----

def piece(iters: int) -> None:
    hashlib.pbkdf2_hmac("sha256", b"busy_holder", b"0123456789abcdef", iters)


def calibrate(ms: float) -> int:
    """Iterations of one piece that take about `ms` on this core now (best of 5, so a busy host does not shrink it)."""
    probe_iters = 2000
    best = min(_timed(piece, probe_iters) for _ in range(5))
    return max(200, int(probe_iters * (ms / 1000.0) / max(best, 1e-6)))


def _timed(fn, *a) -> float:
    t0 = time.perf_counter()
    fn(*a)
    return time.perf_counter() - t0


def threads_run_in_parallel(iters: int) -> bool:
    """True when two threads of work take about the time of one (the hash releases the interpreter lock)."""
    if (os.cpu_count() or 1) < 2:
        return True
    reps = 8
    one = min(_timed(lambda: [piece(iters) for _ in range(reps)]) for _ in range(3))

    def both():
        ts = [threading.Thread(target=lambda: [piece(iters) for _ in range(reps)]) for _ in range(2)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
    two = min(_timed(both) for _ in range(3))
    return two < one * 1.6


def parallel_checked(iters: int) -> bool:
    """The check needs free cores: 3 tries; on a host that is already busy (a second start in one hold) it is
    skipped, because the first start of the hold made it on the quiet host."""
    if load1() > (os.cpu_count() or 1) / 2.0:
        return True
    return any(threads_run_in_parallel(iters) for _ in range(3))


# ---- worker process ----

def worker_main(threads: int, deadline: float, iters: int, supervisor: int) -> None:
    left = max(1, int(deadline - time.monotonic()) + 3)
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    signal.alarm(left)  # kernel alarm: the process dies at the limit also when Python is stuck
    cpu = left * max(1, min(threads, os.cpu_count() or 1)) + 5
    try:
        resource.setrlimit(resource.RLIMIT_CPU, (cpu, cpu))
    except (ValueError, OSError):
        pass

    def burn():
        while time.monotonic() < deadline and os.getppid() == supervisor:
            piece(iters)

    for _ in range(threads - 1):
        threading.Thread(target=burn, daemon=True).start()
    burn()
    os._exit(0)


# ---- supervisor ----

def supervise(args) -> int:
    me = os.getpid()
    max_s = min(float(args.max_seconds), HARD_LIMIT_S)
    t_start = time.monotonic()
    deadline = t_start + max_s
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(int(max_s) + 10)  # kernel alarm on the supervisor; its workers end when it is gone
    stop = {"reason": None}
    signal.signal(signal.SIGTERM, lambda *_: stop.__setitem__("reason", "stop"))
    signal.signal(signal.SIGINT, lambda *_: stop.__setitem__("reason", "stop"))

    per = [args.threads // args.procs + (1 if i < args.threads % args.procs else 0) for i in range(args.procs)]
    state = {"pid": me, "token": args.token, "owner": args.owner, "watch_pid": args.watch_pid,
             "threads": args.threads, "procs": args.procs, "cores": os.cpu_count(),
             "threads_per_core": round(args.threads / float(os.cpu_count() or 1), 1),
             "max_seconds": max_s, "piece_iters": args.iters, "qos": current_qos(), "nice": os.nice(0),
             "sched_pri": sched_pri(me),
             "load1_start": load1(), "started_utc": time.strftime("%H:%M:%SZ", time.gmtime()),
             "workers": [], "ready": False, "ended": None}
    workers = []
    for n in per:
        pid = os.fork()
        if pid == 0:
            try:
                worker_main(n, deadline, args.iters, me)
            finally:
                os._exit(0)
        workers.append(pid)
    state["workers"] = workers
    set_qos("user-initiated")  # the safety loop must run on time beside its own load; the workers keep the default
    state["ready"] = True
    write_state(me, state)

    reason, last_lock, cpu_s, live = None, 0.0, 0.0, set(workers)
    while reason is None:
        time.sleep(0.1)
        now = time.monotonic()
        for pid in list(live):
            try:
                done, _, ru = os.wait4(pid, os.WNOHANG)
            except ChildProcessError:
                done, ru = pid, None
            if done:
                live.discard(pid)
                if ru is not None:
                    cpu_s += ru.ru_utime + ru.ru_stime
        if stop["reason"]:
            reason = stop["reason"]
        elif now >= deadline:
            reason = "max-seconds"
        elif not alive(args.watch_pid):
            reason = "parent gone (pid %d)" % args.watch_pid
        elif not live:
            reason = "workers ended"
        elif now - last_lock >= 1.0:
            last_lock = now
            refusal = lock_refusal(args.owner)
            if refusal:
                reason = "lock lost: " + refusal
    for pid in live:
        try:
            os.kill(pid, signal.SIGKILL)  # our own children, by exact PID
        except ProcessLookupError:
            pass
    for pid in live:
        try:
            _, _, ru = os.wait4(pid, 0)
            cpu_s += ru.ru_utime + ru.ru_stime
        except ChildProcessError:
            pass
    wall = time.monotonic() - t_start
    cores_used = min(args.threads, os.cpu_count() or 1)
    state.update({"ended": reason, "seconds": round(wall, 2), "worker_cpu_seconds": round(cpu_s, 1),
                  "cores_filled": round(cpu_s / wall, 2) if wall > 0 else 0.0,
                  "fill_ratio": round(cpu_s / (wall * cores_used), 3) if wall > 0 else 0.0,
                  "load1_end": load1(), "ended_utc": time.strftime("%H:%M:%SZ", time.gmtime())})
    write_state(me, state)
    return 0


# ---- commands ----

def cmd_start(args) -> int:
    test_root = bool(os.environ.get("BUSY_HOLDER_TEST_ROOT"))
    if args.threads < 1 or args.threads > MAX_THREADS:
        return fail("--threads must be 1..%d" % MAX_THREADS)
    if args.procs < 1 or args.procs > args.threads:
        return fail("--procs must be 1..threads")
    if args.max_seconds < 1 or args.max_seconds > HARD_LIMIT_S:
        return fail("--max-seconds must be 1..%d (hard limit)" % HARD_LIMIT_S)
    if test_root and (args.threads > TEST_MAX_THREADS or args.max_seconds > TEST_MAX_S):
        return fail("BUSY_HOLDER_TEST_ROOT allows at most %d threads and %d s" % (TEST_MAX_THREADS, TEST_MAX_S))
    if not test_root and sys.platform != "darwin":
        return fail("a bench host is a Mac")
    owner = args.owner or os.environ.get("GUI_VD_OWNER") or ""
    if not owner:
        return fail("--owner TASK (or GUI_VD_OWNER) is required: the name in gui.lock/owner")
    refusal = lock_refusal(owner)
    if refusal:
        return fail("refused: " + refusal)
    qos, nice = current_qos(), os.nice(0)
    if nice != 0:
        return fail("refused: start it at nice 0 (it is %d; a zsh login shell gives a `&` job nice 5: start from bash); "
                    "no nice, no taskpolicy" % nice)
    watch = args.watch_pid or os.getppid()
    if not alive(watch):
        return fail("the watched process %d is not alive" % watch)
    iters = calibrate(PIECE_MS)
    if args.threads > args.procs and not parallel_checked(iters):
        return fail("this Python does not run two hash threads in parallel: use --procs equal to --threads")
    token = uuid.uuid4().hex
    log = open(os.path.join(state_dir(), "supervisor.log"), "a")
    sup = subprocess.Popen(
        [sys.executable, os.path.abspath(__file__), "_supervise", "--token", token, "--owner", owner,
         "--watch-pid", str(watch), "--threads", str(args.threads), "--procs", str(args.procs),
         "--max-seconds", str(args.max_seconds), "--iters", str(iters)],
        stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True)
    t0 = time.monotonic()
    state = None
    while time.monotonic() - t0 < 20:
        state = read_state(sup.pid)
        if state and state.get("token") == token and state.get("ready"):
            break
        if sup.poll() is not None:
            return fail("the supervisor ended at once (exit %s); see %s" % (sup.returncode, log.name))
        time.sleep(0.05)
    else:
        sup.terminate()
        return fail("the supervisor was not ready in 20 s; stopped")
    sys.stderr.write(json.dumps({k: state[k] for k in (
        "pid", "owner", "watch_pid", "threads", "procs", "cores", "threads_per_core", "max_seconds", "qos", "nice",
        "sched_pri", "load1_start", "started_utc") if k in state}) + "\n")
    print(sup.pid)
    return 0


def cmd_stop(args) -> int:
    state = read_state(args.pid)
    if not state or state.get("pid") != args.pid:
        return fail("PID %d has no busy_holder state file: not stopped" % args.pid)
    token = state.get("token", "")
    if alive(args.pid):
        if not is_ours(args.pid, token):
            return fail("PID %d is alive but is not this busy_holder (token not on its command line): not stopped"
                        % args.pid)
        os.kill(args.pid, signal.SIGTERM)
        t0 = time.monotonic()
        while alive(args.pid) and time.monotonic() - t0 < 15:
            time.sleep(0.05)
        if alive(args.pid) and is_ours(args.pid, token):
            os.kill(args.pid, signal.SIGKILL)
            time.sleep(0.5)
    left = [p for p in state.get("workers", []) if alive(p) and is_ours(p, token)]
    t0 = time.monotonic()
    while left and time.monotonic() - t0 < 5:  # a worker ends by itself when its supervisor is gone
        time.sleep(0.1)
        left = [p for p in left if alive(p) and is_ours(p, token)]
    for p in left:
        os.kill(p, signal.SIGKILL)
    final = read_state(args.pid) or state
    final["left_after_stop"] = len([p for p in final.get("workers", []) + [args.pid] if alive(p) and is_ours(p, token)])
    final.pop("token", None)
    print(json.dumps(final))
    return 0 if final["left_after_stop"] == 0 else 1


def ps_threads(pid: int) -> dict:
    """`ps -M` of one process (macOS): one line per thread with STAT and PRI."""
    try:
        out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    lines = out.splitlines()
    if len(lines) < 2:
        return {}
    head = lines[0].split()
    try:
        i_cpu, i_stat, i_pri = head.index("%CPU"), head.index("STAT"), head.index("PRI")
    except ValueError:
        return {}
    # A process's first line has every column; its next threads print only PID %CPU STAT PRI STIME UTIME.
    shift = head.index("PID")
    tt = 1 if "TT" in head[:i_cpu] else 0
    threads = running = 0
    cpu = 0.0
    pri: dict = {}
    for n, line in enumerate(lines[1:]):
        w = line.split()
        off = 0 if (n == 0 or len(w) >= len(head)) else shift + tt
        try:
            c, s, p = float(w[i_cpu - off]), w[i_stat - off], w[i_pri - off]
        except (IndexError, ValueError):
            continue
        threads += 1
        cpu += c
        running += 1 if s.startswith("R") else 0
        pri[p] = pri.get(p, 0) + 1
    return {"threads": threads, "running": running, "cpu_percent": round(cpu, 1), "pri": pri}


def live_holders() -> list:
    out = []
    for name in sorted(os.listdir(state_dir())):
        if not name.endswith(".json"):
            continue
        try:
            pid = int(name[:-5])
        except ValueError:
            continue
        st = read_state(pid)
        if not st:
            continue
        pids = [p for p in [pid] + st.get("workers", []) if alive(p) and is_ours(p, st.get("token", ""))]
        if pids:
            out.append({"pid": pid, "owner": st.get("owner"), "live_pids": pids})
    return out


def cmd_status(args) -> int:
    if args.pid is None:
        live = live_holders()
        print("live %d" % len(live))
        for h in live:
            print(json.dumps(h))
        return 0
    state = read_state(args.pid)
    if not state:
        return fail("PID %d has no busy_holder state file" % args.pid)
    token = state.pop("token", "")
    total = {"threads": 0, "running": 0, "cpu_percent": 0.0, "pri": {}}
    for p in state.get("workers", []):
        if not (alive(p) and is_ours(p, token)):
            continue
        t = ps_threads(p)
        for k in ("threads", "running", "cpu_percent"):
            total[k] += t.get(k, 0)
        for k, v in t.get("pri", {}).items():
            total["pri"][k] = total["pri"].get(k, 0) + v
    total["cpu_percent"] = round(total["cpu_percent"], 1)
    state["now"] = {"supervisor_alive": alive(args.pid) and is_ours(args.pid, token), "workers_ps": total,
                    "load1": load1()}
    print(json.dumps(state))
    return 0


def cmd_cooldown(args) -> int:
    t0 = time.monotonic()
    first = load1()
    while load1() >= args.below:
        if time.monotonic() - t0 >= args.max_seconds:
            print(json.dumps({"cooldown": "timeout", "below": args.below, "load1_first": first, "load1": load1(),
                              "waited_s": round(time.monotonic() - t0, 1)}))
            return 1
        time.sleep(2)
    print(json.dumps({"cooldown": "ok", "below": args.below, "load1_first": first, "load1": load1(),
                      "waited_s": round(time.monotonic() - t0, 1)}))
    return 0


def dist(xs: list) -> dict:
    if not xs:
        return {"n": 0}
    s = sorted(xs)

    def q(p):
        return round(s[min(len(s) - 1, int(p * len(s)))], 3)
    return {"n": len(s), "p50": q(0.50), "p95": q(0.95), "p99": q(0.99), "max": round(s[-1], 3)}


def probe_class(name: str, n: int, iters: int, budget_s: float, long_pieces: int = 12) -> dict:
    """One QoS class: timer wake delay, the wall time of one piece of work (burst) and of `long_pieces` pieces in a
    row (long burst: a thread that computes for longer loses its wake-up credit), and a socket round trip to a
    server process of that class (the client is user-interactive, as the app's main thread is). All in ms."""
    res: dict = {"class": name}
    rng = random.Random(7)

    def in_class(fn):
        box: dict = {}

        def run():
            box["set"] = True if name == "as-started" else set_qos(name)
            box["qos"] = current_qos()
            fn(box)
        t = threading.Thread(target=run)
        t.start()
        t.join()
        return box

    def wake(box):
        out, end = [], time.monotonic() + budget_s
        for _ in range(n):
            d = rng.uniform(0.008, 0.016)
            t0 = time.perf_counter()
            time.sleep(d)
            out.append((time.perf_counter() - t0 - d) * 1000.0)
            if time.monotonic() > end:
                break
        box["out"] = out

    def burst(box):
        out, end = [], time.monotonic() + budget_s
        for _ in range(n):
            time.sleep(rng.uniform(0.008, 0.016))  # mostly asleep, as a request thread is
            out.append(_timed(piece, iters) * 1000.0)
            if time.monotonic() > end:
                break
        box["out"] = out

    def long_burst(box):
        out, end = [], time.monotonic() + budget_s
        for _ in range(max(4, n // 4)):
            time.sleep(rng.uniform(0.008, 0.016))
            out.append(_timed(lambda: [piece(iters) for _ in range(long_pieces)]) * 1000.0)
            if time.monotonic() > end:
                break
        box["out"] = out

    w = in_class(wake)
    res["qos_read"], res["qos_set"] = w.get("qos"), w.get("set")
    res["wake_late_ms"] = dist(w.get("out", []))
    res["burst_wall_ms"] = dist(in_class(burst).get("out", []))
    res["long_burst_wall_ms"] = dist(in_class(long_burst).get("out", []))

    a, b = socket.socketpair()
    pid = os.fork()
    if pid == 0:  # the server process: its own thread group, as a daemon is
        try:
            a.close()
            signal.alarm(int(budget_s) + 30)
            if name != "as-started":
                set_qos(name)
            while True:
                got = b.recv(1)
                if not got or os.getppid() == 1:
                    break
                piece(iters)
                b.send(b"y")
        finally:
            os._exit(0)
    b.close()

    def rtt(box):
        out, end = [], time.monotonic() + budget_s
        set_qos("user-interactive")
        a.settimeout(budget_s + 20)
        for _ in range(n):
            time.sleep(rng.uniform(0.008, 0.016))
            t0 = time.perf_counter()
            try:
                a.send(b"x")
                if not a.recv(1):
                    break
            except OSError:
                break
            out.append((time.perf_counter() - t0) * 1000.0)
            if time.monotonic() > end:
                break
        box["out"] = out

    box: dict = {}
    t = threading.Thread(target=rtt, args=(box,))
    t.start()
    t.join()
    a.close()
    try:
        os.kill(pid, signal.SIGKILL)  # our own child
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    res["rtt_ms"] = dist(box.get("out", []))
    return res


def cmd_probe(args) -> int:
    iters = args.iters or calibrate(args.work_ms)
    classes = [c for c in args.classes.split(",") if c == "as-started" or c in QOS]
    out = {"probe": args.label, "host": os.uname().nodename, "cores": os.cpu_count(), "work_ms_quiet": args.work_ms,
           "long_burst_ms_quiet": args.work_ms * args.long_pieces,
           "piece_iters": iters, "n": args.n, "load1_start": load1(), "utc": time.strftime("%H:%M:%SZ", time.gmtime()),
           "nice": os.nice(0), "classes": []}
    for c in classes:
        out["classes"].append(probe_class(c, args.n, iters, args.class_seconds, args.long_pieces))
    out["load1_end"] = load1()
    print(json.dumps(out))
    return 0


def cmd_selftest(args) -> int:
    """The safety rules, proved with a real load of 4 threads for at most 10 s each (a temp folder stands in for
    ~/perf-lead; the real gui.lock is not read or changed). Prints one line per check and `SELFTEST PASS|FAIL`."""
    import shutil
    import tempfile
    root = tempfile.mkdtemp(prefix="busy-holder-selftest-")
    env = dict(os.environ, BUSY_HOLDER_TEST_ROOT=root, BUSY_HOLDER_STATE_DIR=root)
    me = [sys.executable, os.path.abspath(__file__)]
    lock = os.path.join(root, "gui.lock")
    results = []

    def run(*a, timeout=60):
        r = subprocess.run(me + list(a), env=env, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        return r.returncode, r.stdout.strip(), r.stderr.strip()

    def check(name, ok, detail=""):
        results.append(ok)
        print("%s %s %s" % ("ok  " if ok else "FAIL", name, detail))

    def state_of(pid):
        try:
            with open(os.path.join(root, "busy-holder-%d" % os.getuid(), "%d.json" % pid)) as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def gone(pid, st, limit):
        t0 = time.monotonic()
        pids = [pid] + st.get("workers", [])
        while time.monotonic() - t0 < limit:
            if not any(alive(p) and "busy_holder" in command_of(p) for p in pids):
                return round(time.monotonic() - t0, 1)
            time.sleep(0.2)
        return None

    def take_lock(owner):
        os.makedirs(lock, exist_ok=True)
        with open(os.path.join(lock, "owner"), "w") as f:
            f.write("%s selftest pid %d\n" % (owner, os.getpid()))

    try:
        rc, out, err = run("start", "--owner", "me", "--threads", "4", "--max-seconds", "10")
        check("refuses a host with no GUI-HOST marker", rc == 2 and "not a bench host" in err, err)
        os.makedirs(os.path.join(root, "tools"))
        open(os.path.join(root, "tools", "GUI-HOST"), "w").close()
        rc, out, err = run("start", "--owner", "me", "--threads", "4", "--max-seconds", "10")
        check("refuses with no gui.lock hold", rc == 2 and "no gui.lock hold" in err, err)
        take_lock("other")
        rc, out, err = run("start", "--owner", "me", "--threads", "4", "--max-seconds", "10")
        check("refuses another owner's gui.lock", rc == 2 and "belongs to" in err, err)
        take_lock("me")
        rc, out, err = run("start", "--owner", "me", "--threads", "600", "--max-seconds", "10")
        check("refuses more threads than the limit", rc == 2, err)
        rc, out, err = run("start", "--owner", "me", "--threads", "4", "--max-seconds", "601")
        check("refuses more than the hard limit of 600 s", rc == 2 and "hard limit" in err, err)

        # 1. the self-limit: 4 threads, 10 s, nobody stops it
        t0 = time.monotonic()
        rc, out, err = run("start", "--owner", "me", "--threads", "4", "--max-seconds", "10",
                           "--watch-pid", str(os.getpid()))
        pid = int(out) if rc == 0 and out.isdigit() else 0
        check("start prints its PID", pid > 0, err)
        st = state_of(pid)
        time.sleep(2.0)
        rc2, sout, _ = run("status", str(pid))
        now = json.loads(sout).get("now", {}) if rc2 == 0 and sout else {}
        ps = now.get("workers_ps", {})
        if sys.platform == "darwin":
            check("4 busy threads, all at one default priority", ps.get("threads", 0) >= 4 and len(ps.get("pri", {})) >= 1,
                  json.dumps(ps))
        took = gone(pid, st, 25)
        end = state_of(pid)
        check("ends itself at --max-seconds with nobody to stop it", took is not None and end.get("ended") == "max-seconds"
              and 8 <= time.monotonic() - t0 <= 16, "ended=%r after %.1f s" % (end.get("ended"), time.monotonic() - t0))
        check("the load filled its cores", end.get("fill_ratio", 0) > 0.5 or (os.cpu_count() or 1) < 4,
              "fill_ratio %s cores_filled %s" % (end.get("fill_ratio"), end.get("cores_filled")))

        # 2. the parent is gone
        sleeper = subprocess.Popen(["sleep", "60"], stdin=subprocess.DEVNULL)
        rc, out, err = run("start", "--owner", "me", "--threads", "4", "--max-seconds", "10",
                           "--watch-pid", str(sleeper.pid))
        pid = int(out) if rc == 0 and out.isdigit() else 0
        st = state_of(pid)
        sleeper.kill()
        sleeper.wait()
        took = gone(pid, st, 6)
        check("ends when the watched parent is gone", pid > 0 and took is not None
              and str(state_of(pid).get("ended", "")).startswith("parent gone"), "gone after %s s" % took)

        # 3. the lock is lost
        rc, out, err = run("start", "--owner", "me", "--threads", "4", "--max-seconds", "10",
                           "--watch-pid", str(os.getpid()))
        pid = int(out) if rc == 0 and out.isdigit() else 0
        st = state_of(pid)
        take_lock("other")
        took = gone(pid, st, 6)
        check("ends when gui.lock goes to another owner", pid > 0 and took is not None
              and str(state_of(pid).get("ended", "")).startswith("lock lost"), "gone after %s s" % took)
        take_lock("me")

        # 4. stop: only its own PID
        sleeper = subprocess.Popen(["sleep", "30"], stdin=subprocess.DEVNULL)
        rc, out, err = run("stop", str(sleeper.pid))
        check("stop refuses a PID with no state file", rc == 2 and sleeper.poll() is None, err)
        rc, out, err = run("start", "--owner", "me", "--threads", "4", "--procs", "2", "--max-seconds", "10",
                           "--watch-pid", str(os.getpid()))
        pid = int(out) if rc == 0 and out.isdigit() else 0
        st = state_of(pid)
        # a state file that points at a process that is not a busy_holder: stop must not signal it
        fake = dict(st, pid=sleeper.pid)
        with open(os.path.join(root, "busy-holder-%d" % os.getuid(), "%d.json" % sleeper.pid), "w") as f:
            json.dump(fake, f)
        rc, out, err = run("stop", str(sleeper.pid))
        check("stop refuses a live PID that is not a busy_holder", rc == 2 and sleeper.poll() is None, err)
        sleeper.kill()
        sleeper.wait()
        rc, out, err = run("stop", str(pid))
        summary = json.loads(out) if out.startswith("{") else {}
        check("stop ends its own holder, 0 processes left", rc == 0 and summary.get("left_after_stop") == 0
              and summary.get("ended") == "stop" and gone(pid, st, 3) is not None, out[:200] or err)
        check("the summary has no token and has the shape", "token" not in summary and summary.get("procs") == 2
              and summary.get("threads") == 4 and "load1_start" in summary and "load1_end" in summary)
        rc, out, err = run("status")
        check("status with no PID: live 0", rc == 0 and out.splitlines()[:1] == ["live 0"], out)
    finally:
        shutil.rmtree(root, ignore_errors=True)
    ok = all(results)
    print("SELFTEST %s (%d checks) on %s, %s cores, Python %s" % ("PASS" if ok else "FAIL", len(results),
          os.uname().nodename, os.cpu_count(), sys.version.split()[0]))
    return 0 if ok else 1


def fail(msg: str) -> int:
    sys.stderr.write("busy_holder: %s\n" % msg)
    return 2


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="busy_holder.py", description="the bench load arm `oversub`")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("start")
    s.add_argument("--threads", type=int, default=250)
    s.add_argument("--procs", type=int, default=1)
    s.add_argument("--max-seconds", type=float, default=DEFAULT_MAX_S)
    s.add_argument("--owner", default="")
    s.add_argument("--watch-pid", type=int, default=0)
    s.set_defaults(fn=cmd_start)
    v = sub.add_parser("_supervise")
    for flag, typ in (("--token", str), ("--owner", str), ("--watch-pid", int), ("--threads", int), ("--procs", int),
                      ("--max-seconds", float), ("--iters", int)):
        v.add_argument(flag, type=typ, required=True)
    v.set_defaults(fn=supervise)
    t = sub.add_parser("stop")
    t.add_argument("pid", type=int)
    t.set_defaults(fn=cmd_stop)
    u = sub.add_parser("status")
    u.add_argument("pid", type=int, nargs="?")
    u.set_defaults(fn=cmd_status)
    c = sub.add_parser("cooldown")
    c.add_argument("--below", type=float, default=8.0)
    c.add_argument("--max-seconds", type=float, default=420.0)
    c.set_defaults(fn=cmd_cooldown)
    p = sub.add_parser("probe")
    p.add_argument("--n", type=int, default=60)
    p.add_argument("--work-ms", type=float, default=2.0)
    p.add_argument("--long-pieces", type=int, default=12, help="pieces of work in one long burst")
    p.add_argument("--iters", type=int, default=0, help="work iterations (take them from the quiet probe's JSON)")
    p.add_argument("--class-seconds", type=float, default=8.0, help="time limit of each of the 3 tests of a class")
    p.add_argument("--classes", default="user-interactive,user-initiated,default,as-started,utility,background")
    p.add_argument("--label", default="")
    p.set_defaults(fn=cmd_probe)
    sub.add_parser("selftest").set_defaults(fn=cmd_selftest)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
