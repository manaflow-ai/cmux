#!/usr/bin/env python3
"""cx-warpr: a What's New tab keeps its title and page across Reopen Closed and a relaunch.
Launches a copy of a tagged DEV app, opens What's New (updates.whatsNew), closes the tab
(closeTab), reopens it (reopenClosedBrowserPanel, the Cmd-Shift-T action), quits (SIGTERM, the
sessions stay), relaunches, captures the restored tab, closes and reopens it once more. Each step
writes a main-window capture; the strip shows the tab titles. At the end the copy's sessions and
processes end by exact pid.

  python3 -I scripts/cmux-next/update-harness/reopen_page_title.py --app <cmux DEV tag.app> --tag <tag> --out <dir>

GUI host only (nx-remote --needs gui --host cmux-lawrence-2)."""
import argparse, json, os, plistlib, shutil, signal, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from run import log, rpc, run, wait_exit, wait_socket  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True)
    ap.add_argument("--tag", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    out = os.path.abspath(a.out)
    os.makedirs(out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="reopen-page-")
    copy = os.path.join(work, os.path.basename(a.app.rstrip("/")))
    run(["/usr/bin/ditto", a.app, copy])
    with open(os.path.join(copy, "Contents/Info.plist"), "rb") as f:
        info = plistlib.load(f)
    binary = os.path.join(copy, "Contents/MacOS", info["CFBundleExecutable"])
    sock = f"/tmp/cmux-debug-{a.tag}.sock"
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_DEV_BACKEND_MODE": "local"}
    result = {"steps": []}
    app = None

    def launch(name):
        if os.path.exists(sock):
            if wait_socket(sock, 1):
                raise SystemExit(f"{sock} answers: another app of tag {a.tag} runs; use a tag of your own")
            os.unlink(sock)
        proc = subprocess.Popen([binary], env=env, cwd=work, stdin=subprocess.DEVNULL,
                                stdout=open(os.path.join(out, f"reopen-{name}.log"), "w"), stderr=subprocess.STDOUT,
                                start_new_session=True)
        if not wait_socket(sock, 120):
            raise SystemExit(f"{name}: the control socket {sock} did not open")
        return proc

    def step(name, action=None, settle=2.0):
        # focus: a socket run changes the view only when it asks to (ControlActionRequest.focus).
        reply = rpc(sock, "action.run", {"id": action, "focus": True}) if action else None
        if action and not (reply or {}).get("ok"):
            raise SystemExit(f"{name}: {action} did not run: {json.dumps(reply)[:300]}")
        time.sleep(settle)  # capture timing only: the tab strip and the page view draw
        path = os.path.join(out, f"reopen-{name}.png")
        shot = rpc(sock, "debug.window_snapshot", {"kind": "main", "path": path}, timeout=30).get("result")
        result["steps"].append({"name": name, "action": action, "reply": reply, "shot": shot})
        log(name, json.dumps(reply)[:300])

    try:
        app = launch("first")
        step("1-open", "updates.whatsNew", settle=4.0)
        step("2-closed", "closeTab")
        step("3-reopened", "reopenClosedBrowserPanel", settle=4.0)
        os.kill(app.pid, signal.SIGTERM)
        result["first_exit"] = wait_exit(app.pid, 30)
        if result["first_exit"] is None:
            raise SystemExit("the first instance did not quit within 30 s")
        app = launch("relaunch")
        step("4-relaunched", None, settle=5.0)
        step("5-selected", "updates.whatsNew", settle=3.0)
        step("6-closed", "closeTab")
        step("7-reopened", "reopenClosedBrowserPanel", settle=4.0)
    finally:
        with open(os.path.join(out, "reopen.json"), "w") as f:
            json.dump(result, f, indent=1)
        if app is not None:
            try:
                os.kill(app.pid, signal.SIGTERM)
                wait_exit(app.pid, 20)
            except ProcessLookupError:
                pass
        TagTeardown(copy, log=log).end()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
