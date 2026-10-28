#!/usr/bin/env python3
"""Live check: a hung Chromium page shows cmux's inline "Page unresponsive" card (cx-d0d.36).

  scripts/cmux-next/page-hang-live.py --socket /tmp/cmux-debug-<tag>.sock [--out DIR] [--page]

Drives a running tagged build (a capture slot's, or one launched with CMUX_NEXT_NO_ACTIVATE=1
and CMUX_NEXT_SOCKET_MODE=automation). For each page, a click reaches Chromium's page view
through `debug.mouse {"target": "page"}` (an in-app event, no system event), and then:

  1. `chrome://hang` (typed into the omnibar, as a person opens it), then a page whose click handler never
     returns: the pane shows the "Page unresponsive" card within Chromium's hang delay;
  2. the card is in the pane: no window, sheet or Chromium dialog opens with it;
  3. Wait hides it and restarts Chromium's timer, so the card comes back while the page
     still hangs; Exit page ends the renderer and the pane shows the page-gone view.

With --page, a cmux page tab in Chromium instead (p13-webui-057; launch with
CMUX_ENABLE_FEATURES=pageHangNotice and browser.defaultEngine chromium): `debug.page hangOnClick`
makes the page's next mousedown loop, a click hangs it, and the tab shows the "Page unresponsive"
cmux dialog (`debug.dialog`, identifier page.unresponsive) scoped to the tab; Wait takes it down and
it comes back while the page hangs; Exit page ends the renderer and the shown page reloads.

Until the CEF fork stops counting its own DevTools controller as a debugger, Chromium drops
every hang in a cmux tab and the card checks fail (plans/cmux-next/browser-isolation.md,
Verification). GUI host only. Leaves the app running. Exits 1 when a check fails.
"""
import argparse, json, os, socket, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="page-hang-"))
parser.add_argument("--page", action="store_true", help="hang a cmux page tab instead of browser tabs")
parser.add_argument("--page-id", default="cmux.apps")
parser.add_argument("--page-action", default="appStore.show")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
# Chromium's hang delay is 15 s; its ping adds a few more.
HANG_SECONDS = 45
LOOP_PAGE = """<!doctype html><title>hang test</title>
<body style="font:32px sans-serif">A click here never returns.
<script>addEventListener("mousedown", () => { for (;;) {} })</script>
"""
failures = []
TAB = None


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    result = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    return result if isinstance(result, dict) else {"value": result}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    return None


def page_status(**params):
    """What the pane shows over the page; {} until the tab answers."""
    reply = rpc("debug.browser.page_status", {**({"tab": TAB} if TAB else {}), **params})
    return reply if "gone" in reply else {}


def card_shown():
    return page_status().get("unresponsive") == "1"


def app_windows():
    return {w.get("id"): w for w in rpc("debug.window_list").get("windows") or [] if w.get("visible")}


def open_tab(url):
    global TAB
    TAB = (rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True}, timeout=60)
           .get("created") or [None])[0]
    quiet_wait(lambda: page_status(), 20)


def click_page():
    reply = rpc("debug.mouse", {"target": "page"})
    check(reply.get("delivered") == 2, f"a click reaches the page view ({reply})")


def run_page(name, url, hangs_on_click, typed=None):
    print(f"== {name}", flush=True)
    open_tab(url)
    check(bool(TAB), f"{name}: a Chromium tab opens")
    if typed:
        # Agents cannot open Chromium's own pages; a person types them into the omnibar.
        reply = rpc("debug.omnibar_type", {"text": typed})
        check(reply.get("typed") is True, f"{name}: typed into the omnibar ({reply})")
        # A debug URL commits nothing; the page still answers until the renderer takes it.
        hung = quiet_wait(lambda: "timed out" in str(rpc("browser.page.eval", {"script": "1", "tab": TAB}, timeout=3).get("error")), 15)
        check(bool(hung), f"{name}: the page stops answering")
    time.sleep(3)
    before = set(app_windows())
    click_page()
    if not hangs_on_click:
        # chrome://hang already hangs; one more click is the input Chromium waits on.
        time.sleep(1)
        click_page()
    shown = quiet_wait(card_shown, HANG_SECONDS)
    check(bool(shown), f"{name}: the pane shows Page unresponsive ({page_status()})")
    if not shown:
        rpc("action.run", {"action": "closeTab", "origin": "script"})
        time.sleep(1)
        return
    opened = {id: w for id, w in app_windows().items() if id not in before}
    check(not opened, f"{name}: the card is inline, no window or dialog opened ({opened})")
    reply = page_status(press="wait")
    hidden = quiet_wait(lambda: not card_shown(), 5)
    check(reply.get("pressed") == "1" and bool(hidden), f"{name}: Wait hides the card ({reply})")
    click_page()
    check(bool(quiet_wait(card_shown, HANG_SECONDS)), f"{name}: the card comes back while the page still hangs")
    reply = page_status(press="exit")
    check(reply.get("pressed") == "1", f"{name}: Exit page runs ({reply})")
    gone = quiet_wait(lambda: page_status().get("gone") == "1" and not card_shown(), 20)
    check(bool(gone), f"{name}: Exit page ends the renderer and shows the page-gone view ({page_status()})")
    rpc("action.run", {"action": "closeTab", "origin": "script"})
    time.sleep(1)


def hang_card():
    """The page tab's "Page unresponsive" dialog, visible; None while there is none."""
    dialogs = rpc("debug.dialog").get("dialogs") or []
    return next((d for d in dialogs if d.get("identifier") == "page.unresponsive" and d.get("visible")), None)


def page_state():
    return rpc("debug.page", {"page": opts.page_id}, timeout=10)


def run_cmux_page():
    name = opts.page_id
    print(f"== {name} (cmux page tab)", flush=True)
    rpc("action.run", {"action": opts.page_action, "focus": True}, timeout=60)
    painted = quiet_wait(lambda: page_state().get("painted") is True, 30)
    check(bool(painted), f"{name}: the page tab paints ({page_state()})")
    armed = rpc("debug.page", {"page": name, "action": "hangOnClick"}, timeout=10)
    check(armed.get("armed") is True, f"{name}: the page loops on its next mousedown ({armed})")
    before = set(app_windows())
    click_page()
    time.sleep(1)
    click_page()
    card = quiet_wait(hang_card, HANG_SECONDS)
    check(bool(card), f"{name}: the tab shows the Page unresponsive card")
    if not card:
        return
    check(card.get("scope") == "tab", f"{name}: the card blocks only its tab ({card.get('scope')})")
    opened = {id: w for id, w in app_windows().items() if id not in before}
    check(not opened, f"{name}: the card is a cmux dialog, no window or alert opened ({opened})")
    reply = rpc("debug.dialog", {"id": card["id"], "press": "wait"})
    hidden = quiet_wait(lambda: not hang_card(), 5)
    check(reply.get("pressed") is True and bool(hidden), f"{name}: Wait takes the card down ({reply})")
    click_page()
    card = quiet_wait(hang_card, HANG_SECONDS)
    check(bool(card), f"{name}: the card comes back while the page still hangs")
    if not card:
        return
    reply = rpc("debug.dialog", {"id": card["id"], "press": "exit"})
    check(reply.get("pressed") is True, f"{name}: Exit page runs ({reply})")
    # The renderer ends; the shown page's crash recovery reloads it at once.
    back = quiet_wait(lambda: not hang_card() and page_state().get("painted") is True, 30)
    check(bool(back), f"{name}: Exit page ends the renderer and the page reloads ({page_state()})")


check("error" not in rpc("debug.cef"), "app socket answers")
if opts.page:
    run_cmux_page()
else:
    scratch = tempfile.mkdtemp(prefix="page-hang-page-")
    loop = os.path.join(scratch, "loop.html")
    with open(loop, "w") as f:
        f.write(LOOP_PAGE)
    run_page("chrome://hang", "file://" + loop, hangs_on_click=False, typed="chrome://hang")
    run_page("a page that loops on click", "file://" + loop, hangs_on_click=True)
print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
