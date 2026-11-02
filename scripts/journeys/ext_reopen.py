"""REOPEN VIDEO (Lawrence 2026-11-02 via cmux-ad: "killing + reopening cmux must be super fast, and have video
evidence of all terminals restoring super fast"). Each cycle ends the app one way, reopens it, and films the whole
display from before the end to after every visible terminal echoed a typed key.

driver.py loads this file (load_extensions) on the mini under the stock /usr/bin/python3 (3.9, standard library
only). It must not import driver.py: install() gets the driver module instead. It needs a whole-host lease
(run.py --whole-host): a key window, and CuaDriver's Screen Recording and Accessibility grants on the mini.

Step (`do`):
  reopen_video {count?, how?, type_keys?, settle?}
      COUNT cycles (default 5) of: the exact state before (windows and their frames on the window server, each
      window's workspaces and selection, every workspace's panes and tabs, the focused pane, every visible
      terminal's screen and scrollback); the display video starts (CuaDriver `start_recording`, ScreenCaptureKit,
      the whole main display, H.264 at its 30 fps); two cursor moves at known wall times (the video's clock
      sync); the END of kind HOW; the reopen through LaunchServices (`open -a`, the app comes to the front, as a
      Dock click does); no socket read until the video has the reopen (the app is not polled while it launches);
      when the new process is the front app, a marker key (TYPE_KEYS, default true) by a real HID key into the
      focused terminal, then a click and a key into each other visible terminal; the video stops; then the app's
      own launch marks and the exact state after, and the differences.
      HOW: quit-keep-hid  a real Cmd-Q (CuaDriver hotkey); a quit dialog is answered with its default (Keep)
           kill-app       SIGKILL of the app only (its daemon and the shells live on)
           kill-daemons   SIGKILL of the app and every background process of its bundle (daemon, holder, terminal
                          hosts): nothing of cmux runs at the reopen
           logout         the quit Apple event with kAEQuitReason kAEReallyLogOut, as loginwindow sends at a logout
                          (AESendMessage); sent only when the system says, with no prompt, that this process may
                          (AEDeterminePermissionToAutomateTarget, askUserIfNeeded false); else the cycle is not run
      Writes, per cycle N: reopen-N.mp4 (the video) and reopen-N.json (wall times of each event, the new process's
      kernel start, the app's main_start and launch marks, the panes' screen rects before and after, the markers'
      cell rects, the sync moves, the state before and after and the differences). reopen_judge.py (on the VM)
      reads the video: (1) the first window frame, (2) every visible terminal back to its last content, (3) each
      marker's echo, all in ms from main() and in display refreshes.
      The step fails when a cycle did not reopen; exactness differences and missed targets are judged from the
      files, not here.
"""
import ctypes
import json
import os
import re
import select
import shutil
import signal
import subprocess
import time
from pathlib import Path

D = None

CUA = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
MARKER_KEY = "x"
# Seconds the video runs after the last marker key (its echo must be on film), and before the end (the reference
# frames of every pane, and the sync moves).
TAIL_SECONDS = 1.5
LEAD_SECONDS = 1.0
FRONT_TIMEOUT = 20.0


def install(driver):
    global D
    D = driver


# ---- CuaDriver: one MCP session for the cycle (the recorder lives as long as its client) -----------------------

class Cua:
    def __init__(self):
        if not os.path.exists(CUA):
            raise D.StepError(f"reopen_video: no CuaDriver at {CUA} on this mini")
        self.proc = subprocess.Popen([CUA, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 1
        self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "reopen-video", "version": "1"}})
        self.rpc("notifications/initialized", notify=True)
        # The agent cursor overlay glides to each action: it would read as motion on the film.
        self.tool("set_agent_cursor_enabled", {"enabled": False}, check=False)

    def rpc(self, method, params=None, notify=False, timeout=30.0):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            message["id"] = self.next_id
            self.next_id += 1
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()
        if notify:
            return None
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            ready, _, _ = select.select([self.proc.stdout], [], [], max(0.0, end - time.monotonic()))
            if not ready:
                break
            line = self.proc.stdout.readline()
            if not line:
                raise D.StepError(f"cua-driver mcp closed during {method}")
            try:
                reply = json.loads(line)
            except ValueError:
                continue
            if reply.get("id") == message["id"]:
                return reply
        raise D.StepError(f"cua-driver mcp: no answer to {method} within {timeout} s")

    def tool(self, name, args, check=True, timeout=30.0):
        reply = self.rpc("tools/call", {"name": name, "arguments": args}, timeout=timeout)
        result = reply.get("result") or {}
        bad = "error" in reply or result.get("isError")
        if bad and check:
            raise D.StepError(f"cua-driver {name}: {json.dumps(reply)[:400]}")
        return result

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=20)
        except (OSError, subprocess.TimeoutExpired):
            self.proc.kill()


def cua_call(tool, args, timeout=30):
    """One CuaDriver tool call in its OWN session (`cua-driver call`): the recording session's per-action
    before/after screenshots (0.5-2.6 s per action while a film runs) do not apply to it. Returns (sent wall, done
    wall, answer)."""
    sent = time.time()
    try:
        done = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise D.StepError(f"cua-driver call {tool} ran past {timeout} s")
    return sent, time.time(), ((done.stdout or "") + (done.stderr or ""))[-300:]


def _windows_of(cua, pid):
    """The app's on-screen layer-0 windows (CuaDriver list_windows), frontmost first."""
    result = cua.tool("list_windows", {}, check=False)
    rows = (result.get("structuredContent") or {}).get("windows") or []
    if not rows:
        for part in result.get("content") or []:
            try:
                rows = json.loads(part.get("text", "")).get("windows", [])
            except (ValueError, AttributeError):
                continue
            if rows:
                break
    mine = [w for w in rows if int(w.get("pid") or w.get("owner_pid") or -1) == pid]
    return [w for w in mine if w.get("layer", 0) == 0 and w.get("is_on_screen", w.get("on_screen", True))]


def _wid(window):
    return int(window.get("window_id") or window.get("id") or window.get("windowNumber"))


# ---- the window server and the process table (no socket read of the launching app) ----------------------------

SCREEN_JXA = """
ObjC.import('AppKit');
const s = $.NSScreen.screens.objectAtIndex(0); const f = s.frame;
JSON.stringify({w: f.size.width, h: f.size.height, scale: s.backingScaleFactor,
  hz: s.maximumFramesPerSecond === undefined ? null : s.maximumFramesPerSecond});
"""

WINDOWS_JXA = """
ObjC.import('CoreGraphics');
const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
JSON.stringify(list.filter(w => w.kCGWindowLayer === 0).map((w, i) => ({order: i, pid: w.kCGWindowOwnerPID,
  owner: w.kCGWindowOwnerName, number: w.kCGWindowNumber, x: w.kCGWindowBounds.X, y: w.kCGWindowBounds.Y,
  w: w.kCGWindowBounds.Width, h: w.kCGWindowBounds.Height})));
"""



def _jxa(script, *args, timeout=30):
    done = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", script, *map(str, args)],
                          capture_output=True, text=True, timeout=timeout)
    return done.stdout.strip(), done.stderr.strip(), done.returncode


def _jxa_json(script, default):
    out, _err, _code = _jxa(script)
    try:
        return json.loads(out)
    except ValueError:
        return default


class _ProcBSDInfo(ctypes.Structure):
    _fields_ = [("pbi_flags", ctypes.c_uint32), ("pbi_status", ctypes.c_uint32), ("pbi_xstatus", ctypes.c_uint32),
                ("pbi_pid", ctypes.c_uint32), ("pbi_ppid", ctypes.c_uint32), ("pbi_uid", ctypes.c_uint32),
                ("pbi_gid", ctypes.c_uint32), ("pbi_ruid", ctypes.c_uint32), ("pbi_rgid", ctypes.c_uint32),
                ("pbi_svuid", ctypes.c_uint32), ("pbi_svgid", ctypes.c_uint32), ("rfu_1", ctypes.c_uint32),
                ("pbi_comm", ctypes.c_char * 16), ("pbi_name", ctypes.c_char * 32), ("pbi_nfiles", ctypes.c_uint32),
                ("pbi_pgid", ctypes.c_uint32), ("pbi_pjobc", ctypes.c_uint32), ("e_tdev", ctypes.c_uint32),
                ("e_tpgid", ctypes.c_uint32), ("pbi_nice", ctypes.c_int32), ("pbi_start_tvsec", ctypes.c_uint64),
                ("pbi_start_tvusec", ctypes.c_uint64)]


_LIBPROC = None


def _libproc():
    global _LIBPROC
    if _LIBPROC is None:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        lib.proc_pidinfo.restype = ctypes.c_int
        lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
        lib.proc_pidpath.restype = ctypes.c_int
        lib.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.proc_listallpids.restype = ctypes.c_int
        _LIBPROC = lib
    return _LIBPROC


def process_start(pid):
    """Wall-clock seconds when the kernel started PID (PROC_PIDTBSDINFO: the app's own launch clock), or None."""
    info = _ProcBSDInfo()
    if _libproc().proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        return None
    return info.pbi_start_tvsec + info.pbi_start_tvusec / 1e6


def _pid_path(pid):
    buf = ctypes.create_string_buffer(4096)
    n = _libproc().proc_pidpath(pid, buf, ctypes.sizeof(buf))
    return buf.value.decode(errors="replace") if n > 0 else ""


def _all_pids():
    lib = _libproc()
    count = lib.proc_listallpids(None, 0)
    arr = (ctypes.c_int * (count + 64))()
    n = lib.proc_listallpids(arr, ctypes.sizeof(arr))
    return [arr[i] for i in range(max(0, n)) if arr[i] > 0]


def find_new_app(executable, old, timeout):
    """The pid of a process running EXECUTABLE other than OLD (the reopened app), from the kernel's process list
    (libproc, no subprocess), polled every 5 ms; None after TIMEOUT s."""
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        for pid in _all_pids():
            if pid != old and _pid_path(pid) == executable:
                return pid
        time.sleep(0.02)
    return None


def front_pid():
    """The front app's pid (lsappinfo: the window server's own answer, no Apple event)."""
    out = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "pid", "-app",
                          subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True).stdout.strip()],
                         capture_output=True, text=True).stdout
    found = re.search(r"pid\"?\s*=\s*(\d+)", out)
    return int(found.group(1)) if found else None


# ---- CoreGraphics: the pointer jump (clock sync) and, where this process may post events, the HID key ----------

class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_CG = None


def _cg():
    global _CG
    if _CG is None:
        cg = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        cg.CGWarpMouseCursorPosition.argtypes = [CGPoint]
        cg.CGWarpMouseCursorPosition.restype = ctypes.c_int32
        cg.CGEventCreate.argtypes = [ctypes.c_void_p]
        cg.CGEventCreate.restype = ctypes.c_void_p
        cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
        cg.CGEventGetLocation.restype = CGPoint
        cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
        cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cg.CGEventPost.restype = None
        cg.CFRelease.argtypes = [ctypes.c_void_p]
        cg.CGPreflightPostEventAccess.restype = ctypes.c_bool
        _CG = cg
    return _CG


def cursor_at():
    cg = _cg()
    ev = cg.CGEventCreate(None)
    if not ev:
        return None
    loc = cg.CGEventGetLocation(ev)
    cg.CFRelease(ev)
    return (loc.x, loc.y)


def warp(x, y):
    """Moves the real pointer at once (CGWarpMouseCursorPosition: no event, no animation); True when the pointer is
    there after."""
    try:
        err = _cg().CGWarpMouseCursorPosition(CGPoint(x, y))
        at = cursor_at()
    except (OSError, AttributeError):
        return False
    return err == 0 and at is not None and abs(at[0] - x) < 1.5 and abs(at[1] - y) < 1.5


def can_post_events():
    try:
        return bool(_cg().CGPreflightPostEventAccess())
    except (OSError, AttributeError):
        return False


KEYCODE_X = 7  # kVK_ANSI_X


def post_click(x, y):
    """A HID left click at screen point (x, y) (the pointer warps there first)."""
    cg = _cg()
    cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
    cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
    warp(x, y)
    for kind in (1, 2):  # kCGEventLeftMouseDown, kCGEventLeftMouseUp
        ev = cg.CGEventCreateMouseEvent(None, kind, CGPoint(x, y), 0)
        cg.CGEventPost(0, ev)
        cg.CFRelease(ev)


def post_key(keycode=KEYCODE_X):
    """A HID key down and up (kCGHIDEventTap); returns the wall times around the down."""
    cg = _cg()
    down = cg.CGEventCreateKeyboardEvent(None, keycode, True)
    up = cg.CGEventCreateKeyboardEvent(None, keycode, False)
    before = time.time()
    cg.CGEventPost(0, down)
    after = time.time()
    cg.CGEventPost(0, up)
    cg.CFRelease(down)
    cg.CFRelease(up)
    return before, after


# ---- the logout quit: the Apple event loginwindow sends (kAEQuitApplication, kAEQuitReason kAEReallyLogOut) ----

class AEDesc(ctypes.Structure):
    _fields_ = [("descriptorType", ctypes.c_uint32), ("dataHandle", ctypes.c_void_p)]


def _fourcc(text):
    return int.from_bytes(text.encode("ascii"), "big")


def send_logout_quit(pid):
    """Sends PID the quit Apple event with kAEQuitReason = kAEReallyLogOut. Asks the system first, without a
    prompt, whether this process may send it (AEDeterminePermissionToAutomateTarget, askUserIfNeeded false): a
    consent dialog must never open on a shared mini. Returns ("sent", 0) or (why not, status)."""
    cs = ctypes.CDLL("/System/Library/Frameworks/CoreServices.framework/CoreServices")
    cs.AECreateDesc.argtypes = [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_long, ctypes.POINTER(AEDesc)]
    cs.AECreateDesc.restype = ctypes.c_int16
    cs.AEDeterminePermissionToAutomateTarget.argtypes = [ctypes.POINTER(AEDesc), ctypes.c_uint32, ctypes.c_uint32, ctypes.c_bool]
    cs.AEDeterminePermissionToAutomateTarget.restype = ctypes.c_int32
    cs.AECreateAppleEvent.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(AEDesc), ctypes.c_int16, ctypes.c_int32,
                                      ctypes.POINTER(AEDesc)]
    cs.AECreateAppleEvent.restype = ctypes.c_int16
    cs.AEPutAttributePtr.argtypes = [ctypes.POINTER(AEDesc), ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_long]
    cs.AEPutAttributePtr.restype = ctypes.c_int16
    cs.AESendMessage.argtypes = [ctypes.POINTER(AEDesc), ctypes.POINTER(AEDesc), ctypes.c_int32, ctypes.c_long]
    cs.AESendMessage.restype = ctypes.c_int32
    cs.AEDisposeDesc.argtypes = [ctypes.POINTER(AEDesc)]
    target, event, reply = AEDesc(), AEDesc(), AEDesc()
    kpid = ctypes.c_int32(pid)
    err = cs.AECreateDesc(_fourcc("kpid"), ctypes.byref(kpid), 4, ctypes.byref(target))
    if err:
        return f"AECreateDesc {err}", err
    try:
        allowed = cs.AEDeterminePermissionToAutomateTarget(ctypes.byref(target), _fourcc("aevt"), _fourcc("quit"), False)
        if allowed != 0:
            # -1744: a consent prompt would be needed; -1743: denied. Never ask.
            return f"no consent to send a quit event (AEDeterminePermissionToAutomateTarget {allowed})", allowed
        err = cs.AECreateAppleEvent(_fourcc("aevt"), _fourcc("quit"), ctypes.byref(target), -1, 0, ctypes.byref(event))
        if err:
            return f"AECreateAppleEvent {err}", err
        reason = ctypes.c_uint32(_fourcc("rlgo"))
        err = cs.AEPutAttributePtr(ctypes.byref(event), _fourcc("why?"), _fourcc("enum"), ctypes.byref(reason), 4)
        if err:
            return f"AEPutAttributePtr {err}", err
        status = cs.AESendMessage(ctypes.byref(event), ctypes.byref(reply), 1, 600)  # kAENoReply, 10 s in ticks
        return ("sent", 0) if status == 0 else (f"AESendMessage {status}", status)
    finally:
        for desc in (target, event, reply):
            if desc.dataHandle:
                cs.AEDisposeDesc(ctypes.byref(desc))


# ---- the exact state a reopen must give back -------------------------------------------------------------------

def _visible_terminals(j):
    report = j.app.rpc("debug.surfaces", {"text": True}, timeout=15) or {}
    rows = []
    for window in report.get("windows", []):
        for p in window.get("panes", []):
            if isinstance(p, dict) and p.get("visible") and p.get("kind") == "terminal":
                rows.append({"window": window.get("window"), "pane": p.get("pane"), "terminal": p.get("terminal_id"),
                             "workspace": p.get("workspace"), "focused": bool(p.get("focused")), "grid": p.get("grid"),
                             "text": p.get("text") or "", "attach": p.get("attach"), "link": p.get("link"),
                             "shown_tab": p.get("shown_tab"), "selected_tab": p.get("selected_tab")})
    return rows


def _topology_shape(topo):
    """Every workspace in order with its screens, panes and tabs (ids, names, selection): what must come back."""
    shape = []
    for ws in topo.get("workspaces", []):
        screens = []
        for screen in ws.get("screens", []):
            panes = []
            for pane in screen.get("panes", []):
                tabs = []
                for tab in pane.get("tabs", []):
                    term = tab.get("terminal")
                    term = term.get("id") if isinstance(term, dict) else term
                    tabs.append([tab.get("id"), tab.get("kind"), str(term) if term else None, tab.get("title")])
                panes.append({"id": pane.get("id"), "tabs": tabs, "selected": pane.get("selected_tab") or pane.get("selected")})
            screens.append({"id": screen.get("id"), "panes": panes, "focused": screen.get("focused_pane") or screen.get("focused")})
        shape.append({"id": ws.get("id"), "name": ws.get("name"), "screens": screens,
                      "selected_screen": ws.get("selected_screen") or ws.get("selected")})
    return shape


def _history(j, term, limit=60):
    try:
        answer = j.app.cmux("terminal", term, "history", "read", "--limit", str(limit))
    except D.StepError as error:
        return {"error": str(error)[-200:]}
    for _ in range(3):
        if isinstance(answer, dict) and "rows" not in answer:
            answer = next((answer[k] for k in ("value", "result", "data") if isinstance(answer.get(k), dict)), answer)
    if not isinstance(answer, dict) or not isinstance(answer.get("rows"), list):
        return {"error": f"no rows: {json.dumps(answer)[:200]}"}
    texts = ["".join(str(r.get("text", "")) for r in row.get("runs", []) if isinstance(r, dict))
             for row in answer["rows"] if isinstance(row, dict)]
    return {"total": int(answer.get("start") or 0) + len(texts), "tail": [t.rstrip() for t in texts[-12:]]}


def main_windows(server):
    """The app's real windows on the window server (wider and taller than 100 points), front to back; the app also
    has small helper windows (a few points wide, at the pane edges) that are not compared one by one."""
    return [w for w in server if (w.get("w") or 0) > 100 and (w.get("h") or 0) > 100 and abs(w.get("x") or 0) < 50000]


def exact_state(j):
    """What a reopen must give back, read through the socket, the daemon CLI and the window server."""
    windows = j.app.rpc("debug.windows", timeout=15) or {}
    server = [w for w in _jxa_json(WINDOWS_JXA, []) if w.get("pid") == j.app.pid]
    terms = _visible_terminals(j)
    topo = j.topology()
    # debug.surfaces' terminal_id is the view's; the daemon's terminal id is the topology's (pane -> shown tab).
    by_tab, by_pane = {}, {}
    for _ws, pane, tab, term in j.places(topo):
        if term:
            by_tab[tab.get("id")] = term
            by_pane.setdefault(pane.get("id"), []).append(term)
    # A pane whose program draws all the time (a TUI) has no fixed screen to compare: read the screens again.
    time.sleep(0.3)
    again = {t["pane"]: t["text"] for t in _visible_terminals(j)}
    for t in terms:
        t["live"] = again.get(t["pane"]) != t["text"]
    for t in terms:
        # The pane's SHOWN tab's terminal; a pane with one terminal tab when the tab id is not in the topology.
        only = by_pane.get(t["pane"]) or []
        t["terminal"] = by_tab.get(t.get("shown_tab")) or (only[0] if len(only) == 1 else None)
    state = {
        "app_pid": j.app.pid,
        "windows": [{"id": w.get("id"), "selected": w.get("selected"), "workspaces": w.get("workspaces"),
                     "sidebar_width": w.get("sidebar_width"), "sidebar_hidden": w.get("sidebar_hidden"),
                     "full_screen": w.get("full_screen"), "display": w.get("display"), "visible": w.get("visible")}
                    for w in windows.get("windows", []) if w.get("open", True)],
        "recency": windows.get("recency"),
        "server_windows": [{k: w.get(k) for k in ("order", "number", "x", "y", "w", "h")} for w in main_windows(server)],
        "helper_windows": len(server) - len(main_windows(server)),
        "topology": _topology_shape(topo),
        "visible_terminals": [{k: t[k] for k in ("window", "pane", "terminal", "workspace", "focused", "grid", "shown_tab", "live")}
                              for t in terms],
        "screens": {t["pane"]: t["text"] for t in terms},
        "history": {t["pane"]: _history(j, t["terminal"]) for t in terms if t.get("terminal")},
    }
    return state


def _screen_lines(text):
    return [line.rstrip() for line in (text or "").split("\n")]


def state_differences(before, after):
    """Every way AFTER is not BEFORE: window frames and order, selection, workspaces, panes, focus, the visible
    terminals' screens and scrollback. Empty when the reopen gave everything back exactly."""
    out = []
    if before.get("helper_windows") != after.get("helper_windows"):
        out.append(f"small helper windows {before.get('helper_windows')} -> {after.get('helper_windows')}")
    if len(before["server_windows"]) != len(after["server_windows"]):
        out.append(f"window count {len(before['server_windows'])} -> {len(after['server_windows'])}")
    for i, (b, a) in enumerate(zip(before["server_windows"], after["server_windows"])):
        for key in ("x", "y", "w", "h"):
            if b.get(key) != a.get(key):
                out.append(f"window {i + 1} frame {key} {b.get(key)} -> {a.get(key)}")
    bw = {w["id"]: w for w in before["windows"]}
    aw = {w["id"]: w for w in after["windows"]}
    for wid, b in bw.items():
        a = aw.get(wid)
        if a is None:
            out.append(f"window {wid[:8]} not back")
            continue
        for key in ("selected", "workspaces", "sidebar_width", "sidebar_hidden", "full_screen", "display"):
            if b.get(key) != a.get(key):
                shown = (lambda v: v if not isinstance(v, list) else f"{len(v)} ids")
                out.append(f"window {wid[:8]} {key} {shown(b.get(key))} -> {shown(a.get(key))}"
                           + (" (order differs)" if key == "workspaces" and isinstance(b.get(key), list)
                              and sorted(b.get(key) or []) == sorted(a.get(key) or []) else ""))
    if (before.get("recency") or [None])[0] != (after.get("recency") or [None])[0]:
        out.append(f"key window {str((before.get('recency') or [None])[0])[:8]} -> {str((after.get('recency') or [None])[0])[:8]}")
    if before["topology"] != after["topology"]:
        bt = {w["id"]: w for w in before["topology"]}
        at = {w["id"]: w for w in after["topology"]}
        lost = [w for w in bt if w not in at]
        if lost:
            out.append(f"{len(lost)} workspace(s) not back")
        if [w["id"] for w in before["topology"]] != [w["id"] for w in after["topology"] if w["id"] in bt]:
            out.append("workspace order differs")
        for wid in bt:
            if wid in at and bt[wid] != at[wid]:
                out.append(f"workspace {str(bt[wid].get('name'))[:24]}: panes, tabs or selection differ")
    bv = {t["pane"]: t for t in before["visible_terminals"]}
    av = {t["pane"]: t for t in after["visible_terminals"]}
    for pane, b in bv.items():
        a = av.get(pane)
        if a is None:
            out.append(f"visible terminal {pane[-8:]} not visible after")
            continue
        if b["focused"] != a["focused"]:
            out.append(f"focus of {pane[-8:]} {b['focused']} -> {a['focused']}")
        bg, ag = b.get("grid") or {}, a.get("grid") or {}
        for key in ("frame_x", "frame_y", "frame_width", "frame_height", "cell_width", "cell_height"):
            if bg.get(key) != ag.get(key):
                out.append(f"pane {pane[-8:]} {key} {bg.get(key)} -> {ag.get(key)}")
        if b.get("live") or a.get("live"):
            # A live program (its screen changes by itself): screen and scrollback not compared; listed.
            out.append(f"NOT COMPARED pane {pane[-8:]}: a live program (its screen changed between two reads)")
            continue
        if _screen_lines(before["screens"].get(pane)) != _screen_lines(after["screens"].get(pane)):
            out.append(f"pane {pane[-8:]} screen text differs")
        bh, ah = before["history"].get(pane) or {}, after["history"].get(pane) or {}
        if bh.get("error") or ah.get("error") or not bh or not ah:
            out.append(f"pane {pane[-8:]} scrollback unreadable (before: {str(bh.get('error'))[:80]}, after: {str(ah.get('error'))[:80]})")
        elif bh.get("total") != ah.get("total") or bh.get("tail") != ah.get("tail"):
            out.append(f"pane {pane[-8:]} scrollback {bh.get('total')} rows -> {ah.get('total')} rows"
                       + (" (tail differs)" if bh.get("tail") != ah.get("tail") else ""))
    for pane in av:
        if pane not in bv:
            out.append(f"terminal {pane[-8:]} visible after, not before")
    return out


# ---- geometry: the panes and the marker cells on screen --------------------------------------------------------

def pane_rects(state):
    """Each visible terminal's rect in screen points: its window's frame on the window server plus the grid's
    top-left offset in the window (debug.surfaces `grid`: window points from the top-left)."""
    frames = {}
    # debug.windows ids and the window server's numbers are matched by order of the app's on-screen windows
    # (front to back) when there is one window; with several, by the frame that holds the pane.
    server = state["server_windows"]
    rects = {}
    for t in state["visible_terminals"]:
        g = t.get("grid") or {}
        if not g or not server:
            continue
        host = max(server, key=lambda w: w["w"] * w["h"])
        for w in server:
            if g.get("frame_x", 0) + g.get("frame_width", 0) <= w["w"] + 1 and g.get("frame_y", 0) + g.get("frame_height", 0) <= w["h"] + 1:
                host = w
                break
        frames[t["pane"]] = host
        rects[t["pane"]] = {"x": host["x"] + g["frame_x"], "y": host["y"] + g["frame_y"], "w": g["frame_width"],
                            "h": g["frame_height"], "cell_w": g.get("cell_width"), "cell_h": g.get("cell_height"),
                            "origin_x": host["x"] + g.get("origin_x", g["frame_x"]),
                            "origin_y": host["y"] + g.get("origin_y", g["frame_y"])}
    return rects


def cursor_cell(text, rect):
    """The cell the next typed character lands in, in screen points: after the prompt on the last line with text
    (the journeys' shells sit at the neutral prompt). debug.surfaces gives logical lines; a line longer than the
    pane's columns takes more rows, as the terminal wraps it."""
    lines = (text or "").split("\n")
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines or not rect.get("cell_w"):
        return None
    pad = max(0.0, rect.get("origin_x", rect["x"]) - rect["x"])
    cols = max(1, int((rect["w"] - 2 * pad) // rect["cell_w"]))
    rows = [max(1, -(-len(line.rstrip("\n")) // cols)) for line in lines]
    last = lines[-1]
    col = len(last.rstrip()) + (1 if last.endswith(" ") else 0)
    row = sum(rows[:-1]) + col // cols
    col = col % cols
    return {"row": row, "col": col, "cols": cols, "x": rect["origin_x"] + col * rect["cell_w"],
            "y": rect["origin_y"] + row * rect["cell_h"], "w": rect["cell_w"], "h": rect["cell_h"]}


# ---- one cycle -------------------------------------------------------------------------------------------------

def _end(j, cua, how, record):
    """Ends the app of kind HOW; returns the monotonic time the old process was gone."""
    app, old = j.app, j.app.pid
    record["end_wall"] = time.time()
    started = D.now()
    if how == "quit-keep-hid":
        windows = _windows_of(cua, old)
        if not windows:
            raise D.StepError("quit-keep-hid: CuaDriver lists no on-screen window of the app")
        cua.tool("hotkey", {"pid": old, "window_id": _wid(windows[0]), "keys": ["cmd", "q"], "delivery_mode": "foreground"})
        record["key_sent_wall"] = time.time()
        end = D.now() + 10
        while D.now() < end and app.alive(old):
            try:
                report = app.rpc("debug.quit", timeout=3) or {}
            except (D.StepError, OSError, ValueError):
                break
            if isinstance(report, dict) and report.get("asking"):
                default = str((report.get("prompt") or {}).get("default") or "keep")
                record["dialog"] = {"default": default, "buttons": [b.get("id") for b in report.get("buttons") or []]}
                app.rpc("debug.quit", {"press": default}, timeout=5)
                break
            time.sleep(0.05)
    elif how == "kill-app":
        os.kill(old, signal.SIGKILL)
    elif how == "kill-daemons":
        others = [r["pid"] for r in app.bundle_processes(old) if r["pid"] != old]
        record["killed_background"] = len(others)
        os.kill(old, signal.SIGKILL)
        for pid in others:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    elif how == "logout":
        sent, status = send_logout_quit(old)
        record["logout_send"] = {"result": sent, "status": status}
        if sent != "sent":
            raise D.NotRun(f"logout: the quit Apple event was not sent: {sent}")
    else:
        raise D.StepError(f"reopen_video: how is quit-keep-hid, kill-app, kill-daemons or logout, not {how!r}")
    gone = D.wait_exit(old, D.QUIT_SECONDS)
    if gone is None:
        while D.now() < started + D.QUIT_SECONDS and app.alive(old):
            time.sleep(0.02)
        if app.alive(old):
            raise D.StepError(f"{how}: app pid {old} still runs {D.QUIT_SECONDS} s later")
        gone = D.now()
    record["gone_wall"] = time.time() - (D.now() - gone)
    record["end_to_gone_ms"] = round((gone - started) * 1000, 1)
    if how == "kill-daemons":
        # The background processes too (a reopen must find nothing of cmux running).
        for pid in [r["pid"] for r in app.bundle_processes(None)]:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        time.sleep(0.3)
        record["background_left"] = len(app.bundle_processes(None))


def _reopen(j, record, env):
    """`open -a` the same bundle, active (a Dock click brings it to the front the same way); the new pid from the
    kernel's process list, its start, and when it became the front app. No socket read."""
    app, old = j.app, j.app.pid
    import plistlib
    with open(os.path.join(app.bundle, "Contents", "Info.plist"), "rb") as f:
        executable = os.path.join(app.bundle, "Contents", "MacOS", plistlib.load(f)["CFBundleExecutable"])
    argv = ["/usr/bin/open", "-n", "-a", app.bundle]
    for key, value in env.items():
        argv += ["--env", f"{key}={value}"]
    record["open_wall"] = time.time()
    opened = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    record["open_returned_wall"] = time.time()
    if opened.returncode != 0:
        raise D.StepError(f"reopen: open exited {opened.returncode}: {(opened.stderr or opened.stdout)[-300:]}")
    pid = find_new_app(os.path.realpath(executable), old, 30) if executable else None
    if not pid:
        raise D.StepError("reopen: no new app process within 30 s")
    record["new_pid"] = pid
    record["process_start_wall"] = process_start(pid)
    end = time.monotonic() + FRONT_TIMEOUT
    prev = record["open_wall"]
    while time.monotonic() < end:
        now_wall = time.time()
        front = front_pid()
        if front == pid:
            # The switch happened after the last poll that did not see it began, and before this poll ended.
            record["front_prev_wall"], record["front_wall"], record["front_done_wall"] = prev, now_wall, time.time()
            break
        prev = now_wall
        time.sleep(0.02)
    else:
        record["front_wall"] = None
    return pid


def _type_markers(j, cua, keys, pid, before, rects, record):
    """A real HID marker key into the focused terminal as soon as the reopened app has a window, then a click and
    the key into each other visible terminal, each with its wall time and the cell it should echo in."""
    marks = []
    if not record.get("front_wall"):
        # Desktop-scope keys go to the front app: never type when the reopened app did not come to the front.
        record["markers_error"] = "the reopened app never became the front app: no key typed"
        return marks
    end = time.monotonic() + FRONT_TIMEOUT
    windows = []
    while time.monotonic() < end and not windows:
        windows = _windows_of(cua, pid)
        if not windows:
            time.sleep(0.01)
    if not windows:
        record["markers_error"] = "the reopened app showed no window"
        return marks
    record["window_listed_wall"] = time.time()
    wid = _wid(windows[0])
    terms = [t for t in before["visible_terminals"] if not t.get("live")]  # never a key into a running TUI
    order = [t for t in terms if t["focused"]] + [t for t in terms if not t["focused"]]
    for index, t in enumerate(order):
        rect = rects.get(t["pane"])
        if not rect:
            continue
        cell = cursor_cell(before["screens"].get(t["pane"]), rect)
        mark = {"pane": t["pane"], "focused_before": t["focused"], "cell": cell}
        if index > 0:
            # A click in the pane's lower half, on its text area, at its screen point (the window restores in place:
            # any move is an exactness defect of its own). No window lookup: it would delay the click by an
            # osascript call while the app launches.
            sx, sy = rect["x"] + rect["w"] / 2, rect["y"] + rect["h"] * 0.6
            mark["click_sent_wall"] = time.time()
            if record.get("can_post_events"):
                post_click(sx, sy)
                mark["click_path"] = "CGEventPost HID"
            else:
                scale = float((record.get("screen") or {}).get("scale") or 1)
                keys.tool("click", {"scope": "desktop", "x": sx * scale, "y": sy * scale}, check=False)
                mark["click_path"] = "cua click, desktop scope (second session, no recording)"
            mark["click_done_wall"] = time.time()
        if record.get("can_post_events"):
            mark["key_sent_wall"], mark["key_done_wall"] = post_key()
            mark["key_path"] = "CGEventPost HID"
        else:
            mark["key_sent_wall"] = time.time()
            keys.tool("press_key", {"scope": "desktop", "key": MARKER_KEY}, check=False)
            mark["key_done_wall"] = time.time()
            mark["key_path"] = "cua press_key, desktop scope (second session, no recording)"
        marks.append(mark)
    return marks


def _clean_markers(j, before, marks):
    """Removes the marker characters (Ctrl-U to each shell through the daemon) and gives focus back to the pane
    that had it, so the next cycle starts from the same state; returns the errors (recorded, never hidden)."""
    errors = []
    marked = {m["pane"] for m in marks}
    for t in before["visible_terminals"]:
        if t["pane"] not in marked:
            continue  # only the panes that got a marker key (never a key into a running TUI)
        if not t.get("terminal"):
            errors.append(f"pane {t['pane'][-8:]}: no daemon terminal to clean")
            continue
        try:
            j.app.cmux("terminal", t["terminal"], "write", "--text", "\u0015")
        except D.StepError as error:
            errors.append(f"pane {t['pane'][-8:]}: {str(error)[-160:]}")
    focused = next((t for t in before["visible_terminals"] if t["focused"]), None)
    if focused:
        try:
            j.app.cmux("pane", focused["pane"], "focus")
        except D.StepError as error:
            errors.append(f"focus {focused['pane'][-8:]}: {str(error)[-160:]}")
    time.sleep(0.4)
    return errors


def _settle(j, timeout=20):
    """After the film: until the reopened app answers and every visible terminal is live."""
    end = D.now() + timeout
    info = None
    while D.now() < end:
        try:
            info = j.app.rpc("system.identify", timeout=3)
            if isinstance(info, dict) and info.get("pid"):
                break
        except (D.StepError, OSError, ValueError):
            pass
        time.sleep(0.1)
    if not info:
        raise D.StepError("reopen: the app never answered on its socket")
    j.app.reidentify(info)
    while D.now() < end:
        try:
            shown = [p for p in j.app.panes() if p.get("kind") == "terminal" and p.get("presence") == "visible"]
            if shown and all(p.get("attach") == "live" for p in shown):
                return True
        except (D.StepError, OSError, ValueError):
            pass
        time.sleep(0.2)
    return False


def step_reopen_video(j, step):
    if not D.ACTIVATE:
        raise D.NotRun("reopen_video needs a whole-host lease (run.py --whole-host): a key window and CuaDriver's grants")
    how = step.get("how", "quit-keep-hid")
    count = int(step.get("count", 5))
    screen = _jxa_json(SCREEN_JXA, {})
    rows = []
    for index in range(1, count + 1):
        record = {"cycle": index, "how": how, "screen": screen, "old_pid": j.app.pid, "can_post_events": can_post_events()}
        env = j.app.launch_env()
        before = exact_state(j)
        record["before"] = before
        rects = pane_rects(before)
        record["pane_rects"] = rects
        movie_dir = Path(j.out) / f"rec-{index}"
        shutil.rmtree(movie_dir, ignore_errors=True)
        movie_dir.mkdir(parents=True, exist_ok=True)
        cua = Cua()
        keys = Cua()  # a second session for the marker keys and clicks: no recording, no per-action screenshots
        try:
            # The pointer away from the sync points before the film starts.
            away = (float(screen.get("w") or 1920) * 0.36, 11)
            use_warp = warp(*away)
            record["sync_method"] = "CGWarpMouseCursorPosition" if use_warp else "cua move_cursor"
            px = float(screen.get("scale") or 1)
            if not use_warp:
                cua.tool("move_cursor", {"x": away[0] * px, "y": away[1] * px, "scope": "desktop"}, check=False)
            cua.tool("start_recording", {"output_dir": str(movie_dir), "record_video": True})
            record["record_started_wall"] = time.time()
            time.sleep(LEAD_SECONDS)
            # The film's clock: the real pointer jumps to four new points on the menu bar (never visited before in
            # this film, so each point's first change on film is the arrival) at known wall times.
            sync = []
            w = float(screen.get("w") or 1920)
            for x in (w * 0.42, w * 0.47, w * 0.52, w * 0.57):
                before_move = time.time()
                if use_warp:
                    warp(x, 11)
                else:
                    cua.tool("move_cursor", {"x": x * px, "y": 11 * px, "scope": "desktop"}, check=False)
                sync.append({"x": x, "y": 11, "sent_wall": before_move, "done_wall": time.time()})
                time.sleep(0.25)
            record["sync"] = sync
            time.sleep(0.3)
            _end(j, cua, how, record)
            pid = _reopen(j, record, env)
            marks = _type_markers(j, cua, keys, pid, before, rects, record) if step.get("type_keys", True) else []
            record["markers"] = marks
            time.sleep(TAIL_SECONDS)
            cua.tool("stop_recording", {}, check=False, timeout=60)
            record["record_stopped_wall"] = time.time()
        finally:
            keys.close()
            cua.close()
        settled = _settle(j)
        record["settled"] = settled
        record["pid_matches"] = record.get("new_pid") == j.app.pid
        try:
            # The app's own input journal (what reached it and when, in its own clock): the marker keys' arrival.
            record["journal"] = (j.app.rpc("debug.journal", {"last": 60}, timeout=10) or {}).get("entries")
        except (D.StepError, OSError, ValueError) as error:
            record["journal"] = {"error": str(error)[-200:]}
        try:
            timings = j.app.rpc("debug.timings", timeout=10) or {}
        except (D.StepError, OSError, ValueError):
            timings = {}
        marks_ms = timings.get("launch_ms_since_process_start") or {}
        record["app_marks_ms"] = {k: marks_ms.get(k) for k in (
            "main_start", "first_window_frame_committed", "terminal.launch_frame_shown", "first_terminal_frame",
            "launch.visible_terminals_drawn", "sidebar_rows_shown") if k in marks_ms}
        record["launch_terminals"] = timings.get("launch_terminals")
        main = marks_ms.get("main_start")
        if record.get("process_start_wall") and isinstance(main, (int, float)):
            record["main_wall"] = record["process_start_wall"] + main / 1000.0
        time.sleep(0.5)
        after = exact_state(j)
        record["after"] = after
        record["after_pane_rects"] = pane_rects(after)
        # Where each marker key went: the screens after hold one more "x" after the prompt per key received.
        trailing = lambda line: len(line.rstrip()) - len(line.rstrip().rstrip(MARKER_KEY))
        for mark in record.get("markers") or []:
            b = (before["screens"].get(mark["pane"]) or "").rstrip("\n").split("\n")[-1]
            a = (after["screens"].get(mark["pane"]) or "").rstrip("\n").split("\n")[-1]
            mark["received"] = trailing(a) - trailing(b)
        # The marker keys are in the screens after; judged by the video. Exactness compares the state without them.
        record["clean_errors"] = _clean_markers(j, before, record.get("markers") or [])
        cleaned = exact_state(j)
        record["differences"] = state_differences(before, cleaned)
        record["cleaned"] = cleaned
        movie = next(iter(sorted(movie_dir.glob("*.mp4"))), None)
        if movie:
            shutil.move(str(movie), str(Path(j.out) / f"reopen-{index}.mp4"))
            record["movie"] = f"reopen-{index}.mp4"
        else:
            record["movie"] = None
            record["movie_dir"] = sorted(p.name for p in movie_dir.iterdir())[:20]
        shutil.rmtree(movie_dir, ignore_errors=True)
        (Path(j.out) / f"reopen-{index}.json").write_text(json.dumps(record, indent=1, default=str) + "\n")
        rows.append({"cycle": index, "movie": record["movie"], "differences": record["differences"],
                     "settled": settled, "app_marks_ms": record["app_marks_ms"],
                     "end_to_gone_ms": record.get("end_to_gone_ms")})
    return {"how": how, "cycles": rows, "screen": screen}


def step_heavy_profile(j, step):
    """Set-up, not under test: the HEAVY profile (owner 3's tui-kit heavy_profile.py build: WORKSPACES workspaces,
    TABS tabs, one shown workspace with VISIBLE TUI panes in columns and rows, a browser and an agent pane) on this
    app, through its socket and bundled CLI; its manifest is kept for the teardown (a `finally` step
    heavy_teardown). The marker keys and the content judge read the panes that run a shell; TUI panes are judged
    for content (no blank), not for an echo."""
    kit = Path(__file__).resolve().parent / "tui-kit" / "heavy_profile.py"
    out = Path(j.out) / "heavy"
    argv = ["/usr/bin/python3", str(kit), "build", "--seed", str(step.get("seed", 7)),
            "--workspaces", str(step.get("workspaces", 40)), "--tabs", str(step.get("tabs", 200)),
            "--visible", str(step.get("visible", 12)), "--duration", str(step.get("duration", 900)),
            "--app-socket", j.app.sock, "--home", j.app.home, "--cli", j.app.cli, "--out", str(out)]
    j.heavy_manifest = out / "heavy.json"
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=float(step.get("timeout", 180)))
    except subprocess.TimeoutExpired:
        raise D.StepError(f"heavy_profile build ran past {step.get('timeout', 180)} s")
    try:
        manifest = json.loads(j.heavy_manifest.read_text())
    except (OSError, ValueError):
        manifest = {}
    if done.returncode != 0 or not (manifest.get("check") or {}).get("ok", done.returncode == 0):
        # A profile not fully built (heavy_profile exit 1: fewer items than planned) gives no HEAVY number.
        raise D.NotRun(f"set-up: the HEAVY profile was not fully built (exit {done.returncode}, check "
                       f"{json.dumps(manifest.get('check'))[:300]}): {(done.stderr or done.stdout)[-300:]}")
    return {"exit": done.returncode, "check": manifest.get("check"), "refusals": len(manifest.get("refusals") or []),
            "tail": (done.stdout or "")[-300:]}


def step_heavy_teardown(j, step):
    manifest = getattr(j, "heavy_manifest", None)
    if not manifest or not Path(manifest).exists():
        return {"skipped": "no heavy profile"}
    kit = Path(__file__).resolve().parent / "tui-kit" / "heavy_profile.py"
    done = subprocess.run(["/usr/bin/python3", str(kit), "teardown", "--manifest", str(manifest), "--app-socket", j.app.sock,
                           "--home", j.app.home, "--cli", j.app.cli], capture_output=True, text=True, timeout=180)
    return {"exit": done.returncode, "tail": (done.stdout or done.stderr or "")[-300:]}


def _signal(pid, sig):
    try:
        os.kill(pid, sig)
    except OSError:
        pass


def step_kill_all_relaunch(j, step):
    """REOPEN-F3 (P0 data loss, cmux-ad 01:30Z): everything of cmux dies AT ONCE, as in a crash of the Mac or a
    force quit of all: every process of the app's bundle (terminal hosts, holder, daemon) and the app are first
    stopped (SIGSTOP: nobody can react, mark a terminal ended or save), then killed (SIGKILL). Between the end and
    the reopen, anything of the bundle still running is killed and listed; the step fails if any survives. Then
    the driver's reopen through LaunchServices finds every named terminal again. No film."""
    app = j.app
    daemon = app.daemon_pid()  # asked before the app is stopped
    rows = app.bundle_processes(app.pid)
    pids = [r["pid"] for r in rows if r["pid"] != app.pid] + ([daemon] if daemon else [])
    for pid in pids + [app.pid]:
        _signal(pid, signal.SIGSTOP)
    for pid in pids:
        _signal(pid, signal.SIGKILL)

    def leftovers():
        for row in app.bundle_processes(None):
            _signal(row["pid"], signal.SIGKILL)
        time.sleep(0.3)
        return [r["command"][:100] for r in app.bundle_processes(None)]

    record = D.Journey.step_relaunch(j, dict(step, how="kill-app", after_end=leftovers))
    record["killed"] = [{"pid": r["pid"], "command": r["command"][:100]} for r in rows] + [{"pid": daemon, "command": "daemon"}]
    if record.get("after_end"):
        raise D.StepError(f"bundle processes still ran at the reopen: {record['after_end'][:5]}")
    return record


def cond_cwd_string(j, want, cache):
    """The current terminal's shell prints its working directory with `pwd` as exactly WANT (the same path string a
    person had: /tmp stays /tmp, not /private/tmp). Reads the daemon's screen for the line after `pwd`'s echo."""
    wanted = j.sub(want["path"] if isinstance(want, dict) else want)
    text = j.app.screen(j.need_term())["text"]
    lines = [line.strip() for line in text.splitlines()]
    after = [lines[i + 1] for i, line in enumerate(lines[:-1]) if line.endswith("pwd")]
    got = after[-1] if after else None
    detail = {"pwd_printed": got, "want": wanted}
    if got != wanted and not after:
        detail["why"] = "no line ending in 'pwd' on the screen (a right prompt in the shell's config would hide it)"
    return got == wanted, detail


def cond_ended_line_after(j, want, cache):
    """The current terminal's screen shows the last content (a line with PREFIX + LAST), and AFTER it a line that
    says the session ended (any of WORDS, default "ended"), then a prompt: the restored last screen is not replaced."""
    prefix, last = j.sub(want["prefix"]), int(want["last"])
    words = want.get("words", ["ended"])
    lines = [line.rstrip() for line in j.app.screen(j.need_term())["text"].splitlines()]
    marker = f"{prefix}{last}"
    at = max([i for i, line in enumerate(lines) if line.strip() == marker] or [-1])
    ended = [i for i, line in enumerate(lines) if i > at >= 0 and any(w in line.lower() for w in words)]
    detail = {"last_content_row": at, "ended_rows": ended[:3], "screen_tail": [l for l in lines if l.strip()][-4:]}
    if at < 0:
        return False, dict(detail, why=f"the last content line {marker!r} is not on the screen (the last screen was not restored)")
    if not ended:
        return False, dict(detail, why="no 'session ended' line after the restored last content")
    return True, detail


STEPS = {"reopen_video": step_reopen_video, "kill_all_relaunch": step_kill_all_relaunch, "heavy_profile": step_heavy_profile, "heavy_teardown": step_heavy_teardown}
CONDITIONS = {"cwd_string": ("daemon", cond_cwd_string), "ended_line_after": ("daemon", cond_ended_line_after)}
