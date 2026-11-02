#!/usr/bin/env python3
"""Live proof that a Chief has one name on every surface (issue 26393), on a scratch Chief home
(cmux-lawrence-2, an --app-from-fleet GUI job). Before the fix a header rename set only the
conversation title: the header said "Mario", the Home list's tile kept the registry's "Chief".

Steps (`debug.home` `chief_names`: each Chief's tile, header and tab names; `rename_chief` through
`debug.home.api` is the header card's rename):
  1. launch the tagged app, show Home, wait for the Chief's conversation and its record name;
  2. rename it "Mario" from the header card: the tile shows "Mario" at once, then the tile, the
     header and the tab all say "Mario" with no rename left pending, the registry record says
     "Mario" (`cmux chief get`) and the owner retitled the conversation "Mario";
  3. rename the record from the CLI (`cmux chief edit --name Luigi`): every surface follows;
  4. undo that (`cmux chief undo`): every surface shows "Mario" again (a settled rename never
     comes back over the record);
  5. a name the registry refuses (101 characters): the card's rename fails and every surface
     keeps "Mario".
Ends with quitEndSessions and `cmux chief shutdown` for the scratch home. Writes report.json.

Exit: 0 all passed; 1 a step failed.
Usage: chief-name-sync-live.py --tag TAG --app APP [--deadline 60] [--out DIR]
"""
import argparse, json, os, shutil, socket, subprocess, sys, tempfile, time

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
    check((renamed or {}).get("ok") is True, "step 2: the header card's rename saved", reply=renamed)
    check(surfaces(conv)["tile"] == "Mario", "step 2: the tile shows the new name at once", seen=surfaces(conv))
    seen = all_say(conv, "Mario")
    check(seen, "step 2: tile, header and tab say Mario, nothing pending", seen=surfaces(conv))
    check(record_name() == "Mario", "step 2: the registry record says Mario", record=record_name())
    check(wait(lambda: surfaces(conv)["title"] == "Mario", opts.deadline), "step 2: the owner retitled the conversation",
          seen=surfaces(conv))

    code, out = cli("chief", "edit", "agent_mux", "--name", "Luigi")
    check(code == 0, "step 3: cmux chief edit --name Luigi", out=out[:300])
    check(all_say(conv, "Luigi"), "step 3: every surface follows the record to Luigi", seen=surfaces(conv))

    code, out = cli("chief", "undo", "agent_mux")
    check(code == 0, "step 4: cmux chief undo", out=out[:300])
    check(all_say(conv, "Mario"), "step 4: every surface shows Mario again after the undo", seen=surfaces(conv))

    refused = rpc("debug.home.api", {"call": "rename_chief", "conversation": conv, "name": "x" * 101})
    check((refused or {}).get("ok") is False, "step 5: a 101-character name is refused", reply=refused)
    check(all_say(conv, "Mario"), "step 5: every surface keeps Mario", seen=surfaces(conv))
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
