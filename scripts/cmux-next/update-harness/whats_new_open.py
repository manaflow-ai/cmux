#!/usr/bin/env python3
"""cx-yuugh / cx-cmge7: What's New opens where the person can see it.
Launches a copy of a tagged DEV app and shows the Updated card (debug.updater updated). Then it runs
updates.whatsNew (focus) and the Updated card's "See What's New" (debug.update_surfaces
open-whats-new, the card button's own call): on the Home page over workspace-1, in a New Tab
workspace (newTab) and in an agent workspace (newTab, then palette.newAgentChat), where the page
must show as the selected tab; then, after every visible workspace is closed, on the Home page that
stands for the hidden home workspace (cx-cmge7), where it must show as the window's top page. Each
step writes a main-window capture and what the window shows (debug.update_surfaces state: topPage,
selectedPage, holdsVisiblePageTab). Exit 1 when a step does not show what it must. At the end the
copy's sessions and processes end by exact pid.

  python3 -I scripts/cmux-next/update-harness/whats_new_open.py --app <cmux DEV tag.app> --tag <tag> --out <dir>

Use a tag with no saved state (a new tag per run): the Home steps expect Home to stand for the
home workspace, as on a fresh launch; a restored window may show Home over another workspace.
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
    work = tempfile.mkdtemp(prefix="whats-new-open-")
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

    def step(name, method=None, params=None, settle=2.0, expect=None):
        reply = rpc(sock, method, params or {}) if method else None
        if method and not (reply or {}).get("ok"):
            log(name, "FAILED", json.dumps(reply)[:300])
        time.sleep(settle)  # capture timing only: the strip, the page view and the notes draw
        path = os.path.join(out, f"{name}.png")
        shot = rpc(sock, "debug.window_snapshot", {"kind": "main", "path": path}, timeout=30).get("result")
        surfaces = rpc(sock, "debug.update_surfaces", {"action": "state"}).get("result") or {}
        shown = {k: surfaces.get(k) for k in ("topPage", "selectedPage", "holdsVisiblePageTab")}
        ok = bool((reply or {}).get("ok", True)) and all(shown.get(k) == v for k, v in (expect or {}).items())
        result["steps"].append({"name": name, "method": method, "params": params, "reply": reply, "shot": shot,
                                "update_surfaces": surfaces, "expect": expect, "shown": shown, "ok": ok})
        log(name, "ok" if ok else "FAIL", json.dumps(shown), json.dumps(reply)[:300])

    def action(name, action_id, settle=2.0, expect=None, args=None):
        # focus: a socket run changes the view only when it asks to (ControlActionRequest.focus).
        step(name, "action.run", {"id": action_id, "focus": True, "args": args or {}}, settle, expect)

    def button(name, expect):
        # The Updated card's "See What's New": the call its page makes (UpdateSurfaceIsland openChangelog).
        step(name, "debug.update_surfaces", {"action": "open-whats-new"}, settle=4.0, expect=expect)

    on_top = {"topPage": "page:changelog"}
    as_tab = {"topPage": "", "selectedPage": "changelog"}

    try:
        if os.path.exists(sock):
            if wait_socket(sock, 1):
                raise SystemExit(f"{sock} answers: another app of tag {a.tag} runs; use a tag of your own")
            os.unlink(sock)
        app = subprocess.Popen([binary], env=env, cwd=work, stdin=subprocess.DEVNULL,
                               stdout=open(os.path.join(out, "app.log"), "w"), stderr=subprocess.STDOUT,
                               start_new_session=True)
        if not wait_socket(sock, 120):
            raise SystemExit(f"the control socket {sock} did not open")
        # The socket answers before the app registers its debug methods: wait for debug.updater.
        deadline = time.monotonic() + 60
        while (rpc(sock, "debug.updater", {"action": "updated", "previous": "0.0.1"}).get("error") or {}).get("code") \
                == "method_not_found" and time.monotonic() < deadline:
            time.sleep(1.0)  # bounded wait for the debug methods at launch; no lifecycle signal on the socket
        step("0-start", "debug.updater", {"action": "updated", "previous": "0.0.1"}, settle=5.0)
        # Home over workspace-1 (a fresh launch): the page opens as a tab of workspace-1.
        action("1-home", "home.show", expect={"topPage": "home", "holdsVisiblePageTab": True})
        action("2-home-action", "updates.whatsNew", settle=4.0, expect=as_tab)
        action("3-home-again", "home.show", expect={"topPage": "home"})
        button("4-home-button", as_tab)
        action("5-newtab-ws", "newTab", settle=3.0, expect={"topPage": ""})
        action("6-newtab-action", "updates.whatsNew", settle=4.0, expect=as_tab)
        action("7-newtab-closed", "closeTab")
        button("8-newtab-button", as_tab)
        action("9-agent-ws", "newTab", settle=3.0, expect={"topPage": ""})
        action("10-agent-chat", "palette.newAgentChat", settle=4.0)
        action("11-agent-action", "updates.whatsNew", settle=4.0, expect=as_tab)
        action("12-agent-closed", "closeTab")
        button("13-agent-button", as_tab)
        # Close every visible workspace: Home then stands for the hidden home workspace (cx-cmge7).
        for n in range(5):
            action(f"14-close-{n}", "closeWorkspace", settle=3.0, args={"confirm": True})
            if result["steps"][-1]["shown"].get("holdsVisiblePageTab") is False:
                break
        action("15-home-hidden", "home.show", expect={"topPage": "home", "holdsVisiblePageTab": False})
        action("16-hidden-action", "updates.whatsNew", settle=4.0, expect=on_top)
        action("17-hidden-again", "updates.whatsNew", settle=2.0, expect=on_top)
        action("18-hidden-home", "home.show", expect={"topPage": "home"})
        button("19-hidden-button", on_top)
        result["ok"] = all(s["ok"] for s in result["steps"])
    finally:
        with open(os.path.join(out, "whats-new-open.json"), "w") as f:
            json.dump(result, f, indent=1)
        if app is not None:
            try:
                os.kill(app.pid, signal.SIGTERM)
                wait_exit(app.pid, 20)
            except ProcessLookupError:
                pass
        TagTeardown(copy, log=log).end()
        shutil.rmtree(work, ignore_errors=True)
    if not result.get("ok"):
        raise SystemExit("a step did not show What's New where it must: " + ", ".join(
            s["name"] for s in result["steps"] if not s["ok"]))


if __name__ == "__main__":
    main()
