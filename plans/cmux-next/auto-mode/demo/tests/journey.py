#!/usr/bin/env python3
"""The whole journey with real processes, and the scripted agent or real Claude Code.

A store, a Cloud machine and a laptop run as three processes with their own homes. The laptop
is frozen in the middle of a tool call (a closed lid), the machine finishes the turn, a third
device sends a message, the laptop wakes, and the chat comes home with everything the Cloud did.

  python3 tests/journey.py                                   scripted agent, about 20 s
  AUTO_TEST_AGENT=claude python3 tests/journey.py            real Claude Code, about 3 min
  AUTO_TEST_AGENT=claude AUTO_TEST_MODEL=claude-haiku-5-5 python3 tests/journey.py

The real run uses this shell's Claude Code sign-in and scratch session folders, never yours.
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
PORT = int(os.environ.get("AUTO_TEST_PORT", "17717"))
REAL = os.environ.get("AUTO_TEST_AGENT") == "claude"
# A store and machine that run already (a Cloud VM): only the laptop and the phone start here.
REMOTE = os.environ.get("AUTO_TEST_STORE_URL")
CHAT = "j-" + os.urandom(3).hex() if REMOTE else "c1"
MODEL = os.environ.get("AUTO_TEST_MODEL")
LEASE = 12.0 if REAL else 4.0
if REMOTE:
    REAL = True
SLOW = 240 if REAL else 40
if REAL:
    FIRST = ("Do exactly these three steps, each as its own separate Bash tool call, in this order: "
             "1) echo started > step1.txt  2) python3 -c 'import time; time.sleep(30)'  3) echo finished > step2.txt . "
             "The secret word of this chat is PINEAPPLE; remember it. "
             "When all three are done, reply with one short line.")
    PHONE = ("Append the secret word I gave you earlier to a new file notes.txt, and write the output "
             "of `uname -s` to where.txt, then reply: done.")
    LAST = "Write the secret word and the word home on one line to home.txt, then reply: done."
else:
    FIRST, PHONE, LAST = "do the long job slow:14", "note from the phone", "one more on the laptop"
T0 = time.time()


def log(text):
    print("%6.1fs  %s" % (time.time() - T0, text), flush=True)


def until(what, check, timeout=60):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            last = check()
        except (Offline, Refused, OSError):
            last = None
        if last:
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
    root = tempfile.mkdtemp(prefix="auto-journey-")
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
                    AUTO_DEVICE="device:laptop" if role == "laptop" else "device:" + role)

    procs = []

    def spawn(role, args, **kw):
        out = open(os.path.join(root, role + ".log"), "a")
        p = subprocess.Popen(AUTO + args, env=env(role), stdout=out, stderr=subprocess.STDOUT, **kw)
        procs.append(p)
        return p

    ok = False
    try:
        c = Client(url, token)
        work = os.path.join(root, "cloud", "work")
        if REMOTE:
            machine = until("the store answers and has a machine", lambda: c.status()["machine"])["name"]
        else:
            machine = "demo-vm"
            spawn("store", ["serve", "--host", "127.0.0.1", "--port", str(PORT), "--token", "t",
                            "--lease", str(LEASE), "--data", os.path.join(root, "store")])
            until("the store answers", lambda: c.status())
            spawn("cloud", ["machine", "--name", machine, "--work", work] + model)
            until("the machine asked for work", lambda: c.status()["machine"])
        vm = "vm:" + machine

        def ended():
            return [e for e in c.events(CHAT, 0)["events"] if e["kind"] == "turn_end"]

        laptop = spawn("laptop", ["chat", CHAT, "-C", proj, "-m", FIRST] + model, stdin=subprocess.PIPE)
        log("chat %s" % CHAT)
        until("the laptop holds the chat and the store has a copy",
              lambda: (lambda v: v["holder"] == "device:laptop" and v["snapshot"] and v["needs_run"])(c.chat(CHAT)))

        def in_the_tool():
            tools = [e for e in c.events(CHAT, 0)["events"] if e["kind"] == "tool" and "sleep" in e["label"]]
            return bool(tools) and c.chat(CHAT)["snapshot_seq"] >= tools[-1]["seq"] \
                and "started" in read(os.path.join(proj, "step1.txt"))
        until("the agent is in its long tool call on the laptop, and the store's copy has it", in_the_tool, SLOW)
        time.sleep(1.5)

        log("-- the lid closes: the laptop and its agent are frozen in the middle of the tool --")
        frozen = tree(laptop.pid)
        for pid in frozen:
            os.kill(pid, signal.SIGSTOP)
        until("the store gave the chat to the machine", lambda: c.chat(CHAT)["holder"] == vm, 60)
        vm_proj = os.path.join(work, CHAT)
        until("the machine finished the cut turn", lambda: [e for e in ended() if e["by"] == vm], SLOW)
        if not REMOTE:
            assert "finished" in read(os.path.join(vm_proj, "step2.txt")), "step2.txt was not written"
            assert "started" in read(os.path.join(vm_proj, "step1.txt")), "the folder did not travel"
        if not REAL:
            assert "finished on cloud" in read(os.path.join(vm_proj, "step2.txt"))
            assert "1 earlier" in read(os.path.join(vm_proj, "resumed.txt")), "the session did not travel"
        assert not os.path.exists(os.path.join(proj, "step2.txt")), "the laptop's frozen agent ran on"

        log("-- a phone sends a message while the laptop is away --")
        phone = subprocess.run(AUTO + ["send", CHAT, PHONE], env=env("phone"),
                               capture_output=True, text=True)
        log("phone: " + phone.stdout.strip())
        until("the machine ran the phone's message", lambda: len([e for e in ended() if e["by"] == vm]) >= 2, SLOW)
        if not REMOTE:
            assert ("PINEAPPLE" if REAL else "cloud: note from the phone") in read(os.path.join(vm_proj, "notes.txt"))
        until("the machine is idle with its copy stored",
              lambda: (lambda v: not v["needs_run"] and v["snapshot_seq"] == v["last_seq"])(c.chat(CHAT)), SLOW)
        assert c.chat(CHAT)["holder"] == vm

        log("-- the lid opens --")
        for pid in frozen:
            try:
                os.kill(pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
        until("the chat is back on the laptop", lambda: c.chat(CHAT)["holder"] == "device:laptop", 40)
        until("the laptop has what the Cloud did",
              lambda: "finished" in read(os.path.join(proj, "step2.txt"))
              and ("PINEAPPLE" if REAL else "note from the phone") in read(os.path.join(proj, "notes.txt"))
              and (not REMOTE or read(os.path.join(proj, "where.txt")).strip()), 60)
        if REMOTE:
            where = read(os.path.join(proj, "where.txt")).strip()
            log("where.txt, written in the Cloud and now on the laptop: %s" % where)
            assert "Linux" in where, where
        until("the laptop stored a copy of its own (Auto can be turned off again)",
              lambda: c.chat(CHAT)["snapshot_seq"] == c.chat(CHAT)["last_seq"], 30)

        log("-- the person types on the laptop again --")
        laptop.stdin.write(LAST.encode() + b"\n")
        laptop.stdin.flush()
        until("the next turn ran on the laptop with the whole history",
              lambda: "PINEAPPLE" in read(os.path.join(proj, "home.txt")) if REAL
              else "laptop: one more on the laptop" in read(os.path.join(proj, "notes.txt")), SLOW)
        until("the store has the laptop's turn",
              lambda: [e for e in c.events(CHAT, 0)["events"] if e["kind"] == "turn_end"][-1]["by"] == "device:laptop", SLOW)
        events = c.events(CHAT, 0)["events"]
        said = [e["text"] for e in events if e["kind"] == "text"]
        if not REAL:
            assert any("Noted on laptop. I remember 3 earlier messages" in t for t in said), said[-3:]
        by = [e["by"] for e in events if e["kind"] == "turn_end"]
        assert by == [vm, vm, "device:laptop"], by
        epochs = c.chat(CHAT)["epoch"]
        log("turns ended on: %s; epoch %d; %d events" % (by, epochs, len(events)))
        ok = True
        print("\nJOURNEY PASSED")
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
