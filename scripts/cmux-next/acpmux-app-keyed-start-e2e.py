#!/usr/bin/env python3
"""T1 of cx-kvmz (cx-0q7o slice 2e): the keyed acpmux start on a Cloud machine of the
app server, at the HTTP boundary of the DEVELOPMENT API Worker
(https://cmux-api-development.debussy.workers.dev), on a real provider VM. It refuses
every other origin. Python standard library only (it runs on the shared dev-backend
host, which has no bun or node).

  python3 -I acpmux-app-keyed-start-e2e.py --out <dir> \
      [--cmux-tui-commit SHA --cmux-tui-sha256 SHA256] [--keep] < secrets

stdin: KEY=VALUE lines, never printed: CMUX_UITEST_STACK_EMAIL/_PASSWORD (the agent
account), CMUX_AGENT2_STACK_EMAIL/_PASSWORD (a second agent account, for the
not-the-owner case), FREESTYLE_API_KEY (the cmux-next development key; root exec on
this run's VM only, found by its exact provider name).

The test key K is made here, sent only as the route's body, kept in this process, and
searched for (hex, upper hex, base64 forms, raw bytes) in what the run brings back: the
guest's process table, environments, provider exec scratch, journal and acpmux logs,
and every CloudDO event committed during the run (the team's op log, replayed over the
cloud wire socket). The Worker's invocation logs are read by request id afterwards
(<out>/requests.tsv). The machine this run creates is recorded in <out>/machines.tsv and
deleted by its exact id at the end (also on failure); nothing is deleted from a list.
"""
import argparse
import base64
import hashlib
import hmac
import io
import json
import os
import secrets
import socket
import ssl
import struct
import sys
import tarfile
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

ORIGIN = "https://cmux-api-development.debussy.workers.dev"
STACK_API = "https://api.stack-auth.com/api/v1"
DEV_STACK_PROJECT = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
DEV_STACK_CLIENT_KEY = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
FREESTYLE_API = "https://api.freestyle.sh"
PROVIDER_PREFIX = "cmuxnp-dev-cld-"
USER_AGENT = "cmux-kvmz-t1/1"


class Run:
    def __init__(self, out):
        self.out = out
        self.steps = []
        os.makedirs(out, exist_ok=True)

    def record(self, step, ok, ms, detail):
        self.steps.append({"step": step, "ok": ok, "ms": ms, "detail": detail})
        print(f"{'PASS' if ok else 'FAIL'} {step} {ms} ms :: {detail}", flush=True)
        with open(os.path.join(self.out, "t1.json"), "w") as f:
            json.dump({"origin": ORIGIN, "steps": self.steps}, f, indent=2)

    def step(self, name, fn):
        t0 = time.monotonic()
        try:
            ok, detail, value = fn()
        except Exception as e:  # a step failure is recorded, then the run goes on to cleanup
            ok, detail, value = False, f"{type(e).__name__}: {str(e)[:300]}", None
        self.record(name, ok, int((time.monotonic() - t0) * 1000), detail)
        return value


def http(method, url, headers=None, body=None, timeout=60):
    """(status, body bytes, response headers)."""
    # Cloudflare refuses the default Python-urllib agent (error 1010).
    req = urllib.request.Request(url, data=body, method=method, headers={"user-agent": USER_AGENT, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(), dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, e.read(), dict(e.headers)


def jbody(raw):
    try:
        return json.loads(raw.decode() or "{}")
    except ValueError:
        return {"raw": raw[:200].decode(errors="replace")}


def stack_headers():
    return {"x-stack-project-id": DEV_STACK_PROJECT, "x-stack-publishable-client-key": DEV_STACK_CLIENT_KEY,
            "x-stack-access-type": "client", "content-type": "application/json"}


def sign_in(email, password):
    status, raw, _ = http("POST", f"{STACK_API}/auth/password/sign-in", stack_headers(), json.dumps({"email": email, "password": password}).encode())
    body = jbody(raw)
    if status != 200 or "access_token" not in body:
        raise RuntimeError(f"Stack sign-in answered {status} {body.get('code', '')}")
    return {"access": body["access_token"], "refresh": body["refresh_token"]}


def sign_out(session):
    h = {**stack_headers(), "x-stack-access-token": session["access"], "x-stack-refresh-token": session["refresh"]}
    http("DELETE", f"{STACK_API}/auth/sessions/current", h, b"{}")


class Api:
    """The development Worker with one person's Stack session."""

    def __init__(self, session, requests_tsv):
        self.session, self.requests_tsv = session, requests_tsv

    def bearer(self):
        return {"authorization": f"Bearer {self.session['access']}"}

    def op(self, op, params, key):
        status, raw, _ = http("POST", f"{ORIGIN}/v1/ops", {**self.bearer(), "content-type": "application/json"}, json.dumps({"op": op, "params": params, "idempotency_key": key}).encode(), 120)
        body = jbody(raw)
        return status, body

    def read(self, op, params):
        status, raw, _ = http("POST", f"{ORIGIN}/v1/read", {**self.bearer(), "content-type": "application/json"}, json.dumps({"op": op, "params": params}).encode(), 60)
        body = jbody(raw)
        if status != 200:
            raise RuntimeError(f"{op}: HTTP {status} {json.dumps(body.get('error') or body)[:200]}")
        return body

    def acpmux(self, machine, action, body, content_type, extra=None, label=""):
        """One acpmux route call; its cf-ray goes to requests.tsv for the invocation log check."""
        h = {**self.bearer(), "content-type": content_type, **(extra or {})}
        t0 = time.time()
        status, raw, rh = http("POST", f"{ORIGIN}/v1/cloud/machines/{machine}/acpmux/{action}", h, body, 180)
        ray = next((v for k, v in rh.items() if k.lower() == "cf-ray"), "")
        with open(self.requests_tsv, "a") as f:
            f.write(f"{ray}\t{int(t0 * 1000)}\t{int(time.time() * 1000)}\t{action}\t{status}\t{label}\n")
        return status, jbody(raw)


class Guest:
    """Root exec on this run's VM through the provider API, found by its exact provider name."""

    def __init__(self, key, name):
        self.key = key
        status, raw, _ = http("GET", f"{FREESTYLE_API}/v5/vms/{name}", {"authorization": f"Bearer {key}"})
        body = jbody(raw)
        if status != 200 or not body.get("id"):
            raise RuntimeError(f"provider VM {name}: HTTP {status}")
        self.id = body["id"]

    def run(self, command, timeout_ms=60_000, stdin=None):
        req = {"command": command, "timeoutMs": timeout_ms, "linuxUser": "root"}
        if stdin is not None:
            req["stdin"] = base64.b64encode(stdin).decode()
        status, raw, _ = http("POST", f"{FREESTYLE_API}/v5/vms/{self.id}/exec-await", {"authorization": f"Bearer {self.key}", "content-type": "application/json"}, json.dumps(req).encode(), timeout_ms / 1000 + 30)
        body = jbody(raw)
        if status != 200:
            raise RuntimeError(f"guest exec answered {status}")
        return {"code": body.get("statusCode"), "stdout": body.get("stdout") or "", "stderr": body.get("stderr") or ""}


def wire_events(token, after_seq, quiet_s=4.0, budget_s=40.0):
    """The cloud stream's committed events after `after_seq` (the team's CloudDO op log), over /v1/wire/cloud."""
    host = urlparse(ORIGIN).hostname
    raw = socket.create_connection((host, 443), timeout=15)
    s = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /v1/wire/cloud HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: {USER_AGENT}\r\n"
               # The session in the Authorization header (cx-dgsp): the invocation log masks it, never a subprotocol.
               f"Authorization: Bearer {token}\r\nSec-WebSocket-Protocol: cmux.wire.v1\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = s.recv(4096)
        if not chunk:
            raise RuntimeError("wire: closed during the handshake")
        head += chunk
    status_line = head.split(b"\r\n", 1)[0].decode(errors="replace")
    if " 101 " not in status_line:
        raise RuntimeError(f"wire: {status_line}")
    buf = head.split(b"\r\n\r\n", 1)[1]

    def send_text(text):
        data = text.encode()
        mask = os.urandom(4)
        n = len(data)
        hdr = bytes([0x81]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n))
        s.sendall(hdr + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def read_exact(n):
        nonlocal buf
        while len(buf) < n:
            chunk = s.recv(65536)
            if not chunk:
                raise EOFError
            buf += chunk
        out, buf = buf[:n], buf[n:]
        return out

    def read_message():
        parts = []
        while True:
            b0, b1 = read_exact(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", read_exact(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", read_exact(8))[0]
            payload = read_exact(n)
            op = b0 & 0x0F
            if op == 0x8:
                raise EOFError
            if op in (0x9, 0xA):
                continue
            parts.append(payload)
            if b0 & 0x80:
                return b"".join(parts)

    send_text(json.dumps({"t": "subscribe", "after_seq": after_seq, "pending": []}))
    frames = []
    t0 = time.monotonic()
    s.settimeout(quiet_s)
    try:
        while time.monotonic() - t0 < budget_s:
            try:
                frames.append(read_message())
            except socket.timeout:
                break
            except EOFError:
                break
    finally:
        s.close()
    return frames


def holds_proof(key_hex, instance, nonce):
    message = b"acpmux-person-holds-v1" + b"\0" + instance.encode() + b"\0" + nonce.encode()
    return hmac.new(bytes.fromhex(key_hex), message, hashlib.sha256).hexdigest()


def key_needles(key_hex):
    line = (key_hex + "\n").encode()
    raw = bytes.fromhex(key_hex)
    return {"hex": key_hex.encode(), "HEX": key_hex.upper().encode(), "base64-line": base64.b64encode(line),
            "base64-key-hex": base64.b64encode(key_hex.encode()), "raw": raw, "base64-raw": base64.b64encode(raw)}


def find(haystack, needles):
    return sorted(name for name, needle in needles.items() if needle in haystack)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--cmux-tui-commit", help="published cmux-tui build to install on the test machine when its own has no keyed start")
    ap.add_argument("--cmux-tui-sha256", help="sha256 of that build's cmux-tui-x86_64-unknown-linux-musl (from its manifest)")
    args = ap.parse_args()
    env = {}
    for line in sys.stdin.read().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip().removeprefix("export ").strip()] = v.strip().strip("'\"")
    run = Run(args.out)
    machines_tsv = os.path.join(args.out, "machines.tsv")
    requests_tsv = os.path.join(args.out, "requests.tsv")
    created = []
    sessions = []
    key_hex = secrets.token_bytes(32).hex()
    needles = key_needles(key_hex)
    # The log check (acpmux-app-keyed-start-logs.py) gets only each form's length and sha256, never K.
    with open(os.path.join(args.out, "needle-digests.json"), "w") as f:
        json.dump({k: {"len": len(v), "sha256": hashlib.sha256(v).hexdigest()} for k, v in needles.items() if k != "raw"}, f)
    tag = f"kvmz-{secrets.token_hex(4)}"
    api = None
    try:
        agent = run.step("signin agent", lambda: (True, "agent account (CMUX_UITEST_STACK_*)", sign_in(env["CMUX_UITEST_STACK_EMAIL"], env["CMUX_UITEST_STACK_PASSWORD"])))
        if not agent:
            return 1
        sessions.append(agent)
        api = Api(agent, requests_tsv)

        def ensure():
            status, body = api.op("user.ensure", {}, f"{tag}-ensure")
            v = body.get("value") or {}
            team = (v.get("team") or {}).get("id") if isinstance(v.get("team"), dict) else v.get("team") or v.get("personal_team")
            return status == 200 and body.get("ok") is True, f"HTTP {status} user {(v.get('user') or {}).get('id') if isinstance(v.get('user'), dict) else v.get('id')}", v
        ensured = run.step("user.ensure", ensure) or {}
        owner_user = (ensured.get("user") or {}).get("id") if isinstance(ensured.get("user"), dict) else ensured.get("id")

        seq0 = run.step("op log head before the run", lambda: (lambda r: (True, f"cloud stream seq {r.get('revision')}", int(r.get("revision") or 0)))(api.read("cloud.plan.get", {})))

        def create():
            body = None
            for _ in range(6):  # same key: a mutation.indeterminate answer resumes the same create
                status, body = api.op("cloud.machine.create", {"name": f"cmuxnp kvmz t1 {tag}", "size": {"cpu": 2, "memory_mb": 4096, "disk_mb": 16384}}, f"{tag}-create")
                m = (body.get("value") or {}).get("machine") or {}
                if m.get("id") and m["id"] not in created:
                    created.append(m["id"])
                    with open(machines_tsv, "a") as f:
                        f.write(f"{m['id']}\t{tag}\tcreated\t{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
                if status == 200 and body.get("ok") is True:
                    return True, f"{m.get('id')} status {m.get('status')}", m["id"]
                if (body.get("error") or {}).get("code") != "mutation.indeterminate":
                    break
            return False, f"create: {json.dumps(body.get('error') if body else None)[:300]}", None
        machine = run.step("cloud.machine.create", create)
        if not machine:
            return 1

        def bound():
            t0 = time.monotonic()  # test-side bounded wait for the bind; the product never polls
            last = {}
            while time.monotonic() - t0 < 300:
                last = api.read("cloud.machine.get", {"machine": machine}).get("value") or {}
                if last.get("status") == "running" and last.get("host"):
                    return True, f"running, host {last.get('host')}, daemon {(last.get('image') or {}).get('daemon_version')}", last
                time.sleep(2)
            return False, f"last status {last.get('status')} host {last.get('host')}", None
        if not run.step("bound (running, host set)", bound):
            return 1
        name = PROVIDER_PREFIX + machine.replace("_", "-")
        guest = run.step("provider VM by its exact name", lambda: (lambda g: (True, f"{name} = {g.id}", g))(Guest(env["FREESTYLE_API_KEY"], name)))
        if not guest:
            return 1

        def probe():
            r = guest.run("set -e; for b in /home/cmux/.cmux/bin/cmux-tui /root/.cmux/bin/cmux-tui; do [ -x $b ] && { echo bin=$b; $b --version 2>&1 | head -1; $b acp daemon start --help 2>&1 | grep -c -- --person-key-fd || true; }; done")
            out = r["stdout"]
            supported = any(l.strip().isdigit() and int(l.strip()) > 0 for l in out.splitlines())
            return True, out.replace("\n", " | ")[:300], supported
        supported = run.step("guest cmux-tui keyed start support (information)", probe)

        def inventory():
            r = guest.run("echo \"markers: vm-kind=$(cat /etc/cmux/vm-kind 2>/dev/null || echo none) team-root=$([ -e /srv/team ] && echo yes || echo no)\"; "
                          "systemctl list-units --all --no-legend 'cmux*' | awk '{print $1}' | while read -r u; do echo \"unit $u: $(systemctl show -p Environment --value $u | tr ' ' '\\n' | cut -d= -f1 | tr '\\n' ' ')\"; done; "
                          "for p in $(pgrep -f '[c]mux-tui'); do echo \"proc $p $(stat -c %U /proc/$p) $(tr '\\0' ' ' < /proc/$p/cmdline | cut -c1-80) :: $(cut -d: -f3 /proc/$p/cgroup)\"; done")
            out = r["stdout"]
            with open(os.path.join(args.out, "inventory.txt"), "w") as f:
                f.write(out)
            # vm-kind=owner is written at bind by cmux-host from 287ee287a708 on; older images have none. Only a team marker refuses.
            owner = "vm-kind=team" not in out and "team-root=no" in out
            return owner, out.replace("\n", " | ")[:600], out
        run.step("inventory: no team machine marker, host units, cmux-tui processes", inventory)

        def spool_probe():
            canary = secrets.token_hex(32)
            cmd = ("echo fd0=$(readlink /proc/self/fd/0); "
                   "for f in /tmp/.freestyle-exec-* /tmp/.freestyle-exec-*/*; do [ -e \"$f\" ] && stat -c 'scratch %n %U:%G %a %F' \"$f\"; done; "
                   f"echo grep-root=$(grep -rlF {canary[:16]}\"\"{canary[16:]} /tmp /var/tmp /run /var/log 2>/dev/null | head -5 | tr '\\n' ' '); "
                   "for f in /tmp/.freestyle-exec-* /tmp/.freestyle-exec-*/*; do [ -f \"$f\" ] && setpriv --reuid=cmux --regid=cmux --init-groups cat \"$f\" >/dev/null 2>&1 && echo cmux-can-read=$f; done; "
                   "cat >/dev/null; echo done")
            out = guest.run(cmd, 4000, (canary + "\n").encode())["stdout"]
            after = guest.run(f"timeout 100 grep -rlsF --exclude-dir=proc --exclude-dir=sys --exclude-dir=dev {canary[:16]}''{canary[16:]} / 2>/dev/null | head -5; true", 120_000)["stdout"]
            with open(os.path.join(args.out, "spool.txt"), "w") as f:
                f.write("== during the exec\n" + out + "\n== after the exec\n" + after)
            readable = "cmux-can-read=" in out
            found_after = any(l.startswith("/") for l in after.splitlines())
            fd0 = out.split("fd0=", 1)[1].split("\n", 1)[0] if "fd0=" in out else "?"
            return not readable and not found_after, f"fd0 {fd0}; cmux can read scratch: {readable}; on disk after: {found_after}", None
        run.step("spool point: stdin not readable by cmux, not on disk after", spool_probe)

        def inline_without_header():
            t0 = time.monotonic()
            r = guest.run("sleep 7; cat >/dev/null; echo inline", 20000, b"x\n")
            ms = int((time.monotonic() - t0) * 1000)
            ok = "inline" in r["stdout"] and ms >= 7000
            return ok, f"200 inline after {ms} ms (no background header sent), stdout {r['stdout'].strip()!r}", ok
        run.step("provider: no background header, no background (200 inline after 7 s)", inline_without_header)

        if not supported:
            def old_binary_refused():
                before = guest.run("pgrep -f '[a]cp.*daemon run' | tr '\\n' ' '; echo")["stdout"].strip()
                status, body = api.acpmux(machine, "keyed-start", (secrets.token_hex(32) + "\n").encode(), "application/octet-stream", label="old-binary")
                after = guest.run("pgrep -f '[a]cp.*daemon run' | tr '\\n' ' '; echo")["stdout"].strip()
                code = (body.get("error") or {}).get("code")
                ok = status == 409 and code == "cloud.acpmux.unsupported" and before == after
                return ok, f"HTTP {status} {code}; acpmux daemon pids before [{before}] after [{after}]", ok
            run.step("old cmux-tui: refused before any daemon stops", old_binary_refused)
            if not args.cmux_tui_commit:
                run.record("keyed start", False, 0, "skipped: the guest cmux-tui has no keyed start (pass --cmux-tui-commit)")
                return 1

            def install_pinned():
                commit, sha = args.cmux_tui_commit, args.cmux_tui_sha256 or ""
                if len(commit) != 40 or not all(c in "0123456789abcdef" for c in commit):
                    raise ValueError("--cmux-tui-commit must be a full sha")
                if len(sha) != 64 or not all(c in "0123456789abcdef" for c in sha):
                    raise ValueError("--cmux-tui-sha256 must be the manifest's sha256")
                url = f"https://files.cmux.com/cmux-tui/{commit}/cmux-tui-x86_64-unknown-linux-musl"
                b = "/home/cmux/.cmux/bin/cmux-tui"
                r = guest.run(f"set -e; t=$(readlink -f {b}); curl -fsSL --retry 3 -o /tmp/kvmz-tui {url}; printf '%s  %s\\n' {sha} /tmp/kvmz-tui | sha256sum -c >/dev/null; "
                              f"chmod 755 /tmp/kvmz-tui; rm -f {b}; install -o cmux -g cmux -m 755 /tmp/kvmz-tui {b}; {b} --version; {b} acp daemon start --help | grep -c -- --person-key-fd", 180_000)
                out = r["stdout"]
                ok = r["code"] == 0 and out.strip().splitlines()[-1].strip() not in ("", "0")
                return ok, out.replace("\n", " | ")[:300] + (f" stderr {r['stderr'][-200:]}" if not ok else ""), ok
            if not run.step("install pinned cmux-tui (test machine only)", install_pinned):
                return 1

        # The session daemon's environ is data. cmux-host passes only CMUX_TUI_* (and a few) on, so the
        # probe is a CMUX_TUI_ variable of cmux-host.service; the session daemon restarts to take it.
        journal_canary = secrets.token_hex(12)
        probe_value = f"a'b\"c $(touch /tmp/kvmz-pwned-1) `touch /tmp/kvmz-pwned-2` ;touch /tmp/kvmz-pwned-3 {journal_canary}\nline2"

        def session_pid():
            return guest.run("pgrep -o -u cmux -f '[c]mux-tui server start' || true")["stdout"].strip()

        def hostile_env_setup():
            unit_value = probe_value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            conf = base64.b64encode(f'[Service]\nEnvironment="CMUX_TUI_KVMZ_PROBE={unit_value}"\n'.encode()).decode()
            old = session_pid()
            guest.run(f"set -e; rm -f /tmp/kvmz-pwned-*; d=/etc/systemd/system/cmux-host.service.d; mkdir -p $d; echo {conf} | base64 -d > $d/kvmz-probe.conf; systemctl daemon-reload; systemctl restart cmux-host.service")
            got = None
            t0 = time.monotonic()  # test-side bounded wait for the supervisor's respawn
            killed = False
            while time.monotonic() - t0 < 90:
                pid = session_pid()
                if pid:
                    b64 = guest.run(f"base64 -w0 /proc/{pid}/environ 2>/dev/null || true")["stdout"].strip()
                    entries = base64.b64decode(b64 or "").split(b"\0")
                    got = next((e[len(b"CMUX_TUI_KVMZ_PROBE="):] for e in entries if e.startswith(b"CMUX_TUI_KVMZ_PROBE=")), None)
                    if got is not None:
                        break
                    if not killed and pid == old:
                        # The session host outlives a cmux-host restart (its own scope) and ignores a SIGTERM
                        # that is not from PID 1: stop its exact unit, so the supervisor starts it with the new environment.
                        guest.run(f"u=$(cut -d: -f3 /proc/{int(pid)}/cgroup | awk -F/ '{{print $NF}}'); case \"$u\" in *.scope) systemctl stop \"$u\";; esac; echo $u")
                        killed = True
                time.sleep(2)
            ok = got == probe_value.encode()
            return ok, f"session daemon carries the hostile value exactly: {ok} (restarted by pid: {killed}); got {got!r}", ok
        hostile_ready = run.step("hostile env value in the session daemon (setup)", hostile_env_setup)

        def bad_requests():
            kb = (key_hex + "\n").encode()
            other = secrets.token_hex(32)
            results = {
                "short body": api.acpmux(machine, "keyed-start", b"not-a-key\n", "application/octet-stream", label="short"),
                "uppercase key": api.acpmux(machine, "keyed-start", (other.upper() + "\n").encode(), "application/octet-stream", label="upper"),
                "json type": api.acpmux(machine, "keyed-start", (other + "\n").encode(), "application/json", label="type"),
                "key-like header": api.acpmux(machine, "keyed-start", (other + "\n").encode(), "application/octet-stream", {"x-kvmz-probe": other}, label="header"),
                "bad nonce": api.acpmux(machine, "person-holds", json.dumps({"nonce": "zz"}).encode(), "application/json", label="nonce"),
            }
            st, raw, rh = http("POST", f"{ORIGIN}/v1/cloud/machines/{machine}/acpmux/keyed-start?k={other}", {**api.bearer(), "content-type": "application/octet-stream"}, (other + "\n").encode())
            results["query string"] = (st, jbody(raw))
            del kb
            ok = all(s == 400 for s, _ in results.values())
            return ok, "; ".join(f"{k} {s} {(b.get('error') or {}).get('code')}" for k, (s, b) in results.items()), ok
        run.step("bad requests refused before any exec (body, type, header, query)", bad_requests)

        def chunked_refused():
            import http.client
            c = http.client.HTTPSConnection(urlparse(ORIGIN).hostname, timeout=60)
            c.putrequest("POST", f"/v1/cloud/machines/{machine}/acpmux/keyed-start")
            for k, v in {**api.bearer(), "user-agent": USER_AGENT, "content-type": "application/octet-stream", "transfer-encoding": "chunked"}.items():
                c.putheader(k, v)
            c.endheaders()
            data = (secrets.token_hex(32) + "\n").encode() * 2  # 130 bytes, past one key line
            c.send(b"%x\r\n%s\r\n0\r\n\r\n" % (len(data), data))
            r = c.getresponse()
            body = jbody(r.read())
            ray = r.getheader("cf-ray") or ""
            with open(requests_tsv, "a") as f:
                f.write(f"{ray}\t{int(time.time()*1000)}\t{int(time.time()*1000)}\tkeyed-start\t{r.status}\tchunked\n")
            # Cloudflare's edge buffers a small chunked body and gives the Worker a Content-Length, so
            # the Worker may see 130 declared (400) or none (411); either way nothing past 65 bytes is read.
            return r.status in (400, 411), f"HTTP {r.status} {(body.get('error') or {}).get('code')}", None
        run.step("a chunked body longer than one key line refused (400 or 411)", chunked_refused)

        def unauthenticated():
            st, raw, _ = http("POST", f"{ORIGIN}/v1/cloud/machines/{machine}/acpmux/keyed-start", {"content-type": "application/octet-stream"}, (secrets.token_hex(32) + "\n").encode())
            return st == 401, f"HTTP {st} {(jbody(raw).get('error') or {}).get('code')}", None
        run.step("no session refused 401", unauthenticated)

        started = {}

        def keyed_start():
            t0 = time.monotonic()
            status, body = api.acpmux(machine, "keyed-start", (key_hex + "\n").encode(), "application/octet-stream", label="keyed-start")
            started.update(body.get("value") or {})
            ms = int((time.monotonic() - t0) * 1000)
            ok = status == 200 and isinstance(started.get("personInstance"), str)
            return ok, f"HTTP {status} {json.dumps(body.get('error') or {})[:200]} instance {started.get('personInstance')} (whole route {ms} ms; the stdin exec is killed at 4.5 s)", ok
        if not run.step("keyed start", keyed_start):
            return 1
        instance = started["personInstance"]

        def holds(label):
            def check():
                nonce = secrets.token_hex(32)
                status, body = api.acpmux(machine, "person-holds", json.dumps({"nonce": nonce}).encode(), "application/json", label="holds")
                v = body.get("value") or {}
                ok = status == 200 and v.get("instance") == instance and hmac.compare_digest(v.get("proof", ""), holds_proof(key_hex, instance, nonce))
                return ok, f"HTTP {status} instance {v.get('instance')} proof-matches {ok}", ok
            return run.step(label, check)
        holds("person_holds matches HMAC(K)")

        def wrong_key_proof():
            nonce = secrets.token_hex(32)
            status, body = api.acpmux(machine, "person-holds", json.dumps({"nonce": nonce}).encode(), "application/json", label="holds")
            ok = status == 200 and not hmac.compare_digest((body.get("value") or {}).get("proof", ""), holds_proof(secrets.token_hex(32), instance, nonce))
            return ok, "a proof under another key does not match", ok
        run.step("person_holds is bound to K", wrong_key_proof)

        def daemon_facts():
            r = guest.run("p=$(pgrep -o -u cmux -f '[a]cp.*daemon run'); s=$(pgrep -o -u cmux -f '[c]mux-tui server start'); echo pid=$p; "
                          "echo keys=$(tr '\\0' '\\n' < /proc/$p/environ | cut -d= -f1 | sort | tr '\\n' ' '); "
                          "echo session=$(tr '\\0' '\\n' < /proc/$s/environ | cut -d= -f1 | sort | tr '\\n' ' '); "
                          "echo cgroup=$(cut -d: -f3 /proc/$p/cgroup); echo user=$(stat -c %U /proc/$p)")
            out = r["stdout"]
            with open(os.path.join(args.out, "daemon.txt"), "w") as f:
                f.write(out)
            fields = dict(l.split("=", 1) for l in out.splitlines() if "=" in l)
            keys, session = set(fields.get("keys", "").split()), set(fields.get("session", "").split())
            dropped = {"INVOCATION_ID", "JOURNAL_STREAM", "SYSTEMD_EXEC_PID", "NOTIFY_SOCKET", "OLDPWD", "PWD",
                       "CMUX_SURFACE_ID", "CMUX_WORKSPACE_ID", "CMUX_TAB_ID", "CMUX_PANEL_ID", "CMUX_PANE_ID",
                       "CMUX_TUI_ADOPT_TEMPLATE_TERMINAL", "CMUX_TUI_TEMPLATE_BOUND_FILE", "CMUX_TUI_TEMPLATE_WORKSPACE_NAME"}
            missing = sorted((session - dropped) - keys)
            leaked = sorted(keys & {"JOURNAL_STREAM", "SYSTEMD_EXEC_PID"})
            cgroup = fields.get("cgroup", "")
            ok = bool(fields.get("pid")) and fields.get("user") == "cmux" and not missing and not leaked and "cmux-acpmux-keyed-" in cgroup
            return ok, f"user {fields.get('user')} cgroup {cgroup}; session-daemon keys missing {missing}; exec-agent keys leaked {leaked}", ok
        run.step("restarted daemon: cmux user, session daemon env, own scope", daemon_facts)

        def hostile_env_check():
            if not hostile_ready:
                return False, "setup failed", None
            r = guest.run("p=$(pgrep -o -u cmux -f '[a]cp.*daemon run'); base64 -w0 /proc/$p/environ; echo; ls /tmp/kvmz-pwned-* /kvmz-pwned-* 2>/dev/null | wc -l")
            b64, count = (r["stdout"].strip().split("\n") + ["", ""])[:2]
            got = next((e[len(b"CMUX_TUI_KVMZ_PROBE="):] for e in base64.b64decode(b64 or "").split(b"\0") if e.startswith(b"CMUX_TUI_KVMZ_PROBE=")), None)
            ok = got == probe_value.encode() and count.strip() == "0"
            return ok, f"daemon value unchanged: {got == probe_value.encode()}; files the value would have made: {count.strip()}", ok
        run.step("hostile env value reaches the daemon unchanged and runs nothing", hostile_env_check)

        def journal_check():
            if not hostile_ready:
                return False, "setup failed", None
            half = len(journal_canary) // 2
            r = guest.run(f"journalctl -b --no-pager -o cat | grep -cF {journal_canary[:half]}''{journal_canary[half:]}; journalctl -b --no-pager -o cat | grep -c 'cmux acpmux keyed start'")
            canary_hits, described = (r["stdout"].split() + ["?", "?"])[:2]
            ok = canary_hits == "0" and described.isdigit() and int(described) >= 1
            return ok, f"journal lines with the canary: {canary_hits}; lines with the scope description: {described}", ok
        run.step("journal: the scope line holds no environ value", journal_check)

        if env.get("CMUX_AGENT2_STACK_EMAIL"):
            other = run.step("signin second agent account", lambda: (True, "agent2 (CMUX_AGENT2_STACK_*)", sign_in(env["CMUX_AGENT2_STACK_EMAIL"], env["CMUX_AGENT2_STACK_PASSWORD"])))
            if other:
                sessions.append(other)

                def not_owner():
                    oapi = Api(other, requests_tsv)
                    s1, b1 = oapi.acpmux(machine, "keyed-start", (secrets.token_hex(32) + "\n").encode(), "application/octet-stream", label="agent2")
                    s2, b2 = oapi.acpmux(machine, "person-holds", json.dumps({"nonce": secrets.token_hex(32)}).encode(), "application/json", label="agent2")
                    owner_team = "team_" + hashlib.sha256(f"personal:{owner_user}".encode()).hexdigest()[:20] if owner_user else None
                    s3, b3 = oapi.acpmux(machine, "keyed-start", (secrets.token_hex(32) + "\n").encode(), "application/octet-stream", {"x-cmux-team": owner_team} if owner_team else None, label="agent2-team")
                    codes = [(s1, (b1.get("error") or {}).get("code")), (s2, (b2.get("error") or {}).get("code")), (s3, (b3.get("error") or {}).get("code"))]
                    ok = all(s in (403, 404) for s, _ in codes)
                    return ok, f"own team keyed-start {codes[0]}; person-holds {codes[1]}; naming the owner's team {owner_team}: {codes[2]}", ok
                run.step("another account refused (its own team, and naming the owner's team)", not_owner)
                holds("after the refusals the same run still holds K (no restart happened)")

        def sweep_guest():
            r = guest.run("d=$(mktemp -d); for p in /proc/[0-9]*; do cat $p/cmdline; echo; cat $p/environ; echo; done > $d/proc 2>/dev/null; "
                          "tar -czf $d/files.tgz --ignore-failed-read /tmp/.freestyle-exec-* /home/cmux/.acpmux /root/.acpmux /var/log /etc/cmux /var/lib/cmux 2>/dev/null; "
                          "journalctl -b --no-pager 2>/dev/null | tail -c 4000000 > $d/journal; "
                          "tar -czf - -C $d proc files.tgz journal | base64 -w0; rm -rf $d", 120_000)
            blob = base64.b64decode(r["stdout"])
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
            return not hits, f"{len(blob)} bytes searched; hits {json.dumps(hits)[:240]}", None
        run.step("guest sweep: K in no argv, env, scratch, journal or log", sweep_guest)

        def op_log():
            frames = wire_events(agent["access"], seq0)
            blob = b"\n".join(frames)
            with open(os.path.join(args.out, "op-log.jsonl"), "wb") as f:
                f.write(blob)
            ops = {}
            snapshot = False
            for fr in frames:
                try:
                    j = json.loads(fr)
                except ValueError:
                    continue
                if j.get("t") == "event":
                    ops[j.get("op")] = ops.get(j.get("op"), 0) + 1
                elif j.get("t") == "snapshot":
                    snapshot = True
            hits = find(blob, needles)
            acpmux_ops = [o for o in ops if o and "acpmux" in o]
            ok = bool(ops) and not snapshot and not hits and not acpmux_ops
            return ok, f"{sum(ops.values())} events after seq {seq0}: {json.dumps(ops)}; acpmux ops {acpmux_ops}; K hits {hits}; snapshot instead of replay: {snapshot}", ok
        run.step("CloudDO op log: no acpmux op, K in no event", op_log)
        return 0 if all(s["ok"] for s in run.steps) else 1
    finally:
        if not args.keep and api is not None:
            for vm in created:
                def delete(vm=vm):
                    body = None
                    for _ in range(6):
                        status, body = api.op("cloud.machine.delete", {"machine": vm}, f"{tag}-delete-{vm}")
                        if status == 200 and body.get("ok") is True:
                            with open(machines_tsv, "a") as f:
                                f.write(f"{vm}\t{tag}\tdeleted\t{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
                            break
                        if (body.get("error") or {}).get("code") != "mutation.indeterminate":
                            break
                    st, _, _ = http("GET", f"{FREESTYLE_API}/v5/vms/{PROVIDER_PREFIX + vm.replace('_', '-')}", {"authorization": f"Bearer {env.get('FREESTYLE_API_KEY', '')}"})
                    return status == 200 and st == 404, f"cloud.machine.delete {vm} by exact id: HTTP {status}; provider VM by name now {st}", None
                run.step("delete machine", delete)
        for s in sessions:
            sign_out(s)
        key_hex = None


if __name__ == "__main__":
    sys.exit(main())
