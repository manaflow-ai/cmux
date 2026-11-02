#!/usr/bin/env python3
"""Writes the focus and input routing journeys (VIDEO EXTRA item 5) into journeys/dogfood/routing-*.json.

    python3 scripts/journeys/routing/gen.py [--attempts 4] [--check]

Each journey plays one routing case a person meets (lead 2026-11-02 00:29Z): an action that moves the focus, then
at once a unique marker line by real HID keys (journey option key_path=real; smoke_type_now), then routing_marker
(ext_routing.py): the line ran on exactly the expected terminal and no other, and the app shows it in that pane.
Run them on a whole-host lease (run.py --whole-host) of a CuaDriver-granted mini; the RESIZE VIDEOS kit records the
screen video around them. --check exits 1 when a written file differs from what this script makes.
"""
import argparse
import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "journeys" / "dogfood"
HEAD = [{"do": "smoke_ready", "timeout": 60}, {"do": "env_windows", "at": "start"}, {"do": "smoke_remember_workspaces"},
        {"do": "smoke_make_key"}]
FINALLY = [{"do": "video_close_open", "title": "stop a recording a failed check left open (its movie is the evidence)"},
           {"do": "env_windows", "at": "end", "title": "host dialogs at the end (SMOKE ENV mark)"},
           {"do": "rpc", "method": "debug.focus", "title": "the focus and key-hold state at the end (records only)"},
           {"do": "app_log", "seconds": 90, "grep": "newTab|closeTab|creation.hold|focus|firstResponder|keyRouter",
            "title": "the app log of the last 90 s (records only)"},
           {"do": "smoke_close_all"}]


def marker(case, n):
    """The line a marker command prints: R<case><n>-<nonce>-42 (the typed command is `echo R..-$((6*7))`, so only
    the command's OUTPUT is the line: it proves the line ran in that shell, not only that its keys were echoed)."""
    return f"R{case}{n}-${{nonce}}", f"R{case}{n}-${{nonce}}-42"


def type_now(case, n):
    text, _line = marker(case, n)
    return {"do": "routing_type_now", "text": f"echo {text}-$((6*7))"}


def check(case, n, on, title, since, extra=(), shown=True, **marker_opts):
    """SHOWN false: the line's workspace is no longer on screen when it is judged (H1, H2: two more Cmd-N came after),
    so neither the app's viewport nor the frame can show it; the daemon verdict and "no shown pane has it" stay."""
    _text, line = marker(case, n)
    if not shown:
        marker_opts = dict(marker_opts, app_shown=False)
    return {"do": "expect", "title": title, "since": since, "timeout": 20,
            "all": [{"routing_marker": dict({"line": line, "on": on, "attempt": f"{case}{n}"}, **marker_opts)},
                    {"smoke_key_window": {}},
                    *([{"frame_screen": {"shows": [line]}}] if shown else []), *extra]}


def home_terminal(name, tag):
    """A new workspace (Cmd-N) with one terminal (Ctrl-`) that ran `echo <tag>-<nonce>`, named NAME (set-up: typed
    after the creation hold (outwait_hold), checked, then named)."""
    line = f"{tag}-${{nonce}}"
    return [
        {"do": "smoke_key", "key": "n", "modifiers": ["cmd"], "mark": f"setup-{name}-ws"},
        {"do": "expect", "title": f"set-up: Cmd-N makes the workspace of {name}", "since": f"setup-{name}-ws",
         "timeout": 20, "all": [{"smoke_frame": {}}]},
        {"do": "smoke_key", "key": "`", "modifiers": ["control"], "mark": f"setup-{name}"},
        {"do": "outwait_hold"},
        {"do": "smoke_type", "text": f"echo {tag}-${{nonce}}", "enter": True},
        {"do": "expect", "title": f"set-up: the terminal of {name} ran its line", "since": f"setup-{name}",
         "timeout": 30, "all": [{"smoke_daemon_lines": {"lines": [line]}}]},
        {"do": "smoke_adopt_line", "line": line, "as": name},
    ]


def split_terminal(name, tag, key="d", mods=("cmd",)):
    line = f"{tag}-${{nonce}}"
    return [
        {"do": "smoke_key", "key": key, "modifiers": list(mods), "mark": f"setup-{name}"},
        {"do": "outwait_hold"},
        {"do": "smoke_type", "text": f"echo {tag}-${{nonce}}", "enter": True},
        {"do": "expect", "title": f"set-up: the split terminal of {name} ran its line", "since": f"setup-{name}",
         "timeout": 30, "all": [{"smoke_daemon_lines": {"lines": [line]}}]},
        {"do": "smoke_adopt_line", "line": line, "as": name},
    ]


FILM = True  # main() sets it: --no-film writes the -nf journeys (same attempts, no recording; app-state verdicts)


def filmed(case, n, attempt_steps):
    """One attempt inside its own recording (ext_video, the HARNESS kit: debug.motion record_*): the action, the
    marker line and the check. The movie is routing-<case><n>.mov; geometry and content only (no pacing claim), so
    no require_hz."""
    name = f"routing-{case.lower()}{n}"  # run.py fetches only lowercase movie names (VIDEO_FILE)
    if not FILM:
        return attempt_steps
    return [{"do": "video_start", "name": name, "seconds": 40}] + attempt_steps + \
        [{"do": "video_stop", "name": name, "tail": 0.6}]


def journey(ident, title, why, steps, budget, key_path="real"):
    """KEY_PATH "real": real HID keys (CuaDriver); "debug.key": the app's debug.key, the smoke gate's own key path in
    its debug.key rounds (the -dk journeys: no CuaDriver, so any mini)."""
    if not FILM:
        ident, title = ident + "-nf", title + " (no film: the verdict is the app's and the daemon's state)"
    # Each filmed attempt adds the recorder's start (frames must come), its 0.6 s tail and the file write.
    budget += 12 * sum(1 for st in steps if st.get("do") == "video_start")
    return {"id": ident, "priority": "P1", "title": title, "why": why,
            "source": "VIDEO EXTRA item 5, focus and input routing (lead 2026-11-02 00:29Z; STATUS 4271, 4283)",
            "budget_seconds": budget, "options": {"key_path": "real"} if key_path == "real" else {},
            "continue_not_judged": True,
            "finally": FINALLY, "steps": HEAD + steps}


def cases(attempts):
    out = []
    # A. Cmd-N, then Ctrl-` when the workspace shows, then the line at once (the smoke gate's step; #29530, #30827).
    steps = []
    for n in range(1, attempts + 1):
        steps += [{"do": "smoke_snapshot", "name": f"a{n}"}] + filmed("A", n, [
                  {"do": "smoke_key", "key": "n", "modifiers": ["cmd"], "mark": f"a{n}-ws"},
                  {"do": "expect", "title": f"A{n}: Cmd-N shows its workspace", "since": f"a{n}-ws", "timeout": 20,
                   "all": [{"smoke_workspaces": {"new": n}}, {"smoke_frame": {}}]},
                  {"do": "smoke_key", "key": "`", "modifiers": ["control"], "mark": f"a{n}"},
                  type_now("A", n),
                  check("A", n, f"new:a{n}", f"A{n}: the line typed at once after Ctrl-` ran in the new terminal only",
                        f"a{n}", in_new_workspace=True)])
    out.append(journey("routing-cmdn-ctrlbt", "Routing A: Cmd-N, Ctrl-` when the workspace shows, then a line at once: "
                       "it runs in the new terminal only", "P0 #29530 / #30827 (dogfood #30271): the keys went to the "
                       "New Tab page or nowhere", steps, 40 + 25 * attempts))
    # B. Cmd-N and Ctrl-` with no wait between them, then the line at once (the race the creation hold covers).
    steps = []
    for n in range(1, attempts + 1):
        steps += [{"do": "smoke_snapshot", "name": f"b{n}"}] + filmed("B", n, [
                  {"do": "smoke_key", "key": "n", "modifiers": ["cmd"], "mark": f"b{n}-ws"},
                  {"do": "smoke_key", "key": "`", "modifiers": ["control"], "mark": f"b{n}"},
                  type_now("B", n),
                  check("B", n, f"new:b{n}", f"B{n}: Cmd-N, Ctrl-` and the line all at once: the line ran in the new "
                        "terminal only", f"b{n}", extra=({"smoke_workspaces": {"new": n}},), in_new_workspace=True)])
    out.append(journey("routing-cmdn-ctrlbt-at-once", "Routing B: Cmd-N, Ctrl-` and a line with no wait: the line runs "
                       "in the new terminal only", "P0 #29530 (Cmd-N's New Tab hold took Ctrl-`), #30827", steps,
                       40 + 20 * attempts))
    # C. Cmd-D, then the line at once: the new right pane gets it.
    steps = home_terminal("c0", "c0home")
    for n in range(1, attempts + 1):
        steps += [{"do": "smoke_snapshot", "name": f"c{n}"}] + filmed("C", n, [
                  {"do": "smoke_key", "key": "d", "modifiers": ["cmd"] if n % 2 else ["cmd", "shift"], "mark": f"c{n}"},
                  type_now("C", n),
                  check("C", n, f"new:c{n}", f"C{n}: Cmd-{'D' if n % 2 else 'Shift-D'} then a line at once: it ran "
                        "in the new pane only", f"c{n}")])
    out.append(journey("routing-split", "Routing C: Cmd-D / Cmd-Shift-D, then a line at once: it runs in the new pane "
                       "only", "P0 1193 (Cmd-D twice, keys to the wrong new terminal), #29262", steps,
                       80 + 20 * attempts))
    # D. Cmd-W closes the focused pane; the line at once goes to the pane the app focuses next (shown focused).
    steps = home_terminal("d0", "d0home") + split_terminal("d1", "d1home") + split_terminal("d2", "d2home")
    steps += filmed("D", 1, [{"do": "smoke_key", "key": "w", "modifiers": ["cmd"], "mark": "d1"},
                             type_now("D", 1),
                             check("D", 1, "focused", "D1: Cmd-W closes the right pane; the line at once runs in the "
                                   "pane the app shows focused, and only there", "d1")])
    steps += filmed("D", 2, [{"do": "smoke_key", "key": "w", "modifiers": ["cmd"], "mark": "d2"},
                             type_now("D", 2),
                             check("D", 2, "focused", "D2: Cmd-W again; the line at once runs in the focused pane only",
                                   "d2")])
    out.append(journey("routing-close", "Routing D: Cmd-W closes a pane, then a line at once: it runs in the pane the "
                       "app shows focused", "wrong-pane typing after a close (focus moved during the close animation)",
                       steps, 150))
    # E. A click into the old pane while the split animates, then the line at once: the clicked pane gets it.
    steps = []
    for n in range(1, attempts + 1):
        # Each attempt in its own new workspace (review N4 at 2d05ea3072e): one pane, then one split, so the clicked
        # pane never shrinks below the minimum width and never moves to a new column.
        steps += home_terminal(f"e{n}0", f"e{n}0home")
        steps += filmed("E", n, [
                  {"do": "smoke_key", "key": "d", "modifiers": ["cmd"], "mark": f"e{n}-split"},
                  {"do": "routing_click", "pane": f"e{n}0", "mark": f"e{n}"},
                  type_now("E", n),
                  check("E", n, f"e{n}0", f"E{n}: Cmd-D, a click into the first pane during the split animation, then "
                        "a line at once: it ran in the clicked pane only", f"e{n}")])
    out.append(journey("routing-click-during-split", "Routing E: a click into a pane while a split animates, then a "
                       "line at once: it runs in the clicked pane", "#29262 (only the pane AppKit gives a press to "
                       "takes the focus); the creation hold must not keep keys a click sent elsewhere", steps,
                       30 + 45 * attempts))
    # F. Cmd-1..9 switches workspaces; the line at once runs in the shown workspace's focused terminal.
    steps = home_terminal("f1", "f1home") + home_terminal("f2", "f2home")
    steps += [{"do": "routing_map_workspace_keys", "names": ["f1", "f2"]}]
    for n in range(1, attempts + 1):
        target = "f1" if n % 2 else "f2"
        steps += filmed("F", n, [
                  {"do": "routing_select_workspace", "pane": target, "mark": f"f{n}"},
                  type_now("F", n),
                  check("F", n, target, f"F{n}: Cmd-<number> to the workspace of {target}, then a line at once: it "
                        f"ran in {target} only", f"f{n}")])
    out.append(journey("routing-switch-workspace", "Routing F: Cmd-1..9 workspace switch, then a line at once: it runs "
                       "in the shown workspace's terminal", "wrong-pane typing after a switch (keys to the old "
                       "workspace's terminal)", steps, 130 + 15 * attempts))
    # G. Shift-Cmd-[ / ] switches tabs in a pane; the line at once runs in the selected tab.
    steps = home_terminal("g1", "g1home") + split_terminal("g2", "g2home", key="`", mods=("control",))
    for n in range(1, attempts + 1):
        target, key = ("g1", "[") if n % 2 else ("g2", "]")
        steps += filmed("G", n, [
                  {"do": "smoke_key", "key": key, "modifiers": ["cmd", "shift"], "mark": f"g{n}"},
                  type_now("G", n),
                  check("G", n, target, f"G{n}: Shift-Cmd-{key} to the tab of {target}, then a line at once: it ran "
                        f"in {target} only", f"g{n}")])
    out.append(journey("routing-switch-tab", "Routing G: tab switch in a pane (Shift-Cmd-[ and ]), then a line at "
                       "once: it runs in the selected tab", "wrong-pane typing after a tab switch", steps,
                       100 + 15 * attempts))
    # H. The smoke gate's own sequence (steps 4-16 of smoke-dogfood.json, the 1-in-7 rate of STATUS 4124/4288): three
    # times Cmd-N, Ctrl-` as soon as the workspace shows, the line at once; judged after the third, each line on
    # exactly its own new terminal.
    seq = []
    for n in range(1, 4):
        seq += [{"do": "smoke_snapshot", "name": f"h{n}"},
                  {"do": "smoke_key", "key": "n", "modifiers": ["cmd"], "mark": f"h{n}-ws"},
                  {"do": "expect", "title": f"H{n}: Cmd-N shows its workspace", "since": f"h{n}-ws", "timeout": 20,
                   "all": [{"smoke_workspaces": {"new": n}}, {"smoke_frame": {}}]},
                  {"do": "smoke_key", "key": "`", "modifiers": ["control"], "mark": f"h{n}"},
                  type_now("H", n)]
    # The movie covers the whole race (review note 5 at 2264f21c0cf); each check is its own expect, judged after all
    # three lines (a red on one check ends the journey: the tally shows the first red line of a run).
    steps = filmed("H", 0, seq + [check("H", n, f"new:h{n}..h{n + 1}" if n < 3 else "new:h3",
                                   f"H{n}: the line typed at once after Ctrl-` {n} of 3 ran in its new terminal only",
                                   "h1", in_new_workspace=True, shown=n == 3) for n in range(1, 4)])
    out.append(journey("routing-smoke-seq", "Routing H: the smoke gate's sequence, 3 x (Cmd-N, Ctrl-`, a line at once); "
                       "each line runs in its own new terminal", "the 1-in-7 failure of smoke step 16 before #30827 "
                       "(STATUS 4124, 4288)", steps, 120))
    # H-dk: the same sequence on debug.key, the key path of the smoke gate round that saw the held Ctrl-` (STATUS
    # 3967, round 2): real HID keys take 100+ ms a call, so the B and H rounds may type too slowly to meet the race.
    out.append(journey("routing-smoke-seq-dk", "Routing H-dk: the smoke gate's sequence on debug.key, 3 x (Cmd-N, "
                       "Ctrl-`, a line at once); each line runs in its own new terminal", "the 1-in-7 held Ctrl-` of "
                       "smoke step 12/16 before #30827 came in a debug.key round (STATUS 3967)", steps, 120,
                       key_path="debug.key"))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--attempts", type=int, default=4)
    ap.add_argument("--check", action="store_true")
    opts = ap.parse_args()
    global FILM
    bad = 0
    specs = []
    for film in (True, False):
        FILM = film
        specs += cases(opts.attempts)
    for spec in specs:
        path = OUT / f"{spec['id']}.json"
        text = json.dumps(spec, indent=2, ensure_ascii=False) + "\n"
        if opts.check:
            if not path.is_file() or path.read_text() != text:
                print(f"differs: {path}")
                bad = 1
            continue
        path.write_text(text)
        print(f"wrote {path} ({len(spec['steps'])} steps)")
    return bad


if __name__ == "__main__":
    sys.exit(main())
