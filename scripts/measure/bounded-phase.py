#!/usr/bin/env python3
"""Run one phase of a fleet measurement with a deadline, a stall limit and progress lines.

The fleet controller stops a measurement whose step log is silent for 45 min (CMUX_CI_MEASURE_SILENT_MAX) and names
nothing but the last line printed. update-click-ab.sh sent each side's build to a file, so a build that took longer
than that on a plain M4 (two builds took 24 and 31 min on faster Macs) was stopped as "hung" right after the
`UCA host` line, and the log could not say which step it was in, or whether it was stuck at all (CMUX-571).

    bounded-phase.py --name NAME --deadline S [--stall S] [--heartbeat S] [--grace S] [--tag UCA]
                     [--log FILE] [--follow FILE]... -- COMMAND [ARGS...]

COMMAND runs in its own process group. With --log its output is appended to FILE, otherwise it streams through.
Output (the stream, or growth of --log or a --follow file) counts as progress. When nothing was printed for
--heartbeat seconds, it prints `TAG-PROGRESS NAME Ns, output Ms ago: <latest line>`. Past --deadline seconds it prints
`TAG-TIMEOUT NAME ...`, and after --stall seconds with no progress `TAG-STALL NAME ...`; either way it ends the group
(SIGTERM, then SIGKILL after --grace) and exits 124. Otherwise it exits with COMMAND's status. A SIGTERM or SIGINT it
gets is passed to the group, so a cancelled step ends the phase too, and the group's leader ends the group when this
process dies without a word (a SIGKILL), so no build or app outlives the step.
"""
import argparse
import os
import re
import select
import signal
import subprocess
import sys
import threading
import time

ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
TIMED_OUT = 124


def last_line(path):
    """The last non-empty line of PATH, cleaned for one log line, or '' when it has none."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 8192))
            tail = f.read().decode("utf-8", "replace")
    except OSError:
        return ""
    for line in reversed(tail.replace("\r", "\n").splitlines()):
        line = ANSI.sub("", line).strip()
        if line:
            return line[:240]
    return ""


def file_state(path):
    try:
        st = os.stat(path)
        return (st.st_size, st.st_mtime_ns)
    except OSError:
        return None


def signal_group(pgid, sig, say=None):
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pass
    except PermissionError as e:  # a member runs as another user: say so, the phase may outlive this
        if say:
            say(f"cannot send {signal.Signals(sig).name} to process group {pgid}: {e}")


def guard(read_fd, grace, command):
    """The group's leader: runs COMMAND and exits with its status, and ends the whole group when the pipe from
    bounded-phase.py closes without a word, as when that process is SIGKILLed (the controller's hard stop): a build
    or an app must never outlive the phase that owns it on an exclusive Mac."""
    child = os.fork()
    if child == 0:
        os.close(read_fd)
        signal.pthread_sigmask(signal.SIG_SETMASK, [])
        os.execvp(command[0], command)
    # The group's SIGTERM is for COMMAND; this leader stays to report its status, and goes with the SIGKILL.
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.pthread_sigmask(signal.SIG_SETMASK, [])

    def watch():
        try:
            data = os.read(read_fd, 1)
        except OSError:
            data = b""
        if data:  # bounded-phase.py said it is done with the group
            return
        signal_group(0, signal.SIGTERM)
        time.sleep(grace)
        signal_group(0, signal.SIGKILL)

    threading.Thread(target=watch, daemon=True).start()
    _, status = os.waitpid(child, 0)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


def end_group(proc, grace, say):
    """SIGTERM to COMMAND's process group, SIGKILL to what is left after GRACE seconds."""
    for sig, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 5)):
        signal_group(proc.pid, sig, say)
        try:
            proc.wait(wait)
            break
        except subprocess.TimeoutExpired:
            if sig == signal.SIGTERM:
                say(f"still running {grace:.0f} s after SIGTERM; sending SIGKILL")
    else:
        say(f"the phase's leader {proc.pid} still runs after SIGKILL")
    # Members of the group may outlive the leader (a daemon the phase started): give them the same end.
    signal_group(proc.pid, signal.SIGKILL, say)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["--guard"]:  # internal: the group leader bounded-phase.py starts, see guard()
        return guard(int(argv[1]), float(argv[2]), argv[4:])
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--name", required=True, help="what the phase is, as the log names it")
    ap.add_argument("--deadline", type=float, required=True, help="seconds the phase may take in all")
    ap.add_argument("--stall", type=float, default=0, help="seconds with no output before it counts as stuck (0: no limit)")
    ap.add_argument("--heartbeat", type=float, default=120, help="seconds between progress lines when nothing printed")
    ap.add_argument("--grace", type=float, default=30, help="seconds from SIGTERM to SIGKILL")
    ap.add_argument("--tag", default="PHASE", help="prefix of the lines it prints")
    ap.add_argument("--log", help="append COMMAND's output to this file instead of streaming it")
    ap.add_argument("--follow", action="append", default=[], help="another file whose growth is progress (repeatable)")
    ap.add_argument("command", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    command = a.command[1:] if a.command[:1] == ["--"] else a.command
    if not command:
        ap.error("no COMMAND after --")

    out = sys.stdout

    def say(text):
        out.write(f"{a.tag}-PROGRESS {a.name}: {text}\n")
        out.flush()

    log_file = open(a.log, "ab") if a.log else None
    started = time.monotonic()
    # No SIGTERM or SIGINT between starting the group and the handlers that pass them on to it.
    signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGTERM, signal.SIGINT])
    alive_r, alive_w = os.pipe()  # the guard's line to this process: EOF without a byte means it died
    proc = subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "--guard", str(alive_r), str(a.grace),
                             "--", *command], stdin=subprocess.DEVNULL,
                            stdout=log_file if log_file else subprocess.PIPE, stderr=subprocess.STDOUT,
                            start_new_session=True, pass_fds=(alive_r,))
    os.close(alive_r)
    if log_file:
        log_file.close()

    received = []

    def forward(signum, _frame):
        received.append(signum)
        signal_group(proc.pid, signum)

    signal.signal(signal.SIGTERM, forward)
    signal.signal(signal.SIGINT, forward)
    signal.pthread_sigmask(signal.SIG_UNBLOCK, [signal.SIGTERM, signal.SIGINT])

    watched = [p for p in ([a.log] if a.log else []) + a.follow]
    states = {p: file_state(p) for p in watched}
    latest = {"line": "", "at": started}  # the newest output and when it came
    printed_at = started
    pipe = proc.stdout
    partial = b""
    exited_at = None

    def note_file_growth(now):
        grew = False
        for p in watched:
            s = file_state(p)
            if s != states[p]:
                states[p] = s
                grew = True
                line = last_line(p)
                if line:
                    latest["line"] = f"{os.path.basename(p)}: {line}"
        if grew:
            latest["at"] = now

    def fail(kind, why):
        line = latest["line"] or "(none)"
        out.write(f"{a.tag}-{kind} {a.name}: {why}; latest output: {line}\n")
        out.flush()
        end_group(proc, a.grace, say)
        return TIMED_OUT

    while True:
        if pipe is not None:
            ready, _, _ = select.select([pipe], [], [], 1.0)
            if ready:
                chunk = os.read(pipe.fileno(), 65536)
                if not chunk:
                    pipe = None
                else:
                    now = time.monotonic()
                    data = partial + chunk
                    *lines, partial = data.split(b"\n")
                    for raw in lines:
                        out.write(raw.decode("utf-8", "replace") + "\n")
                        clean = ANSI.sub("", raw.decode("utf-8", "replace")).strip()
                        if clean:
                            latest["line"] = clean[:240]
                    out.flush()
                    latest["at"] = now
                    if lines:
                        printed_at = now
        else:
            time.sleep(1.0 if proc.poll() is None else 0)
        now = time.monotonic()
        note_file_growth(now)
        if proc.poll() is not None:
            if pipe is None:
                break
            exited_at = exited_at or now
            if now - exited_at > 2:  # a process COMMAND left behind holds the pipe open
                break
        if received:
            end_group(proc, a.grace, say)
            return 128 + received[0]
        elapsed = now - started
        quiet = now - latest["at"]
        if elapsed > a.deadline:
            return fail("TIMEOUT", f"still running after {elapsed:.0f} s (deadline {a.deadline:.0f} s)")
        if a.stall and quiet > a.stall:
            return fail("STALL", f"no output for {quiet:.0f} s (stall limit {a.stall:.0f} s), {elapsed:.0f} s in")
        if now - printed_at >= a.heartbeat:
            say(f"{elapsed:.0f} s, output {quiet:.0f} s ago: {latest['line'] or '(none yet)'}")
            printed_at = now
    if partial:
        out.write(partial.decode("utf-8", "replace") + "\n")
        out.flush()
    code = proc.wait()
    return code if code >= 0 else 128 - code


if __name__ == "__main__":
    sys.exit(main())
