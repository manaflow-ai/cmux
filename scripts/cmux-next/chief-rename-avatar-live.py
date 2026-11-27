#!/usr/bin/env python3
"""Live proof for issue 27915: renaming a Chief from its profile card saves, for the default Chief and
for a second Chief of this Mac (cmux-lawrence-2, an --app-from-fleet GUI job, scratch Chief home).
Before the fix the card said "The Chief's name could not be changed. Try again in a moment." and the
name stayed.

Steps (`rename_chief` through `debug.home.api` is the card's rename, HomeService.renameChief):
  1. launch the tagged app, show Home, wait for the default Chief's conversation;
  2. rename the default Chief "Mario": saved, the registry record says Mario;
  3. make a second Chief (`cmux chief new --name Ops`), wait for its conversation, rename it
     "Ops Desk" from its card: saved, its record says Ops Desk, every surface follows;
  4. a 101-character name is refused with the name rule, not "try again in a moment";
  5. a wide picture picked on the card opens Move and Scale; zoomed in and saved, the default
     Chief's registry record wears a new PNG picture.
Writes report.json. Exit: 0 all passed; 1 a step failed.
Usage: chief-rename-avatar-live.py --tag TAG --app APP [--deadline 60] [--out DIR]
"""
import argparse, json, os, shutil, socket, struct, subprocess, sys, tempfile, time, zlib

ap = argparse.ArgumentParser()
ap.add_argument("--tag", required=True)
ap.add_argument("--app", default=os.environ.get("NX_APP"))
ap.add_argument("--deadline", type=float, default=60)
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = ap.parse_args()
if not opts.app:
    sys.exit("chief-name-sync-live.py: --app or NX_APP is required")

TAG, APP = opts.tag, opts.app
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
DEBUG_SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
# A short path: the Chief home's sockets must fit sun_path (104 bytes).
SCRATCH = tempfile.mkdtemp(prefix="cns-", dir="/tmp")
HOME_DIR = os.path.join(SCRATCH, "chief")
os.makedirs(opts.out, exist_ok=True)
report = {"tag": TAG, "app": APP, "steps": []}
failures = []


def say(*parts):
    print(*parts, flush=True)


def check(ok, what, **seen):
    say(("ok   " if ok else "FAIL ") + what, json.dumps(seen) if seen else "")
    report["steps"].append({"ok": bool(ok), "what": what, **seen})
    if not ok:
        failures.append(what)
    return ok


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(DEBUG_SOCKET)
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


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return predicate()


def cli(*args):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    done = subprocess.run([CLI, *args, "--chief-home", HOME_DIR], capture_output=True, text=True, timeout=60, env=env)
    return done.returncode, (done.stdout + done.stderr).strip()


def chief_conversation():
    rows = [c for c in (rpc("debug.home") or {}).get("conversations", []) if "agent_mux" in c.get("participants", [])]
    return rows[0] if rows else None


def surfaces(conversation):
    home = rpc("debug.home") or {}
    names = (home.get("chief_names") or {}).get(conversation) or {}
    title = next((c.get("title") for c in home.get("conversations", []) if c.get("id") == conversation), None)
    return {"tile": names.get("tile"), "header": names.get("header"), "tab": names.get("tab"),
            "pending": names.get("pending"), "title": title}


def all_say(conversation, name, settled=True):
    def holds():
        seen = surfaces(conversation)
        ok = seen["tile"] == name and seen["tab"] == name and seen["header"] == name
        return seen if ok and (not settled or seen["pending"] is False) else None
    return wait(holds, opts.deadline)


def record_name():
    code, out = cli("chief", "get", "agent_mux", "--json")
    try:
        value = json.loads(out)
        return (value.get("value") or value).get("display_name")
    except ValueError:
        return f"unreadable ({code}): {out[:200]}"


def record_avatar():
    code, out = cli("chief", "get", "agent_mux", "--json")
    try:
        value = json.loads(out)
        return (value.get("value") or value).get("avatar")
    except ValueError:
        return None


def wide_png(width, height):
    """A width x height RGB gradient as PNG bytes (no imaging library on the host)."""
    rows = b"".join(b"\x00" + b"".join(bytes((x * 255 // width, y * 255 // height, 160)) for x in range(width))
                    for y in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


keep = ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG")
env = {k: v for k, v in os.environ.items() if k in keep}
env.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_CHIEF_HOME": HOME_DIR})
config = os.path.join(SCRATCH, "cmux.json")
open(config, "w").write("{}")
env["CMUX_NEXT_CONFIG_FILE"] = config
# The temp home never pushes a memory backup or imports this host's old Chiefs.
os.makedirs(os.path.join(HOME_DIR, "optchat"), exist_ok=True)
open(os.path.join(HOME_DIR, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(HOME_DIR, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
try:
    if not check(wait(lambda: (rpc("debug.windows") or {}).get("windows"), 300), "step 1: the app came up"):
        raise SystemExit
    rpc("action.run", {"id": "home.show"})
    row = wait(chief_conversation, 180)
    if not check(row, "step 1: the Chief's conversation is listed"):
        raise SystemExit
    conv = row["id"]
    check(wait(lambda: surfaces(conv)["tile"], opts.deadline), "step 1: the Chief's record names its tile",
          seen=surfaces(conv), record=record_name())

    renamed = rpc("debug.home.api", {"call": "rename_chief", "conversation": conv, "name": "Mario"})
    check((renamed or {}).get("ok") is True, "step 2: the default Chief's rename saved", reply=renamed)
    check(wait(lambda: record_name() == "Mario", opts.deadline), "step 2: the registry record says Mario",
          record=record_name())

    code, out = cli("chief", "new", "--name", "Ops", "--json")
    check(code == 0, "step 3: cmux chief new --name Ops", out=out[:300])
    try:
        made = json.loads(out)
        ops = (made.get("value") or made).get("id")
    except ValueError:
        ops = None
    check(ops, "step 3: the new Chief has an id", out=out[:300])

    def ops_conversation():
        rows = [c for c in (rpc("debug.home") or {}).get("conversations", []) if ops and ops in c.get("participants", [])]
        return rows[0] if rows else None

    ops_row = wait(ops_conversation, 120)
    if check(ops_row, "step 3: the new Chief's conversation is listed", conversations=(rpc("debug.home") or {}).get("conversations")):
        ops_conv = ops_row["id"]
        renamed = rpc("debug.home.api", {"call": "rename_chief", "conversation": ops_conv, "name": "Ops Desk"})
        check((renamed or {}).get("ok") is True, "step 3: the second Chief's rename saved", reply=renamed)

        def ops_record():
            code, out = cli("chief", "get", ops, "--json")
            try:
                value = json.loads(out)
                return (value.get("value") or value).get("display_name")
            except ValueError:
                return None
        check(wait(lambda: ops_record() == "Ops Desk", opts.deadline), "step 3: its record says Ops Desk", record=ops_record())
        check(wait(lambda: surfaces(ops_conv)["tile"] == "Ops Desk", opts.deadline), "step 3: its tile says Ops Desk",
              seen=surfaces(ops_conv))

    refused = rpc("debug.home.api", {"call": "rename_chief", "conversation": conv, "name": "x" * 101})
    check((refused or {}).get("failure") == "invalidName", "step 4: a 101-character name is refused by the name rule",
          reply=refused)

    picture = os.path.join(SCRATCH, "wide.png")
    open(picture, "wb").write(wide_png(600, 300))
    before = record_avatar()
    edited = rpc("debug.home.api", {"call": "edit_picture", "conversation": conv, "path": picture, "zoom": 2, "save": True})
    check((edited or {}).get("opened") is True, "step 5: the picture opens in Move and Scale", reply=edited)
    check((edited or {}).get("saved") is True, "step 5: Save wrote the crop", reply=edited)
    after = wait(lambda: (lambda a: a if a and a != before else None)(record_avatar()), opts.deadline)
    check(after and after.get("media_type") == "image/png", "step 5: the registry record wears the new PNG",
          before=before, after=after)
except SystemExit:
    pass
finally:
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        say(f"app {app.pid} did not quit within 60 s; NX_APP_STOP ends it at job end")
    subprocess.run([CLI, "chief", "shutdown", "--chief-home", HOME_DIR], capture_output=True, timeout=90,
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")})
    report["result"] = "PASS" if not failures else "FAIL"
    report["failures"] = failures
    json.dump(report, open(os.path.join(opts.out, "report.json"), "w"), indent=2)
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", report["result"], failures)
sys.exit(0 if not failures else 1)
