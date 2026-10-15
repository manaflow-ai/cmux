#!/usr/bin/env python3
"""Crash injection: ending a browser pane's content process never takes cmux down.

Runs against a running tagged DEBUG build (its debug socket). Every kill names an exact
pid that belongs to the app: the WebKit WebContent pid the pane reports
(`debug.browser.page_status`), or a child of the app process started with
`--type=renderer` / `--type=gpu-process` (Chromium helpers), found by parent pid.

Legs (CMUX_CRASH_E2E_LEGS, comma-separated, default all that apply):
  webkit    SIGKILL the WebKit pane's WebContent process: the pane shows the Reload
            overlay, `debug.browser.crashes` records it, Reload brings the page back
            in a new process, cmux keeps running.
  renderer  (Chromium) SIGKILL the pane's renderer: the pane shows "Aw, Snap!" with
            Reload; Reload brings the page back. The chrome://crash equivalent.
  gpu       (Chromium) SIGKILL the GPU process: Chromium starts a new one, the page
            still answers, the crash log records a gpu-process exit. The
            chrome://gpucrash equivalent.
  hang      (Chromium) a page that spins its main thread gets the "Page unresponsive"
            prompt after input; Exit page ends the renderer and shows the crash page.
            The chrome://hang equivalent.

Chromium legs are skipped (not failed) when the build has no Chromium engine.
chrome:// debug URLs are not used: agent-driven navigation refuses chrome:// pages
in Chromium panes (BrowserAgentURLPolicy), so the test ends processes directly.

Usage: CMUX_SOCKET_PATH=<tagged socket> python3 tests_v2/test_browser_crash_injection.py
"""

from __future__ import annotations

import functools
import http.server
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
LEGS = set((os.environ.get("CMUX_CRASH_E2E_LEGS") or "webkit,renderer,gpu,hang").split(","))
PAGE_TITLE = "crash-e2e"


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for(pred, timeout_s: float, label: str):
    """Polls a live app (test harness only) until `pred` returns a truthy value."""
    deadline = time.time() + timeout_s
    last_exc = None
    while time.time() < deadline:
        try:
            value = pred()
            if value:
                return value
        except Exception as exc:  # noqa: BLE001
            last_exc = exc
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {label}" + (f": {last_exc}" if last_exc else ""))


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _app_pid() -> int:
    """The process that holds the socket (lsof lists a unix socket by its bound path)."""
    out = subprocess.run(["lsof", "-U", "-Fpn"], capture_output=True, text=True).stdout
    pid = None
    for line in out.splitlines():
        if line.startswith("p"):
            pid = int(line[1:])
        elif line.startswith("n") and line[1:] == SOCKET_PATH and pid:
            return pid
    raise cmuxError(f"No process holds {SOCKET_PATH}")


def _children(parent: int, kind: str) -> list[int]:
    out = subprocess.run(["ps", "-Ao", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    pids = []
    for line in out.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[1] == str(parent) and f"--type={kind}" in parts[2]:
            pids.append(int(parts[0]))
    return pids


def _serve() -> str:
    root = tempfile.mkdtemp(prefix="cmux-crash-e2e-")
    Path(root, "index.html").write_text(
        f"<!doctype html><title>{PAGE_TITLE}</title><p id=alive>alive</p>", encoding="utf-8"
    )

    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=root))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/"


class Harness:
    def __init__(self, client: cmux, app_pid: int):
        self.c = client
        self.app_pid = app_pid

    def status(self, sid: str, press: str | None = None) -> dict:
        params = {"surface_id": sid}
        if press:
            params["press"] = press
        return self.c._call("debug.browser.page_status", params) or {}

    def crashes(self) -> dict:
        return self.c._call("debug.browser.crashes", {}) or {}

    def page_answers(self, sid: str) -> bool:
        reply = self.c._call("browser.eval", {
            "surface_id": sid, "script": "document.getElementById('alive')?.textContent || ''",
        }) or {}
        return reply.get("value") == "alive"

    def open(self, url: str, engine: str | None) -> str:
        params = {"url": url}
        if engine:
            params["engine"] = engine
        opened = self.c._call("browser.open_split", params) or {}
        sid = str(opened.get("surface_id") or "")
        _must(bool(sid), f"browser.open_split returned no surface_id: {opened}")
        _wait_for(lambda: self.page_answers(sid), 30, f"{engine or 'default'} page load")
        return sid

    def app_still_runs(self, leg: str) -> None:
        _must(_alive(self.app_pid), f"{leg}: cmux exited")
        _must(bool(self.crashes()), f"{leg}: cmux stopped answering on its socket")

    def reload_brings_page_back(self, leg: str, sid: str) -> None:
        pressed = self.status(sid, press="reload").get("pressed")
        _must(pressed is True, f"{leg}: Reload was not offered")
        _wait_for(lambda: not self.status(sid).get("crashed") and self.page_answers(sid), 30,
                  f"{leg}: page back after Reload")


def leg_webkit(h: Harness, url: str) -> None:
    sid = h.open(url, None)
    status = h.status(sid)
    _must(status.get("engine") == "webkit", f"webkit: unexpected engine {status}")
    page_pid = int(status.get("page_pid") or 0)
    _must(page_pid > 0, f"webkit: pane reports no WebContent pid: {status}")
    before = int(h.crashes().get("total") or 0)
    os.kill(page_pid, signal.SIGKILL)
    _wait_for(lambda: h.status(sid).get("crashed"), 20, "webkit: Reload overlay")
    h.app_still_runs("webkit")
    records = h.crashes().get("records") or []
    _must(int(h.crashes().get("total") or 0) > before and any(
        r.get("process_type") == "webcontent" and str(r.get("panel_id") or "").lower() == sid.lower() for r in records
    ), f"webkit: crash log has no WebContent record for {sid}: {records[-3:]}")
    h.reload_brings_page_back("webkit", sid)
    fresh = int(h.status(sid).get("page_pid") or 0)
    _must(fresh > 0 and fresh != page_pid, f"webkit: page did not get a new process ({page_pid} -> {fresh})")
    print("PASS webkit: WebContent crash contained, Reload restores the page")


def chromium_tab(h: Harness, url: str) -> str | None:
    try:
        sid = h.open(url, "chromium")
    except cmuxError as exc:
        print(f"SKIP chromium legs: {exc}")
        return None
    if h.status(sid).get("engine") != "chromium":
        print("SKIP chromium legs: the pane opened in WebKit (Chromium unavailable in this build)")
        return None
    return sid


def leg_renderer(h: Harness, sid: str) -> None:
    renderers = _children(h.app_pid, "renderer")
    _must(bool(renderers), "renderer: no Chromium renderer process")
    for pid in renderers:
        os.kill(pid, signal.SIGKILL)
    _wait_for(lambda: h.status(sid).get("prompt") == "crashed", 20, "renderer: Aw, Snap! page")
    h.app_still_runs("renderer")
    h.reload_brings_page_back("renderer", sid)
    print("PASS renderer: renderer crash contained, Reload restores the page")


def leg_gpu(h: Harness, sid: str) -> None:
    gpus = _children(h.app_pid, "gpu-process")
    _must(bool(gpus), "gpu: no Chromium GPU process")
    before = int(h.crashes().get("total") or 0)
    for pid in gpus:
        os.kill(pid, signal.SIGKILL)
    _wait_for(lambda: set(_children(h.app_pid, "gpu-process")) - set(gpus), 30, "gpu: new GPU process")
    h.app_still_runs("gpu")
    if h.status(sid).get("crashed"):
        h.reload_brings_page_back("gpu", sid)
    _wait_for(lambda: h.page_answers(sid), 30, "gpu: page still answers")
    _wait_for(lambda: any(r.get("process_type") == "gpu-process" for r in (h.crashes().get("records") or []))
              and int(h.crashes().get("total") or 0) > before, 10, "gpu: crash log records the GPU process")
    print("PASS gpu: GPU process crash contained, page still answers")


def leg_hang(h: Harness, sid: str) -> None:
    h.c._call("browser.eval", {"surface_id": sid, "script": "setTimeout(() => { for (;;) {} }, 0); 'spinning'"})
    # Chromium reports a hang when input goes unanswered (its hang monitor).
    try:
        h.c._call("browser.click", {"surface_id": sid, "selector": "#alive"}, timeout_s=5)
    except cmuxError:
        pass
    _wait_for(lambda: h.status(sid).get("prompt") == "unresponsive", 45, "hang: Page unresponsive prompt")
    h.app_still_runs("hang")
    pressed = h.status(sid, press="exit").get("pressed")
    _must(pressed is True, "hang: Exit page was not offered")
    _wait_for(lambda: h.status(sid).get("prompt") == "crashed", 20, "hang: crash page after Exit page")
    h.reload_brings_page_back("hang", sid)
    print("PASS hang: unresponsive prompt shown, Exit page ends the renderer, Reload restores")


def main() -> int:
    url = _serve()
    app_pid = _app_pid()
    with cmux(SOCKET_PATH) as client:
        h = Harness(client, app_pid)
        if "webkit" in LEGS:
            leg_webkit(h, url)
        if LEGS & {"renderer", "gpu", "hang"}:
            sid = chromium_tab(h, url)
            if sid:
                if "renderer" in LEGS:
                    leg_renderer(h, sid)
                if "gpu" in LEGS:
                    leg_gpu(h, sid)
                if "hang" in LEGS:
                    leg_hang(h, sid)
        h.app_still_runs("end")
    print("PASS every injected browser crash is contained")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
