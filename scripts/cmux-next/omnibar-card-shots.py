#!/usr/bin/env python3
"""Proof shots of the omnibar suggestion card, dark and light.

  scripts/cmux-next/omnibar-card-shots.py --socket PATH --out DIR

Attaches to a running tagged app (nx-remote --needs gui --app-from-fleet),
opens a Chromium tab, then per appearance captures the window with the
omnibar at rest (`MODE-closed.png`; MODE is dark, light, and compact:
dark at compact density) and with "google.com" typed so the
suggestion card shows (`MODE-open.png`), plus `MODE.json`: the
`debug.omnibar` reports (pointer frames, card and bar rects). The pixels
are measured afterwards (the card's corner radii and insets, and whether
the reload button's pixels change when the card opens).
The theme and density it changes (in the host user's config file) are put
back at the end.
"""
import argparse, json, os, socket, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--socket", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--text", default="google.com")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)


def rpc(method, params=None, timeout=60):
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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def windows():
    report = rpc("debug.focus") or {}
    return (report.get("windows") or []) if isinstance(report, dict) else []


def omnibar(window):
    reply = rpc("debug.omnibar", {"window": window}) or {}
    return reply if isinstance(reply, dict) else {}


def settle():
    time.sleep(1.5)  # proof capture only: the repaint lands before the capture


def close_card(window):
    for _ in range(4):  # Escape closes the card, then reverts the text
        if omnibar(window).get("phase") in ("idle", "focused"):
            break
        rpc("debug.key", {"key": "escape"})


if not wait(lambda: "error" not in (rpc("debug.focus") or {"error": 1}), 120):
    sys.exit("no app on the socket")
if not windows():
    rpc("action.run", {"action": "newWindow", "origin": "script"})
window = (wait(windows, 60) or [{}])[0].get("id")
print("window", window, flush=True)
if "error" in omnibar(window):
    print("new chromium tab", rpc("action.run", {"action": "tab new-chromium", "args": {"url": "about:blank"}, "focus": True}), flush=True)
if not wait(lambda: "error" not in omnibar(window), 90):
    sys.exit(f"no omnibar: {omnibar(window)}")
settle()

failures = 0
# The settings this script changes live in the host user's config file: put them back after.
TOUCHED = ("appearance.theme", "appearance.density")
saved = {path: rpc("settings.get", {"path": path}) or {} for path in TOUCHED}
print("saved settings", saved, flush=True)
try:
    for mode in ("dark", "compact", "light"):
        # compact: dark at compact density (the tighter tab gap above the bar); light at the default.
        if mode != "dark":
            density = "compact" if mode == "compact" else "comfortable"
            print("density", density, rpc("settings.set", {"path": "appearance.density", "value": density}), flush=True)
        looks = rpc("debug.appearance", {"mode": "dark" if mode == "compact" else mode})
        print(mode, "appearance", looks, flush=True)
        background = (looks or {}).get("terminal_background") if isinstance(looks, dict) else None
        if mode == "light" and isinstance(background, str) and background.startswith("#"):
            r, g, b = (int(background[i:i + 2], 16) for i in (1, 3, 5))
            if r + g + b < 384:  # the default theme has no light side: a light theme
                print("light theme", rpc("settings.set", {"path": "appearance.theme", "value": "Catppuccin Latte"}), flush=True)
        close_card(window)
        settle()
        report = {"mode": mode, "appearance": looks, "closed": omnibar(window)}
        print("snapshot closed", rpc("debug.window_snapshot", {"window": window, "path": os.path.join(opts.out, f"{mode}-closed.png")}), flush=True)
        for attempt in range(3):  # a focus change can close the card before the capture: type again
            typed = rpc("debug.omnibar_type", {"window": window, "text": opts.text, "commit": False})
            print("typed", (typed or {}).get("typed"), (typed or {}).get("phase"), flush=True)
            wait(lambda: omnibar(window).get("card"), 15)
            settle()
            report["open"] = omnibar(window)
            if report["open"].get("card"):
                break
            close_card(window)
        if not report["open"].get("card"):
            print(f"FAIL no card in {mode}: {report['open'].get('phase')}", flush=True)
            failures += 1
        print("card", report["open"].get("card"), "frames", (report["open"].get("pointer") or {}).get("frames"), flush=True)
        print("snapshot open", rpc("debug.window_snapshot", {"window": window, "path": os.path.join(opts.out, f"{mode}-open.png")}), flush=True)
        with open(os.path.join(opts.out, f"{mode}.json"), "w") as f:
            json.dump(report, f, indent=1, default=str)
        close_card(window)
finally:
    for path, before in saved.items():
        if before.get("exists"):
            print("restore", path, rpc("settings.set", {"path": path, "value": before.get("value")}), flush=True)
        else:
            print("restore (unset)", path, rpc("settings.unset", {"path": path}), flush=True)

print(f"{failures} failure(s); shots in {opts.out}")
sys.exit(1 if failures else 0)
