#!/usr/bin/env python3
"""Live proof that new workspace rows are instant and that row opens and closes move smoothly.

Run it on cmux-lawrence-2 in an nx-remote GUI job with a fleet-built app:
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- 'open -n --env ACPMUX_AGENT_LAUNCH=deny --env NX_REMOTE=1 "$NX_APP" && python3 scripts/cmux-next/sidebar-instant-rows-live.py --out "$NX_ARTIFACTS"'
Each scenario records the window (`debug.window_record`, one JPEG per display
frame), the sidebar's presented row frames and opacity per display frame
(`debug.sidebar_rows {"motion": ...}`), and samples `debug.sidebar_rows` as fast
as the socket answers from the press on (title, `row_state`, folder line).
Checks, per scenario:
- instant: each new workspace row is listed in the first sample after its
  press, in its final look: its title (the daemon's default `workspace-N`
  when no name is asked for) and row state never change afterwards (`creating` then `live`
  is the same look); no sample shows a `placeholder` row on this Mac.
- smooth: no row view that stays listed reaches a new place in one display
  frame (a step over 60% of a row height with no motion in the next frame is
  a jump; a long first step of the ease-out after a dropped frame is not),
  and an opening row's opacity rises (it fades in). The longest frame gap is
  reported (a main-thread hitch shows there).
Scenarios: Cmd-N x1, Cmd-N x5 at key-repeat speed (33 ms), Close Workspace x1
and x5, a sidebar tab row open and close (Show Tabs Under Workspaces on), and
the tab strip open and close (frames only). Exit 1 when a check fails. The app
is stopped by the caller ($NX_APP_STOP), never here.
"""
import argparse, json, os, socket, sys, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--socket", default=os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{os.environ.get('NX_APP_TAG', '')}.sock")
parser.add_argument("--seconds", type=float, default=1.6)
opts = parser.parse_args()
failures = []


def rpc(method, params=None, timeout=30):
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


def action(name):
    # A close asks before it ends a running terminal; the proof confirms, as the dialog's Close would.
    arguments = {"confirm": "true"} if name == "closeWorkspace" else {}
    reply = rpc("action.run", {"action": name, "arguments": arguments})
    if isinstance(reply, dict) and reply.get("error"):
        print(f"action {name}: {json.dumps(reply)[:200]}", flush=True)
    return reply


def window_rows():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return (windows[0] if windows else {}).get("rows") or []


def workspace_rows():
    return [r for r in window_rows() if str(r.get("key", "")).startswith("workspace(")]


def wait(check, seconds):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.1)  # test harness polling a live app
    return None


def check(name, ok, detail):
    print(f"{'PASS' if ok else 'FAIL'} {name}: {detail}", flush=True)
    if not ok:
        failures.append(name)


def scenario(name, presses, gap=0.033, settle=None):
    """Runs `presses` (action ids) `gap` seconds apart under a recording and
    returns (samples, motion frames, keys before)."""
    directory = os.path.join(opts.out, name)
    os.makedirs(directory, exist_ok=True)
    before = {r["key"] for r in workspace_rows()}
    rpc("debug.window_record", {"dir": directory, "seconds": opts.seconds})
    rpc("debug.sidebar_rows", {"motion": "start"})
    samples, stop = [], threading.Event()

    def sample():
        while not stop.is_set():
            asked = time.time()  # the time the request left: a sample asked after a press returned must show it
            samples.append((asked, workspace_rows()))

    sampler = threading.Thread(target=sample, daemon=True)
    time.sleep(0.15)  # test harness: still frames before the change
    pressed = []
    sampler.start()
    for press in presses:
        action(press)
        pressed.append(time.time())
        time.sleep(gap)  # test harness: key-repeat spacing
    time.sleep(settle or opts.seconds)  # test harness: the motion and the creates settle
    stop.set()
    sampler.join()
    motion = rpc("debug.sidebar_rows", {"motion": "stop"}) or {}
    time.sleep(0.6)  # test harness: the recording stops by itself
    with open(os.path.join(directory, "samples.json"), "w") as handle:
        json.dump({"pressed": pressed, "samples": samples, "motion": motion}, handle)
    frames = len([f for f in os.listdir(directory) if f.endswith(".jpg")])
    print(f"{name}: {frames} frames, {len(samples)} row samples, {len(motion.get('frames') or [])} motion frames", flush=True)
    return samples, motion, before, pressed


def check_instant(name, samples, before, pressed, expect_new):
    first_seen, looks, bad = {}, {}, []
    for at, rows in samples:
        for row in rows:
            key = row["key"]
            if row.get("row_state") == "placeholder":
                bad.append(f"{key} placeholder at {at - pressed[0]:.3f}s")
            if key in before:
                continue
            look = (row.get("title"), row.get("row_state") if row.get("row_state") != "creating" else "live")
            if key not in first_seen:
                first_seen[key] = at
                looks[key] = look
            elif look != looks[key]:
                bad.append(f"{key} changed look {looks[key]} -> {look}")
                looks[key] = look
    check(f"{name} rows", len(first_seen) == expect_new, f"{len(first_seen)} new rows for {expect_new} presses: {sorted(looks.values())}")
    # The first sample taken after each press lists that press's row.
    late = []
    for index, at in enumerate(pressed):
        after = [rows for when, rows in samples if when > at]
        if not after:
            continue
        shown = sum(1 for row in after[0] if row["key"] not in before)
        if shown < index + 1:
            late.append(f"press {index + 1}: {shown} new rows in the first sample after it")
    check(f"{name} instant", not late and not bad, "; ".join(late + bad) or "every row final from the first sample after its press")


def check_smooth(name, motion):
    frames = motion.get("frames") or []
    jumps, fades = [], {}
    def screen_y(frame, key):
        box = (frame.get("views") or {}).get(key)
        return None if box is None else box[1] - frame.get("scroll", 0)
    for index, (previous, current) in enumerate(zip(frames, frames[1:])):
        following = frames[index + 2] if index + 2 < len(frames) else None
        for key, box in (current.get("views") or {}).items():
            old = (previous.get("views") or {}).get(key)
            if not old or not key.startswith(("workspace(", "tab(")):
                continue
            height = max(1.0, box[3])
            step = screen_y(current, key) - screen_y(previous, key)
            after = screen_y(following, key) if following else None
            still_after = after is None or abs(after - screen_y(current, key)) < 0.5
            if abs(step) > 0.6 * height and still_after and old[4] > 0.05 and box[4] > 0.05:
                jumps.append(f"{key} {step:+.1f} in one frame")
            if box[4] < 0.99 or old[4] < 0.99:
                fades.setdefault(key, []).append(round(box[4], 2))
    gap = max((b["t"] - a["t"] for a, b in zip(frames, frames[1:])), default=0) * 1000
    check(f"{name} smooth", not jumps, ", ".join(jumps[:6]) or f"{len(frames)} frames, no jump, longest frame {gap:.0f} ms; fading rows {len(fades)}")
    return fades


def main():
    if not wait(lambda: (rpc("debug.windows") or {}).get("windows"), 90):
        sys.exit("the app does not answer on " + opts.socket)
    os.makedirs(opts.out, exist_ok=True)
    rpc("debug.motion", {"action": "speed", "value": "normal"})
    rpc("settings.unset", {"path": "sidebar.showWorkspaceTabs"})
    wait(lambda: len(workspace_rows()) >= 1, 30)
    time.sleep(1.0)  # test harness: the launch settles

    samples, motion, before, pressed = scenario("cmd-n-x1", ["newTab"])
    check_instant("cmd-n-x1", samples, before, pressed, 1)
    fades = check_smooth("cmd-n-x1", motion)
    check("cmd-n-x1 opens", bool(fades), f"fading rows: {list(fades)[:4]}")

    samples, motion, before, pressed = scenario("cmd-n-x5", ["newTab"] * 5, settle=3.0)
    check_instant("cmd-n-x5", samples, before, pressed, 5)
    check_smooth("cmd-n-x5", motion)

    _, motion, before, _ = scenario("close-x1", ["closeWorkspace"])
    check_smooth("close-x1", motion)
    check("close-x1 count", len(workspace_rows()) == len(before) - 1, f"{len(before)} -> {len(workspace_rows())}")
    _, motion, before, _ = scenario("close-x5", ["closeWorkspace"] * 5, settle=3.0)
    check_smooth("close-x5", motion)
    check("close-x5 count", len(workspace_rows()) == len(before) - 5, f"{len(before)} -> {len(workspace_rows())}")

    rpc("settings.set", {"path": "sidebar.showWorkspaceTabs", "value": True})
    wait(lambda: any(str(r.get("key", "")).startswith("tab(") for r in window_rows()), 5)
    time.sleep(0.5)  # test harness: the list settles
    try:
        _, motion, _, _ = scenario("sidebar-tab-open", ["newSurface"])
        fades = check_smooth("sidebar-tab-open", motion)
        check("sidebar-tab-open opens", any(k.startswith("tab(") for k in fades), f"fading rows: {list(fades)[:4]}")
        _, motion, _, _ = scenario("sidebar-tab-close", ["closeTab"])
        # A closing row's view leaves the probe (it fades outside rowViews): the frames show its collapse.
        check_smooth("sidebar-tab-close", motion)
    finally:
        rpc("settings.unset", {"path": "sidebar.showWorkspaceTabs"})
    time.sleep(0.5)  # test harness: the list settles
    scenario("tab-strip-open", ["newSurface"])
    scenario("tab-strip-close", ["closeTab"])
    print(f"\nRESULT {'FAIL ' + ', '.join(failures) if failures else 'PASS'}", flush=True)
    sys.exit(1 if failures else 0)


main()
