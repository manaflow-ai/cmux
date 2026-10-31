#!/usr/bin/env python3
"""Live check of a tagged fleet build's agent pane (the native transport), on the GUI host only.

Stages: `run` (LocalApp origin and no token on the page, five pooled harness switches, a
permission with and without a gesture, the quit), `probe`, `perm`, `switch` and `gesture` (one
part each). It downloads the build of `--job`, starts it with its own ACPMUX_HOME, and on exit
(also a failure, Ctrl-C or SIGTERM) ends the tag's daemons (tag_teardown.py); the app keeps
cmux-tui, acpmux and their hosts running after a quit, and they hold PTYs. Only processes of
this job's own copy of the app are stopped, by exact PID.

Usage: agent-pane-live.py <stage> --job <cmux-ci job id> --tag <the build's tag>
Teardown checks: CMUX_LIVE_INJECT_FAILURE=1 fails once the app is up; CMUX_LIVE_HOLD_SECONDS=N
holds N seconds once the app is up (it prints the script PID for a SIGTERM or SIGINT).
Run under nx-remote on cmux-lawrence-2 (NX_ARTIFACTS is the output directory).

The `run` stage times three arms of a harness switch (pick to the new session, `pick_to_ready_ms`; bench_arms.py),
each with p50/p95/p99/max:
  warm   the five switches above: each waits up to 45 s for a ready pooled entry of the target harness (and else
         `_acpmux/prewarm` with wait, up to 120 s) before the pick
  quick  `--quick N` (default 3) switches, each right after the one before showed its session, with no wait for
         the pool to refill and no prewarm
  cold   cold, no wait: the launch's first chat, picked as soon as the app answers, with no pool wait
The HEADLINE is the WORST arm (a missed run first, else the highest p95, then the highest max), printed as
`HEADLINE agent-pane/switch pick_to_ready_ms = <arm> arm ...`; the warm arm alone never stands for the bench."""
import glob, json, os, plistlib, re, signal, socket, subprocess, sys, time

import argparse
_parser = argparse.ArgumentParser()
_parser.add_argument("stage", nargs="?", default="run")
_parser.add_argument("--job", required=True)
_parser.add_argument("--tag", required=True)
_parser.add_argument("--quick", type=int, default=3, help="run stage: switches right after the one before, no pool wait")
_opts = _parser.parse_args()
STAGE = _opts.stage
JOB = _opts.job
OUT = os.environ.get("NX_ARTIFACTS") or "/tmp/hqnt-live"
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "live.log"), "a")
def say(*parts):
    line = " ".join(str(p) for p in parts)
    print(line, flush=True)
    LOG.write(line + "\n"); LOG.flush()

# 1. The fleet build.
zip_path = os.path.join(OUT, "app.zip")
if not os.path.exists(zip_path):
    # This host's client config names an old controller address; the current one is set here only.
    subprocess.run([os.path.expanduser("~/.local/bin/cmux-ci"), "artifact", JOB, zip_path], check=True,
                   env=dict(os.environ, CMUX_CI_CONTROLLER="http://100.89.225.106:18765"))
app_dir = os.path.join(OUT, "app")
if not os.path.isdir(app_dir):
    subprocess.run(["ditto", "-x", "-k", zip_path, app_dir], check=True)
APP = next(iter(glob.glob(os.path.join(app_dir, "*.app"))), None)
if not APP:
    sys.exit("no .app in the artifact")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    info = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", info["CFBundleExecutable"])
say("app", APP, "bundle", info.get("CFBundleIdentifier"), "acpmux bundled:",
    os.path.exists(os.path.join(APP, "Contents/Resources/bin/acpmux")))
TAG = _opts.tag
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown, pty_count
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
HOME_ACP = os.path.join(OUT, "acpmux-home")
ACP_SOCKET = f"/tmp/hqnt-acp-{os.getpid()}.sock"

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

def pane(action, **params):
    params = {k: v for k, v in params.items() if v is not None}
    result = rpc("debug.agent_pane", dict(params, action=action), timeout=40)
    if isinstance(result, dict) and isinstance(result.get("result"), str):
        try:
            result = dict(result, result=json.loads(result["result"]))
        except ValueError:
            pass
    return result

def acp(method, params=None, timeout=10):
    """One JSON-RPC request on the daemon's unix socket (newline-delimited)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(ACP_SOCKET)
        conn.sendall((json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while b"\n" not in buf:
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        return json.loads(buf.split(b"\n")[0])
    except (OSError, ValueError) as error:
        return {"error": str(error)}

def wait(predicate, seconds, step=0.2):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None

def mine():
    """The processes whose executable is inside this job's own copy of the app (none other is mine)."""
    out = subprocess.run(["ps", "-A", "-o", "pid=,command="], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[1].startswith(APP + "/"):
            found.append((int(parts[0]), parts[1][len(APP):][:90]))
    return found

def alive(pid):
    return subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode == 0

def descendants(pid):
    out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = [line.split(None, 2) for line in out.splitlines() if line.strip()]
    kids, frontier = [], [str(pid)]
    while frontier:
        parent = frontier.pop()
        for row in rows:
            if len(row) >= 2 and row[1] == parent:
                kids.append((int(row[0]), row[2] if len(row) > 2 else ""))
                frontier.append(row[0])
    return kids

# This tag's own daemon state (tabs and panes of earlier runs): moved aside, so each run starts clean.
TAG_STATE = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{TAG}")
if os.environ.get("HQNT_KEEP_STATE") != "1" and os.path.isdir(TAG_STATE) and not os.path.islink(TAG_STATE):
    os.rename(TAG_STATE, TAG_STATE + ".old-" + str(int(time.time())))
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
os.makedirs(HOME_ACP, exist_ok=True)
config = os.path.join(OUT, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = dict(os.environ)
env.update({"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800",
            "ACPMUX_HOME": HOME_ACP, "ACPMUX_SOCKET": ACP_SOCKET})
if os.environ.get("CMUX_LIVE_TYPE_KEYS") == "1":
    # Real typed keys (an --needs input job owns the GUI session): under CMUX_NEXT_NO_ACTIVATE the
    # app's keyboard guard counts posted CGEvents as synthetic, not user input, and hands the
    # keyboard back to the previous app at once (job 1014-173056-acf765: 1 key of 130 landed).
    env.pop("CMUX_NEXT_NO_ACTIVATE")
app_log = open(os.path.join(OUT, "app.log"), "a")
TEARDOWN = TagTeardown(APP, acpmux_home=HOME_ACP, acpmux_socket=ACP_SOCKET, log=say)
TEARDOWN.install()
PTYS_BEFORE = pty_count()
say("PTYs open before:", PTYS_BEFORE)
app = subprocess.Popen([BINARY], env=env, stdout=app_log, stderr=app_log, stdin=subprocess.DEVNULL)
say("started app pid", app.pid)
report = {"app_pid": app.pid}
started = []
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 120):
        sys.exit("the app did not come up")
    # Teardown checks: an injected failure, or a hold while a test sends SIGTERM or SIGINT.
    if os.environ.get("CMUX_LIVE_INJECT_FAILURE") == "1":
        raise RuntimeError("injected failure (CMUX_LIVE_INJECT_FAILURE)")
    if os.environ.get("CMUX_LIVE_HOLD_SECONDS"):
        say("HOLDING script pid", os.getpid())
        time.sleep(float(os.environ["CMUX_LIVE_HOLD_SECONDS"]))
    ident = rpc("system.identify")
    say("identify", json.dumps(ident)[:1500])
    windows = rpc("debug.windows")
    snap = rpc("snapshot.get")
    say("windows", json.dumps(windows)[:2500])
    say("snapshot", json.dumps(snap)[:4000])
    panes = [p for p in sorted(set(re.findall(r"pane_[A-Za-z0-9_-]+", json.dumps(snap)))) if p != "pane_chrome"]
    if not panes:
        # A fresh tag state shows a window with no workspace yet: wait for its first pane, else make one.
        def first_panes():
            found = [p for p in sorted(set(re.findall(r"pane_[A-Za-z0-9_-]+", json.dumps(rpc("snapshot.get"))))) if p != "pane_chrome"]
            return found or None
        panes = wait(first_panes, 20, 0.5)
        if not panes:
            say("new workspace", json.dumps(rpc("action.run", {"action": "workspace.newAtBottom", "focus": True}))[:300])
            panes = wait(first_panes, 30, 0.5) or []
    say("panes", panes)
    PANE = panes[0] if panes else None
    WORK = os.path.join(OUT, "work")
    os.makedirs(WORK, exist_ok=True)
    WORK = os.path.realpath(WORK)
    split = rpc("action.run", {"action": "splitLeft", "target": f"pane:{PANE}", "args": {"cwd": WORK}})
    say("terminal split with cwd", WORK, json.dumps(split)[:300])
    rooted = wait(lambda: WORK in json.dumps(rpc("snapshot.get")), 30, 0.5)
    say("WORK is a tab cwd:", bool(rooted))
    panes = [p for p in sorted(set(re.findall(r"pane_[A-Za-z0-9_-]+", json.dumps(rpc("snapshot.get"))))) if p != "pane_chrome"]
    say("panes after split", panes, "agent pane", PANE)
    # Show the workspace that holds the WORK terminal (a fresh window shows none), and use its pane.
    snap_now = rpc("snapshot.get")
    for ws in (snap_now.get("topology") or snap_now).get("workspaces", []):
        for screen in ws.get("screens", []):
            for p in screen.get("panes", []):
                for t in p.get("tabs", []):
                    if t.get("cwd") == WORK:
                        PANE = p["id"]
                        WORK_TAB = t["id"]
                        say("focus WORK tab", t["id"], json.dumps(rpc("action.run", {"action": "tab.focus", "target": f"tab:{t['id']}", "focus": True}))[:200])
    opened = rpc("action.run", {"action": "palette.newAgentChat", "target": f"pane:{PANE}", "focus": True})
    say("open agent chat", json.dumps(opened)[:400])
    if isinstance(opened, dict) and "error" in opened and "WORK_TAB" in globals():
        # A pane id from the snapshot may not be the controller's key: target the WORK tab instead,
        # and let debug.agent_pane find the agent tab itself (pane omitted).
        opened = rpc("action.run", {"action": "palette.newAgentChat", "target": f"tab:{WORK_TAB}", "focus": True})
        say("open agent chat by tab", json.dumps(opened)[:300])
        if not (isinstance(opened, dict) and "error" in opened):
            PANE = None
    if isinstance(opened, dict) and "error" in opened:
        # The first pane of a fresh workspace can be replaced by the split: use a pane that exists now.
        for candidate in panes:
            if candidate == PANE:
                continue
            opened = rpc("action.run", {"action": "palette.newAgentChat", "target": f"pane:{candidate}", "focus": True})
            say("open agent chat in", candidate, json.dumps(opened)[:300])
            if not (isinstance(opened, dict) and "error" in opened):
                PANE = candidate
                break
    if isinstance(opened, dict) and "error" in opened:
        # A pane is found only in a workspace a window shows (ActionScope): after the WORK tab was
        # focused, the focused pane takes the chat when no target is named.
        opened = rpc("action.run", {"action": "palette.newAgentChat", "focus": True})
        say("open agent chat in the focused pane", json.dumps(opened)[:300])
        if not (isinstance(opened, dict) and "error" in opened):
            PANE = None
    def state():
        s = pane("chat_state", pane=PANE)
        return s if isinstance(s, dict) and "error" not in s and s.get("connection") else None
    st = wait(state, 60, 0.5)
    if not st and isinstance(opened, dict) and not opened.get("created"):
        # The action ran on a pane but opened nothing there: open the chat in the focused pane.
        opened = rpc("action.run", {"action": "palette.newAgentChat", "focus": True})
        say("open agent chat again in the focused pane", json.dumps(opened)[:300])
        PANE = None
        st = wait(state, 60, 0.5)
    say("chat_state", json.dumps(st)[:1500])
    if not st:
        say("snapshot after open", json.dumps(rpc("snapshot.get"))[:3000])
        raise SystemExit("no agent view")
    status = acp("_acpmux/status").get("result", {})
    say("daemon", {k: status.get(k) for k in ("pid", "build", "permissionPolicy")}, "pool", json.dumps(status.get("pool")))

    # Step 1: the pane's connection is LocalApp, and the page holds no token.
    log = pane("acp_log", pane=PANE, limit=400)
    entries = (log.get("entries") if isinstance(log, dict) else None) or []
    origins = re.findall(r'"origin":"(\w+)"', "".join(e.get("text", "") for e in entries if e.get("method") == "initialize"))
    say("STEP1 initialize origins seen by the page:", origins, "entries", len(entries))
    export = json.dumps(pane("acp_log_export", pane=PANE))
    secrets = []
    tok_file = os.path.join(HOME_ACP, "run", "localapp.token")
    if os.path.exists(tok_file):
        secrets.append(("localapp", open(tok_file).read().strip()))
    web = status.get("webUrl") or ""
    m = re.search(r"token=([A-Za-z0-9_\-]+)", web)
    if m:
        secrets.append(("dashboard", m.group(1)))
    leaks = [name for name, value in secrets if value and (value in export or value in json.dumps(entries))]
    say("STEP1 tokens checked:", [n for n, _ in secrets], "found in the page wire log:", leaks, "export bytes", len(export))
    report["step1"] = {"origins": origins, "tokens_checked": [n for n, _ in secrets], "leaks": leaks}

    def click():
        return rpc("debug.mouse", {"pane": PANE, "action": "click"})
    def pool_entries():
        return (acp("_acpmux/status").get("result", {}).get("pool") or {}).get("entries") or []
    def events(session):
        r = acp("_acpmux/events", {"sessionId": session, "limit": 200})
        return (r.get("result") or {}).get("events") or r.get("result") or r
    def host_started(session):
        ev = events(session)
        for e in (ev if isinstance(ev, list) else []):
            if e.get("kind") == "host_started":
                return (e.get("msg") or {}).get("hostPid")
        return None
    def lstart(pid):
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return out
    def start_epoch(pid):
        out = lstart(pid)
        try:
            return time.mktime(time.strptime(out, "%a %b %d %H:%M:%S %Y"))
        except ValueError:
            return None

    def wire_dump(tag):
        lg = pane("acp_log", pane=PANE, limit=400)
        for e in (lg.get("entries") or []) if isinstance(lg, dict) else []:
            t = e.get("text", "")
            if e.get("kind") == "error" or (e.get("dir") == "out" and e.get("method") not in ("_acpmux/events", "_acpmux/status", "_acpmux/watch")) or "permission" in (e.get("method") or ""):
                say("WIRE", tag, e.get("seq"), e.get("dir"), e.get("kind"), e.get("method"), t[:500])
    if STAGE == "gesture":
        def seq_now():
            lg = pane("acp_log", pane=PANE, limit=1)
            es = (lg.get("entries") or []) if isinstance(lg, dict) else []
            return es[-1]["seq"] if es else 0
        def dump_since(tag, seq0):
            lg = pane("acp_log", pane=PANE, limit=200)
            for e in (lg.get("entries") or []) if isinstance(lg, dict) else []:
                if e.get("seq", 0) <= seq0:
                    continue
                if e.get("method") in ("_acpmux/event", "_acpmux/session_changed", "session/update"):
                    continue
                say("  W", tag, e.get("seq"), e.get("at"), e.get("dir"), e.get("kind"), e.get("method"), (e.get("text") or json.dumps(e.get("detail")))[:300])
        cases = [("codex", 0), ("claude", 0), ("codex", 0), ("claude", 0), ("codex", 5), ("claude", 5), ("codex", 0.3), ("claude", 2)]
        for n, (h, delay) in enumerate(cases):
            wait(lambda: (lambda st_: st_ if st_ and not st_.get("isWorking") else None)(state()), 30, 0.5)
            time.sleep(3)
            s0 = seq_now()
            t_pick = time.time() * 1000
            r = pane("new_chat", pane=PANE, harness=h)
            t_ret = time.time() * 1000
            time.sleep(delay)
            c = click()
            t_click = time.time() * 1000
            time.sleep(0.2)
            sp = pane("send_prompt", pane=PANE, text="Reply with the single word ok.")
            t_send = time.time() * 1000
            say("CASE", n + 1, h, "delay", delay, "pick", round(t_pick), "pick_ret", round(t_ret), "click", round(t_click), "send_ret", round(t_send),
                "new_chat", json.dumps(r)[:120], "send", json.dumps(sp)[:200])
            dump_since(f"c{n+1}", s0)
        raise SystemExit(0)
    if STAGE == "switch":
        cur_h = "codex"
        pane("new_chat", pane=PANE, harness="codex")
        for i in range(5):
            target = "claude" if cur_h == "codex" else "codex"
            key = "claude-sr" if target == "claude" else "codex"
            def warm():
                es = pool_entries()
                return es if any(e.get("harness") == key and e.get("state") == "ready" for e in es) else None
            before = wait(warm, 40, 0.5)
            hinted = not before
            if hinted:
                acp("_acpmux/prewarm", {"harness": target, "cwd": WORK, "wait": True}, timeout=120)
                before = wait(warm, 40, 0.5)
            before = before or pool_entries()
            t0 = time.time()
            reply = pane("new_chat", pane=PANE, harness=target)
            t1 = time.time()
            sid = reply.get("sessionId") if isinstance(reply, dict) else None
            after = pool_entries()
            hp = host_started(sid) if sid else None
            hs = start_epoch(hp) if hp else None
            row = {"n": i + 1, "target": target, "session": sid, "pick_to_ready_ms": round((t1 - t0) * 1000),
                   "pool_before": [(e.get("harness"), e.get("state"), e.get("roles")) for e in before],
                   "pool_after": [(e.get("harness"), e.get("state"), e.get("roles")) for e in after],
                   "host_pid": hp, "host_started_before_pick_s": round(t0 - hs, 1) if hs else None, "unix_hint": hinted}
            say("SWITCH", json.dumps(row))
            cur_h = target
        raise SystemExit(0)
    if STAGE == "subagents":
        # Native Codex subagents (cx-07ezn): a Codex chat that starts two subagents shows them as one
        # group whose children have their own turns, as the page's wire log and a desktop shot show.
        for name, body in (("a.txt", "alpha\n"), ("b.txt", "beta\n")):
            with open(os.path.join(WORK, name), "w") as f:
                f.write(body)
        say("subagents new_chat", json.dumps(pane("new_chat", pane=PANE, harness=os.environ.get("CMUX_LIVE_HARNESS", "codex"))))
        time.sleep(5)
        if os.environ.get("CMUX_LIVE_MODEL"):
            say("subagents set_model", json.dumps(pane("set_model", pane=PANE, model=os.environ["CMUX_LIVE_MODEL"])))
            time.sleep(2)
        say("subagents send", json.dumps(pane("send_prompt", pane=PANE, text=(
            "Spawn two subagents in parallel with your agent-spawning tool: the first reads a.txt and reports "
            "its contents, the second reads b.txt and reports its contents. Wait for both, then reply with one "
            "line combining their answers."))))
        def wire():
            log = pane("acp_log", pane=PANE, limit=2000)
            return "".join(e.get("text", "") for e in ((log.get("entries") if isinstance(log, dict) else None) or []))
        done = wait(lambda: (lambda t: t if t.count("subagent_state_update") >= 2 else None)(wire()), 420, 2)
        text = done or wire()
        children = set(re.findall(r'"subagent":"([^"]+)"', text))
        say("SUBAGENTS spawned:", text.count("subagent_spawned"), "ended:", text.count("subagent_state_update"),
            "children with own updates:", len(children), "legacy start lines:", text.count("Start subagent"))
        rpc("debug.focus")
        time.sleep(2)
        cua = os.path.expanduser("~/.local/bin/cua-driver")
        shot = os.path.join(OUT, "subagents.png")
        r = subprocess.run([cua, "call", "get_desktop_state", json.dumps({"screenshot_out_file": shot})],
                           capture_output=True, text=True, timeout=60)
        say("screenshot", shot, os.path.exists(shot), r.returncode, r.stderr[-300:])
        report["subagents"] = {"spawned": text.count("subagent_spawned"), "children": len(children)}
        wire_dump("subagents")
        raise SystemExit(0 if children else 1)
    # Real key events at the window server, as a keyboard posts them (args: pid, text, keys/s).
    SP_TYPER = r"""
import AppKit
let args = CommandLine.arguments
let pid = pid_t(args[1])!, text = args[2], rate = Double(args[3])!
let codes: [Character: UInt16] = ["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,
    "e":14,"r":15,"y":16,"t":17,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else { print("no post-event access"); exit(3) }
NSRunningApplication(processIdentifier: pid)?.activate()
let until = Date().addingTimeInterval(5)
while NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, Date() < until {
    RunLoop.current.run(until: Date().addingTimeInterval(0.02))  // harness: wait for the front app
}
let source = CGEventSource(stateID: .hidSystemState)
for character in text {
    guard let code = codes[character] else { continue }
    for down in [true, false] { CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
    usleep(UInt32(1_000_000 / rate))  // harness: key pacing, as a person types
}
print("typed", text.count, "front:", NSWorkspace.shared.frontmostApplication?.processIdentifier == pid)
"""
    if STAGE == "subagent-panes":
        # cx-1933q: a turn that starts two subagents opens two agent panes right of the chat (stacked),
        # focus stays in the chat; the summary card lists both with live status, stays after a click
        # outside it, and a click on a row focuses that subagent's pane. Shots for the crops page.
        def shot(name):
            # The app's own window (nx-remote's window capture), not the desktop.
            path = os.path.join(OUT, f"sp-{name}.png")
            capture = os.environ.get("NX_CAPTURE")
            r = subprocess.run(["bash", capture, "shot", "--pid", str(app.pid), "--out", path] if capture else ["true"],
                               capture_output=True, text=True, timeout=60)
            say("shot", name, os.path.exists(path), r.returncode, r.stderr[-200:])
        def trust():
            # A new folder asks whether the harness may edit and run code there (the pane's trust ask).
            r = pane("click", pane=PANE, text="Trust")
            say("sp trust", json.dumps(r)[:200])
        def topo():
            snap_ = rpc("snapshot.get")
            return snap_.get("topology") or snap_
        def conversation_panes():
            found = []
            for ws in topo().get("workspaces", []):
                for screen in ws.get("screens", []):
                    for p in screen.get("panes", []):
                        if any(t.get("kind") == "conversation" for t in p.get("tabs", [])):
                            found.append(p["id"])
            return found
        def card(pane_id=None):
            s_ = pane("chat_state", pane=pane_id or PANE)
            return (s_ or {}).get("summaryCard") if isinstance(s_, dict) else None
        harness = os.environ.get("CMUX_LIVE_HARNESS", "claude")
        made = pane("new_chat", pane=PANE, harness=harness)
        say("sp new_chat", json.dumps(made))
        # The chat's own pane, by id from here on: subagent panes on the same session come next to it.
        PANE = (made or {}).get("pane") or PANE
        time.sleep(5)
        trust()
        if os.environ.get("CMUX_LIVE_MODEL"):
            say("sp set_model", json.dumps(pane("set_model", pane=PANE, model=os.environ["CMUX_LIVE_MODEL"])))
            time.sleep(2)
        before = conversation_panes()
        say("SP panes before", before)
        shot("before")
        say("sp send", json.dumps(pane("send_prompt", pane=PANE, text=(
            "Start two subagents in parallel with your Task tool (subagent_type general-purpose). The first "
            "runs `sleep 40; echo alpha` in Bash and reports the output; the second runs `sleep 40; echo beta` "
            "and reports it. Wait for both, then reply with one line combining their answers."))))
        time.sleep(4)
        trust()
        # cx-3hw0i: with CMUX_LIVE_TYPE_KEYS=1 (nx-remote --needs input) real keys go to the window
        # server while the subagent panes open; every one must land in the chat's composer.
        typer, typed = None, ""
        if os.environ.get("CMUX_LIVE_TYPE_KEYS") == "1":
            # The input job owns the GUI session: bring the app front first (LaunchServices activates
            # the running copy; the typer's own activate() is ignored on some runs, job 1014-211210-86eeef).
            subprocess.run(["open", APP], check=False, timeout=30)
            say("sp app active", bool(wait(lambda: (rpc("debug.focus") or {}).get("app_active") or None, 10, 0.3)))
            say("sp composer focus", json.dumps(pane("click", pane=PANE, selector=".acpmux-composer-prompt"))[:200])
            say("sp reset typing", json.dumps(pane("reset_typing", pane=PANE)))
            typed = "abcdefghijklmnopqrstuvwxyz" * 5
            with open(os.path.join(OUT, "sp-typer.swift"), "w") as f:
                f.write(SP_TYPER)
            typer = subprocess.Popen(["swift", os.path.join(OUT, "sp-typer.swift"), str(app.pid), typed, "3"],
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        # The daemon's focus over time while the subagent panes open (the chat should keep it).
        timeline, last, last_sample = [], None, 0.0
        deadline = time.time() + 240
        while time.time() < deadline:
            focus_now = (topo().get("focus") or {}).get("pane")
            count = len(conversation_panes())
            # With typing: the chat's key count and the app's focus at each change, and every 10 s.
            if (focus_now, count) != last or (typer and time.time() > last_sample + 10):
                last, last_sample = (focus_now, count), time.time()
                keys_now = (pane("typing_stats", pane=PANE) or {}).get("keys") if typer else None
                timeline.append((round(time.time(), 2), focus_now, count, keys_now))
                say("SP focus timeline", timeline[-1], "app focus:", json.dumps(rpc("debug.focus"))[:2500] if typer else "")
            if count >= len(before) + 2 and len(timeline) and time.time() > timeline[-1][0] + 8:
                break
            time.sleep(0.3)
        report["focus_timeline"] = timeline
        if typer:
            try:
                out_, _ = typer.communicate(timeout=180)
            except subprocess.TimeoutExpired:
                typer.kill()  # our own child, by its Popen handle
                out_, _ = typer.communicate()
            say("SP typer", typer.returncode, out_[-300:])
            stats = {p_: (pane("typing_stats", pane=p_) or {}).get("keys") for p_ in conversation_panes()}
            say("SP keys per pane", json.dumps(stats), "typed:", len(typed))
            report["keys_in_chat"] = stats.get(PANE) == len(typed) and typer.returncode == 0
        opened = len(conversation_panes()) >= len(before) + 2 or None
        panes_now = conversation_panes()
        say("SP panes after spawn", panes_now, "opened two:", bool(opened))
        snap_after = rpc("snapshot.get")
        with open(os.path.join(OUT, "sp-snapshot.json"), "w") as f:
            json.dump(snap_after, f)
        st_parent = pane("chat_state", pane=PANE)
        focus_after = (topo().get("focus") or {}).get("pane")
        say("SP focus after spawn:", focus_after, "chat pane:", PANE, "kept:", focus_after == PANE,
            "card:", json.dumps((st_parent or {}).get("summaryCard")))
        report["focus_kept"] = focus_after == PANE
        children = [p for p in panes_now if p not in before]
        for child in children:
            cs = pane("chat_state", pane=child)
            say("SP child", child, "subagentOf:", (cs or {}).get("subagentOf"), "card:", json.dumps((cs or {}).get("summaryCard"))[:300])
        live = wait(lambda: (lambda c: c if c and len(c.get("agents", [])) >= 2 else None)(card()), 60, 1)
        say("SP card lists:", json.dumps(live))
        shot("spawned")
        # A click outside the card (the transcript) leaves it.
        say("SP click outside", json.dumps(pane("click", pane=PANE, selector=".acpmux-scroll"))[:300])
        time.sleep(1)
        kept = card()
        say("SP card after outside click:", json.dumps(kept))
        shot("outside-click")
        # A click on the first row focuses that subagent's pane.
        name = (live or {}).get("agents", [{}])[0].get("name") if live else None
        target = None
        if name:
            target = pane("click", pane=PANE, selector=".acpmux-summary-agent")
            say("SP click row", name, json.dumps(target)[:300])
            time.sleep(2)
        snap_click = rpc("snapshot.get")
        with open(os.path.join(OUT, "sp-snapshot-after-row.json"), "w") as f:
            json.dump(snap_click, f)
        focus_row = (topo().get("focus") or {}).get("pane")
        focused_child = focus_row if focus_row in children else None
        # The other row focuses the other pane: each row shows its own subagent's pane.
        r2 = None
        try:
            r2 = rpc("debug.agent_pane", {"action": "click", "pane": PANE, "text": (live or {}).get("agents", [{}, {}])[1].get("name")}, timeout=40)
        except Exception as error:  # noqa: BLE001 - a proof script logs and goes on
            say("SP second row click failed", error)
        time.sleep(2)
        focus_row2 = (topo().get("focus") or {}).get("pane")
        say("SP second row", json.dumps(r2)[:200], "focus:", focus_row2, "first:", focus_row, "distinct:", focus_row2 != focus_row and focus_row2 in children)
        report["rows_focus_distinct"] = focus_row2 != focus_row and focus_row2 in children
        if focused_child:
            say("SP focused child shows:", (pane("chat_state", pane=focused_child) or {}).get("subagentOf"))
        say("SP focused child after row click:", focused_child)
        shot("row-click")
        done = wait(lambda: (lambda c: c if c and c.get("agents") and all(a.get("status") == "done" for a in c["agents"]) else None)(card()), 240, 2)
        say("SP card at end:", json.dumps(done or card()))
        shot("done")
        report["subagent_panes"] = {"opened": len(children), "card": live, "kept_after_outside_click": bool(kept),
                                    "focused_child": focused_child, "done": bool(done)}
        say("SP REPORT", json.dumps(report["subagent_panes"]))
        raise SystemExit(0 if len(children) >= 2 and kept and live and report["focus_kept"] and focused_child
                         and report.get("keys_in_chat", not typer) else 1)
    if STAGE == "perm":
        marker = os.path.join(WORK, "perm-marker")
        say("perm new_chat", json.dumps(pane("new_chat", pane=PANE, harness="claude")))
        time.sleep(5)
        say("perm click", json.dumps(click()))
        time.sleep(0.5)
        say("perm send", json.dumps(pane("send_prompt", pane=PANE, text=f"Use the Bash tool to run exactly: touch {marker}")))
        ask = wait(lambda: (lambda s_: s_ if s_ and (s_.get("permission") or s_.get("permissionGroups")) else None)(state()), 120, 0.5)
        say("perm ask", json.dumps(ask and {"permission": ask.get("permission"), "groups": ask.get("permissionGroups")})[:1200])
        if ask:
            time.sleep(31)
            r1 = pane("answer_permission", pane=PANE, allow=True)
            time.sleep(2)
            s1 = state()
            say("PERM no gesture:", json.dumps(r1)[:500], "still pending:", bool(s1 and (s1.get("permission") or s1.get("permissionGroups"))), "marker:", os.path.exists(marker))
            say("perm click 2", json.dumps(click()))
            time.sleep(0.5)
            r2 = pane("answer_permission", pane=PANE, allow=True)
            ok = wait(lambda: os.path.exists(marker), 60, 0.5)
            s2 = state()
            say("PERM after click:", json.dumps(r2)[:500], "still pending:", bool(s2 and (s2.get("permission") or s2.get("permissionGroups"))), "marker:", bool(ok))
        wire_dump("perm")
        raise SystemExit(0)
    if STAGE == "question":
        # A live Claude Code AskUserQuestion answered on the question card by a real click.
        say("q new_chat", json.dumps(pane("new_chat", pane=PANE, harness="claude")))
        time.sleep(5)
        say("q click", json.dumps(click()))
        time.sleep(0.5)
        # A fresh folder asks for trust first: answer it with a real click on Trust.
        say("q trust", json.dumps(pane("click", pane=PANE, selector=".acpmux-trust-ask-action"))[:300])
        time.sleep(2)
        say("q click 2", json.dumps(click()))
        time.sleep(0.5)
        say("q send", json.dumps(pane("send_prompt", pane=PANE, text=(
            'Use the AskUserQuestion tool exactly once to ask me which color I prefer, with header "Color" '
            'and the options "Red" and "Blue". Use no other tool. After my answer, reply with exactly: CHOSE <answer>.'))))
        ask = wait(lambda: (lambda s_: s_ if s_ and s_.get("permission") else None)(state()), 180, 0.5)
        say("q ask", json.dumps(ask and ask.get("permission"))[:1500])
        rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, "question-pending.png")})
        if ask:
            time.sleep(1)
            say("q answer click", json.dumps(pane("click", pane=PANE, text="Blue"))[:300])
            done = wait(lambda: "CHOSE" in json.dumps(state() or {}), 180, 1)
            final = state() or {}
            say("QUESTION answered:", "CHOSE Blue" in json.dumps(final), "pending after:", bool(final.get("permission")))
            rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, "question-answered.png")})
        wire_dump("question")
        raise SystemExit(0)
    if STAGE == "probe":
        say("probe click", json.dumps(click()))
        time.sleep(0.5)
        say("probe send", json.dumps(pane("send_prompt", pane=PANE, text="Say hi.")))
        time.sleep(3)
        lg = pane("acp_log", pane=PANE, limit=30)
        for e in (lg.get("entries") or []) if isinstance(lg, dict) else []:
            say("WIRE", json.dumps(e)[:900])
        say("probe state", json.dumps(state())[:600])
        say("probe status", json.dumps({k: v for k, v in acp("_acpmux/status").get("result", {}).items() if k in ("sessions", "liveAgents", "pool", "defaultHarness", "peers")}))
        raise SystemExit(0)
    # Step 2: harness switches.
    harnesses = ["claude", "codex"]
    t_first = time.time()
    first = pane("new_chat", pane=PANE, harness="claude")
    click()
    say("first send", json.dumps(pane("send_prompt", pane=PANE, text="Reply with the single word ok."))[:300])
    say("first chat", json.dumps(first)[:300])
    current = wait(lambda: (lambda s: s if s and s.get("sessionId") and s.get("harness") else None)(state()), 120, 0.05)
    say("first chat state", json.dumps(current)[:400])
    # The cold arm: the launch's first chat, picked with no pool wait (bench_arms.py).
    cold_row = {"arm": "cold", "target": "claude", "pick_to_ready_ms": round((time.time() - t_first) * 1000) if current else None}
    say("SWITCH", json.dumps(cold_row))
    wait(lambda: (lambda st_: st_ if st_ and not st_.get("isWorking") else None)(state()), 90, 1)
    switches = []
    cur_h = (current or {}).get("harness") or "claude"
    for i in range(5):
        target = "codex" if "claude" in cur_h else "claude"
        def warm():
            es = pool_entries()
            return es if any(e.get("harness") == target and e.get("state") == "ready" for e in es) else None
        before = wait(warm, 45, 1)
        hinted = False
        if not before:
            cwds = [e.get("cwd") for e in pool_entries() if e.get("cwd")]
            hint = acp("_acpmux/prewarm", {"harness": target, "cwd": WORK, "wait": True}, timeout=120)
            hinted = True
            say("switch", i + 1, "no warm", target, "in 45 s; unix prewarm hint:", json.dumps(hint)[:300])
            before = wait(warm, 90, 1)
        before = before or pool_entries()
        old = (state() or {}).get("sessionId")
        t0 = time.time()
        reply = pane("new_chat", pane=PANE, harness=target)
        click()
        sent_i = pane("send_prompt", pane=PANE, text="Reply with the single word ok.")
        t_reply = time.time()
        say("switch", i + 1, "pick reply", json.dumps(reply)[:200], "send", json.dumps(sent_i)[:300])
        ready = wait(lambda: (lambda s: s if s and s.get("sessionId") and s.get("sessionId") != old and s.get("harness") else None)(state()), 120, 0.05)
        t1 = time.time()
        after = pool_entries()
        sid = (ready or {}).get("sessionId") or (reply.get("result") or {}).get("sessionId") if isinstance(reply, dict) else None
        hp = host_started(sid) if sid else None
        hs = start_epoch(hp) if hp else None
        row = {"n": i + 1, "target": target, "harness": (ready or {}).get("harness"), "session": sid,
               "pick_to_reply_ms": round((t_reply - t0) * 1000), "pick_to_ready_ms": round((t1 - t0) * 1000),
               "pool_before": [(e.get("harness"), e.get("state"), e.get("roles")) for e in before],
               "pool_after": [(e.get("harness"), e.get("state"), e.get("roles")) for e in after],
               "host_pid": hp, "host_lstart": lstart(hp) if hp else None,
               "host_started_before_pick_s": round(t0 - hs, 1) if hs else None, "unix_hint": hinted}
        say("SWITCH", json.dumps(row))
        switches.append(row)
        cur_h = (ready or {}).get("harness") or target
        wait(lambda: (lambda st_: st_ if st_ and not st_.get("isWorking") else None)(state()), 90, 1)
    def quick_switch(n):
        """A switch right after the one before showed its session: no pool wait, no prewarm."""
        global cur_h
        target = "codex" if "claude" in cur_h else "claude"
        old = (state() or {}).get("sessionId")
        t0 = time.time()
        reply = pane("new_chat", pane=PANE, harness=target)
        click()
        pane("send_prompt", pane=PANE, text="Reply with the single word ok.")
        ready = wait(lambda: (lambda s: s if s and s.get("sessionId") and s.get("sessionId") != old and s.get("harness") else None)(state()), 120, 0.05)
        row = {"arm": "quick", "n": n, "target": target, "harness": (ready or {}).get("harness"),
               "pick_to_ready_ms": round((time.time() - t0) * 1000) if ready else None,
               "pool_before_pick": [(e.get("harness"), e.get("state")) for e in pool_entries()], "reply": json.dumps(reply)[:200]}
        say("SWITCH", json.dumps(row))
        cur_h = (ready or {}).get("harness") or target
        return row
    quick = [quick_switch(n + 1) for n in range(_opts.quick)]
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import bench_arms
    report["switches"] = switches + quick + [cold_row]
    report["arms"] = bench_arms.report("agent-pane/switch", "pick_to_ready_ms", "ms",
                                       {"warm": [r["pick_to_ready_ms"] for r in switches],
                                        "quick": [r["pick_to_ready_ms"] for r in quick],
                                        "cold": [cold_row["pick_to_ready_ms"]]}, out=say)
    dlog = os.path.join(HOME_ACP, "daemon.log")
    say("daemon log pool lines", "\n".join([l for l in open(dlog).read().splitlines() if "pool" in l.lower()][-20:]) if os.path.exists(dlog) else "none")

    # Step 3: a permission prompt.
    marker = os.path.join(OUT, "perm-marker")
    say("click before prompt", json.dumps(click()))
    time.sleep(0.5)
    sent = pane("send_prompt", pane=PANE, text=f"Use your shell tool to run exactly this command and nothing else: touch {marker}")
    say("STEP3 send_prompt", json.dumps(sent)[:400])
    ask = wait(lambda: (lambda s: s if s and (s.get("permission") or s.get("permissionGroups")) else None)(state()), 180, 0.5)
    say("STEP3 pending ask", json.dumps(ask and {"permission": ask.get("permission"), "groups": ask.get("permissionGroups")})[:1200])
    time.sleep(31)  # the click above is older than the gesture lifetime (30 s) and was used by the prompt
    no_gesture = pane("answer_permission", pane=PANE, allow=True)
    time.sleep(2)
    still = state()
    say("STEP3 allow without a gesture:", json.dumps(no_gesture)[:600], "still pending:",
        bool(still and (still.get("permission") or still.get("permissionGroups"))), "marker exists:", os.path.exists(marker))
    say("click before answer", json.dumps(click()))
    time.sleep(0.5)
    with_gesture = pane("answer_permission", pane=PANE, allow=True)
    done = wait(lambda: os.path.exists(marker), 60, 0.5)
    after_ask = state()
    say("STEP3 allow after a real click:", json.dumps(with_gesture)[:600], "pending after:",
        bool(after_ask and (after_ask.get("permission") or after_ask.get("permissionGroups"))), "marker exists:", bool(done))
    report["step3"] = {"no_gesture": no_gesture, "with_gesture": with_gesture, "marker": bool(done)}
    say("acp_log tail", json.dumps(pane("acp_log", pane=PANE, limit=8))[:3000])
    helpers = mine()
    say("my processes (by my app copy's path)", helpers)
    report["helpers"] = helpers
    quit_reply = rpc("action.run", {"action": "quit", "wait": False}, timeout=10)
    say("quit", json.dumps(quit_reply)[:300])
    exited = wait(lambda: app.poll() is not None, 30, 0.5)
    say("app exited after quit:", bool(exited), "code", app.poll())
    time.sleep(5)
    report["alive_after_quit"] = [(pid, cmd) for pid, cmd in helpers if alive(pid)]
    say("recorded processes alive 5 s after quit:", report["alive_after_quit"])
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)  # the PID launched here
        try:
            app.wait(30)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    TEARDOWN.end()
    report["ptys"] = {"before": PTYS_BEFORE, "after": pty_count()}
    say("PTYs open before:", PTYS_BEFORE, "after:", report["ptys"]["after"])
    with open(os.path.join(OUT, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
