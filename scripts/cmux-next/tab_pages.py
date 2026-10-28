"""Local tab pages and the Chromium process classifier, shared by the idle benches.

idle-budget.py (its stress-static session), browser-idle-cost-live.py (the perf100 browser lane) and
bench_idle.py open Chromium tabs on pages from this server, read the process table with `process_table`
and sort the app's processes with `chromium_kind`. One copy of each, so every bench measures the same
pages and calls a process by the same kind. scripts/perf-bench/procs.py reads its table here too.

Pages (`TabPages.url(kind, n)` is `<origin>/<kind>-<n>`):
  static   a heading and a script that runs only at load and on visibilitychange: it POSTs /loaded/<n> and
           /vis/<n>/<state>, so the bench knows the page loaded and whether it is shown (no timer, no rAF)
  engine   the static page that also POSTs /engine/<n>/<navigator.vendor> at load, so the bench knows which engine
           drew it: "Google Inc." in Chromium (third_party/blink/renderer/core/frame/navigator_id.cc,
           NavigatorID::vendor), "Apple Computer, Inc." in WebKit (Source/WebCore/page/NavigatorBase.cpp); a user
           agent override (device emulation, WebKitEngine's applicationNameForUserAgent) leaves it alone
  plain    no script at all
  grid    STRESS's page (perf-stress-session.py) without its rAF spinner: a card grid and text, no script
  loading  a page whose load never ends (an image request the server holds until close)
  chatty   console.log 4 times a second with the server's marker, POSTing /tick every 4 calls

Kinds follow Chromium's process types (`--type=`, content/public/common/content_switches.cc: kRendererProcess,
kGpuProcess, kUtilityProcess; `--extension-process`, extensions/common/switches.cc) as the idle budget names them.
"""
from __future__ import annotations

import http.server
import itertools
import re
import subprocess
import threading
import urllib.parse
from typing import Callable

# ---------------------------------------------------------------------------------------------------------
# Chromium process classifier

_TYPE = re.compile(r"\s--type=(\S+)")
_TYPE_KINDS = {"renderer": "cef-renderer", "gpu-process": "cef-gpu", "utility": "cef-utility"}
# The Chromium Host: a second executable of the app (embed-cef.sh), "<App>.app/Contents/MacOS/<App> Chromium Host".
# No " -" before it: a shell whose arguments name the host is not the host.
_HOST = re.compile(r"^/(?:(?! -).)*\.app/Contents/MacOS/[^/]* Chromium Host$")
# The executable of a CEF helper app ("<App> Helper (Renderer).app", "<App> Helper.app"), or of the Chromium Host
# app of older builds ("<App> Chromium Host.app" in Contents/Frameworks).
_BUNDLE = re.compile(r"/[^/]* (Helper|Chromium Host)[^/]*\.app/")

# browser-idle-cost-live.py's class names of the `process_type_kind` kinds (its report and budget file key on them).
PERF100_CLASSES = {"cef-gpu": "gpu", "cef-renderer": "renderer", "cef-extension": "extension-renderer",
                   "cef-utility": "utility", "cef-helper": "other-helper"}


def process_type_kind(cmd: str) -> str | None:
    """The kind of a process from its --type switch alone (any executable), or None without one:
    cef-renderer, cef-extension (a renderer with --extension-process), cef-gpu, cef-utility, cef-helper
    (any other --type). browser-idle-cost-live.py's classes are these (PERF100_CLASSES)."""
    match = _TYPE.search(cmd)
    if match is None:
        return None
    if match.group(1) == "renderer" and "--extension-process" in cmd:
        return "cef-extension"
    return _TYPE_KINDS.get(match.group(1), "cef-helper")


def chromium_kind(cmd: str) -> str | None:
    """The kind of a Chromium process from its command line, or None when its executable is neither the
    Chromium Host nor in a Helper app: cef-host (the Chromium Host's browser process), the `process_type_kind`
    kinds, or cef-helper for a Helper app started without --type."""
    exe = cmd.split(" --", 1)[0]
    if _HOST.search(exe):
        return "cef-host"
    bundle = _BUNDLE.search(exe)
    if bundle is None:
        return None
    if bundle.group(1) == "Chromium Host":
        return "cef-host"
    return process_type_kind(cmd) or "cef-helper"


def process_table() -> list[tuple[int, int, str]]:
    """[(pid, ppid, command)] of every process, from one `ps` call with full command lines."""
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    rows = []
    for line in out.splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def chromium_children(app_pid: int, table, names: dict[str, str] | None = None,
                      kind_of: Callable[[str], str | None] = chromium_kind) -> dict[int, str]:
    """{pid: kind} of the Chromium processes `app_pid` started, from a `process_table()`, sorted by `kind_of`.
    With `names`, each kind is reported under its name there and kinds missing from it are left out."""
    out = {}
    for pid, ppid, cmd in table:
        if ppid != app_pid:
            continue
        found = kind_of(cmd)
        if found is None or (names is not None and found not in names):
            continue
        out[pid] = names[found] if names is not None else found
    return out


# ---------------------------------------------------------------------------------------------------------
# Page server

_GRID_STYLE = ("<style>body{margin:0;font:16px -apple-system,sans-serif;background:#f4f4f6}"
               ".g{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:10px;padding:16px}"
               ".g div{height:80px;border-radius:10px;background:#c9d4e8}</style>").replace("{", "{{").replace("}", "}}")

PAGES = {
    "static": "<title>static {n}</title><body style='font:16px system-ui'><h1>Static page {n}</h1><p>Nothing runs here.</p>"
              "<script>fetch('/loaded/{n}',{{method:'POST'}});const v=()=>fetch('/vis/{n}/'+document.visibilityState,{{method:'POST'}});"
              "v();document.addEventListener('visibilitychange',v)</script>",
    "engine": "<title>static {n}</title><body style='font:16px system-ui'><h1>Static page {n}</h1><p>Nothing runs here.</p>"
              "<script>fetch('/loaded/{n}',{{method:'POST'}});"
              "fetch('/engine/{n}/'+encodeURIComponent(navigator.vendor),{{method:'POST'}});"
              "const v=()=>fetch('/vis/{n}/'+document.visibilityState,{{method:'POST'}});"
              "v();document.addEventListener('visibilitychange',v)</script>",
    "plain": "<!doctype html><title>idle</title><h1>static page</h1><p>no script, no animation</p>",
    "grid": "<!doctype html><meta charset='utf-8'><title>idle {n}</title>" + _GRID_STYLE
            + "<h1>idle page {n}</h1><div class='g'>" + "<div></div>" * 120 + "</div><p>"
            + "lorem ipsum dolor sit amet " * 200 + "</p>",
    "loading": "<title>loading</title><body><h1>This load never ends</h1><img src='/never'>"
               "<script>fetch('/loaded/loading',{{method:'POST'}})</script>",
    "chatty": "<title>chatty</title><body><h1>Console chatter</h1><script>let i=0;"
              "setInterval(()=>{{console.log('{marker} ' + (i++));if(i%4==0)fetch('/tick',{{method:'POST'}})}}, 250);"
              "fetch('/loaded/chatty',{{method:'POST'}})</script>",
}


class _Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        pages = self.server.pages
        if self.path == "/never":
            pages.closing.wait(3600)  # keeps the page loading; close() ends it
            return
        body = pages.body(self.path)
        if body is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):  # noqa: N802
        self.server.pages.report(self.path)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


class TabPages:
    """The page server on 127.0.0.1 (a free port) and what the pages reported: `loaded` (keys that POSTed
    /loaded/<key>), `visibility` ({n: latest document.visibilityState} of static and engine pages), `vendors`
    ({n: navigator.vendor} of engine pages) and `ticks` (the
    chatty page's console.log calls, in fours). `url()` with no arguments gives the next page of
    `default_kind`, so a TabPages stands in for perf-stress-session.Pages."""

    def __init__(self, marker: str = "", default_kind: str = "static"):
        if default_kind not in PAGES:
            raise ValueError(f"unknown page kind {default_kind}")
        self.marker = marker
        self.default_kind = default_kind
        self.loaded: set[str] = set()
        self.visibility: dict[str, str] = {}
        self.vendors: dict[str, str] = {}
        self.ticks = 0
        self.closing = threading.Event()
        self._next = itertools.count(1)
        self._server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
        self._server.pages = self
        # poll_interval: how soon serve_forever sees close()'s shutdown request (stdlib default 0.5 s).
        threading.Thread(target=self._server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True).start()
        self.origin = f"http://127.0.0.1:{self._server.server_address[1]}"

    def url(self, kind: str | None = None, n: object = None) -> str:
        kind = kind or self.default_kind
        if kind not in PAGES:
            raise ValueError(f"unknown page kind {kind}")
        return f"{self.origin}/{kind}-{next(self._next) if n is None else n}"

    def body(self, path: str) -> bytes | None:
        """The page at `path` (`/<kind>-<n>`), or None for no such page."""
        kind, _, n = path.strip("/").partition("-")
        template = PAGES.get(kind)
        return None if template is None else template.format(n=n, marker=self.marker).encode()

    def report(self, path: str) -> None:
        if path == "/tick":
            self.ticks += 4
        elif path.startswith("/vis/"):
            parts = path.split("/", 3)
            if len(parts) == 4:
                self.visibility[parts[2]] = parts[3]
        elif path.startswith("/engine/"):
            parts = path.split("/", 3)
            if len(parts) == 4:
                self.vendors[parts[2]] = urllib.parse.unquote(parts[3])
        elif path.startswith("/loaded/"):
            self.loaded.add(path.removeprefix("/loaded/"))

    def close(self) -> None:
        """Ends held loads, stops the server and closes its socket (again: nothing)."""
        if self.closing.is_set():
            return
        self.closing.set()
        self._server.shutdown()
        self._server.server_close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
