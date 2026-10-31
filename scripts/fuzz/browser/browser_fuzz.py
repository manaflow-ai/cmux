#!/usr/bin/env python3
"""Browser fuzz of cmux-next's Chromium (CEF) tabs (fuzz catalog row k), against a tagged app.

  python3 scripts/fuzz/browser/browser_fuzz.py --app "cmux DEV <tag>.app" [--minutes 20] [--seed S] [--ops 150]
      [--replay repro.json] [--shrink-replays 6] [--out DIR]

Launches the tagged app with a scratch HOME and config (bench_memory.launch, direct: a fleet step has no
LaunchServices session), serves its own pages on 127.0.0.1, and runs seeded op sequences (fuzz_model.generate)
through the app's socket, as an agent or script does (origin "script"), plus the person's omnibar
(debug.omnibar_type): opens, navigations to valid, malformed, huge, odd-scheme and IDN URLs, Back/Forward/Reload,
redirect chains, open/close/move storms across panes, workspaces and windows, DevTools open and close, downloads
with odd file names, and renderer crashes (kill -9 of a renderer this run's app started, chrome://crash typed
by the person, a page that runs out of memory).

Oracles, after every op (fuzz_model has the pure parts):
  app_crash        the app process still runs and answers its socket;
  no_answer        every socket call answers within --answer-timeout (a typed error is an answer);
  stall            no main-thread stall over 100 ms (debug.hangs records since the op began). In a Debug build
                   (the default) a stall is only printed ("BROWSER-FUZZ-STALL {json}") for the stall owners:
                   not shrunk, not in the verdict. With --build-config bench each stall signature is a finding;
  sad_tab          a renderer that died shows the crashed-page view (debug.browser.page_status gone=1);
  url_policy       no javascript:/data: payload runs, no tab commits one, an agent-driven tab never shows a page
                   AgentURLPolicy refuses, and no web page takes a tab to file:, data:, javascript: or chrome://;
  external_open    an agent op never opens another app (recorded: CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1);
  download_path    a download lands in the downloads folder under a plain name, or the app shows a prompt;
  lost_tab         every Chromium tab the run opened and did not close is still in the topology.

A failure stops that seed, quits the app, and is shrunk (fuzz_model.ddmin, each try a fresh launch) within
--shrink-replays; the run then goes on with the next seed until --minutes is spent. Each finding prints one line
"BROWSER-FUZZ-FINDING {json}" (seed, the oracle, the shrunk ops, how often the shrunk ops failed) and the run ends
with "BROWSER-FUZZ-VERDICT PASS|FAIL|NOVERDICT ..." (scripts/fuzz/browser/verdict.py reads it). Exits 1 on FAIL.
Ends every process of the bundle it launched, and deletes the downloads it made, at the end.
"""
from __future__ import annotations

import argparse
import glob
import http.server
import json
import os
import pwd
import random
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "..", "cmux-next"))
import fuzz_model as model  # noqa: E402

# The DevTools stall owner named in handoff/fuzz-catalog.md row k; a DevTools stall finding names it.
DEVTOOLS_OWNER = "the DevTools main-thread stall owner (fuzz catalog row k)"


class Failure(Exception):
    def __init__(self, oracle: str, detail: str, op_index: int, extra: dict | None = None):
        super().__init__(f"{oracle}: {detail}")
        self.oracle, self.detail, self.op_index, self.extra = oracle, detail, op_index, extra or {}


# ---------------------------------------------------------------- the run's own web server

class LocalSite:
    """Pages for the corpus's "{origin}" paths. One per process; each run's ops name its origin."""

    def __init__(self):
        site = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):  # noqa: N802 (http.server's name)
                try:
                    site.serve(self)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.origin = f"http://localhost:{self.port}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    @staticmethod
    def send(h, code: int, body: bytes = b"", ctype: str = "text/html; charset=utf-8", headers: dict | None = None):
        h.send_response(code)
        for name, value in (headers or {}).items():
            h.send_header(name, value)
        if code not in (204, 304):
            h.send_header("Content-Type", ctype)
            h.send_header("Content-Length", str(len(body)))
        h.end_headers()
        if code not in (204, 304) and h.command != "HEAD":
            h.wfile.write(body)

    def serve(self, h):
        url = urllib.parse.urlsplit(h.path)
        q = {k: v[-1] for k, v in urllib.parse.parse_qs(url.query, keep_blank_values=True).items()}
        path = url.path
        page = lambda title, body="": f"<!doctype html><meta charset=utf-8><title>{title}</title><body>{body}".encode()  # noqa: E731
        if path == "/page":
            self.send(h, 200, page(f"fuzz page {q.get('id', '')}", "<p id=alive>alive</p><a href='/page?id=link'>next</a>"))
        elif path == "/slow":
            time.sleep(min(int(q.get("ms", "0") or 0), 10_000) / 1000)
            self.send(h, 200, page("fuzz slow"))
        elif path == "/big":
            kb = min(int(q.get("kb", "1") or 1), 16_384)
            self.send(h, 200, page("fuzz big", "<p>" + ("lorem ipsum " * 85 + "</p><p>") * kb))
        elif path == "/redirect":
            n = int(q.get("n", "1") or 1)
            to = q.get("to", "/page")
            target = f"/redirect?n={n - 1}&to={urllib.parse.quote(to, safe='')}" if n > 1 else to
            self.send(h, 302, b"", headers={"Location": target})
        elif path == "/redirect-loop":
            self.send(h, 302, b"", headers={"Location": "/redirect-loop"})
        elif path == "/meta":
            to = json.dumps(q.get("to", "/page"))[1:-1].replace("<", "%3C").replace('"', "%22")
            self.send(h, 200, f'<!doctype html><title>fuzz meta</title><meta http-equiv="refresh" content="0;url={to}">'.encode())
        elif path == "/script-nav":
            self.send(h, 200, f"<!doctype html><title>fuzz script-nav</title><script>location.href = {json.dumps(q.get('to', '/page'))}</script>".encode())
        elif path == "/status":
            code = int(q.get("code", "200") or 200)
            self.send(h, code, page(f"fuzz status {code}") if code not in (204, 304) else b"",
                      headers={"Location": "/page?id=status"} if 300 <= code < 400 else None)
        elif path == "/popups":
            n = min(int(q.get("n", "1") or 1), 20)
            self.send(h, 200, page("fuzz popups", f"<script>for (let i = 0; i < {n}; i++) window.open('/page?id=popup' + i)</script>"))
        elif path == "/history":
            n = min(int(q.get("n", "1") or 1), 50)
            self.send(h, 200, page("fuzz history", f"<script>for (let i = 0; i < {n}; i++) history.pushState({{i}}, '', '?h=' + i)</script>"))
        elif path == "/beforeunload":
            self.send(h, 200, page("fuzz beforeunload", "<script>addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = '' })</script>"))
        elif path == "/oom":
            self.send(h, 200, page("fuzz oom", "<script>const keep = []; (function grow() { for (let i = 0; i < 64; i++) keep.push(new Array(1 << 20).fill(i)); setTimeout(grow, 0) })()</script>"))
        elif path == "/download":
            kb = min(int(q.get("kb", "1") or 1), 65_536)
            name = q.get("name", "fuzz.bin")
            # RFC 5987: Chromium decodes the name, so its own sanitising sees ../, controls and RTL marks;
            # this server's header stays one line.
            disposition = "attachment; filename=\"fuzz.bin\"; filename*=UTF-8''" + urllib.parse.quote(name, safe="")
            self.send(h, 200, os.urandom(1024) * kb, ctype="application/octet-stream", headers={"Content-Disposition": disposition})
        else:
            self.send(h, 404, page("fuzz 404"))


# ---------------------------------------------------------------- one app launch

def rpc(sock: str, method: str, params: dict | None = None, timeout: float = 30.0) -> tuple[dict, float, bool]:
    """(result or {"error": ...}, seconds, timed_out). A typed error is an answer; a timeout is not."""
    started = time.monotonic()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(sock)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf or b"{}")
    except socket.timeout:
        return {"error": f"no answer in {timeout:.0f} s"}, time.monotonic() - started, True
    except (OSError, ValueError) as error:
        return {"error": str(error)}, time.monotonic() - started, False
    if not reply.get("ok", "result" in reply):
        return {"error": reply.get("error") or "error"}, time.monotonic() - started, False
    result = reply.get("result")
    return (result if isinstance(result, dict) else {"value": result}), time.monotonic() - started, False


def children(parent: int, kind: str) -> set[int]:
    out = subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    found = set()
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] == str(parent) and f"--type={kind}" in parts[2]:
            found.add(int(parts[0]))
    return found


class Session:
    """One launch of the app and the ops run on it."""

    def __init__(self, opts, site: LocalSite, run_token: str, log):
        import bench_memory  # scripts/cmux-next: launch, end_bundle
        self.bm = bench_memory
        self.opts, self.site, self.run, self.log = opts, site, run_token, log
        extra = {"CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS": "1", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                 "CMUX_NEXT_HANG_THRESHOLD_MS": "50"}
        self.started = time.time()
        self.pid, self.sock, self.scratch = bench_memory.launch(opts.app, {}, extra, direct=True)
        self.home = os.path.join(self.scratch, "home")
        self.tabs: list[str] = []
        self.closed: set[str] = set()
        self.cursor = 0
        self.windows_made = 0
        self.notes: list[str] = []
        self.stalls: dict[str, Failure] = {}
        self.download_tokens: set[str] = {run_token}
        self.script_nav_tabs: set[str] = set()  # tabs that loaded /script-nav: the page runs its own script
        self.counts = {"ops": 0, "renderer_kills": 0, "sad_tabs": 0, "downloads": 0, "devtools": 0, "refused": 0, "no_renderer": 0, "no_verdict": 0}

    # -- plumbing

    def call(self, method: str, params: dict | None = None, *, index: int, timeout: float | None = None) -> dict:
        result, seconds, timed_out = rpc(self.sock, method, params, timeout or self.opts.answer_timeout)
        if timed_out:
            raise Failure("no_answer", f"{method} {json.dumps(params)[:300]} gave no answer in {seconds:.0f} s", index)
        if "error" in result and self.app_gone():
            raise Failure("app_crash", f"the app process {self.pid} ended during {method}", index, {"crash_reports": self.crash_reports()})
        return result

    def action(self, action: str, *, index: int, target: str | None = None, args: dict | None = None, focus: bool = False) -> dict:
        params = {"action": action, "args": args or {}, "wait": True, "origin": "script",
                  "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
        if target:
            params["target"] = target
        if focus:
            params["focus"] = True
        return self.call("action.run", params, index=index)

    def app_gone(self) -> bool:
        try:
            os.kill(self.pid, 0)
            return False
        except ProcessLookupError:
            return True
        except PermissionError:
            return False

    def crash_reports(self) -> list[str]:
        """Crash reports of the app binary written since this launch (the account's real home)."""
        real = pwd.getpwuid(os.getuid()).pw_dir
        found = []
        for path in glob.glob(os.path.join(real, "Library/Logs/DiagnosticReports", "cmux*")):
            if os.path.getmtime(path) >= self.started:
                found.append(path)
        return sorted(found)

    def hang_cursor(self):
        reading = self.call("debug.hangs", {"after": self.cursor, "limit": 200}, index=-1)
        for record in reading.get("records") or []:
            self.cursor = max(self.cursor, int(record.get("sequence") or 0))

    def settle_launch(self):
        methods = set((self.call("system.identify", {}, index=-1).get("methods") or []))
        # page_status and external_opens are DEBUG-only; a bench build lacks them (those oracles then give no verdict).
        self.has = {m: m in methods for m in ("debug.browser.page_status", "debug.browser.external_opens", "debug.downloads",
                                               "debug.omnibar_type", "debug.hangs", "debug.browser.prompts", "debug.dialog")}
        missing = [m for m, ok in self.has.items() if not ok]
        if missing:
            self.notes.append(f"this build has no {', '.join(missing)}: their oracles give no verdict")
        # Leave Home (a first launch) for a workspace with a pane, as downloads-live.py does.
        self.action("workspace.selectFirst", index=-1)
        self.action("newTab", index=-1, focus=True)
        time.sleep(2)  # the app's launch work ends; its stalls are not this run's
        self.hang_cursor()

    def close(self):
        try:
            rpc(self.sock, "action.run", {"action": "quitEndSessions", "origin": "script"}, 10)
        except Exception:  # noqa: BLE001 (best effort: end_bundle follows)
            pass
        self.bm.end_bundle(self.opts.app)
        import shutil
        shutil.rmtree(self.scratch, ignore_errors=True)
        real = pwd.getpwuid(os.getuid()).pw_dir
        for folder in (os.path.join(real, "Downloads"), os.path.join(self.home, "Downloads")):
            for token in self.download_tokens:
                for path in glob.glob(os.path.join(folder, f"{glob.escape(token)}-*")):
                    try:
                        os.remove(path)
                    except OSError:
                        pass

    # -- model

    def live(self) -> list[str]:
        return [t for t in self.tabs if t not in self.closed]

    def slot(self, op: dict, index: int) -> str:
        tabs = self.live()
        if not tabs:
            self.open_tab(self.site.origin + "/page?id=auto", index)
            tabs = self.live()
        if not tabs:
            raise Failure("no_answer", "openBrowser.chromium opened no tab for an op that needs one", index)
        return tabs[int(op.get("slot", 0)) % len(tabs)]

    def open_tab(self, url: str, index: int, focus: bool = True) -> dict:
        reply = self.action("openBrowser.chromium", index=index, args={"url": url}, focus=focus)
        # `created` lists every object the run made (a pane or workspace too); only tabs are the run's tabs.
        reply["created"] = [t for t in reply.get("created") or [] if isinstance(t, str) and t.startswith("tab_")]
        self.tabs.extend(reply["created"])
        return reply

    def topology_tabs(self) -> dict[str, str] | None:
        snap = self.call("snapshot.get", {}, index=-1)
        topology = snap.get("topology") or {}
        if not isinstance(topology.get("workspaces"), list):
            return None
        out = {}
        for ws in topology["workspaces"]:
            for screen in ws.get("screens") or []:
                for pane in screen.get("panes") or []:
                    for tab in pane.get("tabs") or []:
                        out[tab.get("id")] = ws.get("id")
        return out

    def workspaces(self) -> list[str]:
        snap = self.call("snapshot.get", {}, index=-1)
        return [w.get("id") for w in (snap.get("topology") or {}).get("workspaces") or [] if w.get("id")]

    def state(self, tab: str, index: int) -> dict:
        return self.call("browser.page.state", {"tab": tab}, index=index)

    def pane_of(self, tab: str, index: int) -> str | None:
        snap = self.call("snapshot.get", {}, index=index)
        for ws in (snap.get("topology") or {}).get("workspaces") or []:
            for screen in ws.get("screens") or []:
                for pane in screen.get("panes") or []:
                    if any(t.get("id") == tab for t in pane.get("tabs") or []):
                        return pane.get("id")
        return None

    def pane_action(self, action: str, tab: str, index: int) -> dict:
        """A pane-target browser action (DevTools, Hard Reload, Stop) on the pane that shows `tab`, after showing it."""
        self.action("tab.focus", index=index, target=f"tab:{tab}", focus=True)
        pane = self.pane_of(tab, index)
        reply = self.action(action, index=index, target=f"pane:{pane}" if pane else None, focus=True)
        if "error" in reply:
            self.notes.append(f"op {index}: {action} refused: {str(reply.get('error'))[:160]}")
        return reply

    def type_in_omnibar(self, tab: str, text: str, index: int) -> bool:
        """Types `text` into the omnibar of the pane that shows `tab` and commits it, as a person does. The pane is
        looked up in every window (debug.omnibar_type reads the first window unless it is named)."""
        self.action("tab.focus", index=index, target=f"tab:{tab}", focus=True)
        pane = self.pane_of(tab, index)
        windows = [w.get("id") for w in self.call("debug.focus", {}, index=index).get("windows") or [] if w.get("id")]
        for window in windows or [None]:
            params = {"text": text, **({"window": window} if window else {}), **({"pane": pane} if pane else {})}
            reply = self.call("debug.omnibar_type", params, index=index)
            if reply.get("typed"):
                return True
        self.notes.append(f"op {index}: no window's omnibar took the text for {tab} (pane {pane})")
        return False

    def page_status(self, tab: str, index: int, press: str | None = None) -> dict:
        params = {"tab": tab}
        if press:
            params["press"] = press
        reply = self.call("debug.browser.page_status", params, index=index)
        return reply if isinstance(reply, dict) else {}

    # -- oracles shared by every op

    def check_alive(self, index: int):
        if self.app_gone():
            raise Failure("app_crash", f"the app process {self.pid} ended", index, {"crash_reports": self.crash_reports()})
        _, seconds, timed_out = rpc(self.sock, "system.ping", {}, self.opts.answer_timeout)
        if timed_out:
            raise Failure("no_answer", f"system.ping gave no answer in {seconds:.0f} s", index)

    def check_stalls(self, op: dict, index: int):
        reading = self.call("debug.hangs", {"after": self.cursor, "limit": 200}, index=index)
        records = reading.get("records") or []
        for record in records:
            self.cursor = max(self.cursor, int(record.get("sequence") or 0))
        # A stall is recorded and the seed goes on (one known stall must not hide the rest); each stall signature
        # (its top app frames) is one finding, shrunk on its own after the seed.
        for record in model.stalls_over(records):
            signature = model.stall_signature(record)
            if signature in self.stalls:
                continue
            owner = DEVTOOLS_OWNER if op["op"] == "devtools" else ""
            self.stalls[signature] = Failure("stall", f"a main-thread stall over {model.STALL_MS:.0f} ms during {op['op']}: "
                                             + model.stall_summary(record), index,
                                             {"signature": signature, "stack": model.stall_summary(record, 16), "owner": owner})

    def check_url(self, tab: str, op: dict, index: int, answered_ok: bool):
        agent = op["op"] != "omnibar"
        url = op.get("url") or ""
        via_web = op.get("category") == "local" and any(p in url for p in ("/redirect", "/meta", "/script-nav"))
        for attempt in range(2):
            state = self.state(tab, index)
            if "error" in state:
                return
            # A page may run its own script (location = "javascript:..." from /script-nav), also again on a later
            # reload, Back or Forward: its title is no finding in a tab that ever loaded /script-nav.
            if "/script-nav" in url or "/script-nav" in (state.get("url") or ""):
                self.script_nav_tabs.add(tab)
            title = "" if tab in self.script_nav_tabs else state.get("title") or ""
            problem = model.committed_url_violation(state.get("url") or "", title, agent_op=agent and answered_ok, via_web=via_web)
            if not problem:
                return
            if attempt == 0:
                time.sleep(1.0)  # confirm: a pending navigation's URL is not a commit
        raise Failure("url_policy", f"{op['op']} {url[:200]!r}: {problem}", index)

    def check_tabs(self, index: int):
        expected = set(self.live())
        for _ in range(10):
            seen = self.topology_tabs()
            if seen is None:
                self.notes.append("snapshot.get has no topology.workspaces: lost_tab not checked")
                return
            missing = sorted(expected - set(seen))
            if not missing:
                return
            time.sleep(0.5)  # a move ends in the daemon a moment after its action answers
        problem = model.tab_count_violation(len(expected), len(expected) - len(missing))
        if problem:
            raise Failure("lost_tab", f"{problem}: {missing[:6]}", index)

    def check_external(self, before: int, op: dict, index: int):
        if not self.has["debug.browser.external_opens"]:
            return
        urls = (self.call("debug.browser.external_opens", {}, index=index).get("urls") or [])
        if len(urls) > before and op["op"] != "omnibar":
            raise Failure("external_open", f"{op['op']} {str(op.get('url'))[:200]!r} opened another app: {urls[before:]}", index)

    # -- ops

    def run_op(self, op: dict, index: int):
        name = op["op"]
        if not self.has["debug.browser.external_opens"] and model.touches_external(op.get("url") or ""):
            # Without the recording build (bench), a product bug here would open a real app: skip the op.
            self.notes.append(f"op {index}: skipped {name} to an external scheme (this build does not record external opens)")
            return
        self.counts["ops"] += 1
        opens_before = len(self.call("debug.browser.external_opens", {}, index=index).get("urls") or []) if self.has["debug.browser.external_opens"] else 0
        url_tab, answered_ok = None, True
        if name == "open":
            reply = self.open_tab(op["url"], index)
            answered_ok = "error" not in reply
            created = [t for t in reply.get("created") or [] if isinstance(t, str)]
            url_tab = created[0] if created else None
            if not answered_ok:
                self.counts["refused"] += 1
        elif name == "navigate":
            url_tab = self.slot(op, index)
            reply = self.call("browser.page.navigate", {"tab": url_tab, "url": op["url"]}, index=index)
            answered_ok = "error" not in reply
            self.counts["refused"] += 0 if answered_ok else 1
        elif name in ("back", "forward", "reload"):
            url_tab = self.slot(op, index)
            reply = self.call(f"browser.page.{name}", {"tab": url_tab}, index=index)
            answered_ok = "error" not in reply
        elif name in ("hard_reload", "stop"):
            self.pane_action("browserHardReload" if name == "hard_reload" else "browserStop", self.slot(op, index), index)
        elif name == "focus":
            self.action("tab.focus", index=index, target=f"tab:{self.slot(op, index)}", focus=True)
        elif name == "omnibar":
            url_tab = self.slot(op, index)
            if not self.has["debug.omnibar_type"]:
                return self.finish(op, index, None, True, opens_before)
            if op.get("category") == "crash":
                self.crash_page(index)
                url_tab = None
            elif not self.type_in_omnibar(url_tab, op["url"], index):
                url_tab = None
        elif name == "close":
            tab = self.slot(op, index)
            reply = self.action("closeTab", index=index, target=f"tab:{tab}")
            if "error" not in reply:
                self.closed.add(tab)
                self.accept_leave_prompt(tab, index)
        elif name == "open_storm":
            self.storm([("open", None)] * int(op.get("n", 5)), index)
        elif name == "close_storm":
            tabs = self.live()
            picks = list(dict.fromkeys(tabs[s % len(tabs)] for s in op.get("seeds", []))) if tabs else []
            self.storm([("close", t) for t in picks], index)
        elif name == "move_storm":
            tabs = self.live()
            moves = ["moveSurfaceToNextPane", "moveSurfaceToPreviousPane", "tab.moveToNewSplit", "palette.moveTabToNewWorkspace"]
            for i, s in enumerate(op.get("seeds", [])):
                if tabs:
                    self.action(moves[(s + i) % len(moves)], index=index, target=f"tab:{tabs[s % len(tabs)]}")
        elif name == "move_next_pane":
            self.action("moveSurfaceToNextPane", index=index, target=f"tab:{self.slot(op, index)}")
        elif name == "move_new_split":
            self.action("tab.moveToNewSplit", index=index, target=f"tab:{self.slot(op, index)}", args={"direction": op.get("direction", "right")})
        elif name == "move_workspace":
            spaces = self.workspaces()
            if spaces:
                self.action("tab.moveToWorkspace", index=index, target=f"tab:{self.slot(op, index)}",
                            args={"workspace": f"workspace:{spaces[int(op.get('to', 0)) % len(spaces)]}"})
        elif name == "move_new_workspace":
            self.action("palette.moveTabToNewWorkspace", index=index, target=f"tab:{self.slot(op, index)}")
        elif name == "move_new_window":
            if self.windows_made < 3:
                self.windows_made += 1
                self.action("tab.moveToNewWindow", index=index, target=f"tab:{self.slot(op, index)}")
        elif name == "new_workspace":
            self.action("newTab", index=index, focus=True)
        elif name == "new_window":
            if self.windows_made < 3:
                self.windows_made += 1
                self.action("newWindow", index=index, focus=True)
        elif name == "devtools":
            tab = self.slot(op, index)
            self.counts["devtools"] += 1
            self.pane_action("toggleBrowserDeveloperTools", tab, index)
            time.sleep(int(op.get("hold_ms", 0)) / 1000)
            self.pane_action("toggleBrowserDeveloperTools", tab, index)
        elif name == "download":
            if self.has["debug.downloads"]:
                self.download(op, index)
        elif name == "kill_renderer":
            self.kill_renderer(op, index)
        elif name == "crash_page":
            if self.has["debug.omnibar_type"]:
                self.crash_page(index)
        elif name == "oom_page":
            tab = self.slot(op, index)
            self.action("tab.focus", index=index, target=f"tab:{tab}", focus=True)
            self.call("browser.page.navigate", {"tab": tab, "url": self.site.origin + "/oom"}, index=index)
            if not self.has["debug.browser.page_status"]:
                time.sleep(5)
            elif not self.wait_gone(tab, index, 90):
                self.notes.append(f"op {index}: the out-of-memory page did not end its renderer in 90 s (no verdict)")
            else:
                self.recover(tab, index, "a page that ran out of memory")
        else:
            raise ValueError(f"unknown op {name}")
        self.finish(op, index, url_tab, answered_ok, opens_before)

    def finish(self, op: dict, index: int, url_tab: str | None, answered_ok: bool, opens_before: int):
        """The oracles every op ends with."""
        name = op["op"]
        time.sleep(int(op.get("settle_ms", 0)) / 1000)
        if url_tab and url_tab in self.live() and name in ("open", "navigate", "back", "forward", "reload", "omnibar"):
            if any(p in (op.get("url") or "") for p in ("/meta", "/script-nav")):
                time.sleep(1.5)  # the page's own navigation runs after its load
            self.check_url(url_tab, op, index, answered_ok)
        self.check_alive(index)
        self.check_stalls(op, index)
        self.check_external(opens_before, op, index)
        if name in ("close", "close_storm", "move_storm", "move_next_pane", "move_new_split", "move_workspace",
                    "move_new_workspace", "move_new_window", "open_storm") or index % 10 == 0:
            self.check_tabs(index)

    def storm(self, work: list[tuple[str, str | None]], index: int):
        """Runs the actions at once, each on its own connection, as several agents would."""
        errors: list[Failure] = []

        def one(kind, tab):
            try:
                if kind == "open":
                    self.open_tab(self.site.origin + f"/page?id=storm{random.randrange(1 << 16)}", index, focus=False)
                elif kind == "close":
                    if "error" not in self.action("closeTab", index=index, target=f"tab:{tab}"):
                        self.closed.add(tab)
            except Failure as failure:
                errors.append(failure)

        threads = [threading.Thread(target=one, args=item) for item in work]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(self.opts.answer_timeout + 5)
        if errors:
            raise errors[0]

    def accept_leave_prompt(self, tab: str, index: int):
        """A page with a beforeunload handler asks before it closes; the run says Leave."""
        for _ in range(6):
            seen = self.topology_tabs()
            if seen is None or tab not in seen:
                return
            dialogs = [] if not self.has["debug.dialog"] else [d for d in self.call("debug.dialog", {}, index=index).get("dialogs") or []
                       if d.get("identifier") == "browser.dialog.beforeunload" and d.get("visible")]
            if dialogs:
                self.call("debug.dialog", {"press": "ok"}, index=index)
            time.sleep(0.5)
        self.closed.discard(tab)  # it stayed: the page held it (a visible question), so it is still the run's tab

    def download(self, op: dict, index: int):
        tab = self.slot(op, index)
        name = op.get("name") or f"{self.run}-fuzz.bin"
        url = self.site.origin + f"/download?kb={int(op.get('kb', 1))}&name={urllib.parse.quote(name, safe='')}"
        self.call("browser.page.navigate", {"tab": tab, "url": url}, index=index)
        # The ops name each download "<run token>-<n>-..." (fuzz_model.generate); cleanup deletes only that prefix.
        token = name.split("-")[0] + "-" + name.split("-")[1] if name.count("-") >= 2 else self.run
        self.download_tokens.add(token)
        deadline = time.monotonic() + 30
        row = None
        while time.monotonic() < deadline:
            rows = self.call("debug.downloads", {}, index=index).get("downloads") or []
            mine = [r for r in rows if token in (r.get("filename") or "") or token in (r.get("destination") or "")]
            row = mine[-1] if mine else None
            if row and row.get("status") != "inProgress":
                break
            if not row and (self.call("debug.browser.prompts", {"tab": tab}, index=index).get("prompts") or []):
                self.notes.append(f"op {index}: the download asked first (a visible prompt)")
                return
            time.sleep(0.5)
        if row is None:
            self.notes.append(f"op {index}: no downloads row for {name[:80]!r} in 30 s (no verdict)")
            return
        self.counts["downloads"] += 1
        real = pwd.getpwuid(os.getuid()).pw_dir
        for folder in (os.path.join(real, "Downloads"), os.path.join(self.home, "Downloads")):
            if os.path.realpath(os.path.dirname(row.get("destination") or "")) == os.path.realpath(folder):
                break
        else:
            folder = os.path.join(real, "Downloads")
        problem = model.download_violation(row, folder)
        if problem:
            raise Failure("download_path", f"{name[:120]!r}: {problem}", index, {"row": row})

    def wait_gone(self, tab: str, index: int, seconds: float) -> dict | None:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            status = self.page_status(tab, index)
            if status.get("gone") == "1":
                return status
            time.sleep(0.25)
        return None

    def expect_sad_tab(self, tab: str, index: int, why: str, seconds: float):
        if self.app_gone():
            raise Failure("app_crash", f"the app ended after {why}", index, {"crash_reports": self.crash_reports()})
        if not self.has["debug.browser.page_status"]:
            self.notes.append(f"op {index}: {why}: no debug.browser.page_status in this build, sad tab not checked")
            return
        status = self.wait_gone(tab, index, seconds)
        if not status and self.page_answers(tab):
            # The page still runs: no renderer of this tab ended (a spare renderer was killed, or the URL did not crash).
            self.counts["no_verdict"] += 1
            self.notes.append(f"op {index}: after {why} the page still answers: no crash of this tab's renderer (no verdict)")
            return
        if not status:
            last = self.page_status(tab, index)
            raise Failure("sad_tab", f"after {why} the tab shows no crashed-page view in {seconds:.0f} s "
                          f"(page_status gone={last.get('gone')!r} error={last.get('error', '')[:120]!r} title={last.get('title', '')[:80]!r})", index)
        self.counts["sad_tabs"] += 1
        self.recover(tab, index, why)

    def recover(self, tab: str, index: int, why: str):
        self.page_status(tab, index, press="reload")
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.page_status(tab, index).get("gone") == "0":
                return
            time.sleep(0.5)
        raise Failure("sad_tab", f"after {why}, Reload on the crashed-page view did not bring the page back in 30 s", index)

    def crash_page(self, index: int):
        """chrome://crash typed into a new tab's omnibar (the person's path): its renderer crashes and the tab must
        show the crashed-page view. The tab was opened by a script, so it is agent-driven, and the agent URL guard may
        refuse the page: then the page still answers and the op counts as no verdict (counts.no_verdict)."""
        reply = self.open_tab(self.site.origin + "/page?id=crash", index, focus=True)
        created = [t for t in reply.get("created") or [] if isinstance(t, str)]
        if not created:
            self.notes.append(f"op {index}: openBrowser.chromium made no tab for chrome://crash ({reply.get('error')})")
            return
        time.sleep(1.0)  # the page loads
        if self.type_in_omnibar(created[0], "chrome://crash", index):
            self.expect_sad_tab(created[0], index, "chrome://crash typed in the omnibar", seconds=20)

    def page_answers(self, tab: str) -> bool:
        result, _, timed_out = rpc(self.sock, "browser.page.eval", {"tab": tab, "script": "1 + 1"}, 8)
        return not timed_out and result.get("value") == 2

    def kill_renderer(self, op: dict, index: int):
        before = children(self.pid, "renderer")
        # A host of its own (a *.localhost name is loopback and its own site), so the tab gets its own renderer.
        host = f"k{random.randrange(1 << 30)}.localhost"
        reply = self.open_tab(f"http://{host}:{self.site.port}/page?id=kill", index, focus=True)
        created = [t for t in reply.get("created") or [] if isinstance(t, str)]
        if not created:
            self.notes.append(f"op {index}: openBrowser.chromium made no tab to crash ({reply.get('error')})")
            return
        tab = created[0]
        # The page must load first: a renderer that starts before it may be Chromium's next spare.
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            result, _, _ = rpc(self.sock, "browser.page.eval", {"tab": tab, "script": "document.title"}, 8)
            if result.get("value") == "fuzz page kill":
                break
            time.sleep(0.25)
        else:
            self.counts["no_verdict"] += 1
            self.notes.append(f"op {index}: the tab to crash did not load in 30 s; no kill")
            return
        fresh = children(self.pid, "renderer") - before
        if not fresh:
            self.counts["no_renderer"] += 1
            self.counts["no_verdict"] += 1
            self.notes.append(f"op {index}: the new tab got no renderer process of its own (shared); no kill")
            return
        for pid in fresh:
            try:
                os.kill(pid, signal.SIGKILL)  # a renderer of the app this run launched (its parent is our app pid)
            except ProcessLookupError:
                pass
        self.counts["renderer_kills"] += 1
        self.expect_sad_tab(tab, index, f"kill -9 of its renderer {sorted(fresh)}", seconds=20)


# ---------------------------------------------------------------- runs, shrinking, verdict

class HarnessError(Exception):
    """The harness or the launch failed (not an oracle): no verdict from this run."""


def run_ops(opts, site, ops: list[dict], run_token: str, log, label: str) -> tuple[Failure | None, dict, dict]:
    """Runs `ops` on a fresh launch: the first fatal failure (or None), the run's counts, and its stalls by signature.
    Raises HarnessError when the app did not launch or the harness itself broke."""
    import traceback
    try:
        session = Session(opts, site, run_token, log)
    except BaseException as error:  # bench_memory.launch ends with SystemExit when the app opens no socket
        if isinstance(error, KeyboardInterrupt):
            raise
        raise HarnessError(f"the app did not launch: {str(error)[:800]}") from None
    try:
        session.settle_launch()
        for index, op in enumerate(ops):
            filled = dict(op)
            if "url" in filled:
                filled["url"] = filled["url"].replace("{origin}", site.origin)
            log(f"{label} op {index}: {json.dumps(filled)[:240]}")
            session.run_op(filled, index)
        return None, dict(session.counts, notes=session.notes[-20:]), session.stalls
    except Failure as failure:
        return failure, dict(session.counts, notes=session.notes[-20:]), session.stalls
    except Exception as error:  # noqa: BLE001 (a harness bug: reported, never a verdict)
        raise HarnessError(f"{type(error).__name__}: {error}\n{traceback.format_exc()[-1500:]}") from None
    finally:
        session.close()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="the tagged cmux DEV .app")
    parser.add_argument("--minutes", type=float, default=20, help="the whole run's budget, shrinking included")
    parser.add_argument("--seed", type=int, help="the first seed (default: random, printed)")
    parser.add_argument("--ops", type=int, default=150, help="ops per seed")
    parser.add_argument("--replay", help="a repro JSON (BROWSER-FUZZ-FINDING's object, or {ops}) to run once, no fuzzing")
    parser.add_argument("--shrink-replays", type=int, default=6, help="fresh launches each finding may spend on shrinking")
    parser.add_argument("--answer-timeout", type=float, default=30)
    parser.add_argument("--build-config", default=os.environ.get("BROWSER_FUZZ_BUILD_CONFIG", "debug"),
                        help="the app's build configuration, recorded in each finding (debug builds stall more)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="browser-fuzz-"))
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    os.environ.setdefault("CMUX_BENCH_LAUNCH", "direct")
    deadline = time.monotonic() + opts.minutes * 60
    site = LocalSite()
    log_file = open(os.path.join(opts.out, "ops.log"), "a")

    def log(line: str):
        log_file.write(line + "\n")
        log_file.flush()

    print(f"browser-fuzz: app {opts.app}, config {opts.build_config}, site {site.origin}, out {opts.out}", flush=True)
    if opts.replay:
        with open(opts.replay) as handle:
            repro = json.load(handle)
        try:
            failure, counts, stalls = run_ops(opts, site, repro["ops"], f"rp{uuid.uuid4().hex[:6]}", log, "replay")
        except HarnessError as error:
            print(f"BROWSER-FUZZ-VERDICT NOVERDICT replay of {opts.replay}: {str(error)[:400]}", flush=True)
            return 2
        wanted = repro.get("extra", {}).get("signature")
        if failure is None and wanted and wanted in stalls:
            failure = stalls[wanted]
        if failure:
            print(f"BROWSER-FUZZ-VERDICT FAIL {failure.oracle}: {failure.detail[:400]} (replay of {opts.replay})", flush=True)
            return 1
        print(f"BROWSER-FUZZ-VERDICT PASS replay of {opts.replay}: {len(repro['ops'])} ops, counts {json.dumps(counts)}", flush=True)
        return 0

    seed = opts.seed if opts.seed is not None else random.randrange(1 << 31)
    findings: list[dict] = []
    attempts, harness_errors, total_ops, totals = 0, 0, 0, {}
    seen: set[str] = set()

    advisory: dict[str, dict] = {}
    stalls_judged = opts.build_config != "debug"

    def note_stall(failure: Failure, seed: int):
        """Debug build: a stall is printed for the stall owners, never shrunk, never part of the verdict (Debug code
        is slower; stall evidence needs --config=bench)."""
        signature = failure.extra.get("signature")
        if signature in advisory:
            advisory[signature]["seen"] += 1
            return
        advisory[signature] = {"seed": seed, "op_index": failure.op_index, "detail": failure.detail[:600],
                               "stack": failure.extra.get("stack"), "owner": failure.extra.get("owner"), "seen": 1}
        print("BROWSER-FUZZ-STALL " + json.dumps(dict(advisory[signature], signature=signature)), flush=True)

    def report(failure: Failure, seed: int, ops: list[dict]):
        """Shrinks one failure (fresh launches, within the budget and the deadline) and prints its finding."""
        key = failure.oracle + ":" + (failure.extra.get("signature") or failure.detail[:60])
        if key in seen:
            print(f"browser-fuzz: seed {seed}: {failure.oracle} again (already a finding): {failure.detail[:200]}", flush=True)
            return
        seen.add(key)
        prefix = ops[:failure.op_index + 1] if failure.op_index >= 0 else ops[:1]
        replays = {"tried": 0, "failed": 0, "harness_errors": 0}

        def fails(candidate: list[dict]) -> bool:
            if time.monotonic() > deadline - 90:
                return False
            replays["tried"] += 1
            try:
                again, _, stalls = run_ops(opts, site, candidate, f"sh{seed:x}r{replays['tried']}", log, f"shrink {seed}")
            except HarnessError as error:
                replays["harness_errors"] += 1
                print(f"browser-fuzz: shrink replay: harness error: {str(error)[:300]}", flush=True)
                return False
            if failure.oracle == "stall":
                hit = failure.extra.get("signature") in stalls
            else:
                hit = again is not None and again.oracle == failure.oracle
            replays["failed"] += int(hit)
            return hit

        reproduced = opts.shrink_replays > 0 and fails(prefix)
        shrunk = prefix
        if reproduced and len(prefix) > 1:
            shrunk, _ = model.ddmin(prefix, fails, max(0, opts.shrink_replays - 1))
        finding = {"target": "browser", "id": f"{failure.oracle}-{seed}", "seed": seed, "ops_per_seed": opts.ops,
                   "build_config": opts.build_config, "oracle": failure.oracle, "detail": failure.detail[:1500],
                   "op_index": failure.op_index, "failed_op": ops[failure.op_index] if 0 <= failure.op_index < len(ops) else None,
                   "reproduced": reproduced, "replays": replays, "ops": shrunk, "extra": failure.extra}
        findings.append(finding)
        with open(os.path.join(opts.out, f"finding-{len(findings)}.json"), "w") as out:
            json.dump(finding, out, indent=1)
        print("BROWSER-FUZZ-FINDING " + json.dumps(finding), flush=True)

    while time.monotonic() < deadline - 150:
        attempts += 1
        token = f"fz{seed:x}"
        ops = model.generate(seed, opts.ops, "{origin}", token)
        print(f"browser-fuzz: seed {seed} ({len(ops)} ops)", flush=True)
        try:
            failure, counts, stalls = run_ops(opts, site, ops, token, log, f"seed {seed}")
        except HarnessError as error:
            harness_errors += 1
            print(f"browser-fuzz: seed {seed}: harness error (no verdict): {error}", flush=True)
            seed += 1
            if harness_errors >= 3 and total_ops == 0:
                break
            continue
        for name, value in counts.items():
            if isinstance(value, int):
                totals[name] = totals.get(name, 0) + value
        for note in counts.get("notes") or []:
            print(f"browser-fuzz: note: {note}", flush=True)
        total_ops += counts.get("ops", 0)
        brief = json.dumps({k: v for k, v in counts.items() if k != "notes"})
        if failure is None:
            print(f"browser-fuzz: seed {seed}: no fatal failure, {len(stalls)} stall signature(s), counts {brief}", flush=True)
        else:
            print(f"browser-fuzz: seed {seed} FAIL at op {failure.op_index}: {failure.oracle}: {failure.detail[:600]}", flush=True)
            report(failure, seed, ops)
        for stall in stalls.values():
            if stalls_judged:
                report(stall, seed, ops)
            else:
                note_stall(stall, seed)
        seed += 1

    summary = (f"seeds {attempts}, ops {total_ops}, harness errors {harness_errors}, config {opts.build_config}, "
               f"advisory debug stalls {len(advisory)}, counts {json.dumps(totals)}")
    if findings:
        kinds = ", ".join(sorted({f["oracle"] for f in findings}))
        print(f"BROWSER-FUZZ-VERDICT FAIL {len(findings)} finding(s) ({kinds}); {summary}", flush=True)
        return 1
    if total_ops == 0 or harness_errors * 2 >= attempts:
        print(f"BROWSER-FUZZ-VERDICT NOVERDICT {harness_errors} of {attempts} seeds ended in a harness error; {summary}", flush=True)
        return 2
    caveat = f"(harness errors {harness_errors}) " if harness_errors else ""
    print(f"BROWSER-FUZZ-VERDICT PASS {caveat}{summary}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
