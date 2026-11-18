#!/usr/bin/env python3
"""One fresh launch of a cmux NEXT app, as bench_memory.py's idle launch makes it (a scratch HOME, one
terminal workspace, no chat), then Home's first open and the first Chief reply after it.

  1. At rest (--settle seconds after the control socket answers): whether the Chief's brain host runs
     (an `optchat-chief host` process of the bundle) and which Home view asked for it (the app's
     `chief start asked from <caller> on_screen <bool>` log lines, HomeService.homeDidOpen).
  2. Home's first open: `home.show`, until the Home composer answers `debug.home.drive geometry`.
  3. The first reply: one message sent through the composer (`debug.home.drive` focus, type, send),
     then `debug.home` read every 0.1 s until the Chief answers: the Chief typing, its first live or
     draft text, and its posted reply (a message of agent_mux after the sent one).

The app is ended with the bundle's processes (bench_memory.end_bundle) and its scratch removed.
Prints CHIEF-START lines and writes --out (JSON). Exit 0 when Home opened; a Chief that never
answered within --deadline is reported (reply_ms null), not a failure, since a host with no
model login has no reply to give.

  chief-start-probe.py --app BUNDLE --out result.json [--settle 20] [--deadline 180]
"""
import argparse, glob, json, os, shutil, sqlite3, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory  # noqa: E402  (the same launch, process table and teardown as the memory bench)

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--settle", type=float, default=20)
parser.add_argument("--deadline", type=float, default=180, help="seconds for the Chief's reply after the send")
opts = parser.parse_args()
bundle = os.path.realpath(opts.app)
MUX = "agent_mux"


def ms(since):
    return round((time.monotonic() - since) * 1000)


def wait(predicate, seconds, step=0.1):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def brain_hosts():
    return [pid for pid, _, cmd in bench_memory.process_table()
            if bench_memory.in_bundle(cmd, bundle) and "optchat-chief" in cmd and " host" in cmd]


def asked_lines(pid):
    """The app's `chief start asked` log lines (HomeService.homeDidOpen, .notice)."""
    try:
        out = subprocess.run(["log", "show", "--style", "compact", "--last", "5m", "--predicate",
                              f'processIdentifier == {pid} AND eventMessage CONTAINS "chief start asked"'],
                             capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.TimeoutExpired) as error:
        return [f"log show failed: {error}"]
    return [line.split("chief start asked", 1)[1].strip() for line in out.splitlines() if "chief start asked" in line]


def brain_logged(home, text):
    for path in glob.glob(os.path.join(home, ".cmux", "chief", "**", "optchat", "memory.sqlite3"), recursive=True):
        try:
            db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=1)
            try:
                if any(text in (body or "") for (body,) in db.execute("SELECT text FROM messages WHERE kind = 'user'")):
                    return True
            finally:
                db.close()
        except sqlite3.Error:
            continue
    return False


def chief_rows(app):
    home = app.call("debug.home", timeout=10) or {}
    return [c for c in home.get("conversations", []) if MUX in c.get("participants", [])]


def main():
    result = {"app": bundle}
    started = time.monotonic()
    # The Chief's model route of this step's environment, when it has one (values pass through, never printed).
    model = {name: os.environ[name] for name in ("MUX_HARNESS", "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN",
                                                 "ANTHROPIC_API_KEY", "SUBROUTER_URL") if os.environ.get(name)}
    result["model_env"] = sorted(model)
    pid, socket_path, scratch = bench_memory.launch(bundle, {}, model)
    home = os.path.join(scratch, "home")
    app = bench_memory.App(bundle, socket_path)
    try:
        result["socket_ms"] = ms(started)
        time.sleep(opts.settle)  # test harness: the same rest as bench_memory's idle-launch sample
        result["brain_at_rest"] = bool(brain_hosts())
        result["asked_at_rest"] = asked_lines(pid)
        print(f"CHIEF-START rest brain_running {result['brain_at_rest']} asked {json.dumps(result['asked_at_rest'])}", flush=True)

        opened = time.monotonic()
        app.call("action.run", {"id": "home.show"}, timeout=30)
        if not wait(lambda: (app.call("debug.home.drive", {"action": "geometry"}, timeout=10) or {}).get("ok"), 120):
            result["error"] = "no Home composer within 120 s"
            print(f"CHIEF-START error {result['error']}", flush=True)
            return 1
        result["home_open_ms"] = ms(opened)
        brain = wait(brain_hosts, 30, step=0.2)
        result["brain_after_open_ms"] = ms(opened) if brain else None
        result["asked_after_open"] = asked_lines(pid)

        text = f"chief start probe {int(time.time())}: reply with only the word ok."
        sent = time.monotonic()
        drive = {}
        for action, extra in (("focus", {}), ("type", {"text": text}), ("send", {})):
            drive = app.call("debug.home.drive", {"action": action, **extra}, timeout=30) or {}
            if not drive.get("ok"):
                break
        result["send"] = drive
        marks = {"brain_logged_ms": None, "typing_ms": None, "first_text_ms": None, "reply_ms": None}
        end = time.monotonic() + opts.deadline
        while time.monotonic() < end and marks["reply_ms"] is None:
            if marks["brain_logged_ms"] is None and brain_logged(home, text):
                marks["brain_logged_ms"] = ms(sent)
            for row in chief_rows(app):
                tail = row.get("shown_tail") or []
                at = next((k for k, item in enumerate(tail) if text in (item.get("text") or "")), None)
                if at is None:
                    continue
                if marks["typing_ms"] is None and MUX in (row.get("typing") or []):
                    marks["typing_ms"] = ms(sent)
                running = (row.get("live") or {}).get("text") or (row.get("draft") or {}).get("text")
                if marks["first_text_ms"] is None and running:
                    marks["first_text_ms"] = ms(sent)
                if any(item.get("author") == MUX and item.get("text") for item in tail[at + 1:]):
                    marks["reply_ms"] = ms(sent)
                    marks["first_text_ms"] = marks["first_text_ms"] or marks["reply_ms"]
            time.sleep(0.1)  # test harness: the reply read's step
        result.update(marks)
        print(f"CHIEF-START home_open_ms {result['home_open_ms']} brain_after_open_ms {result['brain_after_open_ms']} "
              + " ".join(f"{k} {v}" for k, v in marks.items()), flush=True)
        return 0
    finally:
        bench_memory.end_bundle(bundle)
        shutil.rmtree(scratch, ignore_errors=True)
        with open(opts.out, "w") as handle:
            json.dump(result, handle, indent=1)


if __name__ == "__main__":
    sys.exit(main())
