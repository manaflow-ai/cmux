#!/usr/bin/env python3
"""cmux-next-ios-sim.sh pair-e2e: the iPhone pairs with a Mac by the Mac's QR code, end to end.

  cmux_next_pair_e2e.py --mac-app APP --ios-app APP --sims SET --udid UDID --bundle-id ID \
      --work DIR --out DIR --summary FILE

The tagged DEBUG cmux NEXT app runs as the e2e rig's Mac does (cmux-next-ios/verify/e2e/mac.py):
its own settings file with iPhone connections on, the DEBUG dev account of CmuxAuthRuntime (a
0600 file, never printed), its own machine id, and NO pairing seed, so only the pairing code's
single-use token can approve the phone. The page's link (`cmux.mobilePairing.status` `qr.url`)
is opened on the simulator iPhone, signed in to the same account, as the Camera opens a scanned
code; the step passes when the Mac logs `phone <id8> paired from this Mac's pairing code`.

Screens: the Mac's Mobile Pairing page on a ref that shows no code (a code's image carries its
token, so on a ref with codes the page is never saved), the phone's Settings > Devices before and after, and its scanner sheet with
the camera off (needs `axe`). On a ref without the feature the Mac shows no code: the pairing is
skipped, the run passes, and the Devices screen is the "before"; on a ref with it, no code fails.
The token is never printed: `t=` is redacted in every log line and file. Ends the Mac app it started (its own PID) and the
tag's daemons (tag_teardown.py), and removes the app's state and its Keychain items.

Why the dev Cloud and not loopback: the gate the code must not weaken is the account check, and
that check lives on the Cloud path (the Worker stamps the verified sender's `fromUserId` on every
signal, and hostd refuses a dial whose `fromUserId` is not the Mac's owner); a loopback seam would
have to fake that stamp, so it would test around the very check this proves. The account is the
in-source DEBUG dev credential of the dev Stack project (the one verify/e2e/mac.py uses), not a
production or personal account and not a secret.
"""
import argparse, glob, hashlib, json, os, plistlib, pwd, re, shutil, socket, subprocess, sys, threading, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.."))
sys.path.insert(0, os.path.join(ROOT, "scripts/cmux-next"))
from tag_teardown import TagTeardown  # noqa: E402

PAGE = "cmux.mobile-pairing"
PAIRED = re.compile(r"phone (\w+) paired from this Mac's pairing code")


def redact(text):
    """A pairing code's token (a link's `t=`, a `pairToken`) never reaches a log or the artifact."""
    return re.sub(r'((?<!\w)t=|pair_?token"?\s*[:=]\s*"?)[A-Za-z0-9_-]+', r"\1<redacted>", text, flags=re.I)


def shows_a_code():
    """Whether this ref's Mobile Pairing page sends a pairing code (`qr`): on a ref without it no
    code is the expected "before"; on one with it, no code is a failure."""
    src = os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Pages/MobilePairing/MobilePairingPageProvider.swift")
    return os.path.exists(src) and 'reply["qr"]' in open(src).read()


def dev_credential():
    """(email, password) of the DEBUG dev account (AuthCoordinator's "42" shortcut), as mac.py reads it."""
    src = os.path.join(ROOT, "Packages/Shared/CmuxAuthRuntime/Sources/CmuxAuthRuntime/Coordinator/AuthCoordinator.swift")
    m = re.search(r'CMUXAuthAutoLoginCredentials\(email:\s*"([^"]+)",\s*password:\s*"([^"]+)"\)', open(src).read())
    if not m:
        raise SystemExit("DEBUG dev credential not found in CmuxAuthRuntime")
    return m.group(1), m.group(2)


def machine_id(bundle_id):
    """This app's own machine id (mac.py rig_machine_id): the phone lists it apart from other builds here."""
    out = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True).stdout
    uuid = re.search(r'"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]+)"', out).group(1).upper()
    return hashlib.sha256(f"cmux-rig-machine-id v1\0{uuid}\0{bundle_id}".encode()).hexdigest()[:32]


class Stream:
    """A child of this script (a `log stream`, or the Mac app itself): its output lines (token redacted
    as they are written, so an interrupted run leaves none on disk) go to `path`; wait() is woken per line."""

    def __init__(self, argv, path, env=None):
        self.lines, self.cond = [], threading.Condition()
        self.file = open(path, "w")
        self.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                     text=True, errors="replace", env=env)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            line = redact(line)
            self.file.write(line)
            self.file.flush()
            with self.cond:
                self.lines.append(line)
                self.cond.notify_all()

    def wait(self, pattern, timeout):
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                for line in self.lines:
                    if m := pattern.search(line):
                        return m
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                self.cond.wait(left)

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(5)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def wait_for(fn, seconds, every=1.0):
    """Bounded wait on the app's own state (no event reaches this script for it)."""
    deadline = time.monotonic() + seconds
    while True:
        value = fn()
        if value or time.monotonic() > deadline:
            return value
        time.sleep(every)


def main():
    ap = argparse.ArgumentParser()
    for flag in ("--mac-app", "--ios-app", "--sims", "--udid", "--bundle-id", "--work", "--out", "--summary"):
        ap.add_argument(flag, required=True)
    a = ap.parse_args()
    screens = os.path.join(a.out, "screens")
    os.makedirs(screens, exist_ok=True)

    def note(line):
        print(line, flush=True)
        with open(a.summary, "a") as f:
            f.write(line + "\n")

    # Read before anything is written, so nothing it decides leaves state behind.
    expects_code = shows_a_code()
    note(f"- this ref's pairing page {'shows' if expects_code else 'shows no'} pairing codes")

    # ---- the Mac app ------------------------------------------------------
    mac_bundle, tag, ls_env = step_tag(a.mac_app)
    no_data_protection_keychain(a.mac_app)
    sock = ls_env.get("CMUX_SOCKET_PATH") or f"/tmp/cmux-debug-{tag}.sock"
    support = os.path.expanduser(f"~/Library/Application Support/{mac_bundle}")
    rig = os.path.join(a.work, "pair-rig")  # written only once cleanup is armed (below)
    config = os.path.join(rig, "cmux-next.json")
    email, password = dev_credential()
    creds = os.path.join(rig, "dev-auth.env")  # written once cleanup is armed (below)
    # Launched by its binary (its PID is this script's child), with the environment `open`
    # would give it (LSEnvironment) plus the rig's settings. An empty seed trusts no phone.
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
    env.update(ls_env)
    env.update(CMUX_NEXT_CONFIG_FILE=config, CMUX_AUTH_CREDENTIALS_FILE=creds, CMUX_NEXT_IPHONE_PAIRING_SEED="",
               CMUX_NEXT_MOBILE_MACHINE_ID=machine_id(mac_bundle), CMUX_NEXT_NO_ACTIVATE="1",
               CMUX_NEXT_SOCKET_MODE="automation")

    def rpc(method, params=None, timeout=30):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(timeout)
                conn.connect(sock)
                conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
                buf = b""
                while not buf.endswith(b"\n"):
                    chunk = conn.recv(1 << 20)
                    if not chunk:
                        break
                    buf += chunk
            reply = json.loads(buf)
            if not reply.get("ok"):
                return {"error": reply.get("error")}
            return reply["result"] if isinstance(reply.get("result"), dict) else {"result": reply.get("result")}
        except (OSError, ValueError) as error:
            return {"error": str(error)}

    last = {}

    def status():
        """The Mobile Pairing page's status (opening the page while it has none)."""
        r = rpc("debug.page", {"page": PAGE, "action": "call", "op": "cmux.mobilePairing.status"})
        if "no live page" in str(r.get("error", "")):
            rpc("action.run", {"action": "palette.mobileConnect", "focus": True})
            return {}
        value = r.get("value") if isinstance(r.get("value"), dict) else {}
        if value and value.get("state") != last.get("state"):
            print(f"Mac pairing page: {value.get('state')} {value.get('failure') or ''}", flush=True)
        if value:
            last.clear()
            last.update(value)
        return value

    def mac_shot(name):
        """The Mac page as rendered, only on a ref that never shows a code: a code's image carries a
        live token (text redaction can't reach it, and a code may render between a status read and
        a snapshot), so there the page's QR elements are only counted, never saved."""
        if expects_code:
            shown = rpc("debug.page", {"page": PAGE, "action": "query", "selector": "img.pairing-qr"})
            count = len(shown.get("elements") or []) if isinstance(shown, dict) else 0
            return f"no snapshot on a ref that shows a code ({count or 'no'} QR element on the page)"
        r = rpc("debug.page", {"page": PAGE, "action": "snapshot", "path": os.path.join(screens, f"{name}.png")})
        return f"screens/{name}.png" if r.get("path") else f"no snapshot ({r.get('error')})"

    simctl = ["xcrun", "simctl", "--set", a.sims]
    phone_env = dict(os.environ, SIMCTL_CHILD_CMUX_MOBILE_STACK_EMAIL=email, SIMCTL_CHILD_CMUX_MOBILE_STACK_PASSWORD=password)

    def phone_launch():
        """cmux on iPhone on Settings > Devices, signed in to the dev account (DEBUG launch environment)."""
        subprocess.run(simctl + ["terminate", a.udid, a.bundle_id], capture_output=True)
        subprocess.run(simctl + ["launch", a.udid, a.bundle_id, "-cmux-mobile-settings-page", "devices"],
                       env=phone_env, check=True, capture_output=True)

    def phone_shot(name):
        subprocess.run(simctl + ["io", a.udid, "screenshot", os.path.join(screens, f"{name}.png")], capture_output=True)
        return f"screens/{name}.png"

    teardown = TagTeardown(a.mac_app)
    teardown.install()
    streams, app, paired, url = [], None, None, None
    try:
        os.makedirs(rig, mode=0o700, exist_ok=True)
        with open(config, "w") as f:
            json.dump({"mobile": {"allowIPhoneConnections": True}}, f)
        with os.fdopen(os.open(creds, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            f.write(f"CMUX_UITEST_STACK_EMAIL={email}\nCMUX_UITEST_STACK_PASSWORD={password}\n")
        if os.path.exists(sock):
            os.unlink(sock)  # this run's own tag
        plist = plistlib.load(open(os.path.join(a.mac_app, "Contents/Info.plist"), "rb"))
        exe = os.path.join(a.mac_app, "Contents/MacOS", plist["CFBundleExecutable"])
        app_out = Stream([exe], os.path.join(a.out, "mac-app.log"), env=env)
        app = app_out.proc
        streams.append(app_out)
        t0 = time.monotonic()
        if not wait_for(lambda: app.poll() is None and "error" not in rpc("debug.focus", timeout=5), 180):
            raise SystemExit("the Mac app never answered on its control socket")
        teardown.remember()
        note(f"- Mac app {mac_bundle}: pid {app.pid}, control socket in {time.monotonic() - t0:.0f} s")
        pairing_logs = f'processID == {app.pid} AND subsystem == "com.cmuxterm.app.next" AND category BEGINSWITH "app.iphone"'
        streams.append(mac_log := Stream(["/usr/bin/log", "stream", "--level", "info", "--style", "compact",
                                          "--predicate", pairing_logs], os.path.join(a.out, "mac-pairing.log")))
        # Signed in, hostd online, iPhone connections on: the page shows the code.
        qr = (wait_for(lambda: status().get("qr"), 300 if expects_code else 60, every=2) or {})
        url = qr.get("url")
        note(f"- Mac pairing page: state {last.get('state')}, Mac {last.get('macName')!r}, "
             f"{'code ' + redact(url) if url else 'NO pairing code (FAIL: this ref shows one)' if expects_code else 'NO pairing code (a ref without it: pairing skipped)'} "
             f"in {time.monotonic() - t0:.0f} s; {mac_shot('mac-pairing')}")

        # ---- the phone ------------------------------------------------------
        # A new install, setup marked done (the account's preferences are the live keys until the
        # first sign-in records them), the camera refused: the scanner shows its camera-off state.
        subprocess.run(simctl + ["terminate", a.udid, a.bundle_id], capture_output=True)
        subprocess.run(simctl + ["uninstall", a.udid, a.bundle_id], check=True, capture_output=True)
        subprocess.run(simctl + ["install", a.udid, a.ios_app], check=True, capture_output=True)
        data = subprocess.run(simctl + ["get_app_container", a.udid, a.bundle_id, "data"],
                              check=True, capture_output=True, text=True).stdout.strip()
        prefs = os.path.join(data, "Library/Preferences", f"{a.bundle_id}.plist")
        os.makedirs(os.path.dirname(prefs), exist_ok=True)
        with open(prefs, "wb") as f:
            plistlib.dump({"cmuxMobile.setupComplete": True}, f)
        subprocess.run(simctl + ["privacy", a.udid, "revoke", "camera", a.bundle_id], capture_output=True)
        streams.append(phone_log := Stream(
            simctl + ["spawn", a.udid, "log", "stream", "--level", "info", "--style", "compact",
                      "--predicate", 'subsystem == "dev.cmux.mobile"'], os.path.join(a.out, "phone-pairing.log")))
        phone_launch()
        live = phone_log.wait(re.compile(r"live data on"), 90)
        time.sleep(5)  # bounded: the Devices list loads from the service after live data starts
        note(f"- phone: {'signed in, live data' if live else 'NO live data in 90 s'}; Settings > Devices "
             f"{phone_shot('phone-devices')}")

        if url:
            t1 = time.monotonic()
            opened_at = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 1))
            # As the Camera opens a scanned code: cmux-next://pair?... (RootView .onOpenURL).
            opened = subprocess.run(simctl + ["openurl", a.udid, url], capture_output=True, text=True)
            if opened.returncode != 0:  # the error names the link: redacted, never raised with it
                raise SystemExit(f"simctl openurl failed ({opened.returncode}): {redact(opened.stderr.strip())[-400:]}")
            paired = mac_log.wait(PAIRED, 180)
            took = time.monotonic() - t1
            if not paired:  # the stream may have missed it: the store keeps info lines a while
                paired = PAIRED.search(subprocess.run(["/usr/bin/log", "show", "--info", "--start", opened_at, "--style",
                                                       "compact", "--predicate", pairing_logs],
                                                      capture_output=True, text=True).stdout)
            connected = wait_for(lambda: status().get("connectedPhones", 0) >= 1, 60, every=2)
            note(f"- pairing: {'PAIRED, phone ' + paired.group(1) if paired else 'NOT paired'} "
                 f"({took:.0f} s after the link opened, no Allow prompt, no seed); Mac lists "
                 f"{last.get('connectedPhones', 0)} connected phone(s){'' if connected else ' (none in 60 s)'}; "
                 f"phone {phone_shot('phone-paired')}; Mac {mac_shot('mac-pairing-paired')}")
            phone_launch()
            phone_log.wait(re.compile(r"live data on"), 60)
            time.sleep(5)  # bounded, as above
            note(f"- phone Settings > Devices after pairing: {phone_shot('phone-devices-paired')}")
        note(f"- scanner sheet: {scanner(a.udid, phone_shot)}")
    finally:
        if app and app.poll() is None:
            # The app signs itself out first, so it deletes its own tokens wherever its store keeps them
            # (the data-protection Keychain, which `security` can't reach, or its file fallback).
            rpc("debug.cloud.end_session", timeout=30)
            rpc("action.run", {"action": "quitEndSessions"})
            try:
                app.wait(30)
            except subprocess.TimeoutExpired:
                app.terminate()  # the exact PID this script started
                try:
                    app.wait(15)
                except subprocess.TimeoutExpired:
                    app.kill()
        for s in streams:
            s.stop()
        collect(support, a.out, note)
        teardown.end()
        shutil.rmtree(rig, ignore_errors=True)  # the settings and credential files
        forget_tag(a.mac_app)  # cmux-next-ios-sim.sh's EXIT runs it again for a rig cut short
    if not url and not expects_code:
        return 0  # the "before": this ref shows no code, and the Devices screen is its evidence
    return 0 if paired else 1


def step_tag(app):
    """(bundle id, tag, LSEnvironment) of cmux-next-ios-sim.sh's own tagged Mac app. Its tag holds the
    step's PID (`iospair-<sha8>-<pid>`), so every path named by the tag or bundle id is this run's."""
    info = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))
    ls_env = {k: str(v) for k, v in (info.get("LSEnvironment") or {}).items()}
    bundle, tag = info.get("CFBundleIdentifier", ""), ls_env.get("CMUX_TAG", "")
    if not re.fullmatch(r"iospair-[0-9a-f]+-\d+", tag) or not bundle.startswith("com.cmuxterm.app.debug."):
        raise SystemExit(f"the Mac app is not this step's tagged build ({bundle!r}, CMUX_TAG {tag!r})")
    return bundle, tag, ls_env


def no_data_protection_keychain(app):
    """reload.sh signs the tagged app ad hoc with no entitlements, so it can't reach the data-protection
    Keychain (no application identifier or access group). Its tokens go to the file fallback, and
    the pairing seal and relay secrets are never stored. Everything it can store is then in the file
    Keychain, which `forget_keychain` reaches. An app signed with those entitlements would leave items
    only it can delete, so the run refuses it."""
    out = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", "--xml", app],
                         capture_output=True, text=True).stdout
    for key in ("keychain-access-groups", "com.apple.application-identifier", "com.apple.developer.team-identifier"):
        if key in out:
            raise SystemExit(f"the Mac app is signed with {key}: its data-protection Keychain items would outlive the run")


def forget_tag(app):
    """Everything the tagged app and reload.sh leave for this tag, by exact path (the one list both cleanup
    paths use): the app's settings, support, auth file fallback, run markers and defaults; the daemon's
    tag state and socket; the isolated Chief home; reload.sh's log and last-socket markers; the debug
    socket and log; the iPhone link journal; the Keychain items. Home paths are tried under $HOME (a step
    runs with its own) and the account home (reload.sh's markers, the app's FileManager home)."""
    bundle, tag, ls_env = step_tag(app)
    slug = re.sub(r"[^a-z0-9]+", "-", bundle[len("com.cmuxterm.app.debug."):].lower()).strip("-")
    safe = re.sub(r"[^A-Za-z0-9.-]", "_", bundle)  # CrashReportWriter.safe
    homes = {os.path.expanduser("~"), pwd.getpwuid(os.getuid()).pw_dir}
    dirs, files = [], [f"/tmp/cmux-reload-{tag}.log", f"/tmp/cmux-debug-{tag}.sock", f"/tmp/cmux-debug-{tag}.log",
                       f"/tmp/cmux-next-irx-journal-{tag}.jsonl", f"/tmp/cmux-dev-{slug}-last-socket-path"]
    sock = ls_env.get("CMUX_SOCKET_PATH", "")
    if tag in os.path.basename(sock):
        files.append(sock)
    for home in homes:
        support = os.path.join(home, "Library/Application Support")
        dirs += [os.path.join(support, bundle), os.path.join(support, "cmux", bundle),
                 os.path.join(support, "cmux/tags", tag), os.path.join(support, "cmux-next", safe),
                 os.path.join(home, ".cmux/chief/isolated", tag)]
        files += [os.path.join(support, f"cmux/cmuxd-dev-{tag}.sock"),
                  os.path.join(support, f"cmux/dev-{slug}-last-socket-path"),
                  os.path.join(home, f".local/state/cmux/dev-{slug}-last-socket-path"),
                  os.path.join(home, "Library/Preferences", f"{bundle}.plist")]
    # Through cfprefsd first, so a cached domain is not written back after the file goes.
    subprocess.run(["/usr/bin/defaults", "delete", bundle], capture_output=True)
    for path in dirs:
        shutil.rmtree(path, ignore_errors=True)
    for path in files:
        if os.path.lexists(path):
            try:
                os.unlink(path)
            except OSError:
                pass
    forget_keychain(bundle)


def forget_keychain(bundle):
    """This run's file-Keychain items: the Stack tokens (`<bundle>.auth`, CloudConfiguration), the iPhone
    host's identity (`<bundle>.iphone-host.identity`, MobileHostMacIdentity) and the device hub's keys
    (`<bundle>.device-hub`, DeviceKeychain), by their exact services;
    the bundle id is this tag's own. Every item of a service goes (one per account)."""
    for service in (f"{bundle}.auth", f"{bundle}.iphone-host.identity", f"{bundle}.device-hub"):
        for _ in range(32):  # bounded: delete-generic-password removes one item per call
            if subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", service],
                              capture_output=True).returncode != 0:
                break


def scanner(udid, shot):
    """Settings > Devices > "Scan QR on your Mac", by a tap through AXe (the rig's UI driver)."""
    if not shutil.which("axe"):
        return "not captured (axe is not installed on this host: brew install cameroncooke/axe/axe)"
    try:
        tree = json.loads(subprocess.run(["axe", "describe-ui", "--udid", udid], capture_output=True, text=True,
                                         timeout=60).stdout or "[]")
    except (ValueError, subprocess.TimeoutExpired) as error:
        return f"not captured (axe describe-ui: {error})"
    nodes = tree if isinstance(tree, list) else [tree]
    while nodes:
        node = nodes.pop()
        if node.get("AXUniqueId") == "settings.scanMacCode":
            f = node.get("frame") or {}
            x, y = f.get("x", 0) + f.get("width", 0) / 2, f.get("y", 0) + f.get("height", 0) / 2
            subprocess.run(["axe", "tap", "--udid", udid, "-x", f"{x:.1f}", "-y", f"{y:.1f}", "--tap-style", "simulator"],
                           capture_output=True, timeout=25)
            time.sleep(2)  # bounded: the sheet's presentation
            return f"camera off, {shot('phone-scanner-camera-off')}"
        nodes.extend(node.get("children") or [])
    return "no \"Scan QR on your Mac\" row (settings.scanMacCode) on this build"


def collect(support, out, note):
    """hostd's pairing lines and the paired phones list, keys redacted."""
    lines = []
    for path in glob.glob(os.path.join(support, "**/cmux-mobile-host.log"), recursive=True):
        lines += [redact(l) for l in open(path, errors="replace")
                  if re.search(r"pair|auth|link (up|down)|registered|signaling connected", l)]
    open(os.path.join(out, "hostd-pairing.log"), "w").writelines(lines)
    def scrub(value, key=""):
        if isinstance(value, dict):
            return {k: scrub(v, k) for k, v in value.items()}
        if isinstance(value, list):
            return [scrub(v, key) for v in value]
        if isinstance(value, str) and any(word in key.lower() for word in ("key", "token", "secret")):
            return f"<redacted, {len(value)} chars>"
        if isinstance(value, str) and key.lower() in ("id", "userid"):
            return value[:8] + "..."
        return redact(value) if isinstance(value, str) else value

    found = glob.glob(os.path.join(support, "**/paired-devices.json"), recursive=True)
    for i, path in enumerate(found):
        try:
            doc = scrub(json.load(open(path)))
        except ValueError as error:
            doc = {"unreadable": str(error)}
        json.dump(doc, open(os.path.join(out, f"paired-devices{i or ''}.redacted.json"), "w"), indent=2)
    note(f"- evidence: mac-pairing.log, phone-pairing.log, hostd-pairing.log ({len(lines)} lines), "
         f"{len(found)} paired-devices.json (keys redacted), mac-app.log")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--forget-tag":  # cmux-next-ios-sim.sh's EXIT: the same list
        forget_tag(sys.argv[2])
        sys.exit(0)
    if sys.argv[1:] == ["--redact"]:  # a filter: cmux-next-ios-sim.sh's app log goes through it
        for line in sys.stdin:
            sys.stdout.write(redact(line))
        sys.exit(0)
    sys.exit(main())
