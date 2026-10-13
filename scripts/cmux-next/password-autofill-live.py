#!/usr/bin/env python3
"""Live check: Chromium fills a saved sign-in into a login form (cx-d0d.13 groundwork).

  scripts/cmux-next/password-autofill-live.py --tag <tag> [--out DIR] [--app PATH]

A daily Chrome user's first expectation of saved passwords. A throwaway sign-in
for a local login page is imported as a person does (Import from Another
Browser…, a passwords CSV). Then:
  1. a Chromium tab a person opens on that page gets the sign-in filled;
  2. a Chromium tab an agent opens (the socket's action.run) never does
     (plans/cmux-next/passwords.md, slice 1);
  3. a CSV with a new password for that sign-in keeps the saved one and its
     toast offers Replace; pressing it saves the new one, so importing the new
     one again counts as already saved (cx-dwg.6);
  4. a sign-in a person types and submits gets cmux's save prompt in the tab's
     prompt bar (not Chromium's bubble); Save stores it, so importing that
     sign-in counts as already saved (cx-d0d.13, passwords.md 1.1).
Nothing reads the page through the socket, since any automated read marks
the tab agent-driven and turns filling off: the page reports its own form
(:autofill on both fields) to the test's local server.

Quits the app through the socket (by PID if it hangs) and stops the tag's daemons at the end.
"""
import argparse, glob, http.server, json, os, plistlib, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="password-autofill-live-"))
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
SCRATCH = tempfile.mkdtemp(prefix=f"password-autofill-{opts.tag}-")
EXPORTS = os.path.join(SCRATCH, "exports")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []
# New each run: the test machine keeps the Chromium profile, which would count a repeat as already saved.
RUN = os.urandom(4).hex()
USERNAME = f"cmux-fill-{RUN}"
TYPED_USER = f"cmux-typed-{RUN}"
TYPED_PASSWORD = f"typed-throwaway-{RUN}"

# The login page reports its own form every 200 ms; reports[tab] is the latest.
reports = {}
LOGIN_PAGE = """<!doctype html><title>Sign in</title>
<form method=post action=/done><input id=u name=username autocomplete=username autofocus>
<input id=p name=password type=password autocomplete=current-password><button>Sign in</button></form>
<script>
const tab = new URLSearchParams(location.search).get("tab");
const filled = el => { try { return el.matches(":autofill"); } catch { return el.matches(":-webkit-autofill"); } };
setInterval(() => {
  const u = document.getElementById("u"), p = document.getElementById("p");
  navigator.sendBeacon("/report", JSON.stringify({tab, username: u.value, usernameFilled: filled(u), passwordFilled: filled(p)}));
}, 200);
</script>"""


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = LOGIN_PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.startswith("/done"):
            # A signed-in page: Chromium sees the submission succeed and asks to save.
            body = b"<!doctype html><title>Signed in</title><p>Signed in"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        try:
            report = json.loads(data)
            reports[report.get("tab")] = report
        except ValueError:
            pass
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
ORIGIN = f"http://127.0.0.1:{server.server_port}"
TYPED_ORIGIN = f"http://localhost:{server.server_port}"
PASSWORDS_CSV = "name,url,username,password,note\n" \
                f"127.0.0.1,{ORIGIN}/login,{USERNAME},not-a-real-password-{RUN},\n"
CHANGED_CSV = PASSWORDS_CSV.replace("not-a-real-password", "a-new-throwaway-password")
CSV_TOAST = "password-csv-imported"


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
    try:
        r = cli("--json", "app", "call", method, json.dumps(params or {}))
    except subprocess.TimeoutExpired:
        return {"error": f"{method} timed out"}  # a hung app is a FAIL line, and cleanup still runs
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


def key(name, modifiers=None, target="palette"):
    reply = rpc("debug.key", {"key": name, "modifiers": modifiers or [], "target": target})
    time.sleep(0.15)  # the palette's search and listing land
    return reply


def type_text(text, target="palette"):
    for char in text:
        key(char, target=target)


def save_prompt():
    prompts = rpc("debug.browser.prompts").get("prompts", [])
    return next((p for p in prompts if "savePassword" in p.get("kind", "")), None)


def shown_toasts():
    return [t for w in rpc("debug.toast").get("windows", []) for t in w.get("toasts", [])]


def toasts():
    return [t.get("message", "") for t in shown_toasts()]


def import_through(browser, filename, attempts=2):
    """Runs the action, picks `browser`, checks its steps, and picks `filename` in the picker; the steps dialog.

    Soon after launch the picker can close before its first key (the window
    taking focus); then the whole flow runs once more."""
    for attempt in range(attempts):
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
        # The picker is the palette; at first launch it can take seconds to open.
        wait_for(lambda: rpc("debug.focus").get("context", {}).get("palette_open"), "the file picker opens", 20)
        time.sleep(0.8)  # the picker's first listing
        type_text(EXPORTS + "/")
        report = key("return")
        if "palette_page" not in report:
            print(f"note: picker closed before its keys (attempt {attempt + 1})", report, flush=True)
            continue
        print("note: picker folder", {k: report.get(k) for k in ("palette_page", "palette_selected")}, flush=True)
        type_text(filename.split(".")[0])
        report = key("forwarddelete")
        print("note: picker filtered", {k: report.get(k) for k in ("palette_page", "palette_selected")}, flush=True)
        report = key("return")
        print("note: picker chose", {k: report.get(k) for k in ("palette_page", "palette_selected", "palette_open")}, flush=True)
        return shown, steps
    check(False, f"the file picker stays open for {filename}")
    return None




def to_workspace():
    """Leaves a top page (Home shows at first launch; a page has no tabs) for a workspace with a pane."""
    rpc("action.run", {"action": "workspace.selectFirst"})
    rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    time.sleep(1)  # the workspace's pane comes up


def filled(tab):
    report = reports.get(tab) or {}
    # Chromium keeps a filled value from page script until the person
    # interacts (its password gatekeeper), so the page sees :autofill only.
    return report if report.get("usernameFilled") and report.get("passwordFilled") else None


write(CONFIG, "{}\n")
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
print(f"app pid {app.pid}, scratch {SCRATCH}, origin {ORIGIN}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)
    to_workspace()  # the picker's keys go to a window's palette, not the first-launch Home page
    import_through("chrome", "passwords.csv")
    summary = wait_for(lambda: next((t for t in toasts() if "Imported:" in t), None), "the passwords toast", 60)
    check(summary is not None and "Imported: 1." in summary, f"the throwaway sign-in is saved ({summary})")

    to_workspace()
    reply = rpc("debug.toast", {"perform": "openBrowser.chromium", "arguments": {"url": f"{ORIGIN}/login?tab=person"}})
    check(reply.get("performed") is True, f"a person opens the login page in a Chromium tab ({reply})")
    opened = time.monotonic()
    report = wait_for(lambda: filled("person"), "the person's tab is filled", 30)
    fill_time = time.monotonic() - opened
    check(report is not None, f"Chromium fills the saved sign-in in a person's tab ({reports.get('person')})")

    reply = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": f"{ORIGIN}/login?tab=agent"}, "focus": True})
    print("note: agent open", reply, flush=True)
    wait_for(lambda: "agent" in reports, "the agent's tab reports", 30)
    time.sleep(max(3, 2 * fill_time))  # twice as long as the person's tab took to fill
    agent = reports.get("agent") or {}
    check("agent" in reports and not agent.get("passwordFilled") and not agent.get("usernameFilled"),
          f"an agent's Chromium tab is never filled ({agent})")

    # The same sign-in with a new password: a conflict, never overwritten
    # silently; Replace is the person's choice.
    write(os.path.join(EXPORTS, "changed.csv"), CHANGED_CSV)
    import_through("chrome", "changed.csv")
    conflict = wait_for(lambda: next((t for t in shown_toasts() if "different password" in t.get("message", "")), None),
                        "the conflict toast", 60)
    check(conflict is not None and (conflict.get("action") or "").startswith("Replace") and conflict.get("id", "").startswith(CSV_TOAST),
          f"the conflict toast offers Replace ({conflict})")
    reply = rpc("debug.toast", {"press": (conflict or {}).get("id")})
    check(reply.get("pressed") is True, f"a person presses Replace ({reply.get('pressed')})")
    replaced = wait_for(lambda: next((t for t in toasts() if "Replaced:" in t), None), "the replaced toast", 60)
    check(replaced is not None and "Replaced: 1." in replaced, f"the saved password is replaced ({replaced})")
    wait_for(lambda: not os.path.exists(os.path.join(EXPORTS, "changed.csv")), "the replaced file goes to the Trash", 10)
    check(not os.path.exists(os.path.join(EXPORTS, "changed.csv")), "every row is saved, so the file goes to the Trash")

    write(os.path.join(EXPORTS, "again.csv"), CHANGED_CSV)
    import_through("chrome", "again.csv")
    again = wait_for(lambda: next((t for t in toasts() if "Imported: 0." in t), None), "the repeat import toast", 60)
    check(again is not None and "different password" not in again,
          f"the new password is the saved one: importing it again is already saved ({again})")

    # A person types a new sign-in and submits it: cmux's prompt bar asks, not Chromium's bubble.
    # Another origin (localhost, same server) with no saved sign-in, so no fill lands in the fields.
    reply = rpc("debug.toast", {"perform": "openBrowser.chromium", "arguments": {"url": f"{TYPED_ORIGIN}/login?tab=typed"}})
    check(reply.get("performed") is True, f"a person opens the login page to sign in ({reply.get('performed')})")
    wait_for(lambda: "typed" in reports, "the sign-in page reports", 30)
    type_text(TYPED_USER, target="page")
    key("tab", target="page")
    type_text(TYPED_PASSWORD, target="page")
    key("return", target="page")
    prompt = wait_for(save_prompt, "the save prompt", 30)
    check(prompt is not None and f'username: "{TYPED_USER}", update: false' in prompt.get("kind", ""),
          f"the prompt bar asks to save the typed sign-in ({prompt})")
    reply = rpc("debug.browser.prompts", {"respond": "accept"})
    check(reply.get("responded") is True, f"a person presses Save ({reply.get('responded')})")
    time.sleep(1)  # the store writes after the answer

    # The earlier import's toast goes first, so the next one read is this import's.
    wait_for(lambda: not any("Imported:" in t or "Replaced:" in t for t in toasts()), "the earlier import toast goes", 40)
    write(os.path.join(EXPORTS, "typed.csv"), "name,url,username,password,note\n"
          f"localhost,{TYPED_ORIGIN}/login,{TYPED_USER},{TYPED_PASSWORD},\n")
    import_through("chrome", "typed.csv")
    typed = wait_for(lambda: next((t for t in toasts() if "Imported:" in t), None),
                     "the typed sign-in's import toast", 60)
    check(typed is not None and "Imported: 0." in typed and "different password" not in typed,
          f"the saved sign-in is the typed one: importing it is already saved ({typed})")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the PID launched above, never a pattern
    teardown.end()
    server.shutdown()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
