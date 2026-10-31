#!/usr/bin/env python3
"""Tagged-app check of where a chat opens in the docked Home (https://github.com/manaflow-ai/cmux/issues/27627).

Home makes a new transcript view each time the person picks a chat in its list (a Chief, a DM, a
channel), so the place has to come from the store. As in Messages:
- a chat opens at its newest message the first time;
- a chat left at its newest message opens at its newest message, with what came meanwhile;
- a chat left scrolled up opens on the rows the person was reading, where they were on screen,
  also when a message came meanwhile;
- a chat scrolled up and then back down opens at its newest message.

Two local channels with 60 messages each, through the real Home data path (`debug.home.api`), are
switched with `home.openConversation`, the action the sidebar's Chief item and Home's list run.
The place is read from the transcript's drawn rows (`debug.home.drive` `rows`, window points);
`scroll` moves it as a wheel does. Socket only, no system input. Runs on cmux-lawrence-2 through
`nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- 'python3 scripts/cmux-next/home-open-placement.py'`
with an isolated HOME and Chief home under /tmp; it launches the app itself and ends with
quitEndSessions, endAgents and the tag's acpmux daemon shutdown. Reads NX_APP, NX_APP_TAG, NX_APP_STOP,
NX_ARTIFACTS. Without a GUI host, the same script runs against a downloaded fleet build in the background
(`NX_APP=<app> NX_APP_TAG=<tag> python3 scripts/cmux-next/home-open-placement.py`; the app is never activated).
"""
import json, os, shutil, socket, subprocess, sys, tempfile, time

APP, TAG = os.environ["NX_APP"], os.environ["NX_APP_TAG"]
OUT, STOP = os.environ.get("NX_ARTIFACTS", "/tmp/home-open-placement"), os.environ.get("NX_APP_STOP", "")
SOCK = "/tmp/cmux-debug-%s.sock" % TAG
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
os.makedirs(OUT, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix="h27627-", dir="/tmp")
HOME, CHIEF = os.path.join(SCRATCH, "home"), os.path.join(SCRATCH, "chief")
COUNT = 60
failures = []


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(SOCK)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": "socket: %s" % error}


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "  " + json.dumps(detail)[:1200]), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=30):
    deadline = time.time() + timeout
    value = predicate()
    while not value and time.time() < deadline:
        time.sleep(0.25)  # test harness wait, not app code
        value = predicate()
    return value


def api(**params):
    return rpc("debug.home.api", params) or {}


def run(action, arguments=None):
    params = {"id": action, "focus": True}
    if arguments:
        params["arguments"] = arguments
    return rpc("action.run", params) or {}


def shot(name):
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, name + ".png")}, 60)


def shown():
    return ((rpc("debug.home") or {}).get("dock") or {}).get("messages_shown")


def message_ids(conversation):
    return [m.get("id") for m in api(call="snapshot", conversation=conversation, tail=COUNT + 10).get("messages") or []]


def rows():
    """The drawn bubble rows: {message id: bottom edge of its last bubble, window points from the bottom}."""
    out = {}
    for r in (rpc("debug.home.drive", {"action": "rows"}) or {}).get("rows") or []:
        parts = r.get("key", "").split(":")
        if len(parts) >= 2 and parts[0] == "part":
            out[parts[1]] = min(out.get(parts[1], 1e9), r["y"])
    return out


def settled_rows():
    """The rows once two reads half a second apart agree (the open's width measure has landed)."""
    last = [None]

    def same():
        now = rows()
        stable = bool(now) and now == last[0]
        last[0] = now
        if not stable:
            time.sleep(0.5)  # test harness: the next read, not app code
        return now if stable else None
    return poll(same, 20) or last[0] or {}


def at_newest(_now=None):
    """The view shows its newest message, pinned there (the transcript's own state)."""
    return (rpc("debug.home.drive", {"action": "rows"}) or {}).get("atNewest") is True


def open_chat(conversation):
    def opened():
        if shown() == conversation:
            return True
        run("home.openConversation", {"conversation": conversation})
        time.sleep(0.5)  # test harness: one request per half second while Home starts, not app code
        return None
    ok = poll(opened, 120)
    return ok and settled_rows()


def same_place(before, after):
    """The rows both show sit where they were (within 2 pt); the largest move, and how many rows matched."""
    common = [k for k in before if k in after]
    worst = max((abs(before[k] - after[k]) for k in common), default=None)
    return bool(common) and worst <= 2, {"matched": len(common), "worst_move": worst}


def body(i, letter):
    words = "the migration plan and the backfill both wait for the cutover next week".split()
    return "%s %02d: %s" % (letter, i, " ".join(words[: 3 + (i * 7) % len(words)] * (1 + i % 3)))


os.makedirs(os.path.join(CHIEF, "optchat"), exist_ok=True)
os.makedirs(HOME, exist_ok=True)
open(os.path.join(CHIEF, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(CHIEF, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
open(os.path.join(SCRATCH, "ghostty"), "w").write("")
env = {k: v for k, v in os.environ.items() if k in ("USER", "LOGNAME", "TMPDIR", "SHELL", "LANG")}
env.update({"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
            "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
            "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1500,940", "CMUX_NEXT_ONBOARDING_COMPUTER_USE": "mock",
            "CMUX_NEXT_CHIEF_HOME": CHIEF, "ACPMUX_AGENT_LAUNCH": "deny"})
env.pop("CMUX_NEXT_CLASSIC_HOME", None)  # the default, docked Home
if os.path.exists(SOCK):
    os.unlink(SOCK)
app = subprocess.Popen([os.path.join(APP, "Contents/MacOS/cmux DEV")], env=env, cwd=OUT, stdin=subprocess.DEVNULL,
                       stdout=open(os.path.join(OUT, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
print("launched pid %d" % app.pid, flush=True)
try:
    poll(lambda: os.path.exists(SOCK) and (rpc("debug.windows") or {}).get("windows"), 240)
    poll(lambda: "error" not in run("home.show"), 120)
    check("the docked Home shows its Messages view", poll(lambda: ((rpc("debug.home") or {}).get("dock") or {}).get("mode") == "messages", 60),
          (rpc("debug.home") or {}).get("dock"))
    check("the local owner answers inbox", bool(poll(lambda: "conversations" in api(call="inbox"), 180)), api(call="inbox"))
    stamp = str(int(time.time()))
    chats = {}
    for letter in ("A", "B"):
        created = api(call="submit", op={"kind": "create_group", "title": "scroll-%s-%s" % (letter, stamp), "participants": []})
        if not check("channel %s is made" % letter, bool(created.get("conversation")), created):
            sys.exit(1)
        chats[letter] = created["conversation"]
        for i in range(1, COUNT + 1):
            api(call="submit", op={"kind": "send", "conversation": chats[letter], "text": body(i, letter)})
        check("channel %s holds %d messages" % (letter, COUNT), poll(lambda: len(message_ids(chats[letter])) >= COUNT, 60),
              len(message_ids(chats[letter])))
    a, b = chats["A"], chats["B"]

    # 1. First open: the newest message.
    now = open_chat(a)
    check("1. A, first open: its newest message shows", at_newest(now), sorted(now.items(), key=lambda kv: kv[1]))
    shot("1-a-first-open")

    # 2. Scrolled up in A, then B, then A: the same rows where they were.
    rpc("debug.home.drive", {"action": "scroll", "dy": -900})
    reading = settled_rows()
    check("2. A, scrolled up: no longer at its newest message", bool(reading) and not at_newest(), reading)
    shot("2a-a-scrolled-up")
    now = open_chat(b)
    check("2. B, first open: its newest message shows", at_newest(now), now)
    shot("2b-b-open")
    now = open_chat(a)
    ok, detail = same_place(reading, now)
    check("2. A, reopened: the rows the person read, where they were", ok and not at_newest(), dict(detail, rows=now))
    shot("2c-a-reopened")

    # 3. Still scrolled up; a message comes while B shows: A still opens at the reading place (Messages does).
    open_chat(b)
    api(call="submit", op={"kind": "send", "conversation": a, "text": "A late: came while B showed"})
    poll(lambda: len(message_ids(a)) >= COUNT + 1, 30)
    now = open_chat(a)
    ok, detail = same_place(reading, now)
    check("3. A, a new message meanwhile: still opens where the person was reading", ok, dict(detail, rows=now))
    shot("3-a-reopened-after-new")

    # 4. Back down to the newest, B, a new message in A, A: the newest message, the new one included.
    rpc("debug.home.drive", {"action": "scroll", "dy": 100000})
    now = settled_rows()
    check("4. A, scrolled back down: its newest message shows", at_newest(now), now)
    open_chat(b)
    api(call="submit", op={"kind": "send", "conversation": a, "text": "A newest: came while B showed"})
    poll(lambda: len(message_ids(a)) >= COUNT + 2, 30)
    now = open_chat(a)
    check("4. A, left at the bottom: opens at its newest message, the one that came meanwhile", at_newest(now), now)
    shot("4-a-reopened-at-newest")

    # 5. B was left at its newest: it opens there.
    now = open_chat(b)
    check("5. B, left at the bottom: opens at its newest message", at_newest(now), now)
    shot("5-b-reopened")
finally:
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        print("app pid %d did not quit within 60 s" % app.pid, flush=True)
    rpc("action.run", {"id": "endAgents"}, timeout=10)
    for acp in (os.path.join(CHIEF, "acpmux"), os.path.join(HOME, ".acpmux")):
        if os.path.isdir(acp):
            subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env=dict(env, ACPMUX_HOME=acp), capture_output=True, timeout=30)
    if STOP:
        subprocess.run([STOP], capture_output=True, timeout=180)
    shutil.rmtree(SCRATCH, ignore_errors=True)

print("%d failed: %s" % (len(failures), failures) if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
