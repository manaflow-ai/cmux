#!/usr/bin/env python3
"""TCC attribution rows of chromium-host-bench.py (`--modes tcc`; plans/cmux-next/chrome-parity/p01-process.md, task 089).

A page in a cmux browser tab whose Chromium runs in the Chromium host (host mode, debug.cef `backend` "host": tasks
015 and 080) asks for each protected resource; every row passes when macOS charges the host's request to cmux itself,
not to the host executable, a Chromium helper or a bundle of their own. The page's site permission is answered the way
a person answers it, with cmux's prompt bar (browser.prompt.allow; every Chromium permission prompt reaches it from
the host, task 062). In any other mode (debug.cef `backend` "inProcess", or the old debug.chromium_host prototype,
which forwards no permission prompt) the requests would never reach macOS from the host: the mode stops with a mode
error and runs no row.

  camera, microphone, screen, bluetooth   tccd's AUTHREQ_SUBJECT and the responsible process of every request for the
                  service (kTCCServiceCamera, ...) from a process of this bundle are cmux's bundle id and cmux's main
                  executable, and at least one of them comes from the host or a helper (its accessing process is in
                  the bundle but is not cmux's main executable): cmux's own preflights (SystemPermissionProbe's
                  AVCaptureDevice.authorizationStatus) never stand for the host's request. Chrome's model: the
                  browser process is the responsible process of its helpers (base/process/launch_mac.cc keeps
                  responsibility; only `disclaim_responsibility` changes it), so its TCC grants are the app's.
  location        locationd names cmux's bundle id as the client and no other identity of the bundle (a helper or
                  host bundle id, an org.chromium id), and the host's request reached CoreLocation: the page got a
                  position, a POSITION_UNAVAILABLE or TIMEOUT error, or a PERMISSION_DENIED after the bench granted
                  the site permission (then it is macOS's answer, not Chromium's), or a locationd line names the
                  host's pid or executable.
  local_network   macOS 15 and later: a fetch to this Mac's LAN address; nehelper (Local Network privacy) names cmux's
                  bundle id and no other identity of the bundle, and the host's fetch reached nehelper: the LAN
                  server counted it, or a nehelper line names the host's pid or executable. macOS 14 has no Local
                  Network privacy: the row does not apply there.
  keychain        Chromium's OSCrypt key ("Chromium Safe Storage", components/os_crypt/sync/keychain_password_mac.mm),
                  in three steps, none of which may show a SecurityAgent prompt (cef-helper-app-DESIGN.md: the item's
                  ACL names the app that made it, and the host is another code identity):
                  cross_identity  the item cmux's in-process engine made in a launch of its own before this one
                                  (the bench's seed launch: the upgrade case) is read by the host: the probe's
                                  cookie that engine stored (encrypted with the item's key) is the host page's
                                  first cookie, and the item is the same one (its creation date).
                  create          after the bench deletes the item, a new host makes it.
                  read            the next host reads the item the create step's host made: that host's cookie,
                                  committed to disk encrypted, is the new host page's first cookie, and the item
                                  is the same one.
                  keychain_release_identity is the same question for the release-signed identity (task 088): not
                  measured until a bench build is signed with a Developer ID.

A row whose site permission (or device chooser, or screen share picker) was never answered and whose request never
reached macOS from the host is a mode error, not a PASS or a FAIL: nothing about attribution was observed.

The mode needs a bench-hooks build (reload.sh's bench config: a com.cmuxterm.app.debug.* id, so debug.key and
debug.cef exist). Such a development bundle runs Chromium with its mock keychain (CEFSwitches.useMockKeychain); the
bench launches it with CMUX_NEXT_BENCH_REAL_KEYCHAIN=1 (read by CEFSwitches.current in Debug and bench builds of a
development bundle only), so both engines use the login keychain as a shipped build does (``keychain_plan``).

tccd charges a request to the requester's responsible process, which a process inherits from the process that
exec'd it. The bench therefore launches cmux with responsibility disclaimed (bench_launch.BenchApp
own_responsibility), as a person's launch through LaunchServices makes cmux its own responsible process, and the mode
first reads the responsible process of cmux's pid (responsibility_get_pid_responsible_for_pid). When that is not
cmux, every row would measure the bench's own parent chain: the mode stops with a mode error and runs no row.

Every row also reads the system prompts that appear while it runs (CGWindowList owners, which need no grant). With
the Accessibility grant for the bench's process it reads their text (it must name cmux and not Chromium or a helper)
and answers "Don't Allow" (a keychain prompt: "Deny"), so a fleet host is never left with a prompt and the grant stays
off. Without it the text is reported as not readable and the prompt stays until the app quits.

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
# Chromium's cookie store writes to disk every 30 s (SQLitePersistentCookieStore's kCommitInterval,
# net/extras/sqlite/sqlite_persistent_cookie_store.cc): a cookie older than this is on disk, encrypted with the key.
COOKIE_COMMIT_S = 35.0
# How long a create step waits for the new host to make the item, and a step watches for a keychain prompt.
KEYCHAIN_WAIT_S = 30.0
KEYCHAIN_SETTLE_S = 5.0
HOST_PAGE_WAIT_S = 60.0
COOKIE = "tcc_probe"
TCC_PROMPT_OWNERS = ("UserNotificationCenter", "universalAccessAuthWarn", "tccd")
KEYCHAIN_PROMPT_OWNERS = ("SecurityAgent",)
DENY_BUTTONS = ("Don’t Allow", "Don't Allow", "Deny")
FOREIGN_PROMPT_NAMES = ("Chromium", "Helper")
LOG_PROCESSES = ("tccd", "locationd", "nehelper")
RELEASE_AUTHORITY = "Developer ID Application"

# How a row's site permission is answered (Row.site).
SITE_PROMPT = "prompt"  # cmux's prompt bar question (task 062), answered with browser.prompt.allow
SITE_PICKER = "picker"  # a prompt, then a screen share picker the bench does not answer (task 228)
SITE_CHOOSER = "chooser"  # Web Bluetooth's device chooser (task 228), which the bench does not answer
SITE_NONE = "none"  # the request needs no site permission
ALLOWED_SITES = (SITE_PROMPT, SITE_PICKER)


@dataclass(frozen=True)
class Row:
    name: str
    key: str  # the key the bench presses in the host page (user activation for the request)
    kind: str  # "tcc": tccd AUTHREQ records of `service`; "daemon": identities `processes` log
    script: str  # JS expression of a promise; `LAN` is the LAN target URL
    service: str = ""
    processes: tuple = ()
    min_macos: int = 0
    site: str = SITE_PROMPT


ROWS = (
    Row("camera", "c", "tcc", "navigator.mediaDevices.getUserMedia({video: true}).then(stopAll)", service="kTCCServiceCamera"),
    Row("microphone", "m", "tcc", "navigator.mediaDevices.getUserMedia({audio: true}).then(stopAll)",
        service="kTCCServiceMicrophone"),
    Row("location", "l", "daemon", "new Promise((ok, no) => navigator.geolocation.getCurrentPosition(() => ok('position'), "
        "e => no(new Error('geolocation ' + e.code)), {timeout: 15000}))", processes=("locationd",)),
    # A loopback page's fetch to a LAN address goes to a less private address space: Chromium's Local Network Access
    # asks only for the other direction, so the request goes straight to macOS.
    Row("local_network", "n", "daemon", "fetch(LAN, {cache: 'no-store'}).then(r => r.text())", processes=("nehelper",),
        min_macos=15, site=SITE_NONE),
    Row("screen", "s", "tcc", "navigator.mediaDevices.getDisplayMedia({video: true}).then(stopAll)",
        service="kTCCServiceScreenCapture", site=SITE_PICKER),
    Row("bluetooth", "b", "tcc", "navigator.bluetooth.requestDevice({acceptAllDevices: true}).then(d => 'device')",
        service="kTCCServiceBluetoothAlways", site=SITE_CHOOSER),
)

# GeolocationPositionError codes after Chromium's own permission check: POSITION_UNAVAILABLE and TIMEOUT (the
# timeout starts once the position is being acquired, after the permission).
LOCATION_PAST_CHROMIUM = ("geolocation 2", "geolocation 3")
LOCATION_DENIED = "geolocation 1"


def page(rows=ROWS, lan_url=""):
    """The probe page: each row's key starts its request, and the title carries every row's outcome and this load's
    `_load`: its time origin `t` (a new host's load has a new one), the probe cookie it found (`prior`) and the one it
    stored (`t`). The persistent cookie is encrypted with the OSCrypt key when Chromium writes it to disk, and the next
    host can show it to the page only after it read the key."""
    table = ",\n".join(f"  {json.dumps(row.key)}: [{json.dumps(row.name)}, () => {row.script}]" for row in rows)
    return f"""<!doctype html><meta charset=utf-8><title>tcc probe</title>
<style>html,body{{margin:0;height:100%;background:#303030;color:#fff;font:16px system-ui}}</style>
<p>TCC attribution probe</p>
<script>
const LAN = {json.dumps(lan_url)};
const COOKIE = {json.dumps(COOKIE + "=")};
const prior = (document.cookie.split('; ').find(c => c.startsWith(COOKIE)) || '').slice(COOKIE.length);
const loaded = String(performance.timeOrigin);
document.cookie = COOKIE + loaded + '; max-age=3600; path=/';
const S = {{_load: {{t: loaded, prior: prior}}}};
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
    error => {{ S[row[0]] = {{state: 'rejected', error: String((error && error.name) || error),
                              message: String((error && error.message) || '').slice(0, 80)}}; report(); }});
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


def names_process(message, pid, path):
    """Whether a daemon line names the process `pid` (as `pid 123`, `pid=123`, `pid: 123`) or its executable."""
    if pid and re.search(rf"\bpid\W{{0,2}}{int(pid)}\b", message):
        return True
    return bool(path) and path in message


def judge_daemon(lines, processes, bundle, host_evidence):
    """Passes when `processes` name cmux's bundle id and no other identity of the bundle, and `host_evidence` (why
    the host's request is known to have reached the daemon, or None) says the lines can be about the host's request.
    Without it the row is not measurable: a line that names cmux may be about cmux's own work."""
    seen = {}
    redacted = False
    for process, message in lines:
        if process not in processes:
            continue
        for name in identities(message, bundle):
            seen[name] = seen.get(name, 0) + 1
        redacted = redacted or "<private>" in message
    foreign = sorted(name for name in seen if name != bundle.identifier)
    verdict = {"identities": seen, "foreign": foreign, "host_evidence": host_evidence}
    if foreign:
        verdict["reason"] = f"{'/'.join(processes)} names {', '.join(foreign)}"
        verdict["pass"] = False
    elif not host_evidence:
        verdict["reason"] = f"no evidence that the host's request reached {'/'.join(processes)}"
        verdict["pass"] = None
    elif bundle.identifier not in seen:
        verdict["reason"] = (f"{'/'.join(processes)} never names {bundle.identifier}"
                             + (" (its log redacts identities: <private>)" if redacted else ""))
        verdict["pass"] = False
    else:
        verdict["pass"] = True
    return verdict


def location_evidence(outcome, site_answered):
    """Why the page's geolocation call is known to have reached CoreLocation, or None: a position, an error past
    Chromium's permission check, or a PERMISSION_DENIED after the bench granted the site permission (macOS's
    answer then)."""
    outcome = outcome or {}
    if outcome.get("state") == "resolved":
        return "the page got a position"
    message = outcome.get("message") or ""
    if message in LOCATION_PAST_CHROMIUM:
        return f"the page's request failed past Chromium's permission check ({message})"
    if message == LOCATION_DENIED and site_answered:
        return "macOS denied the page's request after the bench granted the site permission"
    return None


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


# keychain --------------------------------------------------------------------------------------------------------

CREATED = re.compile(r'"cdat"<timedate>=(?:0x[0-9A-Fa-f]+\s+)?"([^"\\]+)')


def keychain_info(service):
    """The login keychain's `service` item: {"exists", "created"} (`security find-generic-password` without -w reads
    only the attributes: no secret, no prompt; `created` is its cdat), or None when `security` could not answer."""
    try:
        done = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service], capture_output=True,
                              text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if done.returncode != 0:
        return {"exists": False, "created": None}
    found = CREATED.search(done.stdout + done.stderr)
    return {"exists": True, "created": found.group(1) if found else None}


def keychain_item(service, info=keychain_info):
    """Whether the login keychain has `service`, or None when `security` could not answer."""
    found = info(service)
    return None if found is None else found["exists"]


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
    """Before the launches: whether the bench turns Chromium's real keychain on (CMUX_NEXT_BENCH_REAL_KEYCHAIN=1) and
    may delete `service`. An item that exists before the run is another app's unless `reset` allows deleting it; the
    launches then keep the mock keychain, so no engine reads (or prompts for) that item, and the keychain row says why
    it is not measurable. With the plan's real keychain the item does not exist when the seed launch starts."""
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


def code_authority(path):
    """The first signing authority of `path` (`codesign -dvv`: "Developer ID Application: ...", "Apple Development:
    ..."), "adhoc" for an ad hoc signature, or None when it is not signed or codesign could not say."""
    if not path:
        return None
    try:
        done = subprocess.run(["/usr/bin/codesign", "-dvv", path], capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return None
    text = done.stdout + done.stderr
    found = re.search(r"^Authority=(.+)$", text, re.MULTILINE)
    if found:
        return found.group(1).strip()
    return "adhoc" if re.search(r"^Signature=adhoc$", text, re.MULTILINE) else None


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
    keychain: object = keychain_info
    delete_keychain: object = delete_keychain_items
    responsible: object = responsible_pid
    process_path: object = process_path
    authority: object = code_authority
    host_pid: object = lambda: None  # the running Chromium host's pid, or None
    lan_hits: object = lambda: 0  # requests the LAN target answered so far
    clock: object = time.monotonic
    sleep: object = time.sleep
    os_major: int = field(default_factory=macos_major)


def combined(verdicts):
    """One verdict of several: False when one fails, None when one is not measured, else True."""
    verdicts = list(verdicts)
    return False if False in verdicts else (None if None in verdicts else True)


class TccRows:
    """Runs the rows against a host page in a cmux browser tab that `open_host(url)` opens and `title()` reads;
    `press(key)` sends a key to it, `allow()` answers cmux's prompt bar question for it (browser.prompt.allow) and
    says whether there was one, `restart_host()` ends the Chromium host and has the tab reload on a new one
    ({"old_pid", "new_pid", "error"}), and `backend()` is debug.cef's `backend`. `app_pid` is cmux's process (it must
    be its own responsible process), `keychain_plan` is ``keychain_plan``'s answer from before the launches, and
    `seed` is the seed launch's item and cookie ({"created", "cookie"} or {"error"})."""

    def __init__(self, bundle, open_host, title, press, allow, restart_host=None, backend=lambda: "host", seams=None,
                 rows=ROWS, keychain_service=KEYCHAIN_SERVICE, app_pid=None, keychain_plan=None, seed=None):
        self.bundle = bundle
        self.open_host, self.title, self.press, self.allow = open_host, title, press, allow
        self.restart_host = restart_host or (lambda: {"error": "the bench cannot restart the Chromium host"})
        self.backend = backend
        self.seams = seams or Seams()
        self.rows = rows
        self.keychain_service = keychain_service
        self.app_pid = app_pid
        self.keychain_plan = dict(keychain_plan or {"real_keychain": False, "may_delete": False,
                                                    "reason": "the launch kept Chromium's mock keychain"})
        self.seed = seed
        self.prompts_seen = {}  # window id -> owner, every window that appeared while the mode ran
        self.preexisting = set()  # window ids on screen before the host page opened (not this mode's prompts)
        self.preexisting_keychain_prompts = []
        self.keychain_prompts = []  # every keychain prompt this mode saw, read and denied, in order
        self.first_load = None  # the host page's first `_load`

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

    @staticmethod
    def _mode_error(result, problem):
        result.update(error=f"mode error: {problem}", mode_error=True, mode_errors=["mode"], **{"pass": False})
        return result

    def run(self, url):
        s = self.seams
        result = {"os_major": s.os_major, "bundle_id": self.bundle.identifier, "display_name": self.bundle.display_name,
                  "rows": {}}
        result["responsibility"], problem = self.responsibility_error()
        if problem:
            return self._mode_error(result, problem)
        result["backend"] = self.backend()
        if result["backend"] != "host":
            return self._mode_error(result, (
                f"cmux's browser tabs do not run in the Chromium host (debug.cef backend {result['backend']!r}; host "
                "mode is tasks 015 and 080): no request would come from the host, and only a host-backed tab gets its "
                "permission prompts answered (task 062)"))
        windows = s.windows()
        self.preexisting = {window.get("id") for window in windows}
        self.preexisting_keychain_prompts = sorted(
            {w.get("owner") for w in windows if w.get("owner") in KEYCHAIN_PROMPT_OWNERS and (w.get("layer") or 0) > 0})
        opened = self.open_host(url)
        if isinstance(opened, dict) and opened.get("error"):
            result.update(error=f"the host page did not open: {opened['error']}", **{"pass": False})
            return result
        if not self._wait(lambda: self._load() is not None, HOST_PAGE_WAIT_S):
            result.update(error="the host page never showed the probe", **{"pass": False})
            return result
        self.first_load = self._load()
        for row in self.rows:
            result["rows"][row.name] = self._row(row)
        result["rows"]["keychain"] = self._keychain()
        result["rows"]["keychain_release_identity"] = self._release_identity(result["rows"]["keychain"])
        rows = result["rows"]
        result["mode_errors"] = sorted(name for name, row in rows.items() if row.get("mode_error"))
        result["failing"] = sorted(name for name, row in rows.items() if row.get("pass") is False)
        result["not_measurable"] = sorted(name for name, row in rows.items()
                                          if row.get("pass") is None and not row.get("mode_error"))
        result["pass"] = not result["failing"] and not result["not_measurable"] and not result["mode_errors"]
        return result

    def _wait(self, check, seconds):
        deadline = self.seams.clock() + seconds
        while self.seams.clock() < deadline:
            if check():
                return True
            self.seams.sleep(0.25)  # test harness polling a live app
        return False

    def _state(self):
        return page_state(self.title()) or {}

    def _load(self):
        return self._state().get("_load")

    # rows --------------------------------------------------------------------------------------------------------

    def _row(self, row):
        s = self.seams
        if s.os_major and s.os_major < row.min_macos:
            return {"applies": False, "pass": True, "reason": f"macOS {s.os_major} has no {row.name} privacy (from {row.min_macos})"}
        start = s.clock()
        lan_before = s.lan_hits()
        host_pid = s.host_pid()
        host_path = s.process_path(host_pid) if host_pid else None
        self.press(row.key)
        prompts, new_owners, last_allow, answered = [], set(), None, 0
        outcome = None
        while s.clock() < start + ROW_LIMIT_S:
            now = s.clock()
            if row.site in ALLOWED_SITES and (last_allow is None or now - last_allow >= ALLOW_EVERY_S):
                answered += 1 if self.allow() else 0
                last_allow = now
            prompts += self._prompts(TCC_PROMPT_OWNERS, new_owners)
            outcome = self._state().get(row.name)
            if outcome and outcome.get("state") != "pending":
                break
            s.sleep(0.25)  # test harness polling a live app
        s.sleep(LOG_GRACE_S)  # the daemons' last lines reach the stream
        prompts += self._prompts(TCC_PROMPT_OWNERS, new_owners)
        outcome = outcome or {"state": "no answer"}
        lines = s.log.between(start, s.clock()) if s.log else []
        site = self._site(row, outcome, answered)
        if row.kind == "tcc":
            verdict = judge_tcc(tccd_requests(m for p, m in lines if p == "tccd"), row.service, self.bundle)
            reached = verdict["host_requests"] > 0
        else:
            evidence = self._daemon_evidence(row, lines, outcome, answered, s.lan_hits() - lan_before, host_pid, host_path)
            verdict = judge_daemon(lines, row.processes, self.bundle, evidence)
            reached = evidence is not None
        if not reached and not site["answered"]:
            verdict.update(mode_error=True, reason=f"mode error: {site['missing']}, so the host's request never reached "
                                                   "macOS (nothing about attribution was observed)")
            verdict["pass"] = None
        prompt_verdict = judge_prompts(prompts, self.bundle)
        verdict.update({"applies": True, "page": outcome, "site": site, "host_pid": host_pid, "prompts": prompts,
                        "prompt_text": prompt_verdict, "new_windows": sorted(new_owners)})
        if not prompt_verdict["pass"]:
            # A prompt showed, so the request reached macOS: a FAIL, never a mode error.
            verdict.pop("mode_error", None)
            verdict["reason"] = f"a prompt does not name {self.bundle.display_name}: {prompt_verdict['wrong_text'][0]}"
            verdict["pass"] = False
        return verdict

    @staticmethod
    def _site(row, outcome, answered):
        """Whether the row's site permission (or chooser, or picker) was answered, and what was missing if not."""
        resolved = outcome.get("state") == "resolved"
        site = {"kind": row.site, "prompts_allowed": answered}
        if row.site == SITE_NONE:
            site["answered"] = True
        elif row.site == SITE_PROMPT:
            site["answered"] = answered > 0 or resolved
            site["missing"] = (f"cmux's prompt bar never asked for the {row.name} site permission (browser.prompt.allow "
                               "found no question: task 062's prompt is not in this build?)")
        elif row.site == SITE_PICKER:
            site["answered"] = resolved
            site["missing"] = ("the screen share picker was not answered (the bench has no answer for task 228's picker"
                               + ("" if answered else ", and cmux's prompt bar never asked") + ")")
        else:
            site["answered"] = resolved
            site["missing"] = "Chromium's device chooser was not answered (the bench has no answer for task 228's chooser)"
        return site

    @staticmethod
    def _daemon_evidence(row, lines, outcome, answered, lan_delta, host_pid, host_path):
        """Why the host's request is known to have reached the row's daemon, or None."""
        named = [message for process, message in lines if process in row.processes
                 and names_process(message, host_pid, host_path)]
        if named:
            return f"{row.processes[0]} names the host (pid {host_pid}): {named[0][:120]}"
        if row.name == "local_network":
            return f"the LAN target answered {lan_delta} request(s) from the page" if lan_delta > 0 else None
        if row.name == "location":
            return location_evidence(outcome, answered > 0)
        return None

    def _prompts(self, owners, new_owners):
        """Prompt windows of `owners` not seen before, read and answered; a keychain prompt is read, denied and kept in
        ``keychain_prompts``; every other new window owner is listed."""
        found = []
        for window in self.seams.windows():
            wid, owner = window.get("id"), window.get("owner") or ""
            if wid in self.prompts_seen or wid in self.preexisting or (window.get("layer") or 0) <= 0:
                continue
            self.prompts_seen[wid] = owner
            new_owners.add(owner)
            if owner in KEYCHAIN_PROMPT_OWNERS:
                self.keychain_prompts.append({"owner": owner, "pid": window.get("pid"), **self.seams.prompt(owner)})
            elif owner in owners:
                found.append({"owner": owner, "pid": window.get("pid"), **self.seams.prompt(owner)})
        return found

    # keychain ----------------------------------------------------------------------------------------------------

    @property
    def real_keychain(self):
        """Whether Chromium reads the login keychain in this launch: a shipped bundle id always, a development one
        only with the bench's CMUX_NEXT_BENCH_REAL_KEYCHAIN=1 (``keychain_plan``)."""
        return not self.bundle.development or bool(self.keychain_plan.get("real_keychain"))

    def _keychain(self):
        row = {"service": self.keychain_service, "real_keychain": self.real_keychain}
        if not self.real_keychain:
            row.update(reason=(f"Chromium ran with its mock keychain and never read \"{self.keychain_service}\": "
                               f"{self.keychain_plan.get('reason') or 'no real-keychain launch'}"), **{"pass": None})
            return row
        # The cross-identity read is the host's first start of this launch: before create deletes the item.
        steps = {"cross_identity": self._cross_identity()}
        steps["create"] = self._create()
        steps["read"] = self._read(steps["create"])
        row["steps"] = steps
        if self.keychain_plan.get("may_delete"):
            row["deleted_after"] = self.seams.delete_keychain(self.keychain_service)  # this run's item does not outlive it
        row["pass"] = combined(step["pass"] for step in steps.values())
        if row["pass"] is None and any(step.get("mode_error") for step in steps.values()):
            row["mode_error"] = True
        unsettled = [(name, step) for name, step in steps.items() if step["pass"] is not True]
        if unsettled:
            failing = [(name, step) for name, step in unsettled if step["pass"] is False] or unsettled
            row["reason"] = "; ".join(f"{name}: {step.get('reason')}" for name, step in failing)
        return row

    def _keychain_prompts_since(self, count):
        """Keychain prompts that showed since ``keychain_prompts`` had `count` entries (after a fresh look)."""
        self._prompts((), set())
        return self.keychain_prompts[count:]

    def _new_host(self):
        """Ends the host and waits for the tab's page on the next one: (that load, the restart) or (None, the
        restart with its error)."""
        before = self._load()
        restarted = dict(self.restart_host() or {})
        if restarted.get("error"):
            return None, restarted
        if not self._wait(lambda: self._load() not in (None, before), HOST_PAGE_WAIT_S):
            restarted["error"] = "the probe never showed on the new host"
            return None, restarted
        return self._load(), restarted

    def _cross_identity(self):
        """The item cmux's in-process engine made (the seed launch) is read by this launch's host, with no prompt."""
        s = self.seams
        seed = self.seed or {"error": "the bench made no seed launch"}
        step = {"seed": seed, "first_load": self.first_load}
        if seed.get("error") or not seed.get("created"):
            step.update(reason=f"no item made by cmux's in-process engine: {seed.get('error') or 'no creation date'}",
                        **{"pass": None})
            return step
        info = s.keychain(self.keychain_service) or {}
        step["created_after"] = info.get("created")
        prompts = self._keychain_prompts_since(0)
        step["prompts"] = prompts
        step["preexisting_prompts"] = self.preexisting_keychain_prompts
        prior = (self.first_load or {}).get("prior")
        step["prior_cookie"] = prior
        if prompts:
            step.update(reason="a keychain prompt (SecurityAgent) showed when the host read the item cmux's in-process "
                               "engine made", **{"pass": False})
        elif self.preexisting_keychain_prompts:
            # On screen before the mode looked: the host's first read (a warm start) or another app's.
            step.update(reason="a keychain prompt (SecurityAgent) was on screen before the mode started, so the bench "
                               "cannot tell whose it is", **{"pass": None})
        elif not info.get("exists") or info.get("created") != seed["created"]:
            step.update(reason="the host replaced the item cmux's in-process engine made (it could not read it)",
                        **{"pass": False})
        elif prior != seed.get("cookie"):
            step.update(reason=("the host page's first cookie is not the one cmux's in-process engine stored, so the "
                                f"host's read of the item is not proven (found {prior!r})"), **{"pass": None})
        else:
            step["pass"] = True
        return step

    def _create(self):
        """After the bench deletes the item, a new host makes it, with no prompt."""
        s = self.seams
        step = {}
        if not self.keychain_plan.get("may_delete"):
            step.update(reason="the bench may not delete the item, so it cannot see a host make it", **{"pass": None})
            return step
        step["deleted_before"] = s.delete_keychain(self.keychain_service)
        if not step["deleted_before"]:
            step.update(reason=f"the bench could not delete \"{self.keychain_service}\"", **{"pass": None})
            return step
        count = len(self.keychain_prompts)
        load, step["host"] = self._new_host()
        if load is None:
            step.update(reason=f"mode error: {step['host']['error']}", mode_error=True, **{"pass": None})
            return step
        step["load"], step["loaded_at"] = load, s.clock()
        made = self._wait(lambda: (s.keychain(self.keychain_service) or {}).get("exists"), KEYCHAIN_WAIT_S)
        info = s.keychain(self.keychain_service) or {}
        step["created"] = info.get("created")
        step["prompts"] = self._keychain_prompts_since(count)
        if step["prompts"]:
            step.update(reason="a keychain prompt (SecurityAgent) showed while the host made the item", **{"pass": False})
        elif not made:
            step.update(reason=f"no \"{self.keychain_service}\" item {KEYCHAIN_WAIT_S:g} s after the host started "
                               "(OSCrypt never read its key)", **{"pass": False})
        else:
            step["pass"] = True
        return step

    def _read(self, create):
        """The next host reads the item the create step's host made, with no prompt: the cookie that host stored is
        the new page's first cookie, and the item is the same one."""
        s = self.seams
        step = {}
        if create.get("pass") is not True:
            step.update(reason="the create step did not pass: no item of this run's host to read", **{"pass": None})
            return step
        # The create page's cookie is on disk, encrypted with the item's key, once the cookie store committed it.
        s.sleep(max(0.0, create["loaded_at"] + COOKIE_COMMIT_S - s.clock()))  # Chromium's cookie commit interval
        count = len(self.keychain_prompts)
        load, step["host"] = self._new_host()
        if load is None:
            step.update(reason=f"mode error: {step['host']['error']}", mode_error=True, **{"pass": None})
            return step
        s.sleep(KEYCHAIN_SETTLE_S)  # a prompt of the new host's key read has shown by then
        info = s.keychain(self.keychain_service) or {}
        step.update(load=load, created=info.get("created"), prompts=self._keychain_prompts_since(count))
        if step["prompts"]:
            step.update(reason="a keychain prompt (SecurityAgent) showed when the next host read the item",
                        **{"pass": False})
        elif not info.get("exists") or info.get("created") != create["created"]:
            step.update(reason="the next host replaced the item (it could not read it)", **{"pass": False})
        elif load.get("prior") != create["load"].get("t"):
            step.update(reason=("the new host page's first cookie is not the one the create step's host stored "
                                f"({load.get('prior')!r}), so the host's read of the item is not proven"),
                        **{"pass": None})
        else:
            step["pass"] = True
        return step

    def _release_identity(self, keychain):
        """The keychain row for the release-signed identity (task 088): measured only when cmux and its host are
        signed with a Developer ID; then it is the keychain row's verdict."""
        s = self.seams
        host_pid = s.host_pid()
        host_path = s.process_path(host_pid) if host_pid else None
        signed = {"app": s.authority(self.bundle.executable), "host": s.authority(host_path), "host_path": host_path}
        row = {"authorities": signed}
        unsigned = [who for who in ("app", "host") if not (signed[who] or "").startswith(RELEASE_AUTHORITY)]
        if unsigned:
            row.update(reason=(f"not measured: {' and '.join(unsigned)} not signed with a {RELEASE_AUTHORITY} identity "
                               f"({', '.join(f'{w}: {signed[w]}' for w in unsigned)}); task 088's release signing is "
                               "not on this build"), **{"pass": None})
        else:
            row.update(reason=keychain.get("reason"), **{"pass": keychain.get("pass")})
        return row


def print_rows(result, out=print):
    for name, row in (result.get("rows") or {}).items():
        if row.get("applies") is False:
            word = "N/A"
        elif row.get("mode_error"):
            word = "MODE-ERROR"
        else:
            word = {True: "PASS", False: "FAIL", None: "NOT-MEASURABLE"}[row.get("pass")]
        out(f"TCC-ROW {name} {word}" + (f" ({row['reason']})" if row.get("reason") else ""))
        for step, verdict in (row.get("steps") or {}).items():
            word = "MODE-ERROR" if verdict.get("mode_error") else {True: "PASS", False: "FAIL", None: "NOT-MEASURABLE"}[verdict.get("pass")]
            out(f"TCC-ROW {name}.{step} {word}" + (f" ({verdict['reason']})" if verdict.get("reason") else ""))
    if result.get("error"):
        out(f"TCC-ROWS FAIL ({result['error']})")
