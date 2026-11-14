"""Lines one SGR wheel report scrolls in Claude Code's full-screen renderer (claude-wheel-lines.sh).

argv: CLAUDE_BINARY VERSION VENDOR_DIR. Prints CCWHEEL lines; screen dumps go to the log.
"""
import glob
import json
import os
import pty
import re
import select
import shutil
import signal
import sys
import tempfile
import time
import uuid

binary, version, vendor = sys.argv[1], sys.argv[2], sys.argv[3]
for wheel in sorted(glob.glob(os.path.join(vendor, "*.whl"))):
    sys.path.insert(0, wheel)
import pyte  # noqa: E402

COLS, ROWS = 50, 45
LINES = 1500
MARK = re.compile(r"L(\d{4})")


def out(text):
    print(f"CCWHEEL version={version} {text}", flush=True)


root = tempfile.mkdtemp(prefix="ccw-")
home = os.path.join(root, "home")
config = os.path.join(home, ".claude")
cwd = os.path.realpath(os.path.join(root, "proj"))
os.makedirs(config)
os.makedirs(cwd)
key = "sk-ant-api03-" + "x" * 80
session = str(uuid.uuid4())
json.dump({
    "hasCompletedOnboarding": True, "theme": "dark", "numStartups": 10, "autoUpdates": False,
    "lastOnboardingVersion": version, "lastReleaseNotesSeen": version,
    "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []},
    "projects": {cwd: {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True,
                       "allowedTools": []}},
}, open(os.path.join(config, ".claude.json"), "w"))
json.dump({"renderer": "fullscreen"}, open(os.path.join(config, "settings.json"), "w"))
projdir = os.path.join(config, "projects", re.sub(r"[^A-Za-z0-9]", "-", cwd))
os.makedirs(projdir)
now = "2026-11-14T10:00:00.000Z"
records, parent = [], None
per = 300
for block in range(LINES // per):
    u = str(uuid.uuid4())
    records.append({"parentUuid": parent, "isSidechain": False, "type": "user", "userType": "external",
                    "message": {"role": "user", "content": f"part {block}"}, "uuid": u, "timestamp": now,
                    "cwd": cwd, "sessionId": session, "version": version, "entrypoint": "cli"})
    parent = u
    body = "\n".join(f"L{n:04d}" for n in range(block * per + 1, block * per + per + 1))
    a = str(uuid.uuid4())
    records.append({"parentUuid": parent, "isSidechain": False, "type": "assistant", "userType": "external",
                    "message": {"model": "claude-opus-5-5", "id": "msg_" + a.replace("-", ""), "type": "message",
                                "role": "assistant", "content": [{"type": "text", "text": "```\n" + body + "\n```"}],
                                "stop_reason": "end_turn", "stop_sequence": None,
                                "usage": {"input_tokens": 1, "output_tokens": 1}},
                    "uuid": a, "timestamp": now, "cwd": cwd, "sessionId": session, "version": version,
                    "entrypoint": "cli"})
    parent = a
with open(os.path.join(projdir, session + ".jsonl"), "w") as f:
    for r in records:
        f.write(json.dumps(r) + "\n")

env = {
    "HOME": home, "CLAUDE_CONFIG_DIR": config, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "TERM": "xterm-256color", "TERM_PROGRAM": "ghostty", "TERM_PROGRAM_VERSION": "1.3.0", "COLORTERM": "truecolor",
    "LANG": "en_US.UTF-8", "ANTHROPIC_API_KEY": key, "CLAUDE_CODE_NO_FLICKER": "1",
    "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1",
    "DISABLE_ERROR_REPORTING": "1", "CI": "", "USER": os.environ.get("USER", "ci"),
}
pid, fd = pty.fork()
if pid == 0:
    os.chdir(cwd)
    os.execve(binary, [binary, "--resume", session], env)

import fcntl  # noqa: E402
import struct  # noqa: E402
import termios  # noqa: E402
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
os.kill(pid, signal.SIGWINCH)

screen = pyte.Screen(COLS, ROWS)
stream = pyte.ByteStream(screen)
modes = set()
raw_tail = b""


def pump(seconds):
    global raw_tail
    end = time.monotonic() + seconds
    while True:
        left = end - time.monotonic()
        if left <= 0:
            return
        r, _, _ = select.select([fd], [], [], left)
        if not r:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            return
        if not data:
            return
        buf = raw_tail + data
        for m in re.finditer(rb"\x1b\[\?([\d;]+)([hl])", buf):
            for n in m.group(1).split(b";"):
                (modes.add if m.group(2) == b"h" else modes.discard)(int(n))
        # Replies a terminal gives (Ghostty-like).
        if re.search(rb"\x1b\[>0?q", buf):
            os.write(fd, b"\x1bP>|ghostty 1.3.0\x1b\\")
        if re.search(rb"\x1b\[0?c", buf):
            os.write(fd, b"\x1b[?62;22;52c")
        for _ in re.finditer(rb"\x1b\[6n", buf):
            y, x = screen.cursor.y + 1, screen.cursor.x + 1
            os.write(fd, f"\x1b[{y};{x}R".encode())
        for m in re.finditer(rb"\x1b\[\?(\d+)\$p", buf):
            os.write(fd, b"\x1b[?" + m.group(1) + b";2$y")
        for m in re.finditer(rb"\x1b\](1[01]);\?(\x07|\x1b\\)", buf):
            color = b"rgb:0000/0000/0000" if m.group(1) == b"11" else b"rgb:e6e6/e6e6/e6e6"
            os.write(fd, b"\x1b]" + m.group(1) + b";" + color + m.group(2))
        if re.search(rb"\x1b\[\?u", buf):
            os.write(fd, b"\x1b[?0u")
        raw_tail = buf[-16:]
        stream.feed(data)


def marks():
    return [int(n) for line in screen.display for n in MARK.findall(line)]


def top():
    m = marks()
    return min(m) if m else None


def dump(label):
    print(f"--- screen {version} {label} modes={sorted(modes)}")
    for line in screen.display:
        print("|" + line.rstrip())


def wheel(up=True, x=10, y=10):
    return f"\x1b[<{64 if up else 65};{x};{y}M".encode()


deadline = time.monotonic() + 60
while time.monotonic() < deadline:
    pump(1.0)
    if marks():
        break
pump(3)
dump("launched")
if not marks():
    out("result=no-transcript-on-screen")
    sys.exit(3)
out(f"launched top={top()} marks={len(marks())} modes={sorted(modes)}")


def measure(name, counts_per_write, gap_ms, writes, settle=1.8):
    pump(settle)
    before = top()
    t0 = time.monotonic()
    for i in range(writes):
        os.write(fd, wheel() * counts_per_write)
        target = t0 + (i + 1) * gap_ms / 1000.0
        while time.monotonic() < target:
            pump(max(0.0, min(0.004, target - time.monotonic())))
    pump(1.0)
    after = top()
    reports = counts_per_write * writes
    moved = (before - after) if before is not None and after is not None else None
    per = f"{moved / reports:.2f}" if moved is not None else "?"
    out(f"pattern={name} reports={reports} per_write={counts_per_write} gap_ms={gap_ms} "
        f"top_before={before} top_after={after} lines={moved} lines_per_report={per}")
    return moved


# Isolated reports: one each, 400 ms apart (no acceleration window).
for i in range(5):
    measure(f"isolated-{i}", 1, 400, 1, settle=0.6)
measure("isolated-x10-400ms", 1, 400, 10)
measure("x20-100ms", 1, 100, 20)
measure("x20-50ms", 1, 50, 20)
measure("x20-33ms", 1, 33, 20)
measure("x20-16ms", 1, 16, 20)
measure("x20-8ms", 1, 8, 20)
measure("x20-one-write", 20, 1, 1)
measure("phone-2perframe-x15-16ms", 2, 16, 15)
measure("phone-4per-write-x5-33ms", 4, 33, 5)
dump("end")
os.kill(pid, signal.SIGTERM)
time.sleep(0.5)
try:
    os.kill(pid, signal.SIGKILL)
except OSError:
    pass
shutil.rmtree(root, ignore_errors=True)
