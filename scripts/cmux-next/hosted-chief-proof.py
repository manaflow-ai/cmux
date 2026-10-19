#!/usr/bin/env python3
"""Tagged-app proof of the Hosted Chief in Home (staging). Run on cmux-lawrence-2 only:
  nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- \
    'python3 scripts/cmux-next/hosted-chief-proof.py --tag <tag> --app "$NX_APP" --out "$NX_ARTIFACTS" --expect <conv>; "$NX_APP_STOP"'
Signs in as the host's agent test account (CMUX_AUTH_CREDENTIALS_FILE, never printed), launches the tagged app
(no activate, docked Home), checks that Home shows the Hosted Chief's main conversation, sends one real message
through the app's Home data path (debug.home.api submit) and waits for the Chief's reply. Socket only: no system input.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time
p = argparse.ArgumentParser()
p.add_argument("--tag", required=True); p.add_argument("--app", required=True); p.add_argument("--out", required=True)
p.add_argument("--expect", required=True, help="the Hosted Chief's main conversation id")
o = p.parse_args()
SOCKET = f"/tmp/cmux-debug-{o.tag}.sock"
os.makedirs(o.out, exist_ok=True)
RESULT = {"tag": o.tag, "expect": o.expect, "checks": {}}
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
def wait(pred, seconds, step=1.0):
    end = time.time() + seconds
    while time.time() < end:  # test harness wait on the app's socket, not app code
        v = pred()
        if v: return v
        time.sleep(step)
    return None
def check(name, ok, detail=None):
    RESULT["checks"][name] = {"ok": bool(ok), "detail": detail}
    print(("ok   " if ok else "FAIL ") + name + ("" if detail is None else ": " + json.dumps(detail)[:300]), flush=True)
    return ok
scratch = tempfile.mkdtemp(prefix=f"hostedproof-{o.tag}-")
cfg, gh = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
open(cfg, "w").write("{}"); open(gh, "w").write("")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": cfg, "CMUX_NEXT_GHOSTTY_CONFIG": gh,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1",
       "CMUX_AUTH_CREDENTIALS_FILE": os.path.expanduser("~/.secrets/cmuxterm-dev.env")}
log = open(os.path.join(o.out, "app.log"), "a")
app = subprocess.Popen([os.path.join(o.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
print(f"launched pid {app.pid}", flush=True)
rc = 1
try:
    if not check("app socket up", wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 180)): sys.exit(1)
    def shown():
        h = rpc("debug.home") or {}
        page = h.get("page") or {}
        s = page.get("shown") if isinstance(page, dict) else None
        RESULT["last_home"] = {"shown": s, "classic": h.get("classic"), "conversations": [c.get("id") for c in h.get("conversations", [])][:20]}
        return s == o.expect and s
    ok = check("Home shows the Hosted Chief's main conversation", wait(shown, 180, 2), RESULT.get("last_home"))
    rpc("debug.window_snapshot", {"path": os.path.join(o.out, "home-hosted-before.png")})
    text = f"hq-b5 GUI proof {o.tag}: answer with one short sentence."
    sent = rpc("debug.home.api", {"call": "submit", "op": {"kind": "send", "conversation": o.expect, "text": text}}, 40)
    check("send through the app's Home data path", isinstance(sent, dict) and sent.get("ok"), sent)
    def reply():
        snap = rpc("debug.home.api", {"call": "snapshot", "conversation": o.expect, "tail": 10}) or {}
        msgs = snap.get("messages") or []
        mine = [i for i, m in enumerate(msgs) if text in json.dumps(m)]
        if not mine: return None
        after = [m for m in msgs[mine[-1] + 1:] if json.dumps(m).find(text) < 0]
        return after[-1] if after else None
    got = wait(reply, 240, 3)
    ok = check("the Hosted Chief replied (seen by the app)", got, got) and ok
    time.sleep(3)  # test harness: let the transcript paint before the snapshot
    rpc("debug.window_snapshot", {"path": os.path.join(o.out, "home-hosted-after.png")})
    RESULT["home_after"] = rpc("debug.home")
    rc = 0 if ok and sent and got else 1
finally:
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try: app.wait(timeout=30)
    except subprocess.TimeoutExpired: print("app still runs; NX_APP_STOP ends it", flush=True)
    open(os.path.join(o.out, "result.json"), "w").write(json.dumps(RESULT, indent=1, default=str))
sys.exit(rc)
