#!/usr/bin/env python3
"""T2 machine prep and cleanup of cx-kvmz (cx-0q7o slice 2e), on the shared dev-backend host,
against the DEVELOPMENT API Worker only (Python standard library; reuses the T1 harness's
helpers from acpmux-app-keyed-start-e2e.py beside this file).

  python3 -I acpmux-app-approvals-t2-machine.py prep --out <dir> --cmux-tui-commit SHA --cmux-tui-sha256 SHA256 < secrets
  python3 -I acpmux-app-approvals-t2-machine.py delete --out <dir> --machine vm_... < secrets

prep: signs in the agent account (CMUX_UITEST_STACK_*), creates one machine with
cloud.machine.create, and readies it for the GUI check on that machine only, as root through
the provider (FREESTYLE_API_KEY, the cmux-next development key, the VM found by its exact
provider name):
- the pinned cmux-tui with the keyed start (the dev image's 09827ef9 has none), then a restart
  of cmux-host.service so the session daemon runs it;
- /etc/cmux/vm-kind = owner, root 0644 (cmux-host writes it at bind only from 287ee287a708 on;
  the dev image predates it, so agent-session-start would answer host_unverified);
- acpmux's test agent (cmux-tui/crates/acpmux/tests/fake_agent.py) as the harness profile
  `fake` of the cmux user, FAKE_NO_MODES=1 (no mode counts as asking), and /home/cmux trusted.
It records the machine in <out>/machines.tsv and prints `machine <id>`. delete removes that
machine by its exact id (cloud.machine.delete), never from a list.
"""
import argparse
import base64
import importlib.util
import json
import os
import secrets
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("t1", os.path.join(HERE, "acpmux-app-keyed-start-e2e.py"))
t1 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t1)

HARNESS = """schema = 1
id = "fake"
name = "Fake"
command = "python3"
args = ["/home/cmux/.cmux-kvmz/fake_agent.py"]
[env]
FAKE_NO_MODES = "1"
"""


def read_env():
    env = {}
    for line in sys.stdin.read().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            env[k.strip().removeprefix("export ").strip()] = v.strip().strip("'\"")
    return env


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["prep", "delete"])
    ap.add_argument("--out", required=True)
    ap.add_argument("--machine")
    ap.add_argument("--fake-agent", default=os.path.join(HERE, "fake_agent.py"))
    ap.add_argument("--cmux-tui-commit")
    ap.add_argument("--cmux-tui-sha256")
    args = ap.parse_args()
    env = read_env()
    run = t1.Run(args.out)
    session = t1.sign_in(env["CMUX_UITEST_STACK_EMAIL"], env["CMUX_UITEST_STACK_PASSWORD"])
    api = t1.Api(session, os.path.join(args.out, "requests.tsv"))
    tsv = os.path.join(args.out, "machines.tsv")
    try:
        if args.mode == "delete":
            machine = args.machine or ""
            if not machine.startswith("vm_"):
                sys.exit("--machine vm_... is required")
            status, body = 0, {}
            for _ in range(6):
                status, body = api.op("cloud.machine.delete", {"machine": machine}, f"kvmz-t2-delete-{machine}")
                if (body.get("error") or {}).get("code") != "mutation.indeterminate":
                    break
            st, _, _ = t1.http("GET", f"{t1.FREESTYLE_API}/v5/vms/{t1.PROVIDER_PREFIX + machine.replace('_', '-')}", {"authorization": f"Bearer {env['FREESTYLE_API_KEY']}"})
            with open(tsv, "a") as f:
                f.write(f"{machine}\tkvmz-t2\tdeleted\t{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
            run.record("delete machine", status == 200 and st == 404, 0, f"cloud.machine.delete {machine} by exact id: HTTP {status}; provider VM by name now {st}")
            return 0 if status == 200 and st == 404 else 1
        tag = f"kvmz-t2-{secrets.token_hex(4)}"
        status, body = api.op("cloud.machine.create", {"name": f"cmuxnp kvmz t2 {tag}", "size": {"cpu": 2, "memory_mb": 4096, "disk_mb": 16384}}, f"{tag}-create")
        machine = ((body.get("value") or {}).get("machine") or {}).get("id")
        if not machine:
            run.record("cloud.machine.create", False, 0, json.dumps(body)[:300])
            return 1
        with open(tsv, "a") as f:
            f.write(f"{machine}\t{tag}\tcreated\t{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\n")
        run.record("cloud.machine.create", True, 0, machine)
        t0 = time.monotonic()  # test-side bounded wait for the bind
        last = {}
        while time.monotonic() - t0 < 300:
            last = api.read("cloud.machine.get", {"machine": machine}).get("value") or {}
            if last.get("status") == "running" and last.get("host"):
                break
            time.sleep(2)
        run.record("bound", last.get("status") == "running", 0, f"status {last.get('status')} host {last.get('host')}")
        guest = t1.Guest(env["FREESTYLE_API_KEY"], t1.PROVIDER_PREFIX + machine.replace("_", "-"))
        commit, sha = args.cmux_tui_commit or "", args.cmux_tui_sha256 or ""
        if len(commit) != 40 or len(sha) != 64:
            sys.exit("--cmux-tui-commit and --cmux-tui-sha256 are required")
        fake = base64.b64encode(open(args.fake_agent, "rb").read()).decode()
        harness = base64.b64encode(HARNESS.encode()).decode()
        url = f"https://files.cmux.com/cmux-tui/{commit}/cmux-tui-x86_64-unknown-linux-musl"
        b = "/home/cmux/.cmux/bin/cmux-tui"
        r = guest.run(
            "set -e; "
            f"curl -fsSL --retry 3 -o /tmp/kvmz-tui {url}; printf '%s  %s\\n' {sha} /tmp/kvmz-tui | sha256sum -c >/dev/null; "
            f"rm -f {b}; install -o cmux -g cmux -m 755 /tmp/kvmz-tui {b}; rm -f /tmp/kvmz-tui; "
            "printf 'owner\\n' > /etc/cmux/vm-kind; chown root:root /etc/cmux/vm-kind; chmod 644 /etc/cmux/vm-kind; "
            f"install -d -o cmux -g cmux /home/cmux/.cmux-kvmz /home/cmux/.config/cmux/harnesses /home/cmux/.acpmux; "
            f"echo {fake} | base64 -d > /home/cmux/.cmux-kvmz/fake_agent.py; chown cmux:cmux /home/cmux/.cmux-kvmz/fake_agent.py; "
            f"echo {harness} | base64 -d > /home/cmux/.config/cmux/harnesses/fake.toml; chown cmux:cmux /home/cmux/.config/cmux/harnesses/fake.toml; "
            "printf '{\"/home/cmux\":\"trusted\"}\\n' > /home/cmux/.acpmux/trust.json; chown cmux:cmux /home/cmux/.acpmux/trust.json; "
            "systemctl restart cmux-host.service; "
            f"{b} --version; {b} acp daemon start --help | grep -c -- --person-key-fd; cat /etc/cmux/vm-kind; command -v python3",
            180_000)
        out = r["stdout"]
        run.record("ready the test machine (pinned cmux-tui, vm-kind owner, fake harness, trust)", r["code"] == 0, 0, out.replace("\n", " | ")[:400] + (f" stderr {r['stderr'][-300:]}" if r["code"] != 0 else ""))
        t0 = time.monotonic()  # test-side bounded wait for the session daemon on the new binary
        pid = ""
        while time.monotonic() - t0 < 90:
            pid = guest.run("pgrep -o -u cmux -f '[c]mux-tui server start' || true")["stdout"].strip()
            if pid:
                exe = guest.run(f"readlink /proc/{int(pid)}/exe; tr '\\0' ' ' < /proc/{int(pid)}/cmdline")["stdout"].strip()
                if "deleted" not in exe:
                    break
            time.sleep(2)
        run.record("session daemon restarted on the pinned binary", bool(pid), 0, f"pid {pid}")
        print(f"machine {machine}", flush=True)
        return 0 if all(s["ok"] for s in run.steps) else 1
    finally:
        t1.sign_out(session)


if __name__ == "__main__":
    sys.exit(main())
