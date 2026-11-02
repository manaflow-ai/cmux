#!/usr/bin/env python3
"""The typing terminal's program for TYPING UNDER LOAD: reads the tty raw, echoes each key as a line editor does and
logs every read with its time, so a round can check the order (nothing lost, doubled or out of order) and when each
key reached the PTY's reader.

    python3 echo.py LOG.jsonl

Echo: a printable byte prints itself; Backspace (0x7f or 0x08) prints "\\b \\b"; Left and Right arrows move the
cursor (ESC [ D / ESC [ C); Ctrl-C prints "^C" and a new line; Return prints a new line; a bracketed paste (ESC [ 200 ~
... ESC [ 201 ~) prints its text. Ctrl-D (0x04) ends it. Each read() is one log line {"t": time.monotonic(),
"bytes": hex, "n": count}: t is the moment the program got the bytes from the PTY (the same clock as the driver's
key post times and the recorder's frames on macOS). Two keys in one read are kept together (the judge calls that a
merge when they were sent more than 2 refreshes apart). Python 3.9 standard library only.
"""
import json
import os
import sys
import termios
import time
import tty


def main():
    log = open(sys.argv[1], "a", buffering=1)
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    out = sys.stdout.buffer
    out.write(b"\x1b[?2004h")  # bracketed paste on
    out.flush()
    log.write(json.dumps({"t": time.monotonic(), "ready": True, "pid": os.getpid()}) + "\n")
    pending = b""
    pasting = False
    try:
        while True:
            data = os.read(fd, 4096)
            now = time.monotonic()
            if not data:
                break
            log.write(json.dumps({"t": now, "bytes": data.hex(), "n": len(data)}) + "\n")
            pending += data
            echo = b""
            while pending:
                if pasting:
                    end = pending.find(b"\x1b[201~")
                    if end < 0:
                        echo += pending
                        pending = b""
                        break
                    echo += pending[:end]
                    pending = pending[end + 6:]
                    pasting = False
                    continue
                if pending.startswith(b"\x1b"):
                    if len(pending) < 3 and not pending.startswith(b"\x1b[2"):
                        break  # an escape not complete yet
                    if pending.startswith(b"\x1b[200~"):
                        pasting, pending = True, pending[6:]
                    elif pending.startswith(b"\x1b[D") or pending.startswith(b"\x1b[C"):
                        echo += pending[:3]
                        pending = pending[3:]
                    elif pending.startswith(b"\x1b[2") and len(pending) < 6:
                        break
                    else:
                        pending = pending[1:]  # another escape: drop its lead byte
                    continue
                b = pending[:1]
                pending = pending[1:]
                if b == b"\x04":
                    return
                if b in (b"\x7f", b"\x08"):
                    echo += b"\b \b"
                elif b == b"\x03":
                    echo += b"^C\r\n"
                elif b in (b"\r", b"\n"):
                    echo += b"\r\n"
                else:
                    echo += b
            if echo:
                out.write(echo)
                out.flush()
    finally:
        out.write(b"\x1b[?2004l")
        out.flush()
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
