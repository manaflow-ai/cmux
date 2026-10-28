#!/usr/bin/env python3
"""The program in each measured terminal of competitor-bench.py (pro audit 11). Never lands on its own.

Every app's shell (zsh with the bench's ZDOTDIR) execs this at its first prompt, so every terminal app runs the same
child: no app's own shell integration, prompt or plugins count. It connects to the bench (A11_SOCK), says hello with
its pid, tty, size and the terminal's own environment (its IPC socket names), puts the tty in cbreak mode and then:

  stdin   every byte typed (the app's input path, injected by the bench) is stamped (CLOCK_UPTIME_RAW ns), echoed at
          once to stdout and reported (`key`), so key-to-photon splits into input (send to here) and output (here to
          the frame).
  bench   one JSON command per line, answered with the time the work left (CLOCK_UPTIME_RAW ns):
            echo CH       write CH (output-to-photon)
            clear         clear the screen
            cat PATH      /bin/cat PATH to the terminal, seconds until cat exits (the terminal drained it)
            yes SECONDS   write "y\\n" blocks for SECONDS, bytes written (the terminal's drain rate)
            fill N        write N numbered 100-column lines (scrollback for reflow)
            stream R S    one line every 1/R s for S s, each line's write time (output scroll smoothness)
            csi8 R C      ask for an R x C window with xterm's CSI 8 t (apps with no IPC resize)
            size          the tty size
            exit          end (the terminal closes its tab)
  SIGWINCH  reported at once with the new size (`winch`).
"""
import fcntl
import json
import os
import select
import signal
import socket
import struct
import subprocess
import sys
import termios
import time
import tty

CLOCK = getattr(time, "CLOCK_UPTIME_RAW", time.CLOCK_MONOTONIC)


def now():
    return time.clock_gettime_ns(CLOCK)


def size():
    try:
        rows, cols, _x, _y = struct.unpack("HHHH", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\0" * 8))
        return cols, rows
    except OSError:
        return 0, 0


def write_all(data):
    view = memoryview(data)
    while view:
        try:
            n = os.write(1, view)
        except InterruptedError:
            continue
        view = view[n:]


ENV_KEYS = ("TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "KITTY_LISTEN_ON", "KITTY_WINDOW_ID", "KITTY_PID",
            "WEZTERM_UNIX_SOCKET", "WEZTERM_PANE", "ALACRITTY_SOCKET", "ALACRITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR",
            "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_SOCKET_PATH", "__CFBundleIdentifier")


def main():
    started = now()
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(os.environ["A11_SOCK"])

    def send(obj):
        sock.sendall((json.dumps(obj) + "\n").encode())

    winch = []
    signal.signal(signal.SIGWINCH, lambda *_: winch.append(now()))
    cols, rows = size()
    send({"ev": "hello", "pid": os.getpid(), "ppid": os.getppid(), "tty": os.ttyname(0) if os.isatty(0) else None,
          "t": started, "wall": time.time(), "cols": cols, "rows": rows,
          "env": {k: os.environ[k] for k in ENV_KEYS if k in os.environ}})
    try:
        saved = termios.tcgetattr(0)
        tty.setcbreak(0)  # no line buffering or kernel echo; output keeps ONLCR (cat and yes print real lines)
    except termios.error:
        saved = None
    write_all(b"ready> ")
    buf = b""
    try:
        while True:
            if winch:
                at = winch.pop(0)
                c, r = size()
                send({"ev": "winch", "t": at, "cols": c, "rows": r})
            try:
                ready, _, _ = select.select([0, sock], [], [], 0.5)
            except InterruptedError:
                continue
            if 0 in ready:
                data = os.read(0, 4096)
                at = now()
                if not data:
                    return
                write_all(data)
                send({"ev": "key", "t": at, "n": len(data), "b": data[:16].decode("latin-1")})
            if sock in ready:
                chunk = sock.recv(65536)
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if line.strip():
                        if handle(json.loads(line), send) == "exit":
                            return
    finally:
        if saved is not None:
            termios.tcsetattr(0, termios.TCSADRAIN, saved)


def handle(cmd, send):
    op, rid = cmd.get("op"), cmd.get("id")
    reply = {"ev": "done", "id": rid, "op": op}
    if op == "echo":
        data = cmd.get("ch", "x").encode()
        reply["t"] = now()
        write_all(data)
    elif op == "clear":
        write_all(b"\x1b[H\x1b[2J")
        reply["t"] = now()
    elif op == "cat":
        t0 = now()
        code = subprocess.call(["/bin/cat", cmd["path"]], stdin=subprocess.DEVNULL)
        reply.update(t0=t0, t=now(), code=code)
    elif op == "yes":
        block = b"y\n" * 8192
        t0 = now()
        end = t0 + int(float(cmd.get("seconds", 10)) * 1e9)
        sent = 0
        while now() < end:
            write_all(block)
            sent += len(block)
        reply.update(t0=t0, t=now(), bytes=sent)
    elif op == "fill":
        t0 = now()
        n = int(cmd.get("lines", 10000))
        pad = "abcdefghij" * 10
        out = []
        for i in range(n):
            out.append(f"{i:07d} {pad[: 92]}\r\n")
            if len(out) >= 500:
                write_all("".join(out).encode())
                out = []
        if out:
            write_all("".join(out).encode())
        reply.update(t0=t0, t=now())
    elif op == "stream":
        rate, seconds = float(cmd.get("rate", 60)), float(cmd.get("seconds", 5))
        period = int(1e9 / rate)
        start = now() + period
        times = []
        for k in range(int(rate * seconds)):
            when = start + k * period
            while now() < when:
                remaining = when - now()
                if remaining > 2_000_000:
                    time.sleep((remaining - 1_500_000) / 1e9)
            times.append(now())
            write_all(f"line {k:05d} {'=' * 60}\r\n".encode())
        reply.update(times=times, t=now())
    elif op == "csi8":
        write_all(f"\x1b[8;{int(cmd['rows'])};{int(cmd['cols'])}t".encode())
        reply["t"] = now()
    elif op == "size":
        reply["cols"], reply["rows"] = size()
        reply["t"] = now()
    elif op == "exit":
        send(reply)
        return "exit"
    else:
        reply["error"] = f"unknown op {op}"
    send(reply)
    return None


if __name__ == "__main__":
    sys.exit(main())
