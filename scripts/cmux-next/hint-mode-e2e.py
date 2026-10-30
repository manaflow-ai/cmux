#!/usr/bin/env python3
"""Live check of hint mode (cx-zjtn.1) on a running tagged cmux-next DEBUG build.

Hint mode drives the window from the keyboard, like Vimium: `hints.show` gives every
clickable control in the window a one or two letter label, and typing a label clicks that
control. Its key is the leader chord Cmd-J F (Vimium's `f`). It is a preview feature
(`labs.previewFeatures`) until it is styled: off, the action is unavailable and Cmd-J F does nothing.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It sets `labs.previewFeatures` with `settings.set` (and
restores it), opens two workspaces (`action.run`), presses keys as a person does (`debug.key`),
reads the labels (`debug.hints`) and the focused workspace (`snapshot.get`). It never launches or
quits the app.

Usage: hint-mode-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []


def rpc(method, params=None, timeout=30):
    """One request on the app's control socket (line JSON)."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
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


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def row(check, expected, observed, ok):
    ROWS.append(ok)
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def topology():
    snap = rpc("snapshot.get") or {}
    return (snap.get("topology") or snap) if isinstance(snap, dict) else {}


def focused_workspace():
    return (topology().get("focus") or {}).get("workspace")


def workspace_name(workspace):
    return next((ws.get("name") for ws in topology().get("workspaces", []) if ws.get("id") == workspace), None)


def hints():
    """`debug.hints`: whether hint mode is on, and its labels."""
    reply = rpc("debug.hints") or {}
    return reply if "error" not in reply else {"active": False, "hints": [], "error": reply.get("error")}


def cmd_j():
    """The leader chord Cmd-J F."""
    print("Cmd-J:", rpc("debug.key", {"key": "j", "modifiers": ["command"]}), flush=True)
    print("F:", rpc("debug.key", {"key": "f", "modifiers": []}), flush=True)


def new_workspace():
    print("new workspace:", json.dumps(rpc("action.run", {"action": "workspace.newAtBottom", "focus": True}))[:200], flush=True)
    time.sleep(1.5)  # test harness: the workspace shows and its terminal takes focus
    return focused_workspace()


def prefix_free(labels):
    return len(set(labels)) == len(labels) and not any(a != b and b.startswith(a) for a in labels for b in labels)


def checks():
    first = new_workspace()
    second = new_workspace()
    name = workspace_name(first)
    print("workspaces:", first, name, "->", second, flush=True)

    # Off by default: the action is unavailable and Cmd-J labels nothing.
    rpc("settings.set", {"path": "labs.previewFeatures", "value": False})
    time.sleep(0.5)  # test harness: the settings snapshot reloads
    ran = rpc("action.run", {"action": "hints.show", "origin": "script"})
    cmd_j()
    time.sleep(0.5)  # test harness: hint mode would have started
    off = hints()
    rpc("debug.key", {"key": "Escape", "modifiers": []})
    row("Hint mode is off without preview features", "hints.show unavailable; Cmd-J F shows no labels",
        f"hints.show {json.dumps(ran.get('error') if isinstance(ran, dict) else ran)[:160]}; debug.hints {json.dumps(off)[:160]}",
        isinstance(ran, dict) and "error" in ran and not off.get("active"))

    # On: Cmd-J F labels the window's controls.
    rpc("settings.set", {"path": "labs.previewFeatures", "value": True})
    time.sleep(0.5)  # test harness: the settings snapshot reloads
    cmd_j()
    shown = wait(lambda: (lambda h: h if h.get("active") and h.get("hints") else None)(hints()), 5) or hints()
    labels = [h.get("label") for h in shown.get("hints") or []]
    row("Cmd-J F labels the window's controls", "at least 5 labels, unique and prefix-free, 1-2 letters",
        f"{len(labels)} labels {labels[:12]}", len(labels) >= 5 and prefix_free(labels) and all(1 <= len(l) <= 2 for l in labels))
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "hint-mode.png")})

    # Typing a sidebar row's label clicks it: the other workspace shows and hint mode ends.
    target = next((h for h in shown.get("hints") or [] if name and name in (h.get("title") or "")), None)
    if target:
        for letter in target["label"]:
            print("type", letter, rpc("debug.key", {"key": letter, "modifiers": []}), flush=True)
    moved = wait(lambda: focused_workspace() == first, 5)
    row("Typing a workspace row's label switches to that workspace", f"focused {first}; hint mode ended",
        f"label {target and target.get('label')} for {name!r}; focused {focused_workspace()}; active {hints().get('active')}",
        bool(target) and bool(moved) and not hints().get("active"))

    # Escape ends hint mode without clicking anything.
    cmd_j()
    started = wait(lambda: hints().get("active"), 5)
    print("Escape:", rpc("debug.key", {"key": "Escape", "modifiers": []}), flush=True)
    ended = wait(lambda: not hints().get("active"), 5)
    row("Escape ends hint mode", "active, then not active; the workspace stays",
        f"started {started}; ended {ended}; focused {focused_workspace()}",
        bool(started) and bool(ended) and focused_workspace() == first)


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    before = (rpc("settings.get", {"path": "labs.previewFeatures"}) or {}).get("value")
    try:
        checks()
    finally:
        if before is None:
            rpc("settings.unset", {"path": "labs.previewFeatures"})
        else:
            rpc("settings.set", {"path": "labs.previewFeatures", "value": before})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
