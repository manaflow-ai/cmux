#!/usr/bin/env python3
"""Live check: session.transfer.pull moves a cmux-next agent chat between two builds.

  scripts/cmux-next/chat-transfer-live.py --a SOCKET --a-tag TAG --b SOCKET --b-tag TAG \
      --fake-agent PATH [--home DIR] [--home DIR] [--out DIR]

Run on the GUI host where both builds already run, for example one fleet build launched in two
capture slots of one host. Each build has its own control socket (`--a`, `--b`) and build tag,
so its own acpmux home `<home>/.acpmux/builds/com.cmuxterm.app.debug.<tag slug>`: exactly one per tag (`--a-tag`,
`--b-tag`, each a build's whole tag) under the `--home` dirs (the user's home by default). Never `/tmp/acpmux-<uid>` as
such: other apps' daemons listen there too. No real agent and no credentials: each acpmux runs
the test agent (cmux-tui/crates/acpmux/tests/fake_agent.py, `--fake-agent`) as harness `fake`.

1. A opens an agent chat (its acpmux starts; harness `fake` is configured there). A chat made
   on A's acpmux in `--out` gets a reply ("hi"), and A's chat tab shows it
   (`debug.agent_pane select_session`) until B lists it (`session.transfer.peers`).
2. B opens a chat too. Right before the pull, A's chat gets a running turn ("until-cancel"),
   two prompts queued behind it, and a draft. B pulls it:
   `session.transfer.pull {source: A, ids: [the tab], interrupt: true}`.
3. Checks: B shows the chat in a tab bound to its session; B's acpmux has its history, runs the
   two queued prompts once each, in order, and holds the draft; A's tab is gone and A's acpmux
   has the chat closed, having run none of the queue. Then a second pull finds nothing to move.

Exit 0 when every check passes; each check prints ok/FAIL and the last line is RESULT. Each
acpmux home's config.json gets harness `fake` for the run and is put back as it was after.
Quits nothing: the caller ends both builds.
"""
import argparse, json, os, re, socket, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--a", required=True, help="build A's control socket (the source)")
parser.add_argument("--a-tag", required=True, help="text in build A's tag (its acpmux home is tags/<slug> with it)")
parser.add_argument("--b", required=True, help="build B's control socket (the taker)")
parser.add_argument("--b-tag", required=True, help="text in build B's tag")
parser.add_argument("--home", action="append", default=[], help="a HOME the builds may run with")
parser.add_argument("--fake-agent", required=True, help="path of acpmux's tests/fake_agent.py on this host")
parser.add_argument("--out", default="/tmp/chat-transfer-live")
opts = parser.parse_args()
opts.home = opts.home or [os.path.expanduser("~")]
os.makedirs(opts.out, exist_ok=True)
failures = []
LOG = open(os.path.join(opts.out, "live.log"), "a")


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


def check(ok, what):
    say(("ok   " if ok else "FAIL ") + what)
    if not ok:
        failures.append(what)
    return ok


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def rpc(sock, method, params=None, timeout=60):
    """One request on a cmux control socket."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(sock)
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
        self.request("initialize", {"protocolVersion": 1, "clientInfo": {"name": "chat-transfer-live"}})

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

    def send(self, method, params):
        """Sends a request and returns its id without waiting."""
        with self.lock:
            self.next += 1
            rid = self.next
        self.conn.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        return rid

    def answer(self, rid, timeout=30):
        with self.lock:
            self.lock.wait_for(lambda: rid in self.answers, timeout)
            return self.answers.pop(rid, {"error": {"message": "no answer"}})

    def request(self, method, params, timeout=30):
        return self.answer(self.send(method, params), timeout)


def socket_of(home):
    """acpmux `config::socket_path()`: `<home>/acpmux.sock`, or `/tmp/acpmux-<uid>/<fnv1a64>.sock`
    when that is too long for sun_path."""
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred.encode()) < 96:
        return preferred
    h = 0xcbf29ce484222325
    for byte in home.encode():
        h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{h:016x}.sock"


def tag_slug(tag):
    """AcpmuxEnvironment.tagSlug: lowercase, runs of anything outside [a-z0-9] become one `-`."""
    return re.sub(r"[^a-z0-9]+", "-", tag.lower()).strip("-")


def acpmux_homes(tag):
    """The acpmux homes of build tag `tag` whose socket is there, socket by home. Never
    /tmp/acpmux-<uid> as such: it is shared with every other app of this user."""
    found = {}
    for user_home in opts.home:
        home = os.path.join(user_home, ".acpmux", "builds", "com.cmuxterm.app.debug." + re.sub(r"[^a-z0-9]+", ".", tag.lower()).strip("."))
        if os.path.exists(socket_of(home)):
            found[home] = socket_of(home)
    return found


RESTORE = []  # (config path, its text before the run or None, daemon socket)


def write_config(path, text):
    temp = path + ".chat-transfer-live"
    with open(temp, "w") as f:
        f.write(text)
    os.replace(temp, path)


def restore_configs():
    for path, original, sock in RESTORE:
        try:
            if original is None:
                os.remove(path)
            else:
                write_config(path, original)
            Acpmux(sock).request("_acpmux/reload_config", {}, timeout=10)
        except OSError as error:
            say("could not restore", path, error)


def configure_fake(home, sock):
    """Harness `fake` (the test agent) in `home`'s config, read again by the running daemon."""
    path = os.path.join(home, "config.json")
    try:
        with open(path) as f:
            original = f.read()
    except FileNotFoundError:
        original = None
    config = json.loads(original) if original is not None else {}  # a bad file stops the run
    config.setdefault("harnesses", {})["fake"] = {"argv": ["python3", opts.fake_agent]}
    write_config(path, json.dumps(config, indent=2))
    RESTORE.append((path, original, sock))
    client = Acpmux(sock)
    reloaded = client.request("_acpmux/reload_config", {})
    say("reload", home, json.dumps(reloaded)[:200])
    return client


def open_chat(sock, tag):
    """Opens an agent chat on build `sock` and returns its acpmux (home, socket)."""
    say("open chat", json.dumps(rpc(sock, "action.run", {"action": "palette.newAgentChat", "focus": True}))[:300])
    new = wait(lambda: acpmux_homes(tag) or None, 60, 0.5)
    if not new or len(new) > 1:
        say("acpmux homes for", tag, new)
        return None, None
    return next(iter(new.items()))


def chat_tabs(sock):
    """Agent chat tabs of a build: (tab id, acpmux session, surface) per tab, wherever the
    snapshot nests them."""
    snap = rpc(sock, "snapshot.get")
    if not isinstance(snap, dict) or "error" in snap:
        return None
    tabs = []

    def walk(node):
        if isinstance(node, dict):
            if node.get("kind") == "conversation" and "surface" in node:
                tabs.append((node.get("id"), node.get("agent_session"), node.get("surface")))
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(snap)
    with open(os.path.join(opts.out, "snapshot-" + os.path.basename(sock) + ".json"), "w") as f:
        json.dump(snap, f, indent=1)
    return tabs


def queue_of(client, sid):
    return (client.request("_acpmux/info", {"sessionId": sid}).get("result") or {}).get("queue") or []


def events(client, sid, kind):
    page = client.request("_acpmux/events", {"sessionId": sid, "afterSeq": 0, "limit": 5000})
    rows = ((page.get("result") or {}).get("events")) or []
    return [e.get("msg", {}) for e in rows if e.get("kind") == kind]


def texts(client, sid):
    return [m.get("text") for m in events(client, sid, "user_message")]


def main():
    # 1. A's chat, with history, a running turn, a queue and a draft.
    a_home, a_sock = open_chat(opts.a, opts.a_tag)
    if not check(bool(a_sock), "A's acpmux runs after A opens a chat"):
        return
    a = configure_fake(a_home, a_sock)

    def pane(sock, action, **params):
        answer = rpc(sock, "debug.agent_pane", {"action": action, **params}, timeout=60)
        say(action, json.dumps(answer)[:400])
        return answer

    # The chat: made on A's acpmux in this run's folder (the fake agent needs no folder trust),
    # with a reply; a turn left running and two prompts queued behind it come later.
    created = a.request("session/new", {"cwd": opts.out, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake"}}})
    sid = (created.get("result") or {}).get("sessionId")
    if not check(bool(sid), f"A's acpmux made a fake chat: {json.dumps(created)[:200]}"):
        return

    def prompt(pid, text):
        return {"sessionId": sid, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": pid}}}

    a.request("session/prompt", prompt("p-hi", "hi"), timeout=60)

    b_home, b_sock = open_chat(opts.b, opts.b_tag)
    if not check(bool(b_sock) and b_sock != a_sock, "B's own acpmux runs after B opens a chat"):
        return
    b = configure_fake(b_home, b_sock)

    # A's chat tab shows it, as when a person picks it in the pane (which reloads the page); B
    # sees the chat through `session.transfer.peers`, the list the pull moves from.
    def listed():
        peers = rpc(opts.b, "session.transfer.peers", timeout=90)
        for peer in (peers or {}).get("peers", []) if isinstance(peers, dict) else []:
            for item in peer.get("sessions", []):
                if item.get("kind") == "chat" and item.get("agent_session") == sid:
                    return (peer["socket"], item)
        return None

    record = None
    for _ in range(3):
        pane(opts.a, "select_session", session=sid)
        record = wait(listed, 20, 2)
        if record:
            break
    say("A tabs", chat_tabs(opts.a))
    if not check(bool(record), "B lists A's chat tab as a chat record"):
        return
    check(record[1].get("acpmux_socket") == a_sock, "the record names A's acpmux socket")

    # Busy right before the pull: the fake agent's running turn ends on its own after 30 s.
    a.send("session/prompt", prompt("p-turn", "until-cancel"))
    time.sleep(1)
    a.send("session/prompt", prompt("p-a", "queued a"))
    wait(lambda: len(queue_of(a, sid)) >= 1, 10)
    a.send("session/prompt", prompt("p-b", "queued b"))
    queued = wait(lambda: (lambda q: q if len(q) >= 2 else None)(queue_of(a, sid)), 10)
    say("A queue", json.dumps(queued)[:600])
    check(bool(queued), "A's chat has two prompts queued behind its running turn")

    # 2. B pulls it.
    a.request("_acpmux/draft_set", {"sessionId": sid, "text": "unsent words"})
    pulled = rpc(opts.b, "session.transfer.pull", {"source": record[0], "ids": [record[1]["surface"]], "interrupt": True}, timeout=300)
    say("pull", json.dumps(pulled)[:1500])
    check(isinstance(pulled, dict) and len(pulled.get("moved") or []) == 1 and not pulled.get("failed"), "the pull moved the chat")

    # 3. Where it is now.
    has = lambda tabs: tabs is not None and any(t[1] == sid for t in tabs)
    check(bool(wait(lambda: has(chat_tabs(opts.b)), 20)), "B shows the chat in a tab bound to its session")
    check(bool(wait(lambda: (lambda t: t is not None and not has(t))(chat_tabs(opts.a)), 20)), "A's tab for the chat closed")
    wait(lambda: "queued b" in texts(b, sid), 60)
    time.sleep(5)  # a prompt run twice would show by now
    ran = texts(b, sid)
    say("B user messages", ran)
    check(ran == ["hi", "until-cancel", "queued a", "queued b"], "B has the history and ran the queue once, in order")
    draft = (b.request("_acpmux/draft_get", {"sessionId": sid}).get("result") or {}).get("draft")
    check(draft == "unsent words", f"B holds the draft ({draft!r})")
    a_info = a.request("_acpmux/info", {"sessionId": sid}).get("result") or {}
    check(a_info.get("status") == "closed", f"A's acpmux has the chat closed ({a_info.get('status')})")
    check(texts(a, sid) == ["hi", "until-cancel"], f"A ran none of the queue ({texts(a, sid)})")
    again = rpc(opts.b, "session.transfer.pull", {"source": record[0], "ids": [record[1]["surface"]]}, timeout=120)
    say("second pull", json.dumps(again)[:500])
    nothing = isinstance(again, dict) and (
        (not again.get("moved") and "error" not in again)
        or "No sessions are available" in str((again.get("error") or {}).get("message", "")))
    check(nothing, "a second pull moves nothing")


try:
    main()
except BaseException as error:
    failures.append(f"the check stopped: {error!r}")
    raise
finally:
    restore_configs()
    say("RESULT", "PASS" if not failures else f"FAIL ({len(failures)}): " + "; ".join(failures))
raise SystemExit(1 if failures else 0)
