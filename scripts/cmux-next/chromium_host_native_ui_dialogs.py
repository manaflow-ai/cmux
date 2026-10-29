"""The page dialog rows of chromium-host-bench.py `--native-ui` (p01-process-064): Chromium's file picker, certificate
error, beforeunload question and renderer hang, each answered by cmux while the Chromium host is never the frontmost
app and owns no visible window (CGWindowList: a window of the host's pid with alpha > 0).

  file_picker        <input type=file>: a click opens cmux's picker (FILE_DIALOG, ChromiumHostFiles, feature
                     `chromiumHostFileDialogs`; `debug.cef` `host_file_dialogs`). A choice through it
                     (`debug.cef` `file_dialog_choose`) gives the page that file by its path; a cancel
                     (`file_dialog_cancel`) gives the page its `cancel` event and no file. Without cmux's picker
                     (`host_file_dialogs` null: host mode not live, or the feature off) the row says so and fails.
  certificate_error  a page on a self-signed https server: Chromium's interstitial (or cmux's warning in an
                     agent-driven tab) shows in the pane; its Proceed loads the page.
  beforeunload       a person's Cmd-W of a page with a beforeunload handler: cmux's question
                     (`browser.dialog.beforeunload`) asks in the tab, which stays; Cancel keeps it; Leave closes it.
  unresponsive       a page whose click never returns: the pane shows "Page unresponsive" within Chromium's hang
                     delay; Wait hides it; Exit page ends the renderer and the sad tab shows.
"""
import http.server
import json
import os
import shutil
import ssl
import subprocess
import threading
import time

ROWS = ("file_picker", "certificate_error", "beforeunload", "unresponsive")
# What the app needs for these rows.
FEATURES = "chromiumHostFileDialogs"
# How long a picker, warning or question may take to show after the input that opens it.
SHOW_DEADLINE_S = 10.0
# Chromium's hang delay is 15 s; its ping adds a few more (page-hang-live.py).
HANG_DEADLINE_S = 45.0
QUESTION = "browser.dialog.beforeunload"

FILE_PAGE = """<!doctype html><meta charset=utf-8><title>file probe</title>
<input id=file type=file style="position:fixed;left:40px;top:40px;width:240px;height:32px">
<script>
window.chosen = []; window.cancels = 0;
const input = document.getElementById('file');
input.addEventListener('change', () => { window.chosen = [...input.files].map(f => f.name); });
input.addEventListener('cancel', () => { window.cancels += 1; });
</script>
"""

UNLOAD_PAGE = """<!doctype html><meta charset=utf-8><title>unload probe</title>
<body style="margin:0;height:100vh">
<script>
addEventListener('beforeunload', e => { e.preventDefault(); e.returnValue = ''; });
document.addEventListener('mousedown', () => { document.title = 'unload armed'; });
</script>
"""

HANG_PAGE = """<!doctype html><meta charset=utf-8><title>hang probe</title>
<body style="margin:0;height:100vh">A click here never returns.
<script>addEventListener('mousedown', () => { for (;;) {} })</script>
"""

CERT_PAGE = b"<!doctype html><title>certificate probe proceeded</title><p>past the warning"


def host_ui_clear(host_pid, front, windows):
    """While a page's dialog shows: the host's pid, the frontmost pid, the host's visible windows, and `clear` when
    the host is not frontmost and owns no visible window (an unreadable window list is not clear)."""
    pid = host_pid()
    listed = windows(pid) if pid else None
    visible = [w for w in listed or [] if (w.get("alpha") or 0) > 0]
    front_pid = front()
    return {"host_pid": pid, "front_pid": front_pid, "host_windows": visible,
            "clear": pid is not None and listed is not None and front_pid != pid and not visible}


def file_dialogs(rpc, **params):
    """`debug.cef` `host_file_dialogs` (after the params' answer, if any): None without cmux's picker."""
    return (rpc("debug.cef", params) or {}).get("host_file_dialogs")


def open_page(rpc, wait, page_eval, url, title):
    """A new focused Chromium tab on `url`, once its title is `title`; False when it never loads."""
    rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
    return bool(wait(lambda: page_eval("document.title") == title, 60))


def focused_tab(rpc):
    """The first window's focused tab and every tab id it holds (`debug.focus`)."""
    windows = (rpc("debug.focus") or {}).get("windows") or []
    if not windows:
        return None, set()
    tabs = {t.rsplit(":", 1)[0] for p in windows[0].get("topology") or [] for t in p.get("tabs") or []}
    return (windows[0].get("model") or {}).get("resolved_tab"), tabs


def page_status(rpc, **params):
    """What the focused pane shows over its page (`debug.browser.page_status`); {} until it answers."""
    reply = rpc("debug.browser.page_status", params) or {}
    return reply if "gone" in reply else {}


def write_page(out, name, html):
    path = os.path.join(out, name)
    with open(path, "w") as f:
        f.write(html)
    return "file://" + path


def file_picker_row(rpc, wait, page_eval, out, clear):
    if file_dialogs(rpc) is None:
        return {"ok": False, "not_run": "no cmux file picker: host mode is not live in this build or "
                                        "chromiumHostFileDialogs is off"}
    chosen = os.path.join(out, "native-ui-chosen.txt")
    with open(chosen, "w") as f:
        f.write("chosen by the file_picker row\n")
    if not open_page(rpc, wait, page_eval, write_page(out, "native-ui-file.html", FILE_PAGE), "file probe"):
        return {"ok": False, "error": "the file probe never loaded"}
    rect = page_eval("(() => { const r = document.getElementById('file').getBoundingClientRect(); "
                     "return [r.x + r.width / 2, r.y + r.height / 2]; })()") or [0, 0]

    def ask():
        before = (file_dialogs(rpc) or {}).get("asked") or 0
        started = time.time()
        rpc("debug.mouse", {"target": "page", "x": rect[0], "y": rect[1]})
        shown = wait(lambda: (lambda d: d if d and d.get("waiting") and (d.get("asked") or 0) > before else None)(file_dialogs(rpc)),
                     SHOW_DEADLINE_S)
        return shown, round((time.time() - started) * 1000, 1) if shown else None

    row = {}
    shown, row["show_ms"] = ask()
    row["host"] = clear()
    rpc("debug.cef", {"file_dialog_choose": [chosen]})
    name = os.path.basename(chosen)
    row["chose"] = bool(shown) and bool(wait(lambda: page_eval("window.chosen.join('|')") == name, 5))
    shown_again, _ = ask()
    rpc("debug.cef", {"file_dialog_cancel": True})
    row["cancelled"] = bool(shown_again) and bool(wait(lambda: page_eval("window.cancels") == 1, 5)) and \
        page_eval("window.chosen.join('|')") == name
    row["dialogs"] = file_dialogs(rpc)
    row["ok"] = bool(shown) and row["host"]["clear"] and row["chose"] and row["cancelled"]
    return row


def self_signed(out):
    """(cert, key) of a fresh self-signed certificate for 127.0.0.1, or None without openssl."""
    openssl = shutil.which("openssl") or "/usr/bin/openssl"
    cert, key = os.path.join(out, "native-ui-cert.pem"), os.path.join(out, "native-ui-key.pem")
    try:
        subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
                        "-keyout", key, "-out", cert], capture_output=True, timeout=60, check=True)
    except (OSError, subprocess.SubprocessError):
        return None
    return cert, key


def serve_https(cert, key):
    """An https server on 127.0.0.1 with `cert` that serves CERT_PAGE; (server, url)."""
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(CERT_PAGE)))
            self.end_headers()
            self.wfile.write(CERT_PAGE)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"https://127.0.0.1:{server.server_address[1]}/"


def certificate_row(rpc, wait, page_eval, out, clear):
    pair = self_signed(out)
    if not pair:
        return {"ok": False, "not_run": "no openssl to make the self-signed certificate"}
    server, url = serve_https(*pair)
    try:
        rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True, "origin": "script"}, timeout=120)
        started = time.time()
        warning = wait(lambda: (lambda s: s if s.get("enginePage") == "1" or s.get("certificate") == "1" else None)(page_status(rpc)),
                       SHOW_DEADLINE_S * 3)
        row = {"warning": warning and {k: warning.get(k) for k in ("enginePage", "certificate", "title")},
               "show_ms": round((time.time() - started) * 1000, 1) if warning else None, "host": clear()}
        if warning and warning.get("certificate") == "1":
            row["proceed"] = "cmux warning"
            page_status(rpc, press="proceed")
        elif warning:
            # Chromium's interstitial: its Proceed link, as a person's click on it.
            row["proceed"] = "interstitial"
            page_eval("(() => { const link = document.getElementById('proceed-link'); if (!link) return false; "
                      "link.click(); return true; })()")
        title = "certificate probe proceeded"
        row["proceeded"] = bool(warning) and bool(wait(lambda: page_eval("document.title") == title, 20))
        row["ok"] = bool(warning) and row["host"]["clear"] and row["proceeded"]
        return row
    finally:
        server.shutdown()


def questions(rpc):
    return [d for d in (rpc("debug.dialog") or {}).get("dialogs") or [] if d.get("identifier") == QUESTION and d.get("visible")]


def beforeunload_row(rpc, wait, page_eval, out, clear):
    if not open_page(rpc, wait, page_eval, write_page(out, "native-ui-unload.html", UNLOAD_PAGE), "unload probe"):
        return {"ok": False, "error": "the unload probe never loaded"}
    tab = wait(lambda: focused_tab(rpc)[0], 10)
    # Chromium asks only a page the person used: a click gives it the user activation.
    rpc("debug.mouse", {"target": "page"})
    row = {"armed": bool(wait(lambda: page_eval("document.title") == "unload armed", 10))}
    has_tab = lambda: tab in focused_tab(rpc)[1]  # noqa: E731
    rpc("debug.key", {"key": "w", "modifiers": ["cmd"]})
    row["asked"] = bool(wait(lambda: questions(rpc), SHOW_DEADLINE_S))
    row["host"] = clear()
    row["kept_while_asking"] = has_tab()
    rpc("debug.dialog", {"press": "cancel"})
    time.sleep(1.0)  # test harness: a close that ignored Cancel would land within this
    row["stayed"] = bool(wait(lambda: not questions(rpc), 5)) and has_tab()
    rpc("debug.key", {"key": "w", "modifiers": ["cmd"]})
    asked_again = wait(lambda: questions(rpc), SHOW_DEADLINE_S)
    rpc("debug.dialog", {"press": "ok"})
    row["left"] = bool(asked_again) and bool(wait(lambda: not has_tab(), 10)) and not questions(rpc)
    row["ok"] = bool(tab) and row["armed"] and row["asked"] and row["host"]["clear"] and row["kept_while_asking"] and \
        row["stayed"] and row["left"]
    return row


def unresponsive_row(rpc, wait, page_eval, out, clear):
    if not open_page(rpc, wait, page_eval, write_page(out, "native-ui-hang.html", HANG_PAGE), "hang probe"):
        return {"ok": False, "error": "the hang probe never loaded"}
    rpc("debug.mouse", {"target": "page"})
    started = time.time()
    shown = wait(lambda: page_status(rpc).get("unresponsive") == "1", HANG_DEADLINE_S)
    row = {"shown": bool(shown), "show_ms": round((time.time() - started) * 1000, 1) if shown else None, "host": clear()}
    row["waited"] = bool(shown) and page_status(rpc, press="wait").get("pressed") == "1" and \
        bool(wait(lambda: page_status(rpc).get("unresponsive") == "0", 5))
    # The page still hangs: the card comes back, and Exit page ends its renderer.
    back = bool(shown) and bool(wait(lambda: page_status(rpc).get("unresponsive") == "1", HANG_DEADLINE_S))
    row["exited"] = back and page_status(rpc, press="exit").get("pressed") == "1" and \
        bool(wait(lambda: page_status(rpc).get("gone") == "1", 10))
    row["ok"] = row["shown"] and row["host"]["clear"] and row["waited"] and row["exited"]
    return row


RUNNERS = {"file_picker": file_picker_row, "certificate_error": certificate_row, "beforeunload": beforeunload_row,
           "unresponsive": unresponsive_row}


def run(rpc, wait, page_eval, out, host_pid, front, windows, rows_to_run=ROWS, on_row=lambda name, row: row):
    """The rows of `rows_to_run`, in ROWS order. `host_pid` gives the running host's pid, `front` the frontmost app's,
    `windows(pid)` that pid's on-screen windows (chromium-host-bench.py's on_screen_windows). `on_row(name, row)` runs
    right after each row and returns the row to keep. Returns (rows, ok)."""
    rows = {}
    clear = lambda: host_ui_clear(host_pid, front, windows)  # noqa: E731
    for name in ROWS:
        if name not in rows_to_run:
            continue
        try:
            rows[name] = RUNNERS[name](rpc, wait, page_eval, out, clear)
        except Exception as error:  # noqa: BLE001 - a row's failure is that row's result
            rows[name] = {"ok": False, "error": f"{type(error).__name__}: {error}"[:300]}
        rows[name] = on_row(name, rows[name])
    return rows, bool(rows) and all(row.get("ok") for row in rows.values())


if __name__ == "__main__":
    print(json.dumps({"rows": ROWS, "features": FEATURES}))
