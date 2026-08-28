# Repro harness for https://github.com/manaflow-ai/cmux/issues/10431.
#
# Restores the smoke step that pasted a ~818-byte python heredoc into the
# TUI's shell as raw pty keystrokes, loops it under CPU load, and stops at
# the first iteration where the OSC 11 reply never appears. Run with
# CMUX_TUI_INPUT_AUDIT=<file> and CMUX_TUI_INPUT_AUDIT_ALLOW_SENSITIVE=1 so the
# TUI logs its byte-accounting taps; on
# failure this script prints the screen, the exact bytes it wrote, and where
# the audit says the bytes died.
#
# Env:
#   CMUX_TUI_BIN     path to the cmux-tui binary (default target/debug/cmux-tui)
#   REPRO_ITERS      paste iterations (default 30)
#   REPRO_LOAD       busy-spin worker count (default: os.cpu_count())
#   CMUX_TUI_INPUT_AUDIT  audit file the TUI appends taps to (recommended)
#   CMUX_TUI_INPUT_AUDIT_ALLOW_SENSITIVE  must be `1` to record raw bytes

import json
import multiprocessing
import os
import pty
import re
import select
import signal
import socket
import subprocess
import sys
import tempfile
import time

BIN = os.path.abspath(os.environ.get("CMUX_TUI_BIN", "target/debug/cmux-tui"))
SESSION = f"repro10431-{os.getpid()}"
CONTROL_SOCKET_RE = re.compile(r"control socket at (.+)$")
ITERS = int(os.environ.get("REPRO_ITERS", "30"))
LOAD = int(os.environ.get("REPRO_LOAD", str(os.cpu_count() or 4)))
AUDIT = os.environ.get("CMUX_TUI_INPUT_AUDIT")
if AUDIT and os.environ.get("CMUX_TUI_INPUT_AUDIT_ALLOW_SENSITIVE") != "1":
    raise SystemExit(
        "set CMUX_TUI_INPUT_AUDIT_ALLOW_SENSITIVE=1 before recording raw input bytes"
    )


def write_all(fd, data):
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError("PTY write made no progress")
        view = view[written:]


def wait_for_control_socket(server, seconds=30):
    deadline = time.monotonic() + seconds
    output = []
    while time.monotonic() < deadline:
        if server.poll() is not None:
            rest = server.stdout.read() or ""
            if rest:
                output.append(rest)
            break
        wait = min(0.1, max(0.0, deadline - time.monotonic()))
        readable, _, _ = select.select([server.stdout], [], [], wait)
        if not readable:
            continue
        line = server.stdout.readline()
        if not line:
            continue
        output.append(line)
        match = CONTROL_SOCKET_RE.search(line.strip())
        if match:
            path = match.group(1)
            socket_deadline = time.monotonic() + 5
            while time.monotonic() < socket_deadline:
                if os.path.exists(path):
                    return path
                if server.poll() is not None:
                    break
                time.sleep(0.05)
            raise AssertionError(f"control socket line found but socket missing at {path}")
    raise AssertionError("no control socket: " + "".join(output)[-2000:])


def stop_process(process):
    if process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def discover_socket_path():
    probe = subprocess.Popen(
        [BIN, "--headless", "--session", SESSION],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    path = None
    try:
        path = wait_for_control_socket(probe)
        return path
    finally:
        stop_process(probe)
        if path and os.path.exists(path):
            os.unlink(path)


SOCK = discover_socket_path()


def rpc(cmd):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(15)
    s.connect(SOCK)
    s.sendall((json.dumps(cmd) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf)


def spin_worker():
    x = 0
    while True:
        x = (x * 1103515245 + 12345) & 0xFFFFFFFF


load_procs = []


def start_load():
    for _ in range(LOAD):
        p = multiprocessing.Process(target=spin_worker, daemon=True)
        p.start()
        load_procs.append(p)
    print(f"load: {LOAD} spin workers")

tmpdir = tempfile.TemporaryDirectory(prefix="cmux-tui-repro10431-")

pid, fd = pty.fork()
if pid == 0:
    os.chdir(tmpdir.name)
    os.environ["TERM"] = "xterm-256color"
    os.environ["SHELL"] = os.environ.get("REPRO_SHELL", "/bin/sh")
    os.environ["HOME"] = tmpdir.name
    os.environ["CMUX_MUX_CDP_URL"] = "http://127.0.0.1:1/"
    os.environ.pop("NO_COLOR", None)
    os.execv(BIN, [BIN, "--session", SESSION, "--socket", SOCK, "--ephemeral"])

import fcntl
import struct
import termios

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
os.kill(pid, signal.SIGWINCH)

output = b""
probe_pending = b""
keyboard_probe_answers = 0


def answer_host_color_queries(chunk):
    global probe_pending
    probe_pending += chunk
    while True:
        start = probe_pending.find(b"\x1b]")
        if start < 0:
            probe_pending = probe_pending[-1:]
            return
        if start > 0:
            probe_pending = probe_pending[start:]
        bel = probe_pending.find(b"\x07", 2)
        st = probe_pending.find(b"\x1b\\", 2)
        ends = [(bel, b"\x07"), (st, b"\x1b\\")]
        ends = [e for e in ends if e[0] >= 0]
        if not ends:
            probe_pending = probe_pending[-64:]
            return
        end, terminator = min(ends, key=lambda e: e[0])
        seq = probe_pending[:end]
        if seq == b"\x1b]10;?":
            write_all(fd, b"\x1b]10;rgb:d8d8/d9d9/dada" + terminator)
        elif seq == b"\x1b]11;?":
            write_all(fd, b"\x1b]11;rgb:1313/1414/1515" + terminator)
        probe_pending = probe_pending[end + len(terminator):]


def drain(seconds):
    global output, keyboard_probe_answers
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, 65536)
                output += chunk
                keyboard_queries = output.count(b"\x1b[?u")
                while keyboard_probe_answers < keyboard_queries:
                    write_all(fd, b"\x1b[?29u")
                    keyboard_probe_answers += 1
                answer_host_color_queries(chunk)
            except OSError:
                break


def read_screen(surface_id):
    return rpc({"id": 300, "cmd": "read-screen", "surface": surface_id})["data"]["text"]


def wait_screen(surface_id, needle, seconds=45, absent=False):
    deadline = time.monotonic() + seconds
    last = ""
    while time.monotonic() < deadline:
        drain(0.2)
        last = read_screen(surface_id)
        if (needle in last) != absent:
            return last, True
    return last, False


def first_surface():
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        drain(0.2)
        workspaces = rpc({"id": 999, "cmd": "list-workspaces"})["data"]["workspaces"]
        for workspace in workspaces:
            for screen in workspace["screens"]:
                for pane in screen["panes"]:
                    for tab in pane["tabs"]:
                        return tab["surface"]
    raise AssertionError("no surface appeared")


surface_id = first_surface()
write_all(fd, b"printf 'ready-%s\\n' ok\r")
screen, ok = wait_screen(surface_id, "ready-ok")
assert ok, screen[-500:]
print("shell ready")

# Optional one-time setup command typed into the shell (e.g. 'stty -ixon'
# for the kernel IXON-lookahead A/B experiment).
SETUP = os.environ.get("REPRO_SETUP")
if SETUP:
    write_all(fd, SETUP.encode() + b"; printf 'setup-%s\\n' ok\r")
    screen, ok = wait_screen(surface_id, "setup-ok")
    assert ok, screen[-500:]
    print(f"setup ran: {SETUP}")

inner_osc_query = """python3 - <<'PY'
import os, select, termios, time, tty
fd = os.open('/dev/tty', os.O_RDWR)
old = termios.tcgetattr(fd)
try:
    tty.setraw(fd)
    os.write(fd, b'\\x1b]11;?\\x1b\\\\')
    data = b''
    # Generous deadline: the shell may still be consuming the pasted
    # heredoc and the TUI coalesces frames (this raced at 2s, and 8s
    # still fails on saturated CI runners).
    end = time.monotonic() + 30
    while time.monotonic() < end and not (data.endswith(b'\\x1b\\\\') or data.endswith(b'\\x07')):
        r, _, _ = select.select([fd], [], [], max(0, end - time.monotonic()))
        if not r:
            break
        data += os.read(fd, 128)
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    os.close(fd)
print(data.decode('ascii', 'ignore').replace('\\x1b', '<ESC>').replace('\\x07', '<BEL>'))
PY
"""
PASTE = inner_osc_query.replace("\n", "\r").encode()
print(f"paste is {len(PASTE)} bytes")

# capture mode (REPRO_CAPTURE=1): same heredoc body, but the shell writes it
# to a file so the exact bytes the inner shell received (tap T4) can be
# diffed afterwards. The file lives in a fresh private directory (mkdtemp)
# so a predictable, symlinkable path is never written through. Pass the
# printed path to analyze-10431-audit.py via REPRO_CAPTURE.
CAPTURE = None
if os.environ.get("REPRO_CAPTURE"):
    CAPTURE = os.path.join(
        tempfile.mkdtemp(prefix="repro10431-cap-"), "paste-cap.txt"
    )
EXPECT_BODY = None
if CAPTURE:
    body = inner_osc_query.split("\n", 1)[1]
    body = body[: body.rindex("PY\n") + len("PY\n")]
    tail = "printf 'CAPTURE-%s\\n' done\n"
    PASTE = (f"cat > {CAPTURE} <<'PY'\n" + body + tail).replace("\n", "\r").encode()
    EXPECT_BODY = body[: body.rindex("PY\n")]
    print(f"capture mode: paste is {len(PASTE)} bytes, capture file {CAPTURE}")


def audit_mark(marker):
    # Create 0600 like the TUI's audit writer; the writer refuses an audit
    # file with group/other permission bits (it captures raw keystrokes).
    if AUDIT:
        fd = os.open(AUDIT, os.O_CREAT | os.O_WRONLY | os.O_APPEND, 0o600)
        try:
            os.write(fd, f"0 harness {marker} -\n".encode())
        finally:
            os.close(fd)


SUCCESS_NEEDLE = "CAPTURE-done" if CAPTURE else "1313/1414/1515"

start_load()


def dump_tui_death(iteration):
    print(f"iteration {iteration}: TUI/control socket died mid-iteration")
    drain(1.0)
    try:
        done, status = os.waitpid(pid, os.WNOHANG)
        if done:
            print(f"TUI waitpid status: {status:#x} (exited={os.WIFEXITED(status)} "
                  f"code={os.WEXITSTATUS(status) if os.WIFEXITED(status) else '-'} "
                  f"signaled={os.WIFSIGNALED(status)} "
                  f"sig={os.WTERMSIG(status) if os.WIFSIGNALED(status) else '-'})")
        else:
            print("TUI process still running; socket alone vanished")
    except OSError as error:
        print(f"waitpid failed: {error}")
    print("---- last pty output (repr, tail 4000) ----")
    print(repr(output[-4000:]))
    print("---- end pty output ----")


failures = 0
for iteration in range(1, ITERS + 1):
    if CAPTURE and os.path.exists(CAPTURE):
        os.unlink(CAPTURE)
    audit_mark(f"iter-{iteration}-begin")
    try:
        write_all(fd, PASTE)
        screen, ok = wait_screen(surface_id, SUCCESS_NEEDLE, seconds=45)
    except (FileNotFoundError, ConnectionRefusedError, OSError) as error:
        audit_mark(f"iter-{iteration}-DIED")
        print(f"iteration {iteration}: rpc/pty error: {error!r}")
        dump_tui_death(iteration)
        failures += 1
        break
    if ok and CAPTURE:
        try:
            got = open(CAPTURE, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            got = "<missing capture file>"
        if got != EXPECT_BODY:
            ok = False
            print(f"iteration {iteration}: capture file diverges from paste")
            import difflib
            for line in difflib.unified_diff(
                EXPECT_BODY.splitlines(), got.splitlines(), "expected", "received", lineterm=""
            ):
                print(line)
    audit_mark(f"iter-{iteration}-{'ok' if ok else 'FAIL'}")
    if not ok:
        failures += 1
        print(f"iteration {iteration}: FAILURE")
        print("---- screen ----")
        print(screen)
        print("---- end screen ----")
        sys.stdout.flush()
        break
    # Interrupt any half-open heredoc state and clear for the next round.
    write_all(fd, b"\x03")
    drain(0.3)
    write_all(fd, b"clear\r")
    screen, cleared = wait_screen(surface_id, SUCCESS_NEEDLE, seconds=15, absent=True)
    if not cleared:
        print(f"iteration {iteration}: screen did not clear; aborting")
        print(screen)
        break
    print(f"iteration {iteration}: ok")
    sys.stdout.flush()

write_all(fd, b"\x03")
drain(0.3)
rpc({"id": 1, "cmd": "shutdown"}) if False else None
os.kill(pid, signal.SIGTERM)
time.sleep(0.5)
try:
    os.kill(pid, signal.SIGKILL)
except ProcessLookupError:
    pass
for p in load_procs:
    p.terminate()

sys.exit(2 if failures else 0)
