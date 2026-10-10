#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The Computer Use helper v2 socket as a real process (bead cx-insb): this
# script starts the built cmux-cua-helper with a control pipe, as the cmux
# app does, and drives its socket from a second process (python3).
# Covers:
# - the socket goes in this user's Darwin temp dir (confstr
#   _CS_DARWIN_USER_TEMP_DIR): directory 0700, socket 0600, owned by us;
# - a socket path outside that dir and /tmp is refused;
# - under /tmp, a group/other-writable directory on the way is refused, a
#   fresh chain is created 0700;
# - a symlink on the way is refused;
# - a same-user client that is not acpmux gets past the uid gate and is
#   refused by code identity (unknown_code), before it sends a byte;
# - stdin EOF removes the socket.
# The other-user client case needs a second account (bead cx-8coo).
# macOS only; run on a fleet Mac or cmux-lawrence-2:
#   swift build --package-path Packages/macOS/CmuxComputerUseHelper
#   scripts/cmux-next/tests/cua-helper-socket.test.sh [path/to/cmux-cua-helper]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HELPER=${1:-"$ROOT/Packages/macOS/CmuxComputerUseHelper/.build/debug/cmux-cua-helper"}
[ -x "$HELPER" ] || { echo "FAIL: no helper at $HELPER (swift build first)" >&2; exit 1; }
exec /usr/bin/python3 -I - "$HELPER" <<'PY'
import json, os, socket, stat, subprocess, sys, uuid

helper = sys.argv[1]
failures = []
cleanup = []

def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)

def user_temp():
    path = subprocess.run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True,
                          text=True, check=True).stdout.strip()
    return path.rstrip("/")

def start(socket_path):
    proc = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL)
    msg = {"type": "configure", "socket": socket_path, "secret": "ab" * 32,
           "acpmux_cdhashes": [], "acpmux_requirement": None}
    proc.stdin.write((json.dumps(msg) + "\n").encode())
    proc.stdin.flush()
    line = proc.stdout.readline()
    return proc, (json.loads(line) if line else {})

def stop(proc):
    proc.stdin.close()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    return proc.returncode

tag = "cuat-" + uuid.uuid4().hex[:8]
me = os.geteuid()

# 1. The Darwin per-user temp dir.
base = os.path.join(user_temp(), tag)
cleanup.append(base)
sock = os.path.join(base, "s", "h.sock")
check(len(sock.encode()) < 104, f"socket path fits sun_path ({len(sock.encode())} bytes)")
proc, ready = start(sock)
check(ready.get("type") == "ready" and ready.get("socket") == sock, f"ready in the user temp dir: {ready}")
if ready.get("type") == "ready":
    d = os.lstat(os.path.dirname(sock))
    s = os.lstat(sock)
    check(stat.S_ISDIR(d.st_mode) and d.st_uid == me and stat.S_IMODE(d.st_mode) == 0o700,
          f"socket directory is ours and 0700 ({oct(stat.S_IMODE(d.st_mode))})")
    check(stat.S_ISSOCK(s.st_mode) and s.st_uid == me and stat.S_IMODE(s.st_mode) == 0o600,
          f"socket is ours and 0600 ({oct(stat.S_IMODE(s.st_mode))})")
    # A second process of this user that is not acpmux: refused by code
    # identity at accept, before it sends anything.
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(10)
    client.connect(sock)
    reply = json.loads(client.makefile().readline() or "{}")
    client.close()
    # unknown_code for a signed client; invalid_signature if its signature
    # does not validate. Never foreign_user: the uid gate passes for us.
    check(reply.get("error") == "refused" and reply.get("reason") in ("unknown_code", "invalid_signature"),
          f"same-user non-acpmux client refused by code identity: {reply}")
code = stop(proc)
check(code == 0 and not os.path.exists(sock), f"stdin EOF: exit {code}, socket removed")

# 2. Outside the user temp dir and /tmp.
outside = os.path.join(os.path.expanduser("~"), "." + tag, "h.sock")
cleanup.append(os.path.dirname(outside))
proc, reply = start(outside)
check(reply.get("type") == "error" and "socket did not start" in reply.get("error", ""),
      f"path outside the allowed roots refused: {reply}")
stop(proc)

# 3. /tmp fallback: a shared-writable directory on the way is refused.
shared = os.path.join("/tmp", tag + "-w")
cleanup.append(shared)
os.mkdir(shared)
os.chmod(shared, 0o777)
proc, reply = start(os.path.join(shared, "s", "h.sock"))
check(reply.get("type") == "error", f"/tmp chain with a 0777 directory refused: {reply}")
stop(proc)

# 4. /tmp fallback: a fresh chain is created private.
fresh = os.path.join("/tmp", tag + "-p")
cleanup.append(fresh)
sock = os.path.join(fresh, "s", "h.sock")
proc, ready = start(sock)
check(ready.get("type") == "ready", f"fresh /tmp chain accepted: {ready}")
if ready.get("type") == "ready":
    modes = [stat.S_IMODE(os.lstat(p).st_mode) for p in (fresh, os.path.dirname(sock))]
    check(modes == [0o700, 0o700], f"/tmp chain directories are 0700: {[oct(m) for m in modes]}")
stop(proc)

# 5. A symlink on the way (in the user temp dir) is refused.
target = os.path.join(user_temp(), tag + "-t")
link = os.path.join(user_temp(), tag + "-l")
cleanup += [target, link]
os.mkdir(target, 0o700)
os.symlink(target, link)
proc, reply = start(os.path.join(link, "s", "h.sock"))
check(reply.get("type") == "error", f"symlink in the chain refused: {reply}")
stop(proc)

for path in cleanup:
    if os.path.islink(path):
        os.unlink(path)
    elif os.path.isdir(path):
        subprocess.run(["rm", "-rf", path], check=False)

if failures:
    print(f"cua-helper-socket.test.sh: {len(failures)} failed", file=sys.stderr)
    sys.exit(1)
print("cua-helper-socket.test.sh: ok")
PY
