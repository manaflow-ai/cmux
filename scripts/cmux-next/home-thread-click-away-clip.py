#!/usr/bin/env python3
"""Tagged-app clip: a click on empty space of an open reply thread closes it (Lawrence 2026-11-18, "clicking some
space fails to close it").

Launches the tagged app (classic Home) with no activation, makes a conversation on the local owner and, through
Home's own paths, a nested thread: root R, my reply A to R, my reply B to A, so the thread view of R draws a "1 Reply"
line under A. Then it records the window (`debug.window_record`, 12 s) while it opens R's thread and clicks
(`debug.mouse`, events through the app's queue and its local monitors, as a person's) on the empty part of that line,
away from its words, then on the words themselves. Each click's spot and the thread state after it go to
`clicks.json`; `clip.mp4` is the recording with a ring at each click (before the fix the empty spots keep the thread
open, after it they close it; the words open A's branch in both).

No system input: socket only. Runs on cmux-lawrence-2 (a fleet build's app).

Usage: home-thread-click-away-clip.py --tag <tag> --app APP --out DIR
"""
import argparse, json, os, signal, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402
from state_wait import wait_until, wait_stable  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
home = os.environ["HOME"]
sock = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode()); b = b""
        while not b.endswith(b"\n"):
            x = c.recv(1 << 20)
            if not x: break
            b += x
        c.close(); r = json.loads(b)
    except (OSError, ValueError) as e:
        return {"error": str(e)}
    return r.get("result") if r.get("ok") else {"error": r.get("error")}


def drive(action, **params):
    return rpc("debug.home.drive", {"action": action, **params}) or {}


def poll(predicate, timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        v = predicate()
        if v: return v
        time.sleep(0.25)  # harness wait for the app's own state
    return None


def component(raw):
    out = ""
    for ch in raw:
        out += ch if ch.isalnum() or ch in "-_." else "-"
    return out.strip("-.")


def owner_socket():
    root_dir = os.path.join(home, ".cmux/chief/isolated", component(opts.tag))
    h = 0x811C9DC5
    for b in root_dir.encode():
        h ^= b; h = (h * 0x01000193) & 0xFFFFFFFF
    name = f"cmux-chief-{h:08x}.sock"
    try:
        lines = [l for l in open(os.path.join(root_dir, "client.log")) if "control socket at " in l]
    except OSError:
        return None
    path = lines[-1].split("control socket at ", 1)[1].strip() if lines else None
    return path if path and path.endswith(name) and os.path.exists(path) else None


def daemon(path, cmd, **fields):
    c = socket.socket(socket.AF_UNIX); c.settimeout(20); c.connect(path)
    f = c.makefile("rwb")
    f.write((json.dumps({"id": 7, "cmd": cmd, **fields}) + "\n").encode()); f.flush()
    for line in f:
        r = json.loads(line)
        if r.get("id") == 7:
            c.close(); return r.get("data") or r
    c.close(); return {"ok": False, "error": "closed"}


def send_from_field(text):
    drive("focus"); drive("type", text=text)
    return drive("send")


def thread_rows():
    r = drive("thread_rows")
    return json.loads(r["rows"]) if r.get("ok") == "1" else None


def store_texts(conversation):
    """The message texts Home's store holds for the conversation (debug.home.api snapshot)."""
    messages = (rpc("debug.home.api", {"call": "snapshot", "conversation": conversation, "tail": 20}) or {}).get("messages") or []
    return [m.get("text") for m in messages]


def settled_view():
    """What the transcript draws, once it stops changing: the thread view's rows when one is open, else Home's rows."""
    return wait_stable(lambda: json.dumps([drive("thread_state").get("open_thread"), thread_rows() or drive("rows").get("rows")],
                                          sort_keys=True), "the transcript's rows", timeout=10, interval=0.1,
                       raise_on_timeout=False)


def thread_closed():
    """Esc, Esc closed the thread view (it is gone from thread_state), and the rows settled."""
    wait_until(lambda: drive("thread_state").get("open_thread") is None and "closed", "the thread view to close",
               timeout=10, raise_on_timeout=False)
    settled_view()


if os.path.exists(sock):
    os.unlink(sock)
env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,900,860", **home_classic.ENV}
process = subprocess.Popen([f"{opts.app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
print(f"launched pid {process.pid}", flush=True)
result = {"tag": opts.tag, "clicks": []}
try:
    if not home_classic.require(rpc):
        sys.exit(2)
    inbox = poll(lambda: (r := rpc("debug.home.api", {"call": "inbox"})) and "conversations" in r and r, timeout=180)
    if not inbox: sys.exit("no inbox")
    me = inbox["me"]; me = me["id"] if isinstance(me, dict) else me
    owner = poll(owner_socket, timeout=90)
    if not owner: sys.exit("no owner socket")
    stamp = str(int(time.time()))
    created = daemon(owner, "conversation-create", idempotency_key=f"away-{stamp}", actor=me, title=f"Click away {stamp}",
                     participants=[{"id": me, "kind": "human", "display_name": "Me"},
                                   {"id": "agent_instinct", "kind": "agent", "display_name": "Maybe: Instinct"}])
    conversation = (created.get("conversation") or {}).get("id")
    first = f"Start {stamp}"
    daemon(owner, "conversation-op", conversation=conversation, idempotency_key=f"away-start-{stamp}", actor=me,
           op={"kind": "message.send", "client_msg_id": f"away-start-{stamp}", "parts": [{"type": "text", "text": first}]})

    def opened():
        def shown():
            return ((rpc("debug.home") or {}).get("page") or {}).get("shown") == conversation
        if not shown():
            rpc("action.run", {"id": "home.openConversation", "arguments": {"conversation": conversation}, "focus": True})
            # Home shows it; a request while Home starts can be dropped, and the poll asks again.
            if not wait_until(shown, "Home to show the conversation", timeout=5, raise_on_timeout=False):
                return None
        return first in (drive("texts").get("texts") or [])
    if not poll(opened, timeout=180): sys.exit("Home did not show the conversation")
    texts = {"R": "Can the thread close on any empty click?", "A": "It should, anywhere off a bubble.",
             "B": "Even beside the 1 Reply line under this one."}
    def sent(text):
        """The message is in Home's store and the transcript drew it (its rows settled)."""
        if not wait_until(lambda: text in store_texts(conversation), f"Home's store to hold {text!r}", timeout=20,
                          raise_on_timeout=False):
            print(f"Home's store does not hold {text!r} yet", flush=True)
        settled_view()

    send_from_field(texts["R"]); sent(texts["R"])
    for parent, child in (("R", "A"), ("A", "B")):
        if drive("thread_state").get("open_thread"): drive("escape"); drive("escape"); thread_closed()
        drive("reply", mine=True)
        # Reply… opened the thread view on my message, and its rows settled, before the field takes the text.
        wait_until(lambda: drive("thread_state").get("open_thread"), "Reply… to open the thread view", timeout=10,
                   raise_on_timeout=False)
        settled_view()
        send_from_field(texts[child]); sent(texts[child])
    if drive("thread_state").get("open_thread"): drive("escape"); drive("escape")
    thread_closed()

    def open_thread():
        state = drive("thread")
        settled_view()  # the open's flight: the thread view's rows stop moving
        return state.get("open_thread")
    if not open_thread(): sys.exit("the thread did not open")
    rows = thread_rows()
    result["rows"] = rows
    line = next((r for r in (rows or {}).get("rows", []) if r["kind"] == "replies"), None)
    if not line: sys.exit(f"no \"1 Reply\" line in the thread view: {rows}")
    height = rows["windowHeight"]
    f, c = line["frame"], line["control"]
    y = height - (f["y"] + f["height"] / 2)  # debug.mouse: window points from the top left
    # The empty part of the line: away from its words (mine sit at the right edge).
    words_left = c["x"] < f["x"] + f["width"] / 2
    empties = [f["x"] + f["width"] - 60, f["x"] + f["width"] / 2] if words_left else [f["x"] + 60, f["x"] + f["width"] / 2]
    spots = [("empty", x) for x in empties] + [("words", c["x"] + c["width"] / 2)]
    drive("escape"); drive("escape"); thread_closed()
    rec = os.path.join(opts.out, "frames")
    rpc("debug.window_record", {"dir": rec, "seconds": 12})
    t0 = time.monotonic()
    # The recording runs: its first frame is in the frames folder.
    wait_until(lambda: os.path.isdir(rec) and os.listdir(rec), "the recording's first frame", timeout=10,
               raise_on_timeout=False)
    time.sleep(0.6)  # sleep-ok: the clip's lead-in, 0.6 s of the closed view before the first open
    for name, x in spots:
        if not drive("thread_state").get("open_thread"):
            open_thread()
        time.sleep(0.6)
        before = drive("thread_state")
        t = time.monotonic() - t0
        rpc("debug.mouse", {"action": "click", "x": x, "y": y})
        time.sleep(1.4)
        after = drive("thread_state")
        result["clicks"].append({"spot": name, "x": x, "y": y, "t": round(t, 3), "before": before, "after": after,
                                 "closed": after.get("open_thread") is None,
                                 "drilled": len(after.get("thread_path") or []) > len(before.get("thread_path") or [])})
        print(json.dumps(result["clicks"][-1]), flush=True)
    time.sleep(1.0)  # sleep-ok: the clip's tail, 1 s of the last click's effect on the recording
finally:
    with open(os.path.join(opts.out, "clicks.json"), "w") as fh:
        json.dump(result, fh, indent=1)
    try:
        rpc("action.run", {"action": "quit", "origin": "script"}, timeout=5)
    except Exception:
        pass
    try:
        process.wait(timeout=10)  # the quit ends the app
    except subprocess.TimeoutExpired:
        pass
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)  # the app this script started
