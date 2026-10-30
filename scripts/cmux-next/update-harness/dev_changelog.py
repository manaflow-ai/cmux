#!/usr/bin/env python3
"""The What's New page of a plain tagged DEV build (cx-7rone): no harness keys, no test feed, so
the page lists the cmux-next nightly notes (UpdaterService.changelogNotes). Launches a copy of the
app, opens the page through the palette action, captures every visible window light and dark,
then ends the copy's sessions and processes by exact pid.

  python3 -I scripts/cmux-next/update-harness/dev_changelog.py --app <cmux DEV tag.app> --tag <tag> --out <dir>

GUI host only (nx-remote --needs gui --host cmux-lawrence-2)."""
import argparse, json, os, shutil, signal, subprocess, sys, tempfile, time

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
    work = tempfile.mkdtemp(prefix="dev-changelog-")
    copy = os.path.join(work, os.path.basename(a.app.rstrip("/")))
    run(["/usr/bin/ditto", a.app, copy])
    sock = f"/tmp/cmux-debug-{a.tag}.sock"
    if os.path.exists(sock):
        if wait_socket(sock, 1):
            raise SystemExit(f"{sock} answers: another app of tag {a.tag} runs; use a tag of your own")
        os.unlink(sock)
    config = os.path.join(work, "cmux.json")
    with open(config, "w") as f:
        json.dump({"appearance": {"theme": "light:Builtin Light,dark:Builtin Dark"}}, f)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "SHELL": "/bin/zsh", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_DEV_BACKEND_MODE": "local", "CMUX_NEXT_CONFIG_FILE": config}
    import plistlib
    with open(os.path.join(copy, "Contents/Info.plist"), "rb") as f:
        info = plistlib.load(f)
    result = {"su_feed_url": info.get("SUFeedURL"), "harness": "CMUXNextUpdateHarness" in info}
    binary = os.path.join(copy, "Contents/MacOS", info["CFBundleExecutable"])
    app = subprocess.Popen([binary], env=env, cwd=work, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(out, "dev-changelog-app.log"), "w"), stderr=subprocess.STDOUT,
                           start_new_session=True)
    try:
        if not wait_socket(sock, 120):
            raise SystemExit(f"the app's control socket {sock} did not open")
        status = rpc(sock, "updates.status").get("result", {})
        result.update(track=status.get("track"), feed_url=status.get("feed_url"), test_feed=status.get("test_feed"))
        # focus: a socket run changes the view only when it asks to (ControlActionRequest.focus).
        result["open"] = rpc(sock, "action.run", {"id": "updates.whatsNew", "focus": True})
        time.sleep(5.0)  # capture timing only: the page fetches the nightly notes index and the newest notes
        windows = rpc(sock, "debug.window_list").get("result", {}).get("windows", [])
        result["windows"] = windows
        for mode in ("light", "dark"):
            rpc(sock, "debug.appearance", {"mode": mode})
            time.sleep(0.5)  # capture timing only: the appearance change repaints the page views
            path = os.path.join(out, f"dev-changelog-{mode}-window.png")
            result[path] = rpc(sock, "debug.window_snapshot", {"kind": "main", "path": path}, timeout=30).get("result")
        log("dev changelog", json.dumps(result)[:3000])
    finally:
        with open(os.path.join(out, "dev-changelog.json"), "w") as f:
            json.dump(result, f, indent=1)
        try:
            os.kill(app.pid, signal.SIGTERM)
            wait_exit(app.pid, 20)
        except ProcessLookupError:
            pass
        TagTeardown(copy, log=log).end()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
