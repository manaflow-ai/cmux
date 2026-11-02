#!/usr/bin/env python3
"""Writes the TYPING UNDER LOAD journeys (Lawrence P0, 2026-11-02) into journeys/video/typing-load-*.json.

    python3 scripts/journeys/typing/gen_load.py [--check]

One journey per load profile (L0 = no load, L1 CLI storm, L2 MCP storm, L3 browser, L4 agents, L5 12-pane HEAVY
TUI, L6 all; the 15 GB hog is run.py --hog-swap-gb on top), filmed (HARNESS recorder, two 60 s movies) and an -nf copy
(no recorder: in-app marks, echo and keys_check only). Each: a new workspace and terminal named `typing`, echo.py in
it, the load around it (load_profiles.py --keep typing), then the seeded 2-minute typist (typist_play) in two
halves, then the load stops. Judges: typing/keys_check.py (order, lost, merged, PTY arrival) and the video judge.
"""
import argparse
import json
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "journeys" / "video"
PROFILES = ("L0", "L1", "L2", "L3", "L4", "L5", "L6")
SEED = 7


def steps(profile, film):
    s = [{"do": "smoke_ready", "timeout": 60}, {"do": "env_windows", "at": "start"},
         {"do": "smoke_remember_workspaces"}, {"do": "smoke_make_key"},
         {"do": "smoke_key", "key": "n", "modifiers": ["cmd"], "mark": "ws"},
         {"do": "expect", "title": "set-up: Cmd-N makes the typing workspace", "since": "ws", "timeout": 20,
          "all": [{"smoke_workspaces": {"new": 1}}, {"smoke_frame": {}}]},
         {"do": "smoke_key", "key": "`", "modifiers": ["control"], "mark": "term"},
         {"do": "outwait_hold"},
         {"do": "smoke_type", "text": "echo typing-${nonce}", "enter": True},
         {"do": "expect", "title": "set-up: the typing terminal runs its line", "since": "term", "timeout": 30,
          "all": [{"smoke_daemon_lines": {"lines": ["typing-${nonce}"]}}]},
         {"do": "smoke_adopt_line", "line": "typing-${nonce}", "as": "typing"},
         # The app reopens with the in-app per-key probe on. The typing terminal exists first, so the reopen settles
         # as soon as it is attached again (with no shown terminal, the driver's relaunch waits its full 90 s).
         {"do": "probe_relaunch", "mark": "probed"}, {"do": "smoke_ready", "timeout": 60}, {"do": "smoke_make_key"},
         {"do": "smoke_adopt_line", "line": "typing-${nonce}", "as": "typing"},
         {"do": "echo_start"}]
    if profile != "L0":
        args = []
        if profile in ("L1", "L6"):
            args += ["--rate", "120"]  # CLI storm: 120 calls/s in total (the order's 50-200)
        if profile in ("L3", "L6"):
            args += ["--devtools"]  # DevTools open (the load tool refuses it when it would take focus)
        # --duration 400: longer than everything after LOAD-READY (two 60 s parts, at most ~200 s), so the load runs
        # until load_stop's SIGTERM (stopped_by 15 is checked). Not 0: with 0 the tool gives HEAVY's TUI programs only
        # 60 s (heavy --duration = duration + 60), so L5's panes went still during part 2 (round 04:02Z cmux20).
        s.append({"do": "load_start", "profile": profile, "seed": SEED, "duration": 400, "keep": "typing",
                  "ready_timeout": 120 if profile in ("L5", "L6") else 60, "args": args})
    s.append({"do": "typing_rect", "target": "terminal"})
    s.append({"do": "probe_mark", "as": "before"})
    for half, (lo, hi) in enumerate(((0, 60), (60, 120)), 1):
        name = f"typing-load-{profile.lower()}-part{half}"
        if film:
            # HEVC at 120 Mbit/s: ProRes 4444 movies of 60 s did not fetch within run.py's 240 s (round
            # tul-l0-feat-film); the judge's threshold (24 levels) is far above HEVC's error on terminal text.
            s.append({"do": "video_start", "name": name, "seconds": 75, "codec": "hevc", "mbps": 120})
        s.append({"do": "typist_play", "seed": SEED, "seconds": 120, "from": lo, "to": hi, "label": name})
        if film:
            s.append({"do": "video_stop", "name": name, "tail": 0.6})
    s.append({"do": "probe_mark", "as": "after"})
    if profile != "L0":
        s.append({"do": "load_stop"})
    s.append({"do": "expect", "title": "after the typing: the terminal still shows its last typed text (the frame kept)",
              "since": "term", "timeout": 10, "all": [{"smoke_key_window": {}}, {"smoke_frame": {}}]})
    return s


def journey(profile, film):
    ident = f"typing-load-{profile.lower()}" + ("" if film else "-nf")
    return {"id": ident, "priority": "P0",
            "title": f"Typing under load {profile}: a seeded 2-minute typist (real HID keys) into a terminal"
                     + (", filmed at 120 Hz" if film else " (no film)"),
            "why": "Lawrence 2026-11-02: 'video + metric evidence that typing into terminals is never laggy, even when "
                   "there's a lot of CLI/mcp commands and browser use and browser tabs etc going on in the background'. "
                   "Rule: key-to-photon <= 1 refresh p95, <= 2 max; no lost or merged key; exact order.",
            "source": "TYPING UNDER LOAD (lead 02:3xZ)", "budget_seconds": 260, "options": {"key_path": "real"},
            "continue_not_judged": True,
            "finally": [{"do": "video_close_open"}, {"do": "load_stop"}, {"do": "env_windows", "at": "end"},
                        {"do": "smoke_close_all"}],
            "steps": steps(profile, film)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    bad = 0
    for profile in PROFILES:
        for film in (True, False):
            spec = journey(profile, film)
            path = OUT / f"{spec['id']}.json"
            text = json.dumps(spec, indent=2) + "\n"
            if a.check:
                if not path.is_file() or path.read_text() != text:
                    print(f"differs: {path}")
                    bad = 1
                continue
            path.write_text(text)
    return bad


if __name__ == "__main__":
    sys.exit(main())
