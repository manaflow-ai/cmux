"""The page dialog rows of chromium-host-bench.py --native-ui (p01-process-063): a Chromium page's alert, confirm,
prompt and HTTP sign-in ask in cmux's own dialog over the tab (feature `chromiumPageDialogs`, CEFPageDialogs), never
in a Chromium widget, in process and in the Chromium Host:

  alert       alert(): a `browser.dialog.javascript` dialog; OK returns to the page
  confirm     confirm(): the same dialog; OK makes confirm() true
  prompt      prompt(): the same dialog with a text field; OK returns the typed text
  http_auth   a page behind HTTP Basic authentication: a `browser.dialog.httpAuth` dialog; Sign In with the
              bench server's user name and password loads the page

Each row passes when `debug.dialog` lists the dialog within the deadline and the page sees the answer the row gave
through the dialog's own press path (`debug.dialog` set and press). http_auth navigates the tab away, so it runs last.
"""
import base64
import http.server
import threading
import time

PAGE = """<button id=alert style="top:400px" onclick="alert('native-ui alert'); S.alert = 'closed'">alert</button>
<button id=confirm style="top:460px" onclick="S.confirm = String(confirm('native-ui confirm'))">confirm</button>
<button id=prompt style="top:520px" onclick="S.prompt = String(prompt('native-ui prompt', 'default'))">prompt</button>
<script>window.S = {}</script>
"""

FEATURE = "chromiumPageDialogs"
# The rows on the probe page, then http_auth, which navigates the tab away and so runs last.
PAGE_ROWS = ("alert", "confirm", "prompt")
ROWS = (*PAGE_ROWS, "http_auth")
JAVASCRIPT_DIALOG = "browser.dialog.javascript"
AUTH_DIALOG = "browser.dialog.httpAuth"
AUTH_USER, AUTH_PASSWORD, AUTH_REALM = "native-ui", "s3cret", "native-ui"
SIGNED_IN_TITLE = "native-ui signed in"
# How long a dialog may take to show after the input that opens it, and the page to see its answer.
DEADLINE_S = 10.0


class _AuthHandler(http.server.BaseHTTPRequestHandler):
    """HTTP Basic authentication for AUTH_USER and AUTH_PASSWORD; anything else is a 401 with a challenge."""

    def do_GET(self):
        expected = "Basic " + base64.b64encode(f"{AUTH_USER}:{AUTH_PASSWORD}".encode()).decode()
        if self.headers.get("Authorization") == expected:
            status, body = 200, f"<!doctype html><title>{SIGNED_IN_TITLE}</title>ok".encode()
        else:
            status, body = 401, b"<!doctype html><title>native-ui 401</title>refused"
        self.send_response(status)
        if status == 401:
            self.send_header("WWW-Authenticate", f'Basic realm="{AUTH_REALM}"')
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def open_dialog(rpc, identifier):
    """The newest visible cmux dialog with `identifier` (`debug.dialog`), or None."""
    dialogs = (rpc("debug.dialog") or {}).get("dialogs") or []
    return next((d for d in reversed(dialogs) if d.get("identifier") == identifier and d.get("visible")), None)


def answered(rpc, wait, page_eval, opens, identifier, answer, script, expected):
    """Opens a dialog with `opens`, answers it with `answer(id)`, and waits for `script` to read `expected`."""
    started = time.time()
    opens()
    dialog = wait(lambda: open_dialog(rpc, identifier), DEADLINE_S)
    if dialog is None:
        return {"ok": False, "error": f"no {identifier} dialog showed", "dialogs": (rpc("debug.dialog") or {}).get("dialogs")}
    show_ms = round((time.time() - started) * 1000, 1)
    answer(dialog["id"])
    seen = wait(lambda: (lambda value: value if value == expected else None)(page_eval(script)), DEADLINE_S)
    return {"ok": seen == expected, "show_ms": show_ms, "page": seen if seen is not None else page_eval(script),
            "dialog": {key: dialog.get(key) for key in ("title", "lines", "origin", "buttons")}}


def rows(rpc, wait, page_eval, click, names=ROWS):
    """alert, confirm and prompt of `names` on the probe page (PAGE is part of it); http_auth is auth_row."""
    press = lambda button: (lambda dialog: rpc("debug.dialog", {"id": dialog, "press": button}))

    def typed(dialog):
        rpc("debug.dialog", {"id": dialog, "set": {"text": "typed"}})
        rpc("debug.dialog", {"id": dialog, "press": "ok"})

    runs = {
        "alert": lambda: answered(rpc, wait, page_eval, lambda: click("alert"), JAVASCRIPT_DIALOG, press("ok"), "S.alert", "closed"),
        "confirm": lambda: answered(rpc, wait, page_eval, lambda: click("confirm"), JAVASCRIPT_DIALOG, press("ok"), "S.confirm", "true"),
        "prompt": lambda: answered(rpc, wait, page_eval, lambda: click("prompt"), JAVASCRIPT_DIALOG, typed, "S.prompt", "typed"),
    }
    return {name: run() for name, run in runs.items() if name in names}


def auth_row(rpc, wait, page_eval):
    """The tab loads a page behind HTTP Basic authentication from a server of this run and signs in."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _AuthHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/auth"

    def sign_in(dialog):
        rpc("debug.dialog", {"id": dialog, "set": {"user": AUTH_USER, "password": AUTH_PASSWORD}})
        rpc("debug.dialog", {"id": dialog, "press": "sign-in"})

    try:
        return answered(rpc, wait, page_eval, lambda: page_eval(f"location.href = {url!r}"), AUTH_DIALOG, sign_in,
                        "document.title", SIGNED_IN_TITLE)
    finally:
        server.shutdown()
        server.server_close()
