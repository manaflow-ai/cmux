#!/usr/bin/env python3
"""Live miss count for Toggle Browser Focus Mode (Cmd-Opt-Return) in every focus it can start from
(Lawrence 2026-11-16: "cmd option enter / browser focus mode sometimes doesn't work").

The script attaches to a tagged DEBUG app through its debug socket (it never launches or quits
it), opens a local test page in a Chromium browser tab, and for each state below puts the
keyboard there, presses Cmd-Opt-Return, and reads the window's focus model (`debug.focus`
`browser_focus_mode`) for the toggle. A press that leaves the tab's focus mode unchanged within
`--settle` seconds is a miss. Each state is tried `--rounds` times; each try presses twice (on,
then off), so a state's count is 2 x rounds presses.

States:
  page        the page's own content has the keyboard (a click into the page)
  pageinput   a text field in the page has the keyboard
  omnibar     the address bar is editing (Cmd-L)
  findbar     the find bar has the keyboard (Cmd-F)
  devtools    DevTools is open beside the page and has the keyboard
  navigated   the press comes right after the page navigated (the press ~30 ms after)
  newtab      the press comes right after a new browser tab opened in the pane
  tabswitch   the press comes right after switching to the browser tab from a terminal tab
  split       the press comes right after splitting the pane (focus back on the page)
  terminal    a terminal beside the page has the keyboard: expected to do nothing (no page)

Input (`--input`):
  real      cua-driver clicks and a foreground hotkey (the app frontmost on a GUI host);
  sequence  `debug.key` `sequence`: CGEvents posted to the app's event queue, the path a
            hardware key takes from `nextEvent` on (no click: page focus comes from Escape).

Run on cmux-lawrence-2 (GUI host), never the laptop.
Usage: browser-focus-mode-toggle-live.py --socket /tmp/cmux-debug-<tag>.sock [--input real]
       [--states page,omnibar,...] [--rounds 20] [--out DIR]
Exit status 0 when no press missed.
"""
import argparse, http.server, json, os, socket, subprocess, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--input", choices=["real", "sequence"], default="sequence")
parser.add_argument("--states", default="page,pageinput,omnibar,findbar,devtools,navigated,newtab,tabswitch,split,terminal")
parser.add_argument("--rounds", type=int, default=20)
parser.add_argument("--settle", type=float, default=1.5)
parser.add_argument("--out", default="/tmp")
parser.add_argument("--key-window", choices=["page", "shell"],
                    help="sequence input: make this window key first (`page`: the Chromium page window, as a press "
                         "in a focused page; the keys then reach Chromium's own window as a person's do)")
parser.add_argument("--url", help="a real site to test instead of the local page (linear.app, github.com); "
                    "`navigated` then reloads the page before the press")
opts = parser.parse_args()
APP_PID = int(os.environ.get("APP_PID", "0"))
CUA = os.path.expanduser("~/.local/bin/cua-driver")
ROWS = []


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
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


def wait(check, seconds, step=0.05):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def run(action, args=None):
    return rpc("action.run", {"action": action, "args": args or {}, "focus": True})


def window():
    windows = (rpc("debug.focus") or {}).get("windows") or []
    key = [w for w in windows if w.get("is_key")]
    return (key or windows or [{}])[0]


def model():
    return window().get("model") or {}


def focus_mode_tabs():
    return set(model().get("browser_focus_mode") or [])


def resolved():
    m = model()
    return m.get("resolved"), m.get("resolved_tab"), m.get("resolved_pane")


def cua(tool, payload):
    done = subprocess.run([CUA, "call", tool, json.dumps(payload)], capture_output=True, text=True, timeout=30)
    return (done.stdout or done.stderr).strip()


WINDOW_ID = []


def main_window_id():
    if not WINDOW_ID:
        listed = json.loads(cua("list_windows", {"pid": APP_PID}) or "{}")
        windows = [w for w in (listed.get("windows") if isinstance(listed, dict) else listed) or []
                   if w.get("pid") == APP_PID and w.get("is_on_screen")]
        windows.sort(key=lambda w: -((w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)))
        WINDOW_ID.append(windows[0]["window_id"] if windows else None)
    return WINDOW_ID[0]


# ANSI key codes: 55 left command, 58 left option, 36 return, 53 escape, 45 n.
def chord_steps(after=0):
    return [{"key_code": 55, "down": True, "after_ms": after}, {"key_code": 58, "down": True, "after_ms": 5},
            {"key_code": 36, "down": True, "after_ms": 5}, {"key_code": 36, "down": False, "after_ms": 40},
            {"key_code": 58, "down": False, "after_ms": 5}, {"key_code": 55, "down": False, "after_ms": 5}]


def play(steps):
    params = {"sequence": steps}
    if opts.key_window and resolved()[0] in ("browserPage",):
        params["key_window"] = opts.key_window
    reply = rpc("debug.key", params) or {}
    if reply.get("error"):
        print("debug.key:", reply.get("error"), flush=True)
    # sleep-ok: the app posts the sequence on its own timer over the duration_ms it reports and sends no done event;
    # each caller then waits on the sequence's effect (toggled, resolved).
    time.sleep(((reply.get("duration_ms") or 0) + 30) / 1000)
    return reply


def press_chord(prefix=None):
    """Cmd-Opt-Return, after `prefix` key steps (sequence) when given."""
    if opts.input == "sequence" or prefix:
        return play((prefix or []) + chord_steps(after=30 if prefix else 0))
    return cua("hotkey", {"pid": APP_PID, "window_id": main_window_id(), "keys": ["cmd", "option", "return"],
                          "delivery_mode": "foreground"})


def click_page():
    """A click into the page's body (real), else Escape from the address bar back to the page."""
    if opts.input == "real":
        state = json.loads(cua("get_window_state", {"pid": APP_PID, "window_id": main_window_id(), "include_image": False}) or "{}")
        size = state.get("window_size") or state.get("size") or {}
        width, height = size.get("width", 1200), size.get("height", 800)
        return cua("click", {"pid": APP_PID, "window_id": main_window_id(), "x": int(width * 0.7), "y": int(height * 0.75)})
    run("focusBrowserAddressBar")
    wait(lambda: resolved()[0] == "addressBar" or None, 2)
    return play([{"key_code": 53, "down": True}, {"key_code": 53, "down": False, "after_ms": 30}])


# The test page: a body to click, a field, and `n` navigates (the press right after a navigation).
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write((
            "<!doctype html><title>focus mode</title><body style='height:100vh;margin:0'>"
            "<p>focus mode test %s</p><input id=f style='width:300px'>"
            "<script>addEventListener('keydown',e=>{if(e.key==='n'&&!e.metaKey&&document.activeElement.id!=='f')"
            "location='/p?'+Date.now()})</script></body>" % self.path).encode())

    def log_message(self, *args):
        pass


def page_eval(script):
    """The focused page's answer to `script` (browser.page.eval), or None."""
    tab = browser_tab()
    reply = rpc("browser.page.eval", {"tab": tab, "script": script}, timeout=10) if tab else None
    return reply.get("value") if isinstance(reply, dict) and not reply.get("error") else None


def browser_tab():
    kind, tab, pane = resolved()
    return tab if kind in ("browserPage", "addressBar", "findBar", "devTools") else None


def page_tab_in_pane():
    """The selected browser tab of the focused pane (also while a terminal beside it has focus)."""
    w = window()
    for pane in w.get("topology") or []:
        for tab in pane.get("tabs") or []:
            tab_id, _, kind = tab.rpartition(":")
            if kind == "browser" and pane.get("selected") == tab_id:
                return tab_id
    return None


def toggled(tab, was_on):
    return wait(lambda: ((tab in focus_mode_tabs()) != was_on) or None, opts.settle)


def record(state, attempt, tab, was_on, ok, note=""):
    kind, rtab, _ = resolved()
    ROWS.append({"state": state, "attempt": attempt, "tab": tab, "was_on": was_on, "ok": bool(ok),
                 "resolved": kind, "note": note})
    if not ok:
        print(f"MISS {state} #{attempt} was_on={was_on} resolved={kind}/{rtab} {note}", flush=True)


def exit_all():
    """Leaves focus mode everywhere (the next state starts from off)."""
    for tab in list(focus_mode_tabs()):
        rpc("action.run", {"action": "toggleBrowserFocusMode", "target": {"kind": "tab", "id": tab}, "focus": True})
    wait(lambda: not focus_mode_tabs() or None, 2)


def setup_state(state, url):
    """Puts the keyboard in `state`; returns (tab, prefix key steps or None, note)."""
    if state in ("page", "pageinput", "navigated"):
        click_page()
        wait(lambda: resolved()[0] == "browserPage" or None, 2)
        if state == "pageinput":
            play([{"key_code": 48, "down": True}, {"key_code": 48, "down": False, "after_ms": 20}])  # Tab into the field
            wait(lambda: page_eval("document.activeElement && document.activeElement.id") == "f" or None, 2)  # the field has focus
        if state == "navigated":
            if opts.url:
                run("browserReload")  # a real site: the press right after a reload starts
                # sleep-ok: the scenario is a press about 50 ms into the reload of a real site (a person's timing)
                time.sleep(0.05)
                return browser_tab(), None, "after reload"
            return browser_tab(), [{"key_code": 45, "down": True}, {"key_code": 45, "down": False, "after_ms": 20}], ""
        return browser_tab(), None, ""
    if state == "omnibar":
        click_page()
        run("focusBrowserAddressBar")
        wait(lambda: resolved()[0] == "addressBar" or None, 2)
        return browser_tab(), None, ""
    if state == "findbar":
        click_page()
        run("find")
        wait(lambda: resolved()[0] == "findBar" or None, 2)
        return browser_tab(), None, ""
    if state == "devtools":
        click_page()
        run("toggleBrowserDeveloperTools")
        wait(lambda: resolved()[0] == "devTools" or None, 4)
        return browser_tab(), None, ""
    if state == "terminal":
        return page_tab_in_pane(), None, "expected no toggle"
    return None, None, ""


def try_transition(state, url, attempt):
    """newtab / tabswitch / split: the change, then the press at once; returns (tab, note)."""
    if state == "newtab":
        run("openBrowser", {"url": url if opts.url else url + "nt%d" % attempt})
        # The press goes as soon as the model names the new tab, as a person's would.
        wait(lambda: resolved()[0] == "browserPage" and resolved()[1] != STATE["tab"] or None, 5)
        STATE["tab"] = browser_tab()
        return STATE["tab"], ""
    if state == "tabswitch":
        run("prevSurface")  # to the terminal tab
        wait(lambda: resolved()[0] == "terminal" or None, 3)
        run("nextSurface")  # back to the page: the press right after
        wait(lambda: resolved()[0] == "browserPage" or None, 3)
        return browser_tab(), ""
    if state == "split":
        run("splitRight")
        wait(lambda: resolved()[0] == "terminal" or None, 3)
        run("focusLeft")
        wait(lambda: resolved()[0] == "browserPage" or None, 3)
        return browser_tab(), ""
    return None, ""


STATE = {"tab": None}


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = opts.url or f"http://127.0.0.1:{server.server_address[1]}/"
    if opts.input == "real":
        cua("bring_to_front", {"pid": APP_PID})
    print("newBrowserWorkspace", run("newBrowserWorkspace"), flush=True)
    wait(lambda: browser_tab() or None, 15)
    print("openBrowser", run("openBrowser", {"url": url}), flush=True)
    wait(lambda: browser_tab() or None, 15)
    # Until the page loaded: it reports readyState complete.
    if not wait(lambda: page_eval("document.readyState") == "complete" or None, 20 if opts.url else 10, 0.1):
        print("note: the page did not report readyState complete", flush=True)
    STATE["tab"] = browser_tab()
    print("page tab", STATE["tab"], resolved(), flush=True)

    totals = {}
    for state in opts.states.split(","):
        exit_all()
        if state == "tabswitch":
            run("newSurface")  # a terminal tab in the page's pane, then back to the page
            time.sleep(1)  # test harness: the terminal starts
            run("nextSurface")
        if state == "terminal":
            run("splitRight")
            wait(lambda: resolved()[0] == "terminal" or None, 3)
        misses = 0
        for attempt in range(opts.rounds):
            for was_on in (False, True):
                if state in ("newtab", "tabswitch", "split"):
                    if was_on:
                        # Off again from a settled page (the transition was the "on" press's).
                        tab = browser_tab()
                        prefix, note = None, ""
                    else:
                        tab, note = try_transition(state, url, attempt)
                        prefix = None
                else:
                    tab, prefix, note = setup_state(state, url)
                if not tab:
                    record(state, attempt, tab, was_on, False, "no page tab: " + str(resolved()))
                    misses += 1
                    continue
                actual_on = tab in focus_mode_tabs()
                press_chord(prefix)
                if state == "terminal":
                    ok = not toggled(tab, actual_on)  # a terminal's key: no page toggles
                else:
                    ok = toggled(tab, actual_on)
                record(state, attempt, tab, actual_on, ok, note)
                misses += 0 if ok else 1
                if state == "devtools":
                    run("toggleBrowserDeveloperTools")  # closed again; the next try reopens it
                    time.sleep(0.3)  # test harness: DevTools closes
            if state == "split":
                exit_all()
                # Close the split's terminal pane: back to one pane for the next try.
                run("focusRight")
                if resolved()[0] == "terminal":
                    run("closePane")
                wait(lambda: len(window().get("topology") or []) == 1 or None, 3)
                click_page()
        presses = 2 * opts.rounds
        totals[state] = (misses, presses)
        print(f"STATE {state}: {misses}/{presses} missed", flush=True)
        if state in ("tabswitch",):
            run("prevSurface")
            run("closeTab")
        if state == "terminal":
            run("closePane")
            run("focusLeft")
    path = os.path.join(opts.out, "browser-focus-mode-toggle.json")
    with open(path, "w") as handle:
        json.dump({"totals": totals, "rows": ROWS}, handle)
    missed = sum(m for m, _ in totals.values())
    print(f"RESULT missed {missed}/{sum(p for _, p in totals.values())} ({opts.input}) -> {path}", flush=True)
    return 0 if missed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
