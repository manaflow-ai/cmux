#!/usr/bin/env python3
"""cmux-next-ios-sim.sh pair-e2e: the iPhone pairs with a Mac, end to end.

Since the Mobile Pairing page and its QR code went (#48532), the phone pairs as a hand-off's does
(cmux-next-ios/scripts/review.sh): the phone app is the Mac's own tag's (`dev.cmux.mobile.<tag>`,
cmux-next-ios-sim.sh pair-e2e), it is launched with the Mac named to focus (`CMUX_MOBILE_FOCUS_MAC`,
the device id on Settings' `iphone` card), and the tagged DEBUG Mac's dev auto-approve
(IPhoneDevAutoApprove) pairs it; the step passes when the Mac logs `phone <id8> paired from the dev
auto-approve`. A ref without the dev auto-approve, or a phone app of another tag, fails: no pairing is
never a pass.

  cmux_next_pair_e2e.py --mac-app APP --ios-app APP --sims SET --udid UDID --bundle-id ID \
      --work DIR --out DIR --summary FILE

The tagged DEBUG cmux NEXT app runs as the e2e rig's Mac does (cmux-next-ios/verify/e2e/mac.py):
its own settings file with iPhone connections on, the DEBUG dev account of CmuxAuthRuntime (a
0600 file, never printed), its own machine id, and NO pairing seed, so only the dev auto-approve
can pair the phone, which is signed in to the same account. With discovery enabled, the Mac first
holds the phone's pairing request unanswered, then restarts without the hold to pair. The phone's
readiness receipt must identify this Mac as linked, and the Mac's Settings must list the very
same phone paired and connected.

Screens: the Mac's Settings page, the phone's Settings > Devices before and after pairing, and its
scanner sheet (Pair Another Machine invites) with the camera off (needs `axe`).
Then the upload leg (on a ref whose app has UploadProbe): a sparse file of about 150 MB, past the
old 100 MiB cap, with marked pages at its start, middle and end, is streamed by the app's own
`LinkUpload.upload(fileAt:)` over the paired link to the Mac's Chat Folder; it passes when the file
lands in `<folder>/.cmux/attachments/phone-<session>/` with the same size and SHA-256 and the app's
memory footprint grew by less than a fifth of the file (no whole-file Data).
Once paired, the theme-file leg: the rig's cmux-next.json names a theme file (`<rig>/themes/pair-e2e.json`),
the phone opens the Mac's terminal, and ten atomic saves alternating two terminal backgrounds are each
timed from the save to the phone's `terminal theme of ... background #hex` log line (with the Mac's
hand-off to hostd and hostd's publish as hops); then a refused value and a half-written file must leave
the phone's background as it was while the Mac's notice names the file.
After pairing and the other legs, the rig verifies the Mac's standing consent is off and quits
the tagged app. The iPhone taps Share for that Mac. The daemon's admission audit, a decoded
phone frame showing InputProbe, and the probe's mouse events are separate required receipts.
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

A step sent with `cmux-ci run --sign-in agent` carries no email or password: it gets the agent
account's own session instead (CMUX_CI_SIGNIN_FILE, the file scripts/lib/fleet-signin-session.sh
reads for handoff mode). With no email and password set, both apps start signed in from it: the
phone from its DEBUG launch environment (CMUX_MOBILE_STACK_REFRESH_TOKEN, adopted while it holds no
session), the Mac from its own token store file, written before its launch. The refresh token is
never printed, and is in no argv and no artifact.
"""
import argparse, calendar, glob, hashlib, json, math, os, plistlib, pwd, re, secrets, shutil, stat, statistics, subprocess, sys, threading, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../.."))
sys.path.insert(0, os.path.join(ROOT, "scripts/cmux-next"))
import build_names  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cmux_next_cloud_pair_proof import allowlist_public_cloud_artifact, read_proof, run_cloud_leg  # noqa: E402
from cmux_next_pair_share_host import TaggedShareHost, share_without_asking_off  # noqa: E402
from cmux_next_pair_share_phone import PairInputProbe, PairSharePhone, viewer_log  # noqa: E402

sys.path.insert(0, os.path.join(ROOT, "cmux-next-ios/scripts"))
import review_mac  # noqa: E402

# Settings, whose `iphone` card (`cmux.settings.host.lists`) lists the Mac's device id, its phones and
# their waiting requests (cmux-next-ios/scripts/review_mac.py status).
PAGE = "cmux.settings"
RIG_MAC_NAME = "0 e2e rig Mac"
PAIRED = re.compile(r"phone (\w+) paired from the dev auto-approve")
# The upload leg: past the old 100 MiB cap and not a multiple of LinkUpload's 192 KiB chunk.
UPLOAD_BYTES = (150 << 20) + 12_345
UPLOAD_NAME = "cmux-upload-probe.bin"


def redact(text):
    """A pairing code's token (a link's `t=`, a `pairToken`) never reaches a log or the artifact."""
    return re.sub(r'((?<!\w)t=|pair_?token"?\s*[:=]\s*"?)[A-Za-z0-9_-]+', r"\1<redacted>", text, flags=re.I)


def auto_pairs(phone_bundle, mac_tag):
    """Whether this ref's tagged Mac pairs the phone by itself: it has the dev auto-approve
    (IPhoneDevAutoApprove) and the phone app is its own tag's (`dev.cmux.mobile.<tag>`)."""
    path = os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextMobileHost/IPhoneDevAutoApprove.swift")
    return os.path.exists(path) and phone_bundle.lower() == f"dev.cmux.mobile.{mac_tag}".lower()


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


def mac_workspace(app, sock, home):
    """A terminal workspace on the Mac, made by its bundled CLI (`cmux workspace create`, as
    relaunch_restore_check does): "created <id8>, terminal <id8>", or why not."""
    cli = os.path.join(app, "Contents/Resources/bin/cmux")
    env = {"HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_PATH": sock, "CMUX_QUIET": "1"}
    # The app starts its terminal daemon with TMPDIR set to the user's Darwin temp folder
    # (DaemonLauncher.userTemporaryDirectory), so its socket is TEMP/cmux-tui-UID/SESSION.sock. Without the same
    # TMPDIR the CLI looked under /tmp and found "no cmux session is running" (run 45551555308).
    try:
        temp = subprocess.run(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True,
                              stdin=subprocess.DEVNULL, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        temp = ""
    if temp:
        env["TMPDIR"] = temp
    try:
        done = subprocess.run([cli, "--json", "--app-socket", sock, "workspace", "create", "--name", "pair-e2e"],
                              env=env, cwd=home, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=60)
        lines = [line for line in done.stdout.splitlines() if line.strip()]
        made = json.loads(lines[-1]) if lines else {}
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        return f"NOT created ({type(error).__name__})"
    made = made.get("result", made) if isinstance(made, dict) else {}
    ws, term = (made.get("workspace_id"), made.get("terminal_id")) if isinstance(made, dict) else (None, None)
    if not ws:
        return f"NOT created (exit {done.returncode}: {redact((done.stderr or done.stdout).strip())[-200:]})"
    return f"created {str(ws)[:8]}, terminal {str(term)[:8] if term else 'none'}"


def sha256(path):
    digest, total = hashlib.sha256(), 0
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            digest.update(chunk)
            total += len(chunk)
    return total, digest.hexdigest()


def phone_receipt_ids(path, nonce, mac_id, *, linked):
    """This launch's signed-in phone, focused on this Mac; optionally require its live paired link."""
    try:
        with open(path) as f:
            receipt = json.load(f)
    except (OSError, ValueError):
        return set()
    if receipt.get("nonce") != nonce or receipt.get("signed_in") is not True:
        return set()
    if not any(row.get("id") == mac_id and (not linked or row.get("linked") is True)
               for row in receipt.get("paired_macs", [])):
        return set()
    return {value.lower() for value in receipt.get("phone_device_ids", []) if value}


def connected_phone(card, ids):
    return any(row.get("id", "").lower() in ids and row.get("paired") is True and row.get("connected") is True
               for row in card.get("phones", []))


def signin_session():
    """The step's own agent session ({email, project, refresh_token}) from `cmux-ci run --sign-in agent`
    (CMUX_CI_SIGNIN_FILE), with the checks of scripts/lib/fleet-signin-session.sh; None when the step has
    none. A file that fails them stops the run with the reason, never a value."""
    path = os.environ.get("CMUX_CI_SIGNIN_FILE", "")
    if not path:
        return None
    try:
        info = os.lstat(path)
    except OSError:
        info = None
    if info is None or not stat.S_ISREG(info.st_mode):
        raise SystemExit("the sign-in session file is not a regular file")
    if stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
        raise SystemExit(f"the sign-in session file must be this user's, mode 0600 "
                         f"(it is {info.st_uid}, {stat.S_IMODE(info.st_mode):o})")
    try:
        with open(path) as f:
            doc = json.load(f)
    except (OSError, ValueError):
        doc = None
    keys = ("email", "project", "refresh_token")
    values = {k: str(doc.get(k, "")) for k in keys} if isinstance(doc, dict) else {}
    if (not values or doc.get("profile") != "agent" or "@" not in values["email"] or not values["project"]
            or not values["refresh_token"] or any("\n" in v or "\r" in v for v in values.values())):
        raise SystemExit("the sign-in session file is not an agent session (profile, email, project, refresh_token)")
    return values


def dev_credential():
    """The DEBUG dev account: {email, password} from the environment (`CMUX_UITEST_STACK_EMAIL` /
    `CMUX_UITEST_STACK_PASSWORD`, the names the app reads), else from the CI auth profile
    (`~/.secrets/cmuxterm-dev.env`, which ios-e2e.yml materializes from the existing dogfood secrets
    under those same names), else the step's own agent session ({email, project, refresh_token},
    signin_session); the source holds no credential."""
    keys = ("CMUX_UITEST_STACK_EMAIL", "CMUX_UITEST_STACK_PASSWORD")
    found = {k: os.environ.get(k, "") for k in keys}
    profile = os.path.expanduser("~/.secrets/cmuxterm-dev.env")
    if not all(found.values()) and os.path.isfile(profile):
        for line in open(profile):
            k, sep, v = line.rstrip("\n").partition("=")
            if sep and k in keys and not found[k]:
                found[k] = v
    if all(found.values()):
        return {"email": found[keys[0]], "password": found[keys[1]]}
    session = signin_session()
    if session:
        return session
    raise SystemExit("DEBUG dev credential: set CMUX_UITEST_STACK_EMAIL and CMUX_UITEST_STACK_PASSWORD "
                     "(or provide ~/.secrets/cmuxterm-dev.env), or send the step with cmux-ci run --sign-in agent")


def mac_token_store(app, bundle, exe, env, project, home):
    """The tagged Mac app's own token store file for `project` (FileStackTokenStore's credentials.json in
    CloudConfiguration.credentialsDirectory under `home`, the app's FileManager home). The app is signed ad
    hoc (no_data_protection_keychain) and the rig's keychain holds no item of its bundle, so it restores its
    session from this file. The folder's namespace is the Cloud selection the app itself reads at launch
    (its bundled `cmux --json cloud env get`, asked here with the app's own environment and arguments); the
    folder is under the tag's `cmux-next/<bundle>` or `cmux/<bundle>`, which forget_tag removes."""
    cli = os.path.join(app, "Contents/Resources/bin/cmux")
    try:
        got = subprocess.run([cli, "--json", "cloud", "env", "get", "--cache-first", "--launch-args", json.dumps([exe])],
                             env=dict(env, CMUX_BUNDLE_ID=bundle), capture_output=True, text=True,
                             stdin=subprocess.DEVNULL, timeout=60)
        selection = json.loads(got.stdout) if got.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit(f"the Mac app's Cloud selection: {type(error).__name__}") from None
    if not isinstance(selection, dict):
        raise SystemExit(f"the Mac app's Cloud selection: cmux cloud env get exited {got.returncode}: "
                         f"{redact(got.stderr.strip())[-300:]}")
    if selection.get("bundle_id") != bundle:
        raise SystemExit("the Mac app's Cloud selection belongs to another bundle")
    if selection.get("stack_project_id") != project:
        raise SystemExit("the sign-in session is for another Stack project than the Mac app's Cloud selection "
                         f"({selection.get('name')!r}): the Mac could not use it")
    namespace = selection.get("auth_storage_namespace") if selection.get("legacy_storage") else selection.get("auth_namespace")
    parts = [home, "Library", "Application Support", "cmux-next" if namespace else "cmux", bundle]
    return os.path.join(*parts, *([namespace] if namespace else []), "credentials.json")


def write_mac_session(path, refresh_token):
    """The session's refresh token in the Mac app's token store file (0600 in a 0700 folder), as the app
    writes it; the app trades it for an access token at launch."""
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump({"refreshToken": refresh_token}, f)


def mac_session_refreshed(path):
    """Whether the Mac app has written an access token beside the refresh token it was given (it signed
    in from the session); reads the file, prints nothing of it."""
    try:
        with open(path) as f:
            return bool(json.load(f).get("accessToken"))
    except (OSError, ValueError, AttributeError):
        return False


def machine_id(bundle_id):
    """This app's own machine id (mac.py rig_machine_id): the phone lists it apart from other builds here."""
    out = subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True).stdout
    uuid = re.search(r'"IOPlatformUUID"\s*=\s*"([0-9A-Fa-f-]+)"', out).group(1).upper()
    return hashlib.sha256(f"cmux-rig-machine-id v1\0{uuid}\0{bundle_id}".encode()).hexdigest()[:32]


class Stream:
    """A child of this script (a `log stream`, or the Mac app itself): its output lines (token redacted
    as they are written, so an interrupted run leaves none on disk) go to `path`; wait() is woken per line."""

    def __init__(self, argv, path, env=None):
        self.lines, self.times, self.cond = [], [], threading.Condition()
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
                self.times.append(time.monotonic())
                self.cond.notify_all()

    def wait(self, pattern, timeout):
        hit = self.wait_at(pattern, timeout)
        return hit[1] if hit else None

    def wait_at(self, pattern, timeout, since=0.0):
        """(the monotonic time its line arrived, the match) of the first line at or after `since`."""
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                for at, line in zip(self.times, self.lines):
                    if at >= since and (m := pattern.search(line)):
                        return at, m
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


class ShareChecks:
    steps = ("iPhone tapped Share on the rig Mac",
             "Mac admitted the iPhone approval with the app closed and standing consent off",
             "iPhone received a frame from the rig Mac",
             "iPhone click landed on the rig Mac")

    def __init__(self, note):
        self.note = note
        self.count = 0
        self.incomplete = "pairing or rig setup did not finish"

    @property
    def passed(self):
        return self.count == len(self.steps)

    def pass_step(self):
        self.note(f"- PASS {self.steps[self.count]}")
        self.count += 1

    def finish(self):
        for i, step in enumerate(self.steps[self.count:]):
            reason = self.incomplete if i == 0 else "preceding share check did not pass"
            self.note(f"- FAIL {step} ({reason})")


def main():
    ap = argparse.ArgumentParser()
    for flag in ("--mac-app", "--ios-app", "--sims", "--udid", "--bundle-id", "--work", "--out", "--summary"):
        ap.add_argument(flag, required=True)
    # The upload leg's shape (cmux-next-ios-sim.sh pair-e2e's upload words): a size other than the gate's
    # sparse ~150 MB, random bytes (a real video's), the phone's relay-only or UDP-blocked link, a longer wait.
    ap.add_argument("--upload-bytes", type=int, default=UPLOAD_BYTES)
    ap.add_argument("--upload-random", action="store_true")
    ap.add_argument("--upload-relay-only", action="store_true")
    ap.add_argument("--upload-block-udp", action="store_true")
    ap.add_argument("--upload-wait", type=int, default=300)
    a = ap.parse_args()

    def note(line):
        print(line, flush=True)
        with open(a.summary, "a") as f:
            f.write(line + "\n")

    share = ShareChecks(note)
    try:
        return run_pair(a, note, share)
    finally:
        share.finish()


def run_pair(a, note, share):
    proof_path = os.environ.get("CMUX_IOS_CLOUD_PROOF_FILE")
    proof = read_proof(proof_path, artifact_root=a.out) if proof_path else None
    cloud_ok = proof is None
    screens = os.path.join(a.out, "screens")
    os.makedirs(screens, exist_ok=True)

    # ---- the Mac app ------------------------------------------------------
    mac_bundle, tag, ls_env = step_tag(a.mac_app)
    # Read before anything is written, so nothing it decides leaves state behind.
    pairs = auto_pairs(a.bundle_id, tag)
    note(f"- pairing: {'the Mac' + chr(39) + 's dev auto-approve, phone ' + a.bundle_id + ' of its tag' if pairs else 'NO dev auto-approve for phone ' + a.bundle_id + ' on this ref (FAIL)'}")
    no_data_protection_keychain(a.mac_app)
    sock = ls_env.get("CMUX_SOCKET_PATH") or f"/tmp/cmux-debug-{tag}.sock"
    # The app's Application Support is the account's home (NSHomeDirectory), not a step's $HOME.
    support = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, "Library/Application Support", mac_bundle)
    rig = os.path.join(a.work, "pair-rig")  # written only once cleanup is armed (below)
    config = os.path.join(rig, "cmux-next.json")
    account = dev_credential()
    email = account["email"]
    probe = has_upload_probe()
    # The upload leg's Mac folder: a Chat Folder (agents.chats.roots), which hostd shares
    # (CMUX_MOBILE_FILE_ROOTS), so an upload with it as `cwd` lands in its .cmux/attachments.
    upload_root = os.path.join(os.path.realpath(a.work), "pair-rig", "upload-root")
    creds = os.path.join(rig, "dev-auth.env")  # written once cleanup is armed (below)
    # Launched by its binary (its PID is this script's child), with the environment `open`
    # would give it (LSEnvironment) plus the rig's settings. An empty seed trusts no phone.
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
    env.update(ls_env)
    env.pop("ACPMUX_SOCKET", None)
    # The Mac's ShareHostDevice finds the daemon channel from its build identity
    # and the account home, independently of HOME or ACPMUX_HOME.
    env["ACPMUX_HOME"] = build_names.names(mac_bundle, tag, pwd.getpwuid(os.getuid()).pw_dir)["acpmux_home"]
    env["CMUX_NEXT_ENROLL_ON_SIGN_IN"] = "1"
    env.update(CMUX_NEXT_CONFIG_FILE=config, CMUX_AUTH_CREDENTIALS_FILE=creds, CMUX_NEXT_IPHONE_PAIRING_SEED="",
               CMUX_NEXT_MOBILE_MACHINE_ID=machine_id(mac_bundle), CMUX_NEXT_NO_ACTIVATE="1",
               # The name phones list this Mac by (DEBUG override): the dev account lists 100+ Macs
               # by name, and this one sorts first, so the Devices captures show its row on top
               # (step 423a0bae's showed only other Macs) and name no host.
               CMUX_NEXT_MOBILE_DEVICE_NAME=RIG_MAC_NAME,
               CMUX_NEXT_SOCKET_MODE="automation")
    # The theme-file leg's folder: `themes/` beside the rig's cmux-next.json (ThemeFileSetting).
    themes_dir = os.path.join(rig, "themes")

    def rpc(method, params=None, timeout=30):
        return review_mac.rpc(sock, method, params, timeout)

    last = {}

    def status():
        """Settings' `iphone` card (review_mac.py status), opening a hidden Settings page while none
        answers, with `connectedPhones`: its phones paired and connected."""
        card = dict(review_mac.status(sock))
        if card:
            phones = [p for p in (card.get("phones") or []) if isinstance(p, dict)]
            card["connectedPhones"] = sum(1 for p in phones if p.get("paired") is True and p.get("connected") is True)
            card["host"] = {"pending": card.get("pending") or []}
            if card.get("phase") != last.get("phase"):
                print(f"Mac iPhone card: {card.get('phase')}", flush=True)
            last.clear()
            last.update(card)
        return card

    def mac_shot(name):
        """The Mac's Settings page as rendered (it shows no code or token since #48532)."""
        r = rpc("debug.page", {"page": PAGE, "action": "snapshot", "path": os.path.join(screens, f"{name}.png")})
        return f"screens/{name}.png" if r.get("path") else f"no snapshot ({r.get('error')})"

    simctl = ["xcrun", "simctl"] + (["--set", a.sims] if a.sims else [])
    if "password" in account:
        phone_env = dict(os.environ, SIMCTL_CHILD_CMUX_MOBILE_STACK_EMAIL=email,
                         SIMCTL_CHILD_CMUX_MOBILE_STACK_PASSWORD=account["password"])
    else:
        # The step's session (handoff mode's launch): the DEBUG app adopts it while it holds no session.
        phone_env = dict(os.environ, SIMCTL_CHILD_CMUX_MOBILE_STACK_REFRESH_TOKEN=account["refresh_token"])

    def phone_launch():
        """cmux on iPhone on Settings > Devices, signed in to the dev account (DEBUG launch environment)."""
        nonce = secrets.token_hex(16)
        subprocess.run(simctl + ["terminate", a.udid, a.bundle_id], capture_output=True, timeout=60)
        subprocess.run(simctl + ["launch", a.udid, a.bundle_id, "-cmux-mobile-settings-page", "devices"],
                       env=dict(phone_env, SIMCTL_CHILD_CMUX_DOGFOOD_READINESS_NONCE=nonce),
                       check=True, capture_output=True, timeout=60)
        return nonce

    def phone_shot(name):
        subprocess.run(simctl + ["io", a.udid, "screenshot", os.path.join(screens, f"{name}.png")], capture_output=True)
        return f"screens/{name}.png"

    def phone_settled(timeout=20.0):
        """Until the phone's screen holds still (3 screenshots in a row the same, 0.5 s apart): the Devices list
        loads from the service after live data starts. Best effort: past TIMEOUT it notes it and goes on."""
        probe = os.path.join(screens, ".settle-probe.png")
        deadline, last, same = time.monotonic() + timeout, None, 0
        try:
            while time.monotonic() < deadline:
                subprocess.run(simctl + ["io", a.udid, "screenshot", probe], capture_output=True)
                try:
                    digest = hashlib.sha256(open(probe, "rb").read()).hexdigest()
                except OSError:
                    digest = None
                same = same + 1 if digest is not None and digest == last else 0
                if same >= 2:
                    return True
                last = digest
                time.sleep(0.5)
            note(f"- phone: the screen never held still in {timeout:.0f} s; capturing it as it is")
            return False
        finally:
            try:
                os.remove(probe)
            except OSError:
                pass

    host = TaggedShareHost(a.mac_app, env)
    teardown = TagTeardown(a.mac_app, acpmux_home=env["ACPMUX_HOME"])
    teardown.install()
    streams, app, paired, mac_id, uploaded, theme_ok = [], None, False, None, not probe, True
    # The discovery leg: the phone's Allow request reaches the running Mac in seconds, and a Mac
    # restart with a second identity key beside its Keychain key heals with no action on the phone.
    # CMUX_PAIR_E2E_DISCOVERY=0 leaves it out (a ref before it).
    discovery = os.environ.get("CMUX_PAIR_E2E_DISCOVERY") != "0"
    connect_runs = connect_timeline_runs()
    if connect_runs:
        note(f"- connect timeline: {connect_runs} runs per profile and launch; foreground after "
             f"{connect_timeline_aways()} s away, {connect_timeline_away_runs(connect_runs)} runs each "
             f"(the commit's Connect-Timeline-Runs / -Away / -Away-Runs)")
    ask_ok = restart_ok = not discovery
    keychain = RigKeychain(a.mac_app)
    quit_for_share = False
    try:
        note(f"- Keychain: {keychain.start()}")
        os.makedirs(rig, mode=0o700, exist_ok=True)
        # The Mac's look comes from a theme file the theme-file leg saves over (theme A at launch).
        settings = {"mobile": {"allowIPhoneConnections": True}, "appearance": {"themeFile": THEME_FILE_NAME},
                    "macScreen": {"shareWithoutAsking": False}}
        os.makedirs(themes_dir, mode=0o700, exist_ok=True)
        write_theme_file(themes_dir, theme_file_text(THEME_FILE_LOOKS[0]))
        if probe:
            os.makedirs(upload_root, mode=0o700)
            settings["agents"] = {"chats": {"roots": [upload_root]}}
        with open(config, "w") as f:
            json.dump(settings, f)
        # With a session, the explicit file names no account: the app signs in from no file (not even the
        # account home's ambient ones) and restores the session put in its token store below.
        with os.fdopen(os.open(creds, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
            if "password" in account:
                f.write(f"CMUX_UITEST_STACK_EMAIL={email}\nCMUX_UITEST_STACK_PASSWORD={account['password']}\n")
        if os.path.exists(sock):
            os.unlink(sock)  # this run's own tag
        plist = plistlib.load(open(os.path.join(a.mac_app, "Contents/Info.plist"), "rb"))
        exe = os.path.join(a.mac_app, "Contents/MacOS", plist["CFBundleExecutable"])
        if "refresh_token" in account:
            store = mac_token_store(a.mac_app, mac_bundle, exe, env, account["project"],
                                    pwd.getpwuid(os.getuid()).pw_dir)
            write_mac_session(store, account["refresh_token"])
            note("- account: the step's agent session (cmux-ci run --sign-in agent), on the Mac and the phone")

        def start_mac(launch_env, suffix=""):
            nonlocal app
            app_out = Stream([exe], os.path.join(a.out, f"mac-app{suffix}.log"), env=launch_env)
            streams.append(app_out)
            app = app_out.proc
            predicate = (f'processID == {app.pid} AND subsystem == "com.cmuxterm.app.next" '
                         'AND category BEGINSWITH "app.iphone"')
            log = Stream(["/usr/bin/log", "stream", "--level", "info", "--style", "compact", "--predicate", predicate],
                         os.path.join(a.out, f"mac-pairing{suffix}.log"))
            streams.append(log)
            return log

        mac_log = start_mac(dict(env, CMUX_NEXT_IPHONE_APPROVE_FIRST="1") if discovery else env)
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
        if "refresh_token" in account:
            # Evidence only (the pairing page's own wait judges the run): a Keychain write would empty the file.
            refreshed = wait_for(lambda: mac_session_refreshed(store), 30, every=2)
            note(f"- Mac session: {'an access token from the step session in its token store file' if refreshed else 'no access token in its token store file in 30 s'}")
        # Signed in, hostd online, iPhone connections on: the card has the Mac's device id, the id the
        # phone is told to focus (review.sh's mac-id). A card still without one at 60 s is sampled once.
        deadline = time.monotonic() + 300
        mac_id = wait_for(lambda: status().get("device_id"), 60, every=2)
        if not mac_id:
            try:  # evidence only: a failure here never replaces the run's own verdict
                why = preparing_evidence(app, a.out, deadline)
            except Exception as error:  # noqa: BLE001
                why = f"no evidence ({type(error).__name__}: {redact(str(error))[:200]})"
            try:
                note(f"- Mac iPhone card: still {last.get('phase') or 'without a status'} at "
                     f"{time.monotonic() - t0:.0f} s; {why}")
            except OSError:
                pass
            left = deadline - time.monotonic()
            mac_id = wait_for(lambda: status().get("device_id"), left, every=2) if left > 0 else None
        note(f"- Mac iPhone card: phase {last.get('phase')}, "
             f"{'device id ' + mac_id[:8] if mac_id else 'NO device id (FAIL)'} in {time.monotonic() - t0:.0f} s; "
             f"{mac_shot('mac-settings')}")
        if not mac_id:
            raise SystemExit("FAIL pairing: the Mac never registered its iPhone host")
        phone_env["SIMCTL_CHILD_CMUX_MOBILE_FOCUS_MAC"] = mac_id

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
        receipt = os.path.join(data, "Library/Application Support/cmux-dogfood/readiness.json")
        asked_from = time.monotonic()
        opened_at = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 1))
        nonce = phone_launch()
        live = phone_log.wait(re.compile(r"live data on"), 90)
        if discovery:
            ids = wait_for(lambda: phone_receipt_ids(receipt, nonce, mac_id, linked=False), 60)
            ask_ok = discovery_ask(mac_log, phone_log, asked_from, ids, status, rpc, note)
        phone_settled()
        note(f"- phone: {'signed in, live data' if live else 'NO live data in 90 s'}; Settings > Devices "
             f"{phone_shot('phone-devices')}")

        if discovery:
            # The first launch specifically asked the Mac to wait for Allow. Start its ordinary
            # tagged build to pair, before any screen-sharing action, then redial from the phone.
            app.terminate()
            try:
                app.wait(30)
            except subprocess.TimeoutExpired:
                app.kill()
                app.wait(15)
            mac_log = start_mac(env, "-pair")
            if not wait_for(lambda: status().get("device_id") == mac_id, 120):
                raise SystemExit("FAIL pairing: the restarted Mac did not register the same device id")
            asked_from = time.monotonic()
            opened_at = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(time.time() - 1))
            nonce = phone_launch()
        # A new tag's Mac opens with no workspace, so the phone's live-terminal and live-attach
        # demos found "no terminal" (run 45538405955): one terminal workspace for them to open.
        note(f"- Mac terminal workspace: {mac_workspace(a.mac_app, sock, pwd.getpwuid(os.getuid()).pw_dir)}")

        ids, connected, pair_line = set(), False, None
        if pairs:
            # The phone's launch named the Mac to focus: its dial asks, and the dev auto-approve answers.
            pair_line = mac_log.wait_at(PAIRED, 180, since=asked_from)
            pair_line = pair_line[1] if pair_line else None
            if not pair_line:  # the stream may have missed it: the store keeps info lines a while
                pairing_logs = (f'processID == {app.pid} AND subsystem == "com.cmuxterm.app.next" '
                                'AND category BEGINSWITH "app.iphone"')
                pair_line = PAIRED.search(subprocess.run(["/usr/bin/log", "show", "--info", "--start", opened_at, "--style",
                                                          "compact", "--predicate", pairing_logs],
                                                         capture_output=True, text=True).stdout)
            ids = wait_for(lambda: phone_receipt_ids(receipt, nonce, mac_id, linked=True), 180) or set()
            connected = bool(ids and wait_for(lambda: connected_phone(status(), ids), 60, every=2))
        took = time.monotonic() - asked_from
        paired = bool(pair_line and connected)
        note(f"- {'PASS' if paired else 'FAIL'} pairing: "
             f"{'phone ' + pair_line.group(1) + ' by the dev auto-approve' if pair_line else 'NO dev auto-approve line'} "
             f"({took:.0f} s after the phone's launch, no seed); phone reports linked to the rig Mac: {bool(ids)}; "
             f"Mac lists that phone paired and connected: {connected}; "
             f"phone {phone_shot('phone-paired')}; Mac {mac_shot('mac-pairing-paired')}")
        if not paired:
            share.incomplete = "this iPhone did not pair and connect to the rig Mac"
        if paired:
            nonce = phone_launch()
            phone_log.wait(re.compile(r"live data on"), 60)
            phone_settled()  # the Devices list loads from the service after live data starts
            note(f"- phone Settings > Devices after pairing: {phone_shot('phone-devices-paired')}")
        if paired and connect_runs:
            # A measurement run (the commit's Connect-Timeline-Runs trailer): only the connect
            # leg; the theme, upload and restart legs are left to the ordinary pair-e2e runs.
            theme_ok, uploaded, ask_ok, restart_ok = True, True, True, True
            theme_ok = connect_timeline_leg(simctl, a.udid, a.bundle_id, phone_env, phone_log, connect_runs,
                                            a.out, note)
        elif paired:
            try:
                theme_ok = theme_file_leg(simctl, a.udid, a.bundle_id, phone_env, phone_log, mac_log, phone_shot,
                                          rpc, screens, themes_dir, support, a.out, note)
            except Exception as error:  # noqa: BLE001  the leg fails; the legs after it still run
                theme_ok = False
                note(f"- theme-file repaint: FAIL ({type(error).__name__}: {redact(str(error))[:300]})")
        if paired and probe and not connect_runs:
            # The phone lists this Mac by the rig's device name (CMUX_NEXT_MOBILE_DEVICE_NAME): the
            # probe waits for a link to that name.
            uploaded, line = upload_leg(simctl, a.udid, a.bundle_id, phone_env, upload_root, RIG_MAC_NAME,
                                        size=a.upload_bytes, random_bytes=a.upload_random, wait=a.upload_wait,
                                        relay_only=a.upload_relay_only, block_udp=a.upload_block_udp)
            note(f"- upload: {line}")
        if discovery and paired and not connect_runs:  # last: it quits and restarts the Mac
            app, restart_ok = discovery_restart(app, exe, env, a.out, support, status, ids, phone_log, streams,
                                                phone_shot, note)
        note(f"- scanner sheet: {scanner(a.udid, phone_shot)}")
        if proof is not None:
            if not paired:
                raise SystemExit("Cloud UI proof requires the phone to pair and connect")
            run_cloud_leg(proof, root=ROOT, mac_env=env, email=email, rpc=rpc, phone_log=phone_log,
                          simctl=simctl, udid=a.udid, bundle=a.bundle_id, phone_env=phone_env,
                          rig_name=RIG_MAC_NAME, work=a.work, out=a.out,
                          shot=phone_shot, note=note)
            cloud_ok = True

        if paired:
            try:
                target = host.prepare()
                setting = rpc("settings.get", {"path": "macScreen.shareWithoutAsking"})
                if not share_without_asking_off(setting):
                    raise RuntimeError(f"the Mac did not report Share This Mac Without Asking off: {setting!r}")
                with PairInputProbe(rig) as probe_input:
                    share_env = dict(phone_env, SIMCTL_CHILD_CMUX_PAIR_E2E_SHARE_RECEIPT="1")
                    phone = PairSharePhone(simctl, a.udid, a.bundle_id, share_env,
                                           os.path.join(rig, "share-screens"), probe_input.ocr)
                    # Quit the exact tagged GUI before the phone opens Screen Sharing. From
                    # this point until the click receipt the host-side checks are read-only.
                    quit_for_share = True
                    rpc("action.run", {"action": "quitKeepSessions"})
                    app.wait(timeout=30)
                    cursor = host.detached_baseline()
                    launched = time.monotonic()
                    try:
                        phone.launch()
                    except RuntimeError as error:
                        # The row needs live data (ShellModel.attach): say whether this launch reached it.
                        raise RuntimeError(f"{error}; {launch_live_state(phone_log, launched)}") from error
                    before_tap = time.monotonic()
                    phone.request_share(target["deviceName"], target["deviceId"])
                    share.pass_step()
                    signed = phone_log.wait_at(re.compile(r"pair-e2e signed Share nonce digest ([0-9a-f]{64})"),
                                               30, since=before_tap)
                    if not signed:
                        raise RuntimeError("the simulator did not report signing this Share request")
                    host.admission(cursor, signed[1].group(1))
                    share.pass_step()
                    try:
                        phone.wait_frame(timeout=60, name=target["deviceName"])
                    except RuntimeError as error:
                        raise RuntimeError(f"{error}; {host.summary()}; {host.share_log()}; "
                                           f"phone: {viewer_log(phone_log.lines)}") from error
                    share.pass_step()
                    probe_input.verify_click(phone.tap_center())
                    share.pass_step()
            except RuntimeError as error:
                # Host and phone adapters give fixed diagnostics, never command output or account data.
                share.incomplete = str(error)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                share.incomplete = f"share fixture failed ({type(error).__name__})"
    finally:
        if quit_for_share and app.poll() is not None:
            # Restore the original app solely to run its ordinary sign-out after the proof.
            try:
                start_mac(env, "-signout")
                wait_for(lambda: "error" not in rpc("debug.focus", timeout=2), 45)
            except (OSError, subprocess.SubprocessError) as error:
                note(f"- sign-out relaunch failed ({type(error).__name__})")
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
            try:
                collect(support, a.out, note)
            finally:
                try:
                    host.leave()
                except RuntimeError as error:
                    # A failed revoke leaves a staging enrollment behind; say so, keep the share result.
                    note(f"- share host leave: {error}")
                finally:
                    teardown.end()
                    shutil.rmtree(rig, ignore_errors=True)  # the settings and credential files
        finally:  # the account's keychains are put back even when a step above fails
            forget_tag(a.mac_app)  # cmux-next-ios-sim.sh's EXIT runs it again for a rig cut short
        if proof is not None:
            # The public archive is an allowlist in Cloud mode. Raw screenshots,
            # pairing/app logs and failure captures remain unavailable to upload.
            allowlist_public_cloud_artifact(a.out)
    if discovery:
        note(f"- discovery: Allow request {'PASS' if ask_ok else 'FAIL'}, restart with a split identity "
             f"{'PASS' if restart_ok else 'FAIL'}")
    return 0 if paired and uploaded and theme_ok and cloud_ok and ask_ok and restart_ok and share.passed else 1


LIVE_DATA_LINE = re.compile(r"live data on ")
STACK_LINE = re.compile(r"Stack project ")


def launch_live_state(phone_log, since):
    """Whether the phone, since `since`, logged its sign-in config and its live data (fixed text)."""
    def seen(pattern):
        hit = phone_log.wait_at(pattern, 0, since=since)
        return f"after {hit[0] - since:.0f} s" if hit else "not logged"
    return f"phone since launch: auth config {seen(STACK_LINE)}, live data {seen(LIVE_DATA_LINE)}"


# The connect-timeline leg (RFD 0049's connect rows): the paired phone's own ConnectTimeline marks
# (`timing <attempt> <step> +<ms> (...)`, CmuxMobileModel/ConnectTimeline.swift), per launch and per
# foreground after CONNECT_AWAY seconds in the background, on the direct path ("lan": phone and Mac on
# this one Mac) and forced onto TURN ("relay": -cmuxMobile.dev.relayOnly YES, the Developer toggle).
# A measurement run asks for it with a trailer on the commit under test, since the fleet passes
# pair-e2e no arguments and no environment:  Connect-Timeline-Runs: 20  (1-30).
CONNECT_STEPS = ("dial_start", "link_connected", "first_daemon_response", "workspaces_live")
# Fresh after a foreground: the tree arrived again, or the kept link answered (its list is current).
CONNECT_FRESH = ("workspaces_live", "link_alive", "link_standby_promoted", "link_adopted")
CONNECT_AWAY = 60  # the default away time; `Connect-Timeline-Away: 60,300,600` (seconds, 1-1800) asks for more
CONNECT_BOUND = 30  # seconds one attempt may take before it counts as a miss
TIMING = re.compile(r"timing (\w+) (\w+) \+(\d+)ms(?: \(\d+ms\))? ?(.*)$")


def commit_trailer(key):
    """A trailer of the commit under test ('' when it has none)."""
    try:
        return subprocess.run(["git", "-C", ROOT, "log", "-1", f"--format=%(trailers:key={key},valueonly)"],
                              capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def connect_timeline_runs():
    """The commit's Connect-Timeline-Runs trailer (1-30), else 0: the leg is off."""
    got = commit_trailer("Connect-Timeline-Runs")
    return int(got) if got.isdigit() and 1 <= int(got) <= 30 else 0


def connect_timeline_profiles():
    """The commit's Connect-Timeline-Profiles trailer (lan, relay or both, comma-separated; default both),
    so two fleet steps can take one profile each at once."""
    got = [p.strip() for p in commit_trailer("Connect-Timeline-Profiles").split(",") if p.strip()]
    return [p for p in got if p in ("lan", "relay")] or ["lan", "relay"]


def connect_timeline_aways():
    """The commit's Connect-Timeline-Away trailer: away times in seconds (comma-separated, 1-1800; default 60)."""
    got = [p.strip() for p in commit_trailer("Connect-Timeline-Away").split(",") if p.strip()]
    return [int(p) for p in got if p.isdigit() and 1 <= int(p) <= 1800] or [CONNECT_AWAY]


def connect_timeline_away_runs(runs):
    """The commit's Connect-Timeline-Away-Runs trailer (1-30): foreground runs per away time, else `runs`.
    A 600 s away costs 10 minutes a run, so a long one is usually asked for with fewer runs."""
    got = commit_trailer("Connect-Timeline-Away-Runs")
    return int(got) if got.isdigit() and 1 <= int(got) <= 30 else runs


def connect_attempt(phone_log, attempt, since, wanted):
    """{step: ms since the attempt began} for one attempt, until one of `wanted` (or the bound)."""
    marks, details = {}, {}
    deadline = time.monotonic() + CONNECT_BOUND
    with phone_log.cond:
        while True:
            for at, line in zip(phone_log.times, phone_log.lines):
                if at < since:
                    continue
                m = TIMING.search(line.rstrip())
                if m and m.group(1) == attempt and m.group(2) not in marks:
                    marks[m.group(2)] = int(m.group(3))
                    details[m.group(2)] = m.group(4).strip()
            done = [w for w in wanted if w in marks]
            left = deadline - time.monotonic()
            if done or left <= 0:
                return marks, details, (done[0] if done else None)
            phone_log.cond.wait(left)


def connect_timeline_leg(simctl, udid, bundle_id, phone_env, phone_log, runs, out, note):
    """Launch and foreground-after-away connect times, per profile; True when every run ended."""
    rows, ok = [], True
    aways, away_runs = connect_timeline_aways(), connect_timeline_away_runs(runs)
    path = os.path.join(out, "connect-timeline.jsonl")
    profiles = [(p, a) for p, a in (("lan", []), ("relay", ["-" + "cmuxMobile.dev.relayOnly", "YES"]))
                if p in connect_timeline_profiles()]
    for profile, args in profiles:
        launch = simctl + ["launch", udid, bundle_id] + args
        # Launch: a new process each run; the marks count from the process start.
        for run in range(1, runs + 1):
            subprocess.run(simctl + ["terminate", udid, bundle_id], capture_output=True)
            time.sleep(1)
            since = time.monotonic()
            subprocess.run(launch, env=phone_env, capture_output=True)
            marks, details, end = connect_attempt(phone_log, "launch", since, ("workspaces_live",))
            rows.append({"profile": profile, "phase": "launch", "run": run, "end": end, "marks": marks,
                         "transport": details.get("dial_start", ""), "rtt": details.get("link_alive", "")})
        # Foreground after each away time: one process per away time, sent to the background by Settings and back.
        for away in aways:
            subprocess.run(simctl + ["terminate", udid, bundle_id], capture_output=True)
            since = time.monotonic()
            subprocess.run(launch, env=phone_env, capture_output=True)
            connect_attempt(phone_log, "launch", since, ("workspaces_live",))
            for run in range(1, away_runs + 1):
                subprocess.run(simctl + ["launch", udid, "com.apple.Preferences"], capture_output=True)
                time.sleep(away)
                since = time.monotonic()
                subprocess.run(simctl + ["launch", udid, bundle_id], env=phone_env, capture_output=True)
                marks, details, end = connect_attempt(phone_log, "foreground", since, CONNECT_FRESH)
                rows.append({"profile": profile, "phase": "foreground", "away": away, "run": run, "end": end,
                             "marks": marks, "transport": details.get("dial_start", ""),
                             "rtt": details.get("link_alive", "")})
        subprocess.run(simctl + ["terminate", udid, bundle_id], capture_output=True)
    with open(path, "w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
            print("CONNECTTIMELINE " + json.dumps(row), flush=True)
    note("")
    note("### Connect timeline (ms, p50 / p95, n = runs that reached the end mark)")
    note("")
    note("| profile | phase | interval | p50 | p95 | n |")
    note("| --- | --- | --- | --- | --- | --- |")
    for profile, _ in profiles:
        for phase, away in [("launch", None)] + [("foreground", w) for w in aways]:
            got = [r for r in rows if r["profile"] == profile and r["phase"] == phase and r.get("away") == away]
            label = phase if away is None else f"foreground after {away} s"
            done = [r for r in got if r["end"]]
            if len(done) < len(got):
                ok = False
            intervals = []
            if phase == "launch":
                prev = None
                for step in CONNECT_STEPS:
                    intervals.append((f"{prev or 'process start'} -> {step}",
                                      [r["marks"][step] - (r["marks"][prev] if prev else 0) for r in done
                                       if step in r["marks"] and (prev is None or prev in r["marks"])]))
                    prev = step
            else:
                for step in CONNECT_STEPS:
                    intervals.append((f"foreground -> {step}", [r["marks"][step] for r in done if step in r["marks"]]))
                intervals.append(("foreground -> fresh (first of " + ", ".join(CONNECT_FRESH) + ")",
                                  [r["marks"][r["end"]] for r in done]))
            if phase == "launch":
                intervals.append(("total: process start -> workspaces_live", [r["marks"]["workspaces_live"] for r in done]))
            for name, values in intervals:
                if values:
                    note(f"| {profile} | {label} | {name} | {percentile(values, 0.5):.0f} | {percentile(values, 0.95):.0f} | {len(values)} |")
                else:
                    note(f"| {profile} | {label} | {name} | - | - | 0 |")
            ends = {}
            for r in got:
                ends[r["end"] or "miss"] = ends.get(r["end"] or "miss", 0) + 1
            transports = sorted({r["transport"] for r in got if r["transport"]})
            note(f"| {profile} | {label} | end marks {ends}; transports {transports or ['none dialed']} | | | {len(got)} |")
    note("")
    return ok


ASKS = re.compile(r"phone (\w+) asks to pair: (\w+)")
LINK_REFUSED = re.compile(r"mac_identity_changed|bad_mac_proof")


# The theme-file leg: the rig's cmux-next.json names this theme file (`<rig>/themes/<name>.json`), and
# the leg saves looks A and B over it in turn. Each names a built-in Ghostty theme and its own terminal
# colors (`colors` edit that theme), foreground on background well over 4.5:1, so the contrast guard
# keeps them as written.
THEME_FILE_NAME = "pair-e2e"
THEME_FILE_LOOKS = [
    {"appearance.theme": "Nord", "colors": {"background": "#14233a", "foreground": "#e6edf5"}},
    {"appearance.theme": "Nord", "colors": {"background": "#3a1430", "foreground": "#f5e6ef"}},
]
THEME_FILE_SAMPLES = 10
THEME_FILE_WAIT = 30  # seconds for one save to reach the phone
THEME_FILE_HOLD = 5  # seconds a bad save must leave the phone's terminal as it was
PHONE_THEME = re.compile(r"terminal theme of .*background (#[0-9a-fA-F]{6})")


def theme_file_text(look):
    return json.dumps(look, indent=2) + "\n"


def write_theme_file(themes_dir, text):
    """Saves the active theme file as an editor's atomic save does: a new file renamed over it."""
    path = os.path.join(themes_dir, f"{THEME_FILE_NAME}.json")
    temp = path + ".saving"
    with open(temp, "w") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.replace(temp, path)


def percentile(values, fraction):
    """The median, or the nearest-rank percentile."""
    if fraction == 0.5:
        return statistics.median(values)
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1))]


def hostd_appearance_lines(support):
    """hostd's `published a changed appearance` lines: (UTC epoch seconds, terminal background, line)."""
    found = []
    for path in glob.glob(os.path.join(support, "**/cmux-mobile-host.log"), recursive=True):
        for line in open(path, errors="replace"):
            if "published a changed appearance" not in line:
                continue
            m = re.match(r"\s*(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z", line)
            bg = re.search(r"terminal_background=(\S+)", line)
            if not m:
                continue
            seconds = calendar.timegm(time.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S")) + float("0." + (m.group(2) or "0"))
            found.append((seconds, (bg.group(1) if bg else "none").strip('"').lower(), line))
    return sorted(found)


def terminal_share(bmp_path, colors, tolerance=12):
    """The share of a BMP screenshot's (sampled) pixels within `tolerance` of each `#rrggbb` color."""
    data = open(bmp_path, "rb").read()
    if data[:2] != b"BM":
        return None
    offset = int.from_bytes(data[10:14], "little")
    width = int.from_bytes(data[18:22], "little", signed=True)
    height = abs(int.from_bytes(data[22:26], "little", signed=True))
    bpp = int.from_bytes(data[28:30], "little")
    if bpp not in (24, 32) or width <= 0:
        return None
    step, row = bpp // 8, ((bpp * width + 31) // 32) * 4
    targets = [tuple(int(c[i:i + 2], 16) for i in (1, 3, 5)) for c in colors]
    hits, total = [0] * len(targets), 0
    for y in range(0, height, 6):
        base = offset + y * row
        for x in range(0, width, 6):
            p = base + x * step
            b, g, r = data[p], data[p + 1], data[p + 2]
            total += 1
            for i, (tr, tg, tb) in enumerate(targets):
                if abs(r - tr) <= tolerance and abs(g - tg) <= tolerance and abs(b - tb) <= tolerance:
                    hits[i] += 1
    return [h / total for h in hits] if total else None


def theme_file_leg(simctl, udid, bundle_id, phone_env, phone_log, mac_log, phone_shot, rpc, screens, themes_dir,
                   support, out, note):
    """A theme file saved on the Mac repaints the paired iPhone's terminal (the `appearance` channel):
    the phone opens the Mac's first terminal (DEBUG demo `live-terminal`), then the leg saves looks A
    and B in turn, each timed from the save to the phone's `terminal theme of ... background #hex`
    line, with the Mac's hand-off to hostd and hostd's publish as the hops between. Then a refused
    value and a half-written file: the phone keeps the last good background, and the Mac's notice
    names the file. Returns whether the leg passed."""
    ok = True
    since = time.monotonic()
    subprocess.run(simctl + ["terminate", udid, bundle_id], capture_output=True)
    subprocess.run(simctl + ["launch", udid, bundle_id, "-cmux-mobile-no-restore", "-cmux-mobile-demo", "live-terminal"],
                   env=phone_env, check=True, capture_output=True)
    shown = phone_log.wait_at(re.compile(r"demo step: live-terminal (shown|no \w+)"), 240, since=since)
    outcome = shown[1].group(1) if shown else "timed out"
    looks = THEME_FILE_LOOKS
    hexes = [look["colors"]["background"] for look in looks]
    first = phone_log.wait_at(re.compile(rf"terminal theme of .*background {hexes[0]}", re.I), THEME_FILE_WAIT, since=since)
    mac = rpc("debug.window_snapshot", {"path": os.path.join(screens, "theme-file-mac-window.png")}, timeout=60)
    mac_line = "screens/theme-file-mac-window.png" if isinstance(mac, dict) and not mac.get("error") else f"no Mac snapshot ({mac.get('error')})"
    note(f"- theme-file: phone live-terminal {outcome}; theme A ({hexes[0]}) on the phone "
         f"{'before the first save' if first else f'NOT seen in {THEME_FILE_WAIT} s'}; Mac {mac_line}")

    samples = []  # (index, hex, write->phone ms, write->Mac sent ms, write->hostd ms)
    current = 0
    for i in range(THEME_FILE_SAMPLES):
        current = (i + 1) % len(looks)
        target = hexes[current]
        mark = time.monotonic()
        t_write = time.time()
        write_theme_file(themes_dir, theme_file_text(looks[current]))
        hit = phone_log.wait_at(re.compile(rf"terminal theme of .*background {target}", re.I), THEME_FILE_WAIT, since=mark)
        if not hit:
            ok = False
            note(f"- theme-file sample {i + 1}: TIMEOUT, no phone terminal theme with background {target} in {THEME_FILE_WAIT} s")
            break
        t_phone = log_time(hit[1].string) or (time.time() - (time.monotonic() - hit[0]))
        sent = mac_log.wait_at(re.compile(rf"appearance to hostd: .*terminal background {target}", re.I), 5, since=mark)
        t_sent = log_time(sent[1].string) if sent else None
        samples.append([i + 1, target, (t_phone - t_write) * 1000, (t_sent - t_write) * 1000 if t_sent else None,
                        None, t_write])
    if samples and ok:
        shot = phone_shot("theme-file-phone")
        bmp = os.path.join(out, "theme-file-phone.bmp")
        subprocess.run(simctl + ["io", udid, "screenshot", "--type=bmp", bmp], capture_output=True)
        share = terminal_share(bmp, [hexes[current], hexes[1 - current]]) if os.path.isfile(bmp) else None
        if os.path.isfile(bmp):
            os.unlink(bmp)
        if share is None:
            note(f"- theme-file last screen: {shot}; background pixels not checked (no BMP screenshot)")
        else:
            matches = share[0] >= 0.05 and share[0] > share[1]
            ok = ok and matches
            note(f"- theme-file last screen: {shot}; {share[0]:.0%} of sampled pixels are {hexes[current]}, "
                 f"{share[1]:.0%} the other look's {hexes[1 - current]}: {'PASS' if matches else 'FAIL'}")

    # hostd's publish of each change (its own log, UTC, read once the samples are in).
    published = hostd_appearance_lines(support)
    with open(os.path.join(out, "hostd-appearance.log"), "w") as f:
        f.writelines(redact(line) for _, _, line in published)
    for sample in samples:
        hop = next((t for t, bg, _ in published if bg == sample[1].lower() and t >= sample[5] - 0.05), None)
        sample[4] = (hop - sample[5]) * 1000 if hop else None
    if samples:
        phone_ms = [s[2] for s in samples]
        note(f"- theme-file repaint: n={len(phone_ms)} min {min(phone_ms):.0f} ms, median "
             f"{percentile(phone_ms, 0.5):.0f} ms, p95 {percentile(phone_ms, 0.95):.0f} ms"
             f"{'' if ok and len(samples) == THEME_FILE_SAMPLES else ' (FAIL)'}")
        for name, column in (("Mac sent to hostd", 3), ("hostd published", 4)):
            values = [s[column] for s in samples if s[column] is not None]
            note(f"- theme-file hop, save to {name}: " + (
                f"n={len(values)} min {min(values):.0f} ms, median {percentile(values, 0.5):.0f} ms, p95 "
                f"{percentile(values, 0.95):.0f} ms" if values else "no timestamps read"))
        note("- theme-file samples (save to Mac sent / hostd published / phone, ms): " + "; ".join(
            f"{s[0]} {s[1]} {'-' if s[3] is None else f'{s[3]:.0f}'}/{'-' if s[4] is None else f'{s[4]:.0f}'}/{s[2]:.0f}"
            for s in samples))
    if not ok:
        return False

    # A refused value, then a half-written file: the phone keeps the last good background, and the
    # Mac's settings notice (its toast) names the theme file.
    good = hexes[current]
    other = re.compile(rf"terminal theme of .*background (?!{good})#[0-9a-fA-F]{{6}}", re.I)
    file_label = f"themes/{THEME_FILE_NAME}.json"
    bad = [("a refused appearance.accent \"purple\"", theme_file_text({**looks[current], "appearance.accent": "purple"})),
           ("a half-written file", theme_file_text(looks[current])[:20])]
    results, fallback_ok, seen = [], True, set()
    for what, text in bad:
        mark = time.monotonic()
        write_theme_file(themes_dir, text)
        toasts, deadline = set(), time.monotonic() + THEME_FILE_HOLD
        while time.monotonic() < deadline:
            reply = rpc("debug.toast", {}, timeout=5)
            for window in (reply.get("windows") or []) if isinstance(reply, dict) else []:
                for toast in window.get("toasts") or []:
                    if file_label in str(toast.get("message", "")):
                        toasts.add(str(toast.get("message")))
            time.sleep(0.5)
        moved = phone_log.wait_at(other, 0, since=mark)
        kept = moved is None
        named = sorted(toasts - seen)  # this save's own notice, not the one before still on screen
        seen |= toasts
        fallback_ok = fallback_ok and kept and bool(named)
        results.append(f"{what}: phone {'kept ' + good if kept else 'MOVED to ' + moved[1].group(0)[-7:]} for "
                       f"{THEME_FILE_HOLD} s; Mac notice {('names it: ' + repr(named[0][:160])) if named else 'NAMES NO FILE'}")
    write_theme_file(themes_dir, theme_file_text(looks[current]))  # the last good look again
    note(f"- theme-file fallback {'PASS' if fallback_ok else 'FAIL'}: " + "; ".join(results))
    return ok and fallback_ok


def log_time(line):
    """The time a compact `log stream` line was logged (both logs come from this host's clock)."""
    m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)", line)
    return time.mktime(time.strptime(m.group(1).split(".")[0], "%Y-%m-%d %H:%M:%S")) + float("0." + m.group(1).split(".")[1]) if m else None


def discovery_ask(mac_log, phone_log, since, ids, status, rpc, note):
    """Observe the unanswered Allow request from this launch's simulator phone."""
    if not ids:
        note("- discovery, Allow request: FAIL; no phone identity for this Mac in this launch's receipt")
        return False
    prefixes = "|".join(re.escape(device_id[:8]) for device_id in ids)
    ask = re.compile(rf"phone ({prefixes}) asks to pair:", re.I)
    hit = mac_log.wait_at(ask, 60, since=since)
    live = phone_log.wait_at(re.compile(r"live data on"), 0, since=since)
    m = hit[1] if hit else None
    # From the logged times, not when `log stream` delivered the lines (it lags by tens of seconds).
    asked_at = log_time(m.string) if m else None
    live_at = log_time(live[1].string) if live else None
    took = asked_at - live_at if asked_at is not None and live_at is not None else None
    pending = {row.get("id", "").lower() for row in status().get("pending", [])} & ids
    our_request = bool(m and any(device_id.startswith(m.group(1).lower()) for device_id in pending))
    dialogs = [dialog for dialog in rpc("debug.dialog").get("dialogs", [])
               if dialog.get("identifier") == review_mac.PAIR_DIALOG]
    # Preserve the discovery leg's check that the debugger cannot press a real Allow.
    refused = not dialogs or bool(rpc("debug.dialog", {"id": dialogs[0]["id"], "press": "allow"}).get("error"))
    ok = took is not None and 0 <= took <= 15 and our_request and refused
    scripted = ("refused" if refused else "accepted") if dialogs else "no on-screen dialog"
    note(f"- discovery, Allow request: {'PASS' if ok else 'FAIL'}; simulator phone waiting on the Mac: "
         f"{our_request}; time from live data to request: {f'{took:.1f} s' if took is not None else 'unknown'}; "
         f"scripted Allow: {scripted}")
    return ok


def host_state_directory(support):
    """The Mac's MobileHostStateDirectory: under the bundle's support folder, or under its account
    namespace's subfolder there (IPhoneHostService stateRoot/<storageNamespace>/cmux-mobile-host), as
    collect() finds paired-devices.json. The one holding paired-devices.json wins; None when absent."""
    found = [d for d in glob.glob(os.path.join(support, "**/cmux-mobile-host"), recursive=True) if os.path.isdir(d)]
    found.sort(key=lambda d: (not os.path.exists(os.path.join(d, "paired-devices.json")), d.count(os.sep), d))
    return found[0] if found else None


def discovery_restart(app, exe, env, out, support, status, ids, phone_log, streams, phone_shot, note):
    """The paired Mac quits; a second identity key is put in its fallback file (what a refused Keychain
    read used to mint) while the phone stays open; the Mac starts again. The phone reconnects by
    itself, the Mac keeps its Keychain key (no `mac_identity_changed`) and sets the file key aside."""
    state = host_state_directory(support)
    if state is None:
        note(f"- discovery, restart: no cmux-mobile-host state directory under {support} -> FAIL")
        return app, False
    app.terminate()  # the exact PID this script started
    try:
        app.wait(30)
    except subprocess.TimeoutExpired:
        app.kill()
        app.wait(15)
    planted = os.path.join(state, "mac-identity")
    with os.fdopen(os.open(planted, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb") as f:
        f.write(secrets.token_bytes(32))  # a P-256 private key's raw form: a second identity
    refused_before = len([l for l in phone_log.lines if LINK_REFUSED.search(l)])
    t = time.monotonic()
    restarted = Stream([exe], os.path.join(out, "mac-app-restart.log"), env=env)
    streams.append(restarted)
    connected = wait_for(lambda: connected_phone(status(), ids), 120, every=1)
    took = time.monotonic() - t
    refused = len([l for l in phone_log.lines if LINK_REFUSED.search(l)]) - refused_before
    aside = os.path.exists(planted + ".superseded") and not os.path.exists(planted)
    ok = bool(connected) and refused == 0 and aside
    note(f"- discovery, restart with a second identity key in the file: phone "
         f"{'reconnected %.0f s after the Mac started' % took if connected else 'NOT reconnected in 120 s'} "
         f"with no action on it; phone refusals mac_identity_changed/bad_mac_proof: {refused}; file key "
         f"{'set aside as mac-identity.superseded' if aside else 'NOT set aside'}; phone {phone_shot('phone-after-restart')}"
         f" -> {'PASS' if ok else 'FAIL'}")
    return restarted.proc, ok


def random_file(path, size):
    """`size` random bytes (incompressible, as a video is), written 1 MiB at a time."""
    with open(path, "wb") as f:
        left = size
        while left:
            f.write(os.urandom(min(left, 1 << 20)))
            left -= min(left, 1 << 20)


def upload_leg(simctl, udid, bundle_id, phone_env, root, mac_name, size=UPLOAD_BYTES, random_bytes=False, wait=300,
               relay_only=False, block_udp=False):
    """The phone streams a sparse ~150 MB file (or `size` random bytes) to the Mac with its own LinkUpload
    (UploadProbe, a DEBUG launch argument), over a relay-only or UDP-blocked link when asked (the app's
    developer options, as launch arguments); (passed, summary line). The stored file must match byte for byte."""
    data = subprocess.run(simctl + ["get_app_container", udid, bundle_id, "data"],
                          check=True, capture_output=True, text=True).stdout.strip()
    source = os.path.join(data, "tmp", UPLOAD_NAME)
    result_path = os.path.join(data, "Documents", "upload-probe.json")
    os.makedirs(os.path.dirname(source), exist_ok=True)
    if os.path.exists(result_path):
        os.unlink(result_path)
    (random_file if random_bytes else sparse_file)(source, size)
    try:
        want = sha256(source)
        args = ["-CmuxMobileUploadProbe", source, "-CmuxMobileUploadProbeCwd", root]
        if mac_name:
            args += ["-CmuxMobileUploadProbeMac", mac_name]
        if relay_only:
            args += ["-cmuxMobile.dev.relayOnly", "YES"]
        if block_udp:
            args += ["-cmuxMobile.dev.blockUDP", "YES"]
        subprocess.run(simctl + ["terminate", udid, bundle_id], capture_output=True)
        subprocess.run(simctl + ["launch", udid, bundle_id] + args, env=phone_env, check=True, capture_output=True)
        # Bounded wait on the app's own result file (no event reaches this script for it).
        if not wait_for(lambda: os.path.exists(result_path), wait, every=2):
            # How far it got: the bytes the Mac holds under the attachments folder (a partial file included).
            held = sum(os.path.getsize(p) for p in glob.glob(os.path.join(root, ".cmux", "**"), recursive=True)
                       if os.path.isfile(p))
            return False, (f"FAIL: no upload-probe.json in {wait} s (the probe waits for a served link to {mac_name!r}); "
                           f"the Mac holds {held:,} of {size:,} bytes under .cmux")
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
        "footprint grew < 1/5 of the file": grew < size // 5,
    }
    failed = [name for name, ok in checks.items() if not ok]
    return not failed, (f"{'PASSED' if not failed else 'FAIL: ' + ', '.join(failed)}; {size:,} {'random' if random_bytes else 'sparse'} bytes"
                        f"{', relay only' if relay_only else ''}{', UDP blocked' if block_udp else ''}, sha256 "
                        f"{want[1][:16]}..., in {took:.1f} s ({size / max(took, 1e-9) / 1e6:.2f} MB/s); stored at .../{os.path.relpath(stored, root)}; app footprint "
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
    tag_acpmux_home = build_names.names(bundle, tag, pwd.getpwuid(os.getuid()).pw_dir)["acpmux_home"]
    dirs, files = [tag_acpmux_home], [f"/tmp/cmux-reload-{tag}.log", f"/tmp/cmux-debug-{tag}.sock", f"/tmp/cmux-debug-{tag}.log",
                       f"/tmp/cmux-next-irx-journal-{tag}.jsonl", f"/tmp/cmux-dev-{slug}-last-socket-path"]
    sock = ls_env.get("CMUX_SOCKET_PATH", "")
    if tag in os.path.basename(sock):
        files.append(sock)
    for home in homes:
        support = os.path.join(home, "Library/Application Support")
        dirs += [os.path.join(support, bundle), os.path.join(support, "cmux", bundle),
                 os.path.join(support, "cmux-next/tags", tag), os.path.join(support, "cmux/tags", tag),
                 os.path.join(support, "cmux-next", safe),
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

    # The worker's rule (build-fleet console_session.go readConsoleUser): IOConsoleUsers' session on the console, not
    # scutil's ConsoleUser, which a Screen Sharing login to another account takes over (bench_launch.console_user).
    from bench_launch import console_user
    console = console_user()
    facts = (f"running {app.poll() is None}, account {pwd.getpwuid(os.getuid()).pw_name}, console user "
             f"{console or 'none'}, launchd {run(['/bin/launchctl', 'managername'], 10).strip()}, "
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
        return "not captured (axe is not installed on this host: scripts/install-axe-ci.sh)"
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
                  if re.search(r"pair|auth|link (up|down|path)|registered|signaling connected|upload", l)]
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
