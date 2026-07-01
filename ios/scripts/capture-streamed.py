#!/usr/bin/env python3
"""Capture REAL Mac-streamed agent terminal screenshots for the App Store.

Drives the tagged desktop cmux Mac app + a paired simulator and captures the
live streamed terminal for each agent (claude/codex/opencode/pi):

  Mac app (tag) ── runs each agent in its own workspace ──► paired simulator
  mirrors the live terminal ──► we navigate the device into each workspace,
  set a screenshot-friendly font, and capture.

This is genuine cmux Mac→device streaming (not preview-mode replay). The Workspaces
and Notifications shots stay on the preview-mode path; this only produces the 4
agent terminal shots.

Robustness: the Mac app and the pairing connection can drop, so every step is
guarded — the Mac app is relaunched if its debug socket goes away, and the device
is reconnected (tap "Retry") if it shows a connection-lost / reconnecting state.
Navigation uses idb's accessibility tree (element frames), never hardcoded
coordinates.

Usage:
  ios/scripts/capture-streamed.py --tag stream --sim-id <UDID> --out <dir> \
      [--font <pt>] [--agents claude,codex,opencode,pi]

Requires: a built tagged Mac app (scripts/reload-cloud.sh --tag <tag>) and a
built+installed tagged iOS sim app (ios/scripts/reload.sh --tag <tag>); idb;
the dev secrets for sign-in; the web dev server up (sign-in/pairing go through it).
"""
import argparse
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))

# agent -> (workspace title, shell launch command, screenshot order index)
PROMPT = ("Explain what main.swift does, then give 3 concrete improvements with "
          "code blocks (app entry point, readability, and a #Preview). Do not edit any files.")
# Agent terminals REPLAY real sessions recorded locally (with funded accounts)
# and seeded into each agent's on-disk session store at the matching project cwd
# (/private/tmp/cmux-stream-<agent>), then resumed read-only. This gives genuine
# agent content through the real Mac->device streaming pipeline with no CI billing
# or nondeterminism. The launch command resumes the seeded session; auth tokens
# are still set (the CLIs gate launch on them) but resuming makes no API call.
AGENTS = {
    "claude": {"title": "App entry point", "launch": "claude --resume 21f5e73a-4a3a-42ac-bd73-bc8d88256d65", "order": 3},
    "codex": {"title": "Readability pass", "launch": "codex resume 019f1abc-b2cf-7571-bf39-6127d4ebaba2", "order": 4, "press_enter": True},
    "opencode": {"title": "String catalogs", "launch": "opencode --session ses_0e5411393ffeCDprItbIm19S5J", "order": 5},
    "pi": {"title": "Ship improvements", "launch": "pi --session 019f1abe", "order": 6},
}
# response is considered "settled" when the screen shows code + a cost/footer and
# is no longer actively generating.
DONE_MARKERS = ["#Preview", "WindowGroup", "improvements", "struct "]
BUSY_MARKERS = ["esc interrupt", "Thinking", "Working", "Esc to interrupt"]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def cli(tag, *args):
    """Tagged Mac debug CLI."""
    env = dict(os.environ, CMUX_TAG=tag, CMUX_QUIET="1")
    return run([os.path.join(ROOT, "scripts", "cmux-debug-cli.sh"), *args], env=env, cwd=ROOT)


def mac_up(tag):
    return cli(tag, "identify").returncode == 0


def ensure_mac(tag):
    if mac_up(tag):
        return
    app = None
    base = os.path.expanduser(f"~/Library/Developer/Xcode/DerivedData/cmux-{tag}/Build/Products/Debug")
    if os.path.isdir(base):
        for f in os.listdir(base):
            if f.endswith(".app"):
                app = os.path.join(base, f)
    if not app:
        raise SystemExit(f"no tagged Mac app for tag {tag}; build with scripts/reload-cloud.sh --tag {tag}")
    sock = f"/tmp/cmux-debug-{tag}.sock"
    try:
        os.remove(sock)
    except OSError:
        pass
    print(f"  relaunching Mac app: {app}")
    run(["open", app])
    for _ in range(60):
        if mac_up(tag):
            return
        time.sleep(2)
    raise SystemExit("Mac app did not come up")


def read_screen(tag, ws):
    return cli(tag, "read-screen", "--workspace", ws).stdout


# Directory for Mac-side diagnostic screenshots (set in main from --out). Lets us
# see the Mac's cmux window / terminal theme next to the phone's streamed view,
# to check whether the Mac is streaming a light/default theme (the source of the
# white bands on the phone).
MAC_SHOT_DIR = None


def mac_screencapture(key):
    if not MAC_SHOT_DIR:
        return
    os.makedirs(MAC_SHOT_DIR, exist_ok=True)
    out = os.path.join(MAC_SHOT_DIR, f"mac-{key}.png")
    # -x: no capture sound. Full main display; the just-created workspace is
    # foreground. Best-effort: a headless CI Mac may produce a blank/failed shot.
    r = run(["screencapture", "-x", "-t", "png", out])
    ok = os.path.exists(out) and os.path.getsize(out) > 0
    print(f"  mac screenshot: {out} ({'ok' if ok else 'FAILED rc=%s' % r.returncode})")


def setup_agent(tag, key, sandbox):
    """Create a workspace running the agent + drive it to a settled response.
    Returns the workspace ref."""
    info = AGENTS[key]
    ensure_mac(tag)
    # fresh sandbox so every agent answers the same simple project
    os.makedirs(sandbox, exist_ok=True)
    open(os.path.join(sandbox, "main.swift"), "w").write(
        'import SwiftUI\nstruct ContentView: View { var body: some View { Text("Hello") } }\n')
    open(os.path.join(sandbox, "README.md"), "w").write("# Demo app\n")
    run(["git", "init", "-q"], cwd=sandbox)
    r = cli(tag, "new-workspace", "--name", info["title"], "--cwd", sandbox, "--command", info["launch"])
    ws = next((t for t in r.stdout.split() if t.startswith("workspace:")), None)
    if not ws:
        raise SystemExit(f"could not create workspace for {key}: {r.stdout}{r.stderr}")
    print(f"  {key}: {ws} ({info['title']})")
    if info.get("press_enter"):
        # codex resume opens a "Press enter to continue" welcome before showing
        # the resumed session; advance past it with one Enter.
        _wait_for(lambda: "press enter" in read_screen(tag, ws).lower()
                  or "continue" in read_screen(tag, ws).lower(), 40)
        cli(tag, "send-key", "--workspace", ws, "enter")
        time.sleep(2)
    if info.get("type_prompt"):
        # opencode launches into a TUI; type the prompt after it is ready
        _wait_for(lambda: any(m in read_screen(tag, ws) for m in ("opencode", ">", "Tip", sandbox)), 60)
        time.sleep(3)
        cli(tag, "send", "--workspace", ws, PROMPT)
        cli(tag, "send-key", "--workspace", ws, "enter")
    # wait for a settled response
    _wait_for(lambda: _settled(read_screen(tag, ws)), 240)
    # Snapshot the Mac while this workspace is foreground, so we can compare the
    # Mac terminal's theme to the phone's streamed view for the same agent.
    mac_screencapture(key)
    return ws


def _settled(screen):
    if any(b in screen for b in BUSY_MARKERS):
        return False
    return sum(m in screen for m in DONE_MARKERS) >= 2


def _wait_for(pred, timeout, interval=3):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if pred():
                return True
        except Exception:
            pass
        time.sleep(interval)
    return False


# ---- device side -----------------------------------------------------------

def idb_describe(sim):
    r = run(["idb", "ui", "describe-all", "--udid", sim])
    try:
        return json.loads(r.stdout)
    except Exception:
        return []


def find_element(sim, *needles):
    for e in idb_describe(sim):
        lbl = str(e.get("AXLabel") or "")
        if any(n in lbl for n in needles):
            f = e.get("frame", {})
            return (lbl, f.get("x", 0) + f.get("width", 0) / 2, f.get("y", 0) + f.get("height", 0) / 2)
    return None


def idb_tap(sim, x, y):
    run(["idb", "ui", "tap", "--udid", sim, str(int(x)), str(int(y))])


def idb_swipe(sim, x1, y1, x2, y2, duration=0.25):
    run(["idb", "ui", "swipe", "--udid", sim, "--duration", str(duration),
         str(int(x1)), str(int(y1)), str(int(x2)), str(int(y2))])


def _terminal_row_count(sim):
    """Number of 'Terminal' row buttons visible — the workspace list has several;
    a terminal screen has none, so this distinguishes list from terminal."""
    return sum(1 for e in idb_describe(sim) if str(e.get("AXLabel")) == "Terminal")


def reconnect_if_needed(sim):
    hit = find_element(sim, "Retry")
    if hit:
        print("  device disconnected; tapping Retry")
        idb_tap(sim, hit[1], hit[2])
        time.sleep(5)
        return True
    return False


def status_bar_941(sim):
    run(["xcrun", "simctl", "status_bar", sim, "override", "--time", "9:41",
         "--batteryState", "charged", "--batteryLevel", "100",
         "--cellularBars", "4", "--cellularMode", "active", "--wifiBars", "3",
         "--operatorName", ""])


def set_font(tag, size):
    cli(tag, "rpc", "mobile.terminal.set_font", json.dumps({"font_size": size}))


def navigate_back(sim):
    """Return to the workspace list. The nav-bar back chevron has no
    accessibility label, so tap its known position (top-left of the nav bar) and
    fall back to the iOS interactive-pop edge swipe; verify we reached the list."""
    for _ in range(3):
        if _terminal_row_count(sim) >= 2:
            return True
        idb_tap(sim, 28, 89)
        time.sleep(1.3)
        if _terminal_row_count(sim) >= 2:
            return True
        idb_swipe(sim, 1, 430, 320, 430)
        time.sleep(1.3)
    return _terminal_row_count(sim) >= 2


def capture_agent(tag, sim, key, out_dir, device_name, font):
    info = AGENTS[key]
    # ensure connected + on the workspace list
    for _ in range(6):
        reconnect_if_needed(sim)
        if find_element(sim, info["title"]):
            break
        time.sleep(3)
    hit = find_element(sim, info["title"])
    if not hit:
        print(f"  !! workspace '{info['title']}' not visible on device; skipping {key}")
        return False
    idb_tap(sim, hit[1], hit[2])
    time.sleep(3)
    set_font(tag, font)
    time.sleep(2)
    status_bar_941(sim)
    time.sleep(1)
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"{device_name}-{info['order']:02d}-{key.capitalize()}.png")
    run(["xcrun", "simctl", "io", sim, "screenshot", out])
    print(f"  captured {out}")
    navigate_back(sim)
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", default="stream")
    ap.add_argument("--sim-id", required=True)
    ap.add_argument("--device-name", default="iPhone 17 Pro Max")
    ap.add_argument("--out", default=os.path.join(ROOT, "ios/fastlane/screenshots/en-US"))
    ap.add_argument("--font", type=float, default=15.0)
    ap.add_argument("--agents", default="claude,codex,opencode,pi")
    args = ap.parse_args()
    agents = [a.strip() for a in args.agents.split(",") if a.strip()]

    global MAC_SHOT_DIR
    MAC_SHOT_DIR = os.path.join(args.out, "_diag")

    print("== ensure Mac app ==")
    ensure_mac(args.tag)
    print("== set up agent workspaces ==")
    for key in agents:
        setup_agent(args.tag, key, f"/tmp/cmux-stream-{key}")
    print("== prepare device ==")
    run(["xcrun", "simctl", "ui", args.sim_id, "appearance", "dark"])
    status_bar_941(args.sim_id)
    print("== capture ==")
    ok = 0
    for key in agents:
        if capture_agent(args.tag, args.sim_id, key, args.out, args.device_name, args.font):
            ok += 1
    print(f"captured {ok}/{len(agents)} agent shots")


if __name__ == "__main__":
    main()
