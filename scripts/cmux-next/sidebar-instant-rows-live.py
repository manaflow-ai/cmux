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
  press, in its final look: its title (the live rule's: a daemon default name
  draws none) and row state never change afterwards (`creating` then `live`
  is the same look); no sample shows a `placeholder` row on this Mac.
- smooth: no row view that stays listed reaches a new place in one display
  frame (a step over 60% of a row height with no motion in the next frame is
  a jump; a long first step of the ease-out after a dropped frame is not),
  and an opening row's opacity rises (it fades in). The longest frame gap is
  reported (a main-thread hitch shows there).
- instant close (Close Workspace x1 and x5, no window recording, so its
  per-frame snapshots do not load the main thread): the first sample after
  each press no longer lists the closed row (its close animation started) and
  selects another row (the selection moved with it), and no display frame
  waits over 50 ms (a main-thread stall); a recorded close-x1 keeps the frames.
- refused close (`debug.sidebar_rows {"refuse_next_close": true}` fails the
  next close before the daemon): the row leaves at the press and comes back
  (it opens again), and the workspace count does not change.
Scenarios: Cmd-N x1, Cmd-N x5 at key-repeat speed (33 ms), Close Workspace x1
and x5, a refused close, a sidebar tab row open and close (Show Tabs Under
Workspaces on), and the tab strip open and close (frames only). Exit 1 when a
check fails. The app is stopped by the caller ($NX_APP_STOP), never here.
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


def window_report():
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or []
    return windows[0] if windows else {}


def window_rows():
    return window_report().get("rows") or []


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


def scenario(name, presses, gap=0.033, settle=None, record=True):
    """Runs `presses` (action ids) `gap` seconds apart, under a recording when
    `record`, and returns (samples, motion frames, keys before, press times).
    A sample is (time asked, workspace rows, the window's selection)."""
    directory = os.path.join(opts.out, name)
    os.makedirs(directory, exist_ok=True)
    before = {r["key"] for r in workspace_rows()}
    if record:
        rpc("debug.window_record", {"dir": directory, "seconds": opts.seconds})
    rpc("debug.sidebar_rows", {"motion": "start"})
    samples, stop = [], threading.Event()

    def sample():
        while not stop.is_set():
            asked = time.time()  # the time the request left: a sample asked after a press returned must show it
            report = window_report()
            rows = [r for r in report.get("rows") or [] if str(r.get("key", "")).startswith("workspace(")]
            samples.append((asked, rows, report.get("selection")))

    sampler = threading.Thread(target=sample, daemon=True)
    time.sleep(0.15)  # test harness: still frames before the change
    pressed = []
    sampler.start()
    for press in presses:
        shown = window_report().get("selection")
        sent = time.time()
        action(press)
        pressed.append((sent, time.time(), shown))
        time.sleep(gap)  # test harness: key-repeat spacing
    time.sleep(settle or opts.seconds)  # test harness: the motion and the creates settle
    stop.set()
    sampler.join()
    motion = rpc("debug.sidebar_rows", {"motion": "stop"}) or {}
    if record:
        time.sleep(0.6)  # test harness: the recording stops by itself
    with open(os.path.join(directory, "samples.json"), "w") as handle:
        json.dump({"pressed": pressed, "samples": samples, "motion": motion}, handle)
    pressed = [returned for _, returned, _ in pressed] if not name.startswith(("close", "refused")) else pressed
    frames = len([f for f in os.listdir(directory) if f.endswith(".jpg")])
    print(f"{name}: {frames} frames, {len(samples)} row samples, {len(motion.get('frames') or [])} motion frames", flush=True)
    return samples, motion, before, pressed


def check_instant(name, samples, before, pressed, expect_new):
    first_seen, looks, bad = {}, {}, []
    for at, rows, _ in samples:
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
                # A daemon default name draws no title (SidebarMapping.sidebarTitle); never the placeholder bar.
            elif look != looks[key]:
                bad.append(f"{key} changed look {looks[key]} -> {look}")
                looks[key] = look
    check(f"{name} rows", len(first_seen) == expect_new, f"{len(first_seen)} new rows for {expect_new} presses: {sorted(looks.values())}")
    # The first sample taken after each press lists that press's row.
    late = []
    for index, at in enumerate(pressed):
        after = [rows for when, rows, _ in samples if when > at]
        if not after:
            continue
        shown = sum(1 for row in after[0] if row["key"] not in before)
        if shown < index + 1:
            late.append(f"press {index + 1}: {shown} new rows in the first sample after it")
    check(f"{name} instant", not late and not bad, "; ".join(late + bad) or "every row final from the first sample after its press")


def selection_key(selection):
    return f"workspace({selection})" if selection and not str(selection).startswith("workspace(") else selection


# A sample asked this long after a press was sent is answered after the app ran the press's own turn.
SETTLE_AFTER_SEND = 0.015


def check_close(name, samples, pressed, motion, stall_ms=50):
    """Each press: from the first sample asked after it (the socket's action.run returns only after the
    daemon replied, so the samples between send and return show the row before the reply) the shown row
    is listed no more and another row is selected."""
    late, before_reply = [], 0
    for index, (sent, returned, shown) in enumerate(pressed):
        after = [(when, rows, selection) for when, rows, selection in samples if when > sent + SETTLE_AFTER_SEND]
        if not after or not shown:
            late.append(f"press {index + 1}: no sample or no selection before it")
            continue
        key = selection_key(shown)
        until = [(rows, selection) for when, rows, selection in after if when <= returned] or [after[0][1:]]
        before_reply += len([1 for when, _, _ in after if when <= returned])
        for rows, selection in until:
            if any(r["key"] == key for r in rows) or selection_key(selection) == key:
                late.append(f"press {index + 1}: {key} listed={any(r['key'] == key for r in rows)} selection={selection}")
                break
    detail = f"{len(pressed)} press(es): row gone and selection moved from the first sample ({before_reply} samples before the reply)"
    check(f"{name} instant", not late, "; ".join(late) or detail)
    frames = motion.get("frames") or []
    gaps = [round((b["t"] - a["t"]) * 1000) for a, b in zip(frames, frames[1:])]
    worst = max(gaps, default=0)
    check(f"{name} no stall", bool(frames) and worst <= stall_ms, f"longest frame {worst} ms over {len(frames)} frames (limit {stall_ms} ms)")
    return worst


def check_refused(name, samples, pressed, after_keys):
    sent, _, shown = pressed[0]
    key = selection_key(shown)
    later = [rows for when, rows, _ in samples if when > sent + SETTLE_AFTER_SEND]
    gone = bool(later) and not any(r["key"] == key for r in later[0])
    back = any(any(r["key"] == key for r in rows) for rows in later[1:])
    check(f"{name} row back", gone and back and key in after_keys, f"{key}: gone at the press {gone}, back later {back}, listed at the end {key in after_keys}")


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

    samples, motion, before, pressed = scenario("close-x1", ["closeWorkspace"], record=False)
    check_close("close-x1", samples, pressed, motion)
    check_smooth("close-x1", motion)
    check("close-x1 count", len(workspace_rows()) == len(before) - 1, f"{len(before)} -> {len(workspace_rows())}")
    samples, motion, before, pressed = scenario("close-x5", ["closeWorkspace"] * 5, settle=3.0, record=False)
    check_close("close-x5", samples, pressed, motion)
    check_smooth("close-x5", motion)
    check("close-x5 count", len(workspace_rows()) == len(before) - 5, f"{len(before)} -> {len(workspace_rows())}")
    _, motion, before, _ = scenario("close-x1-recorded", ["closeWorkspace"])
    check_smooth("close-x1-recorded", motion)
    rpc("debug.sidebar_rows", {"refuse_next_close": True})
    samples, motion, before, pressed = scenario("refused-close", ["closeWorkspace"], record=False)
    after_keys = {r["key"] for r in workspace_rows()}
    check_refused("refused-close", samples, pressed, after_keys)
    check("refused-close count", after_keys == before, f"{len(before)} -> {len(after_keys)}")

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
