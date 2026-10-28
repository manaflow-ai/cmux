#!/usr/bin/env python3
"""A remote shell that answers slowly, for bench-restore.py: a terminal running this behaves like an
ssh session to a far host. It starts /bin/sh in its own pty and relays bytes both ways, each chunk
DELAY_MS late, so a key's echo comes back one round trip later, as over a slow link.

  restore_slow_remote.py DELAY_MS [PROMPT]

Stdlib only. It never opens a network connection; it ends when the shell ends.
"""
import os
import pty
import select
import sys
import termios
import time
import tty


def main():
    delay = max(0, int(sys.argv[1] if len(sys.argv) > 1 else "150")) / 1000.0
    prompt = sys.argv[2] if len(sys.argv) > 2 else "remote$ "
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["PS1"] = prompt
        os.environ["ENV"] = ""
        os.execv("/bin/sh", ["/bin/sh", "-i"])
    stdin = sys.stdin.fileno()
    try:
        saved = termios.tcgetattr(stdin)
        tty.setraw(stdin)
    except termios.error:
        saved = None
    # (time due, fd to write, bytes), in arrival order per direction.
    queue = []
    try:
        while True:
            now = time.monotonic()
            due = [item for item in queue if item[0] <= now]
            for item in due:
                os.write(item[1], item[2])
                queue.remove(item)
            wait = min([item[0] for item in queue], default=now + 1.0) - now
            ready, _, _ = select.select([stdin, fd], [], [], max(0.0, wait))
            if stdin in ready:
                data = os.read(stdin, 4096)
                if not data:
                    break
                queue.append((time.monotonic() + delay, fd, data))
            if fd in ready:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    data = b""
                if not data:
                    break
                queue.append((time.monotonic() + delay, sys.stdout.fileno(), data))
    finally:
        if saved is not None:
            termios.tcsetattr(stdin, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main()
