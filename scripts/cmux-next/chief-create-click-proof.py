#!/usr/bin/env python3
"""Chief create by a real click, and the page relay across a Chief owner restart (cx-ebm.59.5). Live proof on cmux-lawrence-2 (nx-remote --needs input --app-from-fleet,
own tag, own socket, isolated HOME and a per-build Chief home under /tmp via CMUX_NEXT_CHIEF_ROOT; run under `zsh -lic`).
Built from s7-proof-v3.py.
Submit the nx-remote job with --allow-agents: gui and input jobs default to ACPMUX_AGENT_LAUNCH=deny (cx-tgf4h).

0. Before the app runs, `cmux chief list --chief-home <this build's home>` starts the Chief owner WITHOUT an install key
   (as an older build or the CLI did). The owner does not verify the DEV app.
1. The app launches (unsigned DEV): its owner connection is not verified and the owner is idle, so the app restarts the
   owner once with the install key (debug.home chief_owner.daemon_pid changes, connected again).
2. Page Chief create WITHOUT a gesture: refused (gesture_required).
3. New Chief through the page with ONE REAL pointer click on Create Chief while cmux is inactive (debug.focus
   deactivate; the window stays in place). Immediately before the click the proof asserts that cmux is not active, no
   cmux window is key and the window server's front app is another app; else it sends no click. The Chief is created
   on the owner (chief list), the page shows no "needs a verified cmux app connection". Only the Home page accepts
   the first mouse: Settings (its browsing-data Clear acts on one click) and every page with no setting do not.
4. The owner restarts while the page is open: page relay calls during and after the restart answer within the relay
   deadline (16 s, checked at 18 s), and a second real
   click on Create Chief makes a Chief on the new owner (no page call left in flight).
Ends with quitEndSessions, endAgents, acpmux daemon shutdown + router shutdown, chief shutdown.
Reads NX_APP, NX_APP_TAG, NX_APP_STOP, NX_APP_CLI, NX_CAPTURE, NX_ARTIFACTS."""
import json, os, shutil, socket, subprocess, sys, tempfile, time
# cx-tgf4h: nx-remote gui and input jobs run with ACPMUX_AGENT_LAUNCH=deny
# (HQ #2130), so no Chief turn can start; fail at once, not after a reply wait.
if os.environ.get("ACPMUX_AGENT_LAUNCH", "").strip().lower() == "deny" or os.environ.get("CMUX_AGENTS_DISABLED", "").strip() == "1":
    sys.exit("chief-create-click-proof.py: this Chief proof needs agents; submit the job with `nx-remote --allow-agents` "
             "(ACPMUX_AGENT_LAUNCH=deny or CMUX_AGENTS_DISABLED=1 is set)")

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
    # The --needs input job owns the GUI session, so the app runs WITHOUT CMUX_NEXT_NO_ACTIVATE and may activate.
    # With it, every click landed on an inactive app; WKWebView does not accept a first mouse on a button, so AppKit
    # held the click back to activate the window, and NoActivateKeyboardGuard then gave the activation back: the
    # Create Chief click never reached the page (cx-ebm.59.5; 4 of 5 runs at 76bca7f6a85b, gate job
    # 1014-174413-fa40d9 at e7e462c474a4). The page's hovered primary button looked disabled.
    for kind, hold in ((5, 0.08), (1, 0.4), (2, 0.08)):  # mouseMoved, leftMouseDown (held), leftMouseUp
        e = cg.CGEventCreateMouseEvent(None, kind, P(x, y), 0)
        cg.CGEventPost(0, e)
        cg.CFRelease(e)
        time.sleep(hold)  # human-like press interval for the window server, not app synchronization


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


def real_click_link(pid, mark, text, role="link", front=True, before_click=None):
    """Finds the link (AXLink whose label or value names `text`/`mark`) in the app's accessibility
    tree and clicks its center with a real pointer event. Returns what it did. `before_click` runs
    immediately before the pointer event; when it returns a falsy "ok", the click is not sent."""
    wins = cua("list_windows", {"pid": pid})
    rows = find(wins, lambda o: isinstance(o, dict) and "window_id" in o and o.get("pid") == pid)
    rows = [w for w in rows if (w.get("bounds") or {}).get("width", 0) > 600]
    if not rows:
        return {"error": "no window", "windows": str(wins)[:800]}
    win = max(rows, key=lambda w: (w.get("z_index") or 0))
    # The input job has the GUI session alone: the window comes forward so the click is not a first-mouse activation.
    if front:
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
    done = {"window": win["window_id"], "bounds": b, "frame": f, "point": [x, y], "role": els[-1].get("role"), "label": els[-1].get("label")}
    if before_click:
        done["before_click"] = before_click()
        if not done["before_click"].get("ok"):
            done["error"] = "precondition failed; click not sent"
            return done
    post_click(x, y)
    return done


def lsapp(*args):
    return subprocess.run(["/usr/bin/lsappinfo", *args], capture_output=True, text=True, timeout=10).stdout.strip()


def front_bundle_id():
    """The bundle id of the frontmost app, as LaunchServices sees it (outside the app's own view)."""
    import re
    info = lsapp("info", "-only", "bundleid", lsapp("front"))
    m = re.search(r'(?:bundleID|CFBundleIdentifier)"?\s*=\s*"([^"]+)"', info)
    return m.group(1) if m else None


def finder_pid():
    """Finder's pid from LaunchServices (one named app, no process scan): the app the proof hands activation to."""
    import re
    m = re.search(r'"?pid"?\s*=\s*(\d+)', lsapp("info", "-only", "pid", lsapp("find", "bundleid=com.apple.finder")))
    return int(m.group(1)) if m else None


def inactive_now():
    """cmux is NOT active and none of its windows is key: the app's own report (debug.focus) and the
    window server's front app agree. Read immediately before the click."""
    f = res(rpc("debug.focus", {}, 30))
    f = f if isinstance(f, dict) else {}
    keys = [w.get("id") for w in f.get("windows") or [] if isinstance(w, dict) and w.get("is_key")]
    front = front_bundle_id()
    # A front app that LaunchServices does not name is not proof that another app is in front.
    ok = f.get("app_active") is False and f.get("key_window") is None and not keys and front not in (None, BUNDLE_ID)
    state = {"ok": ok, "app_active": f.get("app_active"), "key_window": f.get("key_window"), "key_windows": keys,
             "front_app": front, "app_bundle": BUNDLE_ID, "t": round(time.time(), 3)}
    say("INACTIVE-BEFORE-CLICK " + json.dumps(state))
    return state


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
                [ACPMUX, "daemon", "shutdown", "--end-agents"], env={**env, "ACPMUX_HOME": acp}, capture_output=True, text=True, timeout=30).returncode)
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
# Channels is off by default (cx-frn2y); this check uses both views.
open(os.path.join(SCRATCH, "cmux.json"), "w").write('{"home": {"channelsEnabled": true}}')
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
env.update({"CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_CONFIG_FILE": os.path.join(SCRATCH, "cmux.json"), "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
            "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1600,980", "CMUX_NEXT_ONBOARDING_COMPUTER_USE": "mock",
            "CMUX_NEXT_CHIEF_ROOT": CHIEF_ROOT})
app = subprocess.Popen([os.path.join(APP, "Contents/MacOS/cmux DEV")], env=env, stdin=subprocess.DEVNULL,
                       stdout=open(os.path.join(OUT, "app.log"), "a"), stderr=subprocess.STDOUT)
try:
    until(lambda: os.path.exists(SOCK) and (res(rpc("debug.windows")) or {}).get("windows"), 240)
    R["home_show"] = rpc("action.run", {"id": "home.show", "focus": True, "wait": True}, 30)
    # The Home dock opens the native Messages view by default (a23b52396134): the Channels page is one switch away.
    R["home_channels"] = rpc("action.run", {"id": "home.switchView", "focus": True, "wait": True,
                                            "arguments": {"view": "channels"}}, 30)

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
    # The person works in another app: cmux is inactive, its window stays where it is. ONE click on Create Chief
    # must make the Chief (the first click on an inactive window reaches the page, as on the native controls).
    R["finder_pid"] = finder_pid()
    R["deactivate"] = res(rpc("debug.focus", {"deactivate": True, "activate_pid": R["finder_pid"]}, 30)) or {}
    until(lambda: inactive_now().get("ok"), 10)
    # The precondition is read again immediately before the pointer event (in real_click_link); the click is
    # sent only when cmux is not active and no cmux window is key, so an active app cannot make a false green.
    R["create_click"] = real_click_link(app.pid, "Create Chief", "Create Chief", role="button", front=False,
                                        before_click=inactive_now)
    pre = R["create_click"].get("before_click") or {}
    check("app_inactive_and_window_not_key_before_create_click", bool(pre.get("ok")), pre)
    R["focus_after_click"] = {k: (res(rpc("debug.focus", {}, 30)) or {}).get(k) for k in ("app_active", "key_window")}
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
    # Red (no first mouse): the click only activates the window, no create call reaches the host and the owner's
    # chief list has no new Chief. Green: the one click makes it.
    check("new_chief_created_owner_did_not_refuse", bool(made) and refused_text not in json.dumps(after_page)
          and name in json.dumps(after_page),
          {"click": R["create_click"], "created_on_owner": bool(made), "focus_after_click": R["focus_after_click"],
           "list": (R.get("chief_list") or [{}])[-1], "page_tail": json.dumps(after_page)[-600:]})

    # 4. The Chief owner restarts while the page is open (the app's main connection ensures a new owner process on
    #    the same socket). A page relay call then answers within the relay's deadline (16 s) plus margin, and a real
    #    click on Create Chief makes a Chief on the NEW owner: its gesture token is bound to a relay connection on the
    #    new owner, so a relay still on the old owner (or a token bound to another connection) cannot pass.
    try:
        before_restart = owner_status()
        check("owner_running_before_restart", bool(before_restart.get("pid")), {"status": before_restart})
        R["owner_stop"] = subprocess.run([CLI, "--session", owner_session(CHIEF), "--json", "server", "stop", "--force"],
                                         capture_output=True, text=True, timeout=60, env={**env_base(), **OWNER_ENV}).returncode
        def new_owner():
            o = (res(rpc("debug.home", {}, 30)) or {}).get("chief_owner") or {}
            return o if o.get("connected") and o.get("daemon_pid") and o.get("daemon_pid") != before_restart.get("pid") else None
        # A relay call while the owner is down or coming back: an answer (ok or a typed error) within the deadline.
        t0 = time.time()
        during = rpc("debug.page", {"page": "cmux.home-channels", "action": "call", "op": "cmux.chief.profile.list",
                                    "params": {"machine": "current", "session": "current"}}, 30)
        during_ms = int((time.time() - t0) * 1000)
        check("relay_call_answers_while_owner_restarts", during_ms <= 18000 and (res(during) or {}).get("t") in ("ok", "err"),
              {"ms": during_ms, "reply": json.dumps(during)[:600]})
        restarted = until(new_owner, 120)
        t0 = time.time()
        relay_after = rpc("debug.page", {"page": "cmux.home-channels", "action": "call", "op": "cmux.chief.profile.list",
                                         "params": {"machine": "current", "session": "current"}}, 30)
        relay_ms = int((time.time() - t0) * 1000)
        check("relay_call_answers_after_owner_restart", bool(restarted) and bool(before_restart.get("pid")) and relay_ms <= 18000
              and (res(relay_after) or {}).get("t") == "ok",
              {"old_pid": before_restart.get("pid"), "owner": restarted, "ms": relay_ms, "reply": json.dumps(relay_after)[:600]})
        name2 = "Second Chief %s" % MARK[-5:]
        R["new_chief_action_2"] = rpc("action.run", {"id": "home.newChief", "focus": True, "wait": True}, 30)
        until(lambda: (lambda s: s if "Create Chief" in json.dumps(s) else None)(page_state()), 30)
        R["type_name_2"] = rpc("debug.page", {"page": "cmux.home-channels", "action": "type", "selector": ".lg-chief-names input",
                                               "text": name2}, 30)
        until(lambda: None, 1)  # proof pacing: React applies the typed name before the click
        R["name_click_2"] = real_click_link(app.pid, name2, name2, role="textfield")
        until(lambda: None, 1)  # proof pacing: the first click's activation settles before the gesture click
        R["create_click_2"] = real_click_link(app.pid, "Create Chief", "Create Chief", role="button")
        made2 = until(lambda: name2 in chief_list(), 30)
        after2 = page_state()
        R["in_flight_after_restart_click"] = after2.get("in_flight")
        shot("3-after-owner-restart", app.pid)
        check("new_chief_created_on_restarted_owner", bool(made2) and not after2.get("in_flight"),
              {"click": R["create_click_2"], "list": (R.get("chief_list") or [{}])[-1], "in_flight": after2.get("in_flight"),
               "hash": after2.get("hash"), "page_tail": json.dumps(after2)[-600:]})
    except Exception as e:  # step 4 fails alone; the Settings check below still runs
        check("owner_restart_steps_ran", False, {"error": repr(e)})
    # Click-through must not skip a confirmation: Settings (browsing-data Clear acts on one click, no sheet) does
    # not accept the first mouse; the Home page does.
    home_fm = page_state().get("accepts_first_mouse")
    R["open_settings"] = rpc("action.run", {"id": "openSettings", "wait": True}, 30)
    # The answer is the view's own and depends only on the page it shows, so the page need not have painted.
    settings = until(lambda: (lambda s: s if "accepts_first_mouse" in s else None)(
        res(rpc("debug.page", {"page": "cmux.settings", "action": "state"}, 30)) or {}), 60) or {}
    # Pages that set nothing get the fail-closed default (only Home Channels opts in): every live page that is not
    # Home Channels or Settings (History after history.show, the parked pooled spare), each by its instance.
    R["open_history"] = rpc("action.run", {"id": "history.show", "wait": True}, 30)
    def unset_pages():
        rows = (res(rpc("debug.page", {"action": "list"}, 30)) or {}).get("pages") or []
        rows = [r for r in rows if isinstance(r, dict) and r.get("page") not in ("cmux.home-channels", "cmux.settings")]
        return {"%s#%s" % (r.get("page"), r.get("instance")): (res(rpc("debug.page", {
            "page": r.get("page"), "instance": r.get("instance"), "parked": bool(r.get("parked")), "action": "state"}, 30))
            or {}).get("accepts_first_mouse") for r in rows} or None
    unset = until(unset_pages, 30) or {}
    R["unset_pages"] = unset
    check("settings_page_refuses_first_mouse_home_accepts", home_fm is True and settings.get("accepts_first_mouse") is False,
          {"home_channels": home_fm, "settings": settings.get("accepts_first_mouse"), "settings_painted": settings.get("painted")})
    check("page_without_setting_refuses_first_mouse", bool(unset) and all(v is False for v in unset.values()), unset)
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
