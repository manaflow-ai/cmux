#!/usr/bin/env python3
"""own-machine-parity on one ephemeral macOS VM: two tagged DEBUG cmux NEXT Mac apps (A and B), both signed in
as the staging agent account, both allowed to enroll (CMUX_NEXT_ENROLL_ON_SIGN_IN=1, a test-only switch beside
CMUX_NEXT_NO_ACTIVATE=1). Then scripts/cmux-next/machine-join-e2e.ts --scenario own-machine-parity runs against
A's control socket with B named, 3 times, and its JSON report is the evidence. B is a second app on the same
Mac, so the port and file steps are a first number, not the two-Mac proof (the port "seen on A" shares B's
localhost). Run by .github/workflows/own-machine-parity-vm.yml; the build is its job's earlier step.

  own_machine_parity_vm.py --app-a APP --app-b APP --work DIR --out DIR
"""
import argparse, glob, json, os, plistlib, pwd, re, socket, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cmux_next_pair_e2e as r  # noqa: E402

B_NAME = "parity-b"


def enroll_name(tag):
    """The name a sign-in join gives this Mac (acpmux cli/cloud_join/enroll.rs `enroll_name`): the host
    name's first label, lowercased (`host` when it is not a plain name), then `-<tag>`, at most 63
    characters. CMUX_NEXT_MOBILE_DEVICE_NAME names only the iPhone host, never the hub's machine row."""
    first = socket.gethostname().split(".")[0].lower()
    base = first if re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,79}", first) else "host"
    t = re.sub(r"[^a-z0-9-]", "", tag.lower()).strip("-")
    return (f"{base}-{t}" if t else base)[:63].rstrip("-")


def acpmux_evidence(app, tag, out, label):
    """Why B did or did not show on A: each build's acpmux home (~/.acpmux/builds/*, under $HOME and the
    account home) with its join status, machine list and log tails, plus the app's debug log tail.
    Best effort, bounded, redacted."""
    homes = {os.path.expanduser("~"), pwd.getpwuid(os.getuid()).pw_dir}
    acpmux = os.path.join(app, "Contents/Resources/bin/acpmux")
    parts = []
    for home in sorted(homes):
        for d in sorted(glob.glob(os.path.join(home, ".acpmux", "builds", "*"))):
            parts.append(f"== {d}")
            files = []
            for root, dirs, names in os.walk(d):
                if root[len(d):].count(os.sep) >= 3:
                    dirs[:] = []
                files += [os.path.join(root, n) for n in names]
            parts.append("files: " + ", ".join(os.path.relpath(f, d) for f in files[:200]))
            env = dict(os.environ, ACPMUX_HOME=d)
            for argv in (["host", "join", "--status", "--json"], ["machine", "ls", "--json"]):
                try:
                    p = subprocess.run([acpmux, *argv], env=env, capture_output=True, text=True, timeout=30)
                    parts.append(f"$ acpmux {' '.join(argv)} -> {p.returncode}\n{p.stdout[-4000:]}{p.stderr[-2000:]}")
                except (OSError, subprocess.TimeoutExpired) as e:
                    parts.append(f"$ acpmux {' '.join(argv)}: {type(e).__name__}")
            for f in files:
                if f.endswith((".log", ".jsonl")) or "log" in os.path.basename(f):
                    try:
                        with open(f, "rb") as fh:
                            fh.seek(max(0, os.fstat(fh.fileno()).st_size - (64 << 10)))
                            parts.append(f"-- tail {os.path.relpath(f, d)}\n" + fh.read().decode(errors="replace"))
                    except OSError:
                        pass
    debug_log = f"/tmp/cmux-debug-{tag}.log"
    if os.path.isfile(debug_log):
        with open(debug_log, "rb") as fh:
            fh.seek(max(0, os.fstat(fh.fileno()).st_size - (128 << 10)))
            parts.append(f"-- tail {debug_log}\n" + fh.read().decode(errors="replace"))
    r.save_redacted(out, f"acpmux-{label}.txt", "\n".join(parts), 3000)


TEST_AGENT = "parity-agent"


def bundle_of(app):
    return plistlib.load(open(os.path.join(app, "Contents/Info.plist"), "rb")).get("CFBundleIdentifier", "")


def acpmux_home_of(bundle):
    """The acpmux home the tagged app `bundle` runs (`~/.acpmux/builds/<bundle id>` under the account's
    home, where the app's join lives), or None when there is none yet."""
    if not bundle:
        return None
    account = pwd.getpwuid(os.getuid()).pw_dir
    for home in (account, os.path.expanduser("~")):
        d = os.path.join(home, ".acpmux", "builds", bundle)
        if os.path.isfile(os.path.join(d, "machine-credential.json")):
            return d
    return None


def add_test_agent(app):
    """B's chat needs an agent. A person's Mac has theirs (discovery finds claude or codex on PATH); this
    runner has none, so B's daemon answered every start with "no harnesses configured" (run 45924430036,
    3 of 3). Gives B's acpmux home acpmux's own test agent (tests/fake_agent.py, as readiness-soak.py and
    update-e2e.py use) as its default harness, merged into any config.json there, before B starts."""
    bundle = bundle_of(app)
    home = os.path.join(pwd.getpwuid(os.getuid()).pw_dir, ".acpmux", "builds", bundle)
    os.makedirs(home, mode=0o700, exist_ok=True)
    path = os.path.join(home, "config.json")
    config = json.load(open(path)) if os.path.isfile(path) else {}
    agent = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../cmux-tui/crates/acpmux/tests/fake_agent.py"))
    config.setdefault("harnesses", {})[TEST_AGENT] = {"argv": [sys.executable, agent]}
    config.setdefault("defaultHarness", TEST_AGENT)
    json.dump(config, open(path, "w"))
    return path


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
    return stream, sock, ls_env, tag


def probe(sock):
    """The pair rig's liveness check: a `debug.focus` call answers over the control socket."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
            c.settimeout(5)
            c.connect(sock)
            c.sendall((json.dumps({"id": 1, "method": "debug.focus", "params": {}}) + "\n").encode())
            return bool(c.recv(1 << 16))
    except OSError:
        return False


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
        sa, sock_a, env_a, tag_a = launch(a.app_a, "a", a.work, a.out, account)
        streams.append(sa)
        print("B test agent:", add_test_agent(a.app_b), flush=True)
        sb, sock_b, env_b, tag_b = launch(a.app_b, "b", a.work, a.out, account)
        streams.append(sb)
        cli = os.path.join(a.app_a, "Contents/Resources/bin/cmux")
        env = dict(os.environ, PATH=os.path.dirname(cli) + ":" + os.environ["PATH"])
        for label, sock, st, ls_env, tag in (("A", sock_a, sa, env_a, tag_a), ("B", sock_b, sb, env_b, tag_b)):
            up = r.wait_for(lambda: st.proc.poll() is None and probe(sock), 180)
            print(f"app {label}: {'answers' if up else 'NO ANSWER'} on its socket after {time.monotonic() - t0:.0f} s", flush=True)
            if not up:  # evidence only: the harness still runs and reports its own failure
                try:
                    print(f"app {label}: {r.no_answer_evidence(st.proc, ls_env, tag, sock, a.out)}", flush=True)
                except Exception as error:  # noqa: BLE001
                    print(f"app {label}: no evidence ({type(error).__name__}: {r.redact(str(error))[:200]})", flush=True)
                socks = subprocess.run("ls -la /tmp/cmux-* 2>&1 | head -40", shell=True, capture_output=True, text=True).stdout
                open(os.path.join(a.out, f"tmp-cmux-{label.lower()}.txt"), "w").write(r.redact(socks))
                print(f"app {label}: exited {st.proc.poll()}; expected socket {sock}; /tmp/cmux-*:\n{socks}", flush=True)
        # What A lists after B's sign-in (evidence for the join step, and for the name).
        time.sleep(20)
        listed = subprocess.run([cli, "--app-socket", sock_a, "app", "machines", "--json"], env=env, capture_output=True, text=True)
        open(os.path.join(a.out, "a-machines.json"), "w").write(r.redact(listed.stdout + listed.stderr))
        folder = os.path.join(a.work, "picked-folder")
        os.makedirs(folder, exist_ok=True)
        sha = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip() or "unknown"
        b_name = enroll_name(tag_b)
        print(f"B's sign-in join name: {b_name}", flush=True)
        # The CLI reaches A's own acpmux, the one A joined with. A's app keeps it under the account's
        # home (NSHomeDirectory), not this step's HOME, where `cmux acp` would start a second, unjoined
        # daemon (run 45376956910: `acp host ls` there listed no hub, so the start on B failed).
        a_home = acpmux_home_of(bundle_of(a.app_a))
        if a_home:
            env["ACPMUX_HOME"] = a_home
        print(f"A's acpmux home: {a_home or 'not found under the account home; the CLI picks one'}", flush=True)
        res = subprocess.run(["bun", "scripts/cmux-next/machine-join-e2e.ts", "--scenario", "own-machine-parity", "--a-socket", sock_a,
                              "--b-name", b_name, "--folder", os.path.realpath(folder), "--runs", "3",
                              "--report", os.path.join(os.path.realpath(a.out), "own-machine-parity.json"), "--sha", sha], env=env)
        print("harness exit", res.returncode, flush=True)
        for app, tag, label in ((a.app_a, tag_a, "a"), (a.app_b, tag_b, "b")):
            try:
                acpmux_evidence(app, tag, a.out, label)
            except Exception as e:  # noqa: BLE001
                print(f"evidence {label}: {type(e).__name__}", flush=True)
        return res.returncode  # 0 pass, 1 fail, 3 not-built: the job fails with the harness
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
