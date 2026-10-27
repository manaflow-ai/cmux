#!/usr/bin/env python3
"""TCC attribution rows of chromium-host-bench.py (`--modes tcc`; plans/cmux-next/chrome-parity/p01-process.md, task 089).

A page in the Chromium host process asks for each protected resource; every row passes when macOS charges the request
to cmux itself, not to the host executable, a Chromium helper or a bundle of their own:

  camera, microphone, screen, bluetooth   tccd's AUTHREQ_SUBJECT and the responsible process of every request for the
                  service (kTCCServiceCamera, ...) from a process of this bundle are cmux's bundle id and cmux's main
                  executable, and at least one of them comes from the host or a helper (its accessing process is in
                  the bundle but is not cmux's main executable): cmux's own preflights (SystemPermissionProbe's
                  AVCaptureDevice.authorizationStatus) never stand for the host's request. Chrome's model: the
                  browser process is the responsible process of its helpers (base/process/launch_mac.cc keeps
                  responsibility; only `disclaim_responsibility` changes it), so its TCC grants are the app's.
  location        locationd names cmux's bundle id as the client and no other identity of the bundle (a helper or
                  host bundle id, an org.chromium id).
  local_network   macOS 15 and later: a fetch to this Mac's LAN address; nehelper (Local Network privacy) names cmux's
                  bundle id and no other identity of the bundle. macOS 14 has no Local Network privacy: the row does
                  not apply there.
  keychain        Chromium's OSCrypt key ("Chromium Safe Storage", components/os_crypt/sync/keychain_password_mac.mm)
                  does not exist when the host starts, exists after it ran, and no SecurityAgent prompt showed: the
                  host read it through the login keychain (Chromium creates the item at its first read). The bench
                  deletes the item before the host starts only when this run made it or `--keychain-reset` allows
                  it, and deletes it again at the end of the mode in those cases.

The mode needs a bench-hooks build (reload.sh's bench config: a com.cmuxterm.app.debug.* id, so debug.chromium_host
and debug.key exist). Such a development bundle runs Chromium with its mock keychain (CEFSwitches.useMockKeychain);
the bench launches it with CMUX_NEXT_BENCH_REAL_KEYCHAIN=1 (read by CEFSwitches.current in Debug and bench builds of
a development bundle only), so both engines use the login keychain as a shipped build does (``keychain_plan``).

tccd charges a request to the requester's responsible process, which a process inherits from the process that
exec'd it. The bench therefore launches cmux with responsibility disclaimed (bench_launch.BenchApp
own_responsibility), as a person's launch through LaunchServices makes cmux its own responsible process, and the mode
first reads the responsible process of cmux's pid (responsibility_get_pid_responsible_for_pid). When that is not
cmux, every row would measure the bench's own parent chain: the mode stops with a mode error and runs no row.

Every row also reads the system prompts that appear while it runs (CGWindowList owners, which need no grant). With
the Accessibility grant for the bench's process it reads their text (it must name cmux and not Chromium or a helper)
and answers "Don't Allow", so a fleet host is never left with a prompt and the grant stays off. Without it the text is
reported as not readable and the prompt stays until the app quits.

Evidence is the unified log (`log stream`, tccd, locationd and nehelper). A host whose log redacts identities
(`<private>`) fails the row and says so.
"""
from __future__ import annotations

import ctypes
import http.server
import json
import os
import platform
import plistlib
import re
import socket
import subprocess
import threading
import time
from dataclasses import dataclass, field

ROW_LIMIT_S = 20.0
LOG_GRACE_S = 1.5
ALLOW_EVERY_S = 1.0
TITLE_PREFIX = "tcc "
KEYCHAIN_SERVICE = "Chromium Safe Storage"
TCC_PROMPT_OWNERS = ("UserNotificationCenter", "universalAccessAuthWarn", "tccd")
KEYCHAIN_PROMPT_OWNERS = ("SecurityAgent",)
DENY_BUTTONS = ("Don’t Allow", "Don't Allow", "Deny")
FOREIGN_PROMPT_NAMES = ("Chromium", "Helper")
LOG_PROCESSES = ("tccd", "locationd", "nehelper")


@dataclass(frozen=True)
class Row:
    name: str
    key: str  # the key the bench presses in the host page (user activation for the request)
    kind: str  # "tcc": tccd AUTHREQ records of `service`; "daemon": identities `processes` log
    script: str  # JS expression of a promise; `LAN` is the LAN target URL
    service: str = ""
    processes: tuple = ()
    min_macos: int = 0


ROWS = (
    Row("camera", "c", "tcc", "navigator.mediaDevices.getUserMedia({video: true}).then(stopAll)", service="kTCCServiceCamera"),
    Row("microphone", "m", "tcc", "navigator.mediaDevices.getUserMedia({audio: true}).then(stopAll)",
        service="kTCCServiceMicrophone"),
    Row("location", "l", "daemon", "new Promise((ok, no) => navigator.geolocation.getCurrentPosition(() => ok('position'), "
        "e => no(new Error('geolocation ' + e.code)), {timeout: 15000}))", processes=("locationd",)),
    Row("local_network", "n", "daemon", "fetch(LAN, {cache: 'no-store'}).then(r => r.text())", processes=("nehelper",),
        min_macos=15),
    Row("screen", "s", "tcc", "navigator.mediaDevices.getDisplayMedia({video: true}).then(stopAll)",
        service="kTCCServiceScreenCapture"),
    Row("bluetooth", "b", "tcc", "navigator.bluetooth.requestDevice({acceptAllDevices: true}).then(d => 'device')",
        service="kTCCServiceBluetoothAlways"),
)


def page(rows=ROWS, lan_url=""):
    """The probe page: each row's key starts its request and the title carries every row's outcome."""
    table = ",\n".join(f"  {json.dumps(row.key)}: [{json.dumps(row.name)}, () => {row.script}]" for row in rows)
    return f"""<!doctype html><meta charset=utf-8><title>tcc probe</title>
<style>html,body{{margin:0;height:100%;background:#303030;color:#fff;font:16px system-ui}}</style>
<p>TCC attribution probe</p>
<script>
const LAN = {json.dumps(lan_url)};
const S = {{}};
const stopAll = stream => {{ stream.getTracks().forEach(t => t.stop()); return 'stream'; }};
const ROWS = {{
{table}
}};
function report() {{ document.title = {json.dumps(TITLE_PREFIX)} + JSON.stringify(S); }}
addEventListener('keydown', e => {{
  const row = ROWS[e.key];
  if (!row) return;
  S[row[0]] = {{state: 'pending'}}; report();
  Promise.resolve().then(row[1]).then(
    value => {{ S[row[0]] = {{state: 'resolved', value: String(value).slice(0, 80)}}; report(); }},
    error => {{ S[row[0]] = {{state: 'rejected', error: String((error && error.name) || error)}}; report(); }});
}}, true);
report();
</script>"""


def page_state(title):
    if not title or not title.startswith(TITLE_PREFIX):
        return None
    try:
        return json.loads(title[len(TITLE_PREFIX):])
    except ValueError:
        return None


@dataclass(frozen=True)
class Bundle:
    path: str
    identifier: str
    display_name: str
    executable: str

    @property
    def development(self):
        """CEFSwitches.current's rule: these bundles run Chromium with its mock keychain."""
        return ".debug" in self.identifier or self.identifier.endswith(".dev")

    @classmethod
    def read(cls, app):
        app = os.path.realpath(app).rstrip("/")
        with open(os.path.join(app, "Contents/Info.plist"), "rb") as plist:
            info = plistlib.load(plist)
        return cls(path=app, identifier=info.get("CFBundleIdentifier", ""),
                   display_name=info.get("CFBundleDisplayName") or info.get("CFBundleName") or "",
                   executable=os.path.join(app, "Contents/MacOS", info.get("CFBundleExecutable", "")))


# tccd ---------------------------------------------------------------------------------------------------------

MSG_ID = re.compile(r"\bmsgID=([^,\s]+)")
SERVICE = re.compile(r"\bservice=(kTCCService\w+)")
FUNCTION = re.compile(r"\bfunction=(\w+)")
SUBJECT = re.compile(r"\bsubject=([^,\s]+)")


def tccd_process(message, role):
    """`{TCCDProcess: identifier=..., pid=..., responsible_path=..., binary_path=...}` of `role`, as a dict."""
    start = message.find(role + "={TCCDProcess:")
    if start < 0:
        return None
    end = message.find("}", start)
    body = message[start + len(role) + len("={TCCDProcess:"):end if end >= 0 else None]
    fields = {}
    for part in body.split(","):
        key, sep, value = part.strip().partition("=")
        if sep:
            fields[key] = value.strip()
    return fields


def tccd_requests(messages):
    """tccd's AUTHREQ_* lines grouped by msgID: service, function, subject, responsible and accessing process."""
    requests = {}
    for message in messages:
        if "AUTHREQ_" not in message:
            continue
        found = MSG_ID.search(message)
        if not found:
            continue
        request = requests.setdefault(found.group(1), {"msg_id": found.group(1)})
        if "AUTHREQ_CTX" in message:
            for key, pattern in (("service", SERVICE), ("function", FUNCTION)):
                value = pattern.search(message)
                if value:
                    request[key] = value.group(1)
        elif "AUTHREQ_ATTRIBUTION" in message:
            for role in ("responsible", "accessing", "requesting"):
                process = tccd_process(message, role)
                if process is not None:
                    request[role] = process
        elif "AUTHREQ_SUBJECT" in message:
            value = SUBJECT.search(message)
            if value:
                request["subject"] = value.group(1)
        elif "AUTHREQ_RESULT" in message:
            value = re.search(r"\bauthValue=(\d+)", message)
            if value:
                request["auth_value"] = int(value.group(1))
    return list(requests.values())


def in_bundle(path, bundle):
    return bool(path) and os.path.normpath(path).startswith(bundle.path + "/")


def ours(request, bundle):
    """A request from a process of this bundle (the app, the host or a helper), by either end of the attribution."""
    paths = [(request.get(role) or {}).get(key) for role in ("accessing", "responsible") for key in ("binary_path", "responsible_path")]
    subject = request.get("subject") or ""
    return any(in_bundle(path, bundle) for path in paths) or subject == bundle.identifier \
        or subject.startswith(bundle.identifier + ".")


def requester(path, bundle):
    """Who in the bundle made a request: "app" (cmux's main executable), "host" (the Chromium host or a helper:
    another executable of the bundle) or "other" (outside the bundle, absent or redacted)."""
    if path and os.path.normpath(path) == bundle.executable:
        return "app"
    return "host" if in_bundle(path, bundle) else "other"


def judge_tcc(requests, service, bundle):
    """Passes when the host or a helper asked for `service` and tccd charged every request of the bundle (cmux's own
    preflights too) to cmux's bundle id and main executable."""
    mine = [r for r in requests if r.get("service") == service and ours(r, bundle)]
    rows = []
    for request in mine:
        responsible = request.get("responsible") or {}
        accessing = (request.get("accessing") or {}).get("binary_path")
        rows.append({
            "function": request.get("function"), "subject": request.get("subject"),
            "responsible": responsible.get("identifier"),
            "responsible_path": responsible.get("responsible_path") or responsible.get("binary_path"),
            "accessing": accessing, "by": requester(accessing, bundle), "auth_value": request.get("auth_value"),
        })
    redacted = any("<private>" in json.dumps(row) for row in rows)
    wrong = [row for row in rows if row["subject"] != bundle.identifier or row["responsible"] != bundle.identifier
             or os.path.normpath(row["responsible_path"] or "") != bundle.executable]
    from_host = [row for row in rows if row["by"] == "host"]
    verdict = {"requests": rows, "wrong": len(wrong), "host_requests": len(from_host),
               "app_requests": sum(1 for row in rows if row["by"] == "app")}
    if redacted:
        verdict["reason"] = "tccd's log redacts identities on this host (<private>)"
    elif not rows:
        verdict["reason"] = f"no {service} request from this bundle in tccd's log"
    elif wrong:
        verdict["reason"] = f"{len(wrong)} request(s) charged to another identity (first: {wrong[0]})"
    elif not from_host:
        verdict["reason"] = (f"no {service} request from the Chromium host or a helper in tccd's log (the "
                             f"{verdict['app_requests']} from cmux's own process do not measure the host)")
    verdict["pass"] = bool(from_host) and not wrong and not redacted
    return verdict


# locationd, nehelper ---------------------------------------------------------------------------------------------

def identities(message, bundle):
    """The bundle's identities a daemon line names: cmux's id, ids that extend it (helpers, a host bundle) and
    Chromium's own ids."""
    names = set(re.findall(re.escape(bundle.identifier) + r"(?:\.[\w\-]+)*(?![\w\-])", message))
    names.update(re.findall(r"org\.chromium[\w.\-]*", message))
    return names


def judge_daemon(lines, processes, bundle):
    seen = {}
    redacted = False
    for process, message in lines:
        if process not in processes:
            continue
        for name in identities(message, bundle):
            seen[name] = seen.get(name, 0) + 1
        redacted = redacted or "<private>" in message
    foreign = sorted(name for name in seen if name != bundle.identifier)
    verdict = {"identities": seen, "foreign": foreign}
    if foreign:
        verdict["reason"] = f"{'/'.join(processes)} names {', '.join(foreign)}"
    elif bundle.identifier not in seen:
        verdict["reason"] = (f"{'/'.join(processes)} never names {bundle.identifier}"
                             + (" (its log redacts identities: <private>)" if redacted else ""))
    verdict["pass"] = bundle.identifier in seen and not foreign
    return verdict


# prompts ---------------------------------------------------------------------------------------------------------

def judge_prompts(prompts, bundle):
    """Readable prompt text names cmux and no Chromium or helper process; unreadable text is not judged."""
    bad = []
    for prompt in prompts:
        text = " ".join(prompt.get("text") or [])
        if prompt.get("text") is None:
            continue
        if bundle.display_name not in text or any(name in text for name in FOREIGN_PROMPT_NAMES):
            bad.append(text[:200])
    return {"pass": not bad, "wrong_text": bad, "unreadable": sum(1 for p in prompts if p.get("text") is None)}


WINDOWS_JXA = """ObjC.import('CoreGraphics');
const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0))) || [];
JSON.stringify(list.map(w => ({owner: w.kCGWindowOwnerName, pid: w.kCGWindowOwnerPID, layer: w.kCGWindowLayer,
  alpha: w.kCGWindowAlpha, id: w.kCGWindowNumber})));"""

PROMPT_JXA = """function run(argv) {
  const owner = argv[0], deny = JSON.parse(argv[1]);
  const process = Application('System Events').processes.byName(owner);
  const out = {text: [], buttons: [], clicked: null};
  process.windows().forEach(w => {
    w.staticTexts().forEach(t => out.text.push(String(t.value())));
    w.buttons().forEach(b => {
      const name = String(b.name()); out.buttons.push(name);
      if (!out.clicked && deny.indexOf(name) >= 0) { b.click(); out.clicked = name; }
    });
  });
  return JSON.stringify(out);
}"""


def list_windows():
    """On-screen windows (CGWindowList: owner, pid, layer, alpha; no Screen Recording grant needed), or []."""
    try:
        done = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", WINDOWS_JXA], capture_output=True,
                              text=True, timeout=10)
        return json.loads(done.stdout) if done.returncode == 0 else []
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return []


def read_and_deny(owner):
    """The prompt's text and buttons through System Events (the Accessibility grant), answering "Don't Allow"."""
    try:
        done = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", PROMPT_JXA, owner, json.dumps(DENY_BUTTONS)],
                              capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"text": None, "error": str(error)[:200]}
    if done.returncode != 0:
        return {"text": None, "error": (done.stderr or "osascript failed").strip()[:200]}
    try:
        return json.loads(done.stdout)
    except ValueError:
        return {"text": None, "error": "unreadable System Events reply"}


def keychain_item(service):
    """Whether the login keychain has `service` (`security find-generic-password` without -w reads only the
    attributes: no secret, no prompt)."""
    try:
        return subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service], capture_output=True,
                              timeout=10).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return None


def delete_keychain_items(service, limit=20):
    """Deletes every login keychain item of `service` (one per `security delete-generic-password`); True when none
    is left."""
    for _ in range(limit):
        try:
            if subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", service], capture_output=True,
                              timeout=10).returncode != 0:
                break
        except (OSError, subprocess.TimeoutExpired):
            return False
    return keychain_item(service) is False


def keychain_plan(service, reset, keychain=keychain_item, delete=delete_keychain_items):
    """Before the launch: whether the bench turns Chromium's real keychain on (CMUX_NEXT_BENCH_REAL_KEYCHAIN=1) and
    may delete `service` before the host starts. An item that exists before the run is another app's unless `reset`
    allows deleting it; the launch then keeps the mock keychain, so no engine reads (or prompts for) that item, and
    the keychain row says why it is not measurable."""
    existed = keychain(service)
    if existed is None:
        return {"real_keychain": False, "may_delete": False, "existed": None,
                "reason": "`security` could not read the login keychain"}
    if existed and not reset:
        return {"real_keychain": False, "may_delete": False, "existed": True,
                "reason": f"\"{service}\" exists before the run (another app's?): pass --keychain-reset to delete it first"}
    if existed and not delete(service):
        return {"real_keychain": False, "may_delete": False, "existed": True,
                "reason": f"--keychain-reset could not delete \"{service}\""}
    return {"real_keychain": True, "may_delete": True, "existed": existed}


LIBSYSTEM = "/usr/lib/libSystem.B.dylib"


def responsible_pid(pid, library=LIBSYSTEM):
    """The pid macOS charges `pid`'s privacy requests to (libsystem's responsibility_get_pid_responsible_for_pid),
    or None when this system does not say."""
    try:
        function = ctypes.CDLL(library).responsibility_get_pid_responsible_for_pid
    except (OSError, AttributeError):
        return None
    function.argtypes = [ctypes.c_int]
    function.restype = ctypes.c_int
    found = function(int(pid))
    return found if found > 0 else None


def process_path(pid):
    """`pid`'s executable (ps), or None."""
    try:
        done = subprocess.run(["/bin/ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return done.stdout.strip() or None


class LogStream:
    """`log stream` of tccd, locationd and nehelper while the rows run; lines carry their arrival time."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.lines = []
        self.process = None
        self.error = None

    def start(self):
        predicate = " OR ".join(f'process == "{name}"' for name in LOG_PROCESSES)
        try:
            self.process = subprocess.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--level", "debug",
                                             "--predicate", predicate], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                            text=True)
        except OSError as error:
            self.error = str(error)
            return
        threading.Thread(target=self._read, name="tcc-log-stream", daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            try:
                event = json.loads(line)
            except ValueError:
                continue  # the "Filtering the log data" header
            process = os.path.basename(event.get("processImagePath") or "")
            self.lines.append((self.clock(), process, event.get("eventMessage") or ""))

    def between(self, start, end):
        return [(process, message) for at, process, message in list(self.lines) if start <= at <= end]

    def stop(self):
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(5)
            except subprocess.TimeoutExpired:
                self.process.kill()


class Pages:
    """The probe page on 127.0.0.1 (a secure context, so the APIs exist) and the Local Network target on this Mac's
    LAN address (it answers with CORS, so the page sees the fetch arrive)."""

    def __init__(self, rows=ROWS):
        self.rows = rows
        self.servers = []
        self.lan_hits = 0

    def start(self):
        lan = lan_address()
        lan_url = ""
        if lan:
            lan_server = self._serve(lan, lambda handler: self._lan(handler))
            lan_url = f"http://{lan}:{lan_server.server_address[1]}/lan"
        body = page(self.rows, lan_url).encode()
        local = self._serve("127.0.0.1", lambda handler: self._send(handler, body, "text/html; charset=utf-8"))
        return f"http://127.0.0.1:{local.server_address[1]}/tcc.html", lan

    def _lan(self, handler):
        self.lan_hits += 1
        self._send(handler, b"lan", "text/plain")

    @staticmethod
    def _send(handler, body, kind):
        handler.send_response(200)
        handler.send_header("Content-Type", kind)
        handler.send_header("Access-Control-Allow-Origin", "*")
        handler.send_header("Content-Length", str(len(body)))
        handler.end_headers()
        handler.wfile.write(body)

    def _serve(self, host, respond):
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                respond(self)

            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer((host, 0), Handler)
        threading.Thread(target=server.serve_forever, name="tcc-page", daemon=True).start()
        self.servers.append(server)
        return server

    def stop(self):
        for server in self.servers:
            server.shutdown()
            server.server_close()


def lan_address():
    """This Mac's address on its default route (a UDP connect sends nothing), or None when it has only loopback."""
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))
        address = probe.getsockname()[0]
    except OSError:
        return None
    finally:
        probe.close()
    return None if address.startswith("127.") or address == "0.0.0.0" else address


def macos_major():
    version = platform.mac_ver()[0]
    return int(version.split(".")[0]) if version else 0


@dataclass
class Seams:
    log: object = None
    windows: object = list_windows
    prompt: object = read_and_deny
    keychain: object = keychain_item
    delete_keychain: object = delete_keychain_items
    responsible: object = responsible_pid
    process_path: object = process_path
    clock: object = time.monotonic
    sleep: object = time.sleep
    os_major: int = field(default_factory=macos_major)


class TccRows:
    """Runs the rows against a host page that `open_host(url)` shows and `title()` reads; `press(key)` sends a key
    to it and `allow()` answers cmux's own site-permission prompt (062, 228). `app_pid` is cmux's process (it must be
    its own responsible process) and `keychain_plan` is ``keychain_plan``'s answer from before the launch. The host
    must not run yet: its first start reads the OSCrypt key."""

    def __init__(self, bundle, open_host, title, press, allow, seams=None, rows=ROWS, keychain_service=KEYCHAIN_SERVICE,
                 app_pid=None, keychain_plan=None):
        self.bundle = bundle
        self.open_host, self.title, self.press, self.allow = open_host, title, press, allow
        self.seams = seams or Seams()
        self.rows = rows
        self.keychain_service = keychain_service
        self.app_pid = app_pid
        self.keychain_plan = dict(keychain_plan or {"real_keychain": False, "may_delete": False,
                                                    "reason": "the launch kept Chromium's mock keychain"})
        self.prompts_seen = {}  # window id -> owner, every window that appeared while the mode ran
        self.preexisting = set()  # window ids on screen before the host opened (not this mode's prompts)

    def responsibility_error(self):
        """None when cmux is its own responsible process; otherwise why tccd would charge the rows to the bench."""
        s = self.seams
        if self.app_pid is None:
            return {"app_pid": None}, "the bench did not say which process is cmux"
        owner = s.responsible(self.app_pid)
        facts = {"app_pid": self.app_pid, "responsible_pid": owner,
                 "responsible_path": s.process_path(owner) if owner else None}
        if owner is None:
            return facts, f"this macOS does not say which process is responsible for cmux (pid {self.app_pid})"
        if owner != self.app_pid:
            return facts, (f"macOS charges cmux (pid {self.app_pid}) to pid {owner} ({facts['responsible_path']}): "
                           "the app was not launched as its own responsible process, so every row would measure the "
                           "bench's parent chain")
        return facts, None

    def run(self, url):
        s = self.seams
        result = {"os_major": s.os_major, "bundle_id": self.bundle.identifier, "display_name": self.bundle.display_name,
                  "rows": {}}
        result["responsibility"], problem = self.responsibility_error()
        if problem:
            result["error"] = f"mode error: {problem}"
            result["mode_error"] = True
            result["pass"] = False
            return result
        keychain_before = self._keychain_before()
        self.preexisting = {window.get("id") for window in s.windows()}
        started = s.clock()
        opened = self.open_host(url)
        if isinstance(opened, dict) and opened.get("error"):
            result["error"] = f"the host page did not open: {opened['error']}"
            result["pass"] = False
            return result
        if not self._wait(lambda: page_state(self.title()) is not None, 60):
            result["error"] = "the host page never showed the probe"
            result["pass"] = False
            return result
        for row in self.rows:
            result["rows"][row.name] = self._row(row)
        result["rows"]["keychain"] = self._keychain(keychain_before, started)
        verdicts = {name: row.get("pass") for name, row in result["rows"].items()}
        result["failing"] = sorted(name for name, ok in verdicts.items() if ok is False)
        result["not_measurable"] = sorted(name for name, ok in verdicts.items() if ok is None)
        result["pass"] = not result["failing"] and not result["not_measurable"]
        return result

    def _wait(self, check, seconds):
        deadline = self.seams.clock() + seconds
        while self.seams.clock() < deadline:
            if check():
                return True
            self.seams.sleep(0.25)  # test harness polling a live app
        return False

    def _row(self, row):
        s = self.seams
        if s.os_major and s.os_major < row.min_macos:
            return {"applies": False, "pass": True, "reason": f"macOS {s.os_major} has no {row.name} privacy (from {row.min_macos})"}
        start = s.clock()
        self.press(row.key)
        prompts, new_owners, last_allow = [], set(), None
        outcome = None
        while s.clock() < start + ROW_LIMIT_S:
            now = s.clock()
            if last_allow is None or now - last_allow >= ALLOW_EVERY_S:
                self.allow()
                last_allow = now
            prompts += self._prompts(TCC_PROMPT_OWNERS, new_owners)
            outcome = (page_state(self.title()) or {}).get(row.name)
            if outcome and outcome.get("state") != "pending":
                break
            s.sleep(0.25)  # test harness polling a live app
        s.sleep(LOG_GRACE_S)  # the daemons' last lines reach the stream
        prompts += self._prompts(TCC_PROMPT_OWNERS, new_owners)
        lines = s.log.between(start, s.clock()) if s.log else []
        if row.kind == "tcc":
            verdict = judge_tcc(tccd_requests(m for p, m in lines if p == "tccd"), row.service, self.bundle)
        else:
            verdict = judge_daemon(lines, row.processes, self.bundle)
        prompt_verdict = judge_prompts(prompts, self.bundle)
        verdict.update({"applies": True, "page": outcome or {"state": "no answer"}, "prompts": prompts,
                        "prompt_text": prompt_verdict, "new_windows": sorted(new_owners)})
        if not prompt_verdict["pass"]:
            verdict["reason"] = f"a prompt does not name {self.bundle.display_name}: {prompt_verdict['wrong_text'][0]}"
        verdict["pass"] = verdict["pass"] and prompt_verdict["pass"]
        return verdict

    def _prompts(self, owners, new_owners):
        """Prompt windows of `owners` not seen before, read and answered; every other new window owner is listed."""
        found = []
        for window in self.seams.windows():
            wid, owner = window.get("id"), window.get("owner") or ""
            if wid in self.prompts_seen or wid in self.preexisting or (window.get("layer") or 0) <= 0:
                continue
            self.prompts_seen[wid] = owner
            new_owners.add(owner)
            if owner in owners:
                found.append({"owner": owner, "pid": window.get("pid"), **self.seams.prompt(owner)})
        return found

    @property
    def real_keychain(self):
        """Whether Chromium reads the login keychain in this launch: a shipped bundle id always, a development one
        only with the bench's CMUX_NEXT_BENCH_REAL_KEYCHAIN=1 (``keychain_plan``)."""
        return not self.bundle.development or bool(self.keychain_plan.get("real_keychain"))

    def _keychain_before(self):
        """Whether the item exists as the host starts, after the delete the plan allows (this run's in-process engine
        may have made it)."""
        s = self.seams
        deleted = None
        if self.real_keychain and self.keychain_plan.get("may_delete"):
            deleted = s.delete_keychain(self.keychain_service)
        return {"deleted": deleted, "exists": s.keychain(self.keychain_service)}

    def _keychain(self, before, started):
        s = self.seams
        self._prompts((), set())
        keychain_prompts = sorted({owner for owner in self.prompts_seen.values() if owner in KEYCHAIN_PROMPT_OWNERS})
        row = {"service": self.keychain_service, "real_keychain": self.real_keychain, "deleted_before": before["deleted"],
               "item_before": before["exists"], "item_after": s.keychain(self.keychain_service),
               "prompt_owners": keychain_prompts, "seconds": round(s.clock() - started, 1)}
        if keychain_prompts:
            row["pass"] = False
            row["reason"] = "a keychain prompt (SecurityAgent) showed while the host ran"
        elif not self.real_keychain:
            row["pass"] = None
            row["reason"] = (f"Chromium ran with its mock keychain and never read \"{self.keychain_service}\": "
                             f"{self.keychain_plan.get('reason') or 'no real-keychain launch'}")
        elif row["item_before"] is not False:
            row["pass"] = None
            row["reason"] = (f"\"{self.keychain_service}\" existed when the host started: the bench cannot tell the "
                             "host read it" if row["item_before"] else "`security` could not read the login keychain")
        elif not row["item_after"]:
            row["pass"] = False
            row["reason"] = f"no \"{self.keychain_service}\" item after the host ran (OSCrypt never read its key)"
        else:
            row["pass"] = True
        if self.real_keychain and self.keychain_plan.get("may_delete"):
            row["deleted_after"] = s.delete_keychain(self.keychain_service)  # this run's item does not outlive it
        return row


def print_rows(result, out=print):
    for name, row in (result.get("rows") or {}).items():
        word = "N/A" if row.get("applies") is False else {True: "PASS", False: "FAIL", None: "NOT-MEASURABLE"}[row.get("pass")]
        out(f"TCC-ROW {name} {word}" + (f" ({row['reason']})" if row.get("reason") else ""))
    if result.get("error"):
        out(f"TCC-ROWS FAIL ({result['error']})")
