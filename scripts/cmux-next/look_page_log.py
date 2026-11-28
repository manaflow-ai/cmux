"""A look's page log: the agent pane's console and a DOM snapshot with each shot, in the look's own output.

A look that installs published web bundles (hot-verify.py apply_web) had no window into the page: a dev server
forwards the browser's console to its log, an overlay forwards nothing, and a copy of a NIGHTLY has no debug
calls. A fleet look drew a blank New Tab under cmux#62808's bundle (cmux#64758) that the same app and bundle drew
on every other Mac, and its out/ said nothing about why.

So a look stages the bundles with look-page-probe.js as the agent pane's first script, and runs a Sink: a loopback
server web-dev.json names as the copy's `server` (with its token's proof, as WebDevOverride checks), which answers
the probe and 404s every other file, so the app serves those from the overlay as before. Written into OUT/page/:

  console.jsonl          every console call, uncaught error and rejection, one JSON line each, as it comes
  dom.jsonl              each DOM snapshot's time, page, boxes and text (no HTML), as it comes
  OUT/<shot>.dom.json    with each PNG under OUT: the pane's DOM snapshot that was live when the PNG was written
"""
from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import http.server
import json
import os
import re
import shutil
import threading
import time
import urllib.parse
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROBE = HERE / "look-page-probe.js"
PROBE_NAME = "__look_probe.js"
# The agent pane inside a build-web-bundles.sh output root (web-overlay.sh PANE).
PANE = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"
ROUTE = re.compile(r"^/agent-pane/__look_probe/(console|dom)$")
TOKEN = re.compile(r"[A-Za-z0-9_-]{32,}")
CHUNK_TEXT = re.compile(r"[A-Za-z0-9_-]+")
# Parts of one message at most (6000 characters each), and messages held open at once: a page that never sends a
# message's last part holds no more than this.
MAX_PARTS = 400
MAX_OPEN = 64
# DOM snapshots kept on disk until the shots take theirs; older ones go (a page that changes every second for a
# long look keeps the last ones).
MAX_SNAPSHOTS = 400
# Console lines kept: a page logging in a loop fills no more of out.tar than this.
MAX_CONSOLE = 20000


def stage(bundles: Path, into: Path) -> Path:
    """A copy of BUNDLES (hard links where it can) whose agent pane loads the probe first, in INTO; BUNDLES, the
    shared cache, is untouched. With no agent pane in BUNDLES the copy is returned as it is."""
    if into.exists():
        shutil.rmtree(into)

    def link(src, dst):
        try:
            os.link(src, dst)
        except OSError:
            shutil.copy2(src, dst)

    shutil.copytree(bundles, into, copy_function=link, symlinks=True)
    pane = into / PANE
    index = pane / "index.html"
    if not index.is_file():
        return into
    html = index.read_text()
    tag = f'<script src="{PROBE_NAME}"></script>'
    found = re.search(r"<head[^>]*>", html, re.IGNORECASE)
    html = html[:found.end()] + "\n" + tag + html[found.end():] if found else tag + "\n" + html
    # A new file, never a write through a hard link into the cache.
    index.unlink()
    index.write_text(html)
    (pane / PROBE_NAME).unlink(missing_ok=True)
    shutil.copyfile(PROBE, pane / PROBE_NAME)
    return into


class Sink:
    """The probe's server. TOKEN_FILE is the copy's web-dev.json: its token is read on each request, so the sink
    can start before web-overlay.sh writes it there."""

    def __init__(self, out: Path, token_file: Path):
        self.dir = out / "page"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.snapshots = self.dir / ".dom"
        self.snapshots.mkdir(exist_ok=True)
        self.token_file = token_file
        self.lock = threading.Lock()
        self.parts: dict[str, dict] = {}
        self.taken: list[tuple[float, Path]] = []
        self.counts = {"console": 0, "dom": 0, "requests": 0, "dropped": 0}
        self.server = None
        self.thread = None

    def token(self) -> str:
        try:
            value = json.loads(self.token_file.read_text()).get("token")
        except (OSError, ValueError, AttributeError):
            return ""
        return value if isinstance(value, str) and TOKEN.fullmatch(value) else ""

    def start(self) -> int:
        sink = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                url = urllib.parse.urlsplit(self.path)
                found = ROUTE.match(url.path)
                if found:
                    # Before the answer: the probe sends its next chunk once this one is answered, and a look
                    # reads the files once the page has been answered.
                    sink.part(found.group(1), url.query)
                body = b"0" if found else b""
                self.send_response(200 if found else 404)
                self.send_header("Content-Type", "text/javascript")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                nonce = self.headers.get("X-Cmux-Dev-Nonce")
                token = sink.token()
                if nonce and token:
                    self.send_header("X-Cmux-Dev-Proof",
                                     hmac.new(token.encode(), nonce.encode(), hashlib.sha256).hexdigest())
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, name="look-page-sink", daemon=True)
        self.thread.start()
        return self.server.server_address[1]

    @property
    def url(self) -> str:
        return f"http://127.0.0.1:{self.server.server_address[1]}/"

    def stop(self) -> None:
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None

    def part(self, kind: str, query: str) -> None:
        """One chunk of a probe message (QUERY: id, i, n and d, a piece of the message's base64url); the whole
        message once its last chunk is in."""
        fields = dict(pair.partition("=")[::2] for pair in query.split("&"))

        def one(key: str) -> str:
            return fields.get(key, "")

        try:
            index, total = int(one("i")), int(one("n"))
        except ValueError:
            return
        mid = one("id")[:40]
        if not CHUNK_TEXT.fullmatch(mid) or not CHUNK_TEXT.fullmatch(one("d")) or not 0 <= index < total <= MAX_PARTS:
            return
        with self.lock:
            self.counts["requests"] += 1
            held = self.parts.setdefault(f"{kind}:{mid}", {"n": total, "got": {}, "t": time.time()})
            held["got"][index] = one("d")
            if len(held["got"]) < held["n"]:
                while len(self.parts) > MAX_OPEN:
                    self.parts.pop(min(self.parts, key=lambda k: self.parts[k]["t"]))
                    self.counts["dropped"] += 1
                return
            self.parts.pop(f"{kind}:{mid}", None)
        joined = "".join(held["got"][i] for i in range(held["n"]))
        try:
            message = json.loads(base64.urlsafe_b64decode(joined + "=" * (-len(joined) % 4)).decode())
        except (ValueError, binascii.Error):
            with self.lock:
                self.counts["dropped"] += 1
            return
        self.message(kind, message, time.time())

    def message(self, kind: str, message: dict, at: float) -> None:
        if not isinstance(message, dict):
            return
        with self.lock:
            if kind == "console":
                with open(self.dir / "console.jsonl", "a") as log:
                    for line in message.get("lines") or []:
                        if self.counts["console"] >= MAX_CONSOLE:
                            self.counts["dropped"] += 1
                        elif isinstance(line, dict):
                            log.write(json.dumps({"page": message.get("page"), "href": message.get("href"),
                                                  **line}) + "\n")
                            self.counts["console"] += 1
                return
            self.counts["dom"] += 1
            path = self.snapshots / f"{self.counts['dom']:05d}.json"
            path.write_text(json.dumps({"received": at, **message}))
            self.taken.append((at, path))
            while len(self.taken) > MAX_SNAPSHOTS:
                _, old = self.taken.pop(0)
                old.unlink(missing_ok=True)
            summary = {k: message.get(k) for k in ("page", "href", "t", "viewport", "newTabContext", "boxes",
                                                   "html_length")}
            summary["text"] = str(message.get("text") or "")[:400]
            with open(self.dir / "dom.jsonl", "a") as log:
                log.write(json.dumps({"received": at, "file": path.name, **summary}) + "\n")

    def snapshot_at(self, when: float) -> Path | None:
        """The DOM snapshot that was live at WHEN: the last one received by then."""
        with self.lock:
            live = [path for at, path in self.taken if at <= when and path.is_file()]
        return live[-1] if live else None

    def attach(self, out: Path) -> dict:
        """Each PNG under OUT gets OUT/<shot>.dom.json, the snapshot live when the PNG was written; the facts for
        the receipt. The snapshots no shot took are dropped (dom.jsonl keeps their summary)."""
        attached, none = [], []
        for png in sorted(out.rglob("*.png")):
            if self.dir in png.parents:
                continue
            found = self.snapshot_at(png.stat().st_mtime)
            if found is None:
                none.append(str(png.relative_to(out)))
                continue
            shutil.copyfile(found, png.with_suffix(".dom.json"))
            attached.append(str(png.relative_to(out)))
        shutil.rmtree(self.snapshots, ignore_errors=True)
        return {"how": "look-page-probe.js in the overlay's agent pane, its sink as web-dev.json's server",
                "console_file": "page/console.jsonl", "dom_file": "page/dom.jsonl", **self.counts,
                "shots_with_dom": attached, "shots_without_dom": none}
