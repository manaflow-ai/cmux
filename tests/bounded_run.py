#!/usr/bin/env python3
"""bounded_run: run a command with a deadline, and return only once it and every process it left are gone.

run(argv, timeout) starts a small reaper (this file, run as `python3 -I -S bounded_run.py --reap ...`), which starts
the command in a session of its own and tracks every process the command starts, a setsid one included. When the
command and all it left have exited, the run is over. At the deadline the reaper kills every one of them and waits
until each is gone. run() returns a Result whose state is one of:

  exited   the command exited, and nothing it started is left
  timeout  the deadline came first; everything was killed, and nothing is left
  unknown  the run could not be proven over: a process would not die, the process list could not be read, the
           reaper itself crashed or ran past its time, or the tracking could have missed one (below). A caller fails
           closed on it: it is never a pass.

How the reaper tracks the processes (Result.mode):

  subreaper  Linux. The reaper is the child subreaper (prctl(PR_SET_CHILD_SUBREAPER), checked by its return value and
             read back with PR_GET_CHILD_SUBREAPER), so every orphan of the run, a setsid one included, becomes its
             child: it waits until it has no child left, and at the deadline kills each process below it.
  cgroup     Linux, when prctl fails. The command starts in a cgroup v2 of its own, below the reaper's: no process
             leaves a cgroup by setsid or by losing its parent. The run is over when the cgroup is empty; cgroup.kill
             (or a kill per member) ends it.
  tracked    A set of processes the reaper keeps by scanning the process list (/proc, or ps by its absolute path),
             woken on macOS by kqueue on each fork and exit: the command's session and process group, every child of
             a process in the set, and every process whose environment holds this run's BOUNDED_RUN_TOKEN. Where the
             host has a subreaper or a cgroup, the run is held by it too (Result.mode "tracked+subreaper" or
             "tracked+cgroup"), so nothing escapes. With neither (macOS, or a Linux host with neither: "tracked"), it
             fails closed: unknown when any process left the command's session, when kqueue counted a fork whose child
             was never seen, or when a process of this user that launchd adopted since the command started is alive;
             on Linux, where nothing counts the forks, always unknown.

A guardian sits between run() and the reaper (`bounded_run.py --guard ...`). On Linux it is a child subreaper too,
and the reaper dies with it (PR_SET_PDEATHSIG). So when the reaper dies, every process of the run becomes the
guardian's, even one that left the session, cleared its environment and lost its parent before any scan
(`setsid env -i sleep 600 & kill -KILL $PPID`, LW#4477 review F1). The guardian kills each of its children until it
has none left, and reports the run unknown. "Nothing is left" holds only when waitpid says it has no child.

Without the guardian's proof (it died too, or it is not a subreaper, as on macOS), run() kills the run's cgroup and
every process that carries BOUNDED_RUN_TOKEN, is named in the reaper's interim status with a matching start time, or
is below one of those. The run is unknown, and Result.left holds [0] for what could not be accounted for, unless the
run's cgroup proves itself empty. An interim status past SEEN_MAX processes (seen_full) never counts as complete.

Every signal goes to a pid that cannot be someone else's: an unreaped child, or (Linux) a pidfd opened and then
checked against the start time the process was seen with (LW#4477 review F2). The command starts with every signal
at its default and none blocked, whatever the caller ignored or blocked.

No pipe is involved: stdin is DEVNULL or a file holding INPUT, and stdout and stderr go to files read back once the
reaper is done. A process the command left holding its stdout can never keep run() waiting (LW#4380 F1, the
communicate() that hung after a timeout kill while a setsid child held the pipe).

The source is teamleaderleo/leo-workspace tools/bounded_run.py: change it there, and only there. manaflow-ai/cmuxterm-hq
tools/bounded_run.py is a byte copy with a bounded_run.pin beside it naming the leo-workspace commit and its SHA-256;
leo-workspace's VendoredCopies test (test_bounded_run.py) checks the copy against this file at that commit.
"""
from __future__ import annotations

import json
import os
import secrets
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field

MODES = ("auto", "subreaper", "cgroup", "tracked")
TOKEN_VAR = "BOUNDED_RUN_TOKEN"
EMPTY_READS = 3  # tracked on Linux: scans a new process may read an empty environment before it counts as none
# After its SIGKILLs, how long the reaper waits for every process to be gone before it says unknown.
KILL_GRACE = 2.0
# How long past the deadline and KILL_GRACE the caller waits for the reaper itself before it kills the reaper's
# group and the command's.
REAPER_GRACE = 5.0
PR_SET_PDEATHSIG, PR_SET_CHILD_SUBREAPER, PR_GET_CHILD_SUBREAPER = 1, 36, 37
SEEN_MAX = 4096  # processes the interim status names; past it (seen_full) the status is never taken as complete


def _find_ps() -> str | None:
    """ps by its absolute path, found once, never through the run's PATH (cmux#41402 F1: shell_tree's scratch PATH
    had no ps, so the fallback crashed at the timeout)."""
    for path in ("/bin/ps", "/usr/bin/ps"):
        if os.access(path, os.X_OK):
            return path
    found = shutil.which("ps", path=os.defpath)
    return os.path.abspath(found) if found else None


PS = _find_ps()


@dataclass
class Result:
    state: str  # "exited", "timeout" or "unknown"
    code: int | None  # the command's exit status, negative for a signal; None when it was never reaped
    pid: int  # the command's pid: its process group and its session too; 0 when it never started
    mode: str  # "subreaper", "cgroup" or "tracked"; "" when the reaper never chose
    stdout: bytes | str = b""
    stderr: bytes | str = b""
    # State unknown: the processes still alive when the run gave up; 0 stands for one that could not be accounted for
    # (no guardian, cgroup or complete status proves nothing escaped).
    left: list[int] = field(default_factory=list)
    reason: str = ""

    @property
    def ok(self) -> bool:
        return self.state == "exited"

    @property
    def timed_out(self) -> bool:
        return self.state == "timeout"


def run(argv: list[str], timeout: float, *, input: bytes | str | None = None, cwd: str | None = None,
        env: dict[str, str] | None = None, capture: bool = True, text: bool = False, umask: int = -1,
        mode: str = "auto", kill_grace: float = KILL_GRACE, reaper_grace: float = REAPER_GRACE) -> Result:
    """Run ARGV (resolved on ENV's PATH, as subprocess does) under the reaper, past TIMEOUT seconds killed with every
    process it left. INPUT is its stdin (else /dev/null); CAPTURE keeps its stdout and stderr (else /dev/null), as str
    when TEXT. MODE forces one way of tracking (tests); a forced mode this host lacks ends unknown, never run."""
    if mode not in MODES:
        raise ValueError(f"mode {mode!r} is not one of {MODES}")
    work = tempfile.mkdtemp(prefix="bounded-run-")
    opened = []
    try:
        def scratch(name: str, data: bytes = b""):
            f = open(os.path.join(work, name), "w+b")
            opened.append(f)
            f.write(data)
            f.seek(0)
            return f

        stdin = subprocess.DEVNULL
        if input is not None:
            stdin = scratch("in", input.encode() if isinstance(input, str) else input)
        out = scratch("out") if capture else subprocess.DEVNULL
        err = scratch("err") if capture else subprocess.DEVNULL
        status = os.path.abspath(os.path.join(work, "status"))
        token = secrets.token_hex(16)
        guard = subprocess.Popen([sys.executable, "-I", "-S", os.path.abspath(__file__), "--guard", status,
                                  repr(float(timeout)), mode, repr(float(kill_grace)), token, "--", *argv],
                                 stdin=stdin, stdout=out, stderr=err, cwd=cwd, env=env, start_new_session=True,
                                 umask=umask)
        hung = ""
        try:
            # The reaper's deadline and kill grace, then the guardian's own kill grace, then slack.
            guard.wait(timeout=timeout + 2 * kill_grace + reaper_grace)
        except subprocess.TimeoutExpired:
            hung = f"the reaper ran {reaper_grace:g} s past the deadline and its kill grace"
        got = _read_status(status)
        left: list[int] = []
        state, reason = got.get("state", "unknown"), got.get("reason", "")
        if hung or "state" not in got:
            # Neither the reaper nor the guardian wrote a final status: nothing proved the run over, and what the
            # command left may run on. Kill the guardian (unreaped, so its pid is still its own; the reaper dies
            # with it on Linux), then every process the run is known by, and say unknown.
            if guard.returncode is None:
                guard.kill()
                try:
                    guard.wait(timeout=reaper_grace)
                except subprocess.TimeoutExpired:
                    left.append(0)
            reaper = _read_status(status + ".guard")
            if reaper.get("reaper"):
                _kill_seen(int(reaper["reaper"]), str(reaper.get("start", "")))
            gone, why = _clean_up(token, got, kill_grace)
            left += gone
            state = "unknown"
            reason = hung or (got.get("reason") or f"the guardian exited {guard.returncode} with no final status")
            reason += f"; {why}" if why else ""
            reason += (f"; still alive or unaccounted for after the cleanup: {left}" if left else
                       "; the run's cgroup is empty: nothing of the run is alive")
        stdout, stderr = (f.read() if hasattr(f, "read") else b"" for f in (_rewind(out), _rewind(err)))
        if text:
            stdout, stderr = stdout.decode(errors="replace"), stderr.decode(errors="replace")
        return Result(state=state, code=got.get("code"), pid=got.get("pid") or 0, mode=got.get("mode", ""),
                      stdout=stdout, stderr=stderr, left=left + list(got.get("left", [])), reason=reason)
    finally:
        for f in opened:
            f.close()
        shutil.rmtree(work, ignore_errors=True)


def _rewind(f):
    if hasattr(f, "seek"):
        f.seek(0)
    return f


def _read_status(path: str) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _kill_seen(pid: int, start: str) -> bool:
    """SIGKILL PID only if it is still the process seen with START: on Linux through a pidfd opened first and then
    checked against START, so a pid reused since cannot be hit (LW#4477 review F2); elsewhere after checking START.
    True when the signal went (or the process is already gone), False when PID is now someone else's."""
    if not start:
        return False
    pidfd_open, send = getattr(os, "pidfd_open", None), getattr(signal, "pidfd_send_signal", None)
    if pidfd_open and send:
        try:
            fd = pidfd_open(pid)
        except OSError:
            return True  # gone
        try:
            if _start_of(pid) != start:
                return False
            send(fd, signal.SIGKILL)
            return True
        except OSError:
            return True
        finally:
            os.close(fd)
    if _start_of(pid) != start:
        return False
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
    return True


def _clean_up(token: str, status: dict, grace: float) -> tuple[list[int], str]:
    """Kill every process a run whose reaper and guardian died left. A process is the run's when its environment
    holds TOKEN, when the interim STATUS names it with its start time, or when it is below one of those; the run's
    cgroup, if it made one, is killed whole. Nothing else is touched. Returns the pids still alive after GRACE seconds,
    with 0 for what cannot be accounted for, and why: only an empty cgroup proves that nothing of the run lives on (a
    process that cleared its environment and lost its parent before the reaper saw it is found by nothing else)."""
    cgroup = cgroup_path(token) if sys.platform.startswith("linux") else ""
    held = bool(cgroup) and os.path.isdir(cgroup)
    seen = {int(p): str(t) for p, t in status.get("seen", [])}
    why = "" if held else "no cgroup held the run, so a process of it that nothing names cannot be ruled out"
    if not held and status.get("seen_full"):
        why += f" (and the interim status stopped naming them past {SEEN_MAX})"
    stop = time.monotonic() + grace
    while True:
        if cgroup and os.path.isdir(cgroup):
            try:
                with open(os.path.join(cgroup, "cgroup.kill"), "w") as f:
                    f.write("1")
            except OSError:
                pass
        try:
            procs = processes(token, {})
        except Exception as e:  # noqa: BLE001 - the list cannot be read: nothing proven gone
            return [0], f"the process list could not be read: {e!r}"
        ours = {pid for pid, p in procs.items() if not p.zombie and pid != os.getpid()
                and (p.tokened or seen.get(pid) == p.start)}
        for pid in list(ours):
            ours.update(p for p in below(pid, procs))
        for pid in ours:
            _kill_seen(pid, procs[pid].start)
        populated = False
        if cgroup and os.path.isdir(cgroup):
            try:
                with open(os.path.join(cgroup, "cgroup.events")) as f:
                    populated = "populated 1" in f.read()
            except OSError:
                pass
        if not ours and not populated:
            if held:
                try:
                    os.rmdir(cgroup)
                except OSError:
                    pass
                return [], ""
            return [0], why
        if time.monotonic() >= stop:
            return sorted(ours) or [0], why
        time.sleep(0.05)


def default_signals() -> None:
    """Every signal back at its default and none blocked, in this process. A command's start inherits its parent's
    ignored signals and blocked mask across exec (only handlers reset): Python ignores SIGPIPE and SIGXFSZ, nohup
    ignores SIGHUP, a caller may ignore or block anything. The reaper runs this at its start and in the command's
    child before exec, so `kill -PIPE $$` (or HUP, INT, TERM) ends the command as it would from a shell."""
    for sig in signal.valid_signals():
        if sig in (signal.SIGKILL, signal.SIGSTOP):
            continue
        try:
            if signal.getsignal(sig) is not signal.SIG_DFL:
                signal.signal(sig, signal.SIG_DFL)
        except (OSError, ValueError, RuntimeError):
            continue  # a signal number Python cannot set (Linux's real-time ones glibc keeps)
    signal.pthread_sigmask(signal.SIG_SETMASK, [])


# ---- the reaper: everything below runs in its own process (python3 -I -S bounded_run.py --reap ...) ----

class _Reaper:
    def __init__(self, status: str, timeout: float, mode: str, kill_grace: float, argv: list[str],
                 token: str | None = None):
        self.status_path, self.argv, self.kill_grace = status, argv, kill_grace
        self.deadline = time.monotonic() + timeout
        self.asked = mode
        self.mode, self.reason, self.left = "", "", []
        self.leader = 0
        self.code: int | None = None
        # The run's token: in the command's environment in every mode, so the caller can find what a dead reaper
        # left (run() makes it and passes it in, so it knows it before this process writes anything).
        self.token = token or secrets.token_hex(16)
        self.cgroup = ""
        self.contain = ""  # tracked mode: "subreaper" or "cgroup" when one holds the run too, so nothing escapes
        self.escaped = False
        self.tracked: dict[int, object] = {}
        self.kids: dict[int, set[int]] = {}  # tracked mode: each tracked parent's children seen
        self.forks: dict[int, int] = {}  # tracked mode on macOS: forks kqueue saw per tracked pid
        self.seen: dict[int, str] = {}  # every process of the run seen, by pid: its start time
        self.seen_full = False
        self.kq = None
        self.environs: dict = {}  # (pid, start) -> whether its environment holds the token
        r, w = os.pipe()
        os.set_blocking(r, False)
        os.set_blocking(w, False)
        self.wake = r
        default_signals()  # whatever the caller ignored or blocked, the reaper and the command start clean
        signal.signal(signal.SIGCHLD, lambda *_: None)
        signal.set_wakeup_fd(w)

    def write(self, **fields) -> None:
        _write(self.status_path, **fields)

    def interim(self) -> None:
        """The status while the run goes: what the caller needs to clean up if this process and the guardian die.
        It names at most SEEN_MAX processes; past that, seen_full says it is not the whole run."""
        self.seen_full = len(self.seen) > SEEN_MAX
        self.write(pid=self.leader, mode=self.mode, cgroup=self.cgroup,
                   seen=[[p, s] for p, s in list(self.seen.items())[:SEEN_MAX]], seen_full=self.seen_full)

    def note(self, procs: dict) -> None:
        """Add the live processes of PROCS (pid -> Proc) to self.seen (every one: the reaper kills by it); write the
        interim status when it grew while it still names them all."""
        grew = False
        for pid, p in procs.items():
            if pid > 0 and p.start and self.seen.get(pid) != p.start:
                self.seen[pid] = p.start
                grew = True
        if grew and not self.seen_full:
            self.interim()

    def finish(self, state: str) -> None:
        if self.cgroup:
            for _ in range(50):
                try:
                    os.rmdir(self.cgroup)
                    break
                except FileNotFoundError:
                    break
                except OSError:
                    time.sleep(0.01)
        self.write(state=state, code=self.code, pid=self.leader, mode=self.mode, left=self.left, reason=self.reason)
        os._exit(1 if state == "unknown" else 0)

    def nap(self, seconds: float) -> None:
        """Sleep up to SECONDS, woken early by a SIGCHLD (or, tracked on macOS, a fork or exit kqueue saw)."""
        seconds = max(0.0, seconds)
        if self.kq is not None:
            try:
                for ev in self.kq.control(None, 64, seconds):
                    if ev.filter == select.KQ_FILTER_PROC and ev.fflags & select.KQ_NOTE_FORK:
                        self.forks[ev.ident] = self.forks.get(ev.ident, 0) + 1
                    elif ev.filter == select.KQ_FILTER_READ:
                        self.drain()
                return
            except OSError:
                self.kq = None
        try:
            select.select([self.wake], [], [], seconds)
            self.drain()
        except (BlockingIOError, InterruptedError):
            pass

    def drain(self) -> None:
        try:
            while os.read(self.wake, 512):
                pass
        except (BlockingIOError, InterruptedError):
            pass

    # -- choosing a mode --

    def subreaper(self) -> str:
        """'' when this process is now the child subreaper, else why not."""
        return set_subreaper()

    def make_cgroup(self) -> str:
        """'' when self.cgroup is a fresh cgroup v2 below this process's own that the command can join, else why not.
        Its name holds the run's token, so the caller finds it (cgroup_path) if this process dies."""
        if not sys.platform.startswith("linux"):
            return "no cgroup v2 off Linux"
        try:
            path = cgroup_path(self.token)
            if not path:
                return "no cgroup v2 here"
            os.mkdir(path)
            self.cgroup = path
            return ""
        except OSError as e:
            return f"no cgroup of its own: {e}"

    def drop_cgroup(self) -> None:
        if self.cgroup:
            try:
                os.rmdir(self.cgroup)
            except OSError:
                pass
            self.cgroup = ""

    def start(self) -> None:
        why = []
        order = {"auto": ("subreaper", "cgroup", "tracked")}.get(self.asked, (self.asked,))
        for mode in order:
            self.contain = ""
            if mode == "subreaper":
                no = self.subreaper()
            elif mode == "cgroup":
                no = self.make_cgroup()
            else:
                # Tracked runs inside a subreaper or a cgroup where either is there, so no process can escape it;
                # with neither (macOS), it fails closed on any sign of one (over()).
                no = ""
                if not self.subreaper():
                    self.contain = "subreaper"
                elif not self.make_cgroup():
                    self.contain = "cgroup"
            if no:
                why.append(f"{mode}: {no}")
                continue
            self.mode = mode + (f"+{self.contain}" if self.contain else "")
            try:
                self.spawn()
            except subprocess.SubprocessError as e:  # the cgroup could not be joined
                why.append(f"{mode}: the command could not join its cgroup ({e})")
                self.drop_cgroup()
                if mode == "tracked" and self.contain == "cgroup":
                    self.contain, self.mode = "", "tracked"
                    try:
                        self.spawn()
                    except subprocess.SubprocessError:
                        continue
                    except OSError as e:
                        self.cannot_run(e)
                else:
                    continue
            except OSError as e:
                self.cannot_run(e)
            self.reason = "; ".join(why)
            self.note({self.leader: Proc(0, self.leader, self.leader, _start_of(self.leader), False, True)})
            self.interim()
            return
        self.mode = ""
        self.reason = "no way to track the run's processes: " + "; ".join(why)
        self.finish("unknown")

    def cannot_run(self, e: OSError) -> None:
        """The command itself cannot run: like subprocess, 127 or 126."""
        self.code, self.reason = 127 if isinstance(e, FileNotFoundError) else 126, str(e)
        sys.stderr.write(f"bounded_run: {argv0(self.argv)}: {e}\n")
        self.finish("exited")

    def spawn(self) -> None:
        env = {**os.environ, TOKEN_VAR: self.token}
        procs = os.path.join(self.cgroup, "cgroup.procs") if self.cgroup else ""

        def pre():
            # Every signal at its default and none blocked in the command, in every mode, whatever the caller
            # ignored or blocked (handlers reset at exec; ignored signals and the mask do not).
            default_signals()
            if procs:
                with open(procs, "w") as f:
                    f.write("0")
        child = subprocess.Popen(self.argv, env=env, start_new_session=True, preexec_fn=pre, close_fds=True,
                                 restore_signals=True)
        child.returncode = 0  # reaped by waitpid below, never by the Popen object
        self.leader = child.pid
        if sys.platform == "darwin" and self.mode == "tracked":
            self.watch(self.leader)
            try:
                self.kq.control([select.kevent(self.wake, select.KQ_FILTER_READ, select.KQ_EV_ADD)], 0, 0)
            except (OSError, AttributeError):
                pass

    # -- waiting --

    def reap(self) -> bool:
        """Reap every child that exited; False once this process has no child left."""
        while True:
            try:
                pid, status = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return False
            if not pid:
                return True
            if pid == self.leader:
                self.code = os.waitstatus_to_exitcode(status)

    def live(self) -> list[int]:
        """The run's processes that have not exited (a zombie is gone); [0] for one not named yet. Raises when the
        process list cannot be read."""
        children = self.reap()
        base = self.mode.split("+")[0]
        if base == "subreaper":
            # Every orphan of the run is this process's child: none left, none anywhere.
            if not children:
                return []
            procs = processes()
            out = below(os.getpid(), procs)
            self.note({p: procs[p] for p in out})
            return out or [0]
        if base == "cgroup":
            return self.cgroup_members()
        live = self.scan()
        if self.contain == "subreaper" and children:
            procs = processes()
            more = below(os.getpid(), procs)
            self.note({p: procs[p] for p in more})
            live = sorted(set(live) | set(more)) or [0]
        elif self.contain == "cgroup":
            live = sorted(set(live) | set(self.cgroup_members()))
        return live

    def cgroup_members(self) -> list[int]:
        with open(os.path.join(self.cgroup, "cgroup.events")) as f:
            if "populated 0" in f.read():
                return []
        with open(os.path.join(self.cgroup, "cgroup.procs")) as f:
            members = [int(p) for p in f.read().split()]
        new = [p for p in members if p not in self.seen]
        if new:
            self.note({p: Proc(0, 0, 0, _start_of(p), False, False) for p in new if _start_of(p)})
        return members or [0]

    def scan(self) -> list[int]:
        """Tracked mode: grow the set from the process list and return its live members."""
        procs = processes(self.token, self.environs)
        grow = True
        while grow:
            grow = False
            for pid, p in procs.items():
                if pid == os.getpid() or self.tracked.get(pid) == p.start:
                    continue
                parent = procs.get(p.ppid)
                if (pid == self.leader or p.tokened or p.sid == self.leader or p.pgid == self.leader or
                        (parent is not None and self.tracked.get(p.ppid) == parent.start)):
                    self.tracked[pid] = p.start
                    if p.ppid in self.tracked:
                        self.kids.setdefault(p.ppid, set()).add(pid)
                    grow = True
                    self.watch(pid)
        self.note({pid: procs[pid] for pid in self.tracked if pid in procs})
        # A new process whose environment did not read yet may be the run's: the run is not over until it reads.
        live = [0] if any(p.pending and pid not in self.tracked for pid, p in procs.items()) else []
        for pid, start in self.tracked.items():
            p = procs.get(pid)
            if p is not None and p.start == start and not p.zombie:
                live.append(pid)
                # Left the command's session (its group, where ps cannot tell the session): setsid.
                if pid != self.leader and (p.sid != self.leader if p.sid != -1 else p.pgid != self.leader):
                    self.escaped = True
        return live

    def watch(self, pid: int) -> None:
        if sys.platform != "darwin":
            return
        try:
            if self.kq is None:
                self.kq = select.kqueue()
            ev = select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD,
                               select.KQ_NOTE_FORK | select.KQ_NOTE_EXIT)
            self.kq.control([ev], 0, 0)
        except (OSError, AttributeError):
            pass

    def kill(self, pids: list[int]) -> None:
        if self.cgroup:
            try:
                with open(os.path.join(self.cgroup, "cgroup.kill"), "w") as f:
                    f.write("1")
            except OSError:
                pass
        if self.mode.startswith("tracked"):
            # Before the group kill, every process of the run the list shows is recorded with its start time: once
            # the group dies, a setsid descendant reparents away (to launchd, with no subreaper) and only this record
            # still names it (manaflow-ai/cmux-platform#1286 review, F1). Each is killed below by that record.
            try:
                pids = sorted(set(pids) | set(self.scan()))
            except Exception:  # noqa: BLE001 - check() reports a list that cannot be read
                pass
        if self.code is None:
            # The command is unreaped (alive or a zombie): its pid, and so its group's id, is still its own. Once
            # reaped, its group is killed by its members' pids below, never by a pgid that may be someone else's.
            try:
                os.killpg(self.leader, signal.SIGKILL)
            except OSError:
                pass
        for pid in pids:
            if pid > 0:
                _kill_seen(pid, self.seen.get(pid) or _start_of(pid))

    def check(self) -> tuple[list[int], str]:
        try:
            live = self.live()
            if not live and self.mode.startswith("tracked"):
                # One scan lists /proc before it reads each process: a child forked just before its parent died
                # can be missing from that list. A second scan, listed after the first saw every process dead,
                # sees it.
                live = self.live()
            return live, ""
        except Exception as e:  # noqa: BLE001 - a process list that cannot be read is unknown, never a pass
            return [0], f"the process list could not be read: {e!r}"

    def unaccounted(self) -> str:
        """Tracked mode with nothing to hold the run (no subreaper, no cgroup): why a process of the run may still
        live unseen, or '' when none can. Fails closed: any sign of one is enough."""
        if self.contain:
            return ""
        if self.escaped:
            return "a process left the command's session (setsid), and with no subreaper or cgroup one could escape"
        if sys.platform != "darwin":
            return ("tracked with no subreaper and no cgroup on Linux: a child that left the session, cleared its "
                    "environment and lost its parent between two scans cannot be ruled out")
        if self.kq is None:
            return "no kqueue to count the run's forks"
        missed = {p: n for p, n in self.forks.items() if n > len(self.kids.get(p, ()))}
        if missed:
            return f"kqueue saw forks whose children were never seen (pid: forks): {missed}"
        # A process of this user that launchd adopted after the command started, and that the run does not hold:
        # an escape that cleared its environment. Another program's may count too: that is unknown, never a pass.
        try:
            procs = processes()
        except Exception as e:  # noqa: BLE001
            return f"the process list could not be read: {e!r}"
        lead = _epoch(self.tracked.get(self.leader))
        if lead is None:
            return "the command's start time could not be read"
        uid = os.getuid()
        strays = [pid for pid, p in procs.items() if p.ppid == 1 and p.uid == uid and not p.zombie
                  and pid not in self.tracked and (_epoch(p.start) or lead) >= lead]
        if strays:
            return f"processes of this user adopted by launchd since the command started: {strays}"
        return ""

    def over(self, state: str) -> None:
        """Every process of the run is gone: reap the command (dead by now, so this cannot block) and report."""
        if self.code is None:
            try:
                self.code = os.waitstatus_to_exitcode(os.waitpid(self.leader, 0)[1])
            except ChildProcessError:
                pass
        if self.mode.startswith("tracked"):
            why = self.unaccounted()
            if why:
                # Fail closed, and never as "nothing alive": every process of the run recorded that still lives, or 0
                # for one nothing here can see.
                self.reason = why
                state = "unknown"
                self.left = [p for p in self.alive_recorded() if p > 0] or [0]
        self.finish(state)

    def alive_recorded(self) -> list[int]:
        """The processes of the run this reaper recorded (with their start times) that still live."""
        try:
            procs = processes()
        except Exception:  # noqa: BLE001 - nothing can be named: the caller says 0
            return []
        return [pid for pid, start in self.seen.items() if pid != os.getpid() and pid in procs
                and procs[pid].start == start and not procs[pid].zombie]

    def main(self) -> None:
        self.start()
        while True:
            live, trouble = self.check()
            if not live:
                self.over("exited")
            left = self.deadline - time.monotonic()
            if left <= 0:
                break
            self.nap(min(left, 0.01 if self.mode.startswith("tracked") else 0.05))
        # The deadline: kill every process of the run, and wait until each is gone.
        stop = time.monotonic() + self.kill_grace
        while True:
            self.kill([p for p in live if p > 0])
            self.nap(0.01)
            live, trouble = self.check()
            if not live:
                self.over("timeout")
            if time.monotonic() >= stop:
                self.left = [p for p in live if p > 0]
                self.reason = trouble or f"{len(self.left)} processes alive {self.kill_grace:g} s after SIGKILL"
                self.finish("unknown")


def _prctl():
    import ctypes
    return ctypes, ctypes.CDLL(None, use_errno=True)


def set_subreaper() -> str:
    """'' when this process is now the child subreaper, else why not."""
    if not sys.platform.startswith("linux"):
        return "no PR_SET_CHILD_SUBREAPER off Linux"
    try:
        ctypes, libc = _prctl()
        if libc.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
            return f"prctl(PR_SET_CHILD_SUBREAPER) failed: errno {ctypes.get_errno()}"
        got = ctypes.c_int(0)
        if libc.prctl(PR_GET_CHILD_SUBREAPER, ctypes.byref(got), 0, 0, 0) != 0 or got.value != 1:
            return "PR_GET_CHILD_SUBREAPER does not read back 1"
        return ""
    except (AttributeError, OSError) as e:
        return f"prctl unavailable: {e}"


def _guard(status: str, reap: list[str], grace: float) -> None:
    """The guardian: run() -> this -> the reaper -> the command. On Linux this process is a child subreaper and the
    reaper dies with it, so a reaper that dies leaves every process of the run to this one: it kills each child it
    has until waitpid says none is left, and only then calls the run's processes gone. Whatever the reaper's final
    status, a child still here afterwards is a process the reaper missed: killed, and the run is unknown."""
    contained = not set_subreaper()
    me = os.getpid()

    def pre():
        if contained:
            ctypes, libc = _prctl()
            libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL, 0, 0, 0)
            if os.getppid() != me:  # the guardian died before the prctl took
                os._exit(1)
    try:
        reaper = subprocess.Popen(reap, start_new_session=True, preexec_fn=pre, close_fds=True)
    except OSError as e:
        _write(status, state="unknown", code=None, pid=0, mode="", left=[], reason=f"the reaper did not start: {e}")
        os._exit(1)
    reaper.returncode = 0  # reaped by waitpid below, never by the Popen object
    _write(status + ".guard", reaper=reaper.pid, start=_start_of(reaper.pid), contained=contained)
    code = None
    while code is None:  # reaping the run's orphans this process adopts on the way
        try:
            pid, st = os.waitpid(-1, 0)
        except ChildProcessError:
            break
        except InterruptedError:
            continue
        if pid == reaper.pid:
            code = os.waitstatus_to_exitcode(st)
    if not contained:
        os._exit(0)  # run() cleans up after a reaper with no final status, and says what it cannot account for
    got = _read_status(status)
    killed, left = _kill_children(grace)
    if "state" in got and not killed:
        os._exit(0)
    reason = (got.get("reason") if "state" in got else "") or ""
    if "state" in got:
        reason = (f"the reaper said {got['state']} with {len(killed)} processes of the run still alive below the "
                  f"guardian: {killed}" + (f"; {reason}" if reason else ""))
    else:
        reason = f"the reaper exited {code} with no final status"
    reason += (f"; still alive below the guardian after {grace:g} s: {left}" if left else
               f"; the guardian killed {len(killed)} processes of the run and has no child left: nothing of the run "
               "is alive")
    _write(status, state="unknown", code=got.get("code"), pid=got.get("pid") or 0, mode=got.get("mode", ""),
           left=left, reason=reason)
    os._exit(1)


def _kill_children(grace: float) -> tuple[list[int], list[int]]:
    """Kill every child of this process until it has none left. Each is unreaped while it is signalled, so its pid
    cannot be someone else's; a child's own children come here as it dies (a subreaper). Returns the pids killed and
    those still alive after GRACE seconds."""
    me, killed = os.getpid(), []
    stop = time.monotonic() + grace
    while True:
        while True:
            try:
                pid, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                return killed, []
            if not pid:
                break
        try:
            kids = [pid for pid, p in processes().items() if p.ppid == me and not p.zombie]
        except Exception:  # noqa: BLE001 - the list cannot be read: kill what waitpid shows when it can
            kids = []
        for pid in kids:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            if pid not in killed:
                killed.append(pid)
        if time.monotonic() >= stop:
            return killed, kids or [0]
        time.sleep(0.01)


def _write(path: str, **fields) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(fields, f)
    os.replace(tmp, path)


def argv0(argv: list[str]) -> str:
    return argv[0] if argv else ""


@dataclass
class Proc:
    ppid: int
    pgid: int
    sid: int  # -1 where ps cannot tell (macOS): a process's own pid never matches it
    start: str
    zombie: bool
    tokened: bool
    pending: bool = False  # tracked on Linux: its environment did not read yet, so it may be the run's
    uid: int = -1  # from ps (macOS); -1 from /proc, where nothing reads it


def processes(token: str = "", environs: dict | None = None) -> dict[int, Proc]:
    """Every process: from /proc on Linux, else from ps by its absolute path. Raises when neither can be read."""
    if os.path.isdir("/proc/self"):
        return _proc_processes(token, {} if environs is None else environs)
    return _ps_processes(token)


def _ps_processes(token: str = "") -> dict[int, Proc]:
    """The process list from PS (never the run's PATH); on macOS with each one's environment (-E), for the token."""
    if not PS:
        raise OSError("no /proc, and no ps in /bin, /usr/bin or the default PATH")
    flags = "-AEww" if sys.platform == "darwin" else "-Aww"
    got = subprocess.run([PS, flags, "-o", "pid=,ppid=,pgid=,uid=,stat=,lstart=,command="],
                         stdin=subprocess.DEVNULL, capture_output=True, text=True, errors="replace", timeout=10,
                         check=True)
    out = {}
    needle = f"{TOKEN_VAR}={token}" if token else None
    for line in got.stdout.splitlines():
        parts = line.split(None, 10)
        if len(parts) < 10:
            continue
        try:
            pid, ppid, pgid, uid = int(parts[0]), int(parts[1]), int(parts[2]), int(parts[3])
        except ValueError:
            continue
        rest = parts[10] if len(parts) > 10 else ""
        out[pid] = Proc(ppid, pgid, -1, " ".join(parts[5:10]), parts[4].startswith("Z"),
                        bool(needle and needle in rest), uid=uid)
    if not out:
        raise OSError(f"{PS} listed no process")
    return out


def _own_start() -> int:
    try:
        with open("/proc/self/stat", "rb") as f:
            return int(f.read().rsplit(b")", 1)[1].split()[19])
    except (OSError, IndexError, ValueError):
        return 0


_OWN_START = _own_start()


def _proc_processes(token: str, environs: dict) -> dict[int, Proc]:
    """ENVIRONS caches each (pid, start)'s token check, so an old process's environment is read once."""
    needle = f"{TOKEN_VAR}={token}".encode() if token else None
    out = {}
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat", "rb") as f:
                fields = f.read().rsplit(b")", 1)[1].split()
        except (OSError, IndexError):
            continue
        pid, start, zombie = int(name), fields[19].decode(), fields[0] in (b"Z", b"X")
        tokened, pending = environs.get((pid, start)), False
        if tokened is None:
            tokened = False
            if needle:
                try:
                    with open(f"/proc/{name}/environ", "rb") as f:
                        env = f.read()
                    tokened = b"\0" + needle + b"\0" in b"\0" + env + b"\0"
                    # A process in the middle of an exec reads an empty environment: it is read again next scan,
                    # and until it reads non-empty (or empty EMPTY_READS times: a process with no environment at
                    # all) the run is not over.
                    if not env and int(start) >= _OWN_START and not zombie:
                        key = ("empty", pid, start)
                        environs[key] = environs.get(key, 0) + 1
                        pending = environs[key] < EMPTY_READS
                except OSError:  # another user's process, or gone
                    pass
            # A no is kept only for a process older than this one, which can never be the run's.
            if tokened or int(start) < _OWN_START:
                environs[(pid, start)] = tokened
        out[pid] = Proc(int(fields[1]), int(fields[2]), int(fields[3]), start, zombie, tokened, pending)
    return out


def _start_of(pid: int) -> str:
    """PID's start time as processes() reports it, or '' when it cannot be read."""
    if os.path.isdir("/proc/self"):
        try:
            with open(f"/proc/{pid}/stat", "rb") as f:
                return f.read().rsplit(b")", 1)[1].split()[19].decode()
        except (OSError, IndexError):
            return ""
    try:
        return _ps_processes()[pid].start
    except Exception:  # noqa: BLE001
        return ""


def _epoch(start) -> float | None:
    """A ps lstart ("Wed Nov 11 17:45:36 2026") as seconds since the epoch; None for anything else."""
    try:
        return time.mktime(time.strptime(str(start), "%a %b %d %H:%M:%S %Y"))
    except (ValueError, OverflowError):
        return None


def cgroup_path(token: str) -> str:
    """The cgroup v2 a run with TOKEN makes below this process's own (the reaper starts in its caller's cgroup, so
    both name the same one), or '' off cgroup v2."""
    try:
        with open("/proc/self/cgroup") as f:
            rel = next(line[3:].strip() for line in f if line.startswith("0::"))
    except (OSError, StopIteration):
        return ""
    base = "/sys/fs/cgroup" + rel
    if not os.path.exists(os.path.join(base, "cgroup.procs")):
        return ""
    return os.path.join(base, f"bounded-run-{token}")


def below(root: int, procs: dict | None = None) -> list[int]:
    """Every live process below ROOT, by parent links, in PROCS (else a fresh process list)."""
    kids: dict[int, list[int]] = {}
    for pid, p in (processes() if procs is None else procs).items():
        if not p.zombie:
            kids.setdefault(p.ppid, []).append(pid)
    out, todo = [], [root]
    while todo:
        for pid in kids.get(todo.pop(), []):
            out.append(pid)
            todo.append(pid)
    return out


if __name__ == "__main__":
    if sys.argv[1:2] == ["--reap"] and sys.argv[7:8] == ["--"]:
        status, timeout, mode, grace, token = sys.argv[2:7]
        _Reaper(status, float(timeout), mode, float(grace), sys.argv[8:], token).main()
    elif sys.argv[1:2] == ["--guard"] and sys.argv[7:8] == ["--"]:
        _guard(sys.argv[2], [sys.executable, "-I", "-S", os.path.abspath(__file__), "--reap", *sys.argv[2:]],
               float(sys.argv[5]))
    else:
        sys.exit("usage: bounded_run.py --guard|--reap STATUS TIMEOUT MODE KILL_GRACE TOKEN -- ARGV...  (run() "
                 "starts it)")
