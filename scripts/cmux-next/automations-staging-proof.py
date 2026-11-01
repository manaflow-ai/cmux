#!/usr/bin/env python3
"""Staging proof of Cloud Chief jobs made from the person's clients (docs/automations-platonic-ideal.md, Cloud
slice): the same ops `cmux automation --target cloud` sends through the app's `cloud.automation`, as the agent
test account (CMUX_UITEST_STACK_* in ~/.secrets/cmuxterm-dev.env, never printed).

1. chief.list: the default Cloud Chief and its main conversation (the CLI's pick).
2. automation.create with a chief body (cron weekdays 09:00 America/Los_Angeles plus manual), retried with the
   same idempotency key: one automation.
3. automation.run, then automation.runs.list until the run leaves queued (or 90 s).
4. A second chief job: on the free plan it answers automation.plan.required with a checkout link; on a paid
   plan it is made (and deleted again).
5. Cleanup: automation.delete of every automation this run made.

Writes a JSON receipt to --out. Exit 0 when every check passed.
"""
import argparse, json, os, re, sys, time, urllib.error, urllib.request

p = argparse.ArgumentParser()
p.add_argument("--api", default="https://cloud-api-staging.cmux.dev")
p.add_argument("--credentials", default=os.path.expanduser("~/.secrets/cmuxterm-dev.env"))
p.add_argument("--out", default="artifacts/automations-staging-proof.json")
o = p.parse_args()
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RESULT = {"api": o.api, "checks": {}, "started_at": time.time()}
made = []


def check(name, ok, detail=None):
    RESULT["checks"][name] = {"ok": bool(ok), "detail": detail}
    print(("ok   " if ok else "FAIL ") + name + ("" if detail is None else ": " + json.dumps(detail, default=str)[:400]), flush=True)
    return bool(ok)


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
                               headers={"content-type": "application/json", "user-agent": "automations-staging-proof", **(headers or {})})
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"null")


st, signed = http("https://api.stack-auth.com/api/v1/auth/password/sign-in",
                  {"email": vals["CMUX_UITEST_STACK_EMAIL"], "password": vals["CMUX_UITEST_STACK_PASSWORD"]},
                  {"x-hexclave-project-id": project, "x-hexclave-publishable-client-key": client_key, "x-hexclave-access-type": "client"})
if st != 200:
    sys.exit(f"test account sign-in: HTTP {st}")
AUTH = {"authorization": "Bearer " + signed["access_token"]}


def op(name, params, key):
    return http(o.api + "/v1/ops", {"op": name, "params": params, "origin": "cli", "idempotency_key": key}, AUTH)[1] or {}


def read(name, params):
    return http(o.api + "/v1/read", {"op": name, "params": params}, AUTH)[1] or {}


stamp = time.strftime("%Y%m%d%H%M%S")
try:
    op("user.ensure", {}, f"asp-ensure-{stamp}")
    chiefs = (read("chief.list", {}).get("value") or {}).get("chiefs") or []
    active = [c for c in chiefs if not c.get("archived_at")]
    chief = next((c for c in active if c.get("is_default")), active[0] if active else None)
    if not chief:
        chief = (op("chief.create", {"display_name": "Chief"}, "chief-default").get("value") or {})
    check("default Cloud Chief", bool(chief.get("id") and chief.get("main_conversation")), {"chief": chief.get("id")})

    def job(name):
        return {"name": name, "triggers": [{"type": "cron", "expr": "0 9 * * 1-5", "tz": "America/Los_Angeles"}, {"type": "manual"}],
                "body": {"type": "chief", "chief": chief["id"], "conversation": chief["main_conversation"],
                         "prompt": "Staging proof of cmux automation --target cloud: reply with one line, 'automation ran'."}}

    # Delete leftovers of earlier proof runs, so the free cap counts only this run.
    listed = (read("automation.list", {"limit": 100}).get("value") or {}).get("automations") or []
    for a in listed:
        if a.get("name", "").startswith("a908 staging proof"):
            op("automation.delete", {"automation": a["id"]}, f"asp-clean-{a['id']}")
    key = f"asp-create-{stamp}"
    first = op("automation.create", job(f"a908 staging proof {stamp}"), key)
    again = op("automation.create", job(f"a908 staging proof {stamp}"), key)
    auto = (first.get("value") or {}).get("id")
    if auto:
        made.append(auto)
    check("create chief job", bool(first.get("ok") and auto), first.get("error") or {"id": auto})
    check("retry with the same key is the same job", (again.get("value") or {}).get("id") == auto, again.get("error"))

    ran = op("automation.run", {"automation": auto}, f"asp-run-{stamp}")
    run_id = (ran.get("value") or {}).get("id") or ((ran.get("value") or {}).get("run") or {}).get("id")
    check("run now", bool(ran.get("ok") and run_id), ran.get("error") or {"run": run_id})
    state, runs = None, []
    for _ in range(45):  # proof harness wait on the API, not app code
        runs = (read("automation.runs.list", {"automation": auto, "limit": 10}).get("value") or {}).get("runs") or []
        mine = next((r for r in runs if r.get("id") == run_id), None)
        state = mine and mine.get("state")
        if state and state not in ("queued", "running"):
            break
        time.sleep(2)
    check("run history shows the run", any(r.get("id") == run_id for r in runs), {"state": state, "runs": [(r.get("id"), r.get("state"), (r.get("error") or {}).get("code")) for r in runs]})

    second = op("automation.create", job(f"a908 staging proof {stamp} second"), f"asp-second-{stamp}")
    if second.get("ok"):
        made.append(second["value"]["id"])
        check("second job (paid plan: not capped)", True, {"id": second["value"]["id"]})
    else:
        err = second.get("error") or {}
        check("second job on the free plan answers automation.plan.required with a checkout link",
              err.get("code") == "automation.plan.required" and bool((err.get("details") or {}).get("checkout")),
              {"code": err.get("code"), "checkout_host": re.sub(r"(https?://[^/]+).*", r"\1", str((err.get("details") or {}).get("checkout")))})
finally:
    for a in made:
        r = op("automation.delete", {"automation": a}, f"asp-delete-{a}")
        check(f"delete {a}", r.get("ok"), r.get("error"))
    os.makedirs(os.path.dirname(o.out) or ".", exist_ok=True)
    RESULT["finished_at"] = time.time()
    json.dump(RESULT, open(o.out, "w"), indent=2)
sys.exit(0 if all(c["ok"] for c in RESULT["checks"].values()) else 1)
