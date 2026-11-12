#!/usr/bin/env python3
"""Leo's Cloud V0 item 1, measured on the product path from a tagged DEV app (cloud-chat-proof.yml `met`).

Leo: "A chat starts in a few seconds: ready spare, harness login attached in advance, no 10 s relay credential
timeout, no first-boot self-update."

The tagged app runs signed in as the staging agent test account for the whole run. Each of `--claims` claims
(default 10, `--gap` 150 s apart) is one person-session start, `cmux cloud start-chat --wait` through the app's
own CLI, and its first chat. Before each claim this script, signed in as the same account:

1. warms the account's spare (POST /v1/cloud/spare/warm, the app's own intent warm) and waits until it runs;
2. waits, bounded, until the spare holds this run's Claude login. Nothing here puts it there: the app copies it when
   the platform tells it the spare is ready (cloud.spare.ready, cmux-platform#1349; the app's handler, cmux#41676);
3. points Claude Code on the spare at the shared model stub (tests/fixtures/model-stub), the one stand-in, as
   cloud-journey.ts --model stub does. It runs after the login is there: the installer refuses a custom endpoint;
4. reads the spare's credential mark once more just before the claim (login_on_spare_at_claim).

The claim's start passes `--login machine`: it copies no login of its own and refuses when the machine has none,
so a reply proves the login was there in advance. The login is made up (sk-ant-oat01-journeystub-...), seeded into
the app's own cache (`cmux cloud secret set`, the store a `claude setup-token` sign-in fills); no real login
exists. The stub logs the SHA-256 of the login every model request carried, so the run checks the reply came with
the login the app copied.

Per claim: real claim (the start's machine is the warmed spare, which ran before the claim),
login_on_spare_at_claim, create / bound / reply / reply_turn (seconds; create and bound are the start's own
`stages_ms`, through `machine` and through `connect`; reply is the start-chat call to its reply; reply_turn is the
reply after the session started), bound - create and reply - bound. The summary (p50 and p90 over real claims, and
over real claims with the login on the spare) goes to --out as met.json and met.md.

Each claim's machine is killed after its chat. At the end the cached login is removed and any spare this run wrote
to (the stub, or a login of this run) that no claim took is deleted, so no later run of the account finds either.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

STACK_API = "https://api.stack-auth.com"
# cloud-journey.ts STACK.dev: staging signs in through the dev Stack project.
STACK_DEV = {"project": "454ecd03-1db2-4050-845e-4ce5b0cd9895",
             "client_key": "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"}
MODEL_STUB = Path(__file__).resolve().parents[2] / "tests/fixtures/model-stub/model_stub.py"
# CloudCredentialLogin.service: the Keychain service `cmux cloud secret set` stores under.
KEYCHAIN_SERVICE = "cmux-cloud-secret"
MACHINE_ID = re.compile(r"^vm_[A-Za-z0-9]{8,64}$")
PROMPT = "Reply with exactly the text ok and nothing else."
GUEST_DIR = "/home/cmux/.cmux"
STUB_PATH = f"{GUEST_DIR}/met-model-stub.py"
STUB_LOG = f"{GUEST_DIR}/met-model-stub.log"
STUB_READY = f"{GUEST_DIR}/met-model-stub.ready"
STUB_PID = f"{GUEST_DIR}/met-model-stub.pid"
# The metrics the summary takes p50 and p90 of.
METRICS = ("create_s", "bound_s", "reply_s", "reply_turn_s", "bound_minus_create_s", "reply_minus_bound_s")


# --- Pure parts (tests/test_cloud_spare_met.py) ------------------------------------------------------------------

def made_up_login() -> str:
    """A setup-token shape no provider ever issued (cloud-journey.ts --model stub's): CloudCredentialTransfer.validate
    takes it (sk-ant-oat01-, 32+ printable characters), and only the model stub ever sees it."""
    return f"sk-ant-oat01-journeystub-{secrets.token_hex(24)}"


def transfer_name(user_id: str, team_id: str | None = None) -> str:
    """CloudCredentialLogin.name for Claude: the cached login's secret name under one scope (nil team: personal)."""
    scope = hashlib.sha256(f"{user_id}:{team_id or 'personal'}:".encode()).digest()[:12].hex()
    return f"CLAUDE_TRANSFER_{scope}"


def envelope(login: str, now: float) -> bytes:
    """CloudCredentialLogin.store's envelope: {"created": T, "credential": BASE64}."""
    return json.dumps({"created": now, "credential": base64.b64encode(login.encode()).decode()},
                      separators=(",", ":")).encode()


def digest(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def mark_command(want: str) -> str:
    """The spare's credential mark, as the probe reads it (cmux_agent_has_own_login claude), and whether the login
    Claude would use there is this run's (by its SHA-256, the installer's own `installed()`; never the login)."""
    return (
        "if sudo -n bash -c '. /etc/cmux/agent-auth.sh && HOME=/home/cmux cmux_agent_has_own_login claude' "
        ">/dev/null 2>&1; then o=yes; else o=no; fi; "
        "d=$(sudo -n python3 -I -c 'import hashlib, json\n"
        "try: e = json.load(open(\"/home/cmux/.claude/settings.json\")).get(\"env\", {})\n"
        "except Exception: e = {}\n"
        "v = e.get(\"CLAUDE_CODE_OAUTH_TOKEN\")\n"
        "print(hashlib.sha256(v.encode()).hexdigest() if isinstance(v, str) and v else \"\")' 2>/dev/null); "
        f"m=no; [ -n \"$d\" ] && [ \"$d\" = {want} ] && m=yes; echo \"MARK own=$o this_run=$m\""
    )


def read_mark(stdout: str) -> dict:
    found = re.search(r"MARK own=(yes|no) this_run=(yes|no)", stdout or "")
    if not found:
        return {"read": False, "own_login": None, "this_run": None}
    return {"read": True, "own_login": found.group(1) == "yes", "this_run": found.group(2) == "yes"}


def stub_command(nonce: str) -> str:
    """Starts the stub on the spare's loopback (port 0: it picks one) and points Claude Code's settings at it, as
    cloud-journey.ts's "model stub on the machine" step does. Prints stub-ready."""
    return (
        f"rm -f {STUB_LOG} {STUB_READY} {STUB_PID}; "
        f"(nohup python3 {STUB_PATH} --port 0 --nonce {nonce} --log {STUB_LOG} --ready-file {STUB_READY} "
        f">{STUB_LOG}.out 2>&1 & echo $! >{STUB_PID}); "
        f"for i in $(seq 50); do [ -s {STUB_READY} ] && break; sleep 0.2; done; "
        f"port=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"port\"])' {STUB_READY} 2>/dev/null); "
        f"[ -n \"$port\" ] && curl -fsS -m 2 \"http://127.0.0.1:$port/__stub/info\" | grep -q {nonce} "
        f"|| {{ echo stub-down; tail -5 {STUB_LOG}.out; exit 1; }}; "
        "python3 - \"$port\" <<'PY'\nimport json, pathlib, sys\np = pathlib.Path('/home/cmux/.claude/settings.json')\n"
        "c = json.loads(p.read_text()) if p.exists() else {}\n"
        "c.setdefault('env', {})['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:' + sys.argv[1]\n"
        "p.write_text(json.dumps(c))\nprint('stub-ready')\nPY"
    )


def stub_turns(log_text: str) -> list[dict]:
    """The model requests of real turns the stub logged (streamed POSTs, not Claude Code's side requests)."""
    rows = []
    for line in (log_text or "").splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if isinstance(row, dict) and row.get("method") == "POST" and row.get("stream") and not row.get("side"):
            rows.append(row)
    return rows


def stage_times(stages: object) -> dict:
    """The start's `stages_ms` (each step's own ms, in order) as seconds through `machine` (create), through `connect`
    (bound) and through `start` (the session started). None for a step the answer does not list."""
    out = {"create_s": None, "bound_s": None, "started_s": None}
    if not isinstance(stages, list):
        return out
    total = 0
    for row in stages:
        if not isinstance(row, dict) or not isinstance(row.get("ms"), (int, float)):
            continue
        total += row["ms"]
        key = {"machine": "create_s", "connect": "bound_s", "start": "started_s"}.get(row.get("step"))
        if key:
            out[key] = round(total / 1000, 3)
    return out


def login_steps(detail: object) -> list[str]:
    """The login sub-steps the start marked (`stages_detail_ms.steps`: login.receipt, login.machine, ...)."""
    steps = detail.get("steps") if isinstance(detail, dict) else None
    return [s["step"] for s in steps or [] if isinstance(s, dict) and str(s.get("step", "")).startswith("login")]


def claim_row(*, index: int, spare: str | None, spare_ran: bool, mark: dict, answer: dict, exit_code: int,
              wall_s: float, reply: str, nonce: str, login_sha: str, turns: list[dict]) -> dict:
    machine = answer.get("machine_id") if isinstance(answer.get("machine_id"), str) else None
    times = stage_times(answer.get("stages_ms"))
    replied = exit_code == 0 and f"Stub reply {nonce}." in (reply or "")
    row = {
        "claim": index,
        "spare": spare,
        "machine": machine,
        "real_claim": bool(spare and machine == spare and spare_ran),
        "login_on_spare_at_claim": mark.get("this_run") is True,
        "own_login_mark": mark.get("own_login"),
        "start_exit": exit_code,
        "replied": replied,
        # Every model request of the turn carried this run's login: the copy reached the model.
        "login_reached_model": bool(turns) and all(t.get("cred_sha256") == login_sha for t in turns),
        "login_steps": login_steps(answer.get("stages_detail_ms")),
        "create_s": times["create_s"],
        "bound_s": times["bound_s"],
        "reply_s": round(wall_s, 3) if replied else None,
    }
    row["reply_turn_s"] = round(wall_s - times["started_s"], 3) if replied and times["started_s"] is not None else None
    row["bound_minus_create_s"] = (round(row["bound_s"] - row["create_s"], 3)
                                   if row["bound_s"] is not None and row["create_s"] is not None else None)
    row["reply_minus_bound_s"] = (round(row["reply_s"] - row["bound_s"], 3)
                                  if row["reply_s"] is not None and row["bound_s"] is not None else None)
    return row


def percentile(values: list[float], q: float) -> float | None:
    """Nearest-rank percentile (q in 0..100)."""
    if not values:
        return None
    ordered = sorted(values)
    rank = max(1, -(-len(ordered) * q // 100))
    return ordered[int(rank) - 1]


def summarize(rows: list[dict]) -> dict:
    def stats(subset: list[dict]) -> dict:
        out = {"n": len(subset)}
        for key in METRICS:
            values = [r[key] for r in subset if isinstance(r.get(key), (int, float))]
            out[key] = {"p50": percentile(values, 50), "p90": percentile(values, 90), "n": len(values)}
        return out
    real = [r for r in rows if r.get("real_claim")]
    with_login = [r for r in real if r.get("login_on_spare_at_claim")]
    passed = bool(rows) and all(r.get("real_claim") and r.get("login_on_spare_at_claim") and r.get("replied")
                                and r.get("login_reached_model") for r in rows)
    return {"claims": len(rows), "real_claims": len(real), "real_with_login": len(with_login),
            "replied": sum(1 for r in rows if r.get("replied")), "pass": passed,
            "real": stats(real), "real_with_login_stats": stats(with_login)}


def markdown(rows: list[dict], summary: dict, meta: dict) -> str:
    def cell(v):
        return "-" if v is None else ("yes" if v is True else "no" if v is False else str(v))
    lines = ["## Cloud V0 item 1, measured (staging, product path)", "",
             "> Leo: \"A chat starts in a few seconds: ready spare, harness login attached in advance, no 10 s relay "
             "credential timeout, no first-boot self-update.\"", ""]
    lines += [f"- {k}: {cell(v)}" for k, v in meta.items()]
    lines += [f"- claims: {summary['claims']}, real claims: {summary['real_claims']}, real with the login on the spare: "
              f"{summary['real_with_login']}, replied: {summary['replied']}", f"- result: {'pass' if summary['pass'] else 'fail'}", ""]
    lines += ["| set | n | " + " | ".join(f"{m} p50 / p90" for m in METRICS) + " |",
              "|---|---|" + "---|" * len(METRICS)]
    for label, block in (("real claims", summary["real"]), ("real, login on spare", summary["real_with_login_stats"])):
        lines.append(f"| {label} | {block['n']} | " + " | ".join(
            f"{cell(block[m]['p50'])} / {cell(block[m]['p90'])}" for m in METRICS) + " |")
    cols = ("claim", "real_claim", "login_on_spare_at_claim", "replied", "login_reached_model", "create_s", "bound_s",
            "reply_s", "reply_turn_s", "bound_minus_create_s", "reply_minus_bound_s", "login_steps", "spare", "machine")
    lines += ["", "| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    for r in rows:
        lines.append("| " + " | ".join(cell(",".join(r[c]) if isinstance(r.get(c), list) else r.get(c)) for c in cols) + " |")
    return "\n".join(lines) + "\n"


# --- The run -----------------------------------------------------------------------------------------------------

class Api:
    """The agent test account's own session on the Cloud API (the same account the app is signed in as)."""

    def __init__(self, origin: str, email: str, password: str):
        self.origin, self.email, self.password = origin.rstrip("/"), email, password
        self.access, self.user = "", ""

    def sign_in(self) -> None:
        body = self._http("POST", f"{STACK_API}/api/v1/auth/password/sign-in",
                          {"email": self.email, "password": self.password},
                          {"x-stack-access-type": "client", "x-stack-project-id": STACK_DEV["project"],
                           "x-stack-publishable-client-key": STACK_DEV["client_key"]})[1]
        if not isinstance(body.get("access_token"), str) or not isinstance(body.get("user_id"), str):
            raise RuntimeError("Stack sign-in gave no session")
        self.access, self.user = body["access_token"], body["user_id"]

    @staticmethod
    def _http(method: str, url: str, body: object, headers: dict, timeout: float = 60) -> tuple[int, dict]:
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, method=method,
                                         headers={**headers, **({"content-type": "application/json"} if data else {})})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as answer:
                status, text = answer.status, answer.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            status, text = error.code, error.read().decode("utf-8", "replace")
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            return 0, {"error": {"code": "transport", "message": str(error)[:200]}}
        try:
            parsed = json.loads(text) if text else {}
        except ValueError:
            parsed = {"raw": text[:300]}
        return status, parsed if isinstance(parsed, dict) else {"value": parsed}

    def call(self, method: str, route: str, body: object = None, timeout: float = 60) -> tuple[int, dict]:
        for attempt in (1, 2):
            status, answer = self._http(method, f"{self.origin}{route}", body,
                                        {"authorization": f"Bearer {self.access}"}, timeout)
            if status == 401 and attempt == 1:
                self.sign_in()  # a Stack access token lasts minutes; the run lasts half an hour
                continue
            return status, answer
        return status, answer

    def value(self, answer: dict) -> dict:
        v = answer.get("value", answer)
        return v if isinstance(v, dict) else {}

    def machine(self, machine: str) -> dict:
        status, answer = self.call("POST", "/v1/read", {"op": "cloud.machine.get", "params": {"machine": machine}})
        return self.value(answer) if status == 200 else {}

    def exec(self, machine: str, command: str, timeout_ms: int = 60_000) -> dict:
        """The guest exec route the probe uses; a just-resumed machine's 502 vm_unavailable is asked again."""
        for _ in range(5):
            status, answer = self.call("POST", f"/v1/cloud/machines/{machine}/exec",
                                       {"command": command, "timeoutMs": timeout_ms}, timeout_ms / 1000 + 30)
            v = self.value(answer)
            if status == 502 and (answer.get("error") or {}).get("code") == "vm_unavailable":
                time.sleep(3)
                continue
            return {"status": status, "exit": v.get("exitCode"), "stdout": str(v.get("stdout") or ""),
                    "stderr": str(v.get("stderr") or "")}
        return {"status": status, "exit": None, "stdout": "", "stderr": "vm_unavailable"}

    def write(self, machine: str, path: str, data: bytes) -> bool:
        status, answer = self.call("POST", f"/v1/cloud/machines/{machine}/fs/write",
                                   {"path": path, "dataBase64": base64.b64encode(data).decode(), "mode": 0o644}, 120)
        return 200 <= status < 300 and answer.get("ok") is not False


def wait_until(seconds: float, step: float, probe):
    """PROBE() until truthy or SECONDS pass (a harness wait, not product code); its last value."""
    deadline = time.monotonic() + seconds
    while True:
        value = probe()
        if value or time.monotonic() >= deadline:
            return value
        time.sleep(step)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, help="the tagged app bundle")
    parser.add_argument("--tag", required=True)
    parser.add_argument("--cloud-backend", default="staging", choices=("staging",))
    parser.add_argument("--expected-api-origin", default="https://cloud-api-staging.cmux.dev")
    parser.add_argument("--credentials-file", required=True, help="0600 Stack credentials file read by the app")
    parser.add_argument("--claims", type=int, default=10)
    parser.add_argument("--gap", type=float, default=150, help="seconds from one claim to the next")
    parser.add_argument("--login-wait", type=float, default=120,
                        help="seconds a running spare may take to get the login from the app")
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    if not 1 <= args.claims <= 20:
        parser.error("--claims takes 1..20")
    email, password = os.environ.get("MET_STACK_EMAIL", ""), os.environ.get("MET_STACK_PASSWORD", "")
    if not email or not password:
        parser.error("MET_STACK_EMAIL and MET_STACK_PASSWORD (the account the app signs in as) are required")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    cli = str(Path(args.app) / "Contents/Resources/bin/cmux")
    socket = f"/tmp/cmux-debug-{args.tag}.sock"
    env = {**os.environ, "CMUX_SOCKET_PATH": socket, "CMUX_NEXT_SOCKET_PATH": socket}
    env.pop("MET_STACK_PASSWORD", None)
    log: list[dict] = []
    rows: list[dict] = []
    touched: dict[str, bool] = {}  # spare -> taken by a claim
    claimed: set[str] = set()
    login = made_up_login()
    login_sha = digest(login)
    scrub = (login, password)

    def note(step: str, **fields) -> None:
        text = json.dumps({"step": step, **fields})
        for value in scrub:
            text = text.replace(value, "[withheld]")
        print(text, flush=True)
        log.append(json.loads(text))

    def cmux(*words: str, timeout: int = 120, stdin: bytes | None = None) -> tuple[int, str, str]:
        try:
            done = subprocess.run([cli, *words], env=env, input=stdin, capture_output=True, timeout=timeout)
            return done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace")
        except subprocess.TimeoutExpired:
            return 124, "", f"timed out after {timeout}s"

    def parsed(text: str) -> dict:
        for candidate in [text, *reversed(text.splitlines())]:
            try:
                value = json.loads(candidate)
            except ValueError:
                continue
            if isinstance(value, dict):
                value = value.get("result", value)
                return value if isinstance(value, dict) else {}
        return {}

    api = Api(args.expected_api_origin, email, password)
    api.sign_in()
    note("api sign-in", ok=True)
    name = transfer_name(api.user)

    # The app, launched as cloud-chat-proof.py launches it, signed in from the credentials file, up for the run.
    launch = ["/usr/bin/open", "-W", "-g", "-n", "--env", f"CMUX_NEXT_SOCKET_PATH={socket}",
              "--env", f"CMUX_AUTH_CREDENTIALS_FILE={args.credentials_file}", "--env", "CMUX_DEV_AUTH_PROFILE=agent",
              "--env", "CMUX_DEV_AUTH_REPLACE_SESSION=1", str(Path(args.app).resolve()), "--args",
              "--cloud-backend", args.cloud_backend]
    launcher = subprocess.Popen(launch, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    result = "fail: the run did not finish"
    try:
        signed = wait_until(240, 5, lambda: (lambda v: v if v.get("signed_in") is True and str(v.get("backend", "")).rstrip("/")
                                             == args.expected_api_origin.rstrip("/") else None)(
            parsed(cmux("app", "call", "auth.status", "--json", timeout=30)[1])))
        note("app signed in", ok=bool(signed), backend=(signed or {}).get("backend"))
        if not signed:
            raise SystemExit("the app did not sign in to the selected backend")

        # The made-up login in the app's own cache, where a person's `claude setup-token` sign-in puts theirs.
        code, _, err = cmux("cloud", "secret", "set", name, stdin=envelope(login, time.time()), timeout=70)
        found = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", f"*/{name}"],
                               capture_output=True).returncode == 0
        note("cached login seeded", exit=code, found=found, stderr=err[-300:])
        if code != 0 or not found:
            raise SystemExit("the made-up login could not be cached")

        stub = MODEL_STUB.read_bytes()
        first = time.monotonic()
        for index in range(args.claims):
            nonce = secrets.token_hex(6)
            def warmed():
                status, answer = api.call("POST", "/v1/cloud/spare/warm", {})
                spare = api.value(answer).get("machine")
                note("warm", claim=index, status=status, spare=spare if isinstance(spare, str) else None)
                return spare if isinstance(spare, str) and MACHINE_ID.match(spare) else None
            # An account with no spare yet gets the Scaler's fill (its alarm runs about once a minute): asked again
            # for up to one gap, so the first claim is not lost to a cold account.
            spare = wait_until(args.gap, 10, warmed)
            ran = bool(spare) and bool(wait_until(240, 2, lambda: api.machine(spare).get("status") == "running"))
            mark = {"read": False, "own_login": None, "this_run": None}
            login_wait_s = None
            if ran:
                touched.setdefault(spare, False)
                begun = time.monotonic()
                mark = wait_until(args.login_wait, 3, lambda: (lambda m: m if m.get("this_run") else None)(
                    read_mark(api.exec(spare, mark_command(login_sha))["stdout"]))) or read_mark(
                    api.exec(spare, mark_command(login_sha))["stdout"])
                login_wait_s = round(time.monotonic() - begun, 1)
            note("login on the spare", claim=index, ran=ran, waited_s=login_wait_s, **mark)
            if mark.get("this_run"):
                api.exec(spare, f"mkdir -p {GUEST_DIR}")
                wrote = api.write(spare, STUB_PATH, stub)
                fixed = api.exec(spare, f"sudo -n chmod a+r {STUB_PATH}")
                started = api.exec(spare, stub_command(nonce))
                note("model stub on the spare", claim=index, wrote=wrote, chmod=fixed["exit"],
                     ready="stub-ready" in started["stdout"], stdout=started["stdout"][-200:])
            # The claim on the schedule: claim N at N * gap from the first, or at once when the spare took longer.
            time.sleep(max(0.0, first + index * args.gap - time.monotonic()))
            at_claim = read_mark(api.exec(spare, mark_command(login_sha))["stdout"]) if ran else mark
            spare_ran = ran and api.machine(spare).get("status") == "running"
            t0 = time.monotonic()
            code, out_text, err = cmux("cloud", "start-chat", "--prompt", PROMPT, "--agent", "claude", "--login", "machine",
                                       "--wait", "--timeout", "300", "--json", timeout=360)
            wall = time.monotonic() - t0
            answer = parsed(out_text) if code == 0 else {}
            failure = parsed(err) or parsed(out_text)
            details = failure.get("details") if isinstance(failure.get("details"), dict) else {}
            machine = answer.get("machine_id") or details.get("machine_id") or (details.get("answer") or {}).get("machine_id")
            turns = []
            if isinstance(machine, str) and MACHINE_ID.match(machine):
                claimed.add(machine)
                if machine in touched:
                    touched[machine] = True
                    turns = stub_turns(api.exec(machine, f"cat {STUB_LOG} 2>/dev/null")["stdout"])
            row = claim_row(index=index, spare=spare, spare_ran=spare_ran, mark=at_claim, answer=answer, exit_code=code,
                            wall_s=wall, reply=str(answer.get("reply") or ""), nonce=nonce, login_sha=login_sha, turns=turns)
            if code != 0:
                row["start_error"] = f"{failure.get('code', '')}: {str(failure.get('message', ''))[:300]}".strip(": ")
            rows.append(row)
            note("claim", **row)
            if isinstance(machine, str) and MACHINE_ID.match(machine):
                kcode, _, kerr = cmux("cloud", "kill-machine", "--target", f"machine:{machine}", "--confirm", "--json")
                note("kill the claim's machine", claim=index, machine=machine, exit=kcode, stderr=kerr[-200:])
        summary = summarize(rows)
        result = "pass" if summary["pass"] else "fail: not every claim was a real claim with the login attached and a reply"
    finally:
        # No later run of the account may find this run's login: out of the cache first (a refill told ready after
        # this copies nothing), then the app quits, then every spare this run wrote to that no claim took goes.
        subprocess.run(["/usr/bin/security", "delete-generic-password", "-s", KEYCHAIN_SERVICE, "-a", f"*/{name}"],
                       capture_output=True)
        note("cached login removed")
        cmux("app", "quit", "--json", timeout=30)
        try:
            launcher.wait(timeout=60)
        except subprocess.TimeoutExpired:
            note("app exit", ok=False)
        status, answer = api.call("POST", "/v1/cloud/spare/warm", {})
        last = api.value(answer).get("machine")
        if isinstance(last, str) and MACHINE_ID.match(last) and last not in touched and last not in claimed:
            if wait_until(240, 2, lambda: api.machine(last).get("status") == "running"):
                if read_mark(api.exec(last, mark_command(login_sha))["stdout"]).get("this_run"):
                    touched[last] = False  # a refill the app copied this run's login onto before it quit
        for spare, taken in touched.items():
            if taken or spare in claimed:
                continue
            status, answer = api.call("POST", "/v1/ops", {"op": "cloud.machine.delete", "params": {"machine": spare},
                                                          "idempotency_key": f"met-{args.tag}-{spare}"})
            note("delete a spare this run wrote to", machine=spare, status=status)
        summary = summarize(rows)
        meta = {"tag": args.tag, "backend": args.expected_api_origin, "claims asked": args.claims, "gap_s": args.gap,
                "result": result}
        (out / "met.json").write_text(json.dumps({"meta": meta, "summary": summary, "claims": rows, "log": log},
                                                 indent=2) + "\n")
        (out / "met.md").write_text(markdown(rows, summary, meta))
        print(f"result: {result}", flush=True)
    sys.exit(0 if result == "pass" else 1)


if __name__ == "__main__":
    main()
