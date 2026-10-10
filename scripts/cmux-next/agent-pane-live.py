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
Run under nx-remote on cmux-lawrence-2 (NX_ARTIFACTS is the output directory)."""
import glob, json, os, plistlib, re, signal, socket, subprocess, sys, time

import argparse
_parser = argparse.ArgumentParser()
_parser.add_argument("stage", nargs="?", default="run")
_parser.add_argument("--job", required=True)
_parser.add_argument("--tag", required=True)
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
    def state():
        s = pane("chat_state", pane=PANE)
        return s if isinstance(s, dict) and "error" not in s and s.get("connection") else None
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
    first = pane("new_chat", pane=PANE, harness="claude")
    click()
    say("first send", json.dumps(pane("send_prompt", pane=PANE, text="Reply with the single word ok."))[:300])
    say("first chat", json.dumps(first)[:300])
    current = wait(lambda: (lambda s: s if s and s.get("sessionId") and s.get("harness") else None)(state()), 120, 0.5)
    say("first chat state", json.dumps(current)[:400])
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
    report["switches"] = switches
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
