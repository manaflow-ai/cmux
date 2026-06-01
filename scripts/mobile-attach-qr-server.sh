#!/usr/bin/env bash
# Tiny HTTP server that regenerates the mobile attach QR on every page hit
# so the QR you see is always linked to the currently-running Mac instance.
# Defaults to 127.0.0.1:17321 to match the existing tools/cmux-tag-opener
# pattern. Stop with Ctrl-C.

set -euo pipefail

PORT="${PORT:-17321}"
TAG="${CMUX_TAG:-mobile}"
IOS_TAG="${CMUX_IOS_TAG:-$TAG}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

export TAG IOS_TAG SCRIPT_DIR

exec python3 - "$PORT" <<'PYEOF'
import http.server
import json
import os
import re
import socketserver
import subprocess
import sys
import threading
import time

PORT = int(sys.argv[1])
# The tags this server launched with. They are the fallback when no marker file
# exists yet; once a reload script writes the marker, the live tags below track
# it so the QR always pairs against the freshest build.
INITIAL_TAG = os.environ["TAG"]
INITIAL_IOS_TAG = os.environ["IOS_TAG"]
SCRIPT_DIR = os.environ["SCRIPT_DIR"]
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
# `ios/scripts/reload.sh` builds + installs + launches the tagged iOS app on
# the connected iPhone. The Open button shells out to it so a stale (or
# missing) device build is brought current before launch — no manual reload.
IOS_RELOAD = os.path.join(PROJECT_DIR, "ios", "scripts", "reload.sh")
IOS_TEAM = os.environ.get("CMUX_IOS_TEAM", "7WLXT3NR37")
# Build can take a couple minutes (xcodebuild incremental + install over the
# tunnel); give it generous headroom.
IOS_BUILD_TIMEOUT_SECONDS = 600
QR_SCRIPT = os.path.join(SCRIPT_DIR, "mobile-attach-qr.sh")
TMP_ROOT = os.environ.get("TMPDIR", "/tmp").rstrip("/") or "/tmp"

# Marker the reload scripts write so this server tracks the freshest build
# without being restarted. `ios/scripts/reload.sh --tag Y` writes ios_tag=Y.
# The server reads it on every request (see `refresh_tags`), so the QR, the
# Open button, and the bundle id always reflect whatever was last reloaded.
# FIXED `/tmp` path (not TMPDIR-derived): the reload script and this server run
# in different shells/sessions whose per-session `TMPDIR` differ, so the
# rendezvous file must live at a machine-shared location both can find.
TAG_MARKER_PATH = "/tmp/cmux-mobile-attach-qr-tags.json"

# Live tags + their derived paths. `refresh_tags` keeps these in sync with the
# marker; everything downstream reads these globals, never the INITIAL_* ones.
TAG = INITIAL_TAG
IOS_TAG = INITIAL_IOS_TAG
OUT_DIR = ""
IOS_TAG_SLUG = ""
IOS_BUNDLE_ID = ""


def _ios_slug(tag: str) -> str:
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", tag.lower())).strip("-") or "dev"


def _apply_tags(mac_tag: str, ios_tag: str) -> None:
    """Set the live tag globals and recompute everything derived from them."""
    global TAG, IOS_TAG, OUT_DIR, IOS_TAG_SLUG, IOS_BUNDLE_ID
    TAG = mac_tag
    IOS_TAG = ios_tag
    OUT_DIR = os.path.join(TMP_ROOT, f"cmux-mobile-attach-qr-{TAG}")
    IOS_TAG_SLUG = _ios_slug(IOS_TAG)
    IOS_BUNDLE_ID = f"dev.cmux.ios.{IOS_TAG_SLUG}"


def refresh_tags() -> None:
    """Re-read the reload-written marker so the server tracks the freshest
    build. Falls back to the launch-time tag for any key the marker omits, so a
    half-written or partial marker can never blank a tag."""
    mac_tag, ios_tag = INITIAL_TAG, INITIAL_IOS_TAG
    try:
        with open(TAG_MARKER_PATH, "r") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            if isinstance(data.get("mac_tag"), str) and data["mac_tag"]:
                mac_tag = data["mac_tag"]
            if isinstance(data.get("ios_tag"), str) and data["ios_tag"]:
                ios_tag = data["ios_tag"]
    except (FileNotFoundError, ValueError, OSError):
        pass
    if mac_tag != TAG or ios_tag != IOS_TAG or not OUT_DIR:
        _apply_tags(mac_tag, ios_tag)
        # Tag changed → the cached QR points at the old OUT_DIR. Force the next
        # page hit to regenerate against the new tag's socket and out-dir.
        global _LAST_GEN_TS
        _LAST_GEN_TS = 0.0


_apply_tags(INITIAL_TAG, INITIAL_IOS_TAG)
refresh_tags()

_LOCK = threading.Lock()
_LAST_GEN_TS = 0.0
# Don't shell out more often than this, protects the Mac socket from
# accidental load if a browser hammers refresh.
MIN_REGEN_INTERVAL_SECONDS = 2.0

DERIVED_DATA_ROOT = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")


def tagged_app_path() -> str:
    """The exact .app bundle that the launch path will open. Keep this in
    lockstep with the CMUX Tag Opener's `appURL(for:)` resolution so the
    button label and the click handler can't drift apart."""
    return os.path.join(
        DERIVED_DATA_ROOT,
        f"cmux-{TAG}",
        "Build",
        "Products",
        "Debug",
        f"cmux DEV {TAG}.app",
    )


def tagged_app_executable() -> str:
    return os.path.join(tagged_app_path(), "Contents", "MacOS", "cmux DEV")


def app_info() -> dict:
    """Single source of truth for what 'Open cmux DEV <tag>' actually does.
    Returned to the page so the label always reflects reality (build mtime,
    on-disk presence, whether a process is currently running)."""
    app_path = tagged_app_path()
    exe_path = tagged_app_executable()
    info: dict = {
        "tag": TAG,
        "ios_tag": IOS_TAG,
        "app_path": app_path,
        "exe_path": exe_path,
        "exists": False,
        "mtime": None,
        "running_pid": None,
    }
    try:
        st = os.stat(exe_path)
        info["exists"] = True
        info["mtime"] = int(st.st_mtime)
    except FileNotFoundError:
        pass
    try:
        out = subprocess.run(
            ["pgrep", "-f", f"cmux DEV {TAG}.app/Contents/MacOS/cmux DEV"],
            check=False,
            timeout=2,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout.decode().strip()
        if out:
            info["running_pid"] = int(out.splitlines()[0])
    except Exception:
        pass
    return info


def regenerate(force: bool = False) -> tuple[bool, str]:
    global _LAST_GEN_TS
    now = time.time()
    with _LOCK:
        if not force and now - _LAST_GEN_TS < MIN_REGEN_INTERVAL_SECONDS:
            return True, "cached"
        env = os.environ.copy()
        env["CMUX_TAG"] = TAG
        try:
            subprocess.run(
                [QR_SCRIPT, "--tag", TAG, "--out-dir", OUT_DIR],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
                timeout=15,
            )
        except subprocess.CalledProcessError as exc:
            return False, exc.stderr.decode("utf-8", errors="replace")
        except subprocess.TimeoutExpired:
            return False, "regenerate timed out"
        _LAST_GEN_TS = now
        return True, "regenerated"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        # Stay quiet, the cmux helper pane is the visible signal.
        return

    def do_GET(self):
        refresh_tags()
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._serve_qr_page()
            return
        if path == "/healthz":
            self._send(200, "text/plain", b"ok")
            return
        if path == "/ticket.json":
            self._serve_ticket_json()
            return
        if path == "/open-tag":
            self._open_tag()
            return
        if path == "/app-info":
            self._send(200, "application/json", json.dumps(app_info()).encode())
            return
        self._send(404, "text/plain", b"not found")

    def do_POST(self):
        refresh_tags()
        # Mirror /open-tag so a `fetch('/open-tag', {method:'POST'})` works too.
        if self.path.split("?", 1)[0] == "/open-tag":
            self._open_tag()
            return
        self._send(404, "text/plain", b"not found")

    def _open_tag(self) -> None:
        # iOS (the dogfood target): build + install + launch the tagged app on
        # the connected iPhone so a stale or missing device build is brought
        # current before launch. xcodebuild's incremental build makes this a
        # near no-op when nothing changed. This is the "auto build then open"
        # behavior — no separate manual reload.
        ios_result = self._build_and_launch_ios()
        # macOS: launch the tagged `.app` via the CMUX Tag Opener at :17320 if
        # it is already built (it must be, to be serving this QR). We do not
        # auto-build the Mac app here — that is a heavier macOS reload that
        # would restart this very server's host app.
        info = app_info()
        if info["exists"]:
            mac_result = self._launch_mac_tag()
        else:
            mac_result = f"no-build app_path={info['app_path']}"
        body = (
            f"mac:{mac_result}\nios:{ios_result}\n"
        ).encode("utf-8")
        self._send(200, "text/plain", body)

    def _build_and_launch_ios(self) -> str:
        """Build, install, and launch the tagged iOS app on the connected
        iPhone via `ios/scripts/reload.sh --device-only`. Blocks until the
        build finishes (the page shows a building state); the threading server
        keeps serving other requests meanwhile."""
        if not os.path.exists(IOS_RELOAD):
            return f"no-reload-script ({IOS_RELOAD})"
        cmd = [IOS_RELOAD, "--tag", IOS_TAG, "--device-only", "--team", IOS_TEAM]
        env = os.environ.copy()
        env["CMUX_TAG"] = IOS_TAG
        try:
            proc = subprocess.run(
                cmd,
                cwd=PROJECT_DIR,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=IOS_BUILD_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            return f"timeout (>{IOS_BUILD_TIMEOUT_SECONDS}s)"
        except Exception as exc:  # pragma: no cover - defensive
            return f"error {exc!r}"
        out = (proc.stdout or b"").decode("utf-8", errors="replace")
        if "physical device reload succeeded" in out:
            return "built+launched"
        if proc.returncode == 0:
            return "built (launch state unknown)"
        tail = [ln for ln in out.splitlines() if ln.strip()][-3:]
        return f"failed exit={proc.returncode}: " + " | ".join(tail)

    def _launch_mac_tag(self) -> str:
        url = f"http://127.0.0.1:17320/{TAG}"
        try:
            subprocess.run(
                ["curl", "-fsS", "-o", "/dev/null", url],
                check=True,
                timeout=5,
            )
            return "ok"
        except subprocess.CalledProcessError as exc:
            return f"failed exit={exc.returncode}"
        except subprocess.TimeoutExpired:
            return "timeout"

    def _launch_ios_app(self) -> str:
        device_id = self._find_iphone_device_id()
        if device_id is None:
            return "no-iphone-attached"
        try:
            subprocess.run(
                [
                    "xcrun", "devicectl", "device", "process", "launch",
                    "--device", device_id,
                    IOS_BUNDLE_ID,
                ],
                check=True,
                timeout=15,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
            )
            return f"ok device={device_id[:8]}"
        except subprocess.CalledProcessError as exc:
            tail = (exc.stderr or b"").decode("utf-8", errors="replace").strip().splitlines()[-1:]
            tail_text = (" ".join(tail)) if tail else ""
            return f"failed exit={exc.returncode} {tail_text}"
        except subprocess.TimeoutExpired:
            return "timeout"

    def _find_iphone_device_id(self) -> str | None:
        try:
            out = subprocess.run(
                ["xcrun", "devicectl", "list", "devices"],
                check=True, timeout=8,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
            ).stdout.decode("utf-8", errors="replace")
        except Exception:
            return None
        # Pick the first line that has an iPhone model and is reachable.
        # devicectl prints state like "available (paired)" or "connected";
        # both mean the host can talk to the device. Skip "unavailable".
        for line in out.splitlines():
            if "iPhone" not in line:
                continue
            if "unavailable" in line:
                continue
            if "available" not in line and "connected" not in line:
                continue
            # UUIDs are 36 chars with 4 dashes. Pick the first such token.
            for part in line.split():
                if len(part) == 36 and part.count("-") == 4:
                    return part
        return None

    def _serve_qr_page(self) -> None:
        ok, msg = regenerate()
        html_path = os.path.join(OUT_DIR, "index.html")
        if not ok or not os.path.exists(html_path):
            body = (
                "<html><body><h1>QR generation failed</h1>"
                f"<pre>{msg}</pre></body></html>"
            ).encode("utf-8")
            self._send(500, "text/html; charset=utf-8", body)
            return
        with open(html_path, "rb") as fh:
            html = fh.read()
        # Inject a meta refresh + a small banner + an "Open cmux DEV <tag>"
        # button that hits the CMUX Tag Opener at 127.0.0.1:17320.
        marker = b"</head>"
        injection = (
            b'<meta http-equiv="refresh" content="45">\n'
            b'<style>'
            b'.qr-fresh-banner{position:fixed;top:8px;right:12px;'
            b'background:#16a34a;color:#fff;padding:4px 10px;border-radius:8px;'
            b'font:600 12px/1.2 -apple-system,system-ui,sans-serif;}'
            b'.qr-open-tag{position:fixed;top:8px;left:12px;display:inline-block;'
            b'background:#1f2937;color:#fff;padding:6px 14px;border-radius:8px;'
            b'font:600 13px/1.2 -apple-system,system-ui,sans-serif;'
            b'text-decoration:none;border:1px solid #374151;}'
            b'.qr-open-tag:hover{background:#111827;}'
            b'.qr-open-tag code{background:rgba(255,255,255,0.12);padding:1px 5px;'
            b'border-radius:4px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;}'
            b'</style>\n'
        )
        if marker in html:
            html = html.replace(marker, injection + marker, 1)
        body_marker = b"<body"
        # The button's visible text, tooltip, and enabled state all come
        # from `/app-info`. That endpoint shares its truth with `_open_tag`
        # so the label can't claim a build the launch path can't deliver.
        banner = (
            b'<button class="qr-open-tag" type="button" id="cmux-open-btn" disabled '
            b'title="resolving build..." '
            b'onclick="cmuxOpenTag(this)">resolving...</button>'
            + b'<div class="qr-fresh-banner">live, regenerates every 45s</div>'
            + b'<script>(function(){\n'
            + b'var cmuxBuilding=false;\n'
            + b'function fmtMtime(epoch){if(!epoch)return"never";\n'
            + b'  var ageS=Math.max(0,(Date.now()/1000)-epoch);\n'
            + b'  if(ageS<60)return Math.floor(ageS)+"s ago";\n'
            + b'  if(ageS<3600)return Math.floor(ageS/60)+"m ago";\n'
            + b'  if(ageS<86400)return Math.floor(ageS/3600)+"h ago";\n'
            + b'  return Math.floor(ageS/86400)+"d ago";}\n'
            + b'function refresh(){fetch("/app-info",{cache:"no-store"})\n'
            + b'  .then(function(r){return r.json();}).then(function(info){\n'
            + b'    var btn=document.getElementById("cmux-open-btn");\n'
            + b'    if(!btn||cmuxBuilding)return;\n'
            + b'    var built=fmtMtime(info.mtime);\n'
            + b'    var running=info.running_pid?(" \\u00b7 running pid "+info.running_pid):"";\n'
            + b'    if(info.exists){\n'
            + b'      btn.disabled=false;\n'
            + b'      btn.innerHTML="Open <code>cmux DEV "+info.tag+"</code> \\u00b7 built "+built+running;\n'
            + b'      btn.title=info.app_path;\n'
            + b'    }else{\n'
            + b'      btn.disabled=true;\n'
            + b'      btn.innerHTML="<code>cmux DEV "+info.tag+"</code> not built";\n'
            + b'      btn.title="missing on disk: "+info.app_path;\n'
            + b'    }\n'
            + b'  }).catch(function(){});}\n'
            + b'window.cmuxOpenTag=function(btn){\n'
            + b'  if(btn.disabled)return;\n'
            + b'  cmuxBuilding=true;btn.disabled=true;\n'
            + b'  btn.innerHTML="building \\u0026 opening\\u2026 (~1 min)";\n'
            + b'  fetch("/open-tag",{method:"POST"}).then(function(r){return r.text();})\n'
            + b'   .then(function(t){btn.innerHTML="opened \\u00b7 "+t.replace(/\\n/g," ").trim();})\n'
            + b'   .catch(function(){btn.innerHTML="open failed (see helper pane)";})\n'
            + b'   .finally(function(){cmuxBuilding=false;btn.disabled=false;refresh();});};\n'
            + b'refresh();setInterval(refresh,2000);}());</script>\n'
        )
        if body_marker in html:
            insert_at = html.find(b">", html.find(body_marker)) + 1
            html = html[:insert_at] + banner + html[insert_at:]
        self._send(200, "text/html; charset=utf-8", html)

    def _serve_ticket_json(self) -> None:
        ok, msg = regenerate()
        path = os.path.join(OUT_DIR, "attach-ticket.raw.json")
        if not ok or not os.path.exists(path):
            self._send(500, "application/json", json.dumps({"error": msg}).encode())
            return
        with open(path, "rb") as fh:
            self._send(200, "application/json", fh.read())

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# Generate once at startup so the first request is instant.
regenerate(force=True)

with ThreadingServer(("127.0.0.1", PORT), Handler) as httpd:
    print(f"mobile QR server: http://127.0.0.1:{PORT}/  (tag={TAG}, ios_tag={IOS_TAG})")
    print(f"  health:  http://127.0.0.1:{PORT}/healthz")
    print(f"  ticket:  http://127.0.0.1:{PORT}/ticket.json")
    print("Ctrl-C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping QR server")
PYEOF
