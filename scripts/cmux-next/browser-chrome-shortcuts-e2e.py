#!/usr/bin/env python3
"""Live check that Chrome's page shortcuts work in a cmux browser tab, in both engines (#27619).

In Chrome a web page gets every key Chrome does not take itself, and the Edit and View chords
act on the page:
  - Cmd-Shift-V (and Cmd-Opt-Shift-V) paste the clipboard as plain text (Paste and Match Style);
  - Cmd-V pastes it with its formatting;
  - Cmd-Shift-R reloads the page bypassing the cache (the request carries `Cache-Control:
    no-cache`, a plain Cmd-R reload `max-age=0`).

For each engine (`openBrowser.chromium`, `openBrowser.webkit`) the script opens a local page and
checks, with no real key presses unless `--keys` is given: the router delivers Cmd-V, Cmd-Shift-V and
Cmd-Opt-Shift-V to the page, runs cmux's Cmd-B, Cmd-I and Shift-Cmd-E before the page, offers
Cmd-F (Find) to the page first in both engines, and resolves Cmd-Shift-R to Hard Reload (`debug.key` dry_run); Hard
Reload (`browserHardReload`, what the chord runs) reloads with `Cache-Control: no-cache`, read
from the script's own server, and Reload Page does not. On Chromium it also right-clicks a link
and checks that Open Link in New Tab creates the destination tab. With `--keys` (the app active, its page
window key) it also copies a rich-text source with Cmd-C, pastes it into a contenteditable with
each paste chord and reads what landed (bold kept or not), and presses Cmd-Shift-R. Keys go
through `debug.key` (the app's own dispatch: router, window, page, main menu), into the Chromium
page window for a Chromium tab. `--sweep` also prints the router's decision (`debug.key` dry_run)
for every Command chord on a letter, digit or punctuation key while the page has the keyboard:
the chords cmux takes from the page, which a reviewer compares with Chrome's own list.

The script attaches to an app already running through its debug socket and never launches or
quits the app.

Usage: browser-chrome-shortcuts-e2e.py --socket /tmp/cmux-debug-<tag>.sock [--engines chromium,webkit]
       [--sweep] [--keys] [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, http.server, json, os, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--engines", default="chromium,webkit")
parser.add_argument("--sweep", action="store_true", help="print the router's decision for every Command chord")
parser.add_argument("--keys", action="store_true",
                    help="also press the paste and reload chords (the app must be active: it copies to the clipboard)")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []
REQUESTS = []

PAGE = """<!doctype html><title>shortcuts {run}</title>
<a id=menuLink href="/context-link">Context menu link</a>
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
        if self.path not in ("/", "/context-link"):
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


def reload_request(run):
    """The request the next reload sends, after `run` starts it (None: no reload in 10 s)."""
    wait(lambda: evaluate("document.readyState === 'complete'"), 20, 0.5)
    count = len(REQUESTS)
    sent = run()
    reloaded = wait(lambda: len(REQUESTS) > count or None, 10)
    page = [r for r in REQUESTS[count:] if r["path"] == "/"]
    return (page[0] if reloaded and page else None), sent


def bypassed(request):
    return bool(request) and "no-cache" in (request.get("cache_control") or "") + (request.get("pragma") or "")


def check_link_menu(tab, page_url):
    """Choose a native link menu item and verify its new destination tab."""
    label = "Open Link in New Tab"
    destination = page_url + "context-link"
    tabs = rpc("browser.page.tabs", {"all": True}).get("tabs")
    if not tab or not tabs or tab not in {item["id"] for item in tabs}:
        row(label, "source tab in initial tab list", tabs, False)
        return
    before = {item["id"] for item in tabs}
    link = rpc("browser.page.eval", {"tab": tab, "script": """
        (() => {
            const link = document.getElementById('menuLink');
            if (!link) return null;
            link.scrollIntoView({block: 'center'});
            const {left, top, width, height} = link.getBoundingClientRect();
            const x = left + width / 2, y = top + height / 2;
            return document.elementFromPoint(x, y) === link ? {x, y, href: link.href} : null;
        })()"""}).get("value")
    if not link or link.get("href") != destination:
        row(label, destination, link, False)
        return
    try:
        click = rpc("browser.page.mouse", {"tab": tab, "kind": "click", "button": "right", "x": link["x"], "y": link["y"]})
        if click.get("native") is not True:
            row(label, "native right-click", click, False)
            return
        items = wait(lambda: (rpc("debug.menu") or {}).get("items"), 5)
        if label not in (items or []):
            row(label, "link context menu", items, False)
            return
        choice = rpc("debug.menu", {"choose": label})
        if choice.get("chose") != label:
            row(label, label, choice, False)
            return
    finally:
        if rpc("debug.menu").get("open"):
            rpc("debug.menu", {"dismiss": True})

    opened = wait(lambda: [item for item in rpc("browser.page.tabs", {"all": True}).get("tabs", [])
                           if item["id"] not in before and item.get("url") == destination], 5) or []
    row(label, "one new tab at " + destination, opened, len(opened) == 1)
    for item in opened:
        rpc("action.run", {"action": "closeTab", "target": "tab:" + item["id"]})


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

    # The router: the page gets every paste chord; Cmd-Shift-R is Hard Reload (offered to a
    # Chromium page first, as Chrome lets a page preventDefault it).
    for label, key, modifiers, want in [("Cmd-V", "v", ["cmd"], "deliver"), ("Cmd-Shift-V", "V", ["cmd", "shift"], "deliver"),
                                        ("Cmd-Opt-Shift-V", "V", ["cmd", "shift", "option"], "deliver"),
                                        ("Cmd-Shift-R", "R", ["cmd", "shift"], "browserHardReload")]:
        reply = rpc("debug.key", {"key": key, "modifiers": modifiers, "dry_run": True}) or {}
        routed = f"{reply.get('decision')}"
        row(f"{engine}: {label} routes", want, routed, want in routed)

    # cmux shortcuts run before the page (Lawrence 2026-11-11), so Cmd-B toggles the sidebar even in a
    # page that takes it for Bold. Only Find goes to the page first, in both engines (Chromium reports
    # an unhandled key; WebKit sends it back to NSApp.sendEvent), and cmux's Find runs if it comes back.
    for label, key, modifiers, want in [("Cmd-B", "b", ["cmd"], "run("), ("Cmd-I", "i", ["cmd"], "run("),
                                        ("Shift-Cmd-E", "E", ["cmd", "shift"], "run("), ("Cmd-F", "f", ["cmd"], "offerToPage")]:
        reply = rpc("debug.key", {"key": key, "modifiers": modifiers, "dry_run": True}) or {}
        routed = f"{reply.get('decision')}"
        row(f"{engine}: {label} routes", want, routed, routed.startswith(want))

    # Hard Reload as the chord runs it (the same action, without OS key focus): a request past the cache.
    request, sent = reload_request(lambda: rpc("action.run", {"action": "browserHardReload", "args": {}, "focus": True}))
    row(f"{engine}: Hard Reload (browserHardReload) bypasses the cache", "a request with Cache-Control: no-cache",
        f"request={request} ran={sent}", bypassed(request))
    # Reload Page still reloads (Chromium revalidates with max-age=0; WebKit's own reload headers vary).
    request, sent = reload_request(lambda: rpc("action.run", {"action": "browserReload", "args": {}, "focus": True}))
    row(f"{engine}: Reload (browserReload) reloads", "a reload request", f"request={request} ran={sent}", bool(request))

    if opts.keys:
        check_keys(engine, keys)
    if engine == "chromium":
        tab = next((entry for entry in (opened or {}).get("created", []) if entry.startswith("tab_")), None)
        check_link_menu(tab, base_url)


def check_keys(engine, keys):
    """Real paste chords through `debug.key`. Only meaningful while the app is active and the page
    window is key: Chromium's page view takes key equivalents only in the key window."""
    select_source()
    copied = keys.press("c", ["cmd"])
    for label, key, modifiers, want_bold in [("Cmd-V", "v", ["cmd"], True),
                                             ("Cmd-Shift-V", "V", ["cmd", "shift"], False),
                                             ("Cmd-Opt-Shift-V", "V", ["cmd", "shift", "option"], False)]:
        focused = focus_target()
        sent = keys.press(key, modifiers)
        html = wait(lambda: target_html() or None, 5) or ""
        bold = "<b" in html.lower() or "font-weight" in html.lower()
        row(f"{engine}: {label} pastes {'with' if want_bold else 'without'} formatting",
            f"bold27619 in the field, bold={want_bold}",
            f"focused={focused} html={html[:120]!r} sent={sent} copy={copied}",
            bool(focused) and "bold27619" in html and bold == want_bold)
    request, sent = reload_request(lambda: keys.press("R", ["cmd", "shift"]))
    row(f"{engine}: Cmd-Shift-R hard reloads", "a request with Cache-Control: no-cache", f"request={request} sent={sent}",
        bypassed(request))


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
