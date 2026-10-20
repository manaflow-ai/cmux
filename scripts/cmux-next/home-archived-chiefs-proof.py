#!/usr/bin/env python3
"""Tagged-app proof that Home's list hides archived Chiefs' conversations (staging). cmux-lawrence-2 only:
  nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- \
    'python3 scripts/cmux-next/home-archived-chiefs-proof.py --tag <tag> --app "$NX_APP" --out "$NX_ARTIFACTS"; "$NX_APP_STOP"'
As the host's agent test account (CMUX_UITEST_STACK_* in ~/.secrets/cmuxterm-dev.env, never printed):
1. Archives one fresh test chief through the API (its main conversation exists, the chief is archived).
2. Launches the tagged app (no activate) twice: the relaunch restores the stored session and replaces it with
   the test account's sign-in (the race that left the list's Chief directory empty). Opens Home and reads
   debug.home: the directory's archived Chiefs and the docked Home list as drawn. Pass: the directory knows the
   archived chiefs and no archived chief's main conversation is a row. Socket only: no system input.
"""
import argparse, json, os, re, socket, subprocess, sys, tempfile, time, urllib.error, urllib.request
p = argparse.ArgumentParser()
p.add_argument("--tag", required=True); p.add_argument("--app", required=True); p.add_argument("--out", required=True)
p.add_argument("--api", default="https://cloud-api-staging.cmux.dev")
p.add_argument("--credentials", default=os.path.expanduser("~/.secrets/cmuxterm-dev.env"))
o = p.parse_args()
SOCKET = f"/tmp/cmux-debug-{o.tag}.sock"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
os.makedirs(o.out, exist_ok=True)
RESULT = {"tag": o.tag, "checks": {}}

def check(name, ok, detail=None):
    RESULT["checks"][name] = {"ok": bool(ok), "detail": detail}
    print(("ok   " if ok else "FAIL ") + name + ("" if detail is None else ": " + json.dumps(detail, default=str)[:400]), flush=True)

def wait(pred, seconds, step=1.0):
    end = time.time() + seconds
    while time.time() < end:  # test harness wait on the app's socket, not app code
        v = pred()
        if v: return v
        time.sleep(step)
    return None

vals = {}
for line in open(o.credentials).read().splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        k, v = line.split("=", 1)
        vals[k.replace("export ", "").strip()] = v.strip().strip('"').strip("'")
conf = open(os.path.join(ROOT, "Packages/macOS/CmuxNext/Sources/CmuxNextCloud/Config/CloudConfiguration.swift")).read()
project = re.search(r'developmentProjectID = "([^"]+)"', conf).group(1)
client_key = re.search(r'developmentClientKey = "([^"]+)"', conf).group(1)

def http(url, body=None, headers=None):
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method="POST" if body is not None else "GET",
                               headers={"content-type": "application/json", "user-agent": "home-archived-proof", **(headers or {})})
    try:
        with urllib.request.urlopen(r, timeout=60) as resp: return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")

st, signed = http("https://api.stack-auth.com/api/v1/auth/password/sign-in",
                  {"email": vals["CMUX_UITEST_STACK_EMAIL"], "password": vals["CMUX_UITEST_STACK_PASSWORD"]},
                  {"x-hexclave-project-id": project, "x-hexclave-publishable-client-key": client_key, "x-hexclave-access-type": "client"})
if st != 200: sys.exit(f"test account sign-in: HTTP {st}")
AUTH = {"authorization": "Bearer " + signed["access_token"]}
def op(name, params):
    return http(o.api + "/v1/ops", {"op": name, "params": params, "origin": "user", "idempotency_key": f"hap-{time.time_ns()}"}, AUTH)[1] or {}
def chiefs(archived):
    return ((http(o.api + "/v1/read", {"op": "chief.list", "params": {"include_archived": archived}}, AUTH)[1] or {}).get("value") or {}).get("chiefs") or []

made = (op("chief.create", {"display_name": f"Archived proof {o.tag}", "is_default": False}).get("value") or {})
if made.get("id"):
    gone = op("chief.archive", {"chief": made["id"], "expected_rev": made["rev"]})
    check("archive a fresh test chief", gone.get("ok") is not False, gone.get("error"))
archived = {c["id"]: c.get("main_conversation") for c in chiefs(True) if c.get("archived_at")}
RESULT["archived_on_server"] = len(archived)
check("the account has archived chiefs", made.get("id") in archived, {"count": len(archived)})

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

scratch = tempfile.mkdtemp(prefix=f"archproof-{o.tag}-")
cfg, gh = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
open(cfg, "w").write("{}"); open(gh, "w").write("")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": cfg, "CMUX_NEXT_GHOSTTY_CONFIG": gh,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1",
       "CMUX_AUTH_CREDENTIALS_FILE": o.credentials}
log = open(os.path.join(o.out, "app.log"), "a")
def launch():
    app = subprocess.Popen([os.path.join(o.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    up = wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 180)
    rpc("action.run", {"id": "home.show"})
    return app, up

def listed():
    h = rpc("debug.home") or {}
    rows = [r.get("id") for r in ((h.get("dock") or {}).get("messages_list") or [])]
    return (h, rows) if rows else None

app, up = launch()
wait(listed, 120)
rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
try: app.wait(timeout=30)
except subprocess.TimeoutExpired: app.kill()
app, up = launch()
check("the app is up (relaunched)", bool(up))
h, rows = wait(listed, 120) or ((rpc("debug.home") or {}), [])
time.sleep(10)  # test harness: the sign-in replacement and the list settle; then read again
h, rows = listed() or (h, rows)
rows = set(rows)
pg = h.get("page") or {}
known = set(pg.get("archived_chiefs") or [])
shown = sorted(c for a, c in archived.items() if c and c in rows)
RESULT["page"] = {"rows": len(rows), "chiefs": len(pg.get("chiefs") or []), "archived_known": len(known)}
check("Home's directory knows the archived chiefs", made.get("id") in known, RESULT["page"])
check("no archived chief's conversation is a Home row", bool(rows) and not shown, {"archived_rows": shown[:10], "rows": len(rows)})
time.sleep(2)  # test harness: let the page paint before the snapshot
rpc("debug.window_snapshot", {"path": os.path.join(o.out, "home-list.png")})
rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
json.dump(RESULT, open(os.path.join(o.out, "result.json"), "w"), indent=1, default=str)
sys.exit(0 if all(c["ok"] for c in RESULT["checks"].values()) else 1)
