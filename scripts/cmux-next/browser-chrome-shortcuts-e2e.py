#!/usr/bin/env python3
"""Live check that Chrome's page shortcuts work in a cmux browser tab, in both engines (#27619).

In Chrome a web page gets every key Chrome does not take itself, and the Edit and View chords
act on the page:
  - Cmd-Shift-V (and Cmd-Opt-Shift-V) paste the clipboard as plain text (Paste and Match Style);
  - Cmd-V pastes it with its formatting;
  - Cmd-Shift-R reloads the page bypassing the cache (the request carries `Cache-Control:
    no-cache`, a plain Cmd-R reload `max-age=0`).

For each engine (`openBrowser.chromium`, `openBrowser.webkit`) the script opens a local page
with a rich-text source and a contenteditable target, copies the source with Cmd-C, pastes it
into the target with each paste chord and reads what landed (bold kept or not), then presses
Cmd-Shift-R and reads the reload request's headers from its own server. Keys go through
`debug.key` (the app's own dispatch: router, window, page, main menu), into the Chromium page
window for a Chromium tab. `--sweep` also prints the router's decision (`debug.key` dry_run)
for every Command chord on a letter, digit or punctuation key while the page has the keyboard:
the chords cmux takes from the page, which a reviewer compares with Chrome's own list.

The script attaches to an app already running through its debug socket and never launches or
quits the app.

Usage: browser-chrome-shortcuts-e2e.py --socket /tmp/cmux-debug-<tag>.sock [--engines chromium,webkit]
       [--sweep] [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, http.server, json, os, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--engines", default="chromium,webkit")
parser.add_argument("--sweep", action="store_true", help="print the router's decision for every Command chord")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []
REQUESTS = []

PAGE = """<!doctype html><title>shortcuts {run}</title>
<div id=src><b>bold27619</b> plain</div>
<div id=dst contenteditable style="min-height:40px;border:1px solid gray"></div>
<script>
window.__loads = (window.__loads || 0) + 1;
window.__keys = [];
addEventListener('keydown', e => __keys.push([e.key, e.metaKey, e.shiftKey, e.altKey].join(',')), true);
</script>"""


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        REQUESTS.append({"path": self.path, "cache_control": self.headers.get("Cache-Control"),
                         "pragma": self.headers.get("Pragma")})
        if self.path != "/":
            self.send_response(404)
            self.end_headers()
            return
        body = PAGE.format(run=os.getpid()).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        # Cacheable, so a plain reload may revalidate and only a hard reload must bypass the cache.
        self.send_header("Cache-Control", "max-age=600")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
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


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def evaluate(script):
    reply = rpc("browser.page.eval", {"script": script}, timeout=20) or {}
    return reply.get("value") if isinstance(reply, dict) else None


def row(check, expected, observed, ok):
    ROWS.append({"check": check, "expected": expected, "observed": observed, "ok": ok})
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


class Keys:
    """Key-downs through `debug.key`, into the Chromium page window when the tab is Chromium."""

    def __init__(self):
        probe = rpc("debug.key", {"key": "tab", "modifiers": ["ctrl"], "dry_run": True, "target": "page"}) or {}
        # dry_run needs the shell window, so a page target answers with that error when a Chromium
        # page window exists, and with "no Chromium page window" for a WebKit tab.
        self.target = {} if "no Chromium page window" in str(probe.get("error")) else {"target": "page"}

    def press(self, key, modifiers):
        reply = rpc("debug.key", dict(self.target, key=key, modifiers=modifiers)) or {}
        return {k: reply.get(k) for k in ("handled_by", "action", "refused_action", "error", "trace") if reply.get(k)}


def decision(key, modifiers):
    reply = rpc("debug.key", {"key": key, "modifiers": modifiers, "dry_run": True}) or {}
    return reply.get("action") or reply.get("decision") or reply.get("error")


def focus_target():
    return evaluate("(() => { const d = document.getElementById('dst'); d.innerHTML = ''; d.focus();"
                    " return document.activeElement === d; })()")


def select_source():
    return evaluate("(() => { const r = document.createRange(); r.selectNodeContents(document.getElementById('src'));"
                    " const s = getSelection(); s.removeAllRanges(); s.addRange(r); return String(s); })()")


def target_html():
    return evaluate("document.getElementById('dst').innerHTML") or ""


def check_engine(engine, base_url):
    before = len(REQUESTS)
    opened = rpc("action.run", {"action": f"openBrowser.{engine}", "args": {"url": base_url}, "focus": True}, timeout=120)
    loaded = wait(lambda: evaluate("document.readyState === 'complete' && !!document.getElementById('dst')"), 60, 0.5)
    if not loaded:
        row(f"{engine}: page loads", "loaded", opened, False)
        return
    wait(lambda: (rpc("context.keys") or {}).get("keys", {}).get("surfaceKind") == "page" or None, 15)
    keys = Keys()
    print(f"{engine}: keys go to {keys.target or 'the shell window'}; first load {REQUESTS[before:]}", flush=True)

    if opts.sweep:
        sweep(engine)

    # Copy the rich source with Cmd-C, so each paste below reads the same clipboard.
    select_source()
    copied = keys.press("c", ["cmd"])
    for label, key, modifiers, want_bold in [("Cmd-V", "v", ["cmd"], True),
                                             ("Cmd-Shift-V", "V", ["cmd", "shift"], False),
                                             ("Cmd-Opt-Shift-V", "V", ["cmd", "shift", "option"], False)]:
        focused = focus_target()
        sent = keys.press(key, modifiers)
        html = wait(lambda: target_html() or None, 5) or ""
        pasted = "bold27619" in html
        bold = "<b" in html.lower() or "font-weight" in html.lower()
        row(f"{engine}: {label} pastes {'with' if want_bold else 'without'} formatting",
            f"bold27619 in the field, bold={want_bold}",
            f"focused={focused} html={html[:120]!r} sent={sent} copy={copied}",
            bool(focused) and pasted and bold == want_bold)

    # Cmd-Shift-R: a reload whose request bypasses the cache.
    loads = evaluate("window.__loads")
    count = len(REQUESTS)
    sent = keys.press("R", ["cmd", "shift"])
    reloaded = wait(lambda: len(REQUESTS) > count or None, 10)
    request = REQUESTS[count] if reloaded else None
    bypassed = bool(request) and "no-cache" in (request.get("cache_control") or "") + (request.get("pragma") or "")
    row(f"{engine}: Cmd-Shift-R hard reloads", "a request with Cache-Control: no-cache",
        f"request={request} loads_before={loads} sent={sent}", bypassed)

    # Cmd-R stays a plain reload (it may revalidate, it must not bypass the cache).
    wait(lambda: evaluate("document.readyState === 'complete'"), 20, 0.5)
    count = len(REQUESTS)
    sent = keys.press("r", ["cmd"])
    reloaded = wait(lambda: len(REQUESTS) > count or None, 10)
    request = REQUESTS[count] if reloaded else None
    row(f"{engine}: Cmd-R reloads", "a reload request", f"request={request} sent={sent}", bool(request))


def sweep(engine):
    keys = "abcdefghijklmnopqrstuvwxyz0123456789[]\\;',./`-="
    shifted = {"[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?", "`": "~",
               "-": "_", "=": "+"}
    taken = []
    for key in keys:
        for modifiers in (["cmd"], ["cmd", "shift"], ["cmd", "option"], ["cmd", "shift", "option"], ["ctrl", "cmd"]):
            name = key
            if "shift" in modifiers:
                name = key.upper() if key.isalpha() else shifted.get(key, key)
            routed = decision(name, modifiers)
            if routed and "deliver" not in str(routed):
                taken.append(f"{'+'.join(modifiers)}+{name}={routed}")
    print(f"{engine}: chords cmux takes from the page ({len(taken)}): {', '.join(taken)}", flush=True)
    with open(os.path.join(opts.out, f"browser-chrome-shortcuts-sweep-{engine}.json"), "w") as handle:
        json.dump(taken, handle)


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base_url = f"http://127.0.0.1:{server.server_address[1]}/"
    for engine in opts.engines.split(","):
        check_engine(engine, base_url)
    with open(os.path.join(opts.out, "browser-chrome-shortcuts.json"), "w") as handle:
        json.dump({"rows": ROWS, "requests": REQUESTS}, handle)
    passed = sum(1 for r in ROWS if r["ok"])
    print(f"RESULT {passed}/{len(ROWS)}", flush=True)
    return 0 if ROWS and passed == len(ROWS) else 1


if __name__ == "__main__":
    sys.exit(main())
