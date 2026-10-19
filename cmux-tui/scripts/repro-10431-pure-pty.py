# Pure-kernel control experiment for issue 10431: no cmux code involved.
#
# Creates a pty pair with the same termios the cmux-tui child shell has
# (ICANON|ECHO|ICRNL|IXON), forks a reader that consumes canonical lines
# from the slave (like dash collecting a heredoc), writes the same ~860-byte
# paste into the master in one write, drains the echo, and compares what the
# reader received against what was written. Run under CPU load.
#
# Env:
#   REPRO_ITERS  iterations (default 50)
#   REPRO_LOAD   busy-spin workers (default: cpu count)
#   REPRO_IXON   1 keeps IXON (default), 0 clears it
#   REPRO_READER_DELAY  seconds the reader sleeps between line reads (default 0.01)

import multiprocessing
import os
import select
import sys
import termios
import time

ITERS = int(os.environ.get("REPRO_ITERS", "50"))
LOAD = int(os.environ.get("REPRO_LOAD", str(os.cpu_count() or 4)))
KEEP_IXON = os.environ.get("REPRO_IXON", "1") == "1"
READER_DELAY = float(os.environ.get("REPRO_READER_DELAY", "0.01"))
# cmux-tui's pty-input worker delivers a paste as one merged chunk followed
# by hundreds of 1-byte writes; default mimics that. Set large (e.g. 65536)
# for a single-write control.
WRITE_CHUNK = int(os.environ.get("REPRO_WRITE_CHUNK", "1"))
# Echo backpressure: seconds to wait between master-side echo reads, and the
# read size. A busy TUI drains the child master slowly; 0 drains eagerly.
ECHO_DELAY = float(os.environ.get("REPRO_ECHO_DELAY", "0"))
ECHO_READ = int(os.environ.get("REPRO_ECHO_READ", "65536"))

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
EXPECTED = inner_osc_query.encode()  # after ICRNL, CR arrives as NL


def spin_worker():
    x = 0
    while True:
        x = (x * 1103515245 + 12345) & 0xFFFFFFFF


for _ in range(LOAD):
    multiprocessing.Process(target=spin_worker, daemon=True).start()
print(f"load: {LOAD} spin workers; ixon={KEEP_IXON}; reader delay {READER_DELAY}s")

failures = 0
for iteration in range(1, ITERS + 1):
    master, slave = os.openpty()
    import fcntl
    import struct
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    attrs = termios.tcgetattr(slave)
    # default openpty termios already has ICANON|ECHO|ICRNL|IXON on Linux;
    # assert the ones the experiment depends on, and toggle IXON as asked.
    if KEEP_IXON:
        attrs[0] |= termios.IXON
    else:
        attrs[0] &= ~termios.IXON
    attrs[0] |= termios.ICRNL
    attrs[3] |= termios.ICANON | termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, attrs)

    reader_done_r, reader_done_w = os.pipe()
    ps2 = os.environ.get("REPRO_PS2", "0") == "1"
    child = os.fork()
    if child == 0:
        os.close(master)
        os.close(reader_done_r)
        got = bytearray()
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and len(got) < len(EXPECTED):
            r, _, _ = select.select([slave], [], [], deadline - time.monotonic())
            if not r:
                break
            chunk = os.read(slave, 8192)
            if not chunk:
                break
            got.extend(chunk)
            if ps2:
                # dash writes a "> " continuation prompt to the tty between
                # canonical line reads while collecting a heredoc.
                os.write(slave, b"> ")
            if READER_DELAY:
                time.sleep(READER_DELAY)
        os.write(reader_done_w, bytes(got) + b"\x00DONE\x00")
        os.close(reader_done_w)
        os._exit(0)

    os.close(slave)
    os.close(reader_done_w)

    # Echo drainer: a separate thread reads the master like the TUI's reader
    # thread would, optionally slowly (echo backpressure).
    import threading

    echoed = bytearray()
    echo_stop = threading.Event()

    def drain_echo():
        while not echo_stop.is_set():
            r, _, _ = select.select([master], [], [], 0.2)
            if not r:
                continue
            try:
                chunk = os.read(master, ECHO_READ)
            except OSError:
                return
            if not chunk:
                return
            echoed.extend(chunk)
            if ECHO_DELAY:
                time.sleep(ECHO_DELAY)

    echo_thread = threading.Thread(target=drain_echo, daemon=True)
    echo_thread.start()

    view = memoryview(PASTE)
    if WRITE_CHUNK == 0:
        # cmux-tui's observed paste delivery: one large merged chunk, then
        # the remainder as rapid 1-byte writes (the corruption in the full
        # system clusters at exactly this seam).
        seam = int(os.environ.get("REPRO_SEAM", "512"))
        n = os.write(master, view[:seam])
        view = view[n:]
        while view:
            n = os.write(master, view[:1])
            view = view[n:]
    else:
        while view:
            n = os.write(master, view[:WRITE_CHUNK])
            view = view[n:]

    received = bytearray()
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline and not received.endswith(b"\x00DONE\x00"):
        r, _, _ = select.select([reader_done_r], [], [], 1.0)
        if reader_done_r in r:
            chunk = os.read(reader_done_r, 65536)
            if not chunk:
                break
            received.extend(chunk)
    os.close(reader_done_r)
    echo_stop.set()
    os.close(master)
    echo_thread.join(timeout=5)
    os.waitpid(child, 0)

    got = bytes(received)
    if got.endswith(b"\x00DONE\x00"):
        got = got[: -len(b"\x00DONE\x00")]
    if got == EXPECTED:
        print(f"iteration {iteration}: ok")
    else:
        failures += 1
        print(f"iteration {iteration}: FAILURE got {len(got)} expected {len(EXPECTED)}")
        import difflib
        m = difflib.SequenceMatcher(a=EXPECTED, b=got, autojunk=False)
        for op, a0, a1, b0, b1 in m.get_opcodes():
            if op == "equal":
                continue
            print(f"  {op}: expected[{a0}:{a1}]={EXPECTED[a0:a1]!r} got={got[b0:b1]!r}")
    sys.stdout.flush()

print(f"{failures} failures / {ITERS} iterations")
sys.exit(2 if failures else 0)
