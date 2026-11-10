#!/usr/bin/env python3
"""NIGHTLY REGRESSION (m85 b, m87): writes the scroll journeys and the big-session Cmd-T journeys into the kit worktree.
Each scroll burst is one sample: debug.frames start, 120 synthesized scroll events at about 120 Hz (wheel: no phase;
trackpad: began/changed/ended), debug.frames stop. The stop step's title is 'SCROLL <label> <i>' (scroll_summary.py).
  gen_journeys.py [KIT_JOURNEYS_PERF_DIR]"""
import json, os, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "/work/wt/claude-worktrees/nightly-regression-kit/scripts/journeys/journeys/perf"
WHY = ("NIGHTLY REGRESSION cmux-ad m85/m86/m87 (2026-11-10): terminal scroll A/B of nightly ffffff979a1a vs 85b099928a8a "
       "and the 5-point bisect; same journeys for GHOSTTY INTEGRATION. Fleet minis only.")
EVENTS, INTERVAL = 120, 0.008
BIG = {"do": "grow_workspaces", "count": 60, "busy": 0, "settle": 3,
       "title": "big session: 60 workspaces (one terminal each), no busy output (m87: the state-size loop)"}

def burst(label, i, kind, dy):
    steps = [{"do": "rpc", "method": "debug.surfaces", "params": {}, "title": f"SURF0 {label} {i}"},
             {"do": "rpc", "method": "debug.frames", "params": {"action": "start"}, "title": f"frames start {label} {i}"}]
    if kind == "wheel":
        steps.append({"do": "mouse", "action": "scroll", "dy": dy, "hover": False, "count": EVENTS, "interval": INTERVAL,
                      "title": f"wheel {label} {i}"})
    else:
        steps += [
            {"do": "mouse", "action": "scroll", "dy": 0, "phase": "began", "hover": False, "title": f"trackpad began {label} {i}"},
            {"do": "mouse", "action": "scroll", "dy": dy, "phase": "changed", "hover": False, "count": EVENTS - 2,
             "interval": INTERVAL, "title": f"trackpad changed {label} {i}"},
            {"do": "mouse", "action": "scroll", "dy": 0, "phase": "ended", "hover": False, "title": f"trackpad ended {label} {i}"},
        ]
    steps.append({"do": "rpc", "method": "debug.frames", "params": {"action": "stop", "raw": True}, "title": f"SCROLL {label} {i}"})
    # Ghostty's own frames in the burst: the render_counters delta of the scrolled pane (outside the measured span).
    steps.append({"do": "rpc", "method": "debug.surfaces", "params": {}, "title": f"SURF1 {label} {i}"})
    return steps

def offmain(label, kind, dy):
    """Not measured: a debug.motion trace of the terminal sampler during one burst (the sampler costs main time per frame).
    Its rows carry Ghostty's frames and host_off_main_presents: frames that rise with 0 off-main presents mean the surface
    is main-routed (S-P3)."""
    ev = {"do": "mouse", "action": "scroll", "dy": dy, "hover": False, "count": 60, "interval": INTERVAL, "title": f"offmain {kind} {label}"}
    if kind == "trackpad":
        ev["phase"] = "changed"
    return [{"do": "rpc", "method": "debug.motion", "params": {"action": "trace_start", "targets": ["terminal"]}, "title": f"trace start {label}"},
            ev,
            {"do": "rpc", "method": "debug.motion", "params": {"action": "trace_stop"}, "title": f"OFFMAIN {label} 1"}]

def bursts(label, kind, n, step_dy, alternate=True):
    out = []
    for i in range(n):
        sign = (1 if i % 2 == 0 else -1) if alternate else 1
        out += burst(label, i + 1, kind, step_dy * sign)
    return out

def idle_frames(label, n, seconds=2):
    out = []
    for i in range(n):
        out += [{"do": "rpc", "method": "debug.frames", "params": {"action": "start"}, "title": f"frames start {label} {i+1}"},
                {"do": "wait", "seconds": seconds, "title": f"output only {label} {i+1}"},
                {"do": "rpc", "method": "debug.frames", "params": {"action": "stop", "raw": True}, "title": f"SCROLL {label} {i+1}"}]
    return out

TAIL = [
    {"do": "rpc", "method": "debug.action_budget", "params": {"limit": 64}, "title": "action budget"},
    {"do": "type", "text": "clear; echo scrolljr-${nonce}", "enter": True,
     "title": "set-up check: the app still types (its result does not decide the numbers)"},
    {"do": "expect", "title": "the app still types into the base terminal", "timeout": 15,
     "all": [{"pane_frame_text": "scrolljr-${nonce}"}, {"daemon_contains": "scrolljr-${nonce}"},
             {"app_text_contains": "scrolljr-${nonce}"}]},
]

def head(big):
    return [{"do": "wait", "seconds": 3, "title": "the fresh profile's first window"}] + ([BIG] if big else []) + [
        {"do": "base_terminal", "title": "the focused terminal the journey scrolls"},
        {"do": "neutral_prompt"},
    ]

def fill(name):
    return [
        {"do": "type", "text": f"seq -f 'L%06g-${{nonce}}' 1 50000 | tee /tmp/{name}-${{nonce}}.txt", "enter": True,
         "mark": "fill", "title": "50k lines of scrollback (and the same file for less and vim)"},
        {"do": "expect", "title": "the 50k lines arrived and the prompt is back", "since": "fill", "timeout": 90,
         "all": [{"daemon_line": "L050000-${nonce}"}, {"daemon_prompt": True}]},
        {"do": "mouse", "action": "move", "title": "the pointer over the pane, once (the bursts send hover: false)"},
    ]

def zsh(big):
    sfx = "-big" if big else ""
    steps = head(big) + fill("scrolljr") + [
        {"do": "mouse", "action": "scroll", "dy": 40, "count": 10, "interval": 0.02, "title": "start scrolled back (not at the top)"},
    ]
    steps += bursts(f"zsh-wheel{sfx}", "wheel", 20, 12)
    steps += bursts(f"zsh-trackpad{sfx}", "trackpad", 20, 6)
    steps += offmain(f"zsh-wheel{sfx}", "wheel", 12)
    steps += [
        {"do": "key", "key": "end", "modifiers": ["cmd"], "title": "to the bottom"},
        {"do": "type", "text": "for i in $(seq 1 1200); do seq -f \"O%05g-${nonce}\" 1 20; sleep 0.02; done; echo STREAMDONE-${nonce}",
         "enter": True, "mark": "stream", "title": "output streaming (20 lines per 20 ms, about 30 s)"},
        {"do": "wait", "seconds": 1, "title": "the stream runs"},
    ]
    steps += idle_frames(f"zsh-stream-bottom{sfx}", 3)
    steps += [{"do": "mouse", "action": "scroll", "dy": 40, "count": 10, "interval": 0.02, "title": "scroll back while it streams"}]
    steps += bursts(f"zsh-stream-scrolled-wheel{sfx}", "wheel", 10, 12)
    steps += bursts(f"zsh-stream-scrolled-trackpad{sfx}", "trackpad", 6, 6)
    steps += offmain(f"zsh-stream-scrolled{sfx}", "wheel", 12)
    steps += [
        {"do": "expect", "title": "the stream ended", "since": "stream", "timeout": 60, "all": [{"daemon_line": "STREAMDONE-${nonce}"}]},
        {"do": "key", "key": "end", "modifiers": ["cmd"], "title": "to the bottom"},
    ] + TAIL
    return {"id": f"scroll-zsh{sfx}", "priority": "P2",
            "title": f"SCROLL zsh{' (big session)' if big else ''}: per-frame time and missed 120 Hz refreshes while wheel and trackpad scroll 50k lines of scrollback, and while output streams (at the bottom and scrolled back)",
            "why": WHY, "source": "debug.mouse scroll (phase = trackpad) + debug.frames start/stop raw",
            "budget_seconds": 250 if big else 200, "steps": steps}

def tui(big):
    sfx = "-big" if big else ""
    f = "/tmp/scrolltui-${nonce}.txt"
    steps = head(big) + fill("scrolltui") + [
        {"do": "type", "text": f"clear; less {f}", "enter": True, "mark": "less", "title": "less on the 50k-line file"},
        {"do": "expect", "title": "less shows the file's first rows", "since": "less", "timeout": 15,
         "all": [{"pane_frame_text": "L000002-${nonce}"}]},
    ]
    steps += bursts(f"less-wheel{sfx}", "wheel", 12, -12, alternate=False)
    steps += bursts(f"less-trackpad{sfx}", "trackpad", 12, -6, alternate=False)
    steps += offmain(f"less{sfx}", "wheel", -12)
    steps += [
        {"do": "type", "text": "q", "enter": False, "title": "quit less"},
        {"do": "wait", "seconds": 1, "title": "less quit"},
        {"do": "type", "text": f"clear; \"$(command -v nvim || command -v vim)\" -u NONE -R -c 'set mouse=a' {f}", "enter": True,
         "mark": "vim", "title": "nvim (vim when the mini has no nvim) on the file, mouse on"},
        {"do": "expect", "title": "the editor shows the file's first rows", "since": "vim", "timeout": 15,
         "all": [{"pane_frame_text": "L000002-${nonce}"}]},
    ]
    steps += bursts(f"vim-wheel{sfx}", "wheel", 12, -12, alternate=False)
    steps += bursts(f"vim-trackpad{sfx}", "trackpad", 12, -6, alternate=False)
    steps += offmain(f"vim{sfx}", "wheel", -12)
    steps += [{"do": "key", "key": "escape", "modifiers": [], "title": "editor normal mode"},
              {"do": "type", "text": ":qa!", "enter": True, "title": "quit the editor"},
              {"do": "wait", "seconds": 1, "title": "the editor quit"}] + TAIL
    return {"id": f"scroll-tui{sfx}", "priority": "P2",
            "title": f"SCROLL less and nvim/vim{' (big session)' if big else ''}: per-frame time and missed 120 Hz refreshes while wheel and trackpad scroll a 50k-line file in full-screen programs",
            "why": WHY, "source": "debug.mouse scroll (phase = trackpad) + debug.frames start/stop raw",
            "budget_seconds": 250 if big else 200, "steps": steps}

def cmdt_big(eng):
    spec = json.load(open(os.path.join(OUT, f"cmdt-latency-{eng}.json")))
    spec["id"] += "-big"
    spec["title"] = spec["title"].replace("light", "big session (60 workspaces, no busy output; m87)")
    steps = spec["steps"]
    at = next(i for i, s in enumerate(steps) if s["do"] == "base_terminal")
    steps.insert(at, dict(BIG))
    for s in steps:
        if s.get("do") == "latency_runs":
            s["label"] += "-big"
    spec["budget_seconds"] = 255
    return spec

for spec in (zsh(False), zsh(True), tui(False), tui(True), cmdt_big("cef"), cmdt_big("webkit")):
    with open(os.path.join(OUT, spec["id"] + ".json"), "w") as fh:
        json.dump(spec, fh, indent=1); fh.write("\n")
    print(spec["id"], len(spec["steps"]), "steps")
