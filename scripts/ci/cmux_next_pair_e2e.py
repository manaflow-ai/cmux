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
Then the upload leg (on a ref whose app has UploadProbe): a sparse file of about 150 MB, past the
old 100 MiB cap, with marked pages at its start, middle and end, is streamed by the app's own
`LinkUpload.upload(fileAt:)` over the paired link to the Mac's Chat Folder; it passes when the file
lands in `<folder>/.cmux/attachments/phone-<session>/` with the same size and SHA-256 and the app's
memory footprint grew by less than a fifth of the file (no whole-file Data).
With CMUX_IOS_CLOUD_PROOF_FILE, also opens a probe-owned real Cloud session on
the paired phone, copies its history, sends a fresh challenge, reads the
assistant reply, and taps an injected notification. That injection proves
routing only; APNs acceptance is a separate receipt. The 0600 input stays on
the runner, is never copied to evidence, and never supplies credentials.
The token is never printed: `t=` is redacted in every log line and file. Ends the Mac app it started (its own PID) and the
tag's daemons (tag_teardown.py), and removes the app's state and its Keychain items.

The app runs under the rig's own file keychain (RigKeychain): a new keychain first in the user's search
list and the default for the run, deleted after it, with the list and default put back as they were.
A fleet step runs with its own empty HOME (build-fleet worker buildEnv: HOME=<job>/home), and the
Security framework finds the user's keychain preferences under $HOME/Library/Preferences: there are
none, so the app has no default keychain, and its first file-keychain write (the iPhone host identity,
SecItemAdd) asks SecurityAgent to create a login keychain (`system.keychain.create.loginkc`, a dialog
nobody answers); hostd never starts and the page stays "preparing" (steps 59c5f9eb, c9c9b027, e2b11b0c,
8703f0e6, 2026-10-28/29). In a step, the list and default the rig sets are the step HOME's own; the
account's keychains and preferences are never read, changed or deleted.

Why the dev Cloud and not loopback: the gate the code must not weaken is the account check, and
that check lives on the Cloud path (the Worker stamps the verified sender's `fromUserId` on every
signal, and hostd refuses a dial whose `fromUserId` is not the Mac's owner); a loopback seam would
have to fake that stamp, so it would test around the very check this proves. The account is the
in-source DEBUG dev credential of the dev Stack project (the one verify/e2e/mac.py uses), not a
production or personal account and not a secret.
"""
import argparse, glob, hashlib, json, os, plistlib, pwd, re, secrets, shutil, socket, subprocess, sys, threading, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.."))
sys.path.insert(0, os.path.join(ROOT, "scripts/cmux-next"))
from tag_teardown import TagTeardown  # noqa: E402
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmux_next_cloud_pair_proof import allowlist_public_cloud_artifact, read_proof, run_cloud_leg  # noqa: E402

PAGE = "cmux.mobile-pairing"
RIG_MAC_NAME = "0 e2e rig Mac"
PAIRED = re.compile(r"phone (\w+) paired from this Mac's pairing code")
# The upload leg: past the old 100 MiB cap and not a multiple of LinkUpload's 192 KiB chunk.
UPLOAD_BYTES = (150 << 20) + 12_345
UPLOAD_NAME = "cmux-upload-probe.bin"


def redact(text):
    """A pairing code's token (a link's `t=`, a `pairToken`) never reaches a log or the artifact."""
    return re.sub(r'((?<!\w)t=|pair_?token"?\s*[:=]\s*"?)[A-Za-z0-9_-]+', r"\1<redacted>", text, flags=re.I)


def shows_a_code():
    """Whether this ref's Mobile Pairing page sends a pairing code (`qr`): on a ref without it no
    code is the expected "before"; on one with it, no code is a failure."""
    src = os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Pages/MobilePairing/MobilePairingPageProvider.swift")
    return os.path.exists(src) and 'reply["qr"]' in open(src).read()


def has_upload_probe():
    """Whether this ref's app has the DEBUG upload probe (UploadProbe.swift): the leg runs only there."""
    return os.path.exists(os.path.join(ROOT, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/UploadProbe.swift"))


def sparse_file(path, size):
    """`size` bytes that take no disk, with marked 4 KiB pages at the start, middle and end so a
    lost, shifted or zeroed chunk changes the hash."""
    with open(path, "wb") as f:
        f.truncate(size)
        for mark, at in ((0x11, 0), (0x22, size // 2), (0x33, size - 4096)):
            f.seek(at)
            f.write(bytes([mark]) * 4096)


def sha256(path):
    digest, total = hashlib.sha256(), 0
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
            total += len(chunk)
    return total, digest.hexdigest()


def takes_pair_url_env():
    """Whether this ref's phone app (DEBUG) takes a pairing code from CMUX_MOBILE_PAIR_URL at launch: a
    simulator asks "Open in cmux?" for `simctl openurl` (steps d7afa734, c8c0dec1), which nothing answers."""
    src = os.path.join(ROOT, "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileShell/RootView.swift")
    return os.path.exists(src) and '"CMUX_MOBILE_PAIR_URL"' in open(src).read()


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
    proof_path = os.environ.get("CMUX_IOS_CLOUD_PROOF_FILE")
    proof = read_proof(proof_path, artifact_root=a.out) if proof_path else None
    cloud_ok = proof is None
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
    probe = has_upload_probe()
    # The upload leg's Mac folder: a Chat Folder (agents.chats.roots), which hostd shares
    # (CMUX_MOBILE_FILE_ROOTS), so an upload with it as `cwd` lands in its .cmux/attachments.
    upload_root = os.path.join(os.path.realpath(a.work), "pair-rig", "upload-root")
    creds = os.path.join(rig, "dev-auth.env")  # written once cleanup is armed (below)
    # Launched by its binary (its PID is this script's child), with the environment `open`
    # would give it (LSEnvironment) plus the rig's settings. An empty seed trusts no phone.
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
    env.update(ls_env)
    env.update(CMUX_NEXT_CONFIG_FILE=config, CMUX_AUTH_CREDENTIALS_FILE=creds, CMUX_NEXT_IPHONE_PAIRING_SEED="",
               CMUX_NEXT_MOBILE_MACHINE_ID=machine_id(mac_bundle), CMUX_NEXT_NO_ACTIVATE="1",
               # The name phones list this Mac by (DEBUG override): the dev account lists 100+ Macs
               # by name, and this one sorts first, so the Devices captures show its row on top
               # (step 423a0bae's showed only other Macs) and name no host.
               CMUX_NEXT_MOBILE_DEVICE_NAME=RIG_MAC_NAME,
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
    streams, app, paired, url, uploaded = [], None, None, None, not probe
    keychain = RigKeychain(a.mac_app)
    try:
        note(f"- Keychain: {keychain.start()}")
        os.makedirs(rig, mode=0o700, exist_ok=True)
        settings = {"mobile": {"allowIPhoneConnections": True}}
        if probe:
            os.makedirs(upload_root, mode=0o700)
            settings["agents"] = {"chats": {"roots": [upload_root]}}
        with open(config, "w") as f:
            json.dump(settings, f)
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
            try:  # evidence only: a failure here never replaces the error below
                why = no_answer_evidence(app, ls_env, tag, sock, a.out)
            except Exception as error:  # noqa: BLE001
                why = f"no evidence ({type(error).__name__}: {redact(str(error))[:200]})"
            try:
                note(f"- Mac app: no answer on its control socket in 180 s; {why}")
            except OSError:
                pass
            raise SystemExit("the Mac app never answered on its control socket")
        teardown.remember()
        note(f"- Mac app {mac_bundle}: pid {app.pid}, control socket in {time.monotonic() - t0:.0f} s")
        pairing_logs = f'processID == {app.pid} AND subsystem == "com.cmuxterm.app.next" AND category BEGINSWITH "app.iphone"'
        streams.append(mac_log := Stream(["/usr/bin/log", "stream", "--level", "info", "--style", "compact",
                                          "--predicate", pairing_logs], os.path.join(a.out, "mac-pairing.log")))
        # Signed in, hostd online, iPhone connections on: the page shows the code. A page still
        # without one at 60 s is sampled once (where the app waits), then the wait goes on.
        deadline = time.monotonic() + (300 if expects_code else 60)
        qr = (wait_for(lambda: status().get("qr"), 60, every=2) or {})
        if not qr and expects_code:
            try:  # evidence only: a failure here never replaces the run's own verdict
                why = preparing_evidence(app, a.out, deadline)
            except Exception as error:  # noqa: BLE001
                why = f"no evidence ({type(error).__name__}: {redact(str(error))[:200]})"
            try:
                note(f"- Mac pairing page: still {last.get('state') or 'without a status'} at "
                     f"{time.monotonic() - t0:.0f} s; {why}")
            except OSError:
                pass
            # The same 300 s deadline as one wait: the evidence's own time is not added to it, and
            # a page read after the deadline never counts.
            left = deadline - time.monotonic()
            qr = (wait_for(lambda: status().get("qr"), left, every=2) or {}) if left > 0 else {}
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
            # The phone dialed this Mac at its first launch, before it had the code; its auth waits on
            # the Mac's Allow, and the code's token goes out only in an auth's challenge reply
            # (LinkPairing). So the app is started again with the code, and the Mac answers the
            # earlier ask with it. A simulator asks "Open in cmux?" for `simctl openurl` (steps
            # d7afa734, c8c0dec1: nothing answered it), so a ref whose DEBUG app takes the code from
            # its launch environment gets it there (in the environment only, never in argv or a log).
            subprocess.run(simctl + ["terminate", a.udid, a.bundle_id], capture_output=True, timeout=60)
            if takes_pair_url_env():
                try:  # the environment holds the code: an error is raised with neither it nor argv
                    started = subprocess.run(simctl + ["launch", a.udid, a.bundle_id, "-cmux-mobile-settings-page", "devices"],
                                             env=dict(phone_env, SIMCTL_CHILD_CMUX_MOBILE_PAIR_URL=url),
                                             capture_output=True, text=True, timeout=60)
                except (OSError, subprocess.TimeoutExpired) as error:
                    raise SystemExit(f"simctl launch with the code failed ({type(error).__name__})") from None
                if started.returncode != 0:
                    raise SystemExit(f"simctl launch with the code failed ({started.returncode}): "
                                     f"{redact(started.stderr.strip())[-400:]}")
            else:
                # As the Camera opens a scanned code: cmux-next://pair?... (RootView .onOpenURL).
                try:  # a TimeoutExpired names its argv, the link with its token: never raised with it
                    opened = subprocess.run(simctl + ["openurl", a.udid, url], capture_output=True, text=True, timeout=60)
                except (OSError, subprocess.TimeoutExpired) as error:
                    raise SystemExit(f"simctl openurl failed ({type(error).__name__})") from None
                if opened.returncode != 0:  # the error names the link: redacted, never raised with it
                    raise SystemExit(f"simctl openurl failed ({opened.returncode}): {redact(opened.stderr.strip())[-400:]}")
            paired = mac_log.wait(PAIRED, 180)
            took = time.monotonic() - t1
            if not paired:  # the stream may have missed it: the store keeps info lines a while
                paired = PAIRED.search(subprocess.run(["/usr/bin/log", "show", "--info", "--start", opened_at, "--style",
                                                       "compact", "--predicate", pairing_logs],
                                                      capture_output=True, text=True).stdout)
            connected = wait_for(lambda: status().get("connectedPhones", 0) >= 1, 60, every=2)
            took_code = phone_log.wait(re.compile(r"pairing code for"), 0)
            note(f"- pairing: {'PAIRED, phone ' + paired.group(1) if paired else 'NOT paired'} "
                 f"({took:.0f} s after the link opened, no Allow prompt, no seed; the phone "
                 f"{'took' if took_code else 'never logged taking'} the code); Mac lists "
                 f"{last.get('connectedPhones', 0)} connected phone(s){'' if connected else ' (none in 60 s)'}; "
                 f"phone {phone_shot('phone-paired')}; Mac {mac_shot('mac-pairing-paired')}")
            phone_launch()
            phone_log.wait(re.compile(r"live data on"), 60)
            time.sleep(5)  # bounded, as above
            note(f"- phone Settings > Devices after pairing: {phone_shot('phone-devices-paired')}")
            if paired and probe:
                uploaded, line = upload_leg(simctl, a.udid, a.bundle_id, phone_env, upload_root, last.get("macName"))
                note(f"- upload: {line}")
        note(f"- scanner sheet: {scanner(a.udid, phone_shot)}")
        if proof is not None:
            if not paired:
                raise SystemExit("Cloud UI proof requires the real QR pairing to succeed")
            run_cloud_leg(proof, root=ROOT, mac_env=env, email=email, rpc=rpc, phone_log=phone_log,
                          simctl=simctl, udid=a.udid, bundle=a.bundle_id, phone_env=phone_env,
                          rig_name=last.get("macName") or RIG_MAC_NAME, work=a.work, out=a.out,
                          shot=phone_shot, note=note)
            cloud_ok = True
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
        try:
            for s in streams:
                s.stop()
            collect(support, a.out, note)
            teardown.end()
            shutil.rmtree(rig, ignore_errors=True)  # the settings and credential files
        finally:  # the account's keychains are put back even when a step above fails
            forget_tag(a.mac_app)  # cmux-next-ios-sim.sh's EXIT runs it again for a rig cut short
        if proof is not None:
            # The public archive is an allowlist in Cloud mode. Raw screenshots,
            # pairing/app logs and failure captures remain unavailable to upload.
            allowlist_public_cloud_artifact(a.out)
    if not url and not expects_code and proof is None:
        return 0  # the "before": this ref shows no code, and the Devices screen is its evidence
    return 0 if paired and uploaded and cloud_ok else 1


def upload_leg(simctl, udid, bundle_id, phone_env, root, mac_name):
    """The phone streams a sparse ~150 MB file to the Mac with its own LinkUpload (UploadProbe, a DEBUG
    launch argument); (passed, summary line). The stored file must match byte for byte."""
    data = subprocess.run(simctl + ["get_app_container", udid, bundle_id, "data"],
                          check=True, capture_output=True, text=True).stdout.strip()
    source = os.path.join(data, "tmp", UPLOAD_NAME)
    result_path = os.path.join(data, "Documents", "upload-probe.json")
    os.makedirs(os.path.dirname(source), exist_ok=True)
    if os.path.exists(result_path):
        os.unlink(result_path)
    sparse_file(source, UPLOAD_BYTES)
    try:
        want = sha256(source)
        args = ["-CmuxMobileUploadProbe", source, "-CmuxMobileUploadProbeCwd", root]
        if mac_name:
            args += ["-CmuxMobileUploadProbeMac", mac_name]
        subprocess.run(simctl + ["terminate", udid, bundle_id], capture_output=True)
        subprocess.run(simctl + ["launch", udid, bundle_id] + args, env=phone_env, check=True, capture_output=True)
        # Bounded wait on the app's own result file (no event reaches this script for it).
        if not wait_for(lambda: os.path.exists(result_path), 300, every=2):
            return False, f"FAIL: no upload-probe.json in 300 s (the probe waits for a served link to {mac_name!r})"
        result = json.load(open(result_path))
    finally:
        os.unlink(source)
    took, grew = result.get("seconds", 0), result.get("footprintPeak", 0) - result.get("footprintBefore", 0)
    if "path" not in result:
        return False, f"FAIL: the Mac refused it: {result.get('error')}: {result.get('message')}"
    stored = result["path"]
    folder = os.path.dirname(stored)
    checks = {
        "in <cwd>/.cmux/attachments/phone-<session>/": os.path.dirname(folder) == os.path.join(root, ".cmux", "attachments")
        and os.path.basename(folder).startswith("phone-"),
        "same size and SHA-256": os.path.isfile(stored) and sha256(stored) == want,
        "footprint grew < 1/5 of the file": grew < UPLOAD_BYTES // 5,
    }
    failed = [name for name, ok in checks.items() if not ok]
    return not failed, (f"{'PASSED' if not failed else 'FAIL: ' + ', '.join(failed)}; {UPLOAD_BYTES:,} bytes, sha256 "
                        f"{want[1][:16]}..., in {took:.1f} s; stored at .../{os.path.relpath(stored, root)}; app footprint "
                        f"{result.get('footprintBefore', 0) >> 20} MiB before, +{grew >> 20} MiB at its peak")


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
    # First, so no later cleanup step (a hung cfprefsd, an error) can keep the account's search list
    # and default keychain changed: the run's own keychain and its items go, the user's list and default back.
    try:
        RigKeychain(app).end()
    finally:
        _forget_tag_files(app, bundle, tag, ls_env)


def _forget_tag_files(app, bundle, tag, ls_env):
    """forget_tag's files, folders and defaults domain (see there)."""
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
    try:
        subprocess.run(["/usr/bin/defaults", "delete", bundle], capture_output=True, stdin=subprocess.DEVNULL, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        pass  # the plist file goes below either way
    for path in dirs:
        shutil.rmtree(path, ignore_errors=True)
    for path in files:
        if os.path.lexists(path):
            try:
                os.unlink(path)
            except OSError:
                pass


def forget_keychain(bundle, keychain):
    """This run's file-Keychain items in the rig's own `keychain` only (never the account's): the Stack
    tokens (`<bundle>.auth`, CloudConfiguration), the iPhone host's identity
    (`<bundle>.iphone-host.identity`, MobileHostMacIdentity) and the device hub's keys
    (`<bundle>.device-hub`, DeviceKeychain), by their exact services; the bundle id is this tag's own.
    Every item of a service goes (one per account). RigKeychain.end() runs it before it deletes the
    keychain, so the items go even if that delete fails."""
    for service in (f"{bundle}.auth", f"{bundle}.iphone-host.identity", f"{bundle}.device-hub"):
        for _ in range(32):  # bounded: delete-generic-password removes one item per call
            try:
                if subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", service, keychain],
                                  capture_output=True, stdin=subprocess.DEVNULL, timeout=30).returncode != 0:
                    break
            except (OSError, subprocess.TimeoutExpired):
                break


class RigKeychain:
    """The run's own file keychain, so no Keychain call of the app reaches the account's keychains or asks
    to create a login keychain (see the module doc). start() records the user domain's search list and
    default keychain in a 0600 state file next to the tagged app (before changing anything), creates
    `rig.keychain-db` there with a random password (in argv only, never in a file or log; the keychain is
    unlocked with no lock timeout and deleted at the end), puts it first in the search list and makes it
    the default. end() is idempotent and runs from forget_tag (the rig's finally, and the sim script's
    EXIT for a run cut short): the list and the default go back as recorded (a default that was unset
    is unset again), the run's items and the keychain are deleted, and the list and default are read
    back; the record is deleted only when they match it, so a failed restore is tried again by the
    next end(). Every call is bounded."""

    NO_DEFAULT = "A default keychain could not be found"

    def __init__(self, app):
        self.bundle, tag, _ = step_tag(app)
        self.dir = os.path.join(os.path.dirname(os.path.realpath(app)), f"pair-rig-keychain-{tag}")
        self.path = os.path.join(self.dir, "rig.keychain-db")
        self.state = os.path.join(self.dir, "state.json")

    @staticmethod
    def _security(*argv):
        """(exit code, stdout, stderr); -1 when it did not run or timed out."""
        try:
            r = subprocess.run(["/usr/bin/security", *argv], capture_output=True, text=True, errors="replace",
                               stdin=subprocess.DEVNULL, timeout=30)
            return r.returncode, r.stdout, r.stderr
        except (OSError, subprocess.TimeoutExpired) as error:
            return -1, "", f"{error}"

    @staticmethod
    def _lines(out):
        """The paths `security` prints, one quoted path a line, canonical (a /tmp path prints as /private/tmp)."""
        return [os.path.realpath(p) for p in (line.strip().strip('"') for line in out.splitlines()) if p]

    @classmethod
    def _search(cls):
        """The user domain's search list, or None when it could not be read."""
        code, out, _ = cls._security("list-keychains", "-d", "user")
        return cls._lines(out) if code == 0 else None

    @classmethod
    def _default(cls):
        """(read, path): the user domain's default keychain; path None only when `security` says there is none."""
        code, out, err = cls._security("default-keychain", "-d", "user")
        paths = cls._lines(out)
        if code == 0 and len(paths) == 1:
            return True, paths[0]
        return (cls.NO_DEFAULT in err or cls.NO_DEFAULT in out), None

    def start(self):
        # Only a step's own HOME (build-fleet buildEnv: HOME=<job>/home, one per run): its keychain
        # preferences are this run's alone, so no other run or person can see or undo what it sets.
        home = os.path.realpath(os.path.expanduser("~"))
        if home == os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir):
            raise SystemExit("the rig's keychain needs the step's own HOME, not the account's: "
                             "run pair-e2e through cmux-ci")
        # The preferences folder of this HOME (a step's own HOME has none): without it `security` reports
        # success for -s and keeps nothing (macOS 27, 2026-10-29), and the app still has no default.
        os.makedirs(os.path.expanduser("~/Library/Preferences"), mode=0o700, exist_ok=True)
        search = self._search()
        read, default = self._default()
        if search is None or not read:  # never record a guess as the account's state
            raise SystemExit("security could not read the user search list or default keychain; "
                             "the rig's keychain is not set up")
        os.makedirs(self.dir, mode=0o700, exist_ok=True)
        if os.path.exists(self.state):  # a run of this tag already holds it: never record its keychain as the user's
            raise SystemExit(f"{self.state} exists: the rig's keychain of this tag is already set up")
        with os.fdopen(os.open(self.state, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
            json.dump({"search": search, "default": default}, f)
        password = secrets.token_urlsafe(24)
        for argv in (("create-keychain", "-p", password, self.path), ("set-keychain-settings", self.path),
                     ("unlock-keychain", "-p", password, self.path),
                     ("list-keychains", "-d", "user", "-s", self.path, *search),
                     ("default-keychain", "-d", "user", "-s", self.path)):
            code, _, _ = self._security(*argv)
            if code != 0:  # names the subcommand only: argv holds the password
                raise SystemExit(f"security {argv[0]} failed ({code}); the rig's keychain is not set up")
        now, (_, now_default) = self._search(), self._default()
        if not now or now[0] != self.path or now_default != self.path:
            raise SystemExit("security took the rig's keychain but does not list it as first and default "
                             f"(HOME {os.path.expanduser('~')}); the app would ask to create a login keychain")
        return (f"the rig's own (first of {len(search) + 1} in the search list, the default; the account's "
                f"default was {'unset' if default is None else 'set'})")

    def end(self):
        """Returns whether the user's list and default are back (or were never changed). `security ... -s`
        with nothing after it changes nothing (macOS 27, 2026-10-29), so an empty list and an unset default
        come back by `delete-keychain`, which takes the keychain out of the list and unsets it as default."""
        try:
            with open(self.state) as f:
                saved = json.load(f)
        except FileNotFoundError:
            saved = None
        except (OSError, ValueError):
            return False  # unreadable record: keep it and the keychain for a look, never guess
        keep, ours = None, True
        if saved is not None:
            now = self._search()
            read, now_default = self._default()
            if now is None or not read:
                return False
            # The recorded list, plus any keychain added to it during the run (not the rig's).
            keep = saved["search"] + [k for k in now if k not in saved["search"] and k != self.path]
            if keep:
                self._security("list-keychains", "-d", "user", "-s", *keep)
            ours = now_default in (None, self.path)  # a default someone else set during the run stays theirs
            if ours and saved["default"]:
                self._security("default-keychain", "-d", "user", "-s", saved["default"])
        if os.path.exists(self.path):
            forget_keychain(self.bundle, self.path)
            self._security("delete-keychain", self.path)
        if saved is not None:
            after, (read, after_default) = self._search(), self._default()
            if after != keep or not read or after_default == self.path or (ours and after_default != saved["default"]):
                return False  # the record stays: forget_tag's next run tries again
        shutil.rmtree(self.dir, ignore_errors=True)
        return True


def run_bounded(argv, timeout):
    """An evidence read: its output and errors, or why it gave none; never raises, never waits past `timeout`.
    A tool that writes a report file of its own (`sample` writes one to /tmp) is pointed at /dev/stdout,
    so everything it reports reaches disk only through redact()."""
    try:
        r = subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=timeout,
                           stdin=subprocess.DEVNULL)
        return r.stdout + r.stderr
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"{argv[0]}: {error}\n"


def save_redacted(out, name, text, lines=400):
    """The last `lines` lines of `text`, token redacted, as `out/name`; returns `name`."""
    with open(os.path.join(out, name), "w") as f:
        f.writelines(redact(line) for line in text.splitlines(keepends=True)[-lines:])
    return name


def preparing_evidence(app, out, deadline):
    """Why the pairing page stays "preparing" (steps 59c5f9eb, c9c9b027, 2026-10-28: a SecurityAgent
    prompt in the console session 2 s after launch, hostd never started, no code in 302 s): which
    thread waits in a Keychain or Authorization call, and from which frame. A 3 s `sample` of the app
    and of its own children (at most 4, cmux-mobile-host first), the Security framework's and
    SecurityAgent's unified log and the app's own subsystem for the last 3 minutes, and the Keychain
    search list and default keychain (preference reads, no keychain is opened). Each read is bounded
    by its own timeout and by the pairing wait's `deadline` (monotonic; a read with no time left is
    skipped), best effort; tokens are redacted. Returns the summary's words."""
    files, waits, skipped = [], [], []

    def run(argv, timeout, what):
        left = deadline - time.monotonic() - 5  # 5 s stay for the wait's own last read
        if left < 1:
            skipped.append(what)
            return None
        return run_bounded(argv, min(timeout, left))

    rows = (run(["/bin/ps", "-A", "-o", "pid=,ppid=,comm="], 10, "ps") or "").splitlines()
    kids, agents = [], []
    for row in rows:
        parts = row.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
            pid, ppid, comm = int(parts[0]), int(parts[1]), parts[2]
            name = os.path.basename(comm)
            if ppid == app.pid and pid != app.pid:  # the app's own children only, hostd first
                kids.append((name != "cmux-mobile-host", pid, name))
            if name == "SecurityAgent":
                agents.append(pid)
    for _, pid, name in [(False, app.pid, "app")] + sorted(kids)[:4]:
        text = run(["/usr/bin/sample", str(pid), "3", "-file", "/dev/stdout"], 60, f"sample {pid}")
        if text is None:
            continue
        files.append(save_redacted(out, f"preparing-sample-{re.sub(r'[^A-Za-z0-9.-]', '_', name)}-{pid}.txt", text, 3000))
        hits = sorted({m.group(1) for m in re.finditer(
            r"\b(SecItem\w+|SecKeychain\w+|SecTrust\w+|Authorization\w+|SecAccess\w+|LAContext\w*|"
            r"evaluatePolicy\w*|MobileHostMacIdentityStore\.\w+|MobileHostPairingSeal\.\w+|"
            r"KeychainStackTokenStore\.\w+|DeviceKeychain\.\w+)", text)})
        if hits:
            waits.append(f"{name} {pid}: {', '.join(hits[:8])}")
    reads = [("preparing-security.log", 1500, 90,
              ["/usr/bin/log", "show", "--last", "3m", "--info", "--style", "compact", "--predicate",
               'subsystem == "com.apple.securityd" OR process == "SecurityAgent" OR process == "authd" '
               'OR process == "securityd"']),
             ("preparing-app.log", 1500, 90,
              ["/usr/bin/log", "show", "--last", "3m", "--info", "--style", "compact", "--predicate",
               f'processID == {app.pid} AND subsystem == "com.cmuxterm.app.next"']),
             ("preparing-keychains.txt", 40, 10, ["/usr/bin/security", "list-keychains", "-d", "user"]),
             ("preparing-default-keychain.txt", 10, 10, ["/usr/bin/security", "default-keychain", "-d", "user"])]
    for name, lines, timeout, argv in reads:
        text = run(argv, timeout, name)
        if text is not None:
            files.append(save_redacted(out, name, text, lines))
    return (f"SecurityAgent pids {agents or 'none'}; Keychain/Authorization frames: "
            f"{'; '.join(waits) or 'none in the samples'}; {', '.join(files) or 'no files'}"
            f"{'; skipped at the deadline: ' + ', '.join(skipped) if skipped else ''}")


def no_answer_evidence(app, ls_env, tag, sock, out):
    """Why the Mac app did not answer (step 42cdc9d7, 2026-10-27: alive, silent for 180 s, only an
    NSXPCSharedListener 'ClientCallsAuxiliary' line on stderr): the session it runs in, where its main
    thread waits (`sample`), its own unified log and the tail of its debug log, before the teardown
    ends it. Each read is bounded and best effort; tokens are redacted. Returns the summary's words."""
    run = run_bounded

    def save(name, text, lines=400):
        return save_redacted(out, name, text, lines)

    try:  # the worker's rule (build-fleet console_session.go): loginwindow or no key is nobody
        scutil = subprocess.run(["/usr/sbin/scutil"], input="show State:/Users/ConsoleUser\n",
                                capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        scutil = ""
    console = re.search(r"(?m)^\s*Name : (\S+)", scutil)
    facts = (f"running {app.poll() is None}, account {pwd.getpwuid(os.getuid()).pw_name}, console user "
             f"{console.group(1) if console else 'none'}, launchd {run(['/bin/launchctl', 'managername'], 10).strip()}, "
             f"socket {'present' if os.path.exists(sock) else 'absent'}")
    files = [save("mac-app-sample.txt", run(["/usr/bin/sample", str(app.pid), "3", "-file", "/dev/stdout"], 60), 2000),
             save("mac-app-unified.log", run(["/usr/bin/log", "show", "--last", "5m", "--style", "compact",
                                              "--predicate", f"processID == {app.pid}"], 60))]
    debug_log = ls_env.get("CMUX_DEBUG_LOG") or f"/tmp/cmux-debug-{tag}.log"
    if os.path.isfile(debug_log):
        with open(debug_log, "rb") as f:  # only its last 256 KiB: the tail is what shows where launch stopped
            start = max(0, os.fstat(f.fileno()).st_size - (256 << 10))
            f.seek(start)
            tail = f.read(256 << 10).decode(errors="replace")  # bounded: the live app may still append
        if start:  # a line cut by the seek could start right after `t=`, out of the redactor's reach
            tail = tail.partition("\n")[2]
        files.append(save("mac-debug-log-tail.txt", tail, 200))
    return f"{facts}; {', '.join(files)}"


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
