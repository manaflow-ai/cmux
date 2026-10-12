#!/usr/bin/env python3
"""T1 of cx-psxg (cx-0q7o slice 2d): the keyed acpmux start on a Cloud machine,
at the HTTP boundary of ONE development stack (scripts/dev-backend.sh tag), on a
real provider VM. Development only: it refuses an origin that is not loopback.

Runs on the shared dev-backend host, next to the stack it tests, because the
stack's container log and database are read there too. Python standard
library only (the host has no bun or node).

  python3 -I acpmux_person_key_e2e.py --origin http://127.0.0.1:<port> \
      --container <web container> --db-container <postgres container> --out <dir> < secrets

stdin: KEY=VALUE lines, never printed: CMUX_UITEST_STACK_EMAIL/_PASSWORD (the
agent account), optional CMUX_AGENT2_STACK_EMAIL/_PASSWORD (a second agent
account, for the not-the-owner case), optional FREESTYLE_API_KEY (the
development key; used only for the spool probe, on a VM of that account).

The test key K is made here, sent only as the route's body, kept in this
process, and searched for (hex, base64 of the stdin line, raw bytes) in what
the run brings back: the guest's process table, environments, provider exec
scratch, journal and acpmux logs, the stack's container log and a dump of its
database. Every machine this run creates is recorded in <out>/machines.tsv
and deleted by its exact id at the end (also on failure). Nothing is ever
deleted from a list call.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

STACK_API = "https://api.stack-auth.com/api/v1"
DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
DEV_STACK_CLIENT_KEY = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
FREESTYLE_API = "https://api.freestyle.sh"


class Run:
    def __init__(self, out):
        self.out = out
        self.steps = []
        os.makedirs(out, exist_ok=True)

    def record(self, step, ok, ms, detail):
        self.steps.append({"step": step, "ok": ok, "ms": ms, "detail": detail})
        print(f"{'PASS' if ok else 'FAIL'} {step} {ms} ms :: {detail}", flush=True)
        with open(os.path.join(self.out, "t1.json"), "w") as f:
            json.dump({"steps": self.steps}, f, indent=2)

    def step(self, name, fn):
        t0 = time.monotonic()
        try:
            ok, detail, value = fn()
        except Exception as e:  # a step failure is recorded, then the run goes on to cleanup
            ok, detail, value = False, f"{type(e).__name__}: {str(e)[:300]}", None
        self.record(name, ok, int((time.monotonic() - t0) * 1000), detail)
        return value


def http(method, url, headers=None, body=None, timeout=60):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def jbody(raw):
    try:
        return json.loads(raw.decode() or "{}")
    except ValueError:
        return {"raw": raw[:200].decode(errors="replace")}


def stack_headers():
    return {
        "x-stack-project-id": DEV_STACK_PROJECT,
        "x-stack-publishable-client-key": DEV_STACK_CLIENT_KEY,
        "x-stack-access-type": "client",
        "content-type": "application/json",
    }


def sign_in(email, password):
    status, raw = http("POST", f"{STACK_API}/auth/password/sign-in", stack_headers(),
                       json.dumps({"email": email, "password": password}).encode())
    body = jbody(raw)
    if status != 200 or "access_token" not in body:
        raise RuntimeError(f"Stack sign-in answered {status} {body.get('code', '')}")
    session = {"access": body["access_token"], "refresh": body["refresh_token"]}
    h = {**stack_headers(), "x-stack-access-token": session["access"], "x-stack-refresh-token": session["refresh"]}
    _, me = http("GET", f"{STACK_API}/users/me", h)
    me = jbody(me)
    session["user"] = me.get("id")
    session["team"] = me.get("selected_team_id") or (me.get("selected_team") or {}).get("id")
    return session


def sign_out(session):
    h = {**stack_headers(), "x-stack-access-token": session["access"], "x-stack-refresh-token": session["refresh"]}
    http("DELETE", f"{STACK_API}/auth/sessions/current", h, b"{}")


class Api:
    def __init__(self, origin, session):
        self.origin, self.session = origin, session

    def headers(self, extra=None):
        h = {"authorization": f"Bearer {self.session['access']}", "x-stack-refresh-token": self.session["refresh"],
             "x-cmux-client": "cmux-mac", "x-cmux-app-version": "cx-psxg-t1", "accept": "application/json"}
        if self.session.get("team"):
            h["x-cmux-team-id"] = self.session["team"]
        return {**h, **(extra or {})}

    def call(self, method, path, body=None, extra=None, timeout=120):
        data = None if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        h = self.headers(extra)
        if body is not None and not isinstance(body, bytes):
            h["content-type"] = "application/json"
        status, raw = http(method, f"{self.origin}{path}", h, data, timeout)
        return status, jbody(raw), raw

    def exec_root(self, vm, command, timeout_ms=60_000):
        status, body, _ = self.call("POST", f"/api/vm/{vm}/exec", {"command": command, "timeoutMs": timeout_ms},
                                    timeout=timeout_ms / 1000 + 30)
        if status != 200:
            raise RuntimeError(f"exec answered {status} {body.get('error')}")
        return body


def holds_proof(key_hex, instance, nonce):
    message = b"acpmux-person-holds-v1" + b"\0" + instance.encode() + b"\0" + nonce.encode()
    return hmac.new(bytes.fromhex(key_hex), message, hashlib.sha256).hexdigest()


def key_needles(key_hex):
    line = (key_hex + "\n").encode()
    return {
        "hex": key_hex.encode(),
        "HEX": key_hex.upper().encode(),
        "base64-line": base64.b64encode(line),
        "base64-key-hex": base64.b64encode(key_hex.encode()),
        "raw": bytes.fromhex(key_hex),
        "base64-raw": base64.b64encode(bytes.fromhex(key_hex)),
    }


def find(haystack, needles):
    return sorted(name for name, needle in needles.items() if needle in haystack)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--origin", required=True)
    ap.add_argument("--container", required=True)
    ap.add_argument("--db-container", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--cmux-tui-sha256", help="sha256 of that build's cmux-tui-x86_64-unknown-linux-musl (from its manifest)")
    ap.add_argument("--cmux-tui-commit", help="published cmux-tui build to install on the test machine when its own has no keyed start")
    args = ap.parse_args()
    if urlparse(args.origin).hostname not in ("127.0.0.1", "localhost"):
        sys.exit(f"refusing {args.origin}: a loopback development stack only")
    env = {}
    for line in sys.stdin.read().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip().removeprefix("export ").strip()] = v.strip().strip("'\"")
    run = Run(args.out)
    machines_tsv = os.path.join(args.out, "machines.tsv")
    created = []
    sessions = []
    key_hex = secrets.token_bytes(32).hex()
    needles = key_needles(key_hex)
    try:
        agent = run.step("signin agent", lambda: (True, "agent account", sign_in(env["CMUX_UITEST_STACK_EMAIL"], env["CMUX_UITEST_STACK_PASSWORD"])))
        if not agent:
            return 1
        sessions.append(agent)
        api = Api(args.origin, agent)

        def create():
            status, body, _ = api.call("POST", "/api/vm", {"displayName": "cmuxnp-dev-psxg-t1"},
                                       {"idempotency-key": f"psxg-t1-{secrets.token_hex(8)}"}, timeout=700)
            vm = body.get("id") or body.get("providerVmId") or (body.get("vm") or {}).get("id")
            if vm:
                created.append(vm)
                with open(machines_tsv, "a") as f:
                    f.write(f"{vm}\t{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
            return status in (200, 201) and bool(vm), f"HTTP {status} id {vm} status {body.get('status')}", vm
        vm = run.step("create machine", create)
        if not vm:
            return 1

        def wait_running():
            # Test-side bounded wait for the provisioned machine; the product never polls.
            t0 = time.monotonic()
            last = None
            while time.monotonic() - t0 < 600:
                _, last, _ = api.call("GET", f"/api/vm/{vm}")
                if last.get("status") == "running":
                    return True, "running", last
                time.sleep(3)
            return False, f"last status {last and last.get('status')}", last
        if not run.step("machine running", wait_running):
            return 1

        def probe():
            r = api.exec_root(vm, "set -e; for b in /home/cmux/.cmux/bin/cmux-tui /root/.cmux/bin/cmux-tui; do [ -x $b ] && { echo bin=$b; $b --version 2>&1 | head -1; $b acp daemon start --help 2>&1 | grep -c -- --person-key-fd || true; }; done; ls -ld /tmp/.freestyle-exec-* 2>/dev/null | head -5 || true; pgrep -a -f '[a]cp.*daemon' | head -5 || true")
            out = r["stdout"]
            with open(os.path.join(args.out, "probe.txt"), "w") as f:
                f.write(out)
            supported = any(l.strip().isdigit() and int(l.strip()) > 0 for l in out.splitlines())
            return supported, out.replace("\n", " | ")[:300], supported
        # Information only: an old binary is the next step's case.
        supported = run.step("guest cmux-tui keyed start support (information)", lambda: (True, *probe()[1:]))

        def inventory():
            r = api.exec_root(vm, "echo \"markers: vm-kind=$(cat /etc/cmux/vm-kind 2>/dev/null || echo none) image-stamp=$([ -e /etc/cmux/image-stamp ] && echo yes || echo no) bake-instance-id=$([ -e /etc/cmux/bake-instance-id ] && echo yes || echo no) team-root=$([ -e /srv/team ] && echo yes || echo no)\"; "
                                  "systemctl list-units --all --no-legend 'cmux*' | awk '{print $1}' | while read -r u; do echo \"unit $u: $(systemctl show -p Environment --value $u | tr ' ' '\\n' | cut -d= -f1 | tr '\\n' ' ')\"; done; "
                                  "for p in $(pgrep -f '[c]mux-tui'); do echo \"proc $p $(stat -c %U /proc/$p) $(tr '\\0' ' ' < /proc/$p/cmdline | cut -c1-80) :: $(tr '\\0' '\\n' < /proc/$p/environ | cut -d= -f1 | sort | tr '\\n' ' ') :: $(cut -d: -f3 /proc/$p/cgroup)\"; done")
            out = r["stdout"]
            with open(os.path.join(args.out, "inventory.txt"), "w") as f:
                f.write(out)
            return True, out.replace("\n", " | ")[:600], out
        run.step("inventory: host units and cmux-tui processes (information)", inventory)

        # Spool point first (hq-84 rule 2): how does the provider deliver exec stdin, and can the cmux user read it?
        fs_key = env.get("FREESTYLE_API_KEY")
        spool = {}

        def spool_probe():
            if not fs_key:
                return False, "no FREESTYLE_API_KEY on stdin: spool probe not run", None
            canary = secrets.token_hex(32)
            cmd = ("echo fd0=$(readlink /proc/self/fd/0); "
                   "for f in /tmp/.freestyle-exec-* /tmp/.freestyle-exec-*/*; do [ -e \"$f\" ] && stat -c 'scratch %n %U:%G %a %F' \"$f\"; done; "
                   f"echo grep-root=$(grep -rlF {canary[:16]}\"\"{canary[16:]} /tmp /var/tmp /run /var/log 2>/dev/null | head -5 | tr '\\n' ' '); "
                   "for f in /tmp/.freestyle-exec-* /tmp/.freestyle-exec-*/*; do [ -f \"$f\" ] && setpriv --reuid=cmux --regid=cmux --init-groups cat \"$f\" >/dev/null 2>&1 && echo cmux-can-read=$f; done; "
                   "cat >/dev/null; echo done")
            req = {"command": cmd, "timeoutMs": 4000, "linuxUser": "root",
                   "stdin": base64.b64encode((canary + "\n").encode()).decode()}
            # The canary's own grep needle above is split so this command line does not contain it whole.
            status, raw = http("POST", f"{FREESTYLE_API}/v5/vms/{vm}/exec-await",
                               {"authorization": f"Bearer {fs_key}", "content-type": "application/json"},
                               json.dumps(req).encode(), 30)
            body = jbody(raw)
            if status != 200:
                return False, f"provider exec-await answered {status} (VM not in the development key's account?)", None
            out = body.get("stdout") or ""
            after = api.exec_root(vm, f"timeout 100 grep -rlsF --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev {canary[:16]}''{canary[16:]} / 2>/dev/null | head -5; ls -la /tmp | grep -c freestyle-exec || true", timeout_ms=120_000)["stdout"]
            spool.update({"during": out, "after": after})
            with open(os.path.join(args.out, "spool.txt"), "w") as f:
                f.write("== during the exec\n" + out + "\n== after the exec\n" + after)
            readable = "cmux-can-read=" in out
            found_during = "grep-root=" in out and out.split("grep-root=", 1)[1].split("\n", 1)[0].strip() != ""
            found_after = any(l.startswith("/") for l in after.splitlines())
            ok = not readable and not found_after
            return ok, (f"fd0 {out.split('fd0=',1)[1].split(chr(10),1)[0] if 'fd0=' in out else '?'}; on disk during: {found_during}; "
                        f"cmux can read scratch: {readable}; on disk after: {found_after}"), ok
        spool_ok = run.step("spool point: stdin not readable by cmux", spool_probe)

        def inline_without_header():
            # hq-84 rule 3: the provider backgrounds (and stores) a call only when the caller asks with
            # its background header; the driver never sends it. A stdin exec that runs 7 s, past the
            # SDK's 5 s background window, must still answer 200 inline, not 202.
            if not fs_key:
                return False, "no FREESTYLE_API_KEY on stdin", None
            req = {"command": "sleep 7; cat >/dev/null; echo inline", "timeoutMs": 20000, "linuxUser": "root",
                   "stdin": base64.b64encode(b"x\n").decode()}
            t0 = time.monotonic()
            status, raw = http("POST", f"{FREESTYLE_API}/v5/vms/{vm}/exec-await",
                               {"authorization": f"Bearer {fs_key}", "content-type": "application/json"},
                               json.dumps(req).encode(), 60)
            ms = int((time.monotonic() - t0) * 1000)
            body = jbody(raw)
            ok = status == 200 and "inline" in (body.get("stdout") or "") and ms >= 7000
            return ok, f"HTTP {status} after {ms} ms, stdout {(body.get('stdout') or '').strip()!r}, requestId {body.get('requestId')}", ok
        run.step("provider: no background header, no background (200 inline after 7 s)", inline_without_header)

        if not supported:
            def old_binary_refused():
                before = api.exec_root(vm, "pgrep -f '[a]cp.*daemon run' | tr '\\n' ' '; echo")["stdout"].strip()
                status, body, _ = api.call("POST", f"/api/vm/{vm}/acpmux/keyed-start", (secrets.token_hex(32) + "\n").encode(),
                                           {"content-type": "application/octet-stream"}, timeout=180)
                after = api.exec_root(vm, "pgrep -f '[a]cp.*daemon run' | tr '\\n' ' '; echo")["stdout"].strip()
                ok = status == 409 and body.get("error") == "vm_acpmux_unsupported" and before == after
                return ok, f"HTTP {status} {body.get('error')}; acpmux daemon pids before [{before}] after [{after}]", ok
            run.step("old cmux-tui: refused before any daemon stops", old_binary_refused)
            if not args.cmux_tui_commit:
                run.record("keyed start", False, 0, "skipped: the guest cmux-tui has no keyed start (pass --cmux-tui-commit)")
                return 1

            def install_pinned():
                commit = args.cmux_tui_commit
                if not all(c in "0123456789abcdef" for c in commit) or len(commit) != 40:
                    raise ValueError("--cmux-tui-commit must be a full sha")
                sha = args.cmux_tui_sha256 or ""
                if len(sha) != 64 or not all(c in "0123456789abcdef" for c in sha):
                    raise ValueError("--cmux-tui-sha256 must be the manifest's sha256 of cmux-tui-x86_64-unknown-linux-musl")
                url = f"https://files.cmux.com/cmux-tui/{commit}/cmux-tui-x86_64-unknown-linux-musl"
                b = "/home/cmux/.cmux/bin/cmux-tui"
                r = api.exec_root(vm, f"set -e; ls -l {b}; curl -fsSL --retry 3 -o {b}.psxg {url}; printf '%s  %s\\n' {sha} {b}.psxg | sha256sum -c >/dev/null; "
                                      f"chmod 755 {b}.psxg; chown cmux:cmux {b}.psxg; mv -f {b}.psxg {b}; {b} --version; {b} acp daemon start --help | grep -c -- --person-key-fd", timeout_ms=180_000)
                out = r["stdout"]
                ok = r["exitCode"] == 0 and out.strip().splitlines()[-1].strip() not in ("", "0")
                return ok, out.replace("\n", " | ")[:300], ok
            if not run.step("install pinned cmux-tui (test machine only)", install_pinned):
                return 1

        # hq-84 rule: the session daemon's environ is data. A value with quotes, $(...), backticks,
        # a ";" and a newline must reach the restarted acpmux unchanged and run nothing.
        journal_canary = secrets.token_hex(12)
        probe_value = f"a'b\"c $(touch /tmp/psxg-pwned-1) `touch /tmp/psxg-pwned-2` ;touch /tmp/psxg-pwned-3 {journal_canary}\nline2"

        def hostile_env_setup():
            unit_value = probe_value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            conf = f'[Service]\nEnvironment="CMUX_PSXG_PROBE={unit_value}"\n'
            b64 = base64.b64encode(conf.encode()).decode()
            r = api.exec_root(vm, "set -e; rm -f /tmp/psxg-pwned-*; d=/etc/systemd/system/cmux-tui-daemon.service.d; mkdir -p $d; "
                                  f"echo {b64} | base64 -d > $d/psxg-probe.conf; systemctl daemon-reload; systemctl restart cmux-tui-daemon.service; "
                                  "p=$(systemctl show -p MainPID --value cmux-tui-daemon.service); base64 -w0 /proc/$p/environ")
            entries = base64.b64decode(r["stdout"].strip() or "").split(b"\0")
            got = next((e[len(b"CMUX_PSXG_PROBE="):] for e in entries if e.startswith(b"CMUX_PSXG_PROBE=")), None)
            ok = got == probe_value.encode()
            return ok, f"session daemon carries the hostile value exactly: {ok}; got {got!r}", ok
        hostile_ready = run.step("hostile env value in the session daemon (setup)", hostile_env_setup)

        def bad_body():
            s1, b1, _ = api.call("POST", f"/api/vm/{vm}/acpmux/keyed-start", b"not-a-key\n", {"content-type": "application/octet-stream"})
            s2, b2, _ = api.call("POST", f"/api/vm/{vm}/acpmux/keyed-start", (key_hex.upper() + "\n").encode(), {"content-type": "application/octet-stream"})
            s3, b3, _ = api.call("POST", f"/api/vm/{vm}/acpmux/person-holds", {"nonce": "zz"})
            ok = s1 == 400 and s2 == 400 and s3 == 400
            return ok, f"short {s1} {b1.get('error')}; uppercase {s2} {b2.get('error')}; nonce {s3} {b3.get('error')}", ok
        run.step("bad bodies refused before any exec", bad_body)

        def unauthenticated():
            status, raw = http("POST", f"{args.origin}/api/vm/{vm}/acpmux/keyed-start",
                               {"content-type": "application/octet-stream"}, (secrets.token_hex(32) + "\n").encode())
            return status == 401, f"HTTP {status}", status
        run.step("no session refused", unauthenticated)

        started = {}

        def keyed_start():
            t0 = time.monotonic()
            status, body, _ = api.call("POST", f"/api/vm/{vm}/acpmux/keyed-start", (key_hex + "\n").encode(),
                                       {"content-type": "application/octet-stream"}, timeout=180)
            started.update(body)
            elapsed = int((time.monotonic() - t0) * 1000)
            ok = status == 200 and isinstance(body.get("personInstance"), str)
            return ok, f"HTTP {status} {body.get('error') or ''} (whole route {elapsed} ms; the stdin exec is killed at 4.5 s) instance {body.get('personInstance')} in {int((time.monotonic()-t0)*1000)} ms {json.dumps(body.get('details') or {})[:160]}", ok
        if not run.step("keyed start", keyed_start):
            return 1
        instance = started["personInstance"]

        def holds(label="person_holds matches HMAC(K)"):
            def check():
                nonce = secrets.token_hex(32)
                status, body, _ = api.call("POST", f"/api/vm/{vm}/acpmux/person-holds", {"nonce": nonce})
                ok = status == 200 and body.get("instance") == instance and hmac.compare_digest(body.get("proof", ""), holds_proof(key_hex, instance, nonce))
                return ok, f"HTTP {status} instance {body.get('instance')} proof-matches {ok}", ok
            return run.step(label, check)
        holds()

        def wrong_key_proof():
            nonce = secrets.token_hex(32)
            status, body, _ = api.call("POST", f"/api/vm/{vm}/acpmux/person-holds", {"nonce": nonce})
            other = secrets.token_hex(32)
            ok = status == 200 and not hmac.compare_digest(body.get("proof", ""), holds_proof(other, instance, nonce))
            return ok, "a proof under another key does not match", ok
        run.step("person_holds is bound to K", wrong_key_proof)

        def daemon_facts():
            r = api.exec_root(vm, "p=$(pgrep -o -u cmux -f '[a]cp.*daemon run'); s=$(pgrep -o -u cmux -f '[c]mux-tui server start'); echo pid=$p; "
                                  "echo keys=$(tr '\\0' '\\n' < /proc/$p/environ | cut -d= -f1 | sort | tr '\\n' ' '); "
                                  "echo session=$(tr '\\0' '\\n' < /proc/$s/environ | cut -d= -f1 | sort | tr '\\n' ' '); "
                                  "echo cgroup=$(cut -d: -f3 /proc/$p/cgroup); echo user=$(stat -c %U /proc/$p)")
            out = r["stdout"]
            with open(os.path.join(args.out, "daemon.txt"), "w") as f:
                f.write(out)
            fields = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
            keys = set(fields.get("keys", "").split())
            session = set(fields.get("session", "").split())
            dropped = {"INVOCATION_ID", "JOURNAL_STREAM", "SYSTEMD_EXEC_PID", "NOTIFY_SOCKET", "OLDPWD", "PWD",
                       "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID", "CMUX_PANE_ID",
                       # cmux-tui removes these three from its own environment at startup (startup_env.rs
                       # take_cloud_template_env), so its own acpmux starter never passes them on either.
                       "CMUX_TUI_ADOPT_TEMPLATE_TERMINAL", "CMUX_TUI_TEMPLATE_BOUND_FILE", "CMUX_TUI_TEMPLATE_WORKSPACE_NAME"}
            missing = sorted((session - dropped) - keys)
            # INVOCATION_ID is the new scope's own; the exec agent's journal stream and pid must not pass on.
            leaked = sorted(keys & {"JOURNAL_STREAM", "SYSTEMD_EXEC_PID"})
            cgroup = fields.get("cgroup", "")
            ok = bool(fields.get("pid")) and fields.get("user") == "cmux" and not missing and not leaked and "freestyle" not in cgroup
            return ok, f"user {fields.get('user')} cgroup {cgroup}; session-daemon keys missing {missing}; exec-agent keys leaked {leaked}", ok
        run.step("restarted daemon: cmux user, session daemon env, own scope", daemon_facts)

        def hostile_env_check():
            if not hostile_ready:
                return False, "setup failed", None
            r = api.exec_root(vm, "p=$(pgrep -o -u cmux -f '[a]cp.*daemon run'); base64 -w0 /proc/$p/environ; echo; ls /tmp/psxg-pwned-* /psxg-pwned-* 2>/dev/null | wc -l")
            b64, count = (r["stdout"].strip().split("\n") + ["", ""])[:2]
            entries = base64.b64decode(b64 or "").split(b"\0")
            got = next((e[len(b"CMUX_PSXG_PROBE="):] for e in entries if e.startswith(b"CMUX_PSXG_PROBE=")), None)
            ok = got == probe_value.encode() and count.strip() == "0"
            return ok, f"daemon value unchanged: {got == probe_value.encode()}; files the value would have made: {count.strip()}", ok
        run.step("hostile env value reaches the daemon unchanged and runs nothing", hostile_env_check)

        def journal_check():
            # hq-84 review P2: systemd names a scope by its whole command line unless it has a
            # description, and PID 1 writes that name to the journal. The kept environ values must not
            # reach the journal: the canary inside the hostile value is in no journal line, and the
            # scope's own line is there under its fixed description.
            if not hostile_ready:
                return False, "setup failed", None
            half = len(journal_canary) // 2
            r = api.exec_root(vm, f"journalctl -b --no-pager -o cat | grep -cF {journal_canary[:half]}''{journal_canary[half:]}; "
                                  "journalctl -b --no-pager -o cat | grep -c 'cmux acpmux keyed start'")
            lines = r["stdout"].split()
            canary_hits, described = (lines + ["?", "?"])[:2]
            ok = canary_hits == "0" and described.isdigit() and int(described) >= 1
            return ok, f"journal lines with the canary: {canary_hits}; lines with the scope description: {described}", ok
        run.step("journal: the scope line holds no environ value", journal_check)

        if env.get("CMUX_AGENT2_STACK_EMAIL"):
            other = run.step("signin second agent account", lambda: (True, "agent2", sign_in(env["CMUX_AGENT2_STACK_EMAIL"], env["CMUX_AGENT2_STACK_PASSWORD"])))
            if other:
                sessions.append(other)

                def not_owner():
                    oapi = Api(args.origin, other)
                    s1, b1, _ = oapi.call("POST", f"/api/vm/{vm}/acpmux/keyed-start", (secrets.token_hex(32) + "\n").encode(), {"content-type": "application/octet-stream"})
                    s2, b2, _ = oapi.call("POST", f"/api/vm/{vm}/acpmux/person-holds", {"nonce": secrets.token_hex(32)})
                    ok = s1 in (403, 404) and s2 in (403, 404)
                    return ok, f"keyed-start {s1} {b1.get('error')}; person-holds {s2} {b2.get('error')}", ok
                run.step("another account's machine refused", not_owner)
                holds("after the refusals the same run still holds K (no restart happened)")

        def sweep_guest():
            r = api.exec_root(vm, "d=$(mktemp -d); for p in /proc/[0-9]*; do cat $p/cmdline; echo; cat $p/environ; echo; done > $d/proc 2>/dev/null; "
                                  "tar -czf $d/files.tgz --ignore-failed-read /tmp/.freestyle-exec-* /home/cmux/.acpmux /root/.acpmux /var/log /etc/cmux 2>/dev/null; "
                                  "journalctl -b --no-pager 2>/dev/null | tail -c 4000000 > $d/journal; "
                                  "tar -czf - -C $d proc files.tgz journal | base64 -w0; rm -rf $d", timeout_ms=120_000)
            blob = base64.b64decode(r["stdout"])
            import io
            import tarfile
            hits = {}
            with tarfile.open(fileobj=io.BytesIO(blob)) as outer:
                for m in outer.getmembers():
                    data = outer.extractfile(m).read() if m.isfile() else b""
                    if m.name.endswith("files.tgz"):
                        with tarfile.open(fileobj=io.BytesIO(data)) as inner:
                            for im in inner.getmembers():
                                if im.isfile():
                                    found = find(inner.extractfile(im).read(), needles)
                                    if found:
                                        hits[im.name] = found
                    else:
                        found = find(data, needles)
                        if found:
                            hits[m.name] = found
            ok = not hits
            return ok, f"{len(blob)} bytes searched; hits {json.dumps(hits)[:240]}", ok
        run.step("guest sweep: K in no argv, env, scratch, journal or log", sweep_guest)

        def sweep_stack():
            logs = subprocess.run(["docker", "logs", args.container], capture_output=True, timeout=120)
            dump = subprocess.run(["docker", "exec", args.db_container, "sh", "-c", "pg_dumpall -U \"${POSTGRES_USER:-postgres}\" --data-only 2>/dev/null"],
                                  capture_output=True, timeout=300)
            h1 = find(logs.stdout + logs.stderr, needles)
            h2 = find(dump.stdout, needles)
            ok = not h1 and not h2 and len(dump.stdout) > 0
            return ok, f"container log {len(logs.stdout)+len(logs.stderr)} bytes hits {h1}; database dump {len(dump.stdout)} bytes hits {h2}", ok
        run.step("stack sweep: K in no log line or database row", sweep_stack)
        return 0 if all(s["ok"] for s in run.steps) else 1
    finally:
        if not args.keep:
            for vm in created:
                def delete(vm=vm):
                    status, body, _ = Api(args.origin, sessions[0]).call("DELETE", f"/api/vm/{vm}", timeout=180)
                    return status in (200, 202, 204), f"DELETE {vm} by exact id: HTTP {status}", None
                run.step("delete machine", delete)
        for s in sessions:
            sign_out(s)
        key_hex = None


if __name__ == "__main__":
    sys.exit(main())
