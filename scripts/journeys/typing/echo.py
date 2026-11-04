#!/usr/bin/env python3
"""The typing terminal's program for TYPING UNDER LOAD: reads the tty raw, echoes each key as a line editor does and
records every read with its time, so a round can check the order (nothing lost, doubled or out of order) and when each
key reached the PTY's reader.

    python3 echo.py LOG.jsonl

Echo: a printable byte prints itself; Backspace (0x7f or 0x08) prints "\\b \\b"; Left and Right arrows move the
cursor (ESC [ D / ESC [ C); Ctrl-C prints "^C" and a new line; Return prints a new line; a bracketed paste (ESC [ 200 ~
... ESC [ 201 ~) prints its text. Each read() is one record {"t": time.clock_gettime(time.CLOCK_UPTIME_RAW), "bytes":
hex, "n": count}: t is the moment the program got the bytes from the PTY, CLOCK_UPTIME_RAW seconds (the clock of the
driver's key post times, NSEvent.timestamp and the recorder's frames; not time.monotonic, STATUS 4763). Two keys in one
read are kept together (the judge calls that a merge when they were sent more than 2 refreshes apart).

Between a read and the next the program only echoes: the records stay in memory and go to LOG at the end, followed by
an end record {"t", "end": true, "why", "reads"}. Writing a log line per key before the echo held the next keys for up
to 428 ms under the 15 GB hog (REWRITE R-DAEMON-STATE, 2026-11-04): the measured wait was the program's, not the
terminal's. The end: Ctrl-D (0x04 outside a paste; the read's bytes before it are kept, the 0x04 and what follows are
not), the end of input, SIGTERM or SIGHUP. The ready line {"t", "ready": true, "pid"} is written at the start, before
the first read. Python 3.9 standard library only.
"""
import json
import os
import signal
import sys
import termios
import time
import tty


class Stop(Exception):
    """A signal that ends the program (SIGTERM, SIGHUP): the records are still written."""


def _stop(signum, _frame):
    raise Stop(signum)


def now():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def main():
    log = open(sys.argv[1], "a", buffering=1)
    records, why = [], "end of input"
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setraw(fd)
    out = sys.stdout.buffer
    out.write(b"\x1b[?2004h")  # bracketed paste on
    out.flush()
    log.write(json.dumps({"t": now(), "ready": True, "pid": os.getpid()}) + "\n")
    pending = b""
    pasting = False
    try:
        signal.signal(signal.SIGTERM, _stop)
        signal.signal(signal.SIGHUP, _stop)
        while True:
            try:
                data = os.read(fd, 4096)
            except OSError as error:  # the terminal is gone (EIO)
                why = f"read error {error.errno}"
                break
            t = now()
            if not data:
                break
            pending += data
            echo, stop = b"", False
            while pending:
                if pasting:
                    end = pending.find(b"\x1b[201~")
                    if end < 0:
                        # Keep a tail that may be the start of the end marker split across reads (review 6).
                        keep = next((k for k in range(min(5, len(pending)), 0, -1)
                                     if b"\x1b[201~".startswith(pending[-k:])), 0)
                        echo += pending[:len(pending) - keep]
                        pending = pending[len(pending) - keep:]
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
                    stop = True
                    break
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
            if stop:
                # The 0x04 is in this read (an earlier read leaves only an unfinished escape or paste end): keep the
                # bytes before it; it and what follows it are not typed keys.
                cut = len(data) - 1 - len(pending)
                if cut > 0:
                    records.append({"t": t, "bytes": data[:cut].hex(), "n": cut})
                why = "ctrl-d"
                break
            records.append({"t": t, "bytes": data.hex(), "n": len(data)})
    except Stop as error:
        why = f"signal {error.args[0]}"
    finally:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        try:
            log.write("".join(json.dumps(r) + "\n" for r in records)
                      + json.dumps({"t": now(), "end": True, "why": why, "reads": len(records)}) + "\n")
            log.close()
        finally:
            try:  # the tty may be gone (SIGHUP)
                out.write(b"\x1b[?2004l")
                out.flush()
                termios.tcsetattr(fd, termios.TCSADRAIN, old)
            except (OSError, termios.error):
                pass


if __name__ == "__main__":
    main()
