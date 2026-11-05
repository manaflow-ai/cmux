#!/usr/bin/env python3
"""Staging round trip of automation teleport (docs/automations-teleport-teams.md section 6).

  scripts/cmux-next/automations-teleport-proof.py --cli <path to cmux> [--api URL] [--out FILE]

The real `cmux` CLI does every step against an isolated local store (a scratch HOME). Its Cloud
calls go, as in the app, through one `cloud.automation` app-socket method; here a small socket
relay stands in for the app and forwards each call to the staging API as the agent test account
(CMUX_UITEST_STACK_* in ~/.secrets/cmuxterm-dev.env, never printed). The relay keeps the app's
rules: reads go to /v1/read, mutations to /v1/ops with the CLI's idempotency key.

1. create an hourly prompt automation on "this Mac" and fire it (run now);
2. teleport it to Cloud: the local copy becomes a tombstone, Cloud holds one copy (epoch 2);
3. fire it in Cloud (run now) and read the run;
4. teleport it back home: the Cloud copy becomes a tombstone (automation.moved), the local copy
   is back with epoch 3, and it fires again on this Mac;
5. checks: one copy at each instant, no scheduled slot fired twice, the Cloud audit log names
   import, begin and complete for the test user.

Writes a JSON receipt to --out; exit 0 when every check passed.
"""
import argparse, json, os, re, socket, subprocess, sys, tempfile, threading, time, urllib.error, urllib.request

p = argparse.ArgumentParser()
p.add_argument("--cli", required=True)
p.add_argument("--api", default="https://cloud-api-staging.cmux.dev")
p.add_argument("--credentials", default=os.path.expanduser("~/.secrets/cmuxterm-dev.env"))
p.add_argument("--out", default="artifacts/automations-teleport-proof.json")
o = p.parse_args()
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESULT = {"api": o.api, "checks": {}, "calls": [], "started_at": time.time()}
failures = []


def check(name, ok, detail=None):
    RESULT["checks"][name] = {"ok": bool(ok), "detail": detail}
    print(("ok   " if ok else "FAIL ") + name + ("" if detail is None else ": " + json.dumps(detail, default=str)[:400]), flush=True)
    if not ok:
        failures.append(name)
    return bool(ok)


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
                               headers={"content-type": "application/json", "user-agent": "automations-teleport-proof", **(headers or {})})
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read() or b"null")
        except ValueError:
            return e.code, None


st, signed = http("https://api.stack-auth.com/api/v1/auth/password/sign-in",
                  {"email": vals["CMUX_UITEST_STACK_EMAIL"], "password": vals["CMUX_UITEST_STACK_PASSWORD"]},
                  {"x-hexclave-project-id": project, "x-hexclave-publishable-client-key": client_key, "x-hexclave-access-type": "client"})
if st != 200:
    sys.exit(f"test account sign-in: HTTP {st}")
AUTH = {"authorization": "Bearer " + signed["access_token"]}
http(o.api + "/v1/ops", {"op": "user.ensure", "params": {}, "idempotency_key": f"tp-proof-ensure-{int(time.time())}", "origin": "cli"}, AUTH)

# The app's CloudAutomationRelay allowlist (CmuxNextCloud), kept here so the proof refuses what the app refuses.
READS = {"automation.list", "automation.get", "automation.runs.list", "automation.webhook.get", "run.list", "run.get", "chief.list", "automation.audit.list"}
MUTATIONS = {"automation.create", "automation.update", "automation.delete", "automation.run", "automation.import",
             "automation.teleport.begin", "automation.teleport.complete", "automation.teleport.abort"}


def relay(request):
    op, params, key = request.get("op"), request.get("params") or {}, request.get("idempotency_key")
    if op in READS:
        status, answer = http(o.api + "/v1/read", {"op": op, "params": params}, AUTH)
    elif op in MUTATIONS and key:
        status, answer = http(o.api + "/v1/ops", {"op": op, "params": params, "idempotency_key": key, "origin": "cli"}, AUTH)
    else:
        return {"ok": False, "error": {"code": "invalid_params", "message": f"{op} is not relayed"}}
    RESULT["calls"].append({"op": op, "status": status, "key": key})
    if 200 <= status < 300 and isinstance(answer, dict) and answer.get("ok") is not False and "error" not in answer:
        return {"ok": True, "value": answer.get("value")}
    error = (answer or {}).get("error") if isinstance(answer, dict) else None
    return {"ok": False, "error": error if isinstance(error, dict) else {"code": "owner.unreachable", "message": f"HTTP {status}"}}


SCRATCH = tempfile.mkdtemp(prefix="automations-teleport-proof-")
SOCK = os.path.join(SCRATCH, "app.sock")
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCK)
server.listen(8)


def serve(conn):
    with conn:
        f = conn.makefile("rwb")
        for raw in f:
            line = raw.decode().strip()
            if line == "ping":
                f.write(b"PONG\n"); f.flush(); continue
            try:
                req = json.loads(line)
            except ValueError:
                return
            if req.get("method") == "cloud.automation":
                reply = {"id": req.get("id"), "ok": True, "result": relay(req.get("params") or {})}
            else:
                reply = {"id": req.get("id"), "ok": False, "error": {"code": "method_not_found", "message": str(req.get("method"))}}
            f.write((json.dumps(reply) + "\n").encode()); f.flush()


threading.Thread(target=lambda: [threading.Thread(target=serve, args=(server.accept()[0],), daemon=True).start() for _ in iter(int, 1)], daemon=True).start()

HOME = os.path.join(SCRATCH, "home")
os.makedirs(HOME)
ENV = {"HOME": HOME, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_QUIET": "1"}


def cli(*args):
    r = subprocess.run([o.cli, "--json", "--app-socket", SOCK, *args], capture_output=True, text=True, timeout=120, env=ENV)
    try:
        value = json.loads(r.stdout) if r.stdout.strip() else None
    except ValueError:
        value = None
    RESULT.setdefault("cli", []).append({"args": list(args), "code": r.returncode, "stdout": r.stdout[-2000:], "stderr": r.stderr[-1000:]})
    return r.returncode, value, r.stderr


def cloud(op, params):
    status, answer = http(o.api + "/v1/read", {"op": op, "params": params}, AUTH)
    return answer if isinstance(answer, dict) else {}


NAME = f"teleport proof {int(time.time())}"
code, made, err = cli("automation", "create", NAME, "--prompt", "Reply with one word: teleported.", "--hourly")
check("1. create on this Mac", code == 0, made or err)
code, ran, err = cli("automation", "run", NAME, "--wait", "--key", "proof-local-1")
check("1. fire on this Mac", ran is not None, ran or err)

code, moved, err = cli("automation", "teleport", NAME, "--to", "cloud")
check("2. teleport to Cloud", code == 0, moved or err)
code, listed, err = cli("automation", "list")
local_rows = (listed or {}).get("automations", [])
check("2. this Mac keeps only a tombstone", all(a.get("name") != NAME or a.get("moved_to") == "cloud" for a in local_rows), local_rows)
cloud_list = cloud("automation.list", {}).get("value", {})
copies = [a for a in cloud_list.get("automations", []) if a.get("name") == NAME]
check("2. Cloud holds one copy, epoch 2, home cloud", len(copies) == 1 and copies[0].get("epoch") == 2 and copies[0].get("home") == "cloud", copies)
cloud_id = copies[0]["id"] if copies else None

code, ran, err = cli("automation", "run", NAME, "--target", "cloud", "--key", "proof-cloud-1")
check("3. fire in Cloud", code == 0, ran or err)
run_state = None
for _ in range(30):  # harness wait on the staging API, not product code
    runs = cloud("automation.runs.list", {"automation": cloud_id, "limit": 5}).get("value", {}).get("runs", []) if cloud_id else []
    run_state = runs[0]["state"] if runs else None
    if run_state not in (None, "queued"):
        break
    time.sleep(3)
check("3. the Cloud run left queued", run_state not in (None, "queued"), run_state)

code, back, err = cli("automation", "teleport", NAME, "--target", "cloud", "--to", "home")
check("4. teleport back home", code == 0, back or err)
gone = cloud("automation.get", {"automation": cloud_id}) if cloud_id else {}
check("4. Cloud copy is a tombstone", "moved" in json.dumps(gone), gone)
code, listed, err = cli("automation", "list")
home_rows = [a for a in (listed or {}).get("automations", []) if a.get("name") == NAME and not a.get("moved_to")]
check("4. this Mac holds one copy, epoch 3", len(home_rows) == 1 and home_rows[0].get("epoch") == 3, home_rows)
code, ran, err = cli("automation", "run", NAME, "--wait", "--key", "proof-local-2")
check("4. fire on this Mac again", ran is not None, ran or err)

audit = cloud("automation.audit.list", {"automation": cloud_id}).get("value", {}).get("entries", []) if cloud_id else []
ops = [e.get("op") for e in audit]
check("5. Cloud audit: import, run, begin, complete", ops[:1] == ["automation.import"] and "automation.teleport.begin" in ops and "automation.teleport.complete" in ops, ops)
code, runs_local, err = cli("automation", "runs", NAME)
slots = [r.get("scheduled_at") for r in (runs_local or {}).get("runs", []) if r.get("scheduled_at")]
check("5. no scheduled slot fired twice", len(slots) == len(set(slots)), slots)

cli("automation", "delete", NAME, "--yes")
RESULT["finished_at"] = time.time()
os.makedirs(os.path.dirname(os.path.abspath(o.out)), exist_ok=True)
json.dump(RESULT, open(o.out, "w"), indent=2, default=str)
print(f"receipt {o.out}")
print("FAILED: " + ", ".join(failures) if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
