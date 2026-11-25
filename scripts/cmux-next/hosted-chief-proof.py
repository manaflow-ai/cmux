#!/usr/bin/env python3
"""Tagged-app proof of the Hosted Chief in Home (staging). Run on cmux-lawrence-2 only:
  nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- \
    'python3 scripts/cmux-next/hosted-chief-proof.py --tag <tag> --app "$NX_APP" --out "$NX_ARTIFACTS"; "$NX_APP_STOP"'
As the host's agent test account (CMUX_UITEST_STACK_* in ~/.secrets/cmuxterm-dev.env, never printed):
1. Pairs a test server with the app's own `optchat-chief cloud pair` and places a chief named "Chief" on it
   (the "Mac mini" Chief), through the API.
2. Launches the tagged app (no activate, docked Home, copy on: CMUX_NEXT_HOSTED_CHIEF_COPY=1) and checks that
   Home shows the Hosted Chief by default, the placed chief is renamed "Chief (Mac mini)", the copy steps ran
   once (ledger), the brain is on and no notice shows.
3. Switches to "Chief (Mac mini)" and back (debug.home.api chief_switch: the switch control's path).
4. Sends one message through the app's Home data path and waits for the Hosted Chief's reply (a reply proves
   the cloud turn ran; `model_reply` says whether the model answered or the failure notice came).
5. Turns the brain off through the API, relaunches the app and checks that Home shows the brain-off notice
   (never a silent dead Chief); then turns it on again.
Cleanup: archives the placed chief and revokes the test server. Socket only: no system input.
"""
import argparse, json, os, re, shutil, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request
p = argparse.ArgumentParser()
p.add_argument("--tag", required=True); p.add_argument("--app", required=True); p.add_argument("--out", required=True)
p.add_argument("--api", default="https://cloud-api-staging.cmux.dev")
p.add_argument("--credentials", default=os.path.expanduser("~/.secrets/cmuxterm-dev.env"))
o = p.parse_args()
SOCKET = f"/tmp/cmux-debug-{o.tag}.sock"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TURN_FAILED = "I could not reach the model, so I stopped here. Please try again."
os.makedirs(o.out, exist_ok=True)
RESULT = {"tag": o.tag, "checks": {}}
cleanup = []

def check(name, ok, detail=None):
    RESULT["checks"][name] = {"ok": bool(ok), "detail": detail}
    print(("ok   " if ok else "FAIL ") + name + ("" if detail is None else ": " + json.dumps(detail, default=str)[:400]), flush=True)
    return bool(ok)

def wait(pred, seconds, step=1.0):
    end = time.time() + seconds
    while time.time() < end:  # test harness wait on the app's socket or the API, not app code
        v = pred()
        if v: return v
        time.sleep(step)
    return None

# --- API as the test account (secrets read from the file, never printed) ---
vals = {}
for line in open(o.credentials).read().splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1)
        vals[k.replace("export ", "").strip()] = v.strip().strip('"').strip("'")
conf = open(os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextCloud/Config/CloudConfiguration.swift")).read()
project = re.search(r'developmentProjectID = "([^"]+)"', conf).group(1)
client_key = re.search(r'developmentClientKey = "([^"]+)"', conf).group(1)

def http(url, body=None, headers=None, method=None):
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(),
                               method=method or ("POST" if body is not None else "GET"),
                               headers={"content-type": "application/json", "user-agent": "hosted-chief-proof", **(headers or {})})
    try:
        with urllib.request.urlopen(r, timeout=60) as resp: return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")

st, signed = http("https://api.stack-auth.com/api/v1/auth/password/sign-in",
                  {"email": vals["CMUX_UITEST_STACK_EMAIL"], "password": vals["CMUX_UITEST_STACK_PASSWORD"]},
                  {"x-hexclave-project-id": project, "x-hexclave-publishable-client-key": client_key, "x-hexclave-access-type": "client"})
if st != 200: sys.exit(f"test account sign-in: HTTP {st}")
AUTH = {"authorization": "Bearer " + signed["access_token"]}
def op(name, params, key=None):
    return http(o.api + "/v1/ops", {"op": name, "params": params, "origin": "user", "idempotency_key": key or f"hcp-{time.time_ns()}"}, AUTH)[1] or {}
def read(name, params):
    return http(o.api + "/v1/read", {"op": name, "params": params}, AUTH)[1] or {}
def chiefs(): return (read("chief.list", {}).get("value") or {}).get("chiefs") or []
def brain(agent, enabled=None):
    if enabled is None: return ((http(o.api + f"/v1/chiefs/{agent}/brain", headers=AUTH)[1] or {}).get("value") or {}).get("config", {}).get("enabled")
    return http(o.api + f"/v1/chiefs/{agent}/brain", {"enabled": enabled}, AUTH, "PUT")[0]

profile = op("user.ensure", {}).get("value") or {}
team = profile.get("personal_team")

# --- 1. A test server with a placed chief named "Chief" ---
placed = None
tool = os.path.join(o.app, "Contents/Resources/bin/optchat-chief")
if not os.path.exists(tool):
    check("pair a test server (the app's optchat-chief)", False, "the app bundles no optchat-chief")
else:
    pair_dir = tempfile.mkdtemp(prefix=f"hcp-{o.tag}-")
    cleanup.append(("rmdir", {"path": pair_dir}))
    install_file, pair_out = os.path.join(pair_dir, "install.json"), os.path.join(pair_dir, "pair.out")
    pair = subprocess.Popen([tool, "cloud", "pair", "--install", install_file, "--api-base", o.api, "--name", f"proof-{o.tag}", "--wait-chief", "240"],
                            stdout=open(pair_out, "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    def pair_code():
        m = re.search(r"pairing code: ([0-9A-Z-]+)", open(pair_out).read())
        return m and m.group(1).replace("-", "")
    code = wait(pair_code, 60, 0.5)
    approved = op("server.pair.approve", {"code": code, "team": team, "name": f"proof-{o.tag}"}) if code else {}
    place = approved.get("value") or {}
    if place.get("host"): cleanup.append(("server.revoke", {"host": place["host"]}))
    check("pair a test server (the app's optchat-chief)", bool(place.get("install")), {"code": bool(code), "ok": approved.get("ok"), "error": approved.get("error")})
    if place.get("install"):
        made = op("chief.create", {"display_name": "Chief", "is_default": False, "brain_place": {"host": place["host"], "install": place["install"]}})
        placed = made.get("value")
        if placed: cleanup.append(("chief.archive", {"chief": placed["id"]}))
        check("place a chief named \"Chief\" on it", bool(placed), made.get("error"))
    try: pair.wait(timeout=60)
    except subprocess.TimeoutExpired: pair.kill()

hosted = expect = None

# --- the app ---
def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk: break
            buf += chunk
        c.close(); r = json.loads(buf)
        return r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        return {"error": str(e)}

scratch = tempfile.mkdtemp(prefix=f"hostedproof-{o.tag}-")
cfg, gh = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
open(cfg, "w").write("{}"); open(gh, "w").write("")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": cfg, "CMUX_NEXT_GHOSTTY_CONFIG": gh,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1",
       "CMUX_NEXT_HOSTED_CHIEF_COPY": "1", "CMUX_AUTH_CREDENTIALS_FILE": o.credentials}
log = open(os.path.join(o.out, "app.log"), "a")
app = None

def launch():
    global app
    app = subprocess.Popen([os.path.join(o.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    up = wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 180)
    rpc("action.run", {"id": "home.show"})
    return up

def quit_app():
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try: app.wait(timeout=30)
    except subprocess.TimeoutExpired: print("app still runs; NX_APP_STOP ends it", flush=True)

def home():
    h = rpc("debug.home") or {}
    hc = h.get("hosted_chief") or {}
    dock = h.get("dock") or {}
    view = {k: hc.get(k) for k in ("hosted", "placed", "choice", "can_switch", "shown", "pending", "running", "brain_on", "notice", "ledger")}
    view["dock_shown"] = dock.get("messages_shown")
    RESULT["last_home"] = view
    return view

def snapshot(name):
    time.sleep(2)  # test harness: let the page paint before the snapshot
    rpc("debug.window_snapshot", {"path": os.path.join(o.out, name)})

rc = 1
try:
    ok = check("app socket up", launch())
    # The app makes the Hosted Chief when the account has none (ensureHosted): read it from the app.
    hosted_view = wait(lambda: (home().get("hosted") or {}).get("main"), 120, 2) and home()["hosted"]
    hosted = hosted_view and {"id": hosted_view["id"]}
    expect = hosted_view and hosted_view["main"]
    RESULT["expect"] = expect
    ok = check("the app has a default Hosted Chief", bool(expect) and hosted_view.get("default"), hosted_view) and ok
    def ready():
        v = home()
        return (v["shown"] == expect and v["dock_shown"] == expect and v["running"] is False and v["brain_on"] is True) and v
    v = wait(ready, 180, 2) or home()
    ok = check("Home shows the Hosted Chief by default (Chief tab and docked page)", v["shown"] == expect and v["dock_shown"] == expect, v) and ok
    ok = check("the copy steps are done (ledger)", v.get("ledger") == {"history": True, "memory": True, "brain": True}, v.get("ledger")) and ok
    # What each step did, from the app's own log (a target that has content is skipped, never overwritten).
    logq = subprocess.run(["/usr/bin/log", "show", "--last", "10m", "--style", "compact", "--info", "--predicate",
                           f'subsystem == "com.cmuxterm.app.next" AND category == "home" AND processIdentifier == {app.pid} AND eventMessage CONTAINS "hosted chief"'],
                          capture_output=True, text=True, timeout=120).stdout
    lines = [l.split("[com.cmuxterm.app.next:home] ", 1)[-1] for l in logq.splitlines() if "hosted chief" in l]
    open(os.path.join(o.out, "hosted-chief.log"), "w").write("\n".join(lines) + "\n")
    steps = {k: [l for l in lines if l.startswith(f"hosted chief {k}:")] for k in ("history", "memory")}
    RESULT["copy_outcomes"] = steps
    ok = check("each copy step ran once and logged its outcome", all(len(v) == 1 for v in steps.values()), steps) and ok
    ok = check("the brain is on and Home shows no notice", v["brain_on"] is True and v["notice"] is None, {"brain_on": v["brain_on"], "notice": v["notice"], "api": brain(hosted["id"]) if hosted else None}) and ok
    snapshot("home-hosted.png")
    if placed:
        renamed = wait(lambda: (home().get("placed") or {}).get("name") == "Chief (Mac mini)" and home(), 60, 2) or home()
        ok = check("the placed chief is \"Chief (Mac mini)\" and the switch shows", (renamed.get("placed") or {}).get("name") == "Chief (Mac mini)" and renamed.get("can_switch"), renamed.get("placed")) and ok
        rpc("debug.home.api", {"call": "chief_switch", "choice": "placed"})
        mini = wait(lambda: (lambda v: v["shown"] == placed.get("main_conversation") and v["dock_shown"] == v["shown"] and v)(home()), 60, 1) or home()
        ok = check("one switch shows \"Chief (Mac mini)\"", mini["shown"] == placed.get("main_conversation") and mini["dock_shown"] == mini["shown"], mini) and ok
        snapshot("home-mac-mini.png")
        rpc("debug.home.api", {"call": "chief_switch", "choice": "hosted"})
        back = wait(lambda: (lambda v: v["shown"] == expect and v["dock_shown"] == expect and v)(home()), 60, 1) or home()
        ok = check("one switch back shows the Hosted Chief", back["shown"] == expect and back["dock_shown"] == expect, back) and ok
    else:
        check("switch to \"Chief (Mac mini)\"", False, "UNVERIFIED: no placed chief")
        ok = False
    text = f"hosted-chief proof {o.tag}: answer with one short sentence."
    sent = rpc("debug.home.api", {"call": "submit", "op": {"kind": "send", "conversation": expect, "text": text}}, 40)
    ok = check("send through the app's Home data path", isinstance(sent, dict) and sent.get("ok"), sent) and ok
    def reply():
        snap = rpc("debug.home.api", {"call": "snapshot", "conversation": expect, "tail": 10}) or {}
        msgs = snap.get("messages") or []
        mine = [i for i, m in enumerate(msgs) if text in json.dumps(m)]
        after = [m for m in msgs[mine[-1] + 1:] if text not in json.dumps(m)] if mine else []
        return after[-1] if after else None
    got = wait(reply, 240, 3)
    ok = check("the Hosted Chief's cloud turn answered (seen by the app)", got, got) and ok
    RESULT["model_reply"] = None if not got else ("failure_notice" if TURN_FAILED in json.dumps(got) else "answered")
    print(f"model reply: {RESULT['model_reply']}", flush=True)
    snapshot("home-hosted-reply.png")
    quit_app()
    # 5. A brain that is off shows a notice in Home.
    if hosted: cleanup.append(("brain.on", {"agent": hosted["id"]}))
    off = brain(hosted["id"], False) if hosted else None
    launch()
    noticed = wait(lambda: (lambda v: v["brain_on"] is False and v["notice"] and v)(home()), 120, 2) or home()
    ok = check("a brain that is off shows a notice in Home", off == 200 and noticed["brain_on"] is False and bool(noticed["notice"]), {"put": off, "notice": noticed["notice"], "brain_on": noticed["brain_on"]}) and ok
    snapshot("home-brain-off.png")
    RESULT["home_after"] = rpc("debug.home")
    rc = 0 if ok else 1
finally:
    if app: quit_app()
    for name, params in reversed(cleanup):
        if name == "rmdir":
            shutil.rmtree(params["path"], ignore_errors=True)
            continue
        if name == "brain.on":
            RESULT.setdefault("cleanup", []).append([name, brain(params["agent"], True)])
            continue
        if name == "chief.archive":
            cur = next((c for c in chiefs() if c["id"] == params["chief"]), None)
            if not cur: continue
            params = {**params, "expected_rev": cur["rev"]}
        r = op(name, params)
        RESULT.setdefault("cleanup", []).append([name, r.get("ok"), r.get("error")])
    open(os.path.join(o.out, "result.json"), "w").write(json.dumps(RESULT, indent=1, default=str))
sys.exit(rc)
