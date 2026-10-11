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
  4. a passwords CSV picked through Safari's steps is imported (the counts toast).

Quits the app by PID and stops the tag's daemons at the end.
"""
import argparse, glob, json, os, plistlib, subprocess, sys, tempfile, time

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
# Synthetic sign-ins on example.test; never a real password.
PASSWORDS_CSV = "Title,URL,Username,Password,Notes,OTPAuth\n" \
                "one.example.test,https://one.example.test/,cmux-one,not-a-real-password-1,,\n" \
                "two.example.test,https://two.example.test/,cmux-two,not-a-real-password-2,,\n"


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
    imported = wait_for(lambda: next((t for t in toasts() if "Imported: 2" in t), None), "the passwords toast", 90)
    if not imported:
        print("note: csv still in place:", os.path.exists(os.path.join(EXPORTS, "passwords.csv")), "toasts:", toasts(), flush=True)
    check(imported is not None, f"the picked passwords CSV is imported ({toasts()})")
    check("not-a-real-password" not in json.dumps(rpc("debug.toast")), "no password shows in a toast")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the PID launched above, never a pattern
    teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
