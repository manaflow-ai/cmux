#!/usr/bin/env python3
"""A Chief subagent's first prompt shows in its agent chat, in a real tagged app (u4256).

Lawrence 2026-10-20: "When you start the chat here, this is all I see. I don't see the initial
message that you sent." A Chief subagent's first prompt is the Chief's whole view plus its task
(100+ KB, optchat-chief `prompt::subagent_blocks`), so it is larger than the 128 KB page the pane
opens a chat with, and the page started after it. This run proves the pane draws it anyway.

No real agent and no credentials: the tagged app's own acpmux runs the test agent
(cmux-tui/crates/acpmux/tests/fake_agent.py) as harness `fake`, with FAKE_TOOL_CALLS (a turn of
shell calls, as a working agent's) and FAKE_SHORT_ECHO (a short reply). The prompts go to acpmux
exactly as the Chief sends them: `session/prompt` with promptId `optchat-sub:<id>:<ms>` (the task)
and `optchat-tell:<id>:<ms>` (a tell or restart message).

Checks, each with a window snapshot in --out:
  live     the chat tab shows the session before the prompt; after the turn its first bubble is
           the task, labelled "From the Chief", with the Chief's view as one collapsed line
  reopen   the tab shows another chat, then this one again (a fresh open page, which starts after
           the 140 KB prompt): the same first bubble
  tell     a tell from the Chief draws as a second "From the Chief" bubble; the task stays first

Usage: chief-prompt-bubble-live.py --tag <tag> --app PATH [--out DIR] [--json PATH]
Fleet: scripts/measure/chief-prompt-bubble.sh (builds the tagged app first).
"""
import argparse, glob, json, os, re, signal, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
parser.add_argument("--view-kb", type=int, default=140, help="size of the Chief view in the first prompt")
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FAKE_AGENT = os.path.join(ROOT, "cmux-tui/crates/acpmux/tests/fake_agent.py")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"chief-bubble-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
os.makedirs(opts.out, exist_ok=True)
ROWS, RESTORE = [], []
app = None

TASK_MARK = "probe-task-u4256"
TELL_MARK = "probe-tell-u4256"
TASK = (f"Title: Prompt bubble probe\n\n{TASK_MARK}: the Chief's task must show as this chat's first message, "
        f"marked as from the Chief.\nReply with: {TASK_MARK} done")
TELL = f"{TELL_MARK}: a follow-up from the Chief, sent while the subagent works."


def row(name, expected, observed, ok):
    ROWS.append({"check": name, "expected": expected, "observed": observed, "pass": bool(ok)})
    print(f"{'PASS' if ok else 'FAIL'} | {name} | {expected} | {observed}", flush=True)


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def rpc(method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


class Acpmux:
    """One connection to an acpmux daemon: requests answered by id, notifications dropped."""

    def __init__(self, path):
        self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.conn.connect(path)
        self.next, self.answers, self.lock = 0, {}, threading.Condition()
        threading.Thread(target=self._read, daemon=True).start()
        self.request("initialize", {"protocolVersion": 1, "clientInfo": {"name": "chief-prompt-bubble-live"}})

    def _read(self):
        buf = b""
        while True:
            chunk = self.conn.recv(1 << 20)
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                try:
                    message = json.loads(line)
                except ValueError:
                    continue
                if "id" in message and ("result" in message or "error" in message):
                    with self.lock:
                        self.answers[message["id"]] = message
                        self.lock.notify_all()

    def request(self, method, params, timeout=60):
        with self.lock:
            self.next += 1
            rid = self.next
        self.conn.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        with self.lock:
            self.lock.wait_for(lambda: rid in self.answers, timeout)
            return self.answers.pop(rid, {"error": {"message": "no answer"}})


def socket_of(home):
    """acpmux `config::socket_path()`: `<home>/acpmux.sock`, or `/tmp/acpmux-<uid>/<fnv1a64>.sock`."""
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred.encode()) < 96:
        return preferred
    h = 0xcbf29ce484222325
    for byte in home.encode():
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{h:016x}.sock"


def acpmux_home():
    home = os.path.join(os.environ["HOME"], ".acpmux", "builds",
                        "com.cmuxterm.app.debug." + re.sub(r"[^a-z0-9]+", ".", TAG.lower()).strip("."))
    return home if os.path.exists(socket_of(home)) else None


def configure_fake(home):
    """Harness `fake` in the tag's acpmux config, read again by the running daemon; put back on exit."""
    path = os.path.join(home, "config.json")
    try:
        original = open(path).read()
    except FileNotFoundError:
        original = None
    config = json.loads(original) if original is not None else {}
    config.setdefault("harnesses", {})["fake"] = {
        "argv": ["/usr/bin/env", "FAKE_TOOL_CALLS=12", "FAKE_SHORT_ECHO=1", "python3", FAKE_AGENT]}
    temp = path + ".probe"
    open(temp, "w").write(json.dumps(config, indent=2))
    os.replace(temp, path)
    RESTORE.append((path, original))
    client = Acpmux(socket_of(home))
    print("reload", json.dumps(client.request("_acpmux/reload_config", {}))[:200], flush=True)
    return client


def restore():
    for path, original in RESTORE:
        try:
            if original is None:
                os.remove(path)
            else:
                open(path, "w").write(original)
        except OSError as error:
            print("could not restore", path, error, flush=True)


def chief_view(kb):
    """A Chief view as optchat-chief builds it: `<chat>`, one summary line per message range, `</chat>`."""
    lines, n = [], 0
    while sum(len(l) + 1 for l in lines) < kb * 1024:
        lines.append(f"{n}+1|user: probe line {n}: " + "the Chief's memory of the chat, one summary per message. " * 2)
        n += 1
    return "<chat>\n" + "\n".join(lines) + "\n</chat>"


def pane(action, **params):
    return rpc("debug.agent_pane", {"action": action, **params}, timeout=60) or {}


def snapshot(name):
    path = os.path.join(opts.out, f"{name}.png")
    rpc("debug.window_snapshot", {"path": path})
    print("snapshot", path, os.path.exists(path), flush=True)
    return path


def bubbles():
    return (pane("chat_state") or {}).get("userBubbles") or []


def turn_done(client, sid, turns):
    info = (client.request("_acpmux/info", {"sessionId": sid}).get("result") or {})
    return info.get("status") not in ("running", "starting") and (info.get("turnCount") or 0) >= turns


def check_first(label, extra=""):
    shown = wait(lambda: (lambda b: b if b and TASK_MARK in b[0].get("text", "") else None)(bubbles()), 30) or bubbles()
    first = shown[0] if shown else {}
    snap = snapshot(label)
    row(f"{label}: first bubble is the Chief's task", f"text starts '{TASK_MARK}'", (first.get("text") or "")[:80],
        (first.get("text") or "").startswith(TASK_MARK))
    row(f"{label}: marked as from the Chief", "From the Chief", str(first.get("from")), bool(first.get("from")))
    row(f"{label}: the Chief's view is one collapsed line", "a context summary", str(first.get("context")),
        bool(first.get("context")))
    return shown, snap


def main():
    global app
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": "80,80,1400,900"}
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        sys.exit("the tagged app did not come up")
    time.sleep(3)  # test harness: launch work settles
    print("open chat", json.dumps(rpc("action.run", {"action": "palette.newAgentChat", "focus": True}))[:300], flush=True)
    home = wait(acpmux_home, 90, 0.5)
    if not home:
        row("the tag's acpmux runs", "an acpmux home for the tag", "none", False)
        return
    client = configure_fake(home)
    wait(lambda: "error" not in pane("pid"), 60, 0.5)

    def new_session():
        made = client.request("session/new", {"cwd": SCRATCH, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}})
        return (made.get("result") or {}).get("sessionId"), made

    sid, made = new_session()
    if not sid:
        row("a fake chat starts", "a session id", json.dumps(made)[:200], False)
        return
    other, _ = new_session()

    def prompt(session, text, kind):
        pid = f"optchat-{kind}:a999:{int(time.time() * 1000)}"
        return client.request("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": text}],
                                                 "_meta": {"acpmux": {"promptId": pid}}}, timeout=120)

    # live: the tab shows the session before the Chief's first prompt arrives.
    print("select", json.dumps(pane("select_session", session=sid))[:200], flush=True)
    view = chief_view(opts.view_kb)
    first = f"{view}Your task:\n\n{TASK}"
    print(f"first prompt {len(first.encode())} bytes", flush=True)
    answered = prompt(sid, first, "sub")
    row("the task turn ends", "end_turn", json.dumps(answered.get("result") or answered.get("error"))[:120],
        (answered.get("result") or {}).get("stopReason") == "end_turn")
    # The pane's open page: the newest transcript records within 128 KB (direct.ts OPEN_PAGE_BYTES).
    page = client.request("_acpmux/events", {"sessionId": sid, "beforeSeq": 1 << 53, "limit": 400,
                                             "maxBytes": 128 * 1024, "kinds": ["transcript"]})
    events = (page.get("result") or {}).get("events") or []
    row("the open page starts after the prompt (the bug's condition)", "no user_message in a 128 KB page",
        f"{len(events)} events, kinds {sorted({e.get('kind') for e in events})}",
        not any(e.get("kind") == "user_message" for e in events))
    check_first("live")

    # reopen: another chat, then this one again: a fresh 128 KB open page.
    prompt(other, "hi", "sub")
    pane("select_session", session=other)
    wait(lambda: any("hi" in (b.get("text") or "") for b in bubbles()), 30)
    pane("select_session", session=sid)
    check_first("reopen")

    # tell: a Chief follow-up is a second bubble from the Chief; the task stays first.
    prompt(sid, TELL, "tell")
    shown = wait(lambda: (lambda b: b if any(TELL_MARK in (x.get("text") or "") for x in b) else None)(bubbles()), 30) or bubbles()
    snap = snapshot("tell")
    tell = next((b for b in shown if TELL_MARK in (b.get("text") or "")), {})
    row("tell: shows as a bubble from the Chief", f"'{TELL_MARK}' from the Chief", f"{tell.get('from')}: {(tell.get('text') or '')[:60]}",
        bool(tell) and bool(tell.get("from")))
    row("tell: the task is still the first bubble", TASK_MARK, (shown[0].get("text") or "")[:60] if shown else "",
        bool(shown) and TASK_MARK in (shown[0].get("text") or ""))
    with open(os.path.join(opts.out, "bubbles.json"), "w") as f:
        json.dump({"bubbles": shown, "chat_state": pane("chat_state")}, f, indent=1)


def stop():
    restore()
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


try:
    main()
except BaseException as error:
    row("the run finished", "no error", repr(error), False)
    raise
finally:
    stop()
    failed = [r for r in ROWS if not r["pass"]]
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump({"tag": TAG, "rows": ROWS, "pass": not failed and bool(ROWS)}, f, indent=1)
    print("RESULT", "PASS" if ROWS and not failed else f"FAIL ({len(failed)})", flush=True)
raise SystemExit(0 if ROWS and not [r for r in ROWS if not r["pass"]] else 1)
