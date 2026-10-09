#!/usr/bin/env python3
"""OSC 7501 program status: the specification's examples on a tagged build, with evidence.

Spec: https://www.superlogical.com/rex/docs/build/program-status (matrix in
plans/cmux-next/osc7501-conformance.md). Launches the tagged app (no-activate,
automation socket, scratch cmux.json), types each example into a workspace
shell, reads the daemon's records back (`cmux terminal <id> status`), the
notifications (`debug.notifications`), and saves a window snapshot per step:

  terraform   the spec's first example: blocked, kind=permission, app=terraform
  rsync       the spec's shell function around rsync: working -> done, then error
  deploy      the spec's "Several records" example: root working, us-east 40 %,
              eu-west blocked; regions inherit app=deploy; clears; root done
  bel         a report ended with BEL instead of ESC \\
  discarded   reports the spec discards whole (unknown state, bad base64, a control
              character in msg, msg over 2732 encoded bytes, an invalid id)
  bidi        a msg with a right-to-left override and a zero-width space is kept
              without them
  query       OSC 7501 ; ? is answered with the same body, ST and BEL
  terminfo    infocmp shows Pst in the terminal's TERM entry; XTGETTCAP Pst
  tui         the cmux TUI attached to the same daemon, screen text + snapshot

Run on cmux-lawrence-2 (never on the laptop). Writes <out>/report.json and PNGs.
Exit 1 when a check fails; `notes` lists behavior that is reported, not failed.
Usage: terminal-program-status-conformance-live.py --tag <tag> --out <dir> [--app <bundle>]
"""
import argparse, base64, glob, json, os, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}; pass --app")
OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = os.path.realpath(tempfile.mkdtemp(prefix="osc7501c", dir="/tmp"))
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
report = {"tag": opts.tag, "app": APP, "steps": {}, "notes": [], "failures": []}
app = None


def b64(text):
    return base64.b64encode(text.encode()).decode()


def daemon_socket():
    roots = {os.environ.get("TMPDIR", "/tmp"), BASE_ENV["TMPDIR"], "/tmp"}
    darwin_tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    if darwin_tmp:
        roots.add(darwin_tmp)
    for root in roots:
        found = glob.glob(os.path.join(root, "cmux-tui-*", f"cmux-app-{opts.tag}.sock"))
        if found:
            return found[0]
    return None


def cli(*args, timeout=30):
    sock = daemon_socket()
    target = ["--socket", sock] if sock else ["--app-socket", SOCKET]
    return subprocess.run([CLI, *target, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)


def cli_json(*args):
    r = cli("--json", *args)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def rpc(method, params=None, timeout=60):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect(SOCKET)
            sock.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                chunk = sock.recv(1 << 20)
                if not chunk:
                    break
                data += chunk
        reply = json.loads(data)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def rows(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for k in ("items", "terminals", "result", "data"):
            if isinstance(value.get(k), list):
                return value[k]
    return []


def terminals():
    return {row["id"]: row for row in rows(cli_json("terminal", "list")) if isinstance(row, dict) and row.get("id")}


def launch():
    global app
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    cfg = os.path.join(SCRATCH, "cmux.json")
    with open(cfg, "w") as f:
        json.dump({}, f)
    env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": cfg,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1280,800"}
    log = open(os.path.join(SCRATCH, "app.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    up = wait(lambda: os.path.exists(SOCKET) and "windows" in rpc("debug.surfaces"), 180, 0.5)
    if up and not rpc("debug.surfaces").get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script", "focus": True})
    if not wait(lambda: os.path.exists(SOCKET) and rpc("debug.surfaces").get("windows"), 60, 0.5):
        tail = open(os.path.join(SCRATCH, "app.log"), errors="replace").read()[-4000:]
        sys.exit(f"tagged app did not come up (exit {app.poll()}); log tail:\n{tail}")
    print(f"launched pid {app.pid}", flush=True)


def quit_app():
    if app and app.poll() is None:
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.send_signal(signal.SIGKILL)  # the exact PID this script started
            app.wait()


def new_workspace(name):
    before = set(terminals())
    rpc("action.run", {"action": "workspace new", "args": {"focus": True}, "origin": "script"})
    new = wait(lambda: sorted(set(terminals()) - before), 30)
    if not new:
        raise SystemExit(f"no terminal after workspace new ({name})")
    cli("workspace", "current", "rename", name)  # best effort: names the source in banners
    time.sleep(2)  # the shell draws its first prompt (harness wait)
    return new[0]


def status(terminal):
    value = cli_json("terminal", terminal, "status")
    return value if isinstance(value, list) else None


def by_id(records):
    return {record.get("id"): record for record in records or []}


def run(terminal, line):
    cli("terminal", terminal, "write", "--text", line + "\n")


def osc(body, end="\\033\\\\"):
    return f"printf '\\033]7501;{body}{end}'"


def banners():
    value = rpc("debug.notifications")
    return value.get("banners", []) if isinstance(value, dict) else []


def notifications():
    value = cli_json("notification", "list")
    return rows(value) if not isinstance(value, dict) or "error" not in value else value


def shot(name):
    path = os.path.join(OUT, f"{name}.png")
    result = rpc("debug.window_snapshot", {"kind": "main", "path": path})
    return path if os.path.exists(path) else {"error": result}


def step(name, terminal, predicate, seconds=10, fail=True, extra=None):
    def met():
        records = status(terminal)
        return records is not None and bool(predicate(by_id(records)))
    ok = bool(wait(met, seconds))
    entry = {"ok": ok, "records": status(terminal), "snapshot": shot(name)}
    if extra:
        entry.update(extra())
    report["steps"][name] = entry
    print(f"{'ok  ' if ok else ('FAIL' if fail else 'note')} {name}: {json.dumps(entry['records'])}", flush=True)
    if not ok:
        (report["failures"] if fail else report["notes"]).append(f"{name}: {json.dumps(entry['records'])}")
    return ok


def banner_titles():
    return {"banners": [{k: b.get(k) for k in ("title", "subtitle", "body")} for b in banners()]}


def expect_banner(name, title):
    found = wait(lambda: any(b.get("title") == title for b in banners()), 8)
    entry = report["steps"].setdefault(name, {})
    entry["banner_expected"] = title
    entry["banner_found"] = bool(found)
    entry.update(banner_titles())
    print(f"{'ok  ' if found else 'GAP '} {name}: banner {title!r}", flush=True)
    if not found:
        report["notes"].append(f"{name}: no banner {title!r}")


def read_screen(terminal):
    return cli("terminal", terminal, "screen", "read").stdout


teardown = TagTeardown(APP)
teardown.install()
try:
    launch()
    term = new_workspace("osc7501-spec")

    # 1. The spec's first example (Terraform waits for approval).
    tf_msg = "QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/"
    run(term, osc(f"state=blocked:kind=permission:app=terraform:msg={tf_msg}") + "; sleep 10")
    step("terraform", term, lambda r: r.get("", {}).get("state") == "blocked" and r[""].get("kind") == "permission"
         and r[""].get("app") == "terraform" and r[""].get("msg") == "Apply 3 to add, 1 to change, 0 to destroy?",
         extra=banner_titles)
    expect_banner("terraform", "terraform needs approval")
    wait(lambda: "" not in by_id(status(term)), 15)  # the next prompt ends the blocked record

    # 2. The spec's shell function around rsync, success then failure.
    run(term, "status() { printf '\\033]7501;state=%s:msg=%s\\033\\\\' \"$1\" \"$(printf '%s' \"$2\" | base64 | tr -d '\\n')\"; }")
    run(term, "mkdir -p /tmp/osc7501-rsync/src && echo photo > /tmp/osc7501-rsync/src/a.jpg")
    run(term, "status working 'Syncing photos'; sleep 3; rsync -a /tmp/osc7501-rsync/src/ /tmp/osc7501-rsync/dst/ "
              "&& status done 'Photos synced' || status error 'rsync failed'")
    step("rsync-working", term, lambda r: r.get("", {}).get("state") == "working" and r[""].get("msg") == "Syncing photos")
    step("rsync-done", term, lambda r: r.get("", {}).get("state") == "done" and r[""].get("msg") == "Photos synced")
    time.sleep(2)  # past the next prompt (harness wait)
    step("rsync-done-after-prompt", term, lambda r: r.get("", {}).get("state") == "done")
    run(term, "rsync -a /tmp/osc7501-rsync/missing/ /tmp/osc7501-rsync/dst/ 2>/dev/null "
              "&& status done 'Photos synced' || status error 'rsync failed'")
    step("rsync-error", term, lambda r: r.get("", {}).get("state") == "error" and r[""].get("msg") == "rsync failed",
         extra=banner_titles)
    expect_banner("rsync-error", "A program failed")
    run(term, osc("state=clear"))
    step("rsync-cleared", term, lambda r: not r)

    # 3. The spec's "Several records" example.
    deploy = new_workspace("osc7501-deploy")
    run(deploy, osc(f"state=working:app=deploy:msg={b64('Deploying v2.4.1')}") + "; " +
        osc(f"state=working:id=us-east:title={b64('US East')}:progress=40:msg={b64('Pushing image')}") + "; " +
        osc(f"state=blocked:kind=permission:id=eu-west:title={b64('EU West')}:"
            f"msg={b64('Approve deploy to eu-west (production)?')}") + "; sleep 12")
    step("deploy-three-records", deploy, lambda r: r.get("", {}).get("state") == "working"
         and r.get("us-east", {}).get("progress") == 40 and r.get("eu-west", {}).get("state") == "blocked",
         extra=banner_titles)
    step("deploy-app-inherited", deploy, lambda r: r.get("us-east", {}).get("app") == "deploy"
         and r.get("eu-west", {}).get("app") == "deploy", seconds=2, fail=False)
    expect_banner("deploy-three-records", "EU West needs approval")
    wait(lambda: not by_id(status(deploy)), 20)  # the prompt ends working/blocked records
    run(deploy, osc(f"state=working:app=deploy:msg={b64('Deploying v2.4.1')}") + "; " +
        osc(f"state=done:id=us-east:title={b64('US East')}:msg={b64('Healthy')}") + "; " +
        osc(f"state=blocked:kind=permission:id=eu-west:title={b64('EU West')}") + "; sleep 1; " +
        osc("state=clear:id=us-east") + "; " + osc("state=clear:id=eu-west") + "; " +
        osc(f"state=done:app=deploy:msg={b64('Deployed to 3 regions')}"))
    step("deploy-done", deploy, lambda r: set(r) == {""} and r[""].get("state") == "done"
         and r[""].get("msg") == "Deployed to 3 regions")
    run(deploy, osc("state=working:id=build") + "; " + osc("state=working:id=build/test") + "; " +
        osc("state=clear:id=build") + "; sleep 4")
    step("hierarchical-clear", deploy, lambda r: "build" not in r and "build/test" not in r and "" in r)

    # 4. BEL terminator, 5. discarded reports, 6. bidi.
    run(term, osc("state=working:app=bel", end="\\007") + "; sleep 4")
    step("bel", term, lambda r: r.get("", {}).get("app") == "bel")
    time.sleep(5)
    run(term, osc("state=done:app=baseline"))
    step("discard-baseline", term, lambda r: r.get("", {}).get("app") == "baseline")
    bad = ["state=sleeping:app=bad1", "state=done:app=bad2:msg=a", f"state=done:app=bad3:msg={b64('a' + chr(10) + 'b')}",
           "state=done:app=bad4:msg=" + "QUFB" * 920, "state=done:app=bad5:id=a//b"]
    run(term, "; ".join(osc(body) for body in bad))
    time.sleep(2)  # harness wait: the reports are processed in order
    step("discarded", term, lambda r: r.get("", {}).get("app") == "baseline" and "a//b" not in r)
    run(term, osc(f"state=done:app=bidi:msg={b64('ok' + chr(0x202E) + 'gnp.exe' + chr(0x200B))}"))
    step("bidi", term, lambda r: r.get("", {}).get("msg") == "okgnp.exe")

    # 7. The support query, ST and BEL.
    for name, end, expected in (("query-st", "\\033\\\\", "033]7501;?033\\"), ("query-bel", "\\007", "033]7501;?007")):
        run(term, f"stty raw -echo; printf '\\033]7501;?{end}'; r=$(dd bs=1 count={10 if end.startswith(chr(92) + '033') else 9} "
                  f"2>/dev/null | od -An -c | tr -d ' \\n'); stty sane; echo \"Q{name}=$r\"")
        screen = wait(lambda: (lambda s: s if f"Q{name}=" in s else None)(read_screen(term)), 15)
        line = next((l for l in (screen or "").splitlines() if f"Q{name}=" in l and "$r" not in l), "")
        ok = expected in line
        report["steps"][name] = {"ok": ok, "line": line.strip()}
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {line.strip()}", flush=True)
        if not ok:
            report["failures"].append(f"{name}: {line.strip()!r}")

    # 8. Terminfo Pst and XTGETTCAP Pst.
    run(term, "clear; echo TERM=$TERM; infocmp -x 2>/dev/null | tr ',' '\\n' | grep -c 'Pst=' | sed 's/^/PSTCOUNT=/'")
    screen = wait(lambda: (lambda s: s if "PSTCOUNT=" in s else None)(read_screen(term)), 15) or ""
    pst = next((l for l in screen.splitlines() if l.startswith("PSTCOUNT=")), "")
    report["steps"]["terminfo-pst"] = {"ok": pst == "PSTCOUNT=1", "screen": screen.strip()[-400:]}
    print(f"{'ok  ' if pst == 'PSTCOUNT=1' else 'GAP '} terminfo-pst: {pst}", flush=True)
    if pst != "PSTCOUNT=1":
        report["notes"].append(f"terminfo-pst: {pst}")
    run(term, "stty raw -echo; printf '\\033P+q507374\\033\\\\'; r=$(dd bs=1 count=12 2>/dev/null & p=$!; sleep 2; kill $p 2>/dev/null; wait $p) ; "
              "stty sane; echo \"XTG=$(printf '%s' \"$r\" | od -An -c | tr -d ' \\n')\"")
    screen = wait(lambda: (lambda s: s if "XTG=" in s else None)(read_screen(term)), 15) or ""
    xtg = next((l for l in screen.splitlines() if "XTG=" in l and "$(" not in l), "")
    ok = "P1+r507374" in xtg
    report["steps"]["xtgettcap-pst"] = {"ok": ok, "line": xtg.strip()}
    print(f"{'ok  ' if ok else 'GAP '} xtgettcap-pst: {xtg.strip()}", flush=True)
    if not ok:
        report["notes"].append(f"xtgettcap-pst: {xtg.strip()!r}")

    # Leave visible state for the final screenshots: a blocked record in one
    # workspace, an unseen error in the other.
    run(deploy, osc(f"state=blocked:kind=question:app=deploy:msg={b64('Which region next?')}") + "; sleep 40")
    run(term, osc(f"state=error:app=build:msg={b64('exit 2')}"))
    step("final-blocked", deploy, lambda r: r.get("", {}).get("state") == "blocked")
    step("final-error", term, lambda r: r.get("", {}).get("state") == "error", extra=banner_titles)
    report["notifications_daemon"] = notifications()

    # 9. The cmux TUI attached to the same daemon, in a third workspace.
    tui = new_workspace("osc7501-tui")
    sock = daemon_socket()
    run(tui, f"'{CLI}' attach --socket '{sock}'")
    time.sleep(6)  # harness wait: the TUI draws its first frame
    screen = read_screen(tui)
    with open(os.path.join(OUT, "tui-screen.txt"), "w") as f:
        f.write(screen)
    report["steps"]["tui"] = {"screen_file": os.path.join(OUT, "tui-screen.txt"), "snapshot": shot("tui")}
    print("tui screen:\n" + screen, flush=True)
    cli("terminal", tui, "write", "--text", "\x02d")  # best effort detach (prefix d)
finally:
    with open(os.path.join(OUT, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    quit_app()
    teardown.end()
    print(json.dumps({"notes": report["notes"], "failures": report["failures"]}, indent=1), flush=True)
sys.exit(1 if report["failures"] else 0)
