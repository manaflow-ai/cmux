#!/usr/bin/env python3
"""cmux NEXT Stable's UI tests: a person's first session, driven on the real signed app (stable-next.yml).

The app is the exact DMG stable publishes (Developer ID, or ad hoc in a dry run), launched from a
fresh home by scripts/ci/fresh_home_launch_smoke.py (Home must render, no crash). Then, in the same
launch, this runs the session a new user has, through the app's release control socket (the methods
every release build serves: action.run, snapshot.get, browser.page.state, settings.open,
palette.query, system.ping) and the CLI the app bundles (Contents/Resources/bin/cmux), and checks each
step's result in the app's own state, not only that a call returned:

  terminal   New Tab opens a terminal tab in the shown workspace
  echo       a command typed into that terminal runs in its shell and its output is on screen
  split      Split Right adds a pane beside it
  chromium   a page served on 127.0.0.1 loads in a Chromium tab (title and URL)
  webkit     the same page loads in a WebKit tab
  palette    the command palette finds Settings
  settings   Settings opens
  sidebar    the sidebar hides and shows again
  close      Close Tab removes the WebKit tab
  home       Home shows again
  alive      the app answers a ping in under 2 s after all of it
  quit       Quit ends the app with status 0 within 30 s

A screenshot after each step (shot-<n>-<step>.png) and a screen recording of the whole session
(session.mov) are evidence, never the verdict (screencapture may lack the Screen Recording grant).
The report (report.json "journey") lists every step with its detail.

Usage: stable_next_ui_journey.py --dmg DMG|--app APP --out DIR [--seconds S] [--startup-timeout S]
Exit 0: every step passed and the app never crashed. 1: a step failed or the app crashed.
3: it could not run (no GUI session, no app, a signing keychain present).
"""
from __future__ import annotations

import http.server
import importlib.util
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("fresh_home_launch_smoke", HERE / "fresh_home_launch_smoke.py")
smoke = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(smoke)

TITLE = "cmux stable ui journey"
ECHO_OUTPUT = "cmux-stable-42"
# The typed command holds $((6*7)), never "-42": only the shell's output matches.
ECHO_COMMAND = "echo cmux-stable-$((6*7))"
STEP_TIMEOUT = 45.0
RECORD_SECONDS = 600


class Journey:
    def __init__(self, process, socket_path: Path, env: dict, app: Path, out: Path | None, report: dict):
        self.process, self.socket_path, self.env, self.app = process, socket_path, env, app
        self.out = out
        self.report = report
        self.steps: list[dict] = []
        self.cli = app / "Contents" / "Resources" / "bin" / "cmux"
        self.recorder = None

    # --- transport ---------------------------------------------------------------------------
    def call(self, method: str, params: dict | None = None, timeout: float = 30.0) -> dict:
        """One request on the release control socket: the result, or {"error": ...}."""
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(timeout)
                sock.connect(str(self.socket_path))
                sock.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                buffer = b""
                while b"\n" not in buffer:
                    chunk = sock.recv(1 << 20)
                    if not chunk:
                        break
                    buffer += chunk
            reply = json.loads(buffer.split(b"\n", 1)[0])
        except (OSError, ValueError) as error:
            return {"error": str(error)}
        if reply.get("ok") is False or "error" in reply and reply.get("error"):
            return {"error": reply.get("error")}
        result = reply.get("result")
        return result if isinstance(result, dict) else {"value": result}

    def run_action(self, action: str, args: dict | None = None, timeout: float = STEP_TIMEOUT) -> dict:
        params = {"action": action, "focus": True}
        if args:
            params["args"] = args
        return self.call("action.run", params, timeout=timeout)

    def cmux(self, *argv: str, timeout: float = 60.0) -> tuple[int, str]:
        """The app's own CLI, in the app's environment, so it reaches this build's session."""
        try:
            done = subprocess.run([str(self.cli), *argv], env={**self.env, "CMUX_NEXT_SOCKET_PATH": str(self.socket_path)},
                                  cwd=self.env["HOME"], capture_output=True, text=True, timeout=timeout)
            return done.returncode, (done.stdout + done.stderr).strip()
        except (OSError, subprocess.SubprocessError) as error:
            return 127, str(error)

    @staticmethod
    def wait(probe, seconds: float = STEP_TIMEOUT, every: float = 0.5):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            value = probe()
            if value:
                return value
            time.sleep(every)
        return None

    # --- state reads -------------------------------------------------------------------------
    def snap(self) -> dict:
        return self.call("snapshot.get")

    def shown_panes(self, snap: dict | None = None) -> list[dict]:
        topology = (snap or self.snap()).get("topology") or {}
        shown = {w.get("workspace") for w in topology.get("windows") or [] if isinstance(w, dict) and w.get("visible")}
        panes = []
        for workspace in topology.get("workspaces") or []:
            if isinstance(workspace, dict) and workspace.get("id") in shown:
                for screen in workspace.get("screens") or []:
                    panes.extend(p for p in (screen or {}).get("panes") or [] if isinstance(p, dict))
        return panes

    def shown_tabs(self) -> list[dict]:
        return [t for p in self.shown_panes() for t in p.get("tabs") or [] if isinstance(t, dict)]

    def selected_tabs(self) -> list[dict]:
        return [t for p in self.shown_panes() for t in p.get("tabs") or []
                if isinstance(t, dict) and t.get("id") == p.get("selected_tab")]

    # --- evidence ----------------------------------------------------------------------------
    def shot(self, name: str) -> None:
        if self.out is None or shutil.which("screencapture") is None:
            return
        path = self.out / f"shot-{len(self.steps):02d}-{name}.png"
        try:
            subprocess.run(["screencapture", "-x", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
        except (OSError, subprocess.SubprocessError):
            pass

    def start_recording(self) -> None:
        if self.out is None or shutil.which("screencapture") is None:
            return
        try:
            self.recorder = subprocess.Popen(["screencapture", "-x", "-v", "-V", str(RECORD_SECONDS), str(self.out / "session.mov")],
                                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        except OSError:
            self.recorder = None

    def stop_recording(self) -> None:
        if self.recorder is None or self.recorder.poll() is not None:
            return
        self.recorder.send_signal(signal.SIGINT)  # screencapture finishes the movie on SIGINT
        try:
            self.recorder.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.recorder.kill()

    def step(self, name: str, ok: bool, detail=None) -> bool:
        self.steps.append({"step": name, "ok": bool(ok), "detail": detail})
        smoke.log(f"journey {name:9s} {'ok' if ok else 'FAIL'} {json.dumps(detail, default=str)[:400] if detail is not None else ''}")
        self.shot(name)
        return bool(ok)

    # --- the session -------------------------------------------------------------------------
    def serve_page(self) -> tuple[http.server.ThreadingHTTPServer, str]:
        root = Path(self.env["TMPDIR"]) / "www"
        root.mkdir(parents=True, exist_ok=True)
        (root / "index.html").write_text(f"<!doctype html><title>{TITLE}</title><h1>{TITLE}</h1>", encoding="utf-8")

        class Handler(http.server.SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(root), **kwargs)

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server, f"http://127.0.0.1:{server.server_address[1]}/"

    def page_loaded(self, url: str):
        state = self.call("browser.page.state")
        return state if state.get("title") == TITLE and str(state.get("url", "")).startswith(url) else None

    def terminal_id(self, before: set[str]) -> str | None:
        code, text = self.cmux("terminal", "list", "--json")
        if code != 0:
            return None
        try:
            value = json.loads(text.splitlines()[-1])
        except (ValueError, IndexError):
            return None
        records = value if isinstance(value, list) else value.get("terminals") or value.get("items") or []
        ids = [str(r.get("id") or r.get("term_id") or "") for r in records if isinstance(r, dict)]
        fresh = [i for i in ids if i and i not in before]
        return (fresh or [i for i in ids if i] or [None])[-1]

    def run(self) -> list[str]:
        self.start_recording()
        try:
            self.session()
        finally:
            self.quit()
            self.stop_recording()
        self.report["journey"] = self.steps
        return [f"UI step {s['step']} failed: {json.dumps(s['detail'], default=str)[:300]}" for s in self.steps if not s["ok"]]

    def session(self) -> None:
        tabs_before = len(self.shown_tabs())
        code, listed = self.cmux("terminal", "list", "--json")
        terms_before = set()
        if code == 0:
            terms_before = {part for part in listed.replace('"', " ").split() if part.startswith(("term_", "t_"))}
        opened = self.run_action("newTab")
        grown = self.wait(lambda: len(self.shown_tabs()) > tabs_before)
        self.step("terminal", bool(grown) and "error" not in opened, {"run": opened, "tabs_before": tabs_before,
                                                                     "tabs_after": len(self.shown_tabs())})

        term = self.wait(lambda: self.terminal_id(terms_before), 30)
        typed = self.cmux("terminal", term, "write", "--text", ECHO_COMMAND + "\n") if term else (1, "no terminal id")
        seen = self.cmux("terminal", term, "screen", "wait", "--pattern", ECHO_OUTPUT, "--timeout-ms", "30000",
                         timeout=45) if term and typed[0] == 0 else (1, "not typed")
        self.step("echo", seen[0] == 0, {"terminal": term, "write": typed[1][-200:], "screen_wait": seen[1][-300:]})

        panes_before = len(self.shown_panes())
        split = self.run_action("splitRight")
        more = self.wait(lambda: len(self.shown_panes()) > panes_before)
        self.step("split", bool(more) and "error" not in split, {"run": split, "panes_before": panes_before,
                                                                 "panes_after": len(self.shown_panes())})

        server, page = self.serve_page()
        try:
            opened = self.run_action("openBrowser", {"url": page + "?chromium", "engine": "cef"}, timeout=90)
            state = self.wait(lambda: self.page_loaded(page + "?chromium"), 90)
            self.step("chromium", bool(state) and "error" not in opened,
                      {"run": opened, "state": state or self.call("browser.page.state")})
            opened = self.run_action("openBrowser", {"url": page + "?webkit", "engine": "webkit"})
            state = self.wait(lambda: self.page_loaded(page + "?webkit"))
            self.step("webkit", bool(state) and "error" not in opened,
                      {"run": opened, "state": state or self.call("browser.page.state")})
        finally:
            server.shutdown()

        # palette.query needs a scope; a ranked row's own title must name Settings (the reply echoes the
        # query, so matching the whole reply would pass with no row at all).
        found = self.call("palette.query", {"scope": "root", "query": "Settings", "limit": 8})
        titles = [str(item.get("title") or "") for item in found.get("items") or [] if isinstance(item, dict)]
        self.step("palette", "error" not in found and any("Settings" in title for title in titles),
                  {"titles": titles, "error": found.get("error")})

        opened = self.call("settings.open", {"focus": True})
        self.step("settings", opened.get("opened") is True, {"run": opened})

        hidden = self.run_action("toggleSidebar")
        shown = self.run_action("toggleSidebar")
        self.step("sidebar", "error" not in hidden and "error" not in shown, {"hide": hidden, "show": shown})

        tabs = len(self.shown_tabs())
        closed = self.run_action("closeTab")
        fewer = self.wait(lambda: len(self.shown_tabs()) < tabs)
        self.step("close", bool(fewer) and "error" not in closed, {"run": closed, "tabs_before": tabs,
                                                                   "tabs_after": len(self.shown_tabs())})

        home = self.run_action("home.show")
        back = self.wait(lambda: any(t.get("page") == smoke.HOME_PAGE for t in self.selected_tabs()))
        self.step("home", bool(back) and "error" not in home, {"run": home})

        started = time.monotonic()
        ping = self.call("system.ping", timeout=10)
        ms = (time.monotonic() - started) * 1000
        self.step("alive", "error" not in ping and ms < 2000 and self.process.poll() is None,
                  {"ping_ms": round(ms), "reply": ping})
        errors = self.call("errors.list")
        self.report["app_errors"] = errors

    def quit(self) -> None:
        if self.process.poll() is not None:
            self.step("quit", False, {"detail": f"the app was gone before Quit (status {self.process.poll()})"})
            return
        reply = self.call("action.run", {"action": "quitEndEverything"}, timeout=20)
        try:
            status = self.process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            status = None
        self.step("quit", status == 0, {"run": reply, "exit_status": status})


def journey(process, socket_path, env, app, out, report) -> list[str]:
    return Journey(process, Path(socket_path), env, Path(app), Path(out) if out else None, report).run()


if __name__ == "__main__":
    smoke.AFTER_RENDER = journey
    sys.exit(smoke.main())
