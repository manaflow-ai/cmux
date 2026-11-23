"""pair-e2e's terminal-chat leg: a chat handed to a terminal, followed by a paired iPhone.

PR cmux#50782 (Settings > Chats > "Write to a Chat a Terminal Runs", `agents.chats.terminalChatWritable`)
says three things about a chat handed to a cmux terminal (`acpmux resume-here`), and this leg proves each
on a real tagged DEBUG Mac and a real simulator iPhone paired to it, with a simulator video:

  (a) what is typed in the terminal shows live on the phone;
  (b) a send from the phone is refused with `remote.terminal_session`, and never reaches the terminal;
  (c) with the setting turned off the chat on the phone is View Only (no composer).

No Claude or Codex account is involved. The Mac's acpmux daemon (its home is the rig's, `ACPMUX_HOME`) has a
profile `fakeclaude` that runs the acpmux test fake agent (cmux-tui/crates/acpmux/tests/fake_agent.py); the
hand-off is the real `acpmux resume-here`, run in a pty, which execs `claude --resume ID`: a shim on PATH that
runs the acpmux test fake Claude Code (fake_claude_terminal.py: transcript, inbox and typed lines as Claude Code
2.1 writes them). The daemon binds the pid the kernel gives it, as for a real terminal.

Used by cmux_next_pair_e2e.py: `prepare()` before the Mac starts, `run_leg()` once the phone is paired.
"""
import json, os, pty, re, shutil, signal, stat, subprocess, threading, time

CHAT_NAME = "pair-e2e-chat"
FIRST_PROMPT = "pair-e2e terminal chat probe"
FAKE_AGENT = "cmux-tui/crates/acpmux/tests/fake_agent.py"
FAKE_CLAUDE = "cmux-tui/crates/acpmux/tests/fake_claude_terminal.py"
REFUSED = re.compile(r"remote\.terminal_session|runs in a terminal on the Mac")

SHIM = """#!/bin/sh
# `claude --resume ID`, as `acpmux resume-here` runs it: the acpmux test fake Claude Code.
while [ $# -gt 0 ]; do
  if [ "$1" = "--resume" ]; then id="$2"; shift; fi
  shift
done
transcript=$(ls "$CLAUDE_CONFIG_DIR"/projects/*/"$id".jsonl 2>/dev/null | head -n 1)
FAKE_CONFIG="$CLAUDE_CONFIG_DIR" FAKE_SESSION="$id" FAKE_TRANSCRIPT="$transcript" FAKE_LOG="$FAKE_LOG" \\
  FAKE_TURN_MS=1500 exec python3 "$FAKE_CLAUDE_PY"
"""


def prepare(rig, root):
    """The rig's acpmux home (the fake profile), Claude store and `claude` shim; the environment that points the
    Mac app (and so its daemon) and the terminal at them."""
    home, claude, bindir = (os.path.join(rig, d) for d in ("acpmux", "claude", "bin"))
    for d in (home, claude, bindir):
        os.makedirs(d, mode=0o700, exist_ok=True)
    fake_agent = os.path.join(root, FAKE_AGENT)
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"agents": {"fakeclaude": {"argv": ["python3", fake_agent], "family": "claude",
                                             "env": {"CLAUDE_CONFIG_DIR": claude}}}}, f)
    shim = os.path.join(bindir, "claude")
    with open(shim, "w") as f:
        f.write(SHIM)
    os.chmod(shim, os.stat(shim).st_mode | stat.S_IXUSR)
    return {"ACPMUX_HOME": home, "CLAUDE_CONFIG_DIR": claude}


def _nodes(tree):
    stack = tree if isinstance(tree, list) else [tree]
    while stack:
        node = stack.pop(0)
        yield node
        stack.extend(node.get("children") or [])


def _text(node):
    return " ".join(str(node.get(k) or "") for k in ("AXLabel", "AXValue", "AXUniqueId", "title"))


class Phone:
    """The simulator iPhone, driven through AXe (the rig's UI driver)."""

    def __init__(self, simctl, udid, shot, out):
        self.simctl, self.udid, self.shot, self.out, self.dumps = simctl, udid, shot, out, 0

    def tree(self, save=None):
        try:
            raw = subprocess.run(["axe", "describe-ui", "--udid", self.udid], capture_output=True, text=True,
                                 timeout=60).stdout
            tree = json.loads(raw or "[]")
        except (ValueError, subprocess.TimeoutExpired, OSError):
            return []
        if save:
            with open(os.path.join(self.out, f"phone-tree-{save}.json"), "w") as f:
                json.dump(tree, f)
        return list(_nodes(tree))

    def find(self, nodes, needle=None, ident=None, label=None):
        for node in nodes:
            if ident and node.get("AXUniqueId") == ident:
                return node
            if label and (node.get("AXLabel") or "") == label:
                return node
            if needle and needle.lower() in _text(node).lower():
                return node
        return None

    def tap(self, node):
        f = node.get("frame") or {}
        x, y = f.get("x", 0) + f.get("width", 0) / 2, f.get("y", 0) + f.get("height", 0) / 2
        subprocess.run(["axe", "tap", "--udid", self.udid, "-x", f"{x:.1f}", "-y", f"{y:.1f}", "--tap-style", "simulator"],
                       capture_output=True, timeout=25)

    def type(self, text):
        subprocess.run(["axe", "type", text, "--udid", self.udid], capture_output=True, timeout=60)

    def until(self, pred, seconds, every=1.5, save=None):
        """The first tree (as nodes) for which pred(nodes) is truthy within SECONDS, else None."""
        deadline = time.monotonic() + seconds
        while True:
            nodes = self.tree()
            hit = pred(nodes)
            if hit:
                return nodes
            if time.monotonic() > deadline:
                if save:
                    self.tree(save=save)
                return None
            time.sleep(every)


class Video:
    def __init__(self, simctl, udid, path):
        self.path = path
        self.proc = subprocess.Popen(simctl + ["io", udid, "recordVideo", "--codec", "h264", "--force", path],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)  # the process this script started
            try:
                self.proc.wait(30)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        try:
            return os.path.getsize(self.path)
        except OSError:
            return 0


def _find_ids(obj, name, found):
    """Session ids named NAME in any JSON the CLI printed: {sessionId|id, agentSessionId}."""
    if isinstance(obj, dict):
        if str(obj.get("name") or "").lower() == name.lower():
            found.append(obj)
        for v in obj.values():
            _find_ids(v, name, found)
    elif isinstance(obj, list):
        for v in obj:
            _find_ids(v, name, found)
    return found


def run_leg(ctx):
    """ctx: dict(mac_app, env, rig, out, screens, simctl, udid, bundle, phone_env, phone_shot, note, rpc,
    config_path, settings, phone_launch). Returns {"a": bool, "b": bool, "c": bool}."""
    note, out = ctx["note"], os.path.join(ctx["out"], "terminal-chat")
    os.makedirs(out, exist_ok=True)
    env, rig = ctx["env"], ctx["rig"]
    acpmux = os.path.join(ctx["mac_app"], "Contents/Resources/bin/acpmux")
    fake_log = os.path.join(rig, "fake-claude.log")
    result = {"a": False, "b": False, "c": False}
    cenv = dict(env, FAKE_LOG=fake_log, FAKE_CLAUDE_PY=os.path.join(ctx["root"], FAKE_CLAUDE),
                PATH=os.path.join(rig, "bin") + os.pathsep + env.get("PATH", os.defpath))

    def cli(args, name, timeout=120):
        r = subprocess.run([acpmux, *args], env=cenv, capture_output=True, text=True, timeout=timeout)
        with open(os.path.join(out, f"{name}.txt"), "w") as f:
            f.write(f"$ acpmux {' '.join(args)}\nexit {r.returncode}\n--- stdout\n{r.stdout}\n--- stderr\n{r.stderr}\n")
        return r

    def fake_lines(kind):
        try:
            return [l.split(" ", 2) for l in open(fake_log).read().splitlines() if l.startswith(kind + " ")]
        except OSError:
            return []

    cwd = os.path.join(rig, "terminal-chat-cwd")
    os.makedirs(cwd, exist_ok=True)
    # ---- the Mac: a chat, then its hand-off to a terminal ------------------------------------------
    r = cli(["new", "-m", "fakeclaude", "-n", CHAT_NAME, "--cwd", cwd, "--machine", "local", "--detach", FIRST_PROMPT],
            "new")
    session = {}

    def listed():
        ls = cli(["ls", "--json"], "ls")
        try:
            hits = _find_ids(json.loads(ls.stdout or "null"), CHAT_NAME, [])
        except ValueError:
            return {}
        return hits[0] if hits else {}

    def conversation():
        s = listed()
        return s if s.get("agentSessionId") else {}

    for _ in range(40):
        session = conversation()
        if session:
            break
        time.sleep(1.5)
    sid = session.get("sessionId") or session.get("id") or CHAT_NAME
    asid = session.get("agentSessionId")
    note(f"- terminal chat: chat {CHAT_NAME!r} created (acpmux new exit {r.returncode}), "
         f"{'conversation id ' + asid[:8] if asid else 'NO conversation id (FAIL)'}")
    if not asid:
        return result
    time.sleep(4)  # its first turn ends
    projects = os.path.join(env["CLAUDE_CONFIG_DIR"], "projects", "-pair-e2e")
    os.makedirs(projects, exist_ok=True)
    transcript = os.path.join(projects, f"{asid}.jsonl")
    stamp = "2026-11-24T00:00:00.000Z"
    with open(transcript, "a") as f:
        for role, text in (("user", FIRST_PROMPT), ("assistant", "ANSWER " + FIRST_PROMPT)):
            msg = {"role": role, "content": text} if role == "user" else \
                {"role": role, "stop_reason": "end_turn", "content": [{"type": "text", "text": text}]}
            f.write(json.dumps({"type": role, "cwd": cwd, "sessionId": asid, "timestamp": stamp, "message": msg}) + "\n")
    master, slave = pty.openpty()
    term = subprocess.Popen([acpmux, "resume-here", sid], env=cenv, stdin=slave, stdout=slave, stderr=slave,
                            start_new_session=True, cwd=cwd)
    os.close(slave)
    tty_out = open(os.path.join(out, "terminal.log"), "wb")

    def drain():
        while True:
            try:
                data = os.read(master, 4096)
            except OSError:
                return
            if not data:
                return
            tty_out.write(data)
            tty_out.flush()

    threading.Thread(target=drain, daemon=True).start()
    video = None
    try:
        ready = None
        for _ in range(60):
            ready = fake_lines("READY")
            if ready or term.poll() is not None:
                break
            time.sleep(1)
        summary = listed()
        handed = bool(ready)
        note(f"- terminal chat: handed to a terminal (acpmux resume-here -> the fake Claude Code, pid {term.pid}): "
             f"{'READY' if handed else 'NOT ready (FAIL)'}; chat summary watching={summary.get('watching')!r} "
             f"tags={summary.get('tags')!r}")
        if not handed:
            return result

        # ---- the phone: open the chat ----------------------------------------------------------------
        phone = Phone(ctx["simctl"], ctx["udid"], ctx["phone_shot"], out)
        subprocess.run(ctx["simctl"] + ["terminate", ctx["udid"], ctx["bundle"]], capture_output=True)
        subprocess.run(ctx["simctl"] + ["launch", ctx["udid"], ctx["bundle"]], env=ctx["phone_env"], check=True,
                       capture_output=True)
        video = Video(ctx["simctl"], ctx["udid"], os.path.join(out, "terminal-chat.mp4"))
        phone_rpc = ctx["streams_add"](["xcrun", "simctl", "--set", ctx["sims"], "spawn", ctx["udid"], "log", "stream",
                                        "--level", "debug", "--style", "compact", "--predicate",
                                        'subsystem == "dev.cmux.mobile" AND category == "acpmux-rpc"'],
                                       os.path.join(out, "phone-acpmux-rpc.log"))
        time.sleep(6)

        opened = False
        for attempt in range(14):
            nodes = phone.tree(save=f"home-{attempt}" if attempt < 4 else None)
            if phone.find(nodes, ident="chat.composer.field"):
                opened = True
                break
            row = phone.find(nodes, needle=CHAT_NAME) or phone.find(nodes, needle=FIRST_PROMPT)
            if row:
                phone.tap(row)
            else:
                mac = phone.find(nodes, ident="home.mac") or phone.find(nodes, needle="home.mac") or \
                    phone.find(nodes, needle=ctx["mac_name"])
                if mac:
                    phone.tap(mac)
            time.sleep(3)
        shot = ctx["phone_shot"]("terminal-chat-1-open")
        phone.tree(save="open")
        note(f"- terminal chat, phone: chat {'open with its composer' if opened else 'NOT opened or no composer'}: {shot}")

        # ---- (a) typing in the terminal shows live on the phone ----------------------------------------
        marker = "typed in the terminal " + os.urandom(3).hex()
        os.write(master, (marker + "\n").encode())
        seen = phone.until(lambda n: phone.find(n, needle=marker), 45, save="a-miss")
        result["a"] = seen is not None
        note(f"- (a) typed in the terminal, live on the phone: {'PASS' if seen else 'FAIL'} ({marker!r}); "
             f"fake Claude Code ran it: {'yes' if any(marker in l[2] for l in fake_lines('RUN')) else 'NO'}; "
             f"{ctx['phone_shot']('terminal-chat-2-typed-in-terminal')}")

        # ---- (b) a send from the phone is refused with remote.terminal_session --------------------------
        sent = "from the phone " + os.urandom(3).hex()
        nodes = phone.tree()
        field = phone.find(nodes, ident="chat.composer.field")
        refused = None
        if field:
            phone.tap(field)
            time.sleep(1)
            phone.type(sent)
            time.sleep(1)
            nodes = phone.tree(save="b-typed")
            send = phone.find(nodes, label="Send")
            if send:
                phone.tap(send)
            refused = phone_rpc.wait(REFUSED, 30) or phone.until(
                lambda n: phone.find(n, needle="runs in a terminal on the Mac"), 15, save="b-miss")
        time.sleep(2)
        reached = any(sent in l[2] for l in fake_lines("RECV") + fake_lines("RUN"))
        result["b"] = bool(field) and bool(refused) and not reached
        note(f"- (b) a send from the phone is refused with remote.terminal_session: {'PASS' if result['b'] else 'FAIL'} "
             f"(composer {'found' if field else 'MISSING'}, refusal {'seen' if refused else 'NOT seen'}, "
             f"reached the terminal's Claude Code: {'YES' if reached else 'no'}); "
             f"{ctx['phone_shot']('terminal-chat-3-send-refused')}")

        # ---- (c) the setting off: the chat on the phone is View Only -----------------------------------
        ctx["settings"].setdefault("agents", {}).setdefault("chats", {})["terminalChatWritable"] = False
        tmp = ctx["config_path"] + ".tmp"
        with open(tmp, "w") as f:
            json.dump(ctx["settings"], f)
        os.replace(tmp, ctx["config_path"])
        view_only = phone.until(
            lambda n: phone.find(n, ident="chat.composer.field") is None and (
                phone.find(n, needle="View Only") or phone.find(n, needle=CHAT_NAME) or phone.find(n, needle=marker)),
            60, every=2, save="c-miss")
        phone.tree(save="c-final")
        time.sleep(1)
        after = listed()
        result["c"] = view_only is not None
        note(f"- (c) setting off, the chat on the phone is View Only: {'PASS' if result['c'] else 'FAIL'} "
             f"(composer gone: {'yes' if view_only else 'no'}; Mac chat summary watching={after.get('watching')!r} "
             f"tags={after.get('tags')!r}); {ctx['phone_shot']('terminal-chat-4-view-only')}")
    finally:
        if video:
            size = video.stop()
            note(f"- terminal chat video: terminal-chat/terminal-chat.mp4 ({size} bytes)")
        try:
            os.close(master)
        except OSError:
            pass
        if term.poll() is None:  # the process this leg started: resume-here, which became the fake Claude Code
            term.terminate()
            try:
                term.wait(10)
            except subprocess.TimeoutExpired:
                term.kill()
        tty_out.close()
        for name in ("fake-claude.log",):
            try:
                shutil.copy(os.path.join(rig, name), os.path.join(out, name))
            except OSError:
                pass
        try:  # the acpmux daemon's own files: evidence only
            shutil.copy(os.path.join(env["ACPMUX_HOME"], "config.json"), os.path.join(out, "acpmux-config.json"))
            shutil.copy(os.path.join(env["ACPMUX_HOME"], "chat-settings.json"), os.path.join(out, "chat-settings.json"))
        except OSError:
            pass
    return result
