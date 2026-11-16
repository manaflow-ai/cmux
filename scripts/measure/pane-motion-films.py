#!/usr/bin/env python3
"""Films of pane motions: one movie for each act, for a person to look at. This script judges no film.

Launches a tagged bench `cmux DEV <tag>.app` with the repository's bench launcher (bench_launch.py `BenchApp`), makes
a session with the repository's one session maker (scripts/perf-bench/session_real.py make), and then, for each film
id of --films: a new workspace with the film's panes, the app's own recorder (`debug.motion` record_start: a movie of
the display from the window's top left, written off the main thread), the film's keys, record_stop, and the close of
what the film made. Out: <out>/<id>.mov, <out>/<id>.mov.frames.json (the display time of each frame) and
<out>/films.json (one row for each film: `made`, or `not_run` with the reason).

The sources of the acts, and their limits (each row says which it used):
  keys     `debug.key`: real key events on the app's own queue; not the HID tap, not the window server. A held key
           is one key-down and its repeats (the first after --repeat-delay-ms, then one each --repeat-ms). The keys
           have 2 forms (--launch-form): `activate` = the app is launched as a person's app (it takes the keyboard)
           and each act's keys are one sequence in the key window, played by the app's clock; `one-key` = the
           launcher's usual launch (the app never takes the keyboard) and each key-down is one call at its time by
           this script's clock, into a window that is not key; that form has no repeat flag, so a film with a held
           key is `not_run` in it. `auto` (the default) = `activate`, and if its preflight fails, one new launch as
           `one-key`. Each launch and each film's row say the form. In the `activate` form the key window of each
           sequence follows the focus (`focus_word`): the page's own window when a Chromium page has the keys (after
           a Cmd-T, the New Tab page), else the shell window; each act's row says the word.
           The launcher starts the app's binary directly, and on a display Mac such a process did not become the active app; so the `activate` form then asks
           LaunchServices one time (`open BUNDLE`, as a click on the Dock icon of an app that runs), and `PREFLIGHT activate:`
           says what made the app active (`by=launch`, `open`, `none`), which app is frontmost, and which
           instances of the app run. With `by=none` the `activate` form is not run (`forms_not_run` in the report
           and in each row that is not of that form) and `one-key` is next. A second instance after the open ends
           that launch and each launch after it; it gets one SIGTERM if launchd started it, so it does not stay in
           the session of the Mac.
  pointer  `debug.mouse`: mouse events on the app's own queue, one request for each step of a drag, paced by this
           script; the system pointer does not move in the film. The row has the step rate of the app's input journal.
  action   `action.run`, for an act with no default key; its label says so.
The panes: `redraw` = htop, else nvim, else /usr/bin/top (--program); `stream` = /sbin/ping on the loopback;
`page` = a Chromium tab on a page of this script's local server (no network); `chat` = the agent chat page with a
synthetic thread that streams by the page's own debug hook (`debug.agent_pane` stream): no agent runs and the launch
guard stays. That hook runs only under CMUX_NEXT_AGENT_PANE_MOCK=1 (the page then talks to its in-page mock, not to
a daemon), and the mock also changes the New Tab page. So --chat-mock=auto (the default) makes 2 launches of the same
app: the mock off (the product's own pages) for each film but the `A-` and `M-` films, then the mock on for those;
in a launch with the mock off, the `chat` pane of the other set-ups is the product's New Tab page. --chat-mock=1 or 0
is one launch in that state (with 0, the `A-` and `M-` films are not_run). Each row says its launch's state.
The virtual display of the entry script is 1x: a film has 1 pixel for each point.

The preflight: directly after each launch and before the session is made, one of each thing that a film needs runs
in a workspace of its own and is read back (`preflight`, 2 minutes at most): the display link's frames, the
recorder's frames, one new tab and its close, one split, one zoom in and out, each key as a film sends it. One that
the app refuses, or that changes nothing, prints the app's own words (`PREFLIGHT <name> FAILED: ...`, with what the
app said of the key) and ends that launch; with no other launch form left the run ends at once with exit 1. So a
fault of the key path costs minutes, not a session and a list of films with no motion in them. The zoom is the one
check that does not end the launch, and the 2 minutes do not count it: its key is sent after the split's new pane is
settled, and if the key changes nothing, the zoom is made by `action.run toggleSplitZoom`; each film with a zoom then
says `zoom by action.run, not by a key` in its row and in its `keys` words. If the action changes nothing too, only
the films with a zoom are `not_run`. In a film, a key or an action that the app refuses makes the film `not_run`
with the app's words.

  pane-motion-films.py --app <cmux DEV tag.app> --films kinds [--workspaces N --live-shells K] --out DIR
  pane-motion-films.py --films list
--films: ids with commas, or `kinds` (9 films: T, B, A by D, SD, Z), `mixed`, `plist` (P03 to P23), `extra`
(X01 to X16: each pane action with a default key that has no other film), `all`. Exit 0 = each film asked for is
made; 2 = some are made and some are not; 1 = the preflight failed, or no film is made; 3 = not run (no app, an id
that is not known).
"""
import argparse, importlib.util, json, os, platform, re, shutil, signal, subprocess, sys, threading, time, traceback

HERE = os.path.dirname(os.path.abspath(__file__))
NEXT = os.path.join(HERE, "..", "cmux-next")
sys.path.insert(0, NEXT)
import bench_launch  # noqa: E402
SPEC = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(NEXT, "perf-stress-session.py"))
STRESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(STRESS)
MAKER = os.path.join(HERE, "..", "perf-bench", "session_real.py")

KEY = {"d": 2, "h": 4, "x": 7, "c": 8, "b": 11, "w": 13, "r": 15, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "=": 24,
       "-": 27, "0": 29, "o": 31, "p": 35, "return": 36, "l": 37, "n": 45, "tab": 48, "`": 50, "left": 123, "right": 124,
       "down": 125, "up": 126, "cmd": 55, "shift": 56, "opt": 58, "ctrl": 59}
MODIFIERS = ("ctrl", "opt", "shift", "cmd")
NAMES = {"return": "Enter", "`": "backtick", "=": "=", "-": "-"}
ONE_KEY = "one key for each call, no repeat flag, the script's clock"
ZOOM_CHORD, ZOOM_ACTION, BY_ACTION = "cmd+shift+return", "toggleSplitZoom", "zoom by action.run, not by a key"
LAUNCH_FORMS = {"auto": ["activate", "one-key"], "activate": ["activate"], "one-key": ["one-key"]}
PREFLIGHT_S = 120
LEAD_S, MIN_FILM_S, TAKE_S = 1.0, 4.5, 30
DRAG_RATE = 120
PING = "/sbin/ping -i 0.2 127.0.0.1"
SETUPS = {"T": ("row", ("redraw", "stream")), "B": ("row", ("page", "page")), "A": ("row", ("chat", "chat")),
          "M": ("row", ("redraw", "page", "chat")), "P": ("grid", ("redraw", "stream", "page", "chat")),
          "R": ("row", ("redraw", "stream", "shell", "shell", "shell"))}
MOCK_SETUPS = "AM"  # a film of these needs a chat thread that streams: only a launch with the page mock has one
KINDS = {"T": "2 terminals with a program", "B": "2 loaded browser pages", "A": "2 chats with a thread that streams",
         "M": "a terminal, a page and a chat"}
LIMITS = ["1x display: 1 pixel for each point", "the keys are posted to the app's own queue (debug.key), not the HID tap",
          "a chat pane has a synthetic thread that streams by the page's own debug hook; no agent runs",
          "a page pane shows a local page of the script, not a real site",
          "a drag is made by a debug command (debug.mouse); the system pointer is not shown"]


def K(chord, presses=1, gap=250, hold=0.0):
    """Keys: `chord` ("cmd+shift+d"; "cmd+d,w" = D then W under one Command), `presses` times with `gap` ms from
    key-down to key-down, or held `hold` seconds ("tabs": until 2 tabs of the pane are left)."""
    return ("keys", chord, presses, gap, hold)


def W(seconds):
    return ("wait", seconds)


def A(action, target=""):
    return ("action", action, target)


def film(ident, title, setup, acts, **more):
    return {"id": ident, "title": title, "setup": setup, "acts": acts, **more}


ZOOM = [K(ZOOM_CHORD), W(1.6), K(ZOOM_CHORD)]
CANVAS, CANVAS_OFF = [K("ctrl+cmd+c"), W(1.2)], [K("ctrl+cmd+c"), W(0.6)]
FILMS = [made for kind in "TBAM" for made in (
    film(f"{kind}-D", f"Cmd-D on {KINDS[kind]}", kind, [K("cmd+d")]),
    film(f"{kind}-SD", f"Cmd-Shift-D on {KINDS[kind]}", kind, [K("cmd+shift+d")]),
    film(f"{kind}-Z", f"Zoom in and out on {KINDS[kind]}", kind, ZOOM))]
FILMS += [
    film("P03", "Close a pane (its last tab)", "R", [K("cmd+w")], focus=2),
    film("P04", "Close a tab with siblings", "P", [K("cmd+w")], tabs=3),
    film("P05", "One new tab", "P", [K("cmd+t")]),
    film("P06", "New tab held 3 s", "P", [K("cmd+t", hold=3.0)], tail=2.0),
    film("P07", "New tab held, then 5 closes", "P", [K("cmd+t", hold=1.5), W(0.4), K("cmd+w", presses=5, gap=200)], tail=2.0),
    film("P08", "Close tab held", "P", [K("cmd+w", hold="tabs")], pre=[K("cmd+t", presses=12, gap=150), W(1.5)], tail=2.0),
    film("P09", "Next tab held, then the tab before held", "P", [K("ctrl+tab", hold=1.2), W(0.4), K("ctrl+shift+tab", hold=1.2)], tabs=5),
    film("P10", "Zoom in and out with 4 panes", "P", ZOOM),
    film("P11", "Resize by a held key", "P", [K("ctrl+shift+l", hold=1.0), W(0.3), K("ctrl+shift+h", hold=1.0)]),
    film("P12", "Divider drag, then a fast back-and-forth", "P", [("divider",)]),
    film("P13", "A split, then a close, in a row of 5 panes", "R", [K("cmd+d"), W(1.5), K("cmd+w")], focus=2),
    film("P14", "A tab dragged to another pane", "P", [("tab",)], tabs=2),
    film("P15", "Focus moved pane to pane", "P", [K(f"opt+cmd+{way}") if way else W(0.5) for way in ("right", "", "down", "", "left", "", "up")]),
    film("P16", "A new window", "P", [K("shift+cmd+n")], crop="frame", tail=2.5),
    film("P17", "A workspace switch: one shown before, one shown the first time", "P", [K("cmd+2"), W(1.5), K("cmd+3")],
         pre=[K("cmd+2"), W(1.0), ("show",)], tail=2.0),
    film("P18", "Sidebar hidden and shown", "P", [K("cmd+b"), W(1.2), K("cmd+b")]),
    film("P19", "A column docked and not docked", "P", [K("ctrl+cmd+p"), W(1.5), K("ctrl+cmd+p")], focus=1, dock=False),
    film("P20", "A pin and an unpin", "P", [A("palette.toggleWorkspacePin", "workspace"), W(1.2), A("palette.toggleWorkspacePin", "workspace")]),
    film("P21", "A new workspace and its close", "P", [K("cmd+n"), W(1.8), K("shift+cmd+w")], tail=2.0),
    film("P22", "A split, then a close after 60 ms", "P", [K("cmd+d,w", gap=60)]),
    film("P23", "Window cycle between 3 windows: 5 presses, then held", "P", [K("cmd+`", presses=5, gap=250), W(1.0), K("cmd+`", hold=1.0)],
         pre=[K("shift+cmd+n", presses=2, gap=1200), W(1.5)], crop="frame", tail=2.0),
    film("X01", "New column", "P", [K("ctrl+cmd+x")]),
    film("X02", "New row", "P", [K("ctrl+shift+cmd+x")]),
    film("X03", "New pane, layout by the app", "P", [K("ctrl+cmd+n")]),
    film("X04", "Even sizes", "P", [K("ctrl+cmd+=")], pre=[K("ctrl+shift+l", hold=0.8), W(0.5)]),
    film("X05", "Focus by pane number", "P", [K("ctrl+cmd+2"), W(0.5), K("ctrl+cmd+3"), W(0.5), K("ctrl+cmd+4"), W(0.5), K("ctrl+cmd+1")]),
    film("X06", "Flash of the focused pane", "P", [K("shift+cmd+h")]),
    film("X07", "Terminal text larger, 3 presses", "P", [K("cmd+=", presses=3, gap=400)]),
    film("X08", "Terminal text smaller, 3 presses", "P", [K("cmd+-", presses=3, gap=400)]),
    film("X09", "Terminal text size reset", "P", [K("cmd+0")], pre=[K("cmd+=", presses=3, gap=200), W(1.0)]),
    film("X10", "Canvas layout on and off", "P", [K("ctrl+cmd+c"), W(1.6), K("ctrl+cmd+c")]),
    film("X11", "Canvas overview in and out", "P", [K("ctrl+cmd+o"), W(1.6), K("ctrl+cmd+o")], pre=CANVAS, post=CANVAS_OFF),
    film("X12", "Canvas tidy", "P", [K("ctrl+cmd+t")], pre=CANVAS, post=CANVAS_OFF),
    film("X13", "Canvas: show the focused pane", "P", [K("ctrl+cmd+r")], pre=CANVAS + [K("opt+cmd+-", presses=3, gap=200), W(1.0)], post=CANVAS_OFF),
    film("X14", "Canvas zoom in, 3 presses", "P", [K("opt+cmd+=", presses=3, gap=400)], pre=CANVAS, post=CANVAS_OFF),
    film("X15", "Canvas zoom out, 3 presses", "P", [K("opt+cmd+-", presses=3, gap=400)], pre=CANVAS, post=CANVAS_OFF),
    film("X16", "Canvas zoom reset", "P", [K("cmd+0")], pre=CANVAS + [K("opt+cmd+=", presses=3, gap=200), W(1.0)], post=CANVAS_OFF),
]
GROUPS = {"kinds": lambda i: i[0] in "TBA" and "-" in i, "mixed": lambda i: i.startswith("M-"), "plist": lambda i: i[0] == "P",
          "extra": lambda i: i[0] == "X", "all": lambda i: True}


def key_steps(chord, presses=1, gap_ms=250, repeats=0, delay_ms=0, every_ms=0):
    """`chord` as `debug.key` steps: the modifiers go down first and stay down; each key is pressed `presses` times
    with `gap_ms` from key-down to key-down, each key-down with `repeats` auto-repeats behind it (a held key: the
    first repeat after `delay_ms`, the next ones each `every_ms`)."""
    names = chord.split("+")
    mods, keys = [n for n in names if n in MODIFIERS], names[-1].split(",")
    steps = [{"key_code": KEY[m], "down": True, **({"after_ms": 2} if i else {})} for i, m in enumerate(mods)]
    lead = 10
    for _ in range(presses):
        for key in keys:
            steps.append({"key_code": KEY[key], "down": True, "after_ms": lead})
            steps += [{"key_code": KEY[key], "down": True, "after_ms": every_ms if i else delay_ms, "repeat": True} for i in range(repeats)]
            steps.append({"key_code": KEY[key], "down": False, "after_ms": 8})
            lead = max(gap_ms - 8, 1)
    return steps + [{"key_code": KEY[m], "down": False, "after_ms": 2} for m in reversed(mods)]


def send_keys(rpc, form, chord, key_window="shell", presses=1, gap_ms=250, repeats=0, delay_ms=0, every_ms=0):
    """Sends `chord` (as `key_steps`) in the launch's key form; returns what the app said, with `error` when the app
    refused it. `activate`: one `debug.key` sequence in the key window, played by the app's clock; the call waits for
    its end. `one-key`: each key-down is one `debug.key` call at its time by this script's clock."""
    if form == "activate":
        reply = rpc("debug.key", {"sequence": key_steps(chord, presses, gap_ms, repeats, delay_ms, every_ms), "key_window": key_window})
        reply = reply if isinstance(reply, dict) else {"error": f"debug.key: {reply}"}
        said = {k: reply[k] for k in ("base_s", "duration_ms", "scheduled", "key_window", "error") if reply.get(k) is not None}
        if "error" not in said and "base_s" not in said:
            said["error"] = f"debug.key gave no start time: {reply}"
        if "error" not in said:
            time.sleep((said.get("duration_ms") or 0) / 1000 + 0.05)  # the sequence plays in the app for this long
        return said
    said = {"key_source": ONE_KEY, "key_window": key_window, "handled_by": [], "trace": []}
    if repeats:
        return {**said, "error": "a held key needs the key sequence of the `activate` launch form: this form has no repeat"}
    names, start = chord.split("+"), time.monotonic()
    mods = [{"opt": "option"}.get(n, n) for n in names if n in MODIFIERS]  # the app's names of them
    for i, key in enumerate(key for _ in range(presses) for key in names[-1].split(",")):
        time.sleep(max(0.0, start + i * gap_ms / 1000 - time.monotonic()))  # key-down to key-down, as the sequence
        reply = rpc("debug.key", {"key": key, "modifiers": mods, **({"target": "page"} if key_window == "page" else {})})
        reply = reply if isinstance(reply, dict) else {"error": f"debug.key: {reply}"}
        said["handled_by"].append(f"{reply.get('handled_by')}: {reply.get('action')}")
        said["trace"] += [str(line)[:160] for line in (reply.get("trace") or [])[:6]]
        # `refused_action`: the app took the key for that action and the action did not run.
        error = reply.get("error") or (reply.get("refused_action") and f"the app did not run {reply['refused_action']}")
        if error:
            return {**said, "error": str(error)}
    return {**said, "duration_ms": round((time.monotonic() - start) * 1000, 1)}


def focus_word(rpc):
    """The `key_window` word for the next key sequence of the `activate` form, by one read of `debug.focus`: `page`
    when a Chromium page has the keys, else `shell`. The app shows such a page (a browser tab, a chat, the New Tab
    page) in a child window that has the keys while the page has focus, and it gives the keys back to that window
    when the shell window takes them with no click; so it refuses `shell` then (`the shell window did not become
    key`). The word thus follows the focus at each key: a Cmd-T moves the keys to the new tab's page. The read:
    `appkit.child_window_page` of the cmux window that is key, or of each window when none is (a page's window is)."""
    focus = rpc("debug.focus")
    windows = [w for w in (focus.get("windows") if isinstance(focus, dict) else None) or [] if isinstance(w, dict)]
    return "page" if any((w.get("appkit") or {}).get("child_window_page") for w in [w for w in windows if w.get("is_key")] or windows) else "shell"


def app_said(said):
    """What the app answered to the keys of one `send_keys` call, for a PREFLIGHT line. A key sequence plays after
    its call returns, so the app says of it only that it is scheduled."""
    if "handled_by" in said:
        return f"the app's reply to each key (handled_by: action) = {said['handled_by']}, trace = {said.get('trace') or []}"
    return "a key sequence, " + ", ".join(f"{k} = {said[k]}" for k in ("scheduled", "key_window", "duration_ms") if k in said)


def dry_run(rpc, chord):
    """What the app's key router would do with the first key of `chord` (`debug.key` with `dry_run`: nothing runs),
    for the FAILED line of a key sequence: the app says of a sequence only that it is scheduled."""
    names = chord.split("+")
    try:
        reply = rpc("debug.key", {"key": names[-1].split(",")[0], "modifiers": [{"opt": "option"}.get(n, n) for n in names if n in MODIFIERS], "dry_run": True})
    except Exception as error:  # noqa: BLE001  a fault of this read must not hide the fault that it is for
        reply = f"not read: {error!r}"
    return f"a dry run of the key (the key router's decision; nothing runs) = {(json.dumps(reply, default=str) if isinstance(reply, dict) else str(reply))[:400]}"


def label(act, zoom="key"):
    """The words of one act for the film's bar, or "" for a wait. With `zoom` = BY_ACTION the zoom key is not sent:
    the words say what makes the zoom."""
    if act[0] == "keys" and act[1] == ZOOM_CHORD and zoom == BY_ACTION:
        return f"action {ZOOM_ACTION} ({BY_ACTION})"
    if act[0] == "keys":
        _, chord, presses, _, hold = act
        names = chord.split("+")
        mods = "".join(n.capitalize() + "-" for n in names[:-1])
        said = " then ".join(mods + NAMES.get(k, k.capitalize()) for k in names[-1].split(","))
        return said + (f" x{presses}" if presses > 1 else "") + (" held" if hold == "tabs" else f" held {hold:g} s" if hold else "")
    if act[0] == "action":
        return f"action {act[1]} (no key)"
    return {"divider": "drag of a divider by a debug command", "tab": "drag of a tab by a debug command"}.get(act[0], "")


def redraw_program(asked):
    """(name, command line) of the program for a `redraw` pane: `asked`, or the first of htop, nvim that this host
    has, else the system's top."""
    path = os.environ.get("PATH", "") + ":/opt/homebrew/bin:/usr/local/bin"
    for name, tail in (("htop", " -d 5"), ("nvim", " -R /etc/services")):
        found = shutil.which(name, path=path)
        if found and asked in ("auto", name):
            return name, found + tail
    return "top", "/usr/bin/top -s 1"


def seed(app, count, live, url, deadline, out):
    """`count` workspaces by session_real.py `make` on the app's daemon, each with a terminal tab (parked, but for
    `live` of them) and a page tab at `url`: what the maker did, for the report."""
    command = [sys.executable, MAKER, "make", "--app-socket", app.socket, "--workspaces", str(count), "--terminals", str(count),
               "--agents", "0", "--no-agents", "--settle", "0", "--tabs", str(2 * count), "--panes", str(count),
               "--browser-tabs", str(count), "--browser-url", url, "--live-shells", str(live), "--out", os.path.join(out, "session.json")]
    began = time.monotonic()
    try:
        done = subprocess.run(command, check=False, timeout=deadline, capture_output=True, text=True)
        code, said = done.returncode, done.stdout + done.stderr
    except subprocess.TimeoutExpired as late:
        parts = [part.decode(errors="replace") if isinstance(part, bytes) else part or "" for part in (late.stdout, late.stderr)]
        code, said = f"not done in {deadline:.0f} s", "".join(parts)
    print(said[-4000:], flush=True)
    counted = re.findall(r"^made (\d+)/", said, re.M)
    return {"asked": count, "live_shells": live, "maker_exit": code, "maker_said_made": int(counted[-1]) if counted else 0,
            "seed_s": round(time.monotonic() - began, 1)}


class PreflightFailed(RuntimeError):
    pass


class SecondInstance(PreflightFailed):
    """A second instance of the app runs after the LaunchServices open: no other launch form, no film."""


def place(app):
    """The `activate` form: the app reads no window placement at its launch, so the window gets the launcher's frame
    (its x, y from the top left of the main screen's visible frame) here. Returns the frame, or why not."""
    first = app.rpc("debug.window_frame", {"screen": 0})
    visible = first.get("visible_frame") if isinstance(first, dict) else None
    if not visible:
        return f"not placed: {str(first)[:160]}"
    width, height = min(app.window[2], visible[2]), min(app.window[3], visible[3])
    x, y = min(app.window[0], visible[2] - width), min(app.window[1], visible[3] - height)
    reply = app.rpc("debug.window_frame", {"frame": [visible[0] + x, visible[1] + visible[3] - y - height, width, height]})
    return reply.get("frame") if isinstance(reply, dict) and reply.get("frame") else f"not placed: {str(reply)[:160]}"


def front_app():
    """The frontmost app of this session by LaunchServices (`lsappinfo front`, then its name and its pid), or the
    tool's own words when it gives none."""
    try:
        asn = subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True, errors="replace", timeout=5).stdout.strip()
        name, pid = (subprocess.run(["/usr/bin/lsappinfo", "info", "-only", only, asn], capture_output=True, text=True, errors="replace",
                                    timeout=5).stdout.strip() for only in ("name", "pid"))
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return f"not read ({str(error)[:80]})"
    named, numbered = re.search(r'=\s*"([^"]*)"', name), re.search(r'"?pid"?\s*=\s*(\d+)', pid)
    return f"{named.group(1) if named else (name or asn)[:60] or 'none'} (pid {numbered.group(1) if numbered else 'not read'})"


def instances(binary):
    """The running instances of the app `binary`, as {pid: (its parent's pid, the first 120 characters of its
    command)}: each process of that exact path that is not a child of another process of it (LaunchServices starts an
    instance under launchd, pid 1; this run's instance is a child of this script). None when `ps` gave no list (no
    answer in 10 s, an exit that is not 0, words that do not parse): that fault is printed, and the caller then
    counts nothing and sends no signal."""
    try:
        done = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True, errors="replace", timeout=10)
        if done.returncode:
            raise OSError(f"exit {done.returncode}: {done.stderr.strip()[:120]}")
        paths = {binary, os.path.realpath(binary)}
        rows = (line.split(None, 2) for line in done.stdout.splitlines())
        own = {int(row[0]): (int(row[1]), row[2][:120]) for row in rows
               if len(row) == 3 and any(row[2] == path or row[2].startswith(path + " ") for path in paths)}
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"PREFLIGHT activate: ps gave no list of the app's instances: {str(error)[:200]}", flush=True)
        return None
    return {pid: row for pid, row in sorted(own.items()) if row[0] not in own}


def activate(app, form):
    """Prints `PREFLIGHT activate: by=... app_active=... key_window=... front=... instances=N (pids [...])` and
    returns it; then one line for each instance (its parent and its command). The launcher starts the app's binary
    directly, and on a display Mac such a process did not become the active app. So in the `activate` form, if the
    app is not active after its launch: ONE LaunchServices open of the bundle (`open BUNDLE`; for an app that runs,
    the open makes that instance the active app, as a click on its Dock icon does; close-flash-bench.py activates its
    app the same way), then 10 s for `app_active`. `by` = `launch` (active with no open), `open`, `none` (not
    active: the whole `debug.focus` reply is printed, and PreflightFailed with the line), `not asked` (the `one-key`
    form: its launch never takes the keyboard). A `ps` that gives no list is `instances=not read`: it ends nothing.

    A second instance: a pid in the list after the open that was not in the list before it and is not the process
    of this launch. It raises SecondInstance with the line: the run ends there, and no film is made with an app on
    the display that is not this run's. Such a pid gets ONE SIGTERM from this function (no other signal, no second
    try) only when the list before the open was read, the process of this launch was in it (so the list is proven),
    and the pid's parent is pid 1 (what LaunchServices starts): it would stay in the session after the run. In each
    other case the line says `SIGTERM not sent` with the cause. Not of this function: at the end of each launch the
    launcher's stop ends each process of this bundle path that still runs (SIGTERM, then SIGKILL), as it always did."""
    focus = lambda: (lambda reply: reply if isinstance(reply, dict) else {})(app.rpc("debug.focus"))
    own = getattr(getattr(app, "process", None), "pid", None)
    by, asked, before = "not asked", False, None
    if form == "activate":
        by = "launch"
        if not focus().get("app_active"):
            asked, before = True, instances(app.binary)
            try:
                opened = subprocess.run(["/usr/bin/open", app.app], capture_output=True, text=True, errors="replace", timeout=30)
                if opened.returncode:
                    print(f"PREFLIGHT activate: open exit {opened.returncode}: {opened.stderr.strip()[:200]}", flush=True)
            except (OSError, subprocess.SubprocessError, ValueError) as error:
                print(f"PREFLIGHT activate: open did not run: {str(error)[:200]}", flush=True)
            by = "open" if STRESS.wait(lambda: focus().get("app_active"), 10, step=0.25) else "none"
    seen, front = focus(), front_app()  # the front app first: the list of instances is then new when a signal goes
    running = instances(app.binary)
    listed = lambda table: "not read" if table is None else sorted(table)
    inner = ([f"pids {listed(running)}"] if running is not None else []) + ([f"before the open: {listed(before)}"] if asked else [])
    line = (f"PREFLIGHT activate: by={by} app_active={str(bool(seen.get('app_active'))).lower()} key_window={seen.get('key_window') or 'none'} "
            f"front={front} instances={'not read' if running is None else len(running)}" + (f" ({'; '.join(inner)})" if inner else ""))
    print(line, flush=True)
    for pid, (parent, command) in (running or {}).items():
        print(f"PREFLIGHT activate: instance pid {pid}: parent {parent}, command {command}", flush=True)
    new = [pid for pid in (running or {}) if pid not in (before or {}) and pid != own] if asked else []
    if new:
        unproven = ("the list before the open was not read" if before is None
                    else f"the launched pid {own} was not in the list before the open" if own not in before else "")
        ended = []
        for pid in new:
            parent, command = running[pid]
            why = unproven or (f"its parent is pid {parent}, not pid 1" if parent != 1 else "")
            if not why:
                try:
                    os.kill(pid, signal.SIGTERM)
                except OSError as error:
                    why = str(error)[:80]
            ended.append(f"pid {pid} (parent {parent}, command {command}): SIGTERM {f'not sent ({why})' if why else 'sent'}")
        stop = f"a second instance of the app runs after the open; one SIGTERM to each one that launchd started: {'; '.join(ended)}; the run ends here"
        print("PREFLIGHT activate: " + stop, flush=True)
        raise SecondInstance(f"{line}: {stop}")
    if by == "none":
        print("PREFLIGHT activate: debug.focus = " + json.dumps(seen, default=str)[:2000], flush=True)
        raise PreflightFailed(line)
    return line


def preflight(app, st, out, mbps, form, display):
    """One of each thing that a film needs, in a workspace of its own, each read back: `frames`, `record`, `new-tab`,
    `close-tab`, `split`, `zoom`, the keys in the launch's key form. Prints the state of the launch, then
    `PREFLIGHT <name> ok: <what was read>` for each, then returns (the display link's reply, what makes a zoom); the
    first that fails prints the app's words, `debug.focus` and the window's frame, and raises. The zoom does not
    raise: it is "key", else BY_ACTION (the key changed nothing and `action.run` did), else "none: <why>". PREFLIGHT_S
    at most for the checks that can end the launch; the settle wait and the zoom are after that bound and have their
    own (so a slow zoom costs only the films with a zoom)."""
    rpc, began, name = app.rpc, time.monotonic(), "launch"

    def wait(test, bound, step, cut=True):
        """`cut`: the bound ends with the preflight's PREFLIGHT_S."""
        return STRESS.wait(test, max(0.2, min(bound, began + PREFLIGHT_S - time.monotonic())) if cut else bound, step=step)

    def failed(said):
        late = f" (the preflight's {PREFLIGHT_S} s are over)" if name not in ("settle", "zoom") and time.monotonic() - began > PREFLIGHT_S else ""
        print(f"PREFLIGHT {name} FAILED: {str(said)[:1200]}{late}", flush=True)
        print("PREFLIGHT focus: " + json.dumps(rpc("debug.focus"))[:2000], flush=True)
        print("PREFLIGHT window: " + json.dumps(rpc("debug.window_frame", {}))[:600], flush=True)
        return f"{name}: {str(said)[:300]}"

    def fail(said):
        raise PreflightFailed(failed(said))

    def ok(said):
        print(f"PREFLIGHT {name} ok: {said}", flush=True)

    def key(chord, read, want, unit, must=True):
        """One chord as a film sends it; `read()` must become `want` in 10 s. Returns "" when it did; when it did
        not: raises with `must`, else prints the same lines and returns the fault."""
        before = read()
        said = send_keys(rpc, form, chord, focus_word(rpc) if form == "activate" else "shell")
        fault = said.get("error") or (not wait(lambda: read() == want(before), 10, 0.05, cut=must) and f"{unit} {before} -> {read()} in 10 s, not {want(before)}")
        if fault:
            fault = f"{fault}; {app_said(said)}" + (f"; {dry_run(rpc, chord)}" if form == "activate" else "")
            return fail(fault) if must else failed(fault)
        ok(f"{unit} {before} -> {read()}; {app_said(said)}")
        return ""

    focus = rpc("debug.focus")
    focus = focus if isinstance(focus, dict) else {}
    print(f"PREFLIGHT launch: activate={'yes' if form == 'activate' else 'no'} app_active={str(bool(focus.get('app_active'))).lower()} "
          f"key_window={focus.get('key_window') or 'none'} display={display}", flush=True)
    name = "frames"
    rpc("debug.frames", {"action": "start"})
    time.sleep(1.0)  # 1 s of the app's display link: the rate that the display has for this app
    link = rpc("debug.frames", {"action": "stop"})
    link = link if isinstance(link, dict) else {}
    if not link.get("frames"):
        fail(f"the display link gave no frame in 1 s: {link}")
    ok(f"frames {link.get('frames')}, p50 {link.get('p50_ms')} ms")
    workspace = st.new_workspace()
    if workspace:
        st.show(workspace)
    pane = workspace and wait(lambda: (st.panes(st.workspace(workspace)) or [{}])[0].get("id"), 20, 0.05)
    shell = pane and next((t.get("id") for t in st.settled_tabs(workspace, pane) if t.get("kind") == "terminal"), None)
    name = "record"
    if not shell:
        fail(f"no new workspace with a terminal pane (workspace {workspace}, pane {pane})")
    st.focus_pane(pane)
    read = lambda: (lambda r: r if isinstance(r, dict) else {})(rpc("debug.motion", {"action": "record_read"}))
    started = rpc("debug.motion", {"action": "record_start", "path": os.path.join(out, "preflight.mov"), "seconds": 20, "mbps": mbps})
    if not isinstance(started, dict) or started.get("error"):
        fail(f"record_start: {started}")
    if not wait(lambda: read().get("capturing") or read().get("error"), 10, 0.1) or read().get("error"):
        fail(f"the recorder did not start to capture in 10 s: {read()}")
    st.send(shell, "echo preflight\r")  # a change of the screen: the recorder gets a frame only for one
    drawn = wait(lambda: read().get("complete"), 10, 0.1)
    rpc("debug.motion", {"action": "record_stop"})
    done = wait(lambda: (lambda r: r if r.get("written") or r.get("error") else None)(read()), 20, 0.25) or {}
    if not drawn or not done.get("frames") or done.get("error") or done.get("write_error"):
        fail(f"the recorder gave no frame of a screen that changed: {done or read()}")
    ok(f"frames {done.get('frames')}, complete {done.get('complete')}, {started.get('width')}x{started.get('height')}, movie {done.get('movie_status')}")
    tabs = lambda: len(st.tabs(workspace, pane))
    panes = lambda: len(st.panes(st.workspace(workspace)))
    zoomed = lambda: sum(1 for s in (st.workspace(workspace) or {}).get("screens") or [] if s.get("zoomed_pane"))
    for name, chord, count, want, unit in (
            ("new-tab", "cmd+t", tabs, lambda n: n + 1, "tabs"), ("close-tab", "cmd+w", tabs, lambda n: n - 1, "tabs"),
            ("split", "cmd+d", panes, lambda n: n + 1, "panes")):
        key(chord, count, want, unit)
    # The bound is for the checks above, which can end the launch. The settle wait and the zoom are after it.
    name, spent = "time", time.monotonic() - began
    if spent > PREFLIGHT_S:
        fail(f"each check before the zoom passed, in {spent:.0f} s")
    # A film zooms a layout that is made and settled. So the zoom key waits for the split's new pane: 2 reads with
    # the same panes, each with a tab, none of them the app's stand-in for a tab that the daemon does not have yet.
    name, waited = "settle", time.monotonic()
    shape = lambda: [(p.get("id"), [t.get("id") for t in p.get("tabs") or []]) for p in st.panes(st.workspace(workspace))]

    def still():
        one = shape()
        if not all(tabs and not any(str(t).startswith(STRESS.PROVISIONAL_TAB) for t in tabs) for _, tabs in one):
            return None
        time.sleep(0.3)  # between the 2 reads
        return one if shape() == one else None
    settled = wait(still, 15, 0.1, cut=False)
    print(f"PREFLIGHT settle {'ok' if settled else 'not reached in 15 s (the zoom key is sent now)'}: {len(shape())} panes, "
          f"{time.monotonic() - waited:.1f} s after the split" + ("" if settled else f"; the panes and their tabs = {shape()}"[:700]), flush=True)
    name, zoom = "zoom", "key"
    turn = lambda n: 0 if n else 1
    fault = key(ZOOM_CHORD, zoomed, turn, "zoomed panes", must=False) or key(ZOOM_CHORD, zoomed, turn, "zoomed panes", must=False)
    if fault:
        # The key changed nothing: the same motion by the action, on the pane that has the focus in this window.
        zoom, target = BY_ACTION, (st.window_showing(workspace) or {}).get("focused_pane")
        for _ in range(2):
            before = zoomed()
            reply = st.action(ZOOM_ACTION, target=f"pane:{target}" if target else None)
            refusal = isinstance(reply, dict) and reply.get("error")
            if refusal or not wait(lambda: zoomed() == turn(before), 10, 0.05, cut=False):
                unchanged = f"zoomed panes {before} -> {zoomed()} in 10 s, not {turn(before)}; the action's reply = {json.dumps(reply, default=str)[:300]}"
                zoom = "none: " + failed(f"by action.run also: {refusal or unchanged}; the key: {fault}")
                break
            ok(f"zoomed panes {before} -> {zoomed()}, {BY_ACTION}")
    st.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
    st.made.clear()
    print(f"PREFLIGHT passed: frames, record, new-tab, close-tab, split in {spent:.0f} s; zoom = {zoom[:200]}", flush=True)
    return link, zoom


class Films:
    def __init__(self, app, opts, mock, form):
        self.app, self.opts, self.mock, self.form = app, opts, mock, form
        self.zoom = "key"  # the preflight's word: "key", BY_ACTION, or "none: <why>"
        self.st = STRESS.Stress(app.rpc)
        self.program = redraw_program(opts.program)
        self.main_window = next(iter(self.windows()), None)

    def left(self):
        return self.opts.deadline - time.monotonic()

    def windows(self):
        return {w.get("id") or w.get("key") for w in self.st.topology().get("windows") or []} - {None}

    def chat(self, pane):
        """Waits for the chat page of `pane`, then starts its synthetic stream in a thread (the call ends with the
        stream); returns the thread's box."""
        ready = STRESS.wait(lambda: (lambda r: r if isinstance(r, dict) and not r.get("error") else None)(
            self.app.rpc("debug.agent_pane", {"action": "readiness", "pane": pane}, 30)), 20, step=0.5)
        if not ready:
            last = self.app.rpc("debug.agent_pane", {"action": "readiness", "pane": pane}, 30)
            raise RuntimeError(f"the chat page was not ready in 20 s: {last}")
        box = {"reply": None}

        def run():
            box["reply"] = self.app.rpc("debug.agent_pane", {"action": "stream", "pane": pane, "rows": self.opts.thread_rows,
                                                             "seconds": self.opts.stream_seconds}, self.opts.stream_seconds + 90)
        box["thread"] = threading.Thread(target=run, daemon=True)
        box["thread"].start()
        return box

    def build(self, spec, row):
        """A new workspace, shown, with the panes of the film's set-up; returns (workspace, pane ids, stream boxes)."""
        st, (layout, kinds) = self.st, SETUPS[spec["setup"]]
        # With the page mock off no chat thread can stream: that pane is the product's New Tab page.
        kinds = row["panes"] = [kind if kind != "chat" or self.mock else "newtab" for kind in kinds]
        workspace = st.new_workspace()
        if not workspace:
            raise RuntimeError("no new workspace")
        st.show(workspace)
        first = STRESS.wait(lambda: (st.panes(st.workspace(workspace)) or [{}])[0].get("id"), 30, step=0.05)
        if not first:
            raise RuntimeError("the new workspace has no pane")
        panes = [first]
        for index in range(1, len(kinds)):
            parent, verb = (panes[index - 2], "splitDown") if layout == "grid" and index >= 2 else (panes[-1], "splitRight")
            made = st.split(workspace, parent, verb)
            if not made:
                raise RuntimeError(f"{verb} made no pane: {st.refusals[-1:]}")
            panes.append(made)
        chats = []
        for pane, kind in zip(panes, kinds):
            shell = next((t.get("id") for t in st.settled_tabs(workspace, pane) if t.get("kind") == "terminal"), None)
            if kind in ("redraw", "stream") and shell:
                st.send(shell, (self.program[1] if kind == "redraw" else PING) + "\r")
            elif kind in ("page", "chat"):
                fallbacks = st.chat_fallbacks
                st.add_tab(workspace, pane, "chromium" if kind == "page" else "chat")
                if st.chat_fallbacks > fallbacks or not (st.made.get(pane) or [(kind, None)])[-1][1]:
                    raise RuntimeError(f"no {kind} tab: the app refused it or it did not come ({st.refusals[-1:]})")
                if shell:
                    st.action("closeTab", target=f"tab:{shell}", focus=False)
                if kind == "chat":
                    chats.append(pane)
            elif kind == "newtab":
                before = {t.get("id") for t in st.settled_tabs(workspace, pane)}
                reply = st.action("newTab.page", target=f"pane:{pane}")
                if not STRESS.wait(lambda: [t for t in st.tabs(workspace, pane) if t.get("id") not in before] or None, 20, step=0.1):
                    raise RuntimeError(f"no New Tab page in 20 s: {str(reply)[:160]}")
                if shell:
                    st.action("closeTab", target=f"tab:{shell}", focus=False)
        row["dock"] = "not asked"
        if self.opts.dock and spec.get("dock", True):
            # One more shell pane, docked as a column (the app's default edge and mode). A dock that the app refuses,
            # or that the snapshot does not show as a dock, is closed again: the film then has no docked column.
            extra = st.split(workspace, panes[-1], "splitRight")
            reply = st.action("column.dock", target=f"pane:{extra}", focus=False) if extra else {"error": "no pane"}
            docked = extra and STRESS.wait(lambda: extra not in [p["id"] for p in st.panes(st.workspace(workspace))], 5, step=0.1)
            refusal = str(reply.get("error") if isinstance(reply, dict) else reply)[:120]
            row["dock"] = "a docked column" if docked else f"none: {refusal}"
            if extra and not docked:
                first_tab = (st.tabs(workspace, extra) or [{}])[0].get("id")
                st.action("closeTab", target=f"tab:{first_tab}", focus=False)
        focus = panes[spec.get("focus", 0)]
        st.focus_pane(focus)
        for _ in range(spec.get("tabs", 0)):
            st.add_tab(workspace, focus, "terminal")
        streams = [self.chat(pane) for pane in chats]
        time.sleep(self.opts.settle)  # the programs, the pages and the streams' first rows are on the screen before the take
        failed = [box["reply"] for box in streams if isinstance(box["reply"], dict) and box["reply"].get("error")]
        if failed:
            raise RuntimeError(f"the chat page did not stream: {failed[0]}")
        return workspace, panes, streams

    def drag(self, points):
        """One pointer drag through `points`: one `debug.mouse` request for each step, paced by this script; returns
        the steps asked and what the app's input journal has of them."""
        rpc, last = self.app.rpc, points[0]
        rpc("debug.journal", {"clear": True})
        rpc("debug.mouse", {"action": "drag", "x": last[0], "y": last[1], "to_x": last[0], "to_y": last[1], "steps": 1, "release": False})
        for index, point in enumerate(points[1:], 1):
            rpc("debug.mouse", {"action": "drag", "x": last[0], "y": last[1], "to_x": point[0], "to_y": point[1], "steps": 1,
                                "press": False, "release": index == len(points) - 1})
            last = point
            time.sleep(1 / DRAG_RATE)  # the pointer's pace, not a wait for a result
        entries = [e for e in (rpc("debug.journal", {"last": 2000}) or {}).get("entries") or [] if "drag" in json.dumps(e.get("kind"))]
        span = (entries[-1].get("uptimeNanos", 0) - entries[0].get("uptimeNanos", 0)) / 1e9 if len(entries) > 1 else 0
        return {"steps_asked": len(points) - 1, "rate_asked": DRAG_RATE, "journal_steps": len(entries),
                "journal_steps_per_s": round((len(entries) - 1) / span, 1) if span > 0 else None}

    def pointer(self, kind, panes):
        """The points of a drag: `divider` = the first divider, slow down and right, then 4 fast swings; `tab` = the
        first tab pill to the last pane."""
        line = lambda a, b, n: [(a[0] + (b[0] - a[0]) * i / n, a[1] + (b[1] - a[1]) * i / n) for i in range(1, n + 1)]
        at = lambda params: (lambda r: (r["x"], r["y"]) if isinstance(r, dict) and "x" in r else None)(self.app.rpc("debug.mouse", {"action": "move", **params}))
        if kind == "divider":
            start = at({"divider": "first"})
            if not start:
                raise RuntimeError("debug.mouse found no divider")
            far, near = (start[0] + 160, start[1] + 100), (start[0] - 80, start[1] - 50)
            return [start] + line(start, far, DRAG_RATE) + [p for _ in range(2) for p in line(far, near, 12) + line(near, far, 12)]
        pills = [p["pill"] for w in (self.app.rpc("debug.pane_chrome") or {}).get("windows") or [] for p in w.get("panes") or [] if p.get("pill")]
        goal = at({"pane": panes[-1]})
        if not pills or not goal:
            raise RuntimeError("no tab pill or no goal pane for the drag")
        start = (pills[0][0] + pills[0][2] / 2, pills[0][1] + pills[0][3] / 2)
        return [start] + line(start, goal, int(DRAG_RATE * 0.6))

    def play(self, acts, workspace, panes, focus, key_window, clock):
        """Runs `acts`; returns one row for each act that is not a wait."""
        rows = []
        for act in acts:
            if act[0] == "wait":
                time.sleep(act[1])  # the pause between 2 acts of the film
                continue
            row = {"label": label(act, self.zoom), "at_s": round(time.monotonic() - clock, 3)}
            if act[0] == "keys" and act[1] == ZOOM_CHORD and self.zoom == BY_ACTION:
                # The preflight's zoom key changed nothing in this launch: the zoom of the film's focused pane by the action.
                reply = self.st.action(ZOOM_ACTION, target=f"pane:{focus}")
                row["zoom"] = BY_ACTION
                if isinstance(reply, dict) and reply.get("error"):
                    row["error"] = str(reply["error"])[:160]
            elif act[0] == "keys":
                _, chord, presses, gap, hold = act
                # "tabs": the key-down and its repeats close all but 2 tabs of the pane, so the pane stays.
                delay, every = self.opts.repeat_delay_ms, max(self.opts.repeat_ms, 1)
                repeats = max(1, len(self.st.tabs(workspace, focus)) - 3) if hold == "tabs" else max(1, 1 + int((hold * 1000 - delay) / every)) if hold else 0
                # The `activate` form: the window that has the keys now. The `one-key` form: the word of the film's set-up.
                word = focus_word(self.app.rpc) if self.form == "activate" else key_window
                said = send_keys(self.app.rpc, self.form, chord, word, presses, gap, repeats, delay, every)
                if said.get("error") and word != "shell":
                    row["refused_as"] = f"{word}: {str(said['error'])[:120]}"
                    said = send_keys(self.app.rpc, self.form, chord, "shell", presses, gap, repeats, delay, every)
                row.update(said)
            elif act[0] == "action":
                reply = self.st.action(act[1], target=f"workspace:{workspace}" if act[2] == "workspace" else None)
                if isinstance(reply, dict) and reply.get("error"):
                    row["error"] = str(reply["error"])[:160]
            elif act[0] == "show":
                self.st.show(workspace)
                self.st.focus_pane(focus)
                continue
            else:
                row["drag"] = self.drag(self.pointer(act[0], panes))
            rows.append(row)
        return rows

    def take(self, spec):
        """One film: the row for films.json."""
        st, rpc, opts = self.st, self.app.rpc, self.opts
        zooms = any(act[0] == "keys" and act[1] == ZOOM_CHORD for part in ("pre", "acts", "post") for act in spec.get(part, ()))
        row = {"id": spec["id"], "title": spec["title"], "setup": spec["setup"], "status": "not_run", "crop": spec.get("crop", "window"),
               "keys": ", ".join(filter(None, (label(a, self.zoom) for a in spec["acts"]))), "agent_page_mock": self.mock, "launch_form": self.form,
               **({"zoom": self.zoom[:400]} if zooms else {})}
        workspaces, windows = {w["id"] for w in st.workspaces()}, self.windows()
        try:
            if self.left() < 90:
                raise RuntimeError("no time left in the step")
            if zooms and self.zoom not in ("key", BY_ACTION):
                raise RuntimeError(f"the preflight's zoom changed nothing, by the key and by action.run: {self.zoom}")
            if spec["setup"] in MOCK_SETUPS and not self.mock:
                raise RuntimeError("this launch has the page mock off: a chat thread streams only under the mock")
            workspace, panes, streams = self.build(spec, row)
            focus = panes[spec.get("focus", 0)]
            # A person's key on a page goes through the page's own window: the film's keys take that path when the
            # focused pane shows a Chromium page. This word of the set-up is for the `one-key` form; in the `activate`
            # form each key sequence gets its word from the focus at that time (`focus_word`).
            key_window = "page" if SETUPS[spec["setup"]][1][spec.get("focus", 0)] == "page" else "shell"
            self.refused(self.play(spec.get("pre", ()), workspace, panes, focus, key_window, time.monotonic()))
            row["panes_before"] = len(st.panes(st.workspace(workspace)))
            started = rpc("debug.motion", {"action": "record_start", "path": os.path.join(opts.out, spec["id"] + ".mov"), "seconds": TAKE_S, "mbps": opts.mbps})
            if not isinstance(started, dict) or started.get("error"):
                raise RuntimeError(f"record_start: {started}")
            try:
                state = STRESS.wait(lambda: (lambda r: r if isinstance(r, dict) and (r.get("capturing") or r.get("error")) else None)(
                    rpc("debug.motion", {"action": "record_read"})), 10, step=0.1) or {}
                if not state.get("capturing"):
                    raise RuntimeError(f"the recorder did not start to capture: {state.get('error') or 'no word in 10 s'}")
                clock = time.monotonic()
                time.sleep(LEAD_S)  # the film starts with the still window
                row["acts"] = self.play(spec["acts"], workspace, panes, focus, key_window, clock)
                self.refused(row["acts"])
                time.sleep(max(spec.get("tail", 1.5), MIN_FILM_S - (time.monotonic() - clock)))  # the motion's end is in the film
            finally:
                rpc("debug.motion", {"action": "record_stop"})
                read = STRESS.wait(lambda: (lambda r: r if isinstance(r, dict) and (r.get("written") or r.get("error")) else None)(
                    rpc("debug.motion", {"action": "record_read"})), 60, step=0.25) or {"error": "the movie was not written in 60 s"}
            row["panes_after"] = len(st.panes(st.workspace(workspace)))
            row["streams"] = ["still streamed at the film's end" if box["thread"].is_alive() else f"ended before the film's end: {str(box['reply'])[:200]}" for box in streams]
            row["recorder"] = {k: started.get(k) for k in ("width", "height", "scale", "rows", "columns", "filter", "source_rect")}
            row["recorder"].update({k: read.get(k) for k in ("frames", "first_t", "last_t", "complete", "stopped_by", "movie_status", "write_error", "error")
                                    if read.get(k) is not None})
            if not read.get("frames") or read.get("error"):
                raise RuntimeError(f"the recorder gave no movie: frames {read.get('frames')}, {read.get('error') or read.get('write_error')}")
            span = (read.get("last_t") or 0) - (read.get("first_t") or 0)
            # The mean over the whole take, still parts too: the true rate of a motion is in the frames.json times.
            row.update(status="made", file=spec["id"] + ".mov", mean_frames_per_s=round((read["frames"] - 1) / span, 2) if span > 0 else None)
            self.play(spec.get("post", ()), workspace, panes, focus, key_window, time.monotonic())
        except Exception as error:  # noqa: BLE001  one film's fault must not stop the other films
            traceback.print_exc()
            row["reason"] = str(error)[:400]
        finally:
            row["left_open"] = self.restore(workspaces, windows)
        print("PANE-FILM " + json.dumps(row), flush=True)
        return row

    @staticmethod
    def refused(rows):
        """A key or an action that the app refused: the film has no motion of that act, so it is not a film of it."""
        for row in rows:
            if row.get("error"):
                raise RuntimeError(f"the app refused {row['label']}: {row['error']}")

    def restore(self, workspaces, windows):
        """Closes each window and each workspace that the film made; returns what it did not close."""
        left = []
        for window in self.windows() - windows:
            front = self.app.rpc("debug.window.focus", {"window": window}) or {}
            if window in (front.get("key"), front.get("front")):
                self.st.action("closeWindow")
            else:
                left.append(f"a window ({str(front.get('error') or 'it did not come to the front')[:80]})")
        if self.windows() != windows and self.main_window:
            self.app.rpc("debug.window.focus", {"window": self.main_window})
        for workspace in [w["id"] for w in self.st.workspaces() if w["id"] not in workspaces]:
            reply = self.st.action("closeWorkspace", {"confirm": True}, target=f"workspace:{workspace}", focus=False)
            if isinstance(reply, dict) and reply.get("error"):
                left.append(f"a workspace ({str(reply['error'])[:80]})")
        self.st.made.clear()
        return left


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", help="a bench `cmux DEV <tag>.app` to launch (not running)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/pane-motion-films")
    parser.add_argument("--films", default="kinds", help="film ids with commas, or kinds, mixed, plist, extra, all, list")
    parser.add_argument("--workspaces", type=int, default=24, help="the size of the session (0: no maker call)")
    parser.add_argument("--live-shells", type=int, default=4, help="terminals of the session that keep a shell")
    parser.add_argument("--page-url", default="http://127.0.0.1:9/", help="the address of each page tab of the session")
    parser.add_argument("--seed-deadline", type=float, default=900.0, help="seconds for the session's maker")
    parser.add_argument("--pinned", type=int, default=3, help="workspaces of the session that get a pin")
    parser.add_argument("--dock", type=int, default=1, help="1: each film's window has one more pane as a docked column")
    parser.add_argument("--chat-mock", default="auto", choices=("auto", "0", "1"),
                        help="the agent pages' in-page mock: auto = off, then a second launch with it on for the A- and M- films; 0 or 1 = one launch")
    parser.add_argument("--program", default="auto", help="the program of a `redraw` pane: auto, htop, nvim, top")
    parser.add_argument("--mbps", type=float, default=60, help="the recorder's bit rate")
    parser.add_argument("--repeat-delay-ms", type=float, default=375, help="a held key's first repeat (the default is macOS's own default setting)")
    parser.add_argument("--repeat-ms", type=float, default=90, help="a held key's repeat interval (the default is macOS's own default setting)")
    parser.add_argument("--thread-rows", type=int, default=2000, help="rows of a chat pane's thread before it streams")
    parser.add_argument("--stream-seconds", type=float, default=25, help="how long a chat pane streams")
    parser.add_argument("--settle", type=float, default=3.0, help="seconds between a film's set-up and its take")
    parser.add_argument("--launch-form", default="auto", choices=tuple(LAUNCH_FORMS),
                        help="activate: launch without CMUX_NEXT_NO_ACTIVATE (the app takes the keyboard, as a person's does), the keys as "
                             "sequences in the key window; one-key: the launcher's launch, each key-down one call; auto: activate, then one-key")
    parser.add_argument("--display", default="real", help="what the entry script says of the display, for the preflight's first line")
    parser.add_argument("--budget", type=float, default=0, help="seconds for the whole run; a film with no time left is not_run (0: no bound)")
    opts = parser.parse_args()
    known = [spec["id"] for spec in FILMS]
    if opts.films == "list":
        print("\n".join(f"{spec['id']}\t{spec['title']}\t{', '.join(filter(None, (label(a) for a in spec['acts'])))}" for spec in FILMS))
        return 0
    wanted = [i for part in opts.films.split(",") for i in ([k for k in known if GROUPS[part](k)] if part in GROUPS else [part])]
    if not opts.app or [i for i in wanted if i not in known]:
        print(f"pane-motion-films: NOT RUN: needs --app and known film ids (not known: {[i for i in wanted if i not in known]})", flush=True)
        return 3
    # A film that opens a window goes last: a window that stays open is then in no other film.
    wanted = sorted(dict.fromkeys(wanted), key=lambda i: next(s for s in FILMS if s["id"] == i).get("crop") == "frame")
    opts.out = os.path.abspath(opts.out)  # the recorder writes the movie in the app's process
    opts.deadline = time.monotonic() + (opts.budget or 1e9)
    os.makedirs(opts.out, exist_ok=True)
    # No osascript in a step: the launcher leaves the sound as it is and its read of the mute state is a no-op.
    os.environ.update({"BENCH_LAUNCH_AUDIO": "keep", "BENCH_LAUNCH_OSASCRIPT": "/usr/bin/true"})
    needs_mock = [i for i in wanted if next(s for s in FILMS if s["id"] == i)["setup"] in MOCK_SETUPS]
    plan = [(False, [i for i in wanted if i not in needs_mock]), (True, needs_mock)] if opts.chat_mock == "auto" else [(opts.chat_mock == "1", wanted)]
    report = {"films": [], "failures": [], "launches": [], "limits": LIMITS, "key_repeat_ms": [opts.repeat_delay_ms, opts.repeat_ms], "mbps": opts.mbps,
              "alt_screen": "not read: no debug call says if a terminal is on its alternate screen"}
    forms = list(LAUNCH_FORMS[opts.launch_form])
    try:
        report["host"] = f"macOS {platform.mac_ver()[0] or 'not read'}, {platform.machine()}, python {platform.python_version()}"
    except Exception as error:  # noqa: BLE001  a line for a reader of the log: its fault must not end the run before a film
        report["host"] = f"not read ({error!r})"
    print("PREFLIGHT host: " + report["host"], flush=True)
    for mock, idents in plan:
        if not idents:
            continue
        # A second launch makes the session again: it starts only with more time left than the first one's start took.
        spent = max((launch["start_s"] for launch in report["launches"]), default=0)
        reason = f"no time left in the step for a second launch (the first one's start took {spent:.0f} s)" if spent and opts.deadline - time.monotonic() < spent + 240 else ""
        reason = report.get("preflight_failed") or reason  # no launch form is left: no other launch, and each film has its row
        began = time.monotonic()
        try:
            while not reason:
                try:
                    launch_films(opts, mock, idents, report, began, forms[0])
                    break
                except (PreflightFailed, bench_launch.LaunchError) as error:
                    if len(forms) == 1 or isinstance(error, SecondInstance):
                        raise
                    # This launch again, and each launch after it, in the next form.
                    print(f"PREFLIGHT next form: {forms[1]} (the {forms[0]} form failed: {getattr(error, 'reason', error)})", flush=True)
                    report.setdefault("forms_not_run", {})[forms.pop(0)] = str(getattr(error, "reason", error))
        except PreflightFailed as error:  # its PREFLIGHT lines are printed: no session, no film, no other launch
            reason = report["preflight_failed"] = f"the preflight failed (launch form {forms[0]}): {error}"
        except bench_launch.LaunchError as error:  # the launcher printed its BENCH-LAUNCH line
            reason = f"the app did not launch: {error.reason}"
        except Exception as error:  # noqa: BLE001  the rows so far still go into the report
            traceback.print_exc()
            reason = f"the tool stopped: {error!r}"
        if reason:
            report["failures"].append(f"page mock {'on' if mock else 'off'}: {reason}")
        done = {row["id"] for row in report["films"]}
        report["films"] += [{"id": i, "status": "not_run", "agent_page_mock": mock, "reason": reason[:800]} for i in idents if i not in done]
    report["launch_form"] = forms[0]
    for row in report["films"]:
        # Why this film is not a film of that form, in the app's or the check's words; not on a film that is of that form.
        other = {form: why for form, why in report.get("forms_not_run", {}).items() if row.get("launch_form") != form}
        if other:
            row["forms_not_run"] = other
    with open(os.path.join(opts.out, "films.json"), "w") as f:
        json.dump(report, f, indent=1)
    made = sum(1 for r in report["films"] if r["status"] == "made")
    print(f"PANE-FILMS made {made} of {len(wanted)} asked; failures {report['failures']}", flush=True)
    return 0 if made == len(wanted) else 2 if made else 1


def launch_films(opts, mock, idents, report, began, form):
    """One launch of the app in the key form `form`, with the agent pages' mock on or off: the preflight, the
    session, then the films of `idents`."""
    env = {"CMUX_NEXT_INPUT_JOURNAL": "1", **({} if mock else {"CMUX_NEXT_AGENT_PANE_MOCK": None}),
           **({"CMUX_NEXT_NO_ACTIVATE": None} if form == "activate" else {})}
    app = bench_launch.BenchApp(os.path.abspath(opts.app), out=opts.out, env=env, log_name=f"app-mock-{int(mock)}.log")
    app.launch()
    facts = {"executable": os.path.basename(app.binary), "agent_page_mock": "CMUX_NEXT_AGENT_PANE_MOCK" in app.launched_env,
             "agent_launch": app.launched_env.get("ACPMUX_AGENT_LAUNCH"), "films": idents, "start_s": 0,
             "launch_form": form, "no_activate": app.launched_env.get("CMUX_NEXT_NO_ACTIVATE") == "1", "preflight": "not run"}
    report["launches"].append(facts)
    try:
        maker = Films(app, opts, mock, form)
        report["redraw_program"], report["stream_program"] = maker.program[0], "ping"
        try:
            facts["activate"] = activate(app, form)
            if form == "activate":
                facts["window"] = place(app)
            link, maker.zoom = preflight(app, maker.st, opts.out, opts.mbps, form, opts.display)
            facts["zoom"] = maker.zoom
        except PreflightFailed as error:
            facts["preflight"] = f"failed: {error}"
            raise
        except Exception as error:  # noqa: BLE001  a fault of a preflight call is a failed preflight too
            print(f"PREFLIGHT tool FAILED: {error!r}", flush=True)
            facts["preflight"] = f"failed: tool: {error!r}"
            raise PreflightFailed(f"tool: {error!r}") from error
        facts["preflight"] = "passed"
        facts["display"] = {k: link.get(k) for k in ("p50_ms", "refresh_ms", "frames")}
        if opts.workspaces:
            facts["session"] = seed(app, opts.workspaces, opts.live_shells, opts.page_url, opts.seed_deadline, opts.out)
            pins = [maker.st.action("palette.toggleWorkspacePin", {"pinned": True}, target=f"workspace:{w['id']}", focus=False)
                    for w in maker.st.workspaces()[:opts.pinned]]
            facts["session"].update(listed_by_the_app=len(maker.st.workspaces()),
                                    pins_refused=sum(1 for r in pins if isinstance(r, dict) and r.get("error")), pins_asked=len(pins))
            print("PANE-FILMS-SESSION " + json.dumps(facts["session"]), flush=True)
        facts["start_s"] = round(time.monotonic() - began, 1)
        for ident in idents:
            report["films"].append(maker.take(next(s for s in FILMS if s["id"] == ident)))
    finally:
        facts["start_s"] = facts["start_s"] or round(time.monotonic() - began, 1)
        app.stop()


if __name__ == "__main__":
    sys.exit(main())
