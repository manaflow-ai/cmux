#!/usr/bin/env python3
"""own-machine-parity on one ephemeral macOS VM: two tagged DEBUG cmux NEXT Mac apps (A and B), both signed in
as the staging agent account, both allowed to enroll (CMUX_NEXT_ENROLL_ON_SIGN_IN=1, a test-only switch beside
CMUX_NEXT_NO_ACTIVATE=1). Then scripts/cmux-next/machine-join-e2e.ts --scenario own-machine-parity runs against
A's control socket with B named, 3 times, and its JSON report is the evidence. B is a second app on the same
Mac, so the port and file steps are a first number, not the two-Mac proof (the port "seen on A" shares B's
localhost). Run by .github/workflows/own-machine-parity-vm.yml; the build is its job's earlier step.

  own_machine_parity_vm.py --app-a APP --app-b APP --work DIR --out DIR
"""
import argparse, json, os, plistlib, pwd, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmux_next_pair_e2e as r  # noqa: E402

B_NAME = "parity-b"


def launch(app, label, work, out, account):
    bundle, tag, ls_env = r.step_tag(app)
    r.no_data_protection_keychain(app)
    sock = ls_env.get("CMUX_SOCKET_PATH") or f"/tmp/cmux-debug-{tag}.sock"
    rig = os.path.join(work, f"rig-{label}")
    os.makedirs(rig, mode=0o700, exist_ok=True)
    creds = os.path.join(rig, "dev-auth.env")
    with os.fdopen(os.open(creds, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        f.write(f"CMUX_UITEST_STACK_EMAIL={account['email']}\nCMUX_UITEST_STACK_PASSWORD={account['password']}\n")
    config = os.path.join(rig, "cmux-next.json")
    json.dump({}, open(config, "w"))
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
    env.update(ls_env)
    env.update(CMUX_NEXT_CONFIG_FILE=config, CMUX_AUTH_CREDENTIALS_FILE=creds, CMUX_NEXT_NO_ACTIVATE="1",
               CMUX_NEXT_ENROLL_ON_SIGN_IN="1", CMUX_NEXT_MOBILE_MACHINE_ID=r.machine_id(bundle),
               CMUX_NEXT_MOBILE_DEVICE_NAME=B_NAME if label == "b" else "parity-a", CMUX_NEXT_SOCKET_MODE="automation")
    if os.path.exists(sock):
        os.unlink(sock)
    plist = plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb"))
    exe = os.path.join(app, "Contents/MacOS", plist["CFBundleExecutable"])
    stream = r.Stream([exe], os.path.join(out, f"app-{label}.log"), env=env)
    return stream, sock


def main():
    ap = argparse.ArgumentParser()
    for f in ("--app-a", "--app-b", "--work", "--out"):
        ap.add_argument(f, required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    account = r.dev_credential()
    if "password" not in account:
        raise SystemExit("this job needs the staging account's password pair")
    keychain = r.RigKeychain(a.app_a)
    streams = []
    try:
        print("keychain:", keychain.start(), flush=True)
        t0 = time.monotonic()
        sa, sock_a = launch(a.app_a, "a", a.work, a.out, account)
        streams.append(sa)
        sb, sock_b = launch(a.app_b, "b", a.work, a.out, account)
        streams.append(sb)
        cli = os.path.join(a.app_a, "Contents/Resources/bin/cmux")
        env = dict(os.environ, PATH=os.path.dirname(cli) + ":" + os.environ["PATH"])
        for label, sock in (("A", sock_a), ("B", sock_b)):
            up = r.wait_for(lambda: subprocess.run([cli, "--app-socket", sock, "app", "ping"], env=env, capture_output=True).returncode == 0, 180)
            print(f"app {label}: {'answers' if up else 'NO ANSWER'} on its socket after {time.monotonic() - t0:.0f} s", flush=True)
        # What A lists after B's sign-in (evidence for the join step, and for the name).
        time.sleep(20)
        listed = subprocess.run([cli, "--app-socket", sock_a, "app", "machines", "--json"], env=env, capture_output=True, text=True)
        open(os.path.join(a.out, "a-machines.json"), "w").write(r.redact(listed.stdout + listed.stderr))
        folder = os.path.join(a.work, "picked-folder")
        os.makedirs(folder, exist_ok=True)
        sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip() or "unknown"
        res = subprocess.run(["bun", "scripts/cmux-next/machine-join-e2e.ts", "--scenario", "own-machine-parity", "--a-socket", sock_a,
                              "--b-name", B_NAME, "--folder", os.path.realpath(folder), "--runs", "3",
                              "--report", os.path.join(os.path.realpath(a.out), "own-machine-parity.json"), "--sha", sha], env=env)
        print("harness exit", res.returncode, flush=True)
        return 0  # a first number: the report, not the exit, is the evidence
    finally:
        for s in streams:
            s.stop()
        for app in (a.app_a, a.app_b):
            try:
                r.forget_tag(app)
            except Exception as e:  # noqa: BLE001
                print("cleanup:", type(e).__name__)
        keychain.end()


if __name__ == "__main__":
    sys.exit(main())
