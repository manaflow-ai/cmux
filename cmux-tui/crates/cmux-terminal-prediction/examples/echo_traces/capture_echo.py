#!/usr/bin/env python3
"""Record what a program writes back for each typed key, in a real pty.

capture_echo.py NAME OUT.json -- CMD...

Spawns CMD in a 100x32 pty, waits for the screen to go quiet, then types TEXT
one key at a time; after each key it records every byte the program wrote
until it is quiet for QUIET seconds. Output JSON: {"name", "cols", "rows",
"preamble": hex of everything before the first key, "keys": [{"key": "a",
"echo": hex}...]}. Ends by sending Ctrl-U (clear the line) and killing CMD.
"""
import json, os, pty, select, signal, struct, sys, time, fcntl, termios

TEXT = "fix the lag when typing on lte now please"
QUIET = float(os.environ.get("QUIET", "0.35"))
SETTLE = float(os.environ.get("SETTLE", "6"))


def read_until_quiet(fd, quiet, limit):
    out = bytearray()
    end = time.time() + limit
    last = time.time()
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
            last = time.time()
        elif out and time.time() - last >= quiet:
            break
        elif not out and time.time() - last >= quiet * 3:
            break
    return bytes(out)


def main():
    name, path = sys.argv[1], sys.argv[2]
    cmd = sys.argv[sys.argv.index("--") + 1:]
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execvp(cmd[0], cmd)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))
    preamble = read_until_quiet(fd, 1.5, SETTLE + 20)
    # SETUP: keys to get past first-run screens, comma-separated, \r for Enter;
    # each is followed by a quiet wait, and its output joins the preamble.
    for step in filter(None, os.environ.get("SETUP", "").split(",")):
        if step == "WAIT":
            time.sleep(8)
            preamble += read_until_quiet(fd, 1.5, 3)
            continue
        os.write(fd, step.encode().decode("unicode_escape").encode())
        preamble += read_until_quiet(fd, 1.5, SETTLE + 20)
    # PROMPT: a message sent (with Enter) before typing, so the program is
    # busy printing while the keys go in (duress). Keys then go at a fixed
    # GAP, and each key's "echo" is everything printed until the next key.
    prompt = os.environ.get("PROMPT")
    gap = float(os.environ.get("GAP", "0"))
    if prompt:
        os.write(fd, prompt.encode())
        time.sleep(0.5)
        os.write(fd, b"\r")
        preamble += read_until_quiet(fd, 30, float(os.environ.get("BUSY_AFTER", "4")))
    keys = []
    for ch in TEXT:
        os.write(fd, ch.encode())  # EIO here also means the program exited
        if gap:
            echo = bytearray()
            end = time.time() + gap
            while time.time() < end:
                r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
                if r:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        chunk = b""
                    if not chunk:
                        sys.exit(f"{name}: program exited at key {len(keys)}; last output {bytes(echo)[-300:]!r} {preamble[-300:]!r}")
                    echo += chunk
            echo = bytes(echo)
        else:
            echo = read_until_quiet(fd, QUIET, 5)
        keys.append({"key": ch, "echo": echo.hex()})
    os.write(fd, b"\x15")
    read_until_quiet(fd, QUIET, 2)
    os.kill(pid, signal.SIGKILL)
    json.dump({"name": name, "cols": 100, "rows": 32, "preamble": preamble.hex(), "keys": keys},
              open(path, "w"), indent=0)
    empty = sum(1 for k in keys if not k["echo"])
    sizes = sorted(len(k["echo"]) // 2 for k in keys)
    print(f"{name}: {len(keys)} keys, {empty} without echo, echo bytes p50 {sizes[len(sizes)//2]} max {sizes[-1]}, preamble {len(preamble)} B")


if __name__ == "__main__":
    main()
