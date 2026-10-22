#!/usr/bin/env python3
"""Drive a running signed cmux NEXT app into the nightly visual smoke's scenes and
capture its window in each (smoke-signed-app-cli.sh --visual OUT runs it).

Release control socket only (no debug.* method), like the canary checks:

  home        `home.show`: the sidebar, the Home Chief chat and its composer.
  transcript  a test-agent session with one answered turn (the canary's
              agent_turn, in the app's own acpmux), opened with
              `agent.openSessionWorkspace`, then shown with `tab.focus`: the
              chat's transcript in its own workspace (not Home, so no Chief
              column beside it). The capture waits until the window shows that
              workspace and its pane's selected tab is the session's, no
              longer pending (openSessionWorkspace itself switches nothing).
  composer    `palette.newAgentChat` on that pane (it docks the new chat at the
              left of the screen), then `toggleSplitZoom` on the chat's pane: a
              new chat's composer, in a workspace that is not Home.

The smoke gives the app a settings file where a chat's Inspector pushes the
chat aside rather than lying over it, so each chat is drawn whole.

Captured in that order (scenes.json lists home, composer, transcript). Each
capture is repeated until the judge's structural checks pass, for at most
--paint-timeout seconds, so a page still loading is not judged too early.

Each capture is the app's largest on-screen window alone (`screencapture -l`,
its CGWindowID from the window list), so the menu bar, the Dock and a system
dialog over the window never reach the judge (visual_check.py).

  drive.py --socket S --pid PID --acpmux-home H --harness ID --cwd DIR --out DIR

Writes OUT/<scene>.png and OUT/drive.json. Exits 1 when a scene could not be
reached; the scenes it did reach are still captured for the artifact.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("canary_checks", os.path.join(HERE, "..", "signed-app-canary-checks.py"))
canary = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(canary)
Client = canary.Client
Failed = canary.Failed
_spec = importlib.util.spec_from_file_location("visual_check", os.path.join(HERE, "visual_check.py"))
judge = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(judge)

# The app's largest normal-layer window that is on screen, by owner pid. Bounds and ids need
# no Screen Recording grant (only window titles do).
WINDOW_JXA = r'''
ObjC.import("CoreGraphics");
function run(argv) {
  var pid = parseInt(argv[0], 10);
  var info = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0))) || [];
  var best = null;
  info.forEach(function (w) {
    if (w.kCGWindowOwnerPID !== pid || w.kCGWindowLayer !== 0) return;
    var b = w.kCGWindowBounds, area = b.Width * b.Height;
    if (!best || area > best.area) best = {id: w.kCGWindowNumber, area: area, bounds: b};
  });
  return JSON.stringify(best);
}
'''


def app_window(pid):
    run = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", WINDOW_JXA, str(pid)],
                         capture_output=True, text=True, timeout=30)
    if run.returncode != 0:
        raise Failed(f"window list: osascript exited {run.returncode}: {run.stderr.strip()[-300:]}")
    return json.loads(run.stdout.strip() or "null")


def capture(pid, path):
    """The app's window alone as a PNG at path; the window's bounds."""
    window = app_window(pid)
    if not window:
        raise Failed(f"pid {pid} has no on-screen window to capture")
    run = subprocess.run(["/usr/sbin/screencapture", "-x", "-o", "-t", "png", "-l", str(window["id"]), path],
                         capture_output=True, text=True, timeout=60)
    if run.returncode != 0 or not os.path.exists(path) or os.path.getsize(path) == 0:
        raise Failed(f"screencapture -l {window['id']} exited {run.returncode}: {run.stderr.strip()[-300:]}")
    return window["bounds"]


def topology(socket_path):
    return canary.snapshot(socket_path).get("topology") or {}


def placed_tabs(topo):
    """(workspace id, pane, tab) for every tab in every pane of the snapshot."""
    for workspace in topo.get("workspaces") or []:
        for screen in workspace.get("screens") or []:
            for pane in screen.get("panes") or []:
                for tab in pane.get("tabs") or []:
                    yield workspace.get("id"), pane, tab


def shown_tab(socket_path, matches):
    """The (workspace, tab) the visible window shows when its tab matches: the window's selected
    workspace holds it, its pane's selected tab is it, and its id is no longer `pending_`."""
    topo = topology(socket_path)
    window = next((w for w in topo.get("windows") or [] if w.get("visible") is True), None) or {}
    for workspace, pane, tab in placed_tabs(topo):
        if (matches(tab) and workspace == window.get("workspace") and pane.get("selected_tab") == tab.get("id")
                and not str(tab.get("id", "")).startswith("pending_")):
            return {"workspace": workspace, "pane": pane.get("id"), "tab": tab.get("id"), "kind": tab.get("kind")}
    return None


def where(socket_path):
    """What the window shows now, for a failure message and drive.json."""
    topo = topology(socket_path)
    window = next((w for w in topo.get("windows") or [] if w.get("visible") is True), None) or {}
    return {"window_workspace": window.get("workspace"), "focus": topo.get("focus"),
            "tabs": [{"workspace": w, "pane": p.get("id"), "selected": p.get("selected_tab") == t.get("id"),
                      "id": t.get("id"), "kind": t.get("kind"), "agent_session": t.get("agent_session")}
                     for w, p, t in placed_tabs(topo)]}


def act(socket_path, action, target=None, **args):
    params = {"action": action, "focus": True}
    if target:
        params["target"] = target
    if args:
        params["args"] = args
    reply = Client(socket_path, timeout=60).call("action.run", params)
    error = reply.get("error")
    if error and error.get("code") == "timeout" and (error.get("data") or {}).get("not_run") is False:
        # It started and is still running past the control-plane deadline (a slow runner's
        # first window save): the scene's own wait and the judge decide whether it got there.
        print(f"note: action.run {action} still in progress at its deadline", file=sys.stderr)
        return {"action": action, "in_progress": error}
    if reply.get("ok") is False or error:
        raise Failed(f"action.run {action}: {json.dumps(error)[:400]}")
    return reply.get("result") or {}


def zoomed_pane(socket_path, pane_id):
    """Whether a screen of the snapshot has pane_id zoomed."""
    for workspace in topology(socket_path).get("workspaces") or []:
        for screen in workspace.get("screens") or []:
            if screen.get("zoomed_pane") == pane_id:
                return True
    return False


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--acpmux-home", required=True)
    parser.add_argument("--harness", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--settle", type=float, default=4, help="seconds a scene gets to paint before its first capture")
    parser.add_argument("--paint-timeout", type=float, default=20,
                        help="seconds a scene's capture may take to pass the judge's structural checks")
    parser.add_argument("--scenes", default=os.path.join(HERE, "scenes.json"))
    args = parser.parse_args(argv)
    os.makedirs(args.out, exist_ok=True)
    log = {"scenes": {}}
    with open(args.scenes) as f:
        config = json.load(f)

    def scene(name, reach):
        """Reach the scene, let it paint, capture it; record the outcome."""
        entry = log["scenes"][name] = {}
        try:
            entry["reached"] = reach()
            time.sleep(args.settle)
            # A web page paints after it loads (a fresh runner's first New Tab is black for a
            # while): capture again until the structural checks pass or paint-timeout runs out.
            # The last capture is what the judge sees, so a scene that never paints still fails.
            path = os.path.join(args.out, f"{name}.png")
            deadline = time.monotonic() + args.paint_timeout
            entry["captures"] = 0
            while True:
                entry["bounds"] = capture(args.pid, path)
                entry["captures"] += 1
                drawn = judge.check_scene(name, config["scenes"][name], config["defaults"], path)
                if drawn["ok"] or time.monotonic() >= deadline:
                    break
                time.sleep(2)
            entry["shows"] = where(args.socket)
            entry["ok"] = True
            print(f"ok: {name} captured {entry['bounds']}")
        except (Failed, OSError, ValueError, subprocess.TimeoutExpired) as error:
            entry.update(ok=False, error=str(error))
            print(f"FAIL: {name}: {error}", file=sys.stderr)

    try:
        window = canary.wait(lambda: canary.visible_window(args.socket), args.timeout)
    except (Failed, OSError, ValueError) as error:
        print(f"FAIL: snapshot.get: {error}", file=sys.stderr)
        window = None
    log["window"] = window
    if not window:
        print(f"FAIL: no visible window within {args.timeout:.0f}s", file=sys.stderr)
    else:
        def home():
            run = act(args.socket, "home.show")
            log["home_workspace"] = (canary.visible_window(args.socket) or {}).get("workspace")
            return run
        scene("home", home)

        def transcript():
            session = canary.agent_turn(args.acpmux_home, args.harness, args.cwd, args.timeout)
            run = act(args.socket, "agent.openSessionWorkspace", session=session)
            workspace = next((c for c in run.get("created") or [] if str(c).startswith("ws_")), None)

            def placed():
                return next((t for w, _, t in placed_tabs(topology(args.socket))
                             if t.get("agent_session") == session and not str(t.get("id", "")).startswith("pending_")
                             and (workspace is None or w == workspace)), None)
            tab = canary.wait(placed, 30)
            if not tab:
                raise Failed(f"agent.openSessionWorkspace ran but no settled tab shows session {session}: "
                             f"{json.dumps(where(args.socket))[:600]}")
            # openSessionWorkspace selects the tab in its pane but switches no workspace: show it.
            focus = act(args.socket, "tab.focus", target=f"tab:{tab['id']}")
            shown = canary.wait(lambda: shown_tab(args.socket, lambda t: t.get("id") == tab["id"]), 20)
            if not shown or shown["workspace"] == log.get("home_workspace"):
                raise Failed(f"the window does not show session {session}'s tab {tab['id']} in its own workspace: "
                             f"{json.dumps(where(args.socket))[:600]}")
            return {"session": session, "run": run, "focus": focus, **shown}
        scene("transcript", transcript)

        def new_chat():
            before = set(canary.tabs(canary.snapshot(args.socket)))
            pane = log["scenes"]["transcript"]["reached"]["pane"]
            run = act(args.socket, "palette.newAgentChat", target=f"pane:{pane}")
            shown = canary.wait(lambda: shown_tab(args.socket, lambda t: t.get("id") not in before
                                                  and t.get("kind") == "conversation"), 20)
            if not shown:
                raise Failed(f"palette.newAgentChat ran but the window shows no new settled chat tab: "
                             f"{json.dumps(where(args.socket))[:600]}")
            if shown["workspace"] == log.get("home_workspace"):
                raise Failed(f"palette.newAgentChat opened its chat in Home ({shown['workspace']}), beside the Chief column")
            # A new chat in a workspace docks at the left of the screen at half its width, where
            # the open Inspector lies over it; zoomed, the chat has the workspace's width and its
            # Inspector pushes it aside (the smoke's settings), so the chat is drawn whole.
            zoom = act(args.socket, "toggleSplitZoom", target=f"pane:{shown['pane']}")
            if not canary.wait(lambda: zoomed_pane(args.socket, shown["pane"]), 20):
                raise Failed(f"toggleSplitZoom ran but pane {shown['pane']} is not zoomed: {json.dumps(where(args.socket))[:600]}")
            return {"run": run, "zoom": zoom, **shown}
        if log["scenes"].get("transcript", {}).get("ok"):
            scene("composer", new_chat)
        else:
            log["scenes"]["composer"] = {"ok": False, "error": "needs the transcript scene's workspace"}
            print("FAIL: composer: needs the transcript scene's workspace", file=sys.stderr)

    ok = bool(window) and all(s.get("ok") for s in log["scenes"].values())
    if not ok:
        # The whole display, for what stood in the way (no window, a dialog, a crash).
        subprocess.run(["/usr/sbin/screencapture", "-x", "-t", "png", os.path.join(args.out, "screen.png")],
                       capture_output=True, timeout=60)
    with open(os.path.join(args.out, "drive.json"), "w") as f:
        json.dump(log, f, indent=1, default=str)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
