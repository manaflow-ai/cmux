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
           is one key-down and its repeats (the first after 225 ms, then one each 30 ms).
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

  pane-motion-films.py --app <cmux DEV tag.app> --films kinds [--workspaces N --live-shells K] --out DIR
  pane-motion-films.py --films list
--films: ids with commas, or `kinds` (9 films: T, B, A by D, SD, Z), `mixed`, `plist` (P03 to P23), `extra`
(X01 to X16: each pane action with a default key that has no other film), `all`. Exit 0 = films.json is written;
3 = not run (no app, an id that is not known, no launch).
"""
import argparse, importlib.util, json, os, re, shutil, subprocess, sys, threading, time, traceback

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
REPEAT_DELAY_MS, REPEAT_MS = 225, 30
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


ZOOM = [K("cmd+shift+return"), W(1.6), K("cmd+shift+return")]
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


def key_steps(chord, presses=1, gap_ms=250, repeats=0):
    """`chord` as `debug.key` steps: the modifiers go down first and stay down; each key is pressed `presses` times
    with `gap_ms` from key-down to key-down, each key-down with `repeats` auto-repeats behind it (a held key)."""
    names = chord.split("+")
    mods, keys = [n for n in names if n in MODIFIERS], names[-1].split(",")
    steps = [{"key_code": KEY[m], "down": True, **({"after_ms": 2} if i else {})} for i, m in enumerate(mods)]
    lead = 10
    for _ in range(presses):
        for key in keys:
            steps.append({"key_code": KEY[key], "down": True, "after_ms": lead})
            steps += [{"key_code": KEY[key], "down": True, "after_ms": REPEAT_MS if i else REPEAT_DELAY_MS, "repeat": True} for i in range(repeats)]
            steps.append({"key_code": KEY[key], "down": False, "after_ms": 8})
            lead = max(gap_ms - 8, 1)
    return steps + [{"key_code": KEY[m], "down": False, "after_ms": 2} for m in reversed(mods)]


def label(act):
    """The words of one act for the film's bar, or "" for a wait."""
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


class Films:
    def __init__(self, app, opts, mock):
        self.app, self.opts, self.mock = app, opts, mock
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
            row = {"label": label(act), "at_s": round(time.monotonic() - clock, 3)}
            if act[0] == "keys":
                _, chord, presses, gap, hold = act
                # "tabs": the key-down and its repeats close all but 2 tabs of the pane, so the pane stays.
                repeats = max(1, len(self.st.tabs(workspace, focus)) - 3) if hold == "tabs" else 1 + int((hold * 1000 - REPEAT_DELAY_MS) / REPEAT_MS) if hold else 0
                steps = key_steps(chord, presses, gap, repeats)
                reply = self.app.rpc("debug.key", {"sequence": steps, "key_window": key_window}) or {}
                if reply.get("error") and key_window != "shell":
                    row["refused_as"] = f"{key_window}: {str(reply['error'])[:120]}"
                    reply = self.app.rpc("debug.key", {"sequence": steps, "key_window": "shell"}) or {}
                row.update({k: reply.get(k) for k in ("base_s", "duration_ms", "scheduled", "key_window", "error") if reply.get(k) is not None})
                time.sleep((reply.get("duration_ms") or 0) / 1000 + 0.05)  # the sequence plays in the app for this long
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
        row = {"id": spec["id"], "title": spec["title"], "setup": spec["setup"], "status": "not_run", "crop": spec.get("crop", "window"),
               "keys": ", ".join(filter(None, (label(a) for a in spec["acts"]))), "agent_page_mock": self.mock}
        workspaces, windows = {w["id"] for w in st.workspaces()}, self.windows()
        try:
            if self.left() < 90:
                raise RuntimeError("no time left in the step")
            if spec["setup"] in MOCK_SETUPS and not self.mock:
                raise RuntimeError("this launch has the page mock off: a chat thread streams only under the mock")
            workspace, panes, streams = self.build(spec, row)
            focus = panes[spec.get("focus", 0)]
            # A person's key on a page goes through the page's own window: the film's keys take that path when the
            # focused pane shows a Chromium page.
            key_window = "page" if SETUPS[spec["setup"]][1][spec.get("focus", 0)] == "page" else "shell"
            self.play(spec.get("pre", ()), workspace, panes, focus, key_window, time.monotonic())
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
    parser.add_argument("--thread-rows", type=int, default=2000, help="rows of a chat pane's thread before it streams")
    parser.add_argument("--stream-seconds", type=float, default=25, help="how long a chat pane streams")
    parser.add_argument("--settle", type=float, default=3.0, help="seconds between a film's set-up and its take")
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
    report = {"films": [], "failures": [], "launches": [], "limits": LIMITS, "key_repeat_ms": [REPEAT_DELAY_MS, REPEAT_MS], "mbps": opts.mbps,
              "alt_screen": "not read: no debug call says if a terminal is on its alternate screen"}
    for mock, idents in plan:
        if not idents:
            continue
        # A second launch makes the session again: it starts only with more time left than the first one's start took.
        spent = max((launch["start_s"] for launch in report["launches"]), default=0)
        reason = f"no time left in the step for a second launch (the first one's start took {spent:.0f} s)" if spent and opts.deadline - time.monotonic() < spent + 240 else ""
        began = time.monotonic()
        try:
            if not reason:
                launch_films(opts, mock, idents, report, began)
        except bench_launch.LaunchError as error:  # the launcher printed its BENCH-LAUNCH line
            reason = f"the app did not launch: {error.reason}"
        except Exception as error:  # noqa: BLE001  the rows so far still go into the report
            traceback.print_exc()
            reason = f"the tool stopped: {error!r}"
        if reason:
            report["failures"].append(f"page mock {'on' if mock else 'off'}: {reason}")
        done = {row["id"] for row in report["films"]}
        report["films"] += [{"id": i, "status": "not_run", "agent_page_mock": mock, "reason": reason[:400]} for i in idents if i not in done]
    with open(os.path.join(opts.out, "films.json"), "w") as f:
        json.dump(report, f, indent=1)
    print(f"PANE-FILMS made {sum(1 for r in report['films'] if r['status'] == 'made')} of {len(wanted)} asked; failures {report['failures']}", flush=True)
    return 0 if report["launches"] else 3


def launch_films(opts, mock, idents, report, began):
    """One launch of the app with the agent pages' mock on or off: the session, then the films of `idents`."""
    env = {"CMUX_NEXT_INPUT_JOURNAL": "1", **({} if mock else {"CMUX_NEXT_AGENT_PANE_MOCK": None})}
    app = bench_launch.BenchApp(os.path.abspath(opts.app), out=opts.out, env=env, log_name=f"app-mock-{int(mock)}.log")
    app.launch()
    facts = {"executable": os.path.basename(app.binary), "agent_page_mock": "CMUX_NEXT_AGENT_PANE_MOCK" in app.launched_env,
             "agent_launch": app.launched_env.get("ACPMUX_AGENT_LAUNCH"), "films": idents, "start_s": 0}
    report["launches"].append(facts)
    try:
        maker = Films(app, opts, mock)
        report["redraw_program"], report["stream_program"] = maker.program[0], "ping"
        app.rpc("debug.frames", {"action": "start"})
        time.sleep(1.0)  # 1 s of the app's display link: the rate that the display has for this app
        link = app.rpc("debug.frames", {"action": "stop"}) or {}
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
