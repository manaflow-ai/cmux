#!/usr/bin/env python3
"""Live check: Import from Another Browser… on a tagged build (cx-d0d.65).

  scripts/cmux-next/import-files-live.py --tag <tag> [--out DIR] [--app PATH]

The person path, through the socket only: `debug.toast {perform}` runs the
person-only action as a palette run; `debug.dialog` picks the browser and
presses Choose Files…; `debug.key` types into the cmux picker. Files are
synthetic exports in a scratch folder (no real passwords):

  1. picking Microsoft Edge shows its steps, naming its export pages
     (edge://settings/passwords, edge://favorites);
  2. picking Safari shows Safari's steps;
  3. a bookmarks HTML file picked there lands in the bookmark bar's Imported folder;
  4. a passwords CSV picked through Safari's steps is imported (the counts toast);
  5. Safari's Export Browsing Data zip (bookmarks, history, one password and a
     credit card file cmux must not import): the bookmark lands, the password is
     imported, the zip goes to the Trash, and its history shows in the omnibar;
  6. Chrome's Google Takeout history JSON (one row per visit; two pages) shows in the omnibar,
     and Chrome's steps name takeout.google.com;
  7. a CSV whose header names no known column (Site, Login, Secret) opens the column sheet,
     which shows the column names and the row count and no value; Import brings both rows in;
     a CSV with no header row (its first row is a sign-in) opens no sheet and fails, naming no value;
  0. first, in light and dark (window snapshots in --out): the browser sheet; 1Password's and
     Bitwarden's steps (passwords only); Arc's steps (its password page, no bookmarks step); the
     Import step of the onboarding window opens the same browser sheet from its button; the
     Passwords page shows Import from Another Browser…, and a page-script click on it opens
     nothing (person-only; a real click needs the input lane).

Quits the app by PID and stops the tag's daemons at the end.
"""
import argparse, glob, json, os, plistlib, subprocess, sys, tempfile, time, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="import-files-live-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"import-files-{opts.tag}-")
EXPORTS = os.path.join(SCRATCH, "exports")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []

BOOKMARKS_HTML = """<!DOCTYPE NETSCAPE-Bookmark-file-1>
<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
<TITLE>Bookmarks</TITLE>
<H1>Bookmarks</H1>
<DL><p>
    <DT><H3>Favorites bar</H3>
    <DL><p>
        <DT><A HREF="https://edge-export.example.com/">Edge export</A>
    </DL><p>
</DL><p>
"""
# Synthetic sign-ins on example.test, new each run (a profile kept from an earlier run would
# count them as already saved); never a real password.
RUN = os.urandom(4).hex()
PASSWORDS_CSV = "Title,URL,Username,Password,Notes,OTPAuth\n" \
                f"one.example.test,https://one-{RUN}.example.test/,cmux-one-{RUN},not-a-real-password-1,,\n" \
                f"two.example.test,https://two-{RUN}.example.test/,cmux-two-{RUN},not-a-real-password-2,,\n"

# A header cmux does not know: the column sheet matches it. A file with no header row: no sheet.
COLUMNS_CSV = "Site,Login,Secret\n" \
              f"https://cols-one-{RUN}.example.test/,cmux-cols-{RUN},not-a-real-password-4\n" \
              f"https://cols-two-{RUN}.example.test/,cmux-cols-{RUN},not-a-real-password-5\n"
HEADERLESS_CSV = f"https://nohead-{RUN}.example.test/,cmux-nohead-{RUN},not-a-real-password-6\n"


def safari_zip(path):
    """Safari's File > Export Browsing Data to File… layout, with a macOS resource fork entry."""
    history = {"metadata": {"browser_name": "Safari", "data_type": "history", "schema_version": 1},
               "history": [{"url": f"https://safari-hist-{RUN}.example.com/", "title": f"Safari history {RUN}",
                            "time_usec": int(time.time() * 1e6), "visit_count": 3}]}
    bookmarks = BOOKMARKS_HTML.replace("https://edge-export.example.com/", f"https://safari-zip-{RUN}.example.com/")
    passwords = "Title,URL,Username,Password,Notes,OTPAuth\n" \
                f"zip.example.test,https://zip-{RUN}.example.test/,cmux-zip-{RUN},not-a-real-password-3,,\n"
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("Safari Export/Bookmarks.html", bookmarks)
        z.writestr("Safari Export/History.json", json.dumps(history))
        z.writestr("Safari Export/Passwords.csv", passwords)
        z.writestr("Safari Export/CreditCards.csv", "Card Number,Card Name\n0000000000000000,not a real card\n")
        z.writestr("__MACOSX/Safari Export/._Bookmarks.html", "resource fork")


def takeout_history(path):
    now = int(time.time() * 1e6)
    rows = [{"url": f"https://takeout-{RUN}.example.com/", "title": f"Takeout history {RUN}", "time_usec": now - i * 1_000_000,
             "page_transition": "LINK"} for i in range(3)]
    rows.append({"url": f"https://takeout-other-{RUN}.example.com/", "title": "Other", "time_usec": now, "page_transition": "TYPED"})
    rows.append({"url": "chrome://settings/", "title": "Settings", "time_usec": now, "page_transition": "TYPED"})
    write(path, json.dumps({"Browser History": rows}))


def omnibar_rows(query):
    reply = rpc("debug.omnibar_type", {"text": query, "commit": False})
    return reply.get("rows") or []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def cli(*args, timeout=30):
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)


def rpc(method, params=None):
    r = cli("--json", "app", "call", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    check(False, f"timed out: {what}")
    return None


def dialog(identifier):
    found = [d for d in rpc("debug.dialog").get("dialogs", []) if d.get("identifier") == identifier and d.get("visible", True)]
    return found[-1] if found else None


def key(name, modifiers=None):
    reply = rpc("debug.key", {"key": name, "modifiers": modifiers or [], "target": "palette"})
    time.sleep(0.15)  # the palette's search and listing land
    return reply


def type_text(text):
    for char in text:
        key(char)


def toasts():
    return [t.get("message", "") for w in rpc("debug.toast").get("windows", []) for t in w.get("toasts", [])]


def bookmark_urls():
    return [b.get("url") for b in rpc("bookmark.list", {"profile": "default"}).get("bookmarks", []) if b.get("kind") == "url"]


def snapshot(name, kind="main"):
    """The window that shows the open import sheet (its own window number), else the `kind` window."""
    path = os.path.join(opts.out, f"{name}.png")
    shown = [d for d in rpc("debug.dialog").get("dialogs", []) if d.get("visible", True) and d.get("window")]
    target = {"window": shown[-1]["window"]} if shown else {"kind": kind}
    reply = rpc("debug.window_snapshot", {**target, "path": path})
    print(f"note: snapshot {name} {target} {reply.get('kind')}", flush=True)
    check(os.path.exists(path), f"snapshot {name} ({reply.get('method') or reply.get('error')})")


def steps_of(browser, shot=None):
    """Picks `browser` on the open browser sheet; its steps sheet, then Cancel."""
    rpc("debug.dialog", {"set": {"browser": browser}})
    rpc("debug.dialog", {"press": "continue"})
    steps = wait_for(lambda: dialog("cmux.dialog.importFiles.steps"), f"{browser}'s export steps")
    if steps and shot:
        snapshot(shot)
    rpc("debug.dialog", {"press": "cancel"})
    wait_for(lambda: dialog("cmux.dialog.importFiles.steps") is None, f"{browser}'s steps close")
    return steps or {}


def open_browser_sheet(what):
    reply = rpc("debug.toast", {"perform": "browser.importFromFiles"})
    check(reply.get("performed") is True, f"the action runs as a person's palette run ({what}: {reply})")
    return wait_for(lambda: dialog("cmux.dialog.importFiles.browser"), f"the browser sheet ({what})")


def entries_and_steps():
    for mode in ["light", "dark"]:
        rpc("debug.appearance", {"mode": mode})
        time.sleep(1.0)  # the window redraws in the new appearance (screenshot only)
        if not open_browser_sheet(f"palette, {mode}"):
            return
        snapshot(f"browser-sheet-{mode}")
        steps = steps_of("1password", f"steps-1password-{mode}")
        lines = " ".join(steps.get("lines", []))
        check("1Password" in steps.get("title", "") and "File > Export" in lines and "CSV" in lines,
              f"1Password's steps say how it exports its CSV ({steps.get('title')}: {steps.get('lines')})")
        if mode == "dark":
            continue
        open_browser_sheet("Bitwarden")
        lines = " ".join(steps_of("bitwarden").get("lines", []))
        check("Export Vault" in lines and "Bookmarks:" not in lines, f"Bitwarden's steps: passwords only ({lines})")
        open_browser_sheet("Arc")
        lines = " ".join(steps_of("arc").get("lines", []))
        check("arc://password-manager/settings" in lines and "Bookmarks:" not in lines,
              f"Arc's steps name its password page and no bookmarks export ({lines})")
    # The onboarding window's Import step: its button opens the same sheet.
    rpc("debug.onboarding", {"action": "open", "step": "importData"})
    time.sleep(1.0)  # the window lays out (screenshot only)
    snapshot("onboarding-import-dark", "onboarding")
    rpc("debug.onboarding", {"action": "import_from_files"})
    check(wait_for(lambda: dialog("cmux.dialog.importFiles.browser"), "the browser sheet from onboarding") is not None,
          "the onboarding Import step opens Import from Another Browser…")
    snapshot("onboarding-browser-sheet-dark", "onboarding")
    rpc("debug.dialog", {"press": "cancel"})
    rpc("debug.onboarding", {"action": "close"})
    rpc("debug.appearance", {"mode": "light"})
    # The Passwords page shows the button. A click from page script is not the person's (the host
    # tracks real AppKit events), so the person-only action must refuse it: no sheet opens.
    print("note: passwords.open", rpc("debug.toast", {"perform": "passwords.open"}), flush=True)
    clicked = wait_for(lambda: (rpc("debug.page", {"page": "cmux.passwords", "action": "click", "selector": ".pw-import-files"}) or {})
                       .get("clicked") or None, "the Passwords page's import button", 30)
    check(clicked is not None, "the Passwords page shows Import from Another Browser…")
    time.sleep(2)  # a refused run shows nothing; give a wrongly allowed one time to open its sheet
    check(dialog("cmux.dialog.importFiles.browser") is None, "a page-script click does not open the person-only import")
    rpc("debug.dialog", {"press": "cancel"})


def import_through(browser, filename):
    """Runs the action, picks `browser`, checks its steps, and picks `filename` in the picker; the steps dialog."""
    reply = rpc("debug.toast", {"perform": "browser.importFromFiles"})
    check(reply.get("performed") is True, f"the action runs as a person's palette run ({reply})")
    shown = wait_for(lambda: dialog("cmux.dialog.importFiles.browser"), f"the browser dialog ({browser})")
    if not shown:
        return None
    rpc("debug.dialog", {"set": {"browser": browser}})
    rpc("debug.dialog", {"press": "continue"})
    steps = wait_for(lambda: dialog("cmux.dialog.importFiles.steps"), f"{browser}'s export steps")
    if not steps:
        return shown
    rpc("debug.dialog", {"press": "choose"})
    time.sleep(0.8)  # the picker's first listing
    type_text(EXPORTS + "/")
    report = key("return")
    print("note: picker folder", {k: report.get(k) for k in ("palette_page", "palette_selected")}, flush=True)
    type_text(filename.split(".")[0])
    report = key("forwarddelete")
    print("note: picker filtered", {k: report.get(k) for k in ("palette_page", "palette_selected")}, flush=True)
    report = key("return")
    print("note: picker chose", {k: report.get(k) for k in ("palette_page", "palette_selected", "palette_open")}, flush=True)
    return shown, steps


write(CONFIG, "{}\n")
write(os.path.join(EXPORTS, "bookmarks.html"), BOOKMARKS_HTML)
write(os.path.join(EXPORTS, "passwords.csv"), PASSWORDS_CSV)
write(os.path.join(EXPORTS, "columns.csv"), COLUMNS_CSV)
write(os.path.join(EXPORTS, "headerless.csv"), HEADERLESS_CSV)
safari_zip(os.path.join(EXPORTS, "safari-export.zip"))
takeout_history(os.path.join(EXPORTS, "takeout-history.json"))
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
write(EMPTY_GHOSTTY, "")
teardown = TagTeardown(APP)
teardown.install()
app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                                      "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY,
                                      # A DEV bundle stores passwords under Chromium's mock Keychain key, so the
                                      # import is off unless the data is throwaway (DEBUG builds only): it is.
                                      "CMUX_NEXT_PASSWORD_IMPORT_MOCK_KEY": "throwaway"},
                       stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)
    entries_and_steps()
    result = import_through("edge", "bookmarks.html")
    if isinstance(result, tuple):
        shown, steps = result
        check("Microsoft Edge" in steps.get("title", ""), f"the steps name the picked browser ({steps.get('title')})")
        lines = " ".join(steps.get("lines", []))
        check("edge://settings/passwords" in lines and "edge://favorites" in lines,
              f"Microsoft Edge's steps name its export pages ({steps.get('lines')})")
    check(wait_for(lambda: "https://edge-export.example.com/" in bookmark_urls(), "the bookmark lands") is not None,
          f"the picked bookmarks HTML is imported ({bookmark_urls()})")
    result = import_through("safari", "passwords.csv")
    if isinstance(result, tuple):
        check("Safari" in result[1].get("title", ""), f"Safari's steps name Safari ({result[1].get('title')})")
    summary = wait_for(lambda: next((t for t in toasts() if "Imported:" in t), None), "the passwords toast", 60)
    check(summary is not None and "Imported: 2" in summary, f"the picked passwords CSV is imported ({summary})")
    check(not os.path.exists(os.path.join(EXPORTS, "passwords.csv")), "the imported CSV goes to the Trash")
    check("not-a-real-password" not in json.dumps(rpc("debug.toast")), "no password shows in a toast")

    # The passwords toast says "Imported: 2" too: let it go before this import.
    wait_for(lambda: not any("Imported:" in t for t in toasts()), "the earlier passwords toast goes", 40)
    import_through("firefox", "columns.csv")
    sheet = wait_for(lambda: dialog("cmux.dialog.passwordCSV.columns"), "the column sheet", 30)
    if sheet:
        shown = json.dumps(sheet)
        snapshot("column-sheet-light")
        labels = sorted({o.get("label") for opts in (sheet.get("options") or {}).values() for o in opts})
        check("rows: 2" in shown and {"Site", "Login", "Secret"} <= set(labels),
              f"the column sheet offers the column names and shows the row count ({labels}; {sheet.get('lines')})")
        check("not-a-real-password" not in shown and "cols-one" not in shown, "the column sheet shows no value of the file")
        rpc("debug.dialog", {"set": {"url": "0", "username": "1", "password": "2"}})
        rpc("debug.dialog", {"press": "import"})
        # Every row in the store sends the file to the Trash (a toast with the same text may still show).
        moved = wait_for(lambda: not os.path.exists(os.path.join(EXPORTS, "columns.csv")), "the matched CSV goes to the Trash", 60)
        check(moved is not None and any("Imported: 2" in t for t in toasts()), f"the matched columns import both rows ({toasts()})")
    import_through("firefox", "headerless.csv")
    failed = wait_for(lambda: next((t for t in toasts() if "no website and password columns" in t), None), "the headerless CSV's failure", 30)
    check(failed is not None and dialog("cmux.dialog.passwordCSV.columns") is None,
          f"a CSV with no header row opens no column sheet and fails ({toasts()})")
    check("not-a-real-password" not in json.dumps(rpc("debug.toast")) + json.dumps(rpc("debug.dialog")),
          "no password of the column files shows in a toast or a sheet")

    import_through("safari", "safari-export.zip")
    check(wait_for(lambda: f"https://safari-zip-{RUN}.example.com/" in bookmark_urls(), "the zip's bookmark lands") is not None,
          "the Safari zip's bookmarks are imported")
    summary = wait_for(lambda: next((t for t in toasts() if "Imported: 1" in t), None), "the zip's passwords toast", 60)
    check(summary is not None, f"the Safari zip's passwords are imported ({toasts()})")
    check(wait_for(lambda: not os.path.exists(os.path.join(EXPORTS, "safari-export.zip")), "the zip goes to the Trash") is not None,
          "the Safari zip goes to the Trash")
    check(wait_for(lambda: next((t for t in toasts() if "history imported: 1" in t.lower()), None), "the zip's history toast") is not None,
          f"the Safari zip's history is imported ({toasts()})")
    check("0000000000000000" not in json.dumps(rpc("debug.toast")) + json.dumps(bookmark_urls()), "the zip's credit card file is not imported")

    result = import_through("chrome", "takeout-history.json")
    if isinstance(result, tuple):
        check("takeout.google.com" in " ".join(result[1].get("lines", [])), f"Chrome's steps name Google Takeout ({result[1].get('lines')})")
    # Two pages, so the Safari zip's "1" toast can't stand in for this one.
    check(wait_for(lambda: next((t for t in toasts() if "history imported: 2" in t.lower()), None), "the Takeout history toast") is not None,
          f"the Takeout history is imported, two pages from four visits and no chrome:// page ({toasts()})")

    rpc("action.run", {"action": "openBrowser.webkit", "args": {"url": "about:blank"}, "focus": True})
    time.sleep(2)  # the tab's omnibar comes up
    # A history suggestion row shows the page's title, which only the imported history holds;
    # the typed text alone is not one.
    rows = wait_for(lambda: omnibar_rows(f"safari-hist-{RUN}") if f"Safari history {RUN}" in omnibar_rows(f"safari-hist-{RUN}") else None,
                    "Safari history in the omnibar", 15)
    check(rows is not None, f"the omnibar suggests the Safari zip's history ({omnibar_rows(f'safari-hist-{RUN}')})")
    rows = wait_for(lambda: omnibar_rows(f"takeout-{RUN}") if f"Takeout history {RUN}" in omnibar_rows(f"takeout-{RUN}") else None,
                    "Takeout history in the omnibar", 15)
    check(rows is not None, f"the omnibar suggests the Takeout history ({omnibar_rows(f'takeout-{RUN}')})")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the PID launched above, never a pattern
    teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
