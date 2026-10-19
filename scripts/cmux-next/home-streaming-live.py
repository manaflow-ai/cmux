#!/usr/bin/env python3
"""Live proof that Home shows the Chief's reply while it is written (cmux-lawrence-2, GUI lane).

Launches the tagged app (no-activate, scratch config, an isolated Chief home),
sends one Home message through the composer (`debug.home.drive`) that asks
for about 250 words, and then, until the reply is posted:
- takes a window snapshot every 0.5 s (`debug.window_snapshot`) into OUT,
  each named with its time since the send;
- reads `debug.home` every 0.25 s: the Chief conversation's live draft
  (`draft`, when the app reports one), its typing state and its posted tail.
Prints the time of the first visible draft text, how it grew, and the time
the reply was posted, and writes OUT/timeline.json.

On exit it quits the app with quitEndSessions, shuts down the tag's acpmux
daemon and stops this tag's cmux-tui sessions by name. It ends only the app
process it started.

With --live-frames it sends no model turn either: a stand-in brain bound as
agent_mux on the Chief's daemon starts a run and publishes the Chief's live
frames (chief-live-v1, conversation-live-publish): a run.activity line, then
step.delta text. Home must show the line (with its elapsed time) in the
status-line slot under the transcript and the text in the Chief's bubble.
The app is then restarted mid-run: Home must show the text so far from the
owner's run.live snapshot and keep appending. Last the reply is posted
(client_msg_id = the run's turn) and the run ends: the reply takes the
bubble's place (same row, same top, no second bubble) and the line goes.

With --late-turn it sends no model turn: it mints an agent token on the
Chief's daemon, binds a stand-in brain as agent_mux on its socket, and sends
draft A, then draft B (a new turn), then late items of A. Home must show B's
text and never bring A back (debug.home draft and window snapshots).

Usage (under `zsh -lic`, for the subrouter route):
  home-streaming-live.py --tag <tag> --app <path to cmux DEV <tag>.app> --out DIR [--late-turn | --live-frames]
"""
import argparse, fcntl, glob, json, os, shutil, signal, socket, subprocess, sys, tempfile, threading, time
import re
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--timeout", type=float, default=300)
parser.add_argument("--late-turn", action="store_true",
                    help="instead of a real turn: a stand-in brain on the Chief daemon sends draft A, then B, "
                         "then late A items; Home must show B and never bring A back (cx-k1uj follow-up)")
parser.add_argument("--live-frames", action="store_true",
                    help="instead of a real turn: a stand-in brain publishes chief-live-v1 frames; Home shows the "
                         "activity line and the streaming text, joins mid-run from run.live, and the reply lands in place (cx-kmak2)")
opts = parser.parse_args()

TAG = opts.tag
APP = opts.app
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
MUX_HOME = os.path.expanduser(f"~/.cmux/chief/isolated/{TAG}")
SCRATCH = tempfile.mkdtemp(prefix=f"home-streaming-{TAG}-")
PROMPT = "Write about 250 words on why tests should run at product boundaries. Plain prose, no lists."
os.makedirs(opts.out, exist_ok=True)
app = None


def tag_slug(raw):
    """AcpmuxEnvironment.tagSlug: lowercase ASCII letters and digits, other runs become one '-'."""
    slug = ""
    for ch in raw.lower():
        if ch.isascii() and ch.isalnum():
            slug += ch
        elif not slug.endswith("-"):
            slug += "-"
    return slug.strip("-")


def fnv1a32(text):
    h = 0x811C9DC5
    for b in text.encode():
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return f"{h:08x}"


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


def wait(predicate, seconds, step=1.0):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def chief_row():
    home = rpc("debug.home") or {}
    return next((c for c in home.get("conversations", []) if "agent_mux" in c.get("participants", [])), None)


def host_log():
    try:
        return open(os.path.join(MUX_HOME, "host.log"), errors="replace").read()
    except OSError:
        return ""


def stop_sessions():
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    for session in (f"cmux-app-{TAG}", f"cmux-chief-{fnv1a32(MUX_HOME)}"):
        subprocess.run([CLI, "server", "stop", "--session", session, "--end-terminals"],
                       env=env, capture_output=True, timeout=60)


def acpmux_released(home, seconds=20):
    """Waits until the acpmux daemon of `home` released daemon.lock and every
    agent host its records name exited; a host still running at the deadline
    is ended by its recorded pid. True when nothing of `home` is left."""
    def lock_free():
        path = os.path.join(home, "daemon.lock")
        if not os.path.exists(path):
            return True
        with open(path, "a") as f:
            try:
                fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(f, fcntl.LOCK_UN)
                return True
            except OSError:
                return False

    def host_pids():
        pids = []
        for record in glob.glob(os.path.join(home, "hosts", "*.json")) + glob.glob(os.path.join(home, "hosts", "*", "*.json")):
            try:
                pid = json.load(open(record)).get("host_pid")
            except (OSError, ValueError):
                continue
            if isinstance(pid, int) and pid > 1:
                try:
                    os.kill(pid, 0)
                    pids.append(pid)
                except OSError:
                    pass
        return pids

    released = wait(lambda: lock_free() and not host_pids(), seconds, step=0.25)
    left = host_pids()
    for pid in left:
        os.kill(pid, signal.SIGTERM)
    with open(os.path.join(opts.out, "cleanup.log"), "a") as log:
        log.write(f"{home}: daemon.lock free={lock_free()} hosts left={left} released={bool(released)}\n")
    return bool(released)


def cleanup():
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    # Both acpmux daemons of the tag: the Chief's (its home) and the app's
    # agent daemon (~/.acpmux/builds/<build key>, AcpmuxEnvironment); a
    # daemon left running keeps its agent harnesses (and their PTYs) alive.
    for home in (os.path.join(MUX_HOME, "acpmux"), os.path.expanduser("~/.acpmux/builds/com.cmuxterm.app.debug." + re.sub(r"[^a-z0-9]+", ".", TAG.lower()).strip("."))):
        done = subprocess.run([ACPMUX, "daemon", "shutdown", "--end-agents"], env={**os.environ, "ACPMUX_HOME": home},
                              capture_output=True, text=True, timeout=60)
        with open(os.path.join(opts.out, "cleanup.log"), "a") as log:
            log.write(f"acpmux daemon shutdown ACPMUX_HOME={home}: rc={done.returncode} "
                      f"out={done.stdout.strip()[:300]!r} err={done.stderr.strip()[:300]!r}\n")
        acpmux_released(home)
    stop_sessions()


class Line:
    """A JSON-lines connection to the Chief's daemon (the v1 protocol)."""

    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(10)
        self.sock.connect(path)
        self.buf = b""
        self.next = 1

    def request(self, cmd, **params):
        rid = self.next
        self.next += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        while True:
            while b"\n" not in self.buf:
                chunk = self.sock.recv(1 << 16)
                if not chunk:
                    raise RuntimeError(f"{cmd}: the daemon closed the connection")
                self.buf += chunk
            line, self.buf = self.buf.split(b"\n", 1)
            value = json.loads(line)
            if value.get("id") == rid:
                if value.get("ok") is not True:
                    raise RuntimeError(f"{cmd} refused: {value}")
                return value.get("data")


def chief_socket(session):
    """The Chief daemon's socket: `<base>/cmux-tui-<uid>/<session>.sock` for the
    bases an owner can start with; the one whose identify names the session."""
    bases = [os.environ.get("TMPDIR", ""), "/tmp", "/private/tmp"]
    darwin = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    bases.insert(0, darwin)
    for base in [b for b in bases if b]:
        path = os.path.join(base, f"cmux-tui-{os.getuid()}", f"{session}.sock")
        try:
            if Line(path).request("identify").get("session") == session:
                return path
        except (OSError, RuntimeError, ValueError):
            continue
    sys.exit(f"no socket of the Chief daemon {session} answers")


def late_turn(conversation, session):
    """Draft A, then turn B, then late items of A, through the real daemon."""
    path = chief_socket(session)
    token = Line(path).request("conversation-agent-token", participant="agent_mux")["token"]
    brain = Line(path)
    brain.request("conversation-bind", participant="agent_mux", token=token)
    brain.request("conversation-typing", conversation=conversation, on=True)

    def draft(turn, seq, text, fresh=True):
        brain.request("conversation-draft", conversation=conversation, turn=turn, segment=0, seq=seq,
                      kind="talk", text=text, fresh=fresh, done=False)

    def shown(turn, text, seconds=15):
        def check():
            d = (chief_row() or {}).get("draft") or {}
            return d if d.get("turn") == turn and d.get("text") == text else None
        return wait(check, seconds, step=0.25)

    steps = []
    t0 = time.time()

    def snap(name):
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"late-{len(steps):02d}-{name}.png")}, timeout=10)
        steps.append({"t": round(time.time() - t0, 3), "step": name,
                      "draft": (chief_row() or {}).get("draft")})

    draft("turn:late:a", 1, "Alpha streaming")
    a_shown = shown("turn:late:a", "Alpha streaming")
    snap("a-shown")
    time.sleep(1)  # the draft gate's per-turn rate; B is a new turn
    draft("turn:late:b", 1, "Beta streaming")
    b_shown = shown("turn:late:b", "Beta streaming")
    snap("b-shown")
    time.sleep(1)
    # The late items must reach Home (a refusal by the daemon's draft gate
    # would prove nothing): each is retried after the gate's gap, and the
    # outcome is recorded.
    late = []
    for seq, text, fresh in ((2, " LATE", False), (3, "Alpha streaming LATE", True)):
        for _ in range(3):
            try:
                draft("turn:late:a", seq, text, fresh)
                late.append({"seq": seq, "sent": True})
                break
            except RuntimeError as refusal:
                late.append({"seq": seq, "refused": str(refusal)[:200]})
                time.sleep(1)
    time.sleep(3)
    snap("after-late-a")
    final = (chief_row() or {}).get("draft") or {}
    result = {"a_shown": bool(a_shown), "b_shown": bool(b_shown), "late_items": late, "final_draft": final,
              "late_a_dropped": final.get("turn") == "turn:late:b" and final.get("text") == "Beta streaming"}
    brain.request("conversation-typing", conversation=conversation, on=False)
    json.dump({"result": result, "steps": steps}, open(os.path.join(opts.out, "late-turn.json"), "w"), indent=1)
    print(json.dumps(result, indent=1), flush=True)
    if not any(item.get("sent") for item in late):
        sys.exit("INCONCLUSIVE: the daemon refused every late item of turn A")
    if not result["late_a_dropped"] or not result["b_shown"]:
        sys.exit("FAIL: Home did not keep turn B after late items of turn A")


def drive(action, **extra):
    return rpc("debug.home.drive", {"action": action, **extra}) or {}


def chief_bubble():
    """The newest incoming text row (the Chief's bubble), as drawn."""
    rows = [r for r in drive("rows").get("rows", []) if r.get("kind") == "text" and not r.get("outgoing")]
    return min(rows, key=lambda r: r["balloon"]["y"]) if rows else None


def live_frames(conversation, session):
    """A stand-in brain's chief-live-v1 frames through the real daemon (cx-kmak2)."""
    path = chief_socket(session)
    token = Line(path).request("conversation-agent-token", participant="agent_mux")["token"]
    brain = Line(path)
    brain.request("conversation-bind", participant="agent_mux", token=token)
    run = f"turn:live:{int(time.time())}"
    brain.request("conversation-run-append", conversation=conversation,
                  run={"id": run, "turn": run, "status": "running", "title": "live frames proof"})
    seqs = {}
    checks = []

    def publish(frame):
        brain.request("conversation-live-publish", conversation=conversation,
                      frame={**frame, "conversation": conversation, "run": run})

    # Step ids as the Cloud brain makes them (`talk:<generation task id>`, cx-5ylym): no number in
    # them, and their text order is not the segment order. Home orders by the rows' Step.seq.
    s0, s1, s2 = "talk:gen_q7", "talk:gen_c2", "talk:gen_k5"

    def talk(text, step=s0, final=False):
        seq = seqs.get(step, -1) + 1
        seqs[step] = seq
        frame = {"type": "step.delta", "step": step, "kind": "talk", "seq": seq, "text": text}
        if final:
            frame["final"] = True
        publish(frame)

    def check(name, predicate, seconds=20):
        value = wait(predicate, seconds, step=0.2)
        rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"live-{len(checks):02d}-{name}.png")}, timeout=10)
        checks.append({"check": name, "ok": bool(value), "live": (chief_row() or {}).get("live"),
                       "texts": drive("texts", limit=3)})
        print(json.dumps(checks[-1])[:400], flush=True)
        return value

    line = "Editing notes.md"
    now = int(time.time() * 1000)
    publish({"type": "run.activity", "line": line, "since": now - 12000, "at": now})
    check("activity-line", lambda: (drive("texts").get("statusLine") or "").startswith(line + " · "))
    check("activity-row", lambda: any(r.get("key") == "notice" for r in drive("rows").get("rows", [])))
    # Two reply segments end before the join (final frame, then the step row with the whole text,
    # which frees the owner's live text), as a Chief that called a tool between them (cx-kdm25).
    segments = []
    for step, pieces in ((s0, ("Live frames reach ", "the native ", "Messages view.")),
                         (s1, ("Ended segments ", "come from ", "the run rows."))):
        seg = ""
        for i, piece in enumerate(pieces):
            talk(piece, step=step, final=i == len(pieces) - 1)
            seg += piece
        segments.append(seg)
        brain.request("conversation-run-append", conversation=conversation,
                      run={"id": run}, steps=[{"id": step, "kind": "talk", "status": "done", "text": seg}])
        shown = "\n\n".join(segments)
        check(f"stream-{step}", lambda: (drive("texts", limit=1).get("texts") or [""])[-1] == shown)
    # A third segment streams when the view joins.
    seg = ""
    for piece in ("The open segment ", "streams on"):
        talk(piece, step=s2)
        seg += piece
    text = "\n\n".join(segments + [seg])
    check("stream-open", lambda: (drive("texts", limit=1).get("texts") or [""])[-1] == text)
    # Mid-run join: a new app process opens the conversation while the run works. The ended
    # segments come from the run rows, the open one from run.live: the whole text at once.
    restart_app()
    session = ((rpc("debug.home") or {}).get("chief_owner") or {}).get("session")
    check("join-snapshot", lambda: (drive("texts", limit=1).get("texts") or [""])[-1] == text, seconds=60)
    check("join-activity", lambda: (drive("texts").get("statusLine") or "").startswith(line))
    # The bubble as it stands with the line under it, before the step's final frame.
    before = chief_bubble()
    incoming_before = len([r for r in drive("rows").get("rows", []) if r.get("kind") == "text" and not r.get("outgoing")])
    talk(" in place.", step=s2, final=True)
    text += " in place."
    check("after-join", lambda: (drive("texts", limit=1).get("texts") or [""])[-1] == text)
    # The producer's order (spec: final frame, run end, reply), with the gap a real turn can leave
    # between the final frame and the reply (cx-zz30r: 80-450 ms): nothing may move until the reply
    # takes the bubble's place; only then the line closes.
    frames = []
    t0 = time.time()

    def sample(phase):
        frames.append({"t": round(time.time() - t0, 3), "phase": phase, "bubble": chief_bubble(),
                       "line": drive("texts").get("statusLine"),
                       "reply": any(m.get("text") == text and m.get("seq") is not None
                                    for m in (chief_row() or {}).get("shown_tail", []))})

    while time.time() - t0 < 0.4:
        sample("after-final")
    rebuilds_before = drive("texts").get("rebuilds")
    # The running reply is MessagesLab's streaming bubble (ask 11), not a message.
    check("streaming-bubble", lambda: drive("texts").get("streams") == 1, seconds=2)
    brain.request("conversation-run-append", conversation=conversation, run={"id": run, "status": "done"})
    brain.request("conversation-op", conversation=conversation, idempotency_key=run,
                  op={"kind": "message.send", "client_msg_id": run, "parts": [{"type": "text", "text": text}]})
    while time.time() - t0 < 2.0:
        sample("reply")
    # The reply takes the bubble's place without a whole-window rebuild (MessagesLab ask 11 hand-off).
    check("no-rebuild-at-handoff", lambda: rebuilds_before is not None and drive("texts").get("rebuilds") == rebuilds_before
          and drive("texts").get("streams") == 0, seconds=3)
    landed = check("reply-in-place", lambda: (chief_row() or {}).get("live") is None
                   and any(m.get("text") == text and m.get("seq") is not None for m in (chief_row() or {}).get("shown_tail", [])))
    check("line-gone", lambda: drive("texts").get("statusLine") is None)
    after = chief_bubble()
    incoming_after = len([r for r in drive("rows").get("rows", []) if r.get("kind") == "text" and not r.get("outgoing")])

    def edges(b):
        return (b["balloon"]["y"], b["balloon"]["y"] + b["balloon"]["height"]) if b else None

    # Before the reply shows, the bubble does not move (the line still holds its row).
    still = [edges(f["bubble"]) for f in frames if not f["reply"] and f["bubble"]]
    held = bool(still) and all(abs(e[0] - edges(before)[0]) <= 0.5 and abs(e[1] - edges(before)[1]) <= 0.5 for e in still)
    # The line is still there when the reply takes the bubble's place (it closes after the hand-off).
    first_reply = next((f for f in frames if f["reply"]), None)
    line_at_handoff = bool(first_reply and first_reply["line"])  # recorded only: one display frame decides it
    # Settled: same height, no second bubble; the only move is the line's row closing.
    settled_ok = bool(before and after) and abs(before["balloon"]["height"] - after["balloon"]["height"]) <= 0.5 \
        and incoming_after == incoming_before
    tops = [edges(f["bubble"])[1] for f in frames if f["bubble"]]
    # cx-06vn1: the line closes after the frame that first shows the reply (the app's display link count).
    line_close_after_handoff_fires = drive("texts").get("lineCloseAfterHandOffFires")
    in_place = bool(landed) and held and settled_ok and (line_close_after_handoff_fires or 0) >= 2
    result = {"checks": [{"check": c["check"], "ok": c["ok"]} for c in checks], "bubble_before": before,
              "bubble_after": after, "incoming_rows": [incoming_before, incoming_after],
              "top_range_during_handoff": [min(tops), max(tops)] if tops else None, "held_before_reply": held,
              "line_at_handoff": line_at_handoff, "line_close_after_handoff_fires": line_close_after_handoff_fires, "settled_ok": settled_ok, "in_place": in_place}
    json.dump({"result": result, "checks": checks, "handoff": frames}, open(os.path.join(opts.out, "live-frames.json"), "w"), indent=1)
    print(json.dumps(result, indent=1), flush=True)
    if not all(c["ok"] for c in checks) or not in_place:
        sys.exit("FAIL: Home did not show the Chief's live run as required (live-frames.json)")


def launch_app():
    global app
    config = os.path.join(SCRATCH, "cmux.json")
    open(config, "w").write("{}")
    open(os.path.join(SCRATCH, "ghostty"), "w").write("")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900", "MUX_HARNESS": os.environ.get("MUX_HARNESS", "claude-sr"), **home_classic.ENV}
    for name in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "SUBROUTER_URL"):
        if os.environ.get(name):
            env[name] = os.environ[name]
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 600):
        sys.exit("the tagged app did not come up")
    if not home_classic.require(rpc):  # classic Home: these checks drive the native transcript
        sys.exit(2)
    rpc("action.run", {"id": "home.show"})
    wait(lambda: (rpc("debug.home.drive", {"action": "geometry"}) or {}).get("ok"), 20)
    if not wait(chief_row, 180):
        sys.exit(f"no Chief conversation: {json.dumps(rpc('debug.home'))[:600]}")


def restart_app():
    """Ends only the app process this script started (SIGTERM; the Chief's daemon keeps the run) and launches it again."""
    app.send_signal(signal.SIGTERM)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        os.kill(app.pid, signal.SIGKILL)
        app.wait(timeout=10)
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    launch_app()


def main():
    global app
    if os.path.exists(SOCKET):
        if "error" not in (rpc("debug.windows", timeout=3) or {"error": 1}):
            sys.exit(f"{SOCKET} answers: another {TAG} app runs; pick a fresh tag")
        os.unlink(SOCKET)  # left by an ended run of this tag: nothing listens
    stop_sessions()
    cache = os.path.expanduser(f"~/Library/Caches/cmux-home/cmux-chief-{fnv1a32(MUX_HOME)}")
    if os.path.isdir(cache):
        shutil.rmtree(cache)
    launch_app()
    if not wait(lambda: "daemon connected" in host_log(), 180):
        sys.exit("the Chief host did not connect")
    if opts.live_frames:
        session = ((rpc("debug.home") or {}).get("chief_owner") or {}).get("session")
        return live_frames(chief_row()["id"], session)
    if opts.late_turn:
        session = ((rpc("debug.home") or {}).get("chief_owner") or {}).get("session")
        return late_turn(chief_row()["id"], session)
    # A warm-up turn, so the measured turn does not include the session start.
    for action, extra in (("focus", {}), ("type", {"text": "Reply with one word: READY."}), ("send", {})):
        rpc("debug.home.drive", {"action": action, **extra})
    wait(lambda: any("READY" in (m.get("text") or "") and m.get("author") == "agent_mux"
                     for m in (chief_row() or {}).get("shown_tail", [])), 180, step=1)
    time.sleep(3)

    stop = threading.Event()
    t0 = time.time()
    samples = []

    def snapshots():
        k = 0
        while not stop.is_set():
            at = time.time() - t0
            rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"frame-{k:03d}-{at:06.2f}s.png")}, timeout=10)
            k += 1
            stop.wait(max(0.0, 0.5 - ((time.time() - t0) - at)))

    def reads():
        while not stop.is_set():
            row = chief_row() or {}
            draft = row.get("draft") or {}
            tail = [m for m in row.get("shown_tail", []) if m.get("author") == "agent_mux"]
            live = row.get("live") or {}
            bubble = chief_bubble()
            samples.append({"t": round(time.time() - t0, 3), "typing": "agent_mux" in row.get("typing", []),
                            "draft_chars": len(draft.get("text") or ""), "posted": len(tail),
                            "live_chars": len(live.get("text") or ""), "activity": live.get("activity"),
                            "status_line": drive("texts", limit=1).get("statusLine"),
                            "bubble_bottom": bubble["balloon"]["y"] if bubble else None,
                            "bubble_top": bubble["balloon"]["y"] + bubble["balloon"]["height"] if bubble else None,
                            "last_posted": (tail[-1].get("text") or "")[:60] if tail else ""})
            stop.wait(0.25)

    posted_before = len([m for m in (chief_row() or {}).get("shown_tail", []) if m.get("author") == "agent_mux"])
    owner_events = []

    def owner_order():
        """The owner's subscribe stream for this turn as a live client sees it (event order, seq, receive time)."""
        session = ((rpc("debug.home") or {}).get("chief_owner") or {}).get("session")
        try:
            line = Line(chief_socket(session))
            line.request("set-client-info", name="home-streaming-live order probe",
                         capabilities=["chief-live-v1", "conversation-runs-v1", "conversation-draft-events-v1"])
            line.request("subscribe")
            line.sock.settimeout(0.5)
        except (OSError, RuntimeError, SystemExit) as error:
            owner_events.append({"error": str(error)})
            return
        while not stop.is_set():
            while b"\n" not in line.buf:
                try:
                    chunk = line.sock.recv(1 << 16)
                except socket.timeout:
                    chunk = None
                    break
                if not chunk:
                    return
                line.buf += chunk
            if chunk is None and b"\n" not in line.buf:
                continue
            raw, line.buf = line.buf.split(b"\n", 1)
            try:
                event = json.loads(raw)
            except ValueError:
                continue
            name = event.get("event")
            if name not in ("conversation-live", "conversation-run-changed", "conversation-changed", "conversation-typing", "conversation-draft"):
                continue
            frame = event.get("frame") or {}
            item = {"t": round(time.time() - t0, 4), "event": name}
            if frame:
                item.update({k: frame.get(k) for k in ("type", "run", "step", "kind", "seq", "final", "line") if k in frame})
                if "text" in frame:
                    item["chars"] = len(frame["text"])
            if name == "conversation-run-changed":
                run = event.get("run") or {}
                item.update({"run": run.get("id"), "status": run.get("status"),
                             "steps": [st.get("id") for st in event.get("steps") or []]})
            if name == "conversation-changed":
                change = event.get("change") or {}
                message = change.get("message") or {}
                item.update({"kind": change.get("kind") or change.get("type"), "client_msg_id": message.get("client_msg_id"),
                             "author": message.get("author")})
            if name == "conversation-typing":
                item.update({"participant": event.get("participant"), "on": event.get("on")})
            if name == "conversation-draft":
                d = event.get("item") or {}
                item.update({"turn": d.get("turn"), "seq": d.get("seq"), "done": d.get("done"), "chars": len(d.get("text") or "")})
            owner_events.append(item)

    threads = [threading.Thread(target=snapshots, daemon=True), threading.Thread(target=reads, daemon=True),
               threading.Thread(target=owner_order, daemon=True)]
    for thread in threads:
        thread.start()
    for action, extra in (("focus", {}), ("type", {"text": PROMPT}), ("send", {})):
        rpc("debug.home.drive", {"action": action, **extra})
    wait(lambda: samples and samples[-1]["posted"] > posted_before, opts.timeout, step=0.25)
    time.sleep(2)
    stop.set()
    for thread in threads:
        thread.join(timeout=15)
    first_live = next((s["t"] for s in samples if s["live_chars"] > 0), None)
    first_line = next((s["t"] for s in samples if s["status_line"]), None)
    lines = sorted({s["status_line"].split(" · ")[0] for s in samples if s["status_line"]})
    first_draft = next((s["t"] for s in samples if s["draft_chars"] > 0), None)
    first_typing = next((s["t"] for s in samples if s["typing"]), None)
    posted = next((s["t"] for s in samples if s["posted"] > posted_before), None)
    growth = [(s["t"], s["draft_chars"]) for s in samples if s["draft_chars"] > 0]
    live_growth = [(s["t"], s["live_chars"]) for s in samples if s["live_chars"] > 0]
    result = {"first_typing_s": first_typing, "first_draft_text_s": first_draft, "reply_posted_s": posted,
              "first_live_text_s": first_live, "first_status_line_s": first_line, "status_lines": lines,
              "live_growth": live_growth[:: max(1, len(live_growth) // 12)],
              "draft_samples": len(growth), "draft_growth": growth[:: max(1, len(growth) // 12)],
              "frames": len([f for f in os.listdir(opts.out) if f.startswith("frame-")])}
    # The reply's hand-off: the Chief bubble's top and bottom just before and after the reply posted.
    if posted is not None:
        pre = [s for s in samples if s["t"] < posted and s["bubble_top"] is not None]
        post = [s for s in samples if s["t"] >= posted and s["bubble_top"] is not None]
        if pre and post:
            result["handoff"] = {"before": {k: pre[-1][k] for k in ("t", "bubble_top", "bubble_bottom", "status_line")},
                                 "after": {k: post[0][k] for k in ("t", "bubble_top", "bubble_bottom", "status_line")},
                                 "settled": {k: post[-1][k] for k in ("t", "bubble_top", "bubble_bottom")}}
    # cx-06vn1: the activity line closes on a display frame after the one that first shows the reply in the
    # bubble's place (lineCloseAfterHandOffFires >= 2: the frame that presents the hand-off commit still has the line).
    # Sampling the socket cannot see one frame; the app counts its display link fires from the hand-off dispatch.
    result["line_close_after_handoff_fires"] = drive("texts").get("lineCloseAfterHandOffFires")
    json.dump(owner_events, open(os.path.join(opts.out, "owner-events.json"), "w"), indent=1)
    shutil.copy(os.path.join(MUX_HOME, "host.log"), os.path.join(opts.out, "chief-host.log")) if os.path.exists(os.path.join(MUX_HOME, "host.log")) else None
    json.dump({"result": result, "samples": samples}, open(os.path.join(opts.out, "timeline.json"), "w"), indent=1)
    print(json.dumps(result, indent=1), flush=True)
    if (result["line_close_after_handoff_fires"] or 0) < 2:
        sys.exit(f"FAIL: the activity line closed {result['line_close_after_handoff_fires']} display frame(s) after the reply's hand-off was dispatched; "
                 "it must stay through the frame that first shows the reply (cx-06vn1, timeline.json)")


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup()
