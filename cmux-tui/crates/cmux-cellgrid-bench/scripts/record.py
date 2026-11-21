#!/usr/bin/env python3
"""Record a terminal workload as a timed trace for cmux-cellgrid-bench.

Runs WORKLOAD in a COLS x ROWS PTY and writes every read of its output, and
every key the recorder types, with a monotonic timestamp:

    magic  b"CGTRACE1"
    header u16 cols, u16 rows (little-endian)
    record u64 t_ns, u8 kind (0 = output, 1 = key), u32 len, len bytes

Workloads (each a real program, nothing synthetic on the output side):
    flood       `cat` of a ~2 MB source file, in a loop, for --seconds
    vim-idle    vim with syntax colours on a Rust file, then --seconds of no input
    vim-typing  vim as above, then `i` and 120 printable keys at 10 keys/s
    palette     the 256-colour palette and 24-bit ramps, then idle

Usage: record.py WORKLOAD OUT [--cols 120] [--rows 40] [--seconds 6] [--file PATH]
"""

import argparse
import fcntl
import os
import pty
import select
import struct
import termios
import time

MAGIC = b"CGTRACE1"


def now():
    return time.monotonic_ns()


def spawn(argv, cols, rows, env):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(argv[0], argv, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    return pid, fd


class Recorder:
    def __init__(self, out, fd, t0):
        self.out, self.fd, self.t0 = out, fd, t0

    def record(self, kind, data):
        self.out.write(struct.pack("<QBI", now() - self.t0, kind, len(data)))
        self.out.write(data)

    def pump(self, until_ns):
        """Read output until monotonic time until_ns; False once the program exits."""
        while True:
            left = until_ns - now()
            if left <= 0:
                return True
            ready, _, _ = select.select([self.fd], [], [], left / 1e9)
            if not ready:
                return True
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return False
            if not data:
                return False
            self.record(0, data)

    def key(self, data):
        self.record(1, data)
        os.write(self.fd, data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("workload", choices=["flood", "vim-idle", "vim-typing", "palette"])
    ap.add_argument("out")
    ap.add_argument("--cols", type=int, default=120)
    ap.add_argument("--rows", type=int, default=40)
    ap.add_argument("--seconds", type=float, default=6.0)
    ap.add_argument("--file", required=True, help="the source file vim opens and cat floods")
    a = ap.parse_args()

    env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", LANG="C.UTF-8")
    env.pop("TMUX", None)
    vim = ["vim", "-Nu", "NONE", "-i", "NONE", "-n", "-c", "syntax on", "-c", "set number", a.file]
    if a.workload == "flood":
        loop = f'end=$((SECONDS+{int(a.seconds)})); while [ $SECONDS -lt $end ]; do cat "$0"; done'
        argv = ["bash", "-c", loop, a.file]
    elif a.workload == "palette":
        script = (
            'for i in $(seq 0 255); do printf "\\e[48;5;%sm %3s \\e[0m" $i $i; '
            '[ $(((i+1)%16)) -eq 0 ] && echo; done; '
            'for c in 0 1 2; do for x in $(seq 0 4 255); do '
            'case $c in 0) r=$x g=0 b=0;; 1) r=0 g=$x b=0;; 2) r=0 g=0 b=$x;; esac; '
            'printf "\\e[38;2;%s;%s;%sm#\\e[0m" $r $g $b; done; echo; done; '
            f"sleep {a.seconds}"
        )
        argv = ["bash", "-c", script]
    else:
        argv = vim

    with open(a.out, "wb") as out:
        out.write(MAGIC + struct.pack("<HH", a.cols, a.rows))
        pid, fd = spawn(argv, a.cols, a.rows, env)
        rec = Recorder(out, fd, now())
        if a.workload in ("flood", "palette"):
            rec.pump(now() + int((a.seconds + 5) * 1e9))
        else:
            rec.pump(now() + 1_500_000_000)  # vim's first paint
            if a.workload == "vim-typing":
                rec.key(b"G")
                rec.pump(now() + 300_000_000)
                rec.key(b"o")
                rec.pump(now() + 300_000_000)
                text = b"let total = samples.iter().map(|s| s.bytes as u64).sum::<u64>(); // ok "
                for i in range(120):
                    rec.key(text[i % len(text) : i % len(text) + 1])
                    rec.pump(now() + 100_000_000)
                rec.key(b"\x1b")
            rec.pump(now() + int(a.seconds * 1e9))
            rec.key(b":qa!\r")
            rec.pump(now() + 1_000_000_000)
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)


if __name__ == "__main__":
    main()
