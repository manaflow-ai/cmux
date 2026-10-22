#!/usr/bin/env python3
"""Before/after recording of a workspace switch by a sidebar click (Lawrence 2026-10-21: "on mousedown, instantly
switch").

Launches a Debug `cmux DEV <tag>.app` as perf-gate.py does (no activation, automation socket, scratch config), fills
it to --workspaces workspaces (each with a terminal that prints its own name in large block letters, so a frame shows
which one is shown), then records the window (debug.window_record, one JPEG per display frame) while it clicks
--clicks sidebar rows as a person does: mouse-down, the button held --hold-ms, mouse-up. Writes the frames,
`frames.json` and `clicks.json` (host time of each down and up, and the workspace shown right after each down) to
--out. The press-to-shown gap per click is in `clicks.json`; the video is assembled afterwards (ffmpeg).

Usage: workspace-switch-record.py --app "<dir>/cmux DEV <tag>.app" --out DIR [--workspaces 150] [--clicks 4]
"""
import argparse, importlib.util, json, os, sys, time

# The perf gate's App (launch, socket, teardown) from this checkout's scripts/cmux-next, so the script also runs from
# a copy against an older tree (the "before" build).
HERE = os.environ.get("PERF_GATE_DIR") or os.path.join(os.getcwd(), "scripts/cmux-next")
sys.path.insert(0, HERE)
_spec = importlib.util.spec_from_file_location("perf_gate", os.path.join(HERE, "perf-gate.py"))
perf_gate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf_gate)


def sidebar_row(app, workspace):
    """The window-local center of `workspace`'s drawn sidebar row, else None."""
    for window in (app.rpc("debug.sidebar_rows") or {}).get("windows") or []:
        for row in window.get("rows") or []:
            frame = row.get("window_frame") or {}
            if workspace in str(row.get("key", "")) and row.get("in_list") and frame.get("height", 0) > 0 and frame.get("y", -1) >= 0:
                return frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2
    return None


def fill_workspaces(app, want):
    """Grows the window to `want` workspaces (a split terminal each, every 5th a Chromium tab, every 7th an agent chat)."""
    for n in range(max(0, want - len(app.workspace_ids()))):
        app.rpc("action.run", {"action": "newTab", "args": {}, "focus": True, "origin": "script"}, timeout=120)
        app.action("splitRight")
        if (n + 1) % 5 == 0:
            app.action("openBrowser.chromium", {"url": "about:blank"})
        if (n + 1) % 7 == 0:
            app.action("palette.newAgentChat")
    return perf_gate.wait(lambda: (lambda w: w if len(w) >= want else None)(app.workspace_ids()), 300) or app.workspace_ids()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/workspace-switch-record")
    parser.add_argument("--workspaces", type=int, default=150)
    parser.add_argument("--clicks", type=int, default=4)
    parser.add_argument("--hold-ms", type=int, default=150, help="how long the button stays down (a person's click: 80-200 ms)")
    opts = parser.parse_args()
    os.makedirs(opts.out, exist_ok=True)
    app = perf_gate.App(os.path.abspath(opts.app), opts.out)
    try:
        app.launch()
        ids = fill_workspaces(app, opts.workspaces)
        targets = ids[-opts.clicks:]
        for target in targets:
            app.action("goToWorkspace", {"workspace": target})
            # The shown workspace's focused terminal (goToWorkspace above made it current).
            app.cli("--json", "terminal", "current", "write", "--text", f"clear; printf '\\n\\n   >>> WORKSPACE {target[-4:].upper()} <<<\\n\\n'\r")
        app.action("goToWorkspace", {"workspace": ids[-opts.clicks - 1]})
        time.sleep(1.0)  # recording script: the last switch's frame settles before the recording starts
        frames_dir = os.path.join(opts.out, "frames")
        seconds = min(12, 0.6 + opts.clicks * (opts.hold_ms / 1000 + 0.9))
        app.rpc("debug.window_record", {"dir": frames_dir, "seconds": seconds})
        start = time.monotonic()
        clicks = []
        time.sleep(0.4)  # recording script: a still lead-in before the first click
        for target in targets:
            point = sidebar_row(app, target)
            if not point:
                clicks.append({"to": target, "error": "row not pressable"})
                continue
            down = time.monotonic() - start
            app.rpc("debug.mouse", {"action": "down", "x": point[0], "y": point[1]})
            shown_after_down = app.shown_workspace()
            time.sleep(opts.hold_ms / 1000)  # recording script: the button held as a person holds it
            up = time.monotonic() - start
            app.rpc("debug.mouse", {"action": "up", "x": point[0], "y": point[1]})
            clicks.append({"to": target, "down_s": round(down, 3), "up_s": round(up, 3),
                           "shown_after_down": shown_after_down, "switched_on_down": shown_after_down == target})
            time.sleep(0.75)  # recording script: the new workspace stays on screen a moment
        time.sleep(max(0, seconds - (time.monotonic() - start)) + 0.6)  # recording script: the recording stops by itself
        with open(os.path.join(opts.out, "clicks.json"), "w") as f:
            json.dump({"tag": app.tag, "workspaces": len(ids), "hold_ms": opts.hold_ms, "clicks": clicks}, f, indent=1)
        print(json.dumps(clicks, indent=1), flush=True)
    finally:
        app.stop()


if __name__ == "__main__":
    main()
