#!/usr/bin/env python3
"""browser-video: real-app movies of DevTools open and close (BROWSER VIDEO suite of the video program).

For each theme (an app launch each: `-AppleInterfaceStyle Dark` for dark) and each case `devtools:<dock>:<page>`
(dock right | bottom | window; page light | heavy, served from 127.0.0.1 so no network flakes), it opens a Chromium
tab on the page, scrolls it to y=400, puts DevTools at the dock once (the dock action, then close: the cold open,
recorded as round 0), then per round records the window with the HARNESS recorder (`debug.motion record_*`:
ScreenCaptureKit, every composited frame, host-time stamps) while Cmd-Opt-I opens DevTools (`debug.key`, the app's
own key dispatch) and Cmd-Opt-I closes it. The host time (CLOCK_UPTIME_RAW, CACurrentMediaTime's clock) of each key
send is kept, so the judge (browser-video-judge.py) counts display refreshes from the key to each frame.

Writes to --out: <theme>/<case>-r<N>.mov (+ .frames.json, .scan), rounds.json (key times, page state before, open and
after: innerWidth, innerHeight, scrollY; debug.cef geometry; the window frame), app logs. Prints BROWSER-VIDEO {json}.

Usage (a fleet GUI host through scripts/measure/browser-video.sh; never a person's Mac):
  python3 scripts/cmux-next/browser-video.py --app APP --out DIR [--themes dark,light]
      [--cases devtools:right:light,devtools:bottom:light] [--rounds 5]
"""
import argparse, functools, http.server, json, os, shutil, subprocess, sys, tarfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402

DOCK_ACTION = {"right": "devtools.openDockedRight", "bottom": "devtools.openDocked", "window": "devtools.openInWindow"}


def uptime():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def wait(predicate, seconds, step=0.1):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded poll of the app's socket state
        value = predicate()
        if value:
            return value
        time.sleep(step)  # bench: the poll interval
    return None


def serve(root):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    handler.log_message = lambda *args: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


class Run:
    def __init__(self, opts, theme, base_url):
        self.opts, self.theme, self.base = opts, theme, base_url
        self.out = os.path.join(opts.out, theme)
        os.makedirs(self.out, exist_ok=True)
        args = ["-AppleInterfaceStyle", "Dark"] if theme == "dark" else []
        self.app = BenchApp(opts.app, out=self.out, log_name="app.log", args=args,
                            env={"CMUX_NEXT_NO_ACTIVATE": None, "CMUX_NEXT_HANG_THRESHOLD_MS": "50"},
                            window=(40, 40, 1440, 900))
        self.rounds = []
        self.tabs = {}

    def rpc(self, method, params=None, timeout=60):
        reply = self.app.rpc(method, params, timeout)
        return reply if reply is not None else {}

    def eval(self, script, tab):
        params = {"script": script, **({"tab": tab} if tab else {})}
        reply = self.rpc("browser.page.eval", params) or {}
        return reply.get("value") if isinstance(reply, dict) else None

    def page_state(self, tab):
        value = self.eval("JSON.stringify({w: innerWidth, h: innerHeight, y: scrollY, x: scrollX, dpr: devicePixelRatio,"
                          " dark: matchMedia('(prefers-color-scheme: dark)').matches})", tab)
        try:
            return json.loads(value) if isinstance(value, str) else value
        except ValueError:
            return value

    def geometry(self):
        return {"cef": self.rpc("debug.cef"), "windows": self.rpc("debug.windows"), "focus": self.rpc("debug.focus")}

    def launch(self):
        self.app.launch()
        subprocess.run(["open", self.app.app], capture_output=True, timeout=30)
        active = wait(lambda: (self.rpc("debug.focus") or {}).get("app_active") is True, 15)
        print(f"browser-video: {self.theme} pid {self.app.process.pid} active={bool(active)}", flush=True)
        windows = lambda: (self.rpc("debug.focus") or {}).get("windows") or []
        if not windows():
            self.rpc("action.run", {"action": "newWindow", "origin": "script"})
        wait(windows, 60)

    def open_tab(self, page):
        if page in self.tabs:
            return self.tabs[page]
        url = f"{self.base}/{page}.html"
        reply = self.rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
        tab = ((reply or {}).get("created") or [None])[0]
        title = f"bv {page}"
        if not wait(lambda: self.eval("document.title", tab) == title, 90, 0.25):
            raise SystemExit(f"browser-video: the {page} page never loaded in tab {tab}: {reply}")
        self.tabs[page] = tab
        return tab

    def record(self, path):
        reply = self.rpc("debug.motion", {"action": "record_start", "path": path, "seconds": 20,
                                          "codec": self.opts.codec, "mbps": self.opts.mbps,
                                          "rows": [], "columns": []})  # the movie is judged; no scan lines
        if not isinstance(reply, dict) or reply.get("error") or not reply.get("starting"):
            raise SystemExit(f"browser-video: record_start refused: {reply}")
        if not wait(lambda: (self.rpc("debug.motion", {"action": "record_read"}) or {}).get("capturing"), 15):
            raise SystemExit(f"browser-video: the recording never started: {self.rpc('debug.motion', {'action': 'record_read'})}")
        return reply

    def stop(self):
        stopped = self.rpc("debug.motion", {"action": "record_stop"})
        written = wait(lambda: (lambda r: r if r.get("written") else None)(self.rpc("debug.motion", {"action": "record_read"}) or {}), 60)
        return {"stop": stopped, "read": written}

    def key(self):
        before = uptime()
        reply = self.rpc("debug.key", {"key": "i", "modifiers": ["cmd", "option"]})
        return {"t_send": before, "t_reply": uptime(), "reply": reply}

    def devtools_case(self, dock, page):
        name = f"devtools-{dock}-{page}"
        tab = self.open_tab(page)
        self.eval("scrollTo(0, 400)", tab)
        time.sleep(0.5)
        for index in range(self.opts.rounds + 1):
            movie = os.path.join(self.out, f"{name}-r{index}.mov")
            entry = {"theme": self.theme, "case": name, "dock": dock, "page": page, "round": index, "tab": tab,
                     "movie": os.path.relpath(movie, self.opts.out), "cold": index == 0}
            self.eval("scrollTo(0, 400)", tab)
            time.sleep(0.4)
            entry["state_before"] = self.page_state(tab)
            entry["geometry_before"] = self.geometry()
            entry["record"] = self.record(movie)
            time.sleep(self.opts.lead)
            if index == 0:
                # The cold open puts DevTools at this case's dock (and remembers it); later rounds toggle by key.
                t0 = uptime()
                entry["open"] = {"t_send": t0, "reply": self.rpc("action.run", {"action": DOCK_ACTION[dock], "origin": "user"}),
                                 "t_reply": uptime(), "via": DOCK_ACTION[dock]}
            else:
                entry["open"] = self.key()
            time.sleep(self.opts.hold)
            entry["state_open"] = self.page_state(tab)
            entry["geometry_open"] = self.geometry()
            time.sleep(0.3)
            entry["close"] = self.key()
            time.sleep(self.opts.tail)
            entry["stopped"] = self.stop()
            entry["state_after"] = self.page_state(tab)
            entry["geometry_after"] = self.geometry()
            self.rounds.append(entry)
            print(f"browser-video: {self.theme} {name} r{index}: before {entry['state_before']} open {entry['state_open']} "
                  f"after {entry['state_after']} frames {((entry['stopped'] or {}).get('read') or {}).get('complete')}", flush=True)
            time.sleep(0.6)

    def press(self, label, key, modifiers=(), **extra):
        before = uptime()
        reply = self.rpc("debug.key", {"key": key, "modifiers": list(modifiers), **extra})
        return {"label": label, "t_send": before, "t_reply": uptime(), "via": f"debug.key {'+'.join([*modifiers, key])}",
                "reply": reply}

    def act(self, label, method, params, timeout=60):
        before = uptime()
        reply = self.rpc(method, params, timeout)
        return {"label": label, "t_send": before, "t_reply": uptime(), "via": method, "reply": reply}

    def away_workspace(self):
        """A second workspace (a terminal) to switch to and back from: Cmd-2 and Cmd-1."""
        if getattr(self, "_away", None):
            return
        self.rpc("action.run", {"action": "newTab", "args": {"name": "bv-away", "focus": False}})
        time.sleep(1.0)
        self._away = True

    def events_round(self, name, index, steps, extra=None):
        """Records one movie while `steps` run: each a (pause after, callable returning an event dict)."""
        movie = os.path.join(self.out, f"{name}-r{index}.mov")
        entry = {"theme": self.theme, "case": name, "round": index, "movie": os.path.relpath(movie, self.opts.out),
                 "kind": "events", "events": [], **(extra or {})}
        entry["geometry_before"] = self.geometry()
        entry["record"] = self.record(movie)
        time.sleep(self.opts.lead)
        for pause, step in steps:
            event = step()
            if event:
                entry["events"].append(event)
            time.sleep(pause)
        entry["stopped"] = self.stop()
        entry["geometry_after"] = self.geometry()
        self.rounds.append(entry)
        print(f"browser-video: {self.theme} {name} r{index}: events {[e['label'] for e in entry['events']]} "
              f"frames {((entry['stopped'] or {}).get('read') or {}).get('complete')}", flush=True)
        return entry

    def pane_case(self, page):
        """Item 2: open a browser pane (Opt-Cmd-D), navigate, switch away and back (Cmd-2, Cmd-1), resize it
        (Ctrl-Cmd-Left / Right, the spring), close it (Cmd-W)."""
        self.away_workspace()
        url = f"{self.base}/{page}.html"
        for index in range(1, self.opts.rounds + 1):
            self.rpc("debug.key", {"key": "1", "modifiers": ["cmd"]})  # the first workspace
            time.sleep(0.8)
            state = {}

            def navigate():
                event = self.act("navigate", "browser.page.navigate", {"url": url})
                wait(lambda: self.eval("document.title", None) == f"bv {page}", 30, 0.1)
                self.eval("scrollTo(0, 400)", None)
                state["open"] = self.page_state(None)
                return event

            steps = [
                (1.6, lambda: self.press("open browser pane", "d", ("cmd", "option"))),
                (1.6, navigate),
                (1.0, lambda: self.press("switch away", "2", ("cmd",))),
                (1.2, lambda: self.press("switch back", "1", ("cmd",))),
                (1.0, lambda: self.press("resize left", "left", ("ctrl", "cmd"))),
                (1.0, lambda: self.press("resize right", "right", ("ctrl", "cmd"))),
                (1.2, lambda: self.press("close", "w", ("cmd",))),
            ]
            entry = self.events_round(f"pane-{page}", index, steps, {"page": page})
            entry["state_open"] = state.get("open")
            time.sleep(0.6)

    def agent_case(self, load):
        """Item 3: open an agent chat (palette.newAgentChat), type and send, a streamed reply (debug.agent_pane
        stream), switch away and back while it streams, under `load` (heavy: the heavy page in a split beside it)."""
        self.away_workspace()
        for index in range(1, self.opts.rounds + 1):
            self.rpc("debug.key", {"key": "1", "modifiers": ["cmd"]})  # the first workspace
            time.sleep(0.8)
            if load == "heavy" and index == 1:
                self.rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": f"{self.base}/heavy.html"}, "focus": True})
                time.sleep(3)
            stats = {}

            def type_send():
                agent = lambda action, **p: self.rpc("debug.agent_pane", dict(p, action=action), timeout=30) or {}
                wait(lambda: agent("readiness").get("composer_visible"), 20, 0.05)
                agent("focus_composer")
                for letter in "hello stream":
                    self.rpc("debug.key", {"key": "space" if letter == " " else letter})
                    time.sleep(0.05)
                return self.press("send", "return")

            def stream():
                return self.act("stream", "debug.agent_pane", {"action": "stream", "rows": 400, "seconds": 6,
                                                              "chunk_chars": 24, "chunk_ms": 16}, timeout=30)

            def readiness(label):
                def read():
                    stats[label] = self.rpc("debug.agent_pane", {"action": "readiness"}, timeout=10)
                return read

            steps = [
                (1.8, lambda: self.act("open chat", "action.run", {"action": "palette.newAgentChat", "origin": "user"}, timeout=30)),
                (0.8, type_send),
                (1.5, stream),
                (0.0, readiness("streaming")),
                (0.8, lambda: self.press("switch away", "2", ("cmd",))),
                (1.5, lambda: self.press("switch back", "1", ("cmd",))),
                (2.5, readiness("after")),
                (1.0, lambda: self.press("close", "w", ("cmd",))),
            ]
            entry = self.events_round(f"agent-{load}", index, steps, {"load": load})
            entry["readiness"] = stats
            time.sleep(0.6)

    def end(self):
        self.app.stop()  # debug.quit, then TERM and KILL of the PID it started, then the tag's daemons


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--themes", default="dark")
    parser.add_argument("--cases", default="devtools:right:light")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--lead", type=float, default=0.5, help="s recorded before the open key")
    parser.add_argument("--hold", type=float, default=1.8, help="s from the open key to the page read before the close key")
    parser.add_argument("--tail", type=float, default=1.2, help="s recorded after the close key")
    parser.add_argument("--codec", default="hevc")
    parser.add_argument("--mbps", type=float, default=30)
    parser.add_argument("--tar", help="pack --out into this tar (the fleet artifact)")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    base = serve(os.path.join(HERE, "browser-video-pages"))
    report = {"app": opts.app, "themes": opts.themes, "cases": opts.cases, "rounds": [], "errors": []}
    for theme in opts.themes.split(","):
        run = Run(opts, theme, base)
        try:
            run.launch()
            for case in opts.cases.split(","):
                kind, dock, page = (case.split(":") + ["", ""])[:3] if case.count(":") == 2 else (case.split(":")[0], "", case.split(":")[1])
                if kind == "devtools":
                    run.devtools_case(dock, page)
                elif kind == "pane":
                    run.pane_case(page)
                elif kind == "agent":
                    run.agent_case(page)
        except BaseException as error:  # noqa: BLE001  keep what was recorded; the report names the failure
            report["errors"].append(f"{theme}: {error!r}")
            print(f"browser-video: {theme} failed: {error!r}", flush=True)
        finally:
            report["rounds"] += run.rounds
            run.end()
    with open(os.path.join(opts.out, "rounds.json"), "w") as f:
        json.dump(report, f, indent=1)
    summary = {"rounds": len(report["rounds"]), "errors": report["errors"],
               "frames": [((r.get("stopped") or {}).get("read") or {}).get("complete") for r in report["rounds"]]}
    print("BROWSER-VIDEO " + json.dumps(summary), flush=True)
    if opts.tar:
        os.makedirs(os.path.dirname(os.path.abspath(opts.tar)), exist_ok=True)
        with tarfile.open(opts.tar, "w:gz") as tar:
            tar.add(opts.out, arcname="browser-video")
        print(f"browser-video: packed {os.path.getsize(opts.tar) / 1e6:.1f} MB into {opts.tar}", flush=True)
    sys.exit(1 if not report["rounds"] else 0)


if __name__ == "__main__":
    main()
