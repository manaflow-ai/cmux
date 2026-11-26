# cmux-free control for issue 10431: pty.fork straight into /bin/sh, paste
# the same heredoc the smoke test used (optionally as 1-byte writes with a
# slow echo drain), and diff the capture file. If this loses bytes, the loss
# is in the kernel pty/line-discipline path plus dash, with no cmux code
# anywhere in the picture.
#
# Env: REPRO_ITERS (30), REPRO_LOAD (cpu count), REPRO_WRITE_CHUNK (1),
#      REPRO_ECHO_DELAY (0), REPRO_ECHO_READ (65536)

import difflib
import multiprocessing
import os
import pty
import select
import signal
import sys
import time

import tempfile

ITERS = int(os.environ.get("REPRO_ITERS", "30"))
LOAD = int(os.environ.get("REPRO_LOAD", str(os.cpu_count() or 4)))
WRITE_CHUNK = int(os.environ.get("REPRO_WRITE_CHUNK", "1"))
ECHO_DELAY = float(os.environ.get("REPRO_ECHO_DELAY", "0"))
ECHO_READ = int(os.environ.get("REPRO_ECHO_READ", "65536"))
# Fresh private directory: never write through a predictable /tmp path.
CAPTURE = os.path.join(tempfile.mkdtemp(prefix="repro10431-dash-"), "paste-cap.txt")

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
body = inner_osc_query.split("\n", 1)[1]
body = body[: body.rindex("PY\n") + len("PY\n")]
tail = "printf 'CAPTURE-%s\\n' done\n"
PASTE = (f"cat > {CAPTURE} <<'PY'\n" + body + tail).replace("\n", "\r").encode()
EXPECT_BODY = body[: body.rindex("PY\n")]


def spin_worker():
    x = 0
    while True:
        x = (x * 1103515245 + 12345) & 0xFFFFFFFF


for _ in range(LOAD):
    multiprocessing.Process(target=spin_worker, daemon=True).start()
print(f"load: {LOAD}; chunk={WRITE_CHUNK}; echo_delay={ECHO_DELAY}; echo_read={ECHO_READ}")

pid, fd = pty.fork()
if pid == 0:
    os.environ["TERM"] = "xterm-256color"
    os.execv("/bin/sh", ["/bin/sh", "-i"])

import fcntl
import struct
import termios

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

output = b""


def drain(seconds):
    global output
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            try:
                chunk = os.read(fd, ECHO_READ)
            except OSError:
                return
            output += chunk
            if ECHO_DELAY:
                time.sleep(ECHO_DELAY)


def write_all_chunked(data):
    view = memoryview(data)
    while view:
        n = os.write(fd, view[:WRITE_CHUNK])
        view = view[n:]


drain(1.0)
failures = 0
for iteration in range(1, ITERS + 1):
    if os.path.exists(CAPTURE):
        os.unlink(CAPTURE)
    write_all_chunked(PASTE)
    deadline = time.monotonic() + 45
    done = False
    while time.monotonic() < deadline:
        drain(0.2)
        if b"CAPTURE-done" in output:
            done = True
            break
    got = None
    if done:
        try:
            got = open(CAPTURE, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            got = "<missing>"
    if got == EXPECT_BODY:
        print(f"iteration {iteration}: ok")
    else:
        failures += 1
        print(f"iteration {iteration}: FAILURE (done={done})")
        if got is not None:
            for line in difflib.unified_diff(
                EXPECT_BODY.splitlines(), got.splitlines(), "expected", "received", lineterm=""
            ):
                print(line)
        else:
            print("---- raw pty tail ----")
            print(repr(output[-2000:]))
        write_all_chunked(b"\x03")
        drain(0.5)
    output = b""
    write_all_chunked(b"clear\r")
    drain(0.4)
    sys.stdout.flush()

try:
    os.kill(pid, signal.SIGTERM)
except ProcessLookupError:
    pass
print(f"{failures} failures / {ITERS} iterations")
sys.exit(2 if failures else 0)
