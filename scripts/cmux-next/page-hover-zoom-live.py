#!/usr/bin/env python3
"""Live check: `debug.page {action: "hover"}` on a zoomed Chromium page.

  scripts/cmux-next/page-hover-zoom-live.py --socket PATH

Against a running app (a capture slot's, `build-fleet/capture-host launch`): opens Settings at the
Chief pet and, at each UI scale (`app.uiScale` 1, 1.25, 1.5, 0.85), hovers a different pet choice.
Each hover must answer `hovered: true`, and the page must report that same choice as `:hover`.
DevTools mouse input is in the viewport's CSS pixels and Chromium scales it by the page zoom itself
(`InputHandler::ScaleFactor`), so the verb sends `getBoundingClientRect` coordinates unscaled.
Restores `app.uiScale` at the end. Exits 1 when a check fails.
"""
import argparse, json, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
opts = parser.parse_args()
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def call(method, params=None, timeout=30):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    try:
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        reply = json.loads(buf or b"null") or {}
        return reply.get("result") if reply.get("ok", "result" in reply) else {"error": reply.get("error")}
    finally:
        conn.close()


def page(action=None, **params):
    return call("debug.page", {"page": "cmux.settings", **({"action": action} if action else {}), **params}) or {}


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.25)  # live script: polling the app's state over its socket
    check(False, what)
    return False


call("settings.open", {"setting": "home.chiefPetMascot"})
wait_for(lambda: page().get("painted") is True, "Settings painted")
pets = [e["data"].get("pet") for e in page("query", selector=".chief-pet-choice[data-pet]").get("elements", [])]
pets = [pet for pet in pets if pet and pet != "none"]
check(len(pets) >= 4, f"four pet choices to hover ({pets})")
try:
    for scale, pet in zip((1.0, 1.25, 1.5, 0.85), pets[1:] + pets[:1]):
        call("settings.set", {"path": "app.uiScale", "value": scale})
        time.sleep(1)  # live script: Chromium applying the new zoom level
        reply = page("hover", selector=f".chief-pet-choice[data-pet={pet}]")
        hovered = [e["data"].get("pet") for e in page("query", selector=".chief-pet-choice:hover").get("elements", [])]
        check(reply.get("hovered") is True, f"uiScale {scale}: hover {pet} answers hovered ({reply})")
        check(hovered == [pet], f"uiScale {scale}: the page hovers {pet} ({hovered})")
finally:
    call("settings.unset", {"path": "app.uiScale"})
sys.exit(1 if failures else 0)
