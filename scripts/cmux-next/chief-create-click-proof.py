#!/usr/bin/env python3
"""hq-6d P1 owner install key (cx-ebm.59.5) live proof on cmux-lawrence-2 (nx-remote --needs input --app-from-fleet,
own tag, own socket, isolated HOME and a per-build Chief home under /tmp via CMUX_NEXT_CHIEF_ROOT; run under `zsh -lic`).
Built from s7-proof-v3.py.

0. Before the app runs, `cmux chief list --chief-home <this build's home>` starts the Chief owner WITHOUT an install key
   (as an older build or the CLI did). The owner does not verify the DEV app.
1. The app launches (unsigned DEV): its owner connection is not verified and the owner is idle, so the app restarts the
   owner once with the install key (debug.home chief_owner.daemon_pid changes, connected again).
2. Page Chief create WITHOUT a gesture: refused (gesture_required).
3. New Chief through the page with a REAL pointer click on Create Chief: the Chief is created on the owner (chief list),
   the page shows no "needs a verified cmux app connection".
Ends with quitEndSessions, endAgents, acpmux daemon shutdown + router shutdown, chief shutdown.
Reads NX_APP, NX_APP_TAG, NX_APP_STOP, NX_APP_CLI, NX_CAPTURE, NX_ARTIFACTS."""
import json, os, shutil, socket, subprocess, sys, tempfile, time

APP, TAG, OUT = os.environ["NX_APP"], os.environ["NX_APP_TAG"], os.environ["NX_ARTIFACTS"]
CAPTURE, STOP, CLI = os.environ["NX_CAPTURE"], os.environ["NX_APP_STOP"], os.environ["NX_APP_CLI"]
ACPMUX = os.path.join(APP, "Contents/Resources/bin/acpmux")
SOCK = "/tmp/cmux-debug-%s.sock" % TAG
REPLY_WAIT = float(os.environ.get("S7_REPLY_WAIT", "300"))
os.makedirs(OUT, exist_ok=True)
LOG = open(os.path.join(OUT, "transcript.jsonl"), "w")
R = {"tag": TAG, "checks": {}}
# Short paths: the brain's sockets must fit sun_path.
SCRATCH = tempfile.mkdtemp(prefix="h6s7-", dir="/tmp")
HOME = os.path.join(SCRATCH, "home")
CHIEF_ROOT = os.path.join(SCRATCH, "croot")


def chief_component(raw):
    out = ""
    for ch in raw:
        if ch.isascii() and (ch.isalnum() or ch in "._"):
            out += ch
        elif not out.endswith("-"):
            out += "-"
    return out.strip("-.")


import plistlib
BUNDLE_ID = plistlib.load(open(os.path.join(APP, "Contents/Info.plist"), "rb"))["CFBundleIdentifier"]
# ChiefHome rule 2 (CMUX_NEXT_CHIEF_ROOT): this build's own home, <root>/<bundle id>, buildID = bundle id.
CHIEF = os.path.join(CHIEF_ROOT, chief_component(BUNDLE_ID))


def owner_session(root):
    h = 0x811c9dc5
    for b in root.encode():
        h ^= b
        h = (h * 0x01000193) & 0xffffffff
    return "cmux-chief-%08x" % h
MARK = "hq6d-s7-%s-%d" % (TAG.replace("-", ""), int(time.time()) % 100000)
LINK = "https://example.com/?hq6d=%s" % MARK
BROWSE = "https://example.org/"


def say(*parts):
    print(*parts, flush=True)


def rpc(method, params=None, timeout=60):
    t0 = time.time()
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(timeout); c.connect(SOCK)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            ch = c.recv(1 << 22)
            if not ch:
                break
            buf += ch
        c.close(); r = json.loads(buf)
    except (OSError, ValueError) as e:
        r = {"ok": False, "error": str(e)}
    LOG.write(json.dumps({"t": round(t0, 3), "ms": int((time.time() - t0) * 1000), "method": method,
                          "params": params, "reply": r})[:200000] + "\n"); LOG.flush()
    return r


def res(r):
    return r.get("result") if isinstance(r, dict) and "result" in r else r


def until(fn, seconds, step=0.5):
    end = time.time() + seconds
    value = fn()
    while not value and time.time() < end:  # proof harness poll, bounded
        time.sleep(step)
        value = fn()
    return value


def check(name, ok, detail):
    R["checks"][name] = {"pass": bool(ok), "detail": detail}
    say(("PASS " if ok else "FAIL ") + name + ": " + json.dumps(detail)[:800])
    return ok


def shot(name, pid):
    path = os.path.join(OUT, name + ".png")
    p = subprocess.run(["bash", CAPTURE, "shot", "--pid", str(pid), "--out", path], capture_output=True, text=True, timeout=60)
    R.setdefault("shots", {})[name] = {"exit": p.returncode, "out": (p.stdout + p.stderr)[-400:]}
    # The app's own 2x window snapshot (Retina scale); terminal Metal content shows in the helper shot.
    R["shots"][name + "-2x"] = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, name + "-2x.png")}, 60)


def env_base():
    keep = ("USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR")
    env = {k: v for k, v in os.environ.items() if k in keep}
    env.update({"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"})
    return env


def tui(*args, timeout=60, extra=None):
    p = subprocess.run([CLI, "--session", "cmux-app-" + TAG, *args], capture_output=True, text=True, timeout=timeout,
                       env={**env_base(), **(extra or {})})
    R.setdefault("cli", []).append({"args": args, "exit": p.returncode, "out": (p.stdout + p.stderr)[-3000:]})
    return p


def tui_json(*args):
    p = tui("--json", *args)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {}


def chief(text):
    """One Chief message through `cmux chief -p` (the same conversation Home shows); its reply."""
    p = subprocess.run([CLI, "chief", "--chief-home", CHIEF, "--timeout", str(int(REPLY_WAIT)), "-p", text],
                       capture_output=True, text=True, timeout=REPLY_WAIT + 60, env={**env_base(), "NO_COLOR": "1"})
    R.setdefault("chief", []).append({"prompt": text, "exit": p.returncode, "out": p.stdout[-4000:], "err": p.stderr[-2000:]})
    return p.stdout


def panes():
    windows = (res(rpc("debug.pane_chrome")) or {}).get("windows") or []
    return windows[0] if windows else {}


def columns():
    rows = sorted(((p.get("cell") or [0, 0, 0, 0], p) for p in panes().get("panes") or []), key=lambda c: c[0][0])
    return rows


def page_state():
    return res(rpc("debug.page", {"page": "cmux.home-channels", "action": "state"}, 30)) or {}


def home_snapshot():
    """Workspaces, tabs and terminals of the tag's session through the public CLI (one object)."""
    return {"workspaces": tui_json("workspace", "list"), "tabs": tui_json("tab", "list"), "terminals": tui_json("terminal", "list"),
            "browsers": tui_json("browser", "list"), "debug_browsers": res(rpc("debug.browser.page_status")) or {}}


def find(obj, pred, out=None):
    out = [] if out is None else out
    if isinstance(obj, dict):
        if pred(obj):
            out.append(obj)
        for v in obj.values():
            find(v, pred, out)
    elif isinstance(obj, list):
        for v in obj:
            find(v, pred, out)
    return out


CUA = os.path.expanduser("~/.local/bin/cua-driver")


def cua(tool, args):
    p = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=90)
    R.setdefault("cua", []).append({"tool": tool, "exit": p.returncode, "out": (p.stdout + p.stderr)[:6000]})
    try:
        return json.loads(p.stdout)
    except ValueError:
        return {}


def post_click(x, y):
    """One real left click at screen point (x, y) (top-left origin): CGEvents at the HID tap, the
    window server's own pointer path (ctypes CoreGraphics; the SSH session has the Accessibility grant)."""
    import ctypes, ctypes.util
    cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))

    class P(ctypes.Structure):
        _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]
    cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
    cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, P, ctypes.c_uint32]
    cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    cg.CFRelease.argtypes = [ctypes.c_void_p]
    for kind in (5, 1, 2):  # mouseMoved, leftMouseDown, leftMouseUp
        e = cg.CGEventCreateMouseEvent(None, kind, P(x, y), 0)
        cg.CGEventPost(0, e)
        cg.CFRelease(e)
        time.sleep(0.08)  # human-like press interval for the window server, not app synchronization


def post_key(code):
    """One real key press (virtual key `code`) at the HID tap: the frontmost window's first responder gets it."""
    import ctypes, ctypes.util
    cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
    cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
    cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
    cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    cg.CFRelease.argtypes = [ctypes.c_void_p]
    for down in (True, False):
        e = cg.CGEventCreateKeyboardEvent(None, code, down)
        cg.CGEventPost(0, e)
        cg.CFRelease(e)
        time.sleep(0.05)  # human-like press interval for the window server, not app synchronization


def links_state():
    """The Chief home's app links (ChiefAppLinks): where they point and whether each is a socket now."""
    import stat
    out = {}
    for name in ("app.sock", "app-daemon.sock"):
        path = os.path.join(CHIEF, "state", name)
        try:
            target = os.readlink(path)
        except OSError as e:
            out[name] = {"error": str(e)}
            continue
        try:
            is_sock = stat.S_ISSOCK(os.stat(path).st_mode)
        except OSError as e:
            is_sock = "dangling: %s" % e
        out[name] = {"target": target, "socket": is_sock}
    return out


def chief_list():
    p = subprocess.run([CLI, "chief", "list", "--chief-home", CHIEF, "--json"], capture_output=True, text=True,
                       timeout=60, env=env_base())
    R.setdefault("chief_list", []).append({"exit": p.returncode, "out": p.stdout[-3000:], "err": p.stderr[-800:]})
    return p.stdout


def find_elements(obj, out):
    if isinstance(obj, dict):
        if "frame" in obj and ("role" in obj or "label" in obj):
            out.append(obj)
        for v in obj.values():
            find_elements(v, out)
    elif isinstance(obj, list):
        for v in obj:
            find_elements(v, out)
    return out


def real_click_link(pid, mark, text, role="link"):
    """Finds the link (AXLink whose label or value names `text`/`mark`) in the app's accessibility
    tree and clicks its center with a real pointer event. Returns what it did."""
    wins = cua("list_windows", {"pid": pid})
    rows = find(wins, lambda o: isinstance(o, dict) and "window_id" in o and o.get("pid") == pid)
    rows = [w for w in rows if (w.get("bounds") or {}).get("width", 0) > 600]
    if not rows:
        return {"error": "no window", "windows": str(wins)[:800]}
    win = max(rows, key=lambda w: (w.get("z_index") or 0))
    # The input job has the GUI session alone: the window comes forward so the click is not a first-mouse activation.
    R["front"] = cua("bring_to_front", {"pid": pid, "window_id": win["window_id"]})
    # Web content sits deep in the AX tree (WKWebView): past the default depth 25.
    state = cua("get_window_state", {"pid": pid, "window_id": win["window_id"], "include_screenshot": False, "query": text,
                                     "max_depth": 80, "max_elements": 8000})
    named = lambda e: text in str(e.get("label", "")) + str(e.get("value", "")) or mark in json.dumps(e)
    els = [e for e in find_elements(state, []) if role in str(e.get("role", "")).lower() and named(e)]
    if not els:
        # The query projection can miss web content: walk the whole tree once.
        full = cua("get_window_state", {"pid": pid, "window_id": win["window_id"], "include_screenshot": False,
                                        "max_depth": 80, "max_elements": 8000})
        R.setdefault("ax_full_counts", []).append({k: full.get(k) for k in ("element_count", "returned_element_count",
                                                                              "total_element_count", "elements_complete")})
        state = full
        els = [e for e in find_elements(state, []) if role in str(e.get("role", "")).lower() and named(e)]
    if not els and role == "link":
        # WebKit exposes an anchor's text as an AXStaticText child; a click on that text is a click on the link.
        els = [e for e in find_elements(state, []) if "statictext" in str(e.get("role", "")).lower()
               and (str(e.get("label", "")).strip() == text or str(e.get("value", "")).strip() == text)]
    if not els:
        return {"error": "no %s element" % role, "state": str(state)[:1500]}
    f = els[-1]["frame"]
    b = win["bounds"]
    x, y = f["x"] + f["w"] / 2, f["y"] + f["h"] / 2
    # AX frames are screen points; a window-local frame lies inside (0..width).
    if not (b["x"] <= x <= b["x"] + b["width"] and b["y"] <= y <= b["y"] + b["height"]):
        x, y = x + b["x"], y + b["y"]
    post_click(x, y)
    return {"window": win["window_id"], "bounds": b, "frame": f, "point": [x, y], "role": els[-1].get("role"), "label": els[-1].get("label")}


def shutdown_all(app):
    R["quit"] = rpc("action.run", {"id": "quitEndSessions"}, 10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        say("app pid %d did not quit within 60 s" % app.pid)
    R["end_agents"] = rpc("action.run", {"id": "endAgents"}, 10)
    env = {k: v for k, v in env_base().items()}
    for acp in (os.path.join(CHIEF, "acpmux"), os.path.join(HOME, ".acpmux")):
        if os.path.isdir(acp):
            R.setdefault("acpmux_shutdown", []).append(subprocess.run(
                [ACPMUX, "daemon", "shutdown"], env={**env, "ACPMUX_HOME": acp}, capture_output=True, text=True, timeout=30).returncode)
            try:
                c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(5)
                c.connect(os.path.join(acp, "router", "router.sock")); c.sendall(b'{"op":"shutdown"}\n'); c.recv(4096); c.close()
            except OSError:
                pass
    R["chief_shutdown"] = subprocess.run([CLI, "chief", "shutdown", "--chief-home", CHIEF], env=env,
                                         capture_output=True, text=True, timeout=90).returncode
    R["stop"] = subprocess.run([STOP], capture_output=True, text=True, timeout=180).returncode


os.makedirs(os.path.join(CHIEF, "optchat"), exist_ok=True)
os.makedirs(HOME, exist_ok=True)
open(os.path.join(CHIEF, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(SCRATCH, "cmux.json"), "w").write("{}")
open(os.path.join(SCRATCH, "ghostty"), "w").write("")
R["bundle_id"], R["chief_home"], R["owner_session"] = BUNDLE_ID, CHIEF, owner_session(CHIEF)


# The app's owner runtime base is the per-user temp dir (DaemonLauncher.userTemporaryDirectory), not the job's TMPDIR.
USER_TMP = subprocess.run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
OWNER_ENV = {"CMUX_TUI_STATE_DIR": os.path.join(CHIEF, "tui"), "TMPDIR": USER_TMP}
R["user_tmp"] = USER_TMP


def owner_status():
    p = subprocess.run([CLI, "--session", owner_session(CHIEF), "--json", "server", "status"], capture_output=True, text=True,
                       timeout=60, env={**env_base(), **OWNER_ENV})
    R.setdefault("owner_status", []).append({"exit": p.returncode, "out": p.stdout[-800:], "err": p.stderr[-400:]})
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {}


# 0. An owner of this build's Chief home started WITHOUT an install key (as an older build or the CLI did):
#    `server ensure` for the home's owner session and state directory, no --install-key-stdin.
pre = subprocess.run([CLI, "--session", owner_session(CHIEF), "--json", "server", "ensure"], capture_output=True, text=True,
                     timeout=120, env={**env_base(), **OWNER_ENV}, stdin=subprocess.DEVNULL)
R["cli_start"] = {"exit": pre.returncode, "out": pre.stdout[-800:], "err": pre.stderr[-400:]}
before = owner_status()
pre_pid = before.get("pid")
R["key_file_before"] = os.path.exists(os.path.join(CHIEF, "tui", "frontend-install-key"))
check("keyless_owner_running_before_app", before.get("status") == "running" and bool(pre_pid),
      {"status": before, "cli_err": (R.get("chief_list") or [{}])[-1].get("err", "")[-300:]})

env = env_base()
env.update({"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_CONFIG_FILE": os.path.join(SCRATCH, "cmux.json"), "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1600,980", "CMUX_NEXT_ONBOARDING_COMPUTER_USE": "mock",
            "CMUX_NEXT_CHIEF_ROOT": CHIEF_ROOT})
app = subprocess.Popen([os.path.join(APP, "Contents/MacOS/cmux DEV")], env=env, stdin=subprocess.DEVNULL,
                       stdout=open(os.path.join(OUT, "app.log"), "a"), stderr=subprocess.STDOUT)
try:
    until(lambda: os.path.exists(SOCK) and (res(rpc("debug.windows")) or {}).get("windows"), 240)
    R["home_show"] = rpc("action.run", {"id": "home.show", "focus": True, "wait": True}, 30)

    # 1. The app restarted the keyless owner once, with its key.
    def owner():
        o = (res(rpc("debug.home", {}, 30)) or {}).get("chief_owner") or {}
        return o if o.get("connected") and o.get("daemon_pid") and o.get("daemon_pid") != pre_pid else None
    o = until(owner, 120) or (res(rpc("debug.home", {}, 30)) or {}).get("chief_owner")
    after = owner_status()
    R["key_file_mode"] = oct(os.stat(os.path.join(CHIEF, "tui", "frontend-install-key")).st_mode & 0o777) \
        if os.path.exists(os.path.join(CHIEF, "tui", "frontend-install-key")) else None
    check("app_restarted_keyless_owner_with_key", bool(o) and o.get("home") == CHIEF and after.get("pid") == o.get("daemon_pid"),
          {"pre_pid": pre_pid, "owner": o, "status_after": after, "key_file_mode": R["key_file_mode"]})

    page = until(lambda: (lambda s: s if s.get("painted") else None)(page_state()), 120) or page_state()
    R["page_home"] = {k: page.get(k) for k in ("painted", "window_number", "instance", "url", "text")}
    until(lambda: None, 3)  # proof pacing: the page draws its list before the shot
    shot("1-home", app.pid)

    R["host_list"] = rpc("debug.page", {"page": "cmux.home-channels", "action": "call", "op": "cmux.chief.profile.list",
                                         "params": {"machine": "current", "session": "current"}}, 30)
    # 2. A Chief create from the page WITHOUT a gesture is refused.
    nog = rpc("debug.page", {"page": "cmux.home-channels", "action": "call", "op": "cmux.chief.profile.create",
                             "params": {"machine": "current", "session": "current", "display_name": "No Gesture %s" % MARK[-5:],
                                        "role": "", "personality": "", "instructions": "", "idempotency_key": "nog-" + MARK}}, 30)
    R["no_gesture_create"] = nog
    text = json.dumps(nog)
    check("profile_create_without_gesture_refused", "gesture_required" in text and "No Gesture" not in chief_list(),
          {"reply": text[:600]})

    # 3. New Chief through the page with the person's real click.
    name = "Proof Chief %s" % MARK[-5:]
    R["new_chief_action"] = rpc("action.run", {"id": "home.newChief", "focus": True, "wait": True}, 30)
    until(lambda: (lambda s: s if "Create Chief" in json.dumps(s) else None)(page_state()), 30)
    R["type_name"] = rpc("debug.page", {"page": "cmux.home-channels", "action": "type", "selector": ".lg-chief-names input",
                                         "text": name}, 30)
    until(lambda: None, 1)  # proof pacing: React applies the typed name before the click
    # A real click into the Name field first (the window gets real input before the gesture click, as in v3).
    R["name_click"] = real_click_link(app.pid, name, name, role="textfield")
    until(lambda: None, 1)  # proof pacing: the first click's activation settles before the gesture click
    R["create_click"] = real_click_link(app.pid, "Create Chief", "Create Chief", role="button")
    # What the host holds right after the click: the page's calls still running (id, op, age).
    R["in_flight_after_click"] = [(lambda s: {"t": round(time.time(), 3), "in_flight": s.get("in_flight"), "hash": s.get("hash")})(page_state())
                                  for _ in range(1) ]
    made = until(lambda: name in chief_list(), 30)
    R["in_flight_after_wait"] = (lambda s: {"in_flight": s.get("in_flight"), "hash": s.get("hash")})(page_state())
    R["host_list_after_click"] = rpc("debug.page", {"page": "cmux.home-channels", "action": "call", "op": "cmux.chief.profile.list",
                                                     "params": {"machine": "current", "session": "current"}}, 30)
    R["hangs"] = res(rpc("debug.hangs", {}, 30))
    R["debug_home_after_click"] = res(rpc("debug.home", {}, 30))
    until(lambda: None, 3)  # proof pacing: the page shows the new Chief before the shot
    after_page = page_state()
    R["page_after_create"] = json.dumps(after_page)[-3000:]
    shot("2-new-chief", app.pid)
    refused_text = "needs a verified cmux app connection"
    check("new_chief_created_owner_did_not_refuse", bool(made) and refused_text not in json.dumps(after_page)
          and name in json.dumps(after_page),
          {"click": R["create_click"], "list": (R.get("chief_list") or [{}])[-1], "page_tail": json.dumps(after_page)[-600:]})
finally:
    app_pid = app.pid
    shutdown_all(app)
    # The app's own unified log lines (its Logger messages; no key is ever logged).
    lg = subprocess.run(["/usr/bin/log", "show", "--info", "--debug", "--last", "20m", "--style", "compact", "--predicate",
                         "processID == %d" % app_pid], capture_output=True, text=True, timeout=180)
    open(os.path.join(OUT, "app-unified.log"), "w").write(lg.stdout[-400000:])
    # The app's own lines only (the WebKit lines push them out of the tail above).
    lg = subprocess.run(["/usr/bin/log", "show", "--info", "--debug", "--last", "20m", "--style", "compact", "--predicate",
                         'processID == %d AND subsystem == "com.cmuxterm.app.next"' % app_pid], capture_output=True, text=True, timeout=180)
    open(os.path.join(OUT, "app-cmux.log"), "w").write(lg.stdout[-400000:])
    json.dump(R, open(os.path.join(OUT, "result.json"), "w"), indent=1, default=str)
    for log in ("host.log",):
        try:
            shutil.copy(os.path.join(CHIEF, log), os.path.join(OUT, "chief-" + log))
        except OSError:
            pass
    shutil.rmtree(SCRATCH, ignore_errors=True)
ok = all(c["pass"] for c in R["checks"].values())
say("RESULT", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
