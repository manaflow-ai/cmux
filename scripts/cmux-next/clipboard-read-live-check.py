#!/usr/bin/env python3
"""Live check: an OSC 52 clipboard read asks the user, Deny answers empty, Allow answers the clipboard.

  scripts/cmux-next/clipboard-read-live-check.py --tag <tag> [--out DIR] [--allow-timeout 120]

Launches the tagged app (no activation, automation socket) with an isolated
config whose Ghostty config sets `clipboard-read = ask`, puts a marker on the
host pasteboard (pbcopy), and runs a small reader in a terminal: it prints
the OSC 52 read `ESC ] 52 ; c ; ? BEL`, reads the reply from the tty and
writes it, decoded, to a JSON file.

Round 1 (Deny): the clipboard-read dialog (identifier
cmux.dialog.terminalClipboardRead) must be listed by `debug.dialog`, the
socket must refuse to press its buttons, window snapshots are saved, and the
socket DISMISSES it (a refusal): the reply must be an empty clipboard.

Round 2 (Allow): only the user answers a clipboard read, so Allow is pressed
through Computer Use (`cua-driver`, an accessibility press on the Allow button
of the tagged app's window), never through the socket. The reply must be the
marker. When cua-driver has no Accessibility/Screen Recording grant on the
host, Allow is reported UNVERIFIED with the reason and the dialog is
dismissed so the reader ends.

Quits the app it started (its PID only). Writes clipboard-read-live.json and
PNGs to --out. Fleet GUI host only (cmux-lawrence-2), never a laptop in use.
Exit 1 on a failed check; an UNVERIFIED Allow alone is not a failure.
"""
import argparse, glob, json, os, plistlib, re, secrets, shlex, signal, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="clipboard-read-live-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--allow-timeout", type=float, default=120.0, help="seconds the Allow round's reader waits")
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"), help="cua-driver binary")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
OUT = os.path.abspath(opts.out)

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}; pass --app")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
IDENTIFIER = "cmux.dialog.terminalClipboardRead"
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
MARKER = f"r92-clipboard-marker-{secrets.token_hex(6)}"
report = {"tag": opts.tag, "app": APP, "marker": MARKER}
failures = []

# Runs in the terminal: raw tty, OSC 52 read, reply decoded into a JSON file.
READER = r'''
import base64, json, os, select, sys, termios, time, tty
out, timeout = sys.argv[1], float(sys.argv[2])
fd = os.open("/dev/tty", os.O_RDWR)
old = termios.tcgetattr(fd)
tty.setraw(fd)
result = {"status": "timeout"}
try:
    os.write(fd, b"\x1b]52;c;?\x07")
    buf, end = b"", time.time() + timeout
    while time.time() < end:
        ready, _, _ = select.select([fd], [], [], max(0.0, end - time.time()))
        if not ready:
            break
        buf += os.read(fd, 65536)
        start = buf.find(b"\x1b]52;")
        if start < 0:
            continue
        ends = [i for i in (buf.find(b"\x07", start), buf.find(b"\x1b\\", start)) if i >= 0]
        if ends:
            parts = buf[start + 2:min(ends)].split(b";", 2)
            data = parts[2] if len(parts) == 3 else b""
            result = {"status": "reply", "raw": buf[start:min(ends)].decode("latin-1"),
                      "decoded": base64.b64decode(data).decode("utf-8", "replace")}
            break
    result["unparsed"] = buf.decode("latin-1") if result["status"] != "reply" else ""
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
with open(out + ".tmp", "w") as f:
    json.dump(result, f)
os.rename(out + ".tmp", out)
print("clipboard-read reader:", result["status"], repr(result.get("decoded")))
'''


def cli(*args, timeout=30):
    return subprocess.run([CLI, "--socket", SOCKET, *args], capture_output=True, text=True, timeout=timeout,
                          env={**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"})


def rpc(method, params=None):
    r = cli("rpc", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def check(label, ok, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'} {label} {detail}", flush=True)
    if not ok:
        failures.append(label)


def terminal_surface():
    """A selected terminal surface ref in the first workspace."""
    for line in cli("list-workspaces").stdout.splitlines():
        m = re.search(r"(workspace:\d+)", line)
        if not m:
            continue
        for row in cli("tree", "--workspace", m.group(1)).stdout.splitlines():
            s = re.search(r"surface (surface:\d+) \[terminal\]", row)
            if s:
                return s.group(1)
    return None


def clipboard_dialog():
    for dialog in rpc("debug.dialog").get("dialogs") or []:
        if dialog.get("identifier") == IDENTIFIER and dialog.get("visible"):
            return dialog
    return None


def start_read(surface, name, timeout):
    reply = os.path.join(OUT, f"{name}-reply.json")
    if os.path.exists(reply):
        os.unlink(reply)
    command = f"/usr/bin/python3 {shlex.quote(READER_PATH)} {shlex.quote(reply)} {timeout:g}\n"
    sent = cli("send", "--surface", surface, command)
    check(f"{name}: reader sent", sent.returncode == 0, (sent.stdout + sent.stderr).strip()[:200])
    return reply


def read_reply(path, seconds):
    if not wait(lambda: os.path.exists(path), seconds, 0.5):
        return None
    with open(path) as f:
        return json.load(f)


def shots(name, dialog):
    report[f"{name}_snapshot_main"] = rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, f"{name}-window.png")})
    if dialog.get("window"):
        report[f"{name}_snapshot_dialog"] = rpc("debug.window_snapshot", {"window": int(dialog["window"]),
                                                                        "path": os.path.join(OUT, f"{name}-dialog.png")})
    check(f"{name}: window snapshot saved", os.path.exists(os.path.join(OUT, f"{name}-window.png")),
          json.dumps(report[f"{name}_snapshot_main"])[:200])


def cua(tool, args):
    r = subprocess.run([opts.cua, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=60)
    try:
        return r.returncode, json.loads(r.stdout)
    except ValueError:
        return r.returncode, {"text": (r.stdout + r.stderr).strip()}


def find_allow(node):
    """The element_token of an AX button titled Allow, searched anywhere in a cua-driver reply."""
    if isinstance(node, dict):
        token = node.get("element_token")
        labels = {str(node.get(k, "")) for k in ("label", "title", "name", "description", "value")}
        if token and "Allow" in labels and "button" in str(node.get("role", "")).lower():
            return token
        for value in node.values():
            found = find_allow(value)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = find_allow(value)
            if found:
                return found
    return None


def press_allow(pid):
    """Presses Allow through Computer Use. Returns (pressed, reason)."""
    if not os.path.exists(opts.cua):
        return False, f"no cua-driver at {opts.cua}"
    code, perms = cua("check_permissions", {})
    report["cua_permissions"] = perms
    if code != 0 or "pending" in json.dumps(perms) or "denied" in json.dumps(perms).lower():
        return False, f"cua-driver check_permissions: exit {code}: {json.dumps(perms)[:300]}"
    code, windows = cua("list_windows", {"pid": pid})
    report["cua_windows"] = windows
    ids = sorted({w for w in re.findall(r'"window_id":\s*(\d+)', json.dumps(windows))}, key=int)
    for window_id in ids:
        code, state = cua("get_window_state", {"pid": pid, "window_id": int(window_id)})
        token = find_allow(state)
        if token:
            code, clicked = cua("click", {"pid": pid, "window_id": int(window_id), "element_token": token})
            report["cua_click"] = clicked
            return code == 0, f"click exit {code}: {json.dumps(clicked)[:300]}"
    return False, f"no Allow button in the AX tree of windows {ids}"


READER_PATH = os.path.join(OUT, "osc52-reader.py")
with open(READER_PATH, "w") as f:
    f.write(READER)
GHOSTTY = os.path.join(OUT, "ghostty-config")
with open(GHOSTTY, "w") as f:
    f.write("clipboard-read = ask\n")
CONFIG = os.path.join(OUT, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")

subprocess.run(["pbcopy"], input=MARKER, text=True, check=True)
pasted = subprocess.run(["pbpaste"], capture_output=True, text=True).stdout
check("host pasteboard holds the marker", pasted == MARKER, repr(pasted[:80]))

if os.path.exists(SOCKET):
    os.unlink(SOCKET)
env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
log = open(os.path.join(OUT, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report["pid"] = app.pid
print(f"launched pid {app.pid} (log {OUT}/app.log)", flush=True)
try:
    if not wait(lambda: os.path.exists(SOCKET) and rpc("debug.surfaces").get("windows"), 120, 0.5):
        sys.exit("tagged app did not come up")
    surface = wait(terminal_surface, 30, 0.5)
    if not surface:
        sys.exit("no terminal surface")
    report["surface"] = surface
    time.sleep(2)  # let the shell print its prompt before the reader runs

    # Round 1: Deny (a socket dismissal refuses the read).
    reply_path = start_read(surface, "deny", 60)
    dialog = wait(clipboard_dialog, 30, 0.25)
    report["deny_dialog"] = dialog
    check("deny: clipboard-read dialog listed and visible", dialog is not None,
          json.dumps(rpc("debug.dialog"))[:400] if dialog is None else json.dumps(dialog)[:400])
    if dialog:
        shots("deny", dialog)
        refused = rpc("debug.dialog", {"id": dialog["id"], "press": "allow"})
        report["deny_socket_press"] = refused
        check("socket may not press Allow", "answer only to the user" in str(refused.get("error", "")),
              json.dumps(refused)[:200])
        dismissed = rpc("debug.dialog", {"id": dialog["id"], "dismiss": True})
        check("deny: socket dismissed the dialog", dismissed.get("dismissed") is True, json.dumps(dismissed)[:200])
    reply = read_reply(reply_path, 70)
    report["deny_reply"] = reply
    check("deny: reply is an empty clipboard", bool(reply) and reply.get("status") == "reply" and reply.get("decoded") == "",
          json.dumps(reply)[:300])
    report["deny_screen"] = cli("read-screen", "--surface", surface).stdout[-1500:]

    # Round 2: Allow (Computer Use only).
    time.sleep(1)
    reply_path = start_read(surface, "allow", opts.allow_timeout)
    dialog = wait(clipboard_dialog, 30, 0.25)
    report["allow_dialog"] = dialog
    check("allow: clipboard-read dialog listed and visible", dialog is not None)
    if dialog:
        shots("allow", dialog)
        pressed, reason = press_allow(app.pid)
        report["allow_press"] = {"pressed": pressed, "reason": reason}
        if pressed:
            reply = read_reply(reply_path, opts.allow_timeout + 10)
            report["allow_reply"] = reply
            report["allow"] = "VERIFIED" if reply and reply.get("decoded") == MARKER else "FAILED"
            check("allow: reply is the marker", report["allow"] == "VERIFIED", json.dumps(reply)[:300])
        else:
            report["allow"] = f"UNVERIFIED: {reason}"
            print(f"UNVERIFIED allow: {reason}", flush=True)
            rpc("debug.dialog", {"id": dialog["id"], "dismiss": True})
            report["allow_reply_after_dismiss"] = read_reply(reply_path, 20)
    report["allow_screen"] = cli("read-screen", "--surface", surface).stdout[-1500:]
    focus = rpc("debug.focus")
    report["focus"] = focus
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(30)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    report["app_exit"] = app.returncode
report["failures"] = failures
with open(os.path.join(OUT, "clipboard-read-live.json"), "w") as f:
    json.dump(report, f, indent=1)
print("allow:", report.get("allow"))
print("PASS" if not failures else "FAIL", f"(evidence {OUT}/clipboard-read-live.json)")
sys.exit(1 if failures else 0)
