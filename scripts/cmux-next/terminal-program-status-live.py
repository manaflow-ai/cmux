#!/usr/bin/env python3
"""OSC 7501 program status (OSC-7501-PROGRAM-STATUS), live on a tagged build.

Launches the tagged app (no-activate, automation socket, scratch cmux.json), makes a workspace,
and types reports into its shell. Reads the daemon's records back with the public CLI,
`cmux terminal <id> status --json`:

  working    printf '\\e]7501;state=working:progress=40\\e\\\\'; sleep: one root record, working, 40
  prompt     after the command ends, a new primary prompt removes the working record
             (needs cmux shell integration, OSC 133;A; reported, not failed, when absent)
  blocked    kind=permission, base64 msg: decoded text, kind
  done       state=done:app=demo stays after the next prompt
  children   id=build and id=build/test; clear id=build removes both, the root stays
  query      OSC 7501 ; ? is answered with ESC ] 7501 ; ? ST (raw tty read)
  clear      state=clear removes every record

Run on cmux-lawrence-2 or a fleet Mac, never on the laptop. Exit 1 on any failed check.
Usage: terminal-program-status-live.py --tag <tag> [--app <bundle>]
"""
import argparse, glob, json, os, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}; pass --app")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = os.path.realpath(tempfile.mkdtemp(prefix="osc7501", dir="/tmp"))
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures, notes, evidence = [], [], {}
app = None


def daemon_socket():
    """The tag's cmux-tui session socket (`cmux-app-<tag>`)."""
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


def rpc(method, params=None, timeout=30):
    """One request line on the app control socket."""
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
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
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


def status(terminal):
    value = cli_json("terminal", terminal, "status")
    return value if isinstance(value, list) else None


def by_id(records):
    return {record.get("id"): record for record in records or []}


def expect(name, terminal, predicate, seconds=10):
    def met():
        records = status(terminal)
        return records is not None and bool(predicate(by_id(records)))
    ok = bool(wait(met, seconds))
    last = status(terminal)
    evidence[name] = last
    print(f"{'ok  ' if ok else 'FAIL'} {name}: {json.dumps(last)}", flush=True)
    if not ok:
        failures.append(f"{name}: {json.dumps(last)}")
    return ok


def report(terminal, body, tail=""):
    cli("terminal", terminal, "write", "--text", f"printf '\\033]7501;{body}\\033\\\\'{tail}\n")


teardown = TagTeardown(APP)
teardown.install()
try:
    launch()
    before = set(terminals())
    rpc("action.run", {"action": "workspace new", "args": {"focus": True}, "origin": "script"})
    new = wait(lambda: sorted(set(terminals()) - before), 30)
    if not new:
        failures.append("no terminal after workspace new")
        raise SystemExit(1)
    term = new[0]
    time.sleep(2)  # the shell draws its first prompt (harness wait)

    # The decision's shell example; sleep keeps the program in the foreground.
    report(term, "state=working:progress=40", "; sleep 6")
    expect("working", term, lambda r: r.get("", {}).get("state") == "working" and r[""].get("progress") == 40)
    if not wait(lambda: (lambda r: r is not None and "" not in by_id(r))(status(term)), 15):
        notes.append("prompt: the working record stayed after the command ended (no OSC 133;A from the shell?)")
        print("note prompt: working record not removed at the next prompt", flush=True)
    else:
        print("ok   prompt: the next primary prompt removed the working record", flush=True)

    msg = "QXBwbHkgdGhlIHBsYW4/"  # "Apply the plan?"
    report(term, f"state=blocked:kind=permission:app=demo:msg={msg}", "; sleep 6")
    expect("blocked", term, lambda r: r.get("", {}).get("state") == "blocked"
           and r[""].get("kind") == "permission" and r[""].get("msg") == "Apply the plan?")

    report(term, "state=done:app=demo")
    expect("done", term, lambda r: r.get("", {}).get("state") == "done")
    time.sleep(2)  # past the next prompt (harness wait)
    expect("done-after-prompt", term, lambda r: r.get("", {}).get("state") == "done")

    report(term, "state=error:id=build:title=QnVpbGQ=")
    report(term, "state=error:id=build/test")
    expect("children", term, lambda r: {"", "build", "build/test"} <= set(r) and r["build"].get("title") == "Build")
    report(term, "state=clear:id=build")
    expect("clear-subtree", term, lambda r: set(r) == {""})

    # The support query: read the reply from a raw tty.
    cli("terminal", term, "write", "--text",
        "stty raw -echo; printf '\\033]7501;?\\033\\\\'; r=$(dd bs=1 count=10 2>/dev/null | od -An -c | tr -d ' \\n'); "
        "stty sane; echo \"Q7501=$r\"\n")
    screen = wait(lambda: (lambda s: s if "Q7501=" in s else None)(cli("terminal", term, "screen", "read").stdout), 15)
    line = next((l for l in (screen or "").splitlines() if "Q7501=" in l and "$r" not in l), "")
    evidence["query"] = line.strip()
    if "033]7501;?033\\" in line:
        print(f"ok   query: {line.strip()}", flush=True)
    else:
        failures.append(f"query: no ESC ] 7501 ; ? ST reply ({line.strip()!r})")
        print(f"FAIL query: {line.strip()!r}", flush=True)

    report(term, "state=clear")
    expect("clear-all", term, lambda r: not r)
finally:
    quit_app()
    teardown.end()
    print(json.dumps({"evidence": evidence, "notes": notes, "failures": failures}, indent=1), flush=True)
sys.exit(1 if failures else 0)
