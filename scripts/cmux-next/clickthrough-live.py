#!/usr/bin/env python3
"""Click-through correctness check of cmux NEXT's agent chats on a tagged build (Leo 2026-10-18).

Pass 1, picks stick: a model, reasoning level and access mode picked before or after a chat starts
is exactly what the chat runs and what its chips still show after a new tab, a folder pick, a chat
switch and a relaunch. Full access (bypassPermissions) is the start mode. A default never takes back
an explicit pick, and switching chats never changes another chat's model.
Pass 2, switching is fast and still: across --chats chats in several workspaces, each switch shows
the chat's content at once, and nothing on the page moves, pops in or scrolls after that first paint
(`debug.agent_pane layout_watch`); the sidebar's workspace order never changes from a switch.

Everything is driven as a person drives it: clicks on the chips and menu rows
(`debug.agent_pane click`), keys through the app's key router (`debug.key`: Cmd-T, Cmd-Shift-[ and
], Ctrl-Cmd-[ and ]), typed prompts and a click on Send. The chats run on the fake ACP agent
(cmux-tui/crates/acpmux/tests/fake_agent.py) registered as acpmux's `claude` harness, so the
curated Claude models apply and no sign-in or tokens are needed. What the chat runs comes from
acpmux's session list and attach, never from the page.

The app runs with its own ACPMUX_HOME, XDG_CONFIG_HOME and fixture folders, without activating
(CMUX_NEXT_NO_ACTIVATE), and the tag's daemons end with the script (tag_teardown.py). Never point it
at the user's running cmux: it refuses a bundle id outside com.cmuxterm.app.debug.*.

Usage: clickthrough-live.py --tag <tag> [--app PATH] [--out DIR] [--passes 1,2] [--chats 12]
                            [--first-content-ms 150]
Exit status 0 when every check passes; the table of results is printed and written to
<out>/results.md and <out>/results.json.
"""
import argparse, concurrent.futures, glob, json, os, plistlib, shutil, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FAKE = os.path.join(ROOT, "cmux-tui/crates/acpmux/tests/fake_agent.py")
sys.path.insert(0, HERE)
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
parser.add_argument("--tag", required=True)
parser.add_argument("--app", help="the tagged app (default: the tag's DerivedData build)")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS"))
parser.add_argument("--passes", default="1,2")
parser.add_argument("--chats", type=int, default=12, help="chats pass 2 switches between (at least 10)")
parser.add_argument("--first-content-ms", type=float, default=150,
                    help="the most a switch may take to show the chat's content")
opts = parser.parse_args()
PASSES = {p.strip() for p in opts.passes.split(",")}
OUT = opts.out or tempfile.mkdtemp(prefix=f"clickthrough-{opts.tag}-")
os.makedirs(OUT, exist_ok=True)
WORK = tempfile.mkdtemp(prefix=f"clickthrough-{opts.tag}-work-")
LOG = open(os.path.join(OUT, "live.log"), "a")


def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n")
    LOG.flush()


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV*.app")))), None)
if not APP or not os.path.isdir(APP):
    sys.exit(f"no app for tag {opts.tag}; build it with ./scripts/reload.sh --tag {opts.tag} --build-only or pass --app")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
if not INFO.get("CFBundleIdentifier", "").startswith("com.cmuxterm.app.debug."):
    sys.exit(f"refusing {INFO.get('CFBundleIdentifier')}: only a tagged debug build (com.cmuxterm.app.debug.*)")
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
ACP_HOME = os.path.join(WORK, "acpmux")
ACP_SOCKET = os.path.join(WORK, "acp.sock")
XDG = os.path.join(WORK, "xdg")
PROJECTS = os.path.join(WORK, "projects")
# What the fake agent received, in order (kept with the results: which set lost a pick).
CALLS = os.path.join(OUT, "agent-calls.jsonl")
RESULTS = []  # (pass, scenario, ok, detail)


def check(pass_name, scenario, ok, detail=""):
    detail = "" if ok else str(detail)
    RESULTS.append({"pass": pass_name, "scenario": scenario, "ok": bool(ok), "detail": detail})
    say(("ok   " if ok else "FAIL ") + f"[{pass_name}] {scenario}" + (f": {detail}" if detail and not ok else ""))
    return bool(ok)


def rpc(method, params=None, timeout=60):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(SOCKET)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 22)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def page(action, **params):
    reply = rpc("debug.agent_pane", dict(action=action, **params), timeout=90)
    return reply if isinstance(reply, dict) else {"error": reply}


def key(name, modifiers=None):
    return rpc("debug.key", {"key": name, "modifiers": modifiers or []})


def type_text(text):
    for char in text:
        key("space" if char == " " else char)


def wait(predicate, timeout, step=0.1):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # harness wait for the app, not app code
    return None


def snap(name):
    return rpc("debug.window_snapshot", {"path": os.path.join(OUT, f"{name}.png")})


FULL_ACCESS = ("Full access", "Bypass Permissions")


def full_access(label):
    """The access chip names full access (Claude Code's bypassPermissions; the fake names it so)."""
    return any(name in label for name in FULL_ACCESS)


def chips():
    """The composer's chips as drawn: {model, effort, mode} labels ("" when the chip is missing)."""
    composer = page("chat_state").get("composer") or {}
    return {"model": composer.get("Model", ""), "effort": composer.get("Effort", ""), "mode": composer.get("Mode", "")}


def acp(method, params=None):
    """One request to the tag's acpmux as a local client."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(20)
            conn.connect(ACP_SOCKET)
            stream = conn.makefile("rwb")
            for rid, (m, p) in enumerate([("initialize", {"protocolVersion": 1, "clientCapabilities": {}}),
                                          (method, params or {})], 1):
                stream.write((json.dumps({"jsonrpc": "2.0", "id": rid, "method": m, "params": p}) + "\n").encode())
                stream.flush()
                while True:
                    line = json.loads(stream.readline())
                    if line.get("id") == rid:
                        break
            return line.get("result") or {}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def sessions():
    # The daemon may still be starting (a relaunch): ask again for a few seconds.
    reply = wait(lambda: (lambda r: r if "error" not in r else None)(acp("_acpmux/sessions")), 10, 0.3) or {}
    found = reply.get("sessions") or []
    return {s.get("sessionId"): s for s in found if isinstance(s, dict)}


def session_effort(session_id):
    attached = acp("_acpmux/attach", {"sessionId": session_id, "limit": 1})
    options = (attached.get("session") or {}).get("configOptions") or []
    return next((o.get("currentValue") for o in options if o.get("id") == "effort"), None)


def shown_session():
    return page("chat_state").get("sessionId")


# ---- the app --------------------------------------------------------------------------------

def setup():
    for path in ["proj-a", "proj-b", "proj-c", "proj-d"]:
        os.makedirs(os.path.join(PROJECTS, path, ".git"), exist_ok=True)
    os.makedirs(ACP_HOME, exist_ok=True)
    os.makedirs(os.path.join(XDG, "cmux"), exist_ok=True)
    fake = {"argv": ["python3", FAKE], "env": {"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude", "FAKE_CALLS": CALLS, "CLAUDE_CONFIG_DIR": os.path.join(WORK, "claude-home"),
                                               "CODEX_HOME": os.path.join(WORK, "codex-home")}}
    config = {"harnesses": {"claude": fake, "codex": fake}, "defaultHarness": "claude"}
    with open(os.path.join(ACP_HOME, "config.json"), "w") as f:
        json.dump(config, f, indent=1)
    # The tag's own app state starts empty (only this tag's folder; never another build's).
    tag_state = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{opts.tag}")
    if os.path.isdir(tag_state) and not os.path.islink(tag_state):
        os.rename(tag_state, f"{tag_state}.old-{int(time.time())}")


APP_PROC = None


def launch():
    global APP_PROC
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = dict(os.environ)
    for name in [n for n in env if n.startswith(("CMUX_SOCKET", "CMUX_WORKSPACE", "CMUX_SURFACE", "CMUX_TUI_"))]:
        env.pop(name)
    env.update({"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
                "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,900",
                "ACPMUX_HOME": ACP_HOME, "ACPMUX_SOCKET": ACP_SOCKET, "XDG_CONFIG_HOME": XDG})
    APP_PROC = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(OUT, "app.log"), "a"),
                                stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, cwd=PROJECTS)
    say("app pid", APP_PROC.pid)
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180, 0.5):
        raise SystemExit("the app did not come up")
    wait(lambda: (rpc("debug.surfaces") or {}).get("windows"), 60, 0.5)
    wait(lambda: page("chat_state").get("connection") == "connected", 60, 0.3)


def quit_keep_sessions():
    rpc("action.run", {"action": "quitKeepSessions", "origin": "script"})
    if APP_PROC and wait(lambda: APP_PROC.poll() is not None, 30, 0.2) is None:
        raise SystemExit("the app did not quit")


def pick(chip_label, row):
    """Opens the chip whose label is `chip_label` and clicks `row`; for the model menu it types
    the row's name first, as a person may, so a menu covered by other chrome cannot eat the click."""
    page("click", text=chip_label)
    time.sleep(0.4)
    reply = page("click", text=row)
    time.sleep(0.6)
    return reply.get("clicked") is True


def send_from_composer(text):
    """Types `text` into the composer and clicks Send, as a person does."""
    page("click", selector="textarea")
    time.sleep(0.2)
    type_text(text)
    time.sleep(0.2)
    page("click", selector='button[aria-label*="Send"], button[aria-label*="Ask"]')


def answer_trust():
    if wait(lambda: page("click", text="Trust").get("clicked"), 6, 0.5):
        say("answered the folder trust question")


def new_tab_chat(folder, prompt, model=None, effort=None):
    """Cmd-T, the optional picks, a folder pick, a prompt sent with a click; returns the session id."""
    before = set(sessions())
    key("t", ["command"])
    time.sleep(1.2)
    if model:
        pick(chips()["model"], model)
    if effort:
        pick(chips()["effort"], effort)
    page("pick_folder", cwd=os.path.join(PROJECTS, folder))
    time.sleep(0.8)
    picked = chips()
    send_from_composer(prompt)
    answer_trust()
    # The chip picks started a deferred session in the page's first folder: the chat is the new
    # session in `folder` that took this prompt.
    cwd = os.path.realpath(os.path.join(PROJECTS, folder))

    def started():
        return [sid for sid, s in sessions().items() if sid not in before and s.get("lastPrompt") == prompt
                and os.path.realpath(s.get("cwd") or "") == cwd]
    new = wait(started, 20, 0.3)
    session_id = new[0] if new else None
    wait(lambda: shown_session() == session_id, 10, 0.2)
    wait(lambda: page("chat_state").get("lastAssistant"), 10, 0.3)
    time.sleep(0.5)
    return session_id, picked


# ---- pass 1 -----------------------------------------------------------------------------------

def pass1():
    P = "picks stick"
    first = chips()
    snap("p1-first-new-tab")
    check(P, "first New Tab after launch draws model, reasoning and access chips", all(first.values()), json.dumps(first))

    chat1, picked = new_tab_chat("proj-a", "first chat", model="Haiku 5.5", effort="Low")
    check(P, "a pick made before a folder pick holds across it (New Tab)",
          "Haiku" in picked["model"] and picked["effort"] == "Low", json.dumps(picked))
    runs = (sessions().get(chat1, {}).get("model"), session_effort(chat1))
    check(P, "the chat runs exactly the picked model and reasoning", runs == ("claude-haiku-5-5", "low"), runs)
    check(P, "the chat starts in full access", sessions().get(chat1, {}).get("currentModeId") == "bypassPermissions",
          sessions().get(chat1, {}).get("currentModeId"))
    shown = chips()
    snap("p1-chat1")
    check(P, "the chat's chips still show the picks and full access",
          "Haiku" in shown["model"] and shown["effort"] == "Low" and full_access(shown["mode"]), json.dumps(shown))

    # A New Tab after the pick names what its chat will start on, from its first frame.
    key("t", ["command"])
    time.sleep(0.25)
    early = chips()
    snap("p1-new-tab-after-pick")
    time.sleep(1.5)
    settled = chips()
    check(P, "a New Tab after a pick names the pick from its first frame (no stale default)",
          "Haiku" in early["model"] and early["effort"] == "Low", f"at 250 ms {json.dumps(early)}, at 1.75 s {json.dumps(settled)}")
    key("w", ["command"])
    time.sleep(0.8)

    chat2, picked2 = new_tab_chat("proj-b", "second chat", model="Sonnet 5.5")
    check(P, "a second chat starts on its own pick", sessions().get(chat2, {}).get("model") == "claude-sonnet-5-5",
          sessions().get(chat2, {}).get("model"))
    pick(chips()["effort"], "High")
    wait(lambda: session_effort(chat2) == "high", 5, 0.3)
    check(P, "a reasoning pick in a running chat reaches the agent", session_effort(chat2) == "high", session_effort(chat2))

    key("[", ["command", "shift"])
    wait(lambda: shown_session() == chat1, 5)
    time.sleep(0.4)
    one = chips()
    check(P, "switching chats never changes the other chat's picks",
          "Haiku" in one["model"] and one["effort"] == "Low" and session_effort(chat1) == "low", json.dumps(one))
    key("]", ["command", "shift"])
    wait(lambda: shown_session() == chat2, 5)
    time.sleep(0.4)
    two = chips()
    check(P, "switching back shows the chat's own picks", "Sonnet" in two["model"] and two["effort"] == "High",
          json.dumps(two))

    quit_keep_sessions()
    launch()
    time.sleep(1.5)
    shown_now = shown_session()
    for _ in range(2):
        now = chips()
        if shown_now == chat2:
            check(P, "after a relaunch a chat keeps the reasoning it was moved to",
                  "Sonnet" in now["model"] and now["effort"] == "High" and full_access(now["mode"]), json.dumps(now))
        elif shown_now == chat1:
            check(P, "after a relaunch a chat keeps its start picks",
                  "Haiku" in now["model"] and now["effort"] == "Low" and full_access(now["mode"]), json.dumps(now))
        else:
            check(P, "after a relaunch the pane shows one of the chats", False, f"shows {shown_now}")
            break
        key("]" if shown_now == chat1 else "[", ["command", "shift"])
        blank = blank_frames(400)
        check(P, "after a relaunch the first switch to the other chat shows no blank pane", (blank or 0) <= 17,
              f"blank for {blank:.0f} ms" if blank else "")
        wait(lambda: shown_session() not in (None, shown_now), 5)
        time.sleep(1.0)
        shown_now = shown_session()
    key("t", ["command"])
    time.sleep(1.2)
    last = chips()
    check(P, "after a relaunch a New Tab names the latest pick and full access",
          "Sonnet" in last["model"] and last["effort"] == "High" and full_access(last["mode"]), json.dumps(last))
    key("w", ["command"])
    time.sleep(0.8)


# ---- pass 2 -----------------------------------------------------------------------------------

def sidebar_order():
    rows = []
    for window in (rpc("debug.sidebar_rows") or {}).get("windows") or []:
        rows += [item.get("id") for item in window.get("items") or [] if item.get("ref_kind") == "workspace"]
    return rows


def focused_kind():
    panes = [p for w in (rpc("debug.surfaces") or {}).get("windows") or [] for p in w.get("panes") or []]
    return next((p.get("kind") for p in panes if p.get("focused")), None)


def blank_frames(ms=500):
    """Polls the focused pane's native state right after a switch: how long, in ms, it showed no
    content (the polls that read blank, each counted for the time to the next poll)."""
    start = last = time.time()
    blank = 0.0
    was_blank = False
    while (time.time() - start) * 1000 < ms:
        panes = [p for w in (rpc("debug.surfaces") or {}).get("windows") or [] for p in w.get("panes") or []]
        focused = next((p for p in panes if p.get("focused")), None)
        now = time.time()
        if was_blank:
            blank += (now - last) * 1000
        was_blank = bool(focused and (focused.get("blank") or not focused.get("content_installed")
                                      or focused.get("phase") == "loading"))
        last = now
        time.sleep(0.016)
    return round(blank) or None


def pass2():
    P = "switching"
    workspaces = max(3, opts.chats // 4)
    made = 0
    for w in range(workspaces):
        if w:
            rpc("action.run", {"action": "workspace new", "args": {"focus": True}, "origin": "script"})
            time.sleep(1.5)
        for t in range(-(-opts.chats // workspaces)):
            if made >= opts.chats:
                break
            new_tab_chat(["proj-a", "proj-b", "proj-c", "proj-d"][made % 4], f"chat {made} " + "line " * 20)
            made += 1
    say(f"made {made} chats in {workspaces} workspaces")
    order = sidebar_order()
    switches = [("]", ["command", "shift"])] * (opts.chats // workspaces) + [("]", ["command", "control"])]
    results = []
    for round_ in range(2):
        for k, mods in switches * workspaces:
            key(k, mods)
            sent = time.time()
            # The blank poll runs beside the watch, from the key on: sampled after the watch's
            # 1.2 s it would only ever see the settled pane.
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                watching = pool.submit(page, "layout_watch", ms=1200)
                blank = blank_frames(200)
                watch = watching.result()
            if "error" in watch or focused_kind() != "agent":
                # A workspace's terminal: no chat page to watch.
                continue
            latency = (time.time() - sent) * 1000 - 1200
            entry = {"key": "+".join(mods + [k]), "session": shown_session(), "watch": watch,
                     "first_content_ms": None if watch.get("first_content_ms") is None
                     else round(watch["first_content_ms"] + max(latency, 0)), "blank_ms": blank}
            results.append(entry)
    with open(os.path.join(OUT, "switches.json"), "w") as f:
        json.dump(results, f, indent=1)
    if not check(P, f"switches reach at least {opts.chats} chats", len({r["session"] for r in results}) >= min(opts.chats, 10),
                 f"{len(results)} switches measured, {len({r['session'] for r in results})} chats"):
        return
    slow = [r for r in results if r["first_content_ms"] is None or r["first_content_ms"] > opts.first_content_ms]
    check(P, f"each of {len(results)} switches shows its chat within {opts.first_content_ms:.0f} ms",
          not slow, json.dumps([(r["key"], r["first_content_ms"]) for r in slow])[:600])
    moved = [r for r in results if r["watch"].get("shifts")]
    check(P, "nothing moves after first paint", not moved,
          json.dumps([(r["key"], r["watch"]["shifts"][:3]) for r in moved])[:900])
    popped = [r for r in results if r["watch"].get("appeared")]
    check(P, "nothing pops in after first paint", not popped,
          json.dumps([(r["key"], r["watch"]["appeared"][:3]) for r in popped])[:900])
    jumped = [r for r in results if r["watch"].get("scroll_jumps")]
    check(P, "the transcript never jumps after first paint", not jumped,
          json.dumps([(r["key"], r["watch"]["scroll_jumps"][:3]) for r in jumped])[:600])
    # The native state may read not-installed for one poll as the views swap; a blank a person can
    # see lasts longer than a frame.
    blanks = [r for r in results if (r["blank_ms"] or 0) > 17]
    check(P, "no switch shows a blank pane", not blanks, json.dumps([(r["key"], r["blank_ms"]) for r in blanks])[:600])
    after = sidebar_order()
    # An empty read is a failed read (debug.sidebar_rows erred), never a matching order.
    check(P, "the sidebar's workspace order never changes from a switch", bool(order) and after == order,
          f"{order} -> {after}")
    firsts = sorted(r["first_content_ms"] for r in results if r["first_content_ms"] is not None)
    if firsts:
        say(f"time to first content: median {firsts[len(firsts) // 2]} ms, worst {firsts[-1]} ms over {len(firsts)} switches")


def report():
    lines = ["| Pass | Scenario | Result |", "| --- | --- | --- |"]
    for r in RESULTS:
        lines.append(f"| {r['pass']} | {r['scenario']} | {'pass' if r['ok'] else 'FAIL: ' + r['detail'][:160].replace('|', '/')} |")
    table = "\n".join(lines)
    with open(os.path.join(OUT, "results.md"), "w") as f:
        f.write(table + "\n")
    with open(os.path.join(OUT, "results.json"), "w") as f:
        json.dump(RESULTS, f, indent=1)
    print(table)
    say(f"artifacts: {OUT}")


teardown = TagTeardown(APP, acpmux_home=ACP_HOME, acpmux_socket=ACP_SOCKET, log=say)
# Another copy of this tag (a person's, or an earlier run's) would share its socket and daemons, and
# the teardown ends every process of the bundle: refuse rather than mix two runs.
if teardown.processes():
    sys.exit(f"processes of {APP} are running (pids {[pid for pid, _ in teardown.processes()]}); quit that copy first")
teardown.install()
try:
    setup()
    launch()
    if "1" in PASSES:
        pass1()
    if "2" in PASSES:
        pass2()
finally:
    try:
        if APP_PROC and APP_PROC.poll() is None:
            rpc("action.run", {"action": "quitEndEverything", "origin": "script"})
            wait(lambda: APP_PROC.poll() is not None, 20, 0.2)
    finally:
        teardown.end()
        report()
        shutil.rmtree(WORK, ignore_errors=True)
sys.exit(0 if RESULTS and all(r["ok"] for r in RESULTS) else 1)
