#!/usr/bin/env python3
"""Quit and launch bound for cmux-next: a realistic session quits within QUIT_BOUND seconds and
the next launch shows a usable window within its bounds (slow-quit incident, 2026-10-20).

One tagged Debug app (`cmux DEV <tag>.app`), driven only through its real boundaries: the
process, its control socket, its launch-mark pipe (CMUX_NEXT_LAUNCH_MARKS_FD) and a loopback
web server its browser tabs load.

  1. Fresh state for the tag, then one launch that builds a day's session: WORKSPACES workspaces
     of three terminal tabs and a split, Chromium tabs (one page answers beforeunload with a
     question, one spins in beforeunload for 8 s, one keeps a WebSocket and a busy timer), a
     WebKit tab and, when the bundle has acpmux, an agent chat.
  2. For each --quit mode: quit, then launch again (it restores the same session):
       interactive  debug.quit {open: true}: Cmd-Q, the Quit menu, the Dock and the quit Apple
                    event that Restart to Update sends all take this origin (facts read, the
                    incognito question rule);
       scripted     action.run quit (the CLI's `cmux app quit`);
       signal       SIGTERM (dev tooling);
       wedged       debug.quit {wedge_engine_stop: true}, then the interactive quit: the quit's
                    engine stop blocks the main thread for good, as a wedged CefShutdown did
                    (cx-ccjnn). The app must still end within the bound, by its quit deadline.
     The quit is measured from the request to the kernel's exit event (kqueue NOTE_EXIT). While
     it runs, `sample` records the app every SAMPLE_SECONDS into quit-<mode>-<n>.txt.
  3. The launch after it is measured from main() (the loader's time before it is reported): the
     first window frame, the first live terminal frame (interactive), the agent pane's handshake,
     and the main thread's longest stall in the first LAUNCH_WATCH seconds (debug.hangs, threshold
     HANG_MS, with stacks). `sample` records the launch too.
  4. beforeunload: an app quit never shows a page's question, and waits for its handler at most the
     engines' close wait (the quit bound covers it). The pages send a beacon from their handler; a
     beacon during a quit is reported (Chromium's forced close runs the handler), not failed.
  5. --handoff: before the first quit, the bundle's cmux-tui gets another build commit (the same
     bytes otherwise; update-harness/sessions.py), so the launch after it takes the daemon version
     handoff that an update takes: the old daemon exits, the new one adopts every terminal host
     before it answers. That launch's interactive bound covers the adoption (2026-10-20: 113
     terminals took 21 s on a person's Mac). Changes the app bundle given: pass a copy.

Exit 1 when a quit takes longer than --quit-bound, a launch misses --window-bound or
--interactive-bound, a launch stall exceeds --stall-bound, or the restored session has fewer
workspaces or tabs (by kind) than before the first quit. The
report goes to <out>/quit-launch-bound.json; samples and the app's log go to <out>.

  scripts/cmux-next/quit-launch-bound.py --app "<path>/cmux DEV <tag>.app" --out DIR
      [--quit interactive,scripted,signal,wedged] [--rounds 1] [--workspaces 8] [--no-agent]
      [--quit-bound 6] [--window-bound 3] [--interactive-bound 8] [--stall-bound 2000]

GUI host or CI macOS runner only (it launches the app without activation). Ends the tag's
daemons at the end (tag_teardown), also on a failure.
"""
import argparse
import http.server
import importlib.util
import json
import os
import select
import shutil
import signal
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tag_teardown import TagTeardown  # noqa: E402

sys.path.insert(0, os.path.join(HERE, "update-harness"))
from sessions import bundle_commit, patch_build_stamp  # noqa: E402

_spec = importlib.util.spec_from_file_location("bench_startup", os.path.join(HERE, "bench-startup.py"))
bench = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bench)

WINDOW_MARK = "first_window_frame_committed"
TERMINAL_MARK = bench.FINAL_MARK
AGENT_MARK = bench.AGENT_MARK
SAMPLE_SECONDS = 2
LAUNCH_WATCH = 12.0
HANG_MS = 250


def log(*parts):
    print("quit-launch-bound:", *parts, flush=True)


# -- the pages ---------------------------------------------------------------

class Pages:
    """A loopback server for the session's browser tabs. Each page reports its beforeunload."""

    def __init__(self):
        self.beforeunload = []  # (time, page) of every beforeunload beacon
        self.loaded = {}  # page -> count of loads
        self.lock = threading.Lock()
        self.changed = threading.Condition(self.lock)
        pages = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                name = self.path.strip("/").split("?")[0]
                body = pages.html(name).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                data = self.rfile.read(length).decode(errors="replace")
                self.send_response(204)
                self.end_headers()
                kind, _, page = self.path.strip("/").partition("/")
                with pages.changed:
                    if kind == "beforeunload":
                        pages.beforeunload.append((time.time(), page or data))
                    elif kind == "loaded":
                        pages.loaded[page] = pages.loaded.get(page, 0) + 1
                    pages.changed.notify_all()

        class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        self.server = Server(("127.0.0.1", 0), Handler)
        self.origin = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def html(self, name):
        report = f"""
<script>
const page = {json.dumps(name)};
navigator.sendBeacon('/loaded/' + page, page);
addEventListener('beforeunload', (event) => {{
  navigator.sendBeacon('/beforeunload/' + page, page);
  BEFOREUNLOAD
}});
</script>"""
        if name == "ask":
            # Asks "Leave site?" (needs a gesture to show; the handler runs either way).
            handler = "event.preventDefault(); event.returnValue = '';"
        elif name == "spin":
            # A page whose beforeunload never returns in time: a quit that runs it would wait.
            handler = "const end = Date.now() + 8000; while (Date.now() < end) {}"
        elif name == "busy":
            handler = ""
            report += """
<script>
setInterval(() => { let x = 0; for (let i = 0; i < 2e5; i++) x += i; document.title = 'busy ' + x; }, 50);
</script>"""
        else:
            handler = ""
        filler = "".join(f"<p>{name} paragraph {i}</p>" for i in range(200))
        return (f"<!doctype html><title>{name}</title><body><h1>{name}</h1>{filler}"
                + report.replace("BEFOREUNLOAD", handler) + "</body>")

    def wait_loaded(self, names, timeout):
        deadline = time.monotonic() + timeout
        with self.changed:
            while not all(self.loaded.get(n) for n in names):
                left = deadline - time.monotonic()
                if left <= 0:
                    return [n for n in names if not self.loaded.get(n)]
                self.changed.wait(left)
        return []

    def beforeunload_times(self, start, end):
        """{page: seconds after `start`} of each beforeunload beacon in the window."""
        with self.lock:
            return {page: round(at - start, 3) for at, page in self.beforeunload if start <= at <= end}

    def beforeunload_between(self, start, end):
        with self.lock:
            return [page for at, page in self.beforeunload if start <= at <= end]

    def close(self):
        self.server.shutdown()


# -- sampling ----------------------------------------------------------------

class Sampler:
    """`sample <pid> SAMPLE_SECONDS` back to back until the process exits or stop() runs."""

    def __init__(self, pid, out, prefix):
        self.pid, self.out, self.prefix = pid, out, prefix
        self.stopped = threading.Event()
        self.files = []
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        index = 0
        while not self.stopped.is_set() and bench.wait_exit([self.pid], 0) is False:
            path = os.path.join(self.out, f"{self.prefix}-{index}.txt")
            done = subprocess.run(["/usr/bin/sample", str(self.pid), str(SAMPLE_SECONDS), "1", "-mayDie", "-file", path],
                                  capture_output=True, text=True)
            if os.path.exists(path):
                self.files.append(path)
            elif done.returncode != 0:
                break
            index += 1

    def stop(self):
        self.stopped.set()
        self.thread.join(SAMPLE_SECONDS + 10)
        return self.files


def main_thread_top(path, depth=14):
    """The main thread's heaviest path in a sample file (the first chain of the call graph,
    which `sample` sorts by count), leaf first; cmux, Chromium and wait frames only when any."""
    try:
        with open(path) as f:
            text = f.read()
    except OSError:
        return []
    start = text.find("com.apple.main-thread")
    if start < 0:
        return []
    chain, last = [], -1
    for line in text[start:].splitlines()[1:]:
        body = line.lstrip(" +!:|")
        if not body or not body[0].isdigit():
            break
        level = len(line) - len(body)
        if level <= last:
            break
        last = level
        chain.append(body[:220])
    chain.reverse()
    keep = [l for l in chain if any(k in l for k in ("CmuxNext", "cmux", "Chromium", "cef_", "wait", "trap", "semaphore"))]
    return (keep or chain)[:depth]


# -- the app -----------------------------------------------------------------

class Session:
    def __init__(self, opts):
        self.opts = opts
        self.app = os.path.abspath(opts.app)
        self.tag = bench.app_tag(self.app)
        bench.APPS[self.tag] = self.app
        self.socket = f"/tmp/cmux-debug-{self.tag}.sock"
        self.scratch = tempfile.mkdtemp(prefix=f"quit-launch-bound-{self.tag}-")
        with open(os.path.join(self.scratch, "cmux.json"), "w") as f:
            json.dump({}, f)
        self.env = {"CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1440,900", "CMUX_NEXT_HANG_THRESHOLD_MS": str(HANG_MS),
                    "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(self.scratch, "chief")}
        self.launch = None
        self.teardown = TagTeardown(self.app)
        self.has_agent = False

    def start(self):
        if os.path.exists(self.socket):
            os.unlink(self.socket)
        self.launch = bench.Launch(self.tag, self.scratch, extra_env=self.env)
        return self.launch

    def client(self):
        return bench.app_client(self.tag)

    def call(self, method, params=None):
        client = self.client()
        try:
            return client.call(method, params or {})
        finally:
            client.close()

    def action(self, name, args=None, target=None):
        params = {"action": name, "args": args or {}, "origin": "script", "focus": True}
        if target:
            params["target"] = target
        reply = self.call("action.run", params)
        if not reply.get("ok"):
            log(f"action {name} -> {reply.get('error')}")
        return reply

    def seed(self, pages):
        """A day's work in the tag's state (the first launch); returns what it made."""
        from bench_cli_storm import Client  # noqa: E402
        launch = self.launch
        if not launch.wait_for([TERMINAL_MARK, AGENT_MARK], 180, any_of=True):
            raise SystemExit("the seeding launch never drew a terminal")
        daemon = Client(bench.daemon_socket(self.tag), timeout=10)

        def workspaces():
            return {w["id"]: w for w in daemon.call("list-workspaces", cmd_key="cmd")["data"]["workspaces"]}

        for index in range(self.opts.workspaces):
            before = workspaces()
            created = daemon.call("new-workspace", {"name": f"project-{index + 1:02d}"}, cmd_key="cmd")
            if not created.get("ok"):
                raise SystemExit(f"new-workspace failed: {created.get('error')}")
            workspace = next(w for key, w in workspaces().items() if key not in before)
            pane = workspace["screens"][0]["panes"][0]
            for _ in range(2):
                daemon.call("new-tab", {"pane": pane["id"]}, cmd_key="cmd")
            daemon.call("split", {"pane": pane["id"], "dir": "right"}, cmd_key="cmd")
        daemon.close()
        # Home shows at a first launch and a page has no tabs: go to a workspace with a pane first.
        self.action("workspace.selectFirst")
        names = ["ask", "spin", "busy", "plain"]
        replies = {}
        for name in names:
            replies[name] = self.action("openBrowser.chromium", {"url": f"{pages.origin}/{name}"})
            # One at a time: each page loads (its beacon) before the next tab covers it.
            pages.wait_loaded([name], 45)
        replies["webkit"] = self.action("openBrowser.webkit", {"url": f"{pages.origin}/webkit"})
        missing = pages.wait_loaded(names + ["webkit"], 45)
        if missing:
            raise SystemExit(f"browser tabs never loaded: {missing}; replies {json.dumps(replies)[:1500]}")
        if not self.opts.no_agent:
            reply = self.action("palette.newAgentChat")
            self.has_agent = bool(reply.get("ok")) and launch.wait_for(AGENT_MARK, 60)
            if not self.has_agent:
                log("the agent chat did not load; the session has no agent pane")
        tabs = (self.call("browser.page.tabs", {"all": True}).get("result") or {}).get("tabs") or []
        return {"workspaces": self.opts.workspaces, "terminals": self.opts.workspaces * 4,
                "browser_tabs": len(tabs), "agent": self.has_agent}

    def census(self):
        """{workspaces, tabs by kind} of the app's local session (snapshot.get topology)."""
        topology = (self.call("snapshot.get").get("result") or {}).get("topology") or {}
        kinds = {}
        workspaces = topology.get("workspaces", [])
        for workspace in workspaces:
            for screen in workspace.get("screens", []):
                for pane in screen.get("panes", []):
                    for tab in pane.get("tabs", []):
                        kind = str(tab.get("kind") or "?")
                        kinds[kind] = kinds.get(kind, 0) + 1
        return {"workspaces": len(workspaces), "tabs": kinds}

    def restored(self, before, timeout=LAUNCH_WATCH):
        """The census once it holds every workspace and tab of `before`, else the last one read.
        A restore fills in as the daemon answers; this waits for it, one read per second at most."""
        deadline = time.monotonic() + timeout
        while True:
            now = self.census()
            whole = now["workspaces"] >= before["workspaces"] and all(
                now["tabs"].get(kind, 0) >= count for kind, count in before["tabs"].items())
            if whole or time.monotonic() >= deadline:
                return now, whole
            select.select([], [], [], 1.0)  # a re-read cadence for a result that arrives by itself, not a sync

    def quit(self, mode, pages, out, label):
        """Quits the running launch by `mode`; returns its numbers."""
        launch = self.launch
        pid = launch.process.pid
        sampler = Sampler(pid, out, f"quit-{label}")
        started = time.time()
        if mode in ("interactive", "wedged"):
            if mode == "wedged":
                armed = self.call("debug.quit", {"wedge_engine_stop": True})
                if not ((armed.get("result") or {}).get("wedges_engine_stop")):
                    raise SystemExit(f"debug.quit did not arm the engine-stop wedge: {armed}")
            reply = self.call("debug.quit", {"open": True})
            # QUIT P0: a quit with local terminals asks how to quit; answer its default (Keep Sessions), as Return.
            ask_end = time.time() + 10
            while time.time() < ask_end:
                try:
                    asking = self.call("debug.quit", {}).get("result") or {}
                except (OSError, ValueError, SystemExit):
                    break  # the app is gone or going (app_client exits after its own timeout): nothing asks
                if asking.get("asking"):
                    self.call("debug.quit", {"press": "keep"})
                    break
                time.sleep(0.1)
        elif mode == "scripted":
            reply = self.call("action.run", {"action": "quit", "args": {}, "origin": "script"})
        else:
            os.kill(pid, signal.SIGTERM)
            reply = {"ok": True}
        exited = bench.wait_exit([pid], max(self.opts.quit_bound * 4, 60))
        ended = time.time()
        files = sampler.stop()
        if not exited:
            # Over every bound: record the stack, then end it so the run can report.
            log(f"quit {label}: still running after {ended - started:.1f} s; stopping pid {pid}")
            bench.stop([pid], timeout=10)
        launch.process.wait()
        # The marks the quit wrote: the pipe ends (EOF) with the process.
        launch.wait_for("quit.never", 2)
        os.close(launch.read_fd)
        quit_marks = {k: v for k, v in launch.marks.items() if k.startswith("quit.")}
        result = {"mode": mode, "seconds": round(ended - started, 3), "exited": exited, "reply_ok": reply.get("ok", True),
                  "exit_code": launch.process.returncode, "quit_marks_ms": quit_marks,
                  "beforeunload_pages": pages.beforeunload_between(started, ended + 1),
                  "beforeunload_at_s": pages.beforeunload_times(started, ended + 1),
                  "samples": [{"file": os.path.basename(f), "main": main_thread_top(f)} for f in files]}
        self.launch = None
        return result

    def measure_launch(self, out, label):
        launch = self.start()
        sampler = Sampler(launch.process.pid, out, f"launch-{label}")
        launch.wait_for(WINDOW_MARK, LAUNCH_WATCH * 2)
        # Interactive: the first live terminal frame (a terminal takes input). The agent pane's
        # handshake is reported, not bounded: it can come long before the terminals (a daemon
        # that still adopts its terminal hosts).
        launch.wait_for([TERMINAL_MARK] + ([AGENT_MARK] if self.has_agent else []), LAUNCH_WATCH * 2)
        # The main thread's stalls during the restore: read after LAUNCH_WATCH seconds of the process.
        watch_left = LAUNCH_WATCH - (launch.marks.get(WINDOW_MARK, 0) / 1000)
        if watch_left > 0:
            select.select([], [], [], watch_left)  # measurement window only, not a synchronization
        sampler.stop()
        hangs = (self.call("debug.hangs").get("result") or {}).get("records") or []
        stalls = sorted(({"ms": round(r.get("duration_ms", 0), 1),
                          "frames": [f for f in r.get("frames", []) if "cmux" in f or "CmuxNext" in f][:10] or r.get("frames", [])[:10]}
                         for r in hangs), key=lambda s: -s["ms"])
        # Bounds count from main(): the loader's time before it (dyld, the signature check of a bundle
        # signed a moment ago) is the OS's, and is reported as main_start_ms.
        start = launch.marks.get("main_start", 0)

        def since_main(mark):
            return None if mark not in launch.marks else round(launch.marks[mark] - start, 1)
        return {"window_ms": since_main(WINDOW_MARK), "interactive_ms": since_main(TERMINAL_MARK),
                "main_start_ms": launch.marks.get("main_start"),
                "agent_ms": since_main(AGENT_MARK),
                "longest_stall_ms": stalls[0]["ms"] if stalls else 0, "stalls": stalls[:5],
                "marks": launch.marks, "samples": sampler.files and [os.path.basename(f) for f in sampler.files]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="quit-launch-bound-"))
    ap.add_argument("--quit", default="interactive,scripted,signal,wedged")
    ap.add_argument("--rounds", type=int, default=1)
    ap.add_argument("--workspaces", type=int, default=8)
    ap.add_argument("--no-agent", action="store_true")
    ap.add_argument("--handoff", action="store_true",
                    help="the first relaunch takes the daemon version handoff (changes the bundle's cmux-tui)")
    ap.add_argument("--quit-bound", type=float, default=6.0,
                    help="seconds from the quit request to the process exit (the app's own deadline is 4 s after the "
                         "quit is decided; an interactive quit reads its facts for up to 1 s before that)")
    ap.add_argument("--window-bound", type=float, default=3.0, help="seconds from main() to the first window frame")
    ap.add_argument("--interactive-bound", type=float, default=8.0,
                    help="seconds from main() to the first live terminal frame")
    ap.add_argument("--stall-bound", type=float, default=2000, help="ms: the longest main-thread stall in the launch")
    ap.add_argument("--launch-advisory", action="store_true",
                    help="launch bounds only warn (a CI host over its load threshold); the quit bound still fails")
    opts = ap.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    session = Session(opts)
    session.teardown.install()
    pages = Pages()
    report = {"app": session.app, "tag": session.tag, "bounds": {"quit_s": opts.quit_bound, "window_s": opts.window_bound,
              "interactive_s": opts.interactive_bound, "stall_ms": opts.stall_bound}, "quits": [], "launches": []}
    failures, warnings = [], []
    try:
        bench.reset_state(session.tag)
        session.start()
        report["session"] = session.seed(pages)
        report["census"] = session.census()
        log("session", json.dumps(report["session"]), "census", json.dumps(report["census"]))
        if opts.handoff:
            binary = os.path.join(session.app, "Contents/Resources/bin/cmux-tui")
            report["handoff_patch"] = patch_build_stamp(binary, bundle_commit(session.app))
            # The bundle's seal covers its binaries: seal it again (ad hoc), as the update harness does.
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none",
                            "--preserve-metadata=entitlements,requirements,flags,runtime", session.app],
                           check=True, capture_output=True)
            log("handoff: the bundle's cmux-tui has another build commit", report["handoff_patch"])
        for round_index in range(opts.rounds):
            for mode in opts.quit.split(","):
                label = f"{mode}-{round_index}"
                quit_result = session.quit(mode, pages, opts.out, label)
                report["quits"].append(quit_result)
                log(f"quit {label}: {quit_result['seconds']} s exited={quit_result['exited']} "
                    f"beforeunload={quit_result['beforeunload_at_s']} marks={quit_result['quit_marks_ms']}")
                if not quit_result["exited"] or quit_result["seconds"] > opts.quit_bound:
                    failures.append(f"quit {label} took {quit_result['seconds']} s (bound {opts.quit_bound} s)")
                    for sample in quit_result["samples"]:
                        log(f"  {sample['file']}: " + " <- ".join(sample["main"][:8]))
                if quit_result["beforeunload_pages"]:
                    # Chromium's forced close (cmux_shim_close_all) runs a page's beforeunload handler and
                    # never shows its question; the quit waits for it at most QuitDeadline.engineCloseWait,
                    # which the quit bound covers. Recorded, not failed.
                    warnings.append(f"quit {label} ran beforeunload (no prompt) in {quit_result['beforeunload_pages']}")
                launch_result = session.measure_launch(opts.out, label)
                launch_result["after"] = label
                census, whole = session.restored(report["census"])
                launch_result["census"] = census
                if not whole:
                    failures.append(f"launch after {label}: the restored session lost work: {census} "
                                    f"(before the quit: {report['census']})")
                launch_result["handoff"] = bool(opts.handoff and round_index == 0 and mode == opts.quit.split(",")[0])
                report["launches"].append(launch_result)
                log(f"launch after {label}: main() at {launch_result['main_start_ms']} ms, then window "
                    f"{launch_result['window_ms']} ms, terminal {launch_result['interactive_ms']} ms, agent "
                    f"{launch_result['agent_ms']} ms, longest stall {launch_result['longest_stall_ms']} ms")
                for stall in launch_result["stalls"][:3]:
                    log(f"  stall {stall['ms']} ms: " + " <- ".join(stall["frames"][:6]))
                launch_failures = failures if not opts.launch_advisory else warnings
                if launch_result["window_ms"] is None or launch_result["window_ms"] > opts.window_bound * 1000:
                    launch_failures.append(f"launch after {label}: first window frame {launch_result['window_ms']} ms "
                                    f"(bound {opts.window_bound * 1000:.0f} ms)")
                if launch_result["interactive_ms"] is None or launch_result["interactive_ms"] > opts.interactive_bound * 1000:
                    launch_failures.append(f"launch after {label}: interactive {launch_result['interactive_ms']} ms "
                                    f"(bound {opts.interactive_bound * 1000:.0f} ms)")
                if launch_result["longest_stall_ms"] > opts.stall_bound:
                    launch_failures.append(f"launch after {label}: main-thread stall {launch_result['longest_stall_ms']} ms "
                                    f"(bound {opts.stall_bound:.0f} ms)")
        # The last launch ends its sessions so nothing of the tag stays.
        if session.launch:
            session.call("debug.quit", {"fixture_quit": "end-sessions"})
            bench.wait_exit([session.launch.process.pid], 30)
    finally:
        if session.launch and session.launch.process.poll() is None:
            bench.stop([session.launch.process.pid], timeout=20)
        session.teardown.end()
        pages.close()
        report["failures"] = failures
        report["warnings"] = warnings
        with open(os.path.join(opts.out, "quit-launch-bound.json"), "w") as f:
            json.dump(report, f, indent=1)
        shutil.rmtree(session.scratch, ignore_errors=True)
    log("report", os.path.join(opts.out, "quit-launch-bound.json"))
    for warning in warnings:
        log("WARN", warning)
    for failure in failures:
        log("FAIL", failure)
    if failures:
        sys.exit(1)
    log("ok: every quit and launch within its bounds")


if __name__ == "__main__":
    main()
