#!/usr/bin/env python3
"""Mac reference renders of webview gallery stages, in the app's own engines (B7, webviews-linux-parity).

The Linux gallery (scripts/gallery-matrix/runner.ts) renders each stage in headless Chromium and
Playwright WebKit. This renders the same stages in a built, tagged cmux-next app on a Mac: once with
browser.defaultEngine "chromium" (CEF, the engine the agent pane shows in by default) and once with
"webkit" (WKWebView). No Playwright: the app is driven through its own CLI (`cmux browser page ...`),
the way scripts/cmux-next/cef-pak-render-check.py drives it.

For each manifest case and engine it navigates the browser tab to frame.html?<params>, waits for the
stage's `data-gallery-ready`, and screenshots the stage element ([data-gallery-capture], else #root,
as captureClip in runner.ts). It writes OUT/results.json in the runner's shape (id, engine, screenshot,
params, plus the page's devicePixelRatio, viewport and fonts in `env`), so
scripts/gallery-matrix/parity.py pairs it with a Linux run.

  gallery-mac-reference.py --tag T --app "<...>/cmux DEV T.app" --gallery DIR --manifest FILE --out DIR
                           [--engines chromium,webkit] [--limit N] [--input-keys FILE]
Fleet: scripts/measure/gallery-mac-reference.sh builds the app and the gallery and runs this.
Exits 0 once the app came up for every engine (read results.json); 1 when it did not.
"""
import argparse, functools, http.server, json, os, socketserver, subprocess, sys, tempfile, threading, time, urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pathlib import Path
import desktop_goldens as goldens
from state_wait import wait_stable, wait_until  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--gallery", required=True, help="the built gallery (bun run gallery:build, CMUX_GALLERY_OUT_DIR)")
parser.add_argument("--manifest", required=True, help="webviews/scripts/gallery/manifest.ts output")
parser.add_argument("--out", required=True)
parser.add_argument("--engines", default="chromium,webkit")
parser.add_argument("--limit", type=int, default=0)
parser.add_argument("--ready-timeout-ms", type=int, default=20000)
parser.add_argument("--golden-root", type=Path)
parser.add_argument("--runtime", help="versioned reference Mac display, font and OS profile")
parser.add_argument("--rev", help="source revision of the tagged app")
parser.add_argument("--input-keys", help="cmux-shotdiff desktop-gallery key metadata")
opts = parser.parse_args()
if opts.golden_root and not (opts.runtime and opts.rev):
    parser.error("--golden-root requires --runtime and --rev")
TAG, APP, OUT = opts.tag, os.path.abspath(opts.app.rstrip("/")), os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
INPUT_KEYS = {}
if opts.input_keys:
    with open(opts.input_keys, encoding="utf-8") as handle:
        INPUT_KEYS = json.load(handle)
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next(p for p in sorted(os.listdir(os.path.join(APP, "Contents/MacOS"))) if not p.endswith(".dylib"))
BINARY = os.path.join(APP, "Contents/MacOS", BINARY)
CLI_ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1", "CMUX_TAG": TAG,
           "CMUX_BUNDLE_ID": f"com.cmuxterm.app.debug.{TAG}", "CMUX_BUNDLED_CLI_PATH": CLI}
# Large enough for the widest component stage; the stage element is what is captured.
WINDOW_FRAME = "20,20,1680,1200"
CAPTURE_SELECTOR = os.environ.get("CMUX_GALLERY_CAPTURE_SELECTOR") or goldens.GALLERY_SELECTOR


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=os.path.abspath(opts.gallery)))
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_address[1]}"


def cli(*args, timeout=60):
    try:
        done = subprocess.run([CLI, *args], env=CLI_ENV, capture_output=True, text=True, timeout=timeout)
        return done.returncode, (done.stdout + done.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def rpc(method, params=None):
    import socket
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def case_url(item):
    path = item.get("path_or_url") or "frame.html"
    if "#" in path:
        return f"{BASE}/{path.lstrip('/')}"
    query = urllib.parse.urlencode({k: str(v) for k, v in (item.get("params") or {}).items()})
    return f"{BASE}/{path.lstrip('/')}" + (f"?{query}" if query else "")


# What a Linux render can differ by: the scale, the viewport, the faces the stage asked for and got,
# and how wide a scrollbar is (0 for overlay scrollbars).
READ_ENV = """(() => {
  const probe = document.createElement('div');
  probe.style.cssText = 'position:absolute;top:-999px;width:100px;height:100px;overflow:scroll';
  document.body.appendChild(probe);
  const scrollbar = probe.offsetWidth - probe.clientWidth;
  probe.remove();
  const root = document.querySelector('[data-gallery-capture]') || document.querySelector('#root');
  const rect = root ? root.getBoundingClientRect() : null;
  const body = getComputedStyle(document.body);
  const faces = document.fonts ? [...document.fonts].filter((f) => f.status === 'loaded').map((f) => f.family) : [];
  return JSON.stringify({dpr: window.devicePixelRatio, viewport: [innerWidth, innerHeight], scrollbar,
    stage: rect && [rect.left, rect.top, rect.width, rect.height], bodyFont: body.fontFamily,
    loadedFaces: [...new Set(faces)].slice(0, 20), ready: document.documentElement.dataset.galleryReady ?? null,
    ua: navigator.userAgent});
})()"""


def page_json(script):
    code, out = cli("browser", "page", "eval", script)
    try:
        value = json.loads(out)
        return json.loads(value) if isinstance(value, str) else value
    except ValueError:
        return {"eval": [code, out[:400]]}


def safe(name):
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in name)


def render(item, engine):
    row = {"id": item["id"], "engine": engine, "params": item.get("params") or {}, "source": "mac-app"}
    variants = INPUT_KEYS.get("variants", {}) if isinstance(INPUT_KEYS, dict) else {}
    if isinstance(variants.get(engine), dict):
        key = variants[engine].get("key")
        family = INPUT_KEYS.get("family", "desktop-gallery")
        row["input_key"] = {"schema": "cmux.desktop-input-key/v1", "family": family,
                             "runtime": "mac-gallery", "variant": engine,
                             "key": key, "files": variants[engine].get("files"),
                             "revision": variants[engine].get("revision", variants[engine].get("rev", INPUT_KEYS.get("revision"))),
                             "store": f"{family}-mac-gallery-{engine}-{key}"}
    url = case_url(item)
    code, out = cli("browser", "page", "navigate", url)
    if code != 0:
        row["error"] = f"navigate: {out[:300]}"
        return row
    code, out = cli("browser", "page", "wait", "html[data-gallery-ready]", "--timeout-ms", str(opts.ready_timeout_ms),
                    timeout=opts.ready_timeout_ms / 1000 + 30)
    row["ready"] = code == 0
    if code != 0:
        row["error"] = f"never ready: {out[:300]}"
    # The stage is ready when painted and still; one more stable read covers late font swaps.
    wait_stable(lambda: cli("browser", "page", "eval", "document.fonts ? document.fonts.status : 'n/a'")[1],
                f"{item['id']} fonts", timeout=5, interval=0.2, raise_on_timeout=False)
    row["env"] = page_json(READ_ENV)
    name = f"{safe(item['id'])}-{engine}.png"
    code, out = cli("browser", "page", "screenshot", "--out", os.path.join(OUT, name), "--selector", CAPTURE_SELECTOR)
    if code == 0 and os.path.exists(os.path.join(OUT, name)):
        row["screenshot"] = name
    else:
        row.setdefault("error", f"screenshot: {out[:300]}")
    return row


def run_engine(engine, cases):
    scratch = tempfile.mkdtemp(prefix=f"gallery-mac-ref-{TAG}-{engine}-")
    open(os.path.join(scratch, "ghostty"), "w").close()
    config = os.path.join(scratch, "cmux.json")
    with open(config, "w") as handle:
        json.dump({"browser": {"defaultEngine": engine}}, handle)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": WINDOW_FRAME}
    log = open(os.path.join(OUT, f"app-{TAG}-{engine}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    rows = []
    try:
        if not wait_until(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"),
                          f"the tagged app ({engine})", timeout=120, interval=0.5, raise_on_timeout=False):
            print(f"gallery-mac-reference: the tagged app did not come up for {engine}", flush=True)
            return None
        wait_until(lambda: any(w.get("panes") for w in (rpc("debug.surfaces") or {}).get("windows") or []),
                   "the first workspace's pane", timeout=30, interval=0.2, raise_on_timeout=False)
        first = cases[0] if cases else {"id": "blank", "path_or_url": "frame.html"}
        opened = cli("browser", "open", case_url(first))
        cli("browser", "page", "wait", "--load-state", "complete", "--timeout-ms", "30000", timeout=45)
        print(f"{engine}: open {opened}; ua {cli('browser', 'page', 'eval', 'navigator.userAgent')[1][:200]}", flush=True)
        for index, item in enumerate(cases):
            row = render(item, engine)
            rows.append(row)
            print(f"[{engine} {index + 1}/{len(cases)}] {item['id']}: "
                  f"{'ok' if row.get('screenshot') and not row.get('error') else row.get('error')}", flush=True)
        return rows
    finally:
        app.terminate()
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
        # The next engine's app opens the same socket path.
        wait_until(lambda: not os.path.exists(SOCKET), "the app's socket to close", timeout=15, interval=0.2,
                   raise_on_timeout=False)


def main():
    cases = json.load(open(opts.manifest))
    if isinstance(cases, dict):
        cases = cases.get("cases", [])
    if opts.limit:
        cases = cases[: opts.limit]
    results, came_up = [], True
    started = time.time()
    for engine in [e.strip() for e in opts.engines.split(",") if e.strip()]:
        store = None
        if opts.golden_root:
            store = goldens.gallery_store(opts.golden_root, opts.runtime, opts.rev, engine, cases, CAPTURE_SELECTOR)
            if store.is_dir():
                results.extend(goldens.restore_gallery(store, cases, engine, Path(OUT)))
                continue
        rows = run_engine(engine, cases)
        if rows is None:
            came_up = False
            continue
        if store and rows and all(row.get("screenshot") and not row.get("error") for row in rows):
            if not goldens.file_gallery(store, cases, rows, engine, Path(OUT)):
                rows = goldens.restore_gallery(store, cases, engine, Path(OUT))
        results.extend(rows)
    with open(os.path.join(OUT, "results.json"), "w") as handle:
        json.dump(results, handle, indent=1)
    with open(os.path.join(OUT, "run.json"), "w") as handle:
        json.dump({"tag": TAG, "host": os.uname().nodename, "cases": len(cases), "seconds": round(time.time() - started, 1),
                   "engines": opts.engines, "selector": CAPTURE_SELECTOR,
                   "reference_runtime": opts.runtime, "revision": opts.rev,
                   "input_keys": INPUT_KEYS or None}, handle, indent=1)
    server.shutdown()
    return 0 if came_up else 1


if __name__ == "__main__":
    sys.exit(main())
