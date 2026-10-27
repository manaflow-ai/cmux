"""The `--native-ui` suggestion rows of chromium-host-bench.py (p01-process-061): a page's autofill, password and
<datalist> suggestions, which the Chromium host sends as data (fork API 31's suggestion handler, p01-process-172) and
cmux draws in its own list under the field (ChromiumHostSuggestionList, feature `chromiumHostSuggestions`):

  autofill   a submitted form saves an autocomplete entry; typing its first letter in the field shows it in cmux's
             list beside the field, Down selects it there (Chromium's keys move cmux's highlight) and Return fills
             the field with it, after which the list is gone
  password   a sign-in typed and submitted on a local http login page is saved from cmux's save prompt; in a new tab
             of that page a click in the username field shows the saved sign-in (a password entry) and the
             "Manage passwords" footer in cmux's list beside the field; Escape closes it. Chrome's strong password
             offer is not checked: its own popup (PasswordGenerationPopupViewViews) is not the autofill view the
             fork's suggestion handler replaces
  datalist   (the native_ui row, with the feature on) the <input list> options come as cmux's list, not a page popup

Each reads `debug.cef` `host_suggestions` (null unless the host draws suggestions in cmux): the shown lists, each
with its row kinds and Chromium SuggestionTypes, its highlight, its screen frame and the field's.

The password row's tabs are opened as a person opens them (`debug.toast` perform) and never read through the socket:
a socket read marks a tab agent-driven, and Chromium then neither fills nor offers to save sign-ins there
(CEFPasswordPrompts). Its login page tells the row's local server when it loaded.
"""
import http.server
import os
import threading
import time

# The probe's field (chromium_host_native_ui.PAGE): a form whose submission saves an autocomplete entry.
FIELDS = """<form id=af method=get style="position:fixed;top:280px;left:40px;margin:0">
<input id=name name=cmux_native_ui_name autocomplete=on style="position:static"></form>
"""

# The password row's login page, served over http (Chromium saves no sign-in of a file:// page). Its fields sit at
# fixed CSS points, so the row clicks them without reading the page; it reports each load to the server.
LOGIN_PAGE = """<!doctype html><meta charset=utf-8><title>Sign in</title>
<style>body{margin:0;font:16px system-ui} input{position:fixed;left:40px;width:240px;height:32px;font-size:16px}</style>
<form method=post action=/done><input id=u name=username autocomplete=username style="top:40px">
<input id=p name=password type=password autocomplete=current-password style="top:100px"></form>
<script>addEventListener('load', () => fetch('/loaded' + location.search))</script>
"""
DONE_PAGE = "<!doctype html><title>Signed in</title><p>signed in"
# The fields' centers in page CSS points (debug.mouse `target: page`).
USERNAME_AT = {"x": 160, "y": 56}
PASSWORD_AT = {"x": 160, "y": 116}

ENTRY = "alpha"
# autofill::SuggestionType::kDatalistEntry (components/autofill/core/browser/suggestions/suggestion_type.h).
DATALIST_ENTRY = 20
# autofill::SuggestionType::kPasswordEntry: a saved sign-in's row.
PASSWORD_ENTRY = 21
SHOW_DEADLINE_S = 10.0
ROWS = ("autofill", "password")


def host_suggestions(rpc):
    """`debug.cef` `host_suggestions`: None unless the host draws suggestions in cmux, else the lists shown now."""
    return (rpc("debug.cef") or {}).get("host_suggestions")


def drawn(rpc):
    return host_suggestions(rpc) is not None


def shown(rpc, types=None):
    """The first list on screen with an entry row (of one of `types` when given), or None."""
    for listed in host_suggestions(rpc) or []:
        entries = [t for kind, t in zip(listed.get("kinds") or [], listed.get("types") or []) if kind == "entry"]
        if listed.get("frame") and entries and (types is None or any(t in types for t in entries)):
            return listed
    return None


def beside_field(listed):
    """The list sits under its field or over it (AppKit screen points, y up), never across it."""
    frame, field = listed.get("frame"), listed.get("field")
    if not frame or not field:
        return False
    below = frame[1] + frame[3] <= field[1] + 0.5
    above = frame[1] >= field[1] + field[3] - 0.5
    return below or above


def wait_list(rpc, wait, types=None):
    started = time.time()
    listed = wait(lambda: shown(rpc, types), SHOW_DEADLINE_S)
    return listed, (round((time.time() - started) * 1000, 1) if listed else None)


def key(rpc, name):
    rpc("debug.key", {"target": "page", "key": name})


def datalist(rpc, wait):
    """The datalist row with the feature on: its options in cmux's list."""
    listed, show_ms = wait_list(rpc, wait, (DATALIST_ENTRY,))
    return {"ok": bool(listed and beside_field(listed)), "list": listed, "show_ms": show_ms,
            "host_suggestions": None if listed else host_suggestions(rpc)}


def autofill(rpc, wait, page_eval, click):
    page_eval(f"(() => {{ document.getElementById('name').value = '{ENTRY}'; "
              "document.getElementById('af').requestSubmit(); return true; })()")
    if not wait(lambda: page_eval("location.search.includes('cmux_native_ui_name') && document.readyState === 'complete' "
                                  "&& !!document.getElementById('name')"), 30, 0.5):
        return {"ok": False, "error": "the form's submission never loaded"}
    click("name")
    key(rpc, ENTRY[0])
    listed, show_ms = wait_list(rpc, wait)
    if not listed:
        return {"ok": False, "error": "no suggestion list for the saved entry", "host_suggestions": host_suggestions(rpc)}
    placed = beside_field(listed)
    key(rpc, "down")
    selected = wait(lambda: (shown(rpc) or {}).get("highlighted") == 0, 5)
    key(rpc, "return")
    filled = wait(lambda: page_eval("document.getElementById('name').value") == ENTRY and shown(rpc) is None, 5)
    return {"ok": bool(placed and selected and filled), "list": listed, "show_ms": show_ms, "beside_field": placed,
            "key_selected": bool(selected), "accepted": bool(filled)}


class LoginServer:
    """The login page on 127.0.0.1 and the loads it reports (`/loaded?step=...`)."""

    def __init__(self):
        self.loaded = set()
        server = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.startswith("/loaded"):
                    server.loaded.add(self.path.partition("step=")[2])
                    return self.reply("")
                self.reply(LOGIN_PAGE)

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                self.reply(DONE_PAGE)

            def reply(self, body):
                data = body.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.http = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.origin = f"http://127.0.0.1:{self.http.server_address[1]}"
        threading.Thread(target=self.http.serve_forever, daemon=True).start()

    def close(self):
        self.http.shutdown()
        self.http.server_close()


def open_as_person(rpc, wait, server, step):
    """A new tab of the login page, opened as a person opens one; True once the page reported its load."""
    reply = rpc("debug.toast", {"perform": "openBrowser.chromium", "arguments": {"url": f"{server.origin}/login?step={step}"}})
    return bool((reply or {}).get("performed")) and bool(wait(lambda: step in server.loaded, 30, 0.2))


def type_text(rpc, text):
    for char in text:
        key(rpc, char)


def save_prompt(rpc):
    prompts = (rpc("debug.browser.prompts") or {}).get("prompts") or []
    return next((p for p in prompts if "savePassword" in p.get("kind", "")), None)


def password_rows(rpc):
    """The shown list with a saved sign-in's row and the footer, or None."""
    listed = shown(rpc, (PASSWORD_ENTRY,))
    return listed if listed and "footer" in (listed.get("kinds") or []) else None


def password(rpc, wait):
    server = LoginServer()
    try:
        return saved_sign_in_rows(rpc, wait, server)
    finally:
        server.close()


def saved_sign_in_rows(rpc, wait, server):
    run = os.urandom(4).hex()
    if not open_as_person(rpc, wait, server, f"save-{run}"):
        return {"ok": False, "error": "the login page never loaded in a person's tab"}
    rpc("debug.mouse", {"target": "page", **USERNAME_AT})
    type_text(rpc, f"cmux-{run}")
    rpc("debug.mouse", {"target": "page", **PASSWORD_AT})
    type_text(rpc, f"throwaway-{run}")
    key(rpc, "return")
    prompt = wait(lambda: save_prompt(rpc), 30, 0.2)
    if not prompt:
        return {"ok": False, "error": "no save prompt for the submitted sign-in", "prompts": rpc("debug.browser.prompts")}
    answered = rpc("debug.browser.prompts", {"respond": "accept"}) or {}
    if answered.get("responded") is not True:
        return {"ok": False, "error": "the save prompt took no answer", "reply": answered}

    if not open_as_person(rpc, wait, server, f"fill-{run}"):
        return {"ok": False, "error": "the login page never loaded again after the save"}
    started = time.time()
    rpc("debug.mouse", {"target": "page", **USERNAME_AT})
    listed = wait(lambda: password_rows(rpc), SHOW_DEADLINE_S)
    if not listed:
        return {"ok": False, "error": "no saved sign-in and footer in cmux's list", "host_suggestions": host_suggestions(rpc)}
    show_ms = round((time.time() - started) * 1000, 1)
    placed = beside_field(listed)
    key(rpc, "escape")
    closed = wait(lambda: shown(rpc) is None, 5)
    return {"ok": bool(placed and closed), "list": listed, "show_ms": show_ms, "beside_field": placed, "closed": bool(closed)}


def run(rpc, wait, page_eval, click, names=ROWS):
    """The rows of `names` (ROWS); the form's submission reloads the probe, so they run last."""
    if not drawn(rpc):
        reason = "no host suggestions: host mode is not live in this build or chromiumHostSuggestions is off"
        return {name: {"ok": False, "not_run": reason} for name in names}
    rows = {}
    if "autofill" in names:
        rows["autofill"] = autofill(rpc, wait, page_eval, click)
    if "password" in names:
        rows["password"] = password(rpc, wait)
    return rows
