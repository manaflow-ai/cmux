#!/usr/bin/env python3
"""Live check of hint mode on first-party web pages (cx-zjtn.3) on a running tagged cmux-next DEBUG build.

Hint mode (Cmd-J F, a preview feature) labels the window's native controls from the
accessibility tree, which cannot see into web views. First-party pages (Settings, New Tab, agent
chat) are asked through the link hint script, so their controls get labels too, next to the
native ones. This script opens Settings, starts hint mode, and types the label of the "Swap Cmd-T
and Cmd-N" switch: the setting flips, as a click on the switch does.

The script attaches to an app already running (a capture slot's `capture-host launch`, or a
tagged build) through its debug socket. It sets `labs.previewFeatures` with `settings.set`
(and restores it and the flipped setting), opens Settings with `action.run`, presses keys as a
person does (`debug.key`), reads the labels (`debug.hints`) and the setting (`settings.get`). It
never launches or quits the app.

Usage: web-hints-e2e.py --socket /tmp/cmux-debug-<tag>[-capslot<N>].sock [--out DIR]
Exit status 0 when every check passes.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True, help="the tagged app's debug socket")
parser.add_argument("--out", default="/tmp")
opts = parser.parse_args()
ROWS = []
SWAP = "tabs.swapCmdTAndCmdN"
SETTINGS = ["labs.previewFeatures", SWAP]


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


def action(name):
    return json.dumps(rpc("action.run", {"action": name, "args": {}, "focus": True}))[:160]


def key(name, *modifiers):
    reply = rpc("debug.key", {"key": name, "modifiers": list(modifiers)})
    print("key", "+".join([*modifiers, name]), json.dumps(reply)[:120], flush=True)


def hints():
    reply = rpc("debug.hints") or {}
    return reply if "error" not in reply else {"active": False, "hints": [], "error": reply.get("error")}


def setting(path):
    return (rpc("settings.get", {"path": path}) or {}).get("value")


def labelled_page():
    """Hint mode's labels once the Settings page shows (it paints after it loads)."""
    for attempt in range(1, 11):
        key("j", "command")
        key("f")
        shown = wait(lambda: (lambda h: h if h.get("active") and h.get("hints") else None)(hints()), 5) or hints()
        found = shown.get("hints") or []
        if any(h.get("role") == "web" for h in found):
            print("attempts:", attempt, flush=True)
            return found
        key("escape")
        time.sleep(2)  # test harness: the page paints its first frame
    print("attempts: 10", flush=True)
    return []


def checks():
    print("openSettings:", action("openSettings"), flush=True)
    time.sleep(3)  # test harness: the Settings page loads
    rpc("settings.set", {"path": "labs.previewFeatures", "value": True})
    time.sleep(0.5)  # test harness: the settings snapshot reloads
    before = bool(setting(SWAP))

    found = labelled_page()
    web = [h for h in found if h.get("role") == "web"]
    native = [h for h in found if h.get("role") != "web"]
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "web-hints.png")})
    target = next((h for h in web if "Swap Cmd-T and Cmd-N" in (h.get("title") or "")), None)
    row("Hint mode labels the Settings page's controls next to the native controls",
        "web labels including the Swap Cmd-T and Cmd-N switch; native labels too",
        f"{len(web)} web {[(h.get('label'), h.get('title')) for h in web][:10]}; {len(native)} native",
        len(web) >= 5 and len(native) >= 5 and target is not None)

    # Typing the switch's label clicks it: the setting flips and hint mode ends.
    if target:
        for letter in target["label"]:
            key(letter)
    flipped = wait(lambda: bool(setting(SWAP)) != before, 5)
    row("Typing the switch's label flips its setting", f"{SWAP} {before} -> {not before}; hint mode ended",
        f"label {target and target.get('label')}; {SWAP} now {setting(SWAP)}; active {hints().get('active')}",
        bool(target) and bool(flipped) and not hints().get("active"))


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 60):
        sys.exit("the app does not answer on " + opts.socket)
    before = {path: setting(path) for path in SETTINGS}
    try:
        checks()
    finally:
        for path, value in before.items():
            if value is None:
                rpc("settings.unset", {"path": path})
            else:
                rpc("settings.set", {"path": path, "value": value})


main()
print("\nRESULT", "PASS" if ROWS and all(ROWS) else "FAIL", f"({sum(ROWS)}/{len(ROWS)})")
sys.exit(0 if ROWS and all(ROWS) else 1)
