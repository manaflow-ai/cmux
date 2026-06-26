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
AGENTS = {
    "claude": {"title": "App entry point", "launch": f"claude {PROMPT!r}", "order": 3},
    "codex": {"title": "Readability pass", "launch": f"codex {PROMPT!r}", "order": 4},
    "opencode": {"title": "String catalogs", "launch": "opencode", "order": 5, "type_prompt": True},
    "pi": {"title": "Ship improvements", "launch": f"pi {PROMPT!r}", "order": 6},
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
    if info.get("type_prompt"):
        # opencode launches into a TUI; type the prompt after it is ready
        _wait_for(lambda: any(m in read_screen(tag, ws) for m in ("opencode", ">", "Tip", sandbox)), 60)
        time.sleep(3)
        cli(tag, "send", "--workspace", ws, PROMPT)
        cli(tag, "send-key", "--workspace", ws, "enter")
    # wait for a settled response
    _wait_for(lambda: _settled(read_screen(tag, ws)), 240)
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
    hit = find_element(sim, "‹", "Back", "chevron")
    if hit:
        idb_tap(sim, hit[1], hit[2])
        time.sleep(1.5)


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
