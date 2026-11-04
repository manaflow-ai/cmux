#!/usr/bin/env python3
"""RESIZE KEYS cases (agent resize-keys; P0 cmux-ad 2026-11-02 "still dont have pixel perfect ctrl shift hjkl for
resizing"): keyboard pane resize, key.resizePaneLeft/Right/Up/Down = Ctrl-Shift-H/L/K/J and Ctrl-Cmd-arrows (both
are Ghostty-default keys: the cases press them, never change them).

  gen_keys.py --out DIR [--only CASE ...]     writes DIR/<id>.json (scripts/journeys/journeys/video/)
  gen_keys.py --list

Every case: a new workspace, the TUI kit's load in each pane (p1, the pane under test, runs `sigwinch`: its header
counts SIGWINCH and reflows), the theme, then the presses as REAL HID keys (ext_rkeys rk_press, CuaDriver) while
the HARNESS recorder films the window at 120 Hz (`require_hz` 120) with the per-frame geometry trace. Each press is
judged from the trace and the movie by judge_keys.py: the step in points and device pixels, the motion's curve, no
jump back, gap or overlap, edges on device pixels, repeats that never queue, one reflow, focus kept, the first moved
frame in the refresh after the key.

The open-p0 line's journey resize-keyboard is case 1 (the single presses of both key sets). rk-splits is the same case
for the KEYS films (P1): only a resize film skips the first-run page (gen_cases.skips_first_run), and an open P0 journey
never does (the page eating Ctrl-` is a product P0 of its own, #34547).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_cases as G  # noqa: E402  (the suite's set-up blocks: theme, first pane, load, after check)

H, J, K, L = (("h", ("control", "shift")), ("j", ("control", "shift")), ("k", ("control", "shift")), ("l", ("control", "shift")))
LEFT, DOWN, UP, RIGHT = (("left", ("control", "cmd")), ("down", ("control", "cmd")), ("up", ("control", "cmd")),
                         ("right", ("control", "cmd")))
NAMES = {H: "Ctrl-Shift-H", J: "Ctrl-Shift-J", K: "Ctrl-Shift-K", L: "Ctrl-Shift-L",
         LEFT: "Ctrl-Cmd-Left", DOWN: "Ctrl-Cmd-Down", UP: "Ctrl-Cmd-Up", RIGHT: "Ctrl-Cmd-Right"}


def press(key, mark, count=1, gap_ms=0, title=None):
    return {"do": "rk_press", "key": key[0], "modifiers": list(key[1]), "count": count, "gap_ms": gap_ms, "mark": mark,
            "title": title or (f"{NAMES[key]} x{count}, {gap_ms} ms apart" if count > 1 else NAMES[key])}


def rest(seconds=0.8):
    # The spring of one press lands in about 0.3 s: 0.8 s keeps each press's motion apart in the film.
    return {"do": "wait", "seconds": seconds, "title": "the motion lands"}


def singles(keys, prefix):
    steps = []
    for i, key in enumerate(keys):
        steps += [press(key, f"{prefix}{i}"), rest()]
    return steps


def panes_note(names, as_):
    return {"do": "rk_panes", "panes": names, "as": as_, "title": f"focus, grid and SIGWINCH count of {', '.join(names)}"}


def focus(pane):
    return {"do": "rk_focus", "pane": pane, "title": f"set-up: focus {pane} (cmux pane focus; the strip reveals it)"}


def after_check(pane):
    """After the motion: the pane under test still has the focus, takes a REAL HID Ctrl-C (its load program ends; a
    debug.key Ctrl-C can go to the "Center" menu item on the tip, STATUS 6209) and shows the echo: app, daemon, frame."""
    return [focus(pane) if pane == "p0" else {"do": "use_pane", "pane": pane, "title": f"after: {pane} is the journey's pane (no click: it keeps the focus)"},
            {"do": "expect", "title": f"after: {pane} still has the focus", "timeout": 5,
             "all": [{"app_rpc": {"method": "debug.focus", "path": "windows.0.model.resolved", "equals": "terminal"}}]},
            G.kit_key("c", ["control"], "ctrlc", f"after: a real HID Ctrl-C ends {pane}'s load program"),
            {"do": "type", "text": "echo rv-done-${nonce}", "enter": True, "mark": "after"},
            {"do": "expect", "title": f"{pane} echoes the line: app, daemon and frame", "since": "after", "timeout": 10,
             "all": [{"daemon_line": "rv-done-${nonce}"}, {"app_text_line": "rv-done-${nonce}"}, {"frame_text": "rv-done-${nonce}"}]}]


CASES = []


def case(cid, title, build, play, notes, seconds, budget=125, jid=None, after="p1", priority="P0"):
    jid = jid or f"rk-{cid}"
    lead = 0
    while lead < len(play) and play[lead]["do"] in ("use_pane", "rk_focus"):
        lead += 1
    steps = [G.theme(True)] + G.first_pane(jid, True) + build(True) + play[:lead] + [G.settle(1.5)]
    steps += [panes_note(notes, "before"),
              {"do": "rpc", "method": "debug.frames", "params": {"action": "start", "raw": True}, "title": "probe: per-frame main thread on"},
              G.kit_record_start(jid, seconds, require_hz=120),
              {"do": "tiers_start", "name": "tiers", "seconds": seconds + 1.0, "title": "probe: the main thread's core tier per ms (ext_tiers, no profiler)"},
              {"do": "wait", "seconds": 0.6, "title": "lead: the recorder's start stall passes before the first key"}]
    steps += play[lead:]
    steps += [G.kit_record_stop(jid, 1.0), {"do": "tiers_stop", "name": "tiers"},
              {"do": "rpc", "method": "debug.frames", "params": {"action": "stop", "raw": True}, "title": "probe: per-frame main thread (raw)"},
              panes_note(notes, "after")]
    steps += after_check(after)
    CASES.append({"id": jid, "priority": priority, "title": title,
                  "why": "cmux-ad 2026-11-02 (P0): \"still dont have pixel perfect ctrl shift hjkl for resizing\". Each key press is "
                         "judged per frame (judge_keys.py): equal steps on device pixels, the declared curve, no jump back, no "
                         "queue, one reflow, focus kept, first frame in the next refresh.",
                  "source": "RESIZE KEYS (handoff/resize-videos/RESIZE-KEYS.md)",
                  "budget_seconds": budget, "options": {"key_path": "real"}, "steps": steps})


def row2(h):
    """p0 | p1 (splitRight); p1 runs sigwinch and has the focus."""
    return G.splits_in_row(2, h)


def row2_down(h):
    """p0 | (p1 over p2): the pane under test p1 has a divider on each axis."""
    return G.splits_in_row(2, h) + G.add_pane(2, "splitDown", h)


def strip(n):
    def build(h):
        steps = []
        for i in range(1, n):
            steps += G.add_pane(i, "newColumn", h)
        return steps
    return build


def rows(h):
    """p0 | (p1 over p2) with p2 a new ROW (rows-v1, newRow), not a split."""
    return G.add_pane(1, "newColumn", h) + G.add_pane(2, "newRow", h)


def browser_agent(h):
    """p0 terminal | p1 browser page (Cmd-Shift-L) over p2 agent chat (palette.newAgentChat)."""
    return (G.splits_in_row(2, h)
            + [{"do": "key", "key": "l", "modifiers": ["cmd", "shift"], "title": "set-up: a browser tab in p1"},
               {"do": "wait", "seconds": 2.0, "title": "set-up: the page shows"}]
            + G.add_pane(2, "splitDown", False)
            + [{"do": "action", "action": "palette.newAgentChat", "title": "set-up: an agent chat in p2"},
               {"do": "wait", "seconds": 2.0, "title": "set-up: the chat shows"}])


# 1. Single presses, both key sets: the open-p0 line's journey.
case("keyboard", "Single presses of Ctrl-Shift-L/H/J/K, then Ctrl-Cmd-Right/Left/Down/Up, on p1 of p0 | (p1 over p2)",
     row2_down, [focus("p1")] + singles([L, H, J, K], "shift") + singles([RIGHT, LEFT, DOWN, UP], "arrow"),
     ["p0", "p1", "p2"], seconds=14, jid="resize-keyboard")
# 1b. The same presses for the KEYS films: a resize film id, so it skips the first-run page (resize-keyboard, an open P0
# journey, meets the page as a person does). P1: the dogfood gate needs every P0 journey to pass, not this film.
case("splits", "Single presses of Ctrl-Shift-L/H/J/K, then Ctrl-Cmd-Right/Left/Down/Up, on p1 of p0 | (p1 over p2) (KEYS films)",
     row2_down, [focus("p1")] + singles([L, H, J, K], "shift") + singles([RIGHT, LEFT, DOWN, UP], "arrow"),
     ["p0", "p1", "p2"], seconds=14, priority="P1")
# 2. Fast alternating presses (H L H L ...): each motion goes on from where it shows.
def alternate(mark, count, gap_ms):
    return {"do": "rk_press", "keys": [{"key": H[0], "modifiers": list(H[1])}, {"key": L[0], "modifiers": list(L[1])}], "count": count,
            "gap_ms": gap_ms, "mark": mark, "title": f"Ctrl-Shift-H, L, H, L ... x{count}, {gap_ms} ms apart"}


case("alternate", "Ctrl-Shift-H and L alternating, 8 presses 70 ms apart, then 8 presses 150 ms apart",
     row2, [focus("p1"), alternate("fast", 8, 70), rest(1.0), alternate("slow", 8, 150), rest(1.0)],
     ["p0", "p1"], seconds=12)
# 3. The limits: Ctrl-Shift-H until p0 is at its minimum width and past it, then L; then the other side.
case("limit", "Ctrl-Shift-H x12 (p0 to its minimum and past it), then L x4; then L x12 and H x4",
     row2, [focus("p1"), press(H, "toMin", 12, 180), rest(0.8), press(L, "backFromMin", 4, 400), rest(0.8),
            press(L, "toMax", 12, 180), rest(0.8), press(H, "backFromMax", 4, 400), rest(0.8)],
     ["p0", "p1"], seconds=24)
# 4. Held key: the app's repeat path for 2 s, then real HID presses at the repeat rate (33 ms) for 2 s.
case("held", "Ctrl-Shift-L held 2 s (debug.key repeat), then Ctrl-Shift-H as real HID presses every 33 ms for 2 s",
     row2, [focus("p1"),
            {"do": "rk_hold", "key": "l", "modifiers": ["control", "shift"], "seconds": 2.0, "mark": "hold", "title": "Ctrl-Shift-L held 2 s"},
            rest(1.2), press(H, "burst", 60, 33, "Ctrl-Shift-H x60 every 33 ms (real HID)"), rest(1.2)],
     ["p0", "p1"], seconds=10)
# 5. Strip columns: 2, 4 and 8 (column width presses).
for n in (2, 4, 8):
    case(f"cols{n}", f"{n} strip columns: Ctrl-Shift-L, H, L, H and Ctrl-Cmd-Right, Left on column p1",
         strip(n), [focus("p1")] + singles([L, H, L, H, RIGHT, LEFT], f"c{n}_"), ["p0", "p1"], seconds=10,
         budget=240 if n == 8 else 125)
# 6. Rows (rows-v1): J and K on a pane in a row of a column.
case("rows", "A column with 2 rows (newRow): Ctrl-Shift-J, K and Ctrl-Cmd-Down, Up on the upper row p1",
     rows, [focus("p1")] + singles([J, K, DOWN, UP], "row"), ["p1", "p2"], seconds=8)
# 7. A terminal under the 12-pane TUI load (3 columns x 4 panes).
case("twelve", "12 panes under load (3 columns x 4): Ctrl-Shift-L, H, J, K on p1 (column 1, pane 2, sigwinch)",
     lambda h: G.columns(3, h, rows=4), [focus("p1")] + singles([L, H, J, K], "t"), ["p0", "p1", "p2"], seconds=8,
     budget=240)
# 8. Browser and agent panes.
case("browser-agent", "Ctrl-Shift-L, H, J, K with a browser page focused (p1), then with an agent chat focused (p2)",
     browser_agent, [focus("p1")] + singles([L, H, J, K], "page") + [focus("p2")] + singles([L, H, J, K], "chat"),
     ["p0"], seconds=16, budget=180, after="p0")

# 9. K3 cause (STATUS 6884): xctrace Time Profiler on the app clock (xtp_align.py), browser page + agent chat, no recorder.
def xtp_browser_agent():
    jid = "rk-xtpa-browser-agent"
    steps = [G.theme(True)] + G.first_pane(jid, False) + browser_agent(False) + [focus("p1"), G.settle(1.5),
              {"do": "trace_only_start", "name": "close", "title": "the geometry trace (display-link ticks), no recorder"},
              {"do": "xtp_start", "name": "xtp", "seconds": 5.0, "wait_first_sample": True, "first_sample_wait": 1.0,
               "title": "xctrace Time Profiler on the app"},
              {"do": "rpc", "method": "debug.stall", "params": {"ms": 60}, "title": "clock mark: a 60 ms main-thread stall"},
              {"do": "wait", "seconds": 0.5, "title": "the mark's frames pass"}]
    for i, key in enumerate([L, H, L, H]):
        steps += [G.kit_key(key[0], list(key[1]), f"close{i}" if i == 0 else f"k{i}", NAMES[key]), rest(0.6)]
    steps += [{"do": "trace_only_stop", "name": "close"}, {"do": "xtp_stop", "name": "xtp"}] + after_check("p0")
    CASES.append({"id": jid, "priority": "P1", "title": "xctrace, app clock: Ctrl-Shift-L, H, L, H with a browser page and an agent chat (K3 cause)",
                  "why": "RESIZE KEYS K3: horizontal presses lose 5-8 refreshes with a page and a chat in the moving column.",
                  "source": "RESIZE KEYS", "budget_seconds": 200, "options": {"key_path": "real"}, "steps": steps})


xtp_browser_agent()


# 10. First press and idle presses (lead 23:2xZ): the first press of a round moved 1.44-1.46 refreshes late in fix-2 films.
# L H L H L H, each after 2.5 s of idle, so the main thread is asleep before every press (STATUS 7770: a woken main thread
# starts on E cores). Late only on the first press: a first-use cost. Late on every press: the E-core start.
def idle_presses(prefix):
    steps = []
    for i, key in enumerate([L, H, L, H, L, H]):
        steps += [press(key, f"{prefix}{i}"), {"do": "wait", "seconds": 2.5, "title": "idle 2.5 s: the main thread sleeps"}]
    return steps


case("idle", "Ctrl-Shift-L, H, L, H, L, H on a browser page (p1), each after 2.5 s of idle: the first press against later idle presses",
     browser_agent, [focus("p1")] + idle_presses("idle"), ["p0"], seconds=18, budget=200, after="p0")


def xtp_idle():
    jid = "rk-xtpa-idle"
    steps = [G.theme(True)] + G.first_pane(jid, False) + browser_agent(False) + [focus("p1"), G.settle(1.5),
              {"do": "trace_only_start", "name": "close", "title": "the geometry trace (display-link ticks), no recorder"},
              {"do": "tiers_start", "name": "tiers", "seconds": 19.0, "title": "probe: the main thread's core tier per ms"},
              {"do": "xtp_start", "name": "xtp", "seconds": 18.0, "wait_first_sample": True, "first_sample_wait": 1.0,
               "title": "xctrace Time Profiler on the app"},
              {"do": "rpc", "method": "debug.stall", "params": {"ms": 60}, "title": "clock mark: a 60 ms main-thread stall"},
              {"do": "wait", "seconds": 2.5, "title": "idle 2.5 s after the mark: the main thread sleeps"}]
    for i, key in enumerate([L, H, L, H, L, H]):
        steps += [G.kit_key(key[0], list(key[1]), f"close{i}" if i == 0 else f"k{i}", NAMES[key]),
                  {"do": "wait", "seconds": 2.5, "title": "idle 2.5 s: the main thread sleeps"}]
    steps += [{"do": "trace_only_stop", "name": "close"}, {"do": "xtp_stop", "name": "xtp"}, {"do": "tiers_stop", "name": "tiers"}] + after_check("p0")
    CASES.append({"id": jid, "priority": "P1", "title": "xctrace and core tiers, app clock: L, H, L, H, L, H on a browser page, each after 2.5 s of idle",
                  "why": "RESIZE KEYS: the first press of a round moves 1.44-1.46 refreshes late; name the items of its key turn.",
                  "source": "RESIZE KEYS", "budget_seconds": 240, "options": {"key_path": "real"}, "steps": steps})


xtp_idle()


# 11. Mouse divider drags with the core tier probe (lead 2026-11-03 01:3xZ, Lawrence: "resizing columns and splits is still
# not very good"): the RESIZE VIDEOS drag journeys (gen_cases.py: rv-col-drag-*, rv-row-drag-*), each with ext_tiers around
# its recording, as rkd-<case> so a build's keyboard and drag films sit together with start tiers.
DRAG_SOURCES = ["rv-col-drag-2-heavy-dark", "rv-col-drag-3-heavy-dark", "rv-col-drag-6-heavy-dark", "rv-col-drag-clamp-heavy-dark",
                "rv-row-drag-slow-heavy-dark", "rv-row-drag-fast-heavy-dark", "rv-row-drag-clamp-heavy-dark"]


def tiered_drags(journeys_dir):
    out = []
    for src in DRAG_SOURCES:
        path = os.path.join(journeys_dir, src + ".json")
        if not os.path.isfile(path):
            continue
        j = json.load(open(path))
        steps = []
        for st in j["steps"]:
            steps.append(st)
            if st.get("do") == "video_start":
                steps.append({"do": "tiers_start", "name": "tiers", "seconds": float(st.get("seconds", 20)) + 1.0,
                              "title": "probe: the main thread's core tier per ms (ext_tiers, no profiler)"})
            if st.get("do") == "video_stop":
                steps.append({"do": "tiers_stop", "name": "tiers"})
        rid = "rkd-" + src[len("rv-"):]
        if src == "rv-col-drag-6-heavy-dark":
            # Six panes across need 6 x 200 pt (layout.minimumPaneWidth) plus 5 gaps: the 90% window leaves 1153 pt of
            # content beside the sidebar on the 1512 pt 2x display, room for 5. The full-width window leaves 1304 pt.
            for st in steps:
                if st.get("do") == "window_place":
                    st["fraction"] = [0.0, 0.05, 1.0, 0.9]
                    st["title"] = "set-up: the window at the full screen width x 90% (six panes of 200 pt need 1235 pt beside the sidebar)"
        for st in steps:
            if st.get("do") in ("video_start", "video_stop") and st.get("name") == src:
                st["name"] = rid
                st["title"] = st.get("title", "").replace(src, rid)
        j = dict(j, id=rid, steps=steps, source="RESIZE KEYS (drag with core tiers), from " + src)
        out.append(j)
        if src in ("rv-col-drag-2-heavy-dark", "rv-row-drag-slow-heavy-dark"):
            # The drag start (lead 03:3xZ): 91-99 ms from the app's mouse-down to the first moved frame with the main
            # thread idle. The same drags with CuaDriver's hold before the first move set to 0 (hold_ms): a start that
            # follows the hold is the injector's, one that stays is the app's.
            hid = json.loads(json.dumps(dict(j, id=rid.replace("rkd-", "rkd-hold0-"))).replace(rid, rid.replace("rkd-", "rkd-hold0-")))
            for st in hid["steps"]:
                if st.get("do") == "hid_drag":
                    st["hold_ms"] = 0
            out.append(hid)
        if src == "rv-col-drag-3-heavy-dark":
            # The same case with a probe of the grab point before each drag (lead 03:2xZ): the drag reached the app
            # with no mouse event on cmux21 and cmux18.
            psteps = []
            for k, st in enumerate(steps):
                if st.get("do") == "hid_drag":
                    psteps.append({"do": "rk_probe_point", "name": "probe" + "abcdefghij"[sum(1 for x in psteps if x.get("do") == "rk_probe_point")], "target": st["target"],
                                   "title": "probe: the grab point, the windows and the element there"})
                    psteps.append(st)
                else:
                    psteps.append(st)
            pid = rid.replace("rkd-", "rkd-probe-")
            pj = json.loads(json.dumps(dict(j, id=pid, steps=psteps)).replace(rid, pid))
            out.append(pj)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out")
    ap.add_argument("--only", action="append", default=[])
    ap.add_argument("--list", action="store_true")
    opts = ap.parse_args()
    chosen = [c for c in CASES if not opts.only or c["id"] in opts.only]
    if opts.list or not opts.out:
        for c in chosen:
            print(f"{c['id']:24} {c['budget_seconds']:4} {c['title']}")
        return 0
    os.makedirs(opts.out, exist_ok=True)
    chosen += [d for d in tiered_drags(opts.out) if not opts.only or d["id"] in opts.only]
    for c in chosen:
        with open(os.path.join(opts.out, c["id"] + ".json"), "w") as f:
            json.dump(c, f, indent=1)
            f.write("\n")
    print(f"{len(chosen)} cases in {opts.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
