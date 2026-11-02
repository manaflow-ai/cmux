"""SWITCH FRAMES: the beacon program, a beacon workspace profile, real HID switch keys and the HARNESS recorder.

driver.py loads this file (load_extensions) on the mini under /usr/bin/python3 (3.9, standard library only). It must
not import driver.py: install() gets the driver module instead. The same file is the beacon program
(`python3 ext_switch.py beacon --ws N --pane M`) and the beacon codec the VM judge imports
(scripts/cmux-next/switch-frames/judge_switch.py).

Beacon: a terminal program whose every frame says, in colors a video judge reads, WHICH pane it is and WHEN it drew.
Top-left of the terminal, one block = CELL_COLS columns x 1 row, truecolor background:
  row 0:  Y  ws[6 bits]  pane[4 bits]           parity  R
  row 1:  Y  clock gray-code bits 17..9         parity  R
  row 2:  Y  clock gray-code bits  8..0         parity  R
Y = yellow start block, R = red end block, bit 1 = magenta, bit 0 = cyan. The clock is time.time_ns() in
CLOCK_UNIT_MS units, 18 bits (wraps every 524 s). Each frame is one synchronized-output update (DEC mode 2026), so
the three rows always come from one clock read.

Steps (`do`):
  switch_profile {workspaces: 9, panes: 2, prefix: "sw", hz: 240, fill: false}
              N workspaces (action.run newTab, a beacon as the command), each split to `panes` panes (splitRight),
              one beacon per pane (`--ws i --pane p`). Then maps Cmd-1..9 to the shown workspace by the socket's
              debug.key (no HID), and selects the first beacon workspace. Result: the map {digit: workspace}.
  switch_record {action: start|stop, name: "switch", codec: hevc|prores, mbps: 80, seconds: 110}
              debug.motion record_* (the HARNESS recorder, branch perf/debug-screen-record): the window as the
              window server composites it, every frame, into <journey out>/<name>.mov (+ .frames.json, .scan).
  switch_adopt_shown  the focused pane of the shown workspace becomes the journey's terminal (for the end checks).
  switch_keys {keys: [[mods, key, case], ...] | digits: "1234567892...", gap: 1.2, via: hid|socket,
              action: "selectWorkspaceByNumber", name: "switch"}
              each key by CuaDriver HID (foreground delivery), `gap` seconds apart; then reads the action runs from
              debug.action_budget and writes <out>/<name>.events.json: per key the HID key-down host time
              (start_uptime_ns - input_age_ms, the clock of the recorder's frames.json), the case, and the
              workspace the app shows after it (debug.surfaces).
"""
import json
import os
import signal
import subprocess
import sys
import time

D = None

CLOCK_UNIT_MS = 2
CLOCK_BITS = 18
WS_BITS = 6
PANE_BITS = 4
COLORS = {
    "Y": (255, 255, 0),
    "R": (255, 0, 0),
    1: (255, 0, 255),
    0: (0, 255, 255),
}
CUA = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
MODIFIERS = {"control": "ctrl", "ctrl": "ctrl", "cmd": "cmd", "command": "cmd", "shift": "shift",
             "option": "option", "alt": "option", "opt": "option"}


# ---- beacon codec (shared with the VM judge) -------------------------------------------------------------------

def gray(n):
    return n ^ (n >> 1)


def ungray(g):
    n, shift = g, 1
    while (g >> shift) > 0:
        n ^= g >> shift
        shift += 1
    return n


def bits(value, width):
    return [(value >> (width - 1 - i)) & 1 for i in range(width)]


def parity(values):
    return sum(values) & 1


def clock_units(now_ns=None):
    now_ns = time.time_ns() if now_ns is None else now_ns
    return (now_ns // (CLOCK_UNIT_MS * 1000000)) % (1 << CLOCK_BITS)


def rows(ws, pane, clock):
    """The data bits of the three rows (no markers, parity last)."""
    ids = bits(ws % (1 << WS_BITS), WS_BITS) + bits(pane % (1 << PANE_BITS), PANE_BITS)
    g = bits(gray(clock), CLOCK_BITS)
    hi, lo = g[:9], g[9:]
    return [ids + [parity(ids)], hi + [parity(hi)], lo + [parity(lo)]]


def _block(color, cols):
    r, g, b = COLORS[color]
    return "\x1b[48;2;%d;%d;%dm" % (r, g, b) + " " * cols


def ansi(ws, pane, clock, cell_cols=2, row0=1, col0=1):
    out = []
    for i, data in enumerate(rows(ws, pane, clock)):
        out.append("\x1b[%d;%dH" % (row0 + i, col0))
        out.append(_block("Y", cell_cols))
        out.extend(_block(bit, cell_cols) for bit in data)
        out.append(_block("R", cell_cols))
        out.append("\x1b[0m")
    return "".join(out)


def _fill(frame, width, height, top):
    out = []
    for y in range(top, height + 1):
        shade = (frame * 3 + y * 7) % 64 + 32
        out.append("\x1b[%d;1H\x1b[48;2;%d;%d;%dm" % (y, shade, shade // 2, 96 - shade // 2) + " " * width)
    out.append("\x1b[0m")
    return "".join(out)


def beacon_main(argv):
    import argparse
    ap = argparse.ArgumentParser(prog="ext_switch.py beacon")
    ap.add_argument("--ws", type=int, required=True)
    ap.add_argument("--pane", type=int, default=0)
    ap.add_argument("--hz", type=float, default=240.0)
    ap.add_argument("--cell-cols", type=int, default=2)
    ap.add_argument("--fill", action="store_true")
    ap.add_argument("--label", default=None)
    args = ap.parse_args(argv)
    out = sys.stdout
    label = args.label or "WS %d  PANE %d" % (args.ws, args.pane)
    size = [80, 24]

    def resize(*_):
        try:
            size[0], size[1] = os.get_terminal_size()
        except OSError:
            pass
        out.write("\x1b[2J")

    def stop(*_):
        out.write("\x1b[0m\x1b[?25h\x1b[?1049l")
        out.flush()
        sys.exit(0)

    signal.signal(signal.SIGWINCH, resize)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    resize()
    out.write("\x1b[?1049h\x1b[?25l\x1b[2J")
    period = 1.0 / args.hz
    next_at = time.monotonic()
    frame = 0
    while True:
        text = ["\x1b[?2026h", ansi(args.ws, args.pane, clock_units(), args.cell_cols)]
        text.append("\x1b[5;1H\x1b[1m%s\x1b[0m  frame %9d" % (label, frame))
        if args.fill:
            text.append(_fill(frame, size[0], size[1], 7))
        text.append("\x1b[?2026l")
        out.write("".join(text))
        out.flush()
        frame += 1
        next_at += period
        delay = next_at - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        else:
            next_at = time.monotonic()


# ---- journey steps ---------------------------------------------------------------------------------------------

def install(driver):
    global D
    D = driver


def _beacon_command(ws, pane, step):
    me = os.path.abspath(__file__)
    cmd = "/usr/bin/python3 -I %s beacon --ws %d --pane %d --hz %s" % (me, ws, pane, step.get("hz", 240))
    if step.get("fill"):
        cmd += " --fill"
    return cmd


def _workspaces(j):
    return [w for w in (j.topology().get("workspaces") or []) if isinstance(w, dict)]


def _ws_named(j, name):
    return next((w for w in _workspaces(j) if w.get("name") == name), None)


def _terminals_of(ws):
    out = []
    for screen in ws.get("screens", []):
        for pane in screen.get("panes", []):
            for tab in pane.get("tabs", []):
                term = tab.get("terminal")
                term = term.get("id") if isinstance(term, dict) else term
                if term:
                    out.append((pane.get("id"), str(term)))
    return out


def _shown_workspace(j):
    """The workspace id the key window shows (debug.surfaces: the focused pane's workspace)."""
    panes = j.app.panes()
    focused = next((p for p in panes if p.get("focused")), None) or (panes[0] if panes else None)
    return focused.get("workspace") if focused else None


def _wait(cond, timeout, what):
    end = D.now() + timeout
    last = None
    while D.now() < end:
        last = cond()
        if last:
            return last
        time.sleep(0.15)
    raise D.StepError("switch: %s within %.0f s" % (what, timeout))


def step_switch_profile(j, step):
    count, panes = int(step.get("workspaces", 9)), int(step.get("panes", 2))
    prefix = j.sub(step.get("prefix", "sw"))
    made = []
    for i in range(1, count + 1):
        name = "%s-%d" % (prefix, i)
        j.app.rpc("action.run", {"action": "newTab", "args": {"name": name, "focus": True,
                                                                "command": _beacon_command(i, 0, step)}})
        ws = _wait(lambda: _ws_named(j, name), 20, "workspace %s did not appear" % name)
        _wait(lambda: _shown_workspace(j) == ws.get("id"), 10, "workspace %s did not show" % name)
        for p in range(1, panes):
            have = len(_terminals_of(_ws_named(j, name)))
            j.app.rpc("action.run", {"action": "splitRight", "args": {}})
            now = _wait(lambda: (lambda w: w if w and len(_terminals_of(w)) > have else None)(_ws_named(j, name)),
                        20, "split %d of %s made no terminal" % (p, name))
            term = _terminals_of(now)[-1][1]
            known = {t for _, t in _terminals_of(now)[:-1]}
            fresh = [t for _, t in _terminals_of(now) if t not in known]
            term = fresh[-1] if fresh else term
            # The new shell's first prompt, then the beacon command.
            _wait(lambda: j.app.screen(term)["text"].strip(), 20, "the shell of split %d of %s drew no prompt" % (p, name))
            j.app.cmux("terminal", term, "write", "--text", "exec " + _beacon_command(i, p, step) + "\n")
        made.append({"index": i, "name": name, "id": _ws_named(j, name).get("id"),
                     "terminals": _terminals_of(_ws_named(j, name))})
    time.sleep(1.0)
    # Cmd-1..9 -> the workspace it shows (the sidebar's shown order may hold Home or the launch workspace).
    by_id = {m["id"]: m for m in made}
    digits = {}
    for d in range(1, 10):
        reply = j.key(str(d), ["cmd"])
        time.sleep(0.4)
        shown = _shown_workspace(j)
        digits[str(d)] = {"workspace": shown, "beacon_ws": by_id[shown]["index"] if shown in by_id else None,
                          "handled_by": reply.get("handled_by") if isinstance(reply, dict) else None}
    first = next((d for d in sorted(digits) if digits[d]["beacon_ws"]), None)
    if first:
        j.key(first, ["cmd"])
        time.sleep(0.5)
    j.switch_profile = {"workspaces": made, "digits": digits}
    (j.out / "switch-profile.json").write_text(json.dumps(j.switch_profile, indent=1))
    return {"workspaces": len(made), "panes": panes, "digits": {d: v["beacon_ws"] for d, v in digits.items()}}


def step_switch_record(j, step):
    name = step.get("name", "switch")
    if step.get("action", "start") == "start":
        params = {"action": "record_start", "path": str(j.out / (name + ".mov")),
                  "codec": step.get("codec", "hevc"), "mbps": float(step.get("mbps", 80)),
                  "seconds": float(step.get("seconds", 110))}
        reply = j.app.rpc("debug.motion", params) or {}
        if reply.get("error"):
            raise D.StepError("switch_record: record_start: %s (this build has no debug.motion record_*?)" % reply["error"])
        state = _wait(lambda: (lambda r: r if r.get("capturing") or r.get("error") else None)(
            j.app.rpc("debug.motion", {"action": "record_read"}) or {}), 15, "the recorder did not start")
        if state.get("error"):
            raise D.StepError("switch_record: %s" % state["error"])
        time.sleep(0.5)
        return {"start": reply, "read": state}
    reply = j.app.rpc("debug.motion", {"action": "record_stop"}) or {}
    state = _wait(lambda: (lambda r: r if r.get("written") else None)(
        j.app.rpc("debug.motion", {"action": "record_read"}) or {}), 60, "the recorder did not write its files")
    return {"stop": reply, "read": state}


def _cua(tool, args, timeout=30):
    if not os.path.exists(CUA):
        raise D.NotRun("switch_keys: no CuaDriver at %s on this mini" % CUA)
    done = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=timeout)
    text = (done.stdout or "") + (done.stderr or "")
    try:
        answer = json.loads(text[text.index("{"):text.rindex("}") + 1])
    except ValueError:
        answer = {"raw": text.strip()[-600:]}
    return done.returncode, answer


def _main_window(j):
    code, answer = _cua("list_windows", {})
    rows_ = answer.get("windows") or (answer.get("structuredContent") or {}).get("windows") or []
    mine = [w for w in rows_ if int(w.get("pid") or w.get("owner_pid") or -1) == j.app.pid
            and w.get("layer", 0) == 0 and w.get("is_on_screen", w.get("on_screen", True))]
    if not mine:
        raise D.NotRun("switch_keys: CuaDriver lists no on-screen window of the app (pid %s)" % j.app.pid)
    area = lambda w: float((w.get("bounds") or {}).get("width") or 0) * float((w.get("bounds") or {}).get("height") or 0)
    return int(max(mine, key=area).get("window_id"))


def _recent(j):
    try:
        reply = j.app.rpc("debug.action_budget", {"limit": 256}) or {}
    except D.StepError:
        return []
    return [r for r in reply.get("recent") or [] if isinstance(r, dict)]


def step_switch_keys(j, step):
    name = step.get("name", "switch")
    gap = float(step.get("gap", 1.2))
    via = step.get("via", "hid")
    action = step.get("action", "selectWorkspaceByNumber")
    keys = step.get("keys")
    if not keys:
        keys = [[["cmd"], d, "cmd-" + d] for d in str(step.get("digits", "123456789"))]
    profile = getattr(j, "switch_profile", {}) or {}
    digits = profile.get("digits", {})
    wid = _main_window(j) if via == "hid" else None
    before = max([int(r.get("sequence") or 0) for r in _recent(j)] or [0])
    sent = []
    for mods, key, case in keys:
        mods = [MODIFIERS.get(m, m) for m in mods]
        t_wall = time.time()
        if via == "hid":
            code, answer = _cua("hotkey", {"pid": j.app.pid, "window_id": wid, "keys": mods + [key],
                                           "delivery_mode": "foreground"})
            effect = answer.get("effect") or (answer.get("structuredContent") or {}).get("effect")
            if code != 0 or effect in ("refused", "failed", "error"):
                raise D.StepError("switch_keys %s: CuaDriver did not send it (exit %s): %s" % (mods + [key], code, json.dumps(answer)[:400]))
        else:
            j.key(key, mods)
        time.sleep(gap / 2)
        shown = _shown_workspace(j)
        sent.append({"case": case, "keys": mods + [key], "wall": t_wall, "shown": shown,
                     "expect": (digits.get(key) or {}).get("workspace") if action == "selectWorkspaceByNumber" else None})
        time.sleep(gap / 2)
    runs = sorted((r for r in _recent(j) if int(r.get("sequence") or 0) > before and r.get("id") == action),
                  key=lambda r: int(r.get("sequence") or 0))
    events = []
    for i, s in enumerate(sent):
        run = runs[i] if i < len(runs) else None
        ev = dict(s)
        if run:
            start = float(run.get("start_uptime_ns") or 0) / 1e9
            age = float(run.get("input_age_ms") if run.get("input_age_ms") is not None else -1)
            ev["action_start_host_s"] = start
            ev["input_age_ms"] = age
            ev["entrypoint"] = run.get("entrypoint")
            ev["outcome"] = run.get("outcome")
            # The HID key-down's host time: the action's start less its event's age (-1: no event age known).
            ev["t"] = start - age / 1000.0 if age >= 0 else start
            ev["t_source"] = "keydown" if age >= 0 else "action-start"
        events.append(ev)
    (j.out / (name + ".events.json")).write_text(json.dumps({"events": events, "runs": runs}, indent=1))
    missing = sum(1 for e in events if "t" not in e)
    wrong = [e["case"] for e in events if e.get("expect") and e.get("shown") != e["expect"]]
    return {"keys": len(sent), "runs": len(runs), "missing_runs": missing, "wrong_target": wrong,
            "via": via, "entrypoints": sorted({str(e.get("entrypoint")) for e in events})}


def step_switch_adopt_shown(j, step):
    """Makes the focused pane of the shown workspace the journey's current terminal (for the end checks)."""
    panes = j.app.panes()
    focused = next((p for p in panes if p.get("focused")), None) or (panes[0] if panes else None)
    if not focused:
        raise D.StepError("switch_adopt_shown: debug.surfaces lists no pane")
    ws = next((w for w in _workspaces(j) if w.get("id") == focused.get("workspace")), None)
    term = next((t for pid, t in _terminals_of(ws or {}) if pid == focused.get("pane")), None)
    if not term:
        raise D.StepError("switch_adopt_shown: no daemon terminal for pane %s" % focused.get("pane"))
    return j.adopt(term, focused.get("pane"))


STEPS = {"switch_profile": step_switch_profile, "switch_record": step_switch_record, "switch_keys": step_switch_keys,
         "switch_adopt_shown": step_switch_adopt_shown}


if __name__ == "__main__" and len(sys.argv) > 1 and sys.argv[1] == "beacon":
    beacon_main(sys.argv[2:])
