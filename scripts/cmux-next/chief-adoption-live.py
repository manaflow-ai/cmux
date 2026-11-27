#!/usr/bin/env python3
"""Per-build isolation S6 (cx-is1kf.7), live on a GUI host, temp roots only.

Step 1, NIGHTLY adoption backup: the tagged DEV app A runs as NIGHTLY's Chief
build (CMUX_NEXT_CHIEF_BUILD_ID=com.cmuxterm.app.nightly) under a temp Chief
root whose default/ home already holds memory (optchat/adoption-marker.txt)
and a unix socket. On its first launch NIGHTLY clones default/ to
<root>/.backups/default-<UTC>/ (the socket skipped) and records it in
default/adopted.json {by, at, backup}. A second launch makes no new backup.

Step 2, the old per-tag Chief import (ChiefMigration) is NIGHTLY's only: A
launched with an explicit CMUX_NEXT_CHIEF_HOME (a test home of no build)
never runs it, so no migration.json appears in that home.

The test never resolves the host's real Chief, acpmux or daemon names; it
stops only what it started and removes its temp folders.
Both steps always run. Exit 0 on PASS, else the first failed step's number.
Usage: chief-adoption-live.py --tag TAG --app APP [--out DIR]
Submit the nx-remote job with --allow-agents: gui and input jobs default to ACPMUX_AGENT_LAUNCH=deny (cx-tgf4h).
"""
import argparse, glob, json, os, shutil, socket, stat, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--tag", required=True)
ap.add_argument("--app", required=True)
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = ap.parse_args()
# cx-tgf4h: nx-remote gui and input jobs run with ACPMUX_AGENT_LAUNCH=deny
# (HQ #2130), so no Chief turn can start; fail at once, not after a reply wait.
if os.environ.get("ACPMUX_AGENT_LAUNCH", "").strip().lower() == "deny" or os.environ.get("CMUX_AGENTS_DISABLED", "").strip() == "1":
    sys.exit("chief-adoption-live.py: this Chief proof needs agents; submit the job with `nx-remote --allow-agents` "
             "(ACPMUX_AGENT_LAUNCH=deny or CMUX_AGENTS_DISABLED=1 is set)")
os.makedirs(opts.out, exist_ok=True)

TAG = opts.tag
# Short paths: sockets must fit sun_path (104 bytes).
SCRATCH = tempfile.mkdtemp(prefix="cad-", dir="/tmp")
ROOT = os.path.join(SCRATCH, "chief")
DEFAULT = os.path.join(ROOT, "default")
EXPLICIT = os.path.join(SCRATCH, "explicit")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(opts.app, "Contents/Resources/bin/cmux")
ACPMUX = os.path.join(opts.app, "Contents/Resources/bin/acpmux")
CLEAN_ENV = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_", "XDG_RUNTIME"))}


def say(*parts):
    print(*parts, flush=True)


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def launch(extra, name, home):
    keep = ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR")
    env = {k: v for k, v in os.environ.items() if k in keep}
    config = os.path.join(SCRATCH, "cmux.json")
    open(config, "w").write("{}")
    env.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
                "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config,
                "CMUX_NEXT_ACPMUX_ROOT": os.path.join(SCRATCH, "acpmux")})
    env.update(extra)
    log = open(os.path.join(opts.out, f"app-{TAG}-{name}.log"), "a")
    proc = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log,
                            stdin=subprocess.DEVNULL)
    up = wait(lambda: (rpc("debug.windows") or {}).get("windows"), 300)
    say(f"A ({name}) pid {proc.pid}: {'up' if up else 'NOT UP'}")
    return proc if up else quit_app(proc, home)


def quit_app(proc, home):
    if proc and proc.poll() is None:
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            say(f"A pid {proc.pid} did not quit within 60 s")
    if home:
        # The Chief of `home`: its acpmux daemon and router, then brain and owner (documented stop).
        acpmux_home = os.path.join(home, "acpmux")
        subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env={**CLEAN_ENV, "ACPMUX_HOME": acpmux_home},
                       capture_output=True, timeout=30)
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(5)
            conn.connect(os.path.join(acpmux_home, "router", "router.sock"))
            conn.sendall(b'{"op":"shutdown"}\n')
            conn.recv(4096)
            conn.close()
        except OSError:
            pass
        subprocess.run([CLI, "chief", "shutdown", "--chief-home", home], env=CLEAN_ENV, capture_output=True, timeout=90)
    return None


def backups():
    return sorted(glob.glob(os.path.join(ROOT, ".backups", "default-*")))


def read_json(path):
    try:
        return json.load(open(path))
    except (OSError, ValueError):
        return None


# The NIGHTLY home holds memory, a socket, and a done migration record (the run
# never takes in this host's old per-tag Chiefs).
os.makedirs(os.path.join(DEFAULT, "optchat"), exist_ok=True)
open(os.path.join(DEFAULT, "optchat", "adoption-marker.txt"), "w").write(f"memory of {TAG}\n")
json.dump({"status": "done", "at": "test", "sources": []}, open(os.path.join(DEFAULT, "migration.json"), "w"))
seeded_socket = os.path.join(DEFAULT, "s.sock")
listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
listener.bind(seeded_socket)

failed = 0
proc = None
try:
    nightly = {"CMUX_NEXT_CHIEF_ROOT": ROOT, "CMUX_NEXT_CHIEF_BUILD_ID": "com.cmuxterm.app.nightly"}
    proc = launch(nightly, "nightly-1", DEFAULT)
    if not proc:
        failed = 1
        raise SystemExit
    record = wait(lambda: read_json(os.path.join(DEFAULT, "adopted.json")), 120)
    found = backups()
    copy = found[0] if found else None
    marker = bool(copy) and os.path.isfile(os.path.join(copy, "optchat", "adoption-marker.txt"))
    socket_copied = bool(copy) and os.path.lexists(os.path.join(copy, "s.sock"))
    say(f"step 1: adopted.json {record}; backups {found}; memory in backup {marker}; socket in backup {socket_copied}")
    proc = quit_app(proc, DEFAULT)
    proc = launch(nightly, "nightly-2", DEFAULT)
    if not proc:
        failed = 1
        raise SystemExit
    wait(lambda: False, 15)
    again = backups()
    record_2 = read_json(os.path.join(DEFAULT, "adopted.json"))
    say(f"step 1: after the second launch backups {again}; adopted.json {record_2}")
    proc = quit_app(proc, DEFAULT)
    if not (record and copy and record.get("backup") == copy and record.get("by") and record.get("at")
            and marker and not socket_copied and again == found and record_2 == record):
        failed = 1


    os.makedirs(EXPLICIT, exist_ok=True)
    # A scratch HOME too: code that still imports for this home reads no real
    # old per-tag Chief of this host (it finds none and records migration.json).
    scratch_home = os.path.join(SCRATCH, "home")
    os.makedirs(scratch_home, exist_ok=True)
    proc = launch({"CMUX_NEXT_CHIEF_HOME": EXPLICIT, "HOME": scratch_home, "CFFIXED_USER_HOME": scratch_home},
                  "explicit", EXPLICIT)
    if not proc:
        failed = failed or 2
        raise SystemExit
    # The import runs when the Chief owner first answers: wait for the owner.
    owner = wait(lambda: any(n.startswith("cmux-chief-") or n == "tui" for n in os.listdir(EXPLICIT)), 120)
    wait(lambda: os.path.exists(os.path.join(EXPLICIT, "migration.json")), 30)
    migrated = read_json(os.path.join(EXPLICIT, "migration.json"))
    say(f"step 2: explicit home {sorted(os.listdir(EXPLICIT))} (owner state {bool(owner)}); migration.json {migrated}")
    proc = quit_app(proc, EXPLICIT)
    if not owner or migrated is not None:
        failed = failed or 2
except SystemExit:
    pass
finally:
    if proc:
        quit_app(proc, EXPLICIT if os.path.isdir(EXPLICIT) else DEFAULT)
    listener.close()
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", "PASS" if failed == 0 else f"FAIL {failed}")
sys.exit(failed)
