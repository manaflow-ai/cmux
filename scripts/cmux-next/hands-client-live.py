#!/usr/bin/env python3
"""Live proof of the Mac app's Chief hands client against the staging Cloud API (cx-om025).

  scripts/cmux-next/hands-client-live.py --tag <tag> [--credentials-file <file>] [--app PATH] [--out DIR]
      [--api https://cloud-api-staging.cmux.dev]

GUI host only (cmux-lawrence-2 through `nx-remote --needs gui`), with a tagged DEV app. Every
process runs under a scratch HOME: the app (signed in as the owner) and one mac hand paired for the
same owner (installed with --no-service: no LaunchAgent; its `hand run` is this script's child).
The owner must be in staging's HANDS_MAC_OWNERS. The owner's credentials come from ONE source on
this host and are never printed, logged or written anywhere:
- --credentials-file: a mode-600 KEY=value file (CMUX_UITEST_STACK_EMAIL/_PASSWORD, or
  CMUX_DOGFOOD_STACK_*); the app reads the same file through CMUX_AUTH_CREDENTIALS_FILE;
- else HANDS_PROOF_EMAIL_REF and HANDS_PROOF_PASSWORD_REF: 1Password references (op://...) read
  with `op read`; the app gets the pair in its environment (CMUX_UITEST_STACK_*).

Checks, through the app's `debug.hands` and `debug.notifications` and the owner's own API reads:
 0. first launched with no registered Cloud install: a raise and an Allow say the Mac is not set up
    for Cloud (localized text, no internal error name), the banner comes back with that reason, and
    the request does not run; then the app is relaunched with the Cloud path on for 1-8;
 1. the app reads the paired hand (level auto, the mac default);
 2. presence key enroll (PUT /v1/hands/presence-key, signed by the install key), or, on a Mac with
    no Secure Enclave, the refusal;
 3. a lower (auto -> ask) is a plain PUT; the server then says ask;
 4. a raise whose challenge is signed by the install key, not the presence key, is refused
    (hand.level_refused) and the level stays ask;
 5. a raise through the app asks for presence: the prompt's reason names the hand and the new level;
    the script cancels it (no person on the host), the raise fails cancelled, the level stays ask;
 6. a request at ask (fs.write in the hand's root) appears as a banner through the wire event
    (hand-approval-pending), and Deny (the banner's button path) refuses it and removes it;
 7. Allow (install-key signature) lets the write run and removes the banner;
 8. a request that ends unanswered (the hand goes offline) is settled `expired` and removed.
Ends with the app quit, the tag's daemons stopped, the hand stopped by its own PID and removed
(DELETE /v1/hands/<hand>), and the owner's session signed out. Writes report.json.
"""
import argparse, glob, json, os, plistlib, shutil, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request, uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--credentials-file", help="mode-600 KEY=value file (CMUX_UITEST_STACK_EMAIL/_PASSWORD); "
                    "else HANDS_PROOF_EMAIL_REF and HANDS_PROOF_PASSWORD_REF (op:// refs)")
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="hands-client-"))
parser.add_argument("--api", default="https://cloud-api-staging.cmux.dev")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

STACK_API = "https://api.stack-auth.com/api/v1"
DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
DEV_STACK_CLIENT_KEY = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"hands-{opts.tag}-")
HOME = os.path.join(SCRATCH, "home")
HAND_HOME = os.path.join(SCRATCH, "hand")
ROOT = os.path.join(SCRATCH, "root")
for d in (HOME, HAND_HOME, ROOT):
    os.makedirs(d, mode=0o700)
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": HOME, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
report = {"app": APP, "tag": opts.tag, "api": opts.api, "steps": {}}
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)
    return ok


def credentials(path):
    values = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.removeprefix("export ").split("=", 1)
            values[key.strip()] = value.strip().strip("'\"")
    for prefix in ("CMUX_UITEST_STACK", "CMUX_DOGFOOD_STACK"):
        if values.get(f"{prefix}_EMAIL") and values.get(f"{prefix}_PASSWORD"):
            return values[f"{prefix}_EMAIL"], values[f"{prefix}_PASSWORD"]
    sys.exit("the credentials file has no CMUX_UITEST_STACK_* or CMUX_DOGFOOD_STACK_* pair")


def op_read(name):
    """One 1Password reference from the environment, read on this host with `op read` (never echoed)."""
    ref = os.environ.get(name, "")
    if not ref.startswith("op://"):
        sys.exit(f"{name} is not an op:// reference")
    r = subprocess.run(["op", "read", "--no-newline", ref], capture_output=True, text=True, timeout=60)
    if r.returncode != 0 or not r.stdout:
        sys.exit(f"inconclusive: op read {name} failed (exit {r.returncode})")
    return r.stdout


def owner_credentials():
    """(email, password, the app's sign-in environment) from the one configured source."""
    if opts.credentials_file:
        if os.stat(opts.credentials_file).st_mode & 0o077:
            sys.exit("the credentials file must be mode 600")
        email, password = credentials(opts.credentials_file)
        return email, password, {"CMUX_AUTH_CREDENTIALS_FILE": os.path.abspath(opts.credentials_file)}
    email, password = op_read("HANDS_PROOF_EMAIL_REF"), op_read("HANDS_PROOF_PASSWORD_REF")
    return email, password, {"CMUX_UITEST_STACK_EMAIL": email, "CMUX_UITEST_STACK_PASSWORD": password, "CMUX_DEV_AUTH_PROFILE": "agent"}


def http(method, url, headers=None, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    # The API's edge refuses urllib's default User-Agent (HTTP 403, "error code: 1010").
    request = urllib.request.Request(url, data=data, method=method, headers={
        "content-type": "application/json", "user-agent": "cmux-hands-proof/1", **(headers or {})})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as r:
            raw = r.read()
            status = r.status
    except urllib.error.HTTPError as error:
        raw, status = error.read(), error.code
    try:
        return status, json.loads(raw.decode() or "{}")
    except ValueError:
        return status, {"raw": raw[:200].decode(errors="replace")}


STACK = {"x-stack-project-id": DEV_STACK_PROJECT, "x-stack-publishable-client-key": DEV_STACK_CLIENT_KEY, "x-stack-access-type": "client"}
EMAIL, PASSWORD, APP_SIGN_IN = owner_credentials()
status, body = http("POST", f"{STACK_API}/auth/password/sign-in", STACK, {"email": EMAIL, "password": PASSWORD})
PASSWORD = None
if status != 200 or "access_token" not in body:
    sys.exit(f"inconclusive: Stack sign-in answered {status} {body.get('code', '')}")
SESSION = {"access": body["access_token"], "refresh": body["refresh_token"]}


def api(method, path, body=None, timeout=60):
    status, reply = http(method, opts.api + path, {"authorization": f"Bearer {SESSION['access']}"}, body, timeout)
    return status, reply


def cli(*args, timeout=60):
    try:
        return subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=timeout,
                              env={**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"})
    except subprocess.TimeoutExpired as error:
        return subprocess.CompletedProcess(error.cmd, 124, "", "timeout")


def rpc(method, params=None):
    r = cli("--json", "app", "call", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()[-400:]}


def hands(params=None):
    """debug.hands answers its state as JSON text."""
    reply = rpc("debug.hands", params)
    text = reply.get("result", reply) if isinstance(reply, dict) else reply
    try:
        return json.loads(text) if isinstance(text, str) else text
    except ValueError:
        return {"error": text}


def wait_for(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded harness wait for the app's or the server's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    return None


def logged(fragment):
    return wait_for(lambda: next((line for line in hands().get("log", []) if fragment in line), None), 60)


def server_level(hand):
    status, reply = api("GET", f"/v1/hands/{hand}")
    return (reply.get("value") or {}).get("level") if status == 200 else None


def banner_ids():
    return [b.get("id") for b in rpc("debug.notifications").get("banners") or [] if isinstance(b, dict) and b.get("approval")]


def call_in_background(params, results, name):
    """POST /v1/hands/<hand>/call blocks until the request is answered or ends."""
    def run():
        results[name] = api("POST", f"/v1/hands/{HAND}/call", params, timeout=300)
    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    return thread


def approval_round(label, allow):
    """One fs.write at ask: wait for its banner, press Allow or Deny on it, check the outcome."""
    path = os.path.join(ROOT, f"{label}.txt")
    results = {}
    thread = call_in_background({"action": "fs.write", "params": {"path": path, "text": label}, "timeout_ms": 120000}, results, label)
    pending = wait_for(lambda: [p for p in hands().get("pending", []) if p.get("hand") == HAND], 60)
    if not check(bool(pending), f"{label}: the request appears as pending through the wire event"):
        return
    key = pending[0]["key"]
    check(key in banner_ids(), f"{label}: the app posted an approval banner {key} (debug.notifications)")
    rpc("debug.notifications", {"action": "allow" if allow else "deny", "id": key})
    thread.join(90)
    status, reply = results.get(label, (0, {}))
    report["steps"][label] = {"key": key, "status": status, "reply": reply}
    if allow:
        check(status == 200 and os.path.exists(path), f"{label}: Allow ran the write (HTTP {status})")
    else:
        code = ((reply.get("error") or {}).get("code") if isinstance(reply, dict) else None)
        check(status != 200 and not os.path.exists(path), f"{label}: Deny refused the write (HTTP {status} {code})")
    check(bool(wait_for(lambda: not any(p.get("key") == key for p in hands().get("pending", [])), 30)),
          f"{label}: the banner's request is gone from pending ({'allow' if allow else 'deny'})")


HAND = None
hand_process = None
app = None
with open(CONFIG, "w") as f:
    f.write("{}\n")
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
teardown = TagTeardown(APP)
teardown.install()
try:
    # The hand: a mac hand of the owner, paired from this host, run as this script's child.
    status, minted = api("POST", "/v1/hands/pair-codes", {"name": f"hands-proof-{opts.tag}", "profile": "mac"})
    if not check(status == 200, f"pair code minted (HTTP {status} {(minted.get('error') or {}).get('code', '') or minted.get('raw', '')[:120]})"):
        raise SystemExit(1)
    HAND = minted["value"]["hand"]
    report["hand"] = HAND
    hand_env = {**BASE_ENV, "CMUX_HAND_HOME": HAND_HOME}
    installer = subprocess.run(["sh", "-c", f'curl -fsSL "{opts.api}/hand/install.sh" | sh -s -- --pair "$PAIR" --profile mac '
                                            f'--no-service --root "{ROOT}" --name hands-proof-{opts.tag}'],
                               env={**hand_env, "PAIR": minted["value"]["code"]}, capture_output=True, text=True, timeout=300)
    report["install"] = {"exit": installer.returncode, "out": installer.stdout[-600:], "err": installer.stderr[-600:]}
    if not check(installer.returncode == 0, f"hand installed and paired (exit {installer.returncode})"):
        raise SystemExit(1)
    with open(os.path.join(opts.out, "hand.log"), "w") as hand_log:
        hand_process = subprocess.Popen([os.path.join(HAND_HOME, "bin/cmux-hand"), "hand", "run"], env=hand_env,
                                        stdout=hand_log, stderr=subprocess.STDOUT)
    online = wait_for(lambda: (api("GET", f"/v1/hands/{HAND}")[1].get("value") or {}).get("online"), 60)
    check(bool(online), f"hand {HAND} is online")

    def launch(cloud_link, log_name):
        """The app, signed in as the same owner, scratch HOME, automation launch. A --app-from-fleet
        build has the offline (loopback) backend, where the app registers no Cloud install
        (CloudService.mayCallCloud); CMUX_NEXT_CLOUD_LINK=app (kept across the launch) turns the
        Cloud app server path on, so the install key that signs allows and enrolls exists."""
        if os.path.exists(SOCKET):
            os.unlink(SOCKET)
        env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, **APP_SIGN_IN, "CMUX_DEV_AUTH_ACCOUNT": EMAIL}
        if cloud_link:
            env["CMUX_NEXT_CLOUD_LINK"] = "app"
        with open(os.path.join(opts.out, log_name), "w") as app_log:
            launched = subprocess.Popen([BINARY], env=env, stdout=app_log, stderr=subprocess.STDOUT)
        if not check(bool(wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 120)),
                     f"the app socket answers ({log_name})"):
            raise SystemExit(1)
        return launched

    def quit_app(running):
        rpc("action.run", {"action": "quitEndSessions"})
        try:
            running.wait(timeout=20)
        except subprocess.TimeoutExpired:
            running.kill()
        teardown.end()

    def listed():
        hands({"action": "refresh"})
        return next((h for h in hands().get("hands", []) if h.get("hand") == HAND), None)

    # 0. With no registered Cloud install, Allow and a raise say so in the person's words.
    app = launch(cloud_link=False, log_name="app-not-linked.log")
    wait_for(listed, 120)
    hands({"action": "level", "hand": HAND, "level": "full"})
    refused = logged("raise refused:")
    report["steps"]["not_linked_raise"] = refused
    check(bool(refused) and "not set up for Cloud" in refused and "signedOut" not in refused,
          f"0. a raise with no install says the Mac is not set up for Cloud ({refused})")
    results = {}
    thread = call_in_background({"action": "fs.write", "params": {"path": os.path.join(ROOT, "not-linked.txt"), "text": "x"},
                                 "timeout_ms": 120000}, results, "not-linked")
    pending = wait_for(lambda: [p for p in hands().get("pending", []) if p.get("hand") == HAND], 60)
    if check(bool(pending), "0. the request appears as pending"):
        key = pending[0]["key"]
        rpc("debug.notifications", {"action": "allow", "id": key})
        again = wait_for(lambda: [b for b in rpc("debug.notifications").get("banners") or []
                                  if isinstance(b, dict) and b.get("id") == key and "not set up for Cloud" in (b.get("body") or "")], 30)
        report["steps"]["not_linked_banner"] = again
        check(bool(again) and "signedOut" not in again[-1].get("body", ""),
              "0. Allow with no install posts the banner again with the not-set-up reason first")
        rpc("debug.notifications", {"action": "deny", "id": key})
        thread.join(90)
        check(not os.path.exists(os.path.join(ROOT, "not-linked.txt")), "0. the request did not run")
    quit_app(app)
    app = None

    app = launch(cloud_link=True, log_name="app.log")

    # 1. The app reads the hand after its wire subscribe.
    row = wait_for(listed, 120)
    report["steps"]["listed"] = row
    check(bool(row) and row.get("level") == "auto", f"1. the app lists the hand at level auto ({row})")

    # 2. Presence key.
    state = hands({"action": "enroll"})
    report["steps"]["enroll"] = state.get("result")
    secure_enclave = state.get("secure_enclave")
    if secure_enclave:
        check(state.get("result") == "ok", f"2. presence key enrolled ({state.get('result')})")
    else:
        check("unavailable" in str(state.get("result")), f"2. no Secure Enclave: enroll refused ({state.get('result')})")

    # 3. A lower is a plain PUT.
    hands({"action": "level", "hand": HAND, "level": "ask"})
    check(bool(logged(f"level {HAND} ask: ok")), "3. the lower auto -> ask answered ok")
    check(server_level(HAND) == "ask", f"3. the server says ask ({server_level(HAND)})")

    # 4. A raise without the presence signature is refused.
    state = hands({"action": "raise_unsigned", "hand": HAND, "level": "full"})
    report["steps"]["raise_unsigned"] = state.get("result")
    check("hand.level_refused" in str(state.get("result")), f"4. an install-key raise is refused ({state.get('result')})")
    check(server_level(HAND) == "ask", "4. the level stays ask")

    # 5. A raise asks for presence; the script cancels the prompt.
    hands({"action": "level", "hand": HAND, "level": "auto"})
    if secure_enclave:
        prompt = wait_for(lambda: hands().get("prompt"), 30)
        report["steps"]["prompt"] = prompt
        check(bool(prompt) and f"hands-proof-{opts.tag}" in prompt, f"5. the presence prompt was requested and names the hand ({prompt!r})")
        hands({"action": "cancel_prompt"})
        ended = logged(f"level {HAND} auto: failed")
        check(bool(ended) and "cancelled" in ended, f"5. the cancelled raise failed ({ended})")
    else:
        ended = logged("raise refused:")
        check(bool(ended), f"5. no Secure Enclave: the raise is refused with the localized text ({ended})")
    check(server_level(HAND) == "ask", "5. the level stays ask")

    # 6 and 7. A request at ask: Deny, then Allow, through the banner's own path.
    approval_round("deny-round", allow=False)
    approval_round("allow-round", allow=True)

    # 8. A request that ends unanswered: the hand goes offline, the server settles it expired.
    results = {}
    call_in_background({"action": "fs.write", "params": {"path": os.path.join(ROOT, "expire.txt"), "text": "x"}, "timeout_ms": 120000},
                       results, "expire")
    pending = wait_for(lambda: [p for p in hands().get("pending", []) if p.get("hand") == HAND], 60)
    if check(bool(pending), "8. the expiry request appears as pending"):
        key = pending[0]["key"]
        hand_process.terminate()
        hand_process.wait(20)
        hand_process = None
        check(bool(logged(f"settled {key} expired")), "8. the app got hand-approval-settled expired")
        check(not any(p.get("key") == key for p in hands().get("pending", [])), "8. the expired request is gone from pending")
    report["log"] = hands().get("log")
finally:
    if app is not None:
        rpc("action.run", {"action": "quitEndSessions"})
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()
    teardown.end()
    if hand_process is not None:
        hand_process.terminate()
        try:
            hand_process.wait(20)
        except subprocess.TimeoutExpired:
            hand_process.kill()
    if HAND:
        report["hand_removed"] = api("DELETE", f"/v1/hands/{HAND}")[0]
    http("DELETE", f"{STACK_API}/auth/sessions/current",
         {**STACK, "x-stack-access-token": SESSION["access"], "x-stack-refresh-token": SESSION["refresh"]}, {})
    shutil.rmtree(SCRATCH, ignore_errors=True)
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1, default=str)

print(f"{len(failures)} failure(s); report {os.path.join(opts.out, 'report.json')}")
sys.exit(1 if failures else 0)
