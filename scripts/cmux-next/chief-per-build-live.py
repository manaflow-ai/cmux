#!/usr/bin/env python3
"""Live proof of one Chief per build (cmux-lawrence-2 only, an --app-from-fleet
GUI job; run under `zsh -lic` for the Claude login). Everything happens under
a temp Chief root (CMUX_NEXT_CHIEF_ROOT), never ~/.cmux/chief.

  0. The shared home of older builds: app A runs on ROOT/default
     (CMUX_NEXT_CHIEF_HOME), one message M0 gets a reply, A quits (end sessions).
  1. A as NIGHTLY (CMUX_NEXT_CHIEF_BUILD_ID=com.cmuxterm.app.nightly, a DEBUG
     override) resolves ROOT/default: its brain holds that lock, the memory
     still holds M0 once and Home shows it.
  2. B, a copy of the app with bundle id com.cmuxterm.app.debug.<tag>b (ad-hoc
     signed), runs at the same time: its home is ROOT/com.cmuxterm.app.debug.<tag>b,
     empty (no M0), with its own brain, tools socket and acpmux socket.
  3. B quits with quitEndSessions: A's brain is the same process, still alive,
     and A answers a new message.

Exit 0 when every step passed; the first failed step's number otherwise.
Usage: chief-per-build-live.py --tag TAG --app APP [--reply-wait 240] [--out DIR]
"""
import argparse, json, os, shutil, socket, sqlite3, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--tag", required=True)
ap.add_argument("--app", required=True)
ap.add_argument("--reply-wait", type=float, default=240)
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
opts = ap.parse_args()

TAG = opts.tag
# A short path: the brains' sockets (optchat/tools.sock) must fit sun_path
# (104 bytes); a job's TMPDIR is too deep.
SCRATCH = tempfile.mkdtemp(prefix="cpb-", dir="/tmp")
ROOT = os.path.join(SCRATCH, "chief")
NIGHTLY_HOME = os.path.join(ROOT, "default")
TAG_B = f"{TAG}b"
BUNDLE_B = f"com.cmuxterm.app.debug.{TAG_B}"
B_HOME = os.path.join(ROOT, BUNDLE_B)
os.makedirs(opts.out, exist_ok=True)


def say(*parts):
    print(*parts, flush=True)


class App:
    def __init__(self, name, app, tag):
        self.name, self.app, self.tag = name, app, tag
        self.binary = os.path.join(app, "Contents/MacOS/cmux DEV")
        self.cli = os.path.join(app, "Contents/Resources/bin/cmux")
        self.acpmux = os.path.join(app, "Contents/Resources/bin/acpmux")
        self.socket = f"/tmp/cmux-debug-{tag}.sock"
        self.proc = None

    def rpc(self, method, params=None, timeout=30):
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(self.socket)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
            conn.close()
            reply = json.loads(buf)
            return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
        except (OSError, ValueError) as error:
            return {"error": str(error)}

    def launch(self, extra):
        keep = ("HOME", "USER", "LOGNAME", "TMPDIR", "SHELL", "LANG", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR")
        env = {k: v for k, v in os.environ.items() if k in keep}
        config = os.path.join(SCRATCH, "cmux.json")
        open(config, "w").write("{}")
        env.update({"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
                    "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config})
        env.update(extra)
        log = open(os.path.join(opts.out, f"app-{self.tag}.log"), "a")
        self.proc = subprocess.Popen([self.binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        up = wait(lambda: (self.rpc("debug.windows") or {}).get("windows"), 300)
        self.rpc("action.run", {"id": "home.show"})
        say(f"{self.name} ({self.tag}) pid {self.proc.pid}: {'up' if up else 'NOT UP'}")
        return bool(up)

    def chief_row(self):
        rows = [c for c in (self.rpc("debug.home") or {}).get("conversations", []) if "agent_mux" in c.get("participants", [])]
        return rows[0] if rows else None

    def shown(self):
        return [(m["author"], m["text"]) for m in (self.chief_row() or {}).get("shown_tail", [])]

    def send(self, text):
        say(self.name, "drive", self.rpc("debug.home.drive", {"action": "focus"}),
            self.rpc("debug.home.drive", {"action": "type", "text": text}), self.rpc("debug.home.drive", {"action": "send"}))

        def answered():
            shown = self.shown()
            mine = [i for i, (_, t) in enumerate(shown) if t == text]
            return mine and any(a == "agent_mux" for a, _ in shown[mine[-1] + 1:])
        return bool(wait(answered, opts.reply_wait, 2))

    def quit(self, home):
        self.rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
        try:
            self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            say(f"{self.name} pid {self.proc.pid} did not quit within 60 s")
        cleanup(self, home)


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def brain_pid(home):
    """The pid in host.lock while that process runs optchat-chief, else None.
    Never takes the flock: a probe can make a brain that starts at that instant exit."""
    try:
        pid = int(open(os.path.join(home, "state", "host.lock")).read().split()[0])
    except (OSError, ValueError, IndexError):
        return None
    comm = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
    return pid if comm.endswith("optchat-chief") else None


def alive(pid):
    return subprocess.run(["ps", "-p", str(pid)], capture_output=True).returncode == 0


def memory_count(home, text):
    path = os.path.join(home, "optchat", "memory.sqlite3")
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
        try:
            rows = db.execute("SELECT kind, text FROM messages").fetchall()
        finally:
            db.close()
    except sqlite3.Error:
        return -1
    return sum(1 for kind, body in rows if kind == "user" and text in body)


def cleanup(app, home):
    """The Chief of `home`: its acpmux daemon and router, then brain and owner (documented stop)."""
    acpmux_home = os.path.join(home, "acpmux")
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ACPMUX_", "CMUX_"))}
    subprocess.run([app.acpmux, "daemon", "shutdown"], env={**env, "ACPMUX_HOME": acpmux_home}, capture_output=True, timeout=30)
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(5)
        conn.connect(os.path.join(acpmux_home, "router", "router.sock"))
        conn.sendall(b'{"op":"shutdown"}\n')
        conn.recv(4096)
        conn.close()
    except OSError:
        pass
    subprocess.run([app.cli, "chief", "shutdown", "--chief-home", home], env=env, capture_output=True, timeout=90)


def copy_as_b(src):
    """App B: the same build under another bundle id (another tag, sockets and Chief home)."""
    dst = os.path.join(SCRATCH, "B.app")
    subprocess.run(["ditto", src, dst], check=True)
    subprocess.run(["/usr/libexec/PlistBuddy", "-c", f"Set :CFBundleIdentifier {BUNDLE_B}",
                    os.path.join(dst, "Contents/Info.plist")], check=True)
    signed = subprocess.run(["codesign", "--force", "--deep", "--sign", "-", dst], capture_output=True, text=True)
    say("B signed:", signed.returncode, signed.stderr.strip()[-200:])
    return dst


a = App("A", opts.app, TAG)
b = None
failed = 0
m0 = f"per-build check {TAG}: M0 on the shared home, reply with only the word ok."
m1 = f"per-build check {TAG}: M1 after B quit, reply with only the word ok."
# The temp homes never push a memory backup and never take in this host's
# old per-tag Chiefs (~/.cmux/mux/tags): a backup setting and a done
# migration record before the first launch.
for home in (NIGHTLY_HOME, B_HOME):
    os.makedirs(os.path.join(home, "optchat"), exist_ok=True)
    open(os.path.join(home, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
open(os.path.join(NIGHTLY_HOME, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
try:
    # 0. the shared home of older builds
    a.launch({"CMUX_NEXT_CHIEF_HOME": NIGHTLY_HOME})
    ok0 = wait(lambda: brain_pid(NIGHTLY_HOME), 180) and a.send(m0)
    say(f"step 0: shared home {NIGHTLY_HOME}: brain and reply {'ok' if ok0 else 'FAILED'}")
    a.quit(NIGHTLY_HOME)
    if not ok0:
        failed = failed or 10
        raise SystemExit
    # 1. A as NIGHTLY under the temp root keeps that home
    a.launch({"CMUX_NEXT_CHIEF_ROOT": ROOT, "CMUX_NEXT_CHIEF_BUILD_ID": "com.cmuxterm.app.nightly"})
    a_brain = wait(lambda: brain_pid(NIGHTLY_HOME), 180)
    shown_m0 = wait(lambda: any(t == m0 for _, t in a.shown()), 60)
    count = memory_count(NIGHTLY_HOME, m0)
    others = sorted(n for n in os.listdir(ROOT) if n not in ("default", BUNDLE_B))
    say(f"step 1: NIGHTLY brain {a_brain} on default; Home shows M0: {bool(shown_m0)}; memory has M0 {count}x; other homes {others}")
    if not (a_brain and shown_m0 and count == 1 and not others):
        failed = failed or 1
    # 2. B at the same time: its own empty home and brain
    b = App("B", copy_as_b(opts.app), TAG_B)
    b.launch({"CMUX_NEXT_CHIEF_ROOT": ROOT})
    b_brain = wait(lambda: brain_pid(B_HOME), 180)
    wait(lambda: b.chief_row(), 60)
    b_shown = b.shown()
    sockets = {h: os.path.exists(os.path.join(h, "optchat", "tools.sock")) for h in (NIGHTLY_HOME, B_HOME)}
    say(f"step 2: B brain {b_brain} on {B_HOME}; A brain {brain_pid(NIGHTLY_HOME)}; B shows {len(b_shown)} messages;"
        f" M0 in B: {any(t == m0 for _, t in b_shown)}; tools sockets {sockets}; memory M0 in B {memory_count(B_HOME, m0)}")
    if not (b_brain and b_brain != a_brain and not any(t == m0 for _, t in b_shown) and all(sockets.values())
            and memory_count(B_HOME, m0) <= 0):
        failed = failed or 2
    # 3. B quits; A's brain is untouched and answers
    b.quit(B_HOME)
    after = brain_pid(NIGHTLY_HOME)
    replied = a.send(m1)
    say(f"step 3: after B quit, A brain {after} (was {a_brain}, alive {bool(a_brain) and alive(a_brain)}); A replied {replied}")
    if not (after == a_brain and alive(a_brain) and replied):
        failed = failed or 3
except SystemExit:
    pass
finally:
    if a.proc and a.proc.poll() is None:
        a.quit(NIGHTLY_HOME)
    if b and b.proc and b.proc.poll() is None:
        b.quit(B_HOME)
    # Nothing of the run stays: the B copy and the temp homes with their memory.
    shutil.rmtree(SCRATCH, ignore_errors=True)
    say("result", "PASS" if failed == 0 else f"FAIL {failed}")
sys.exit(failed)
