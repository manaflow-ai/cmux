#!/usr/bin/env python3
"""Back and forth: one chat moved by hand between the laptop and the Cloud machine, while it
is idle and in the middle of a turn, with both sides running side by side.

Each round moves the chat to the Cloud and back. Odd rounds go up idle (`/cloud` typed in the
chat) and come back in the middle of a turn (`/local`); even rounds go up in the middle of a turn
(`auto move ID cloud` from a second device) and come back idle (`auto move ID local`). Every
prompt appends its own tag to log.txt, so at the end log.txt must hold every tag once, in order:
a turn that was cut by a move is continued on the other side and lands once.

  python3 tests/pingpong.py [ROUNDS]                          scripted agent (default 3 rounds)
  AUTO_TEST_AGENT=claude python3 tests/pingpong.py 2          real Claude Code on both sides
  AUTO_TEST_STORE_URL=... AUTO_TEST_STORE_TOKEN=... python3 tests/pingpong.py 2
                                                              against a store and machine that
                                                              run already (./remote.sh up)
"""
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, HERE)
from autodemo.agent import tree  # noqa: E402
from autodemo.client import Client, Offline, Refused  # noqa: E402

AUTO = [sys.executable, os.path.join(HERE, "auto")]
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else int(os.environ.get("AUTO_TEST_ROUNDS", "3"))
PORT = int(os.environ.get("AUTO_TEST_PORT", "17727"))
REMOTE = os.environ.get("AUTO_TEST_STORE_URL")
REAL = bool(REMOTE) or os.environ.get("AUTO_TEST_AGENT") == "claude"
MODEL = os.environ.get("AUTO_TEST_MODEL")
RUN = os.urandom(2).hex()
CHAT = "pp-" + RUN if REMOTE else "c1"
LEASE = 15.0 if REAL else 8.0
SLOW = 240 if REAL else 60
T0 = time.time()


def line_prompt(tag):
    if REAL:
        return "Run this one Bash tool call: echo %s >> log.txt . Then reply with only: ok %s" % (tag, tag)
    return "tag:%s note" % tag


def slow_prompt(tag):
    if REAL:
        return ("Run exactly these two separate Bash tool calls, in this order: "
                "1) python3 -c 'import time; time.sleep(20)'  2) echo %s >> log.txt . "
                "Then reply with only: ok %s" % (tag, tag))
    return "tag:%s slow:6" % tag


def log(text):
    print("%6.1fs  %s" % (time.time() - T0, text), flush=True)


def until(what, check, timeout=60, quiet=False):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            last = check()
        except (Offline, Refused, OSError):
            last = None
        if last:
            if not quiet:
                log("ok: " + what)
            return last
        time.sleep(0.2)
    raise SystemExit("FAILED waiting for: %s (last: %r)" % (what, last))


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def main():
    root = tempfile.mkdtemp(prefix="auto-pingpong-")
    proj = os.path.join(root, "laptop", "proj")
    os.makedirs(proj)
    with open(os.path.join(proj, "README.md"), "w") as f:
        f.write("a project\n")
    url, token = REMOTE or "http://127.0.0.1:%d" % PORT, os.environ.get("AUTO_TEST_STORE_TOKEN", "t")
    base = dict(os.environ, AUTO_STORE_URL=url, AUTO_STORE_TOKEN=token, AUTO_PLAIN="1", PYTHONUNBUFFERED="1")
    base.pop("AUTO_AGENT_CMD", None)
    if not REAL:
        base["AUTO_AGENT_CMD"] = "fake"
    model = ["--model", MODEL] if MODEL else []

    def env(role):
        return dict(base, AUTO_HOME=os.path.join(root, role, "home"), AUTO_FAKE_HOST=role,
                    AUTO_CLAUDE_CONFIG_DIR=os.path.join(root, role, "agent-config"),
                    AUTO_DEVICE="device:" + role)

    procs = []

    def spawn(role, args, **kw):
        out = open(os.path.join(root, role + ".log"), "a")
        p = subprocess.Popen(AUTO + args, env=env(role), stdout=out, stderr=subprocess.STDOUT, **kw)
        procs.append(p)
        return p

    ok = False
    try:
        c = Client(url, token)
        if REMOTE:
            machine = until("the store answers and has a machine", lambda: c.status()["machine"])["name"]
        else:
            machine = "demo-vm"
            spawn("store", ["serve", "--host", "127.0.0.1", "--port", str(PORT), "--token", "t",
                            "--lease", str(LEASE), "--data", os.path.join(root, "store")])
            until("the store answers", lambda: c.status())
            spawn("cloud", ["machine", "--name", machine, "--work", os.path.join(root, "cloud", "work")] + model)
            until("the machine asked for work", lambda: c.status()["machine"])
        vm, lap = "vm:" + machine, "device:laptop"
        names = {vm: "Cloud", lap: "laptop"}

        def events():
            return c.events(CHAT, 0)["events"]

        def prompt_of(tag, evs):
            for e in evs:
                if e["kind"] == "user" and tag in e["text"]:
                    return e
            return None

        def ended_by(tag):
            evs = events()
            user = prompt_of(tag, evs)
            ends = [e for e in evs if user and e["kind"] == "turn_end" and e["id"] == user["id"]]
            return ends[-1]["by"] if ends else None

        def in_tool(tag, holder):
            """The prompt's long tool call is running on `holder`, and the store knows."""
            evs = events()
            user = prompt_of(tag, evs)
            if not user:
                return False
            start = [e for e in evs if e["kind"] == "turn_start" and e["id"] == user["id"]]
            if not start:
                return False
            later = [e for e in evs if e["seq"] > start[0]["seq"] and e["kind"] in ("tool", "tool_result")]
            return bool(later) and later[-1]["kind"] == "tool" and "sleep" in later[-1]["label"] \
                and later[-1]["by"] == holder

        expected, expected_by, moves = [], {}, []

        def typed(text):
            laptop.stdin.write(text.encode() + b"\n")
            laptop.stdin.flush()

        def ask(kind, n, holder, slow=False):
            tag = "%s%d-%s" % (kind, n, RUN)
            expected.append(tag)
            expected_by[tag] = holder
            typed(slow_prompt(tag) if slow else line_prompt(tag))
            return tag

        def done(tag, holder):
            by = until("%s ended on the %s" % (tag, names[holder]), lambda: ended_by(tag), SLOW)
            assert by == holder, "%s ended on %s, expected %s" % (tag, by, holder)

        def move(to, how, mid):
            target = vm if to == "cloud" else lap
            began = time.time()
            if how == "chat":
                typed("/" + to)
            else:
                out = subprocess.run(AUTO + ["move", CHAT, to], env=env("phone"), capture_output=True, text=True)
                assert out.returncode == 0, out.stderr.strip() or out.stdout.strip()
            until("the chat is %s" % ("in the Cloud" if to == "cloud" else "on the laptop"),
                  lambda: c.chat(CHAT)["holder"] == target, 60, quiet=True)
            took = time.time() - began
            moves.append((to, "mid-turn" if mid else "idle", how, took))
            log("moved to the %s in %.1fs (%s, asked from the %s)"
                % (names[target], took, "in the middle of a turn" if mid else "idle",
                   "chat" if how == "chat" else "second device"))

        first = "R0-" + RUN
        expected.append(first)
        expected_by[first] = lap
        opening = line_prompt(first)
        if REAL:
            opening = "The secret word of this chat is PINEAPPLE; remember it. " + opening
        laptop = spawn("laptop", ["chat", CHAT, "-C", proj, "-m", opening] + model, stdin=subprocess.PIPE)
        log("chat %s, %d round(s)" % (CHAT, ROUNDS))
        done(first, lap)

        for n in range(1, ROUNDS + 1):
            log("-- round %d --" % n)
            if n % 2:
                move("cloud", "chat", False)
            else:
                tag = ask("L", n, vm, slow=True)
                until("%s is in its long tool call on the laptop" % tag, lambda: in_tool(tag, lap), SLOW)
                move("cloud", "phone", True)
                done(tag, vm)
            done(ask("C", n, vm), vm)
            if n % 2:
                tag = ask("M", n, lap, slow=True)
                until("%s is in its long tool call in the Cloud" % tag, lambda: in_tool(tag, vm), SLOW)
                move("local", "chat", True)
                done(tag, lap)
            else:
                move("local", "phone", False)
            done(ask("H", n, lap), lap)
            until("the laptop's folder has every line so far, once each, in order",
                  lambda: read(os.path.join(proj, "log.txt")).split() == expected, 60)

        if REAL:
            typed("Write the secret word to secret.txt with one Bash tool call, then reply with only: done")
            until("after %d moves the agent still knows the first turn" % (2 * ROUNDS),
                  lambda: "PINEAPPLE" in read(os.path.join(proj, "secret.txt")), SLOW)
        until("the store has every event of the laptop",
              lambda: (lambda v: not v["needs_run"] and v["snapshot_seq"] == v["last_seq"])(c.chat(CHAT)), SLOW)

        evs = events()
        assert [e["seq"] for e in evs] == list(range(1, len(evs) + 1)), "event seqs have a gap or a repeat"
        users = [e for e in evs if e["kind"] == "user"]
        for user in users:
            starts = [e for e in evs if e["kind"] == "turn_start" and e["id"] == user["id"]]
            ends = [e for e in evs if e["kind"] == "turn_end" and e["id"] == user["id"]]
            assert len(starts) == 1 and len(ends) == 1, "prompt %r: %d starts, %d ends" % (
                user["text"][:40], len(starts), len(ends))
            assert ends[0].get("ok"), "a turn failed: %s" % ends[0].get("error")
        for tag, holder in expected_by.items():
            assert ended_by(tag) == holder, tag
        assert read(os.path.join(proj, "log.txt")).split() == expected
        view = c.chat(CHAT)
        extra = view["epoch"] - (1 + 2 * ROUNDS)
        slowest = max(m[3] for m in moves)
        log("%d moves, slowest %.1fs; %d prompts, each ran once; %d events; epoch %d%s"
            % (len(moves), slowest, len(users), len(evs), view["epoch"],
               "" if not extra else " (%d holder changes nobody asked for)" % extra))
        assert extra == 0, "the chat changed hands %d times more than it was moved" % extra
        ok = True
        print("\nPINGPONG PASSED")
    finally:
        for p in procs:
            for pid in tree(p.pid):
                try:
                    os.kill(pid, signal.SIGCONT)
                    os.kill(pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
        if ok and not os.environ.get("AUTO_TEST_KEEP"):
            shutil.rmtree(root, ignore_errors=True)
        else:
            print("logs kept in " + root)


if __name__ == "__main__":
    main()
