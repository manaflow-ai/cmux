#!/usr/bin/env python3
"""Live check: `debug.page {action: "hover"}` on a zoomed Chromium page.

  scripts/cmux-next/page-hover-zoom-live.py --socket PATH

Against a running app (a capture slot's, `build-fleet/capture-host launch`): opens Settings at the
Chief pet in Chromium and, at each UI scale (`app.uiScale` 0.85, 1.25, 1.5, 1), waits until the
page's `devicePixelRatio` shows that zoom, then hovers a different pet choice, taking the ones
farthest from the viewport origin. Each hover must answer `hovered: true` natively, the page must
report that same choice as `:hover`, and at a scale other than 1 a point scaled wrongly (by the zoom
or by its inverse) would have moved off the card on one axis, so it would have missed.
DevTools mouse input is in the viewport's CSS pixels and Chromium scales it by the page zoom itself
(`InputHandler::ScaleFactor`), so the verb sends `getBoundingClientRect` coordinates unscaled.
Puts `app.uiScale` back as it found it. Exits 1 when a check fails.
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


before = call("settings.get", {"path": "app.uiScale"}) or {"error": None}
if "error" in before:
    check(False, f"read app.uiScale before changing it ({before})")
    sys.exit(1)
call("settings.open", {"setting": "home.chiefPetMascot"})
wait_for(lambda: page().get("painted") is True, "Settings painted")
check(page().get("engine") == "chromium", "Settings shows in Chromium")
pets = []


def read_pets():
    found = [e["data"].get("pet") for e in page("query", selector=".chief-pet-choice[data-pet]").get("elements", [])]
    pets[:] = [pet for pet in found if pet and pet != "none"]
    return len(pets) >= 4


wait_for(read_pets, "four pet choices to hover")
try:
    reply = call("settings.set", {"path": "app.uiScale", "value": 1.0})
    check("error" not in (reply or {"error": None}), f"uiScale 1.0: set ({reply})")
    # The display's scale is the ratio over the zoom (1 or 2); a zoom of 1 shows it whole.
    wait_for(lambda: float(page().get("device_pixel_ratio") or 0) in (1.0, 2.0), "zoom 1 reached the page")
    base = float(page().get("device_pixel_ratio") or 1)
    # The smallest change in zoom gets the pet farthest from the origin.
    for scale, pet in zip((0.85, 1.25, 1.5, 1.0), reversed(pets)):
        reply = call("settings.set", {"path": "app.uiScale", "value": scale})
        check("error" not in (reply or {"error": None}), f"uiScale {scale}: set ({reply})")
        wait_for(lambda: abs(float(page().get("device_pixel_ratio") or 0) - base * scale) < 0.02,
                 f"uiScale {scale}: zoom reached the page")
        reply = page("hover", selector=f".chief-pet-choice[data-pet={pet}]")
        hovered = [e["data"].get("pet") for e in page("query", selector=".chief-pet-choice:hover").get("elements", [])]
        check(reply.get("hovered") is True and reply.get("native") is True,
              f"uiScale {scale}: hover {pet} answers hovered natively ({reply})")
        check(hovered == [pet], f"uiScale {scale}: the page hovers {pet} ({hovered})")
        if scale != 1.0:
            # A point scaled by the zoom or by its inverse moves by at least k times its coordinate.
            k = min(abs(1 - scale), abs(1 - 1 / scale))
            x, y, w, h = (float(reply.get(key, 0)) for key in ("x", "y", "width", "height"))
            check(k * x > w / 2 or k * y > h / 2,
                  f"uiScale {scale}: a wrongly scaled point would leave the {w:.0f}x{h:.0f} card ({k * x:.0f}, {k * y:.0f} px)")
finally:
    if before.get("exists"):
        call("settings.set", {"path": "app.uiScale", "value": before.get("value")})
    else:
        call("settings.unset", {"path": "app.uiScale"})
sys.exit(1 if failures else 0)
