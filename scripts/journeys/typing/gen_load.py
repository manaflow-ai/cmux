#!/usr/bin/env python3
"""Writes the TYPING UNDER LOAD journeys (Lawrence P0, 2026-11-02) into journeys/video/typing-load-*.json.

    python3 scripts/journeys/typing/gen_load.py [--check]
    python3 scripts/journeys/typing/gen_load.py --switch KEY [--out DIR]

One journey per load profile (L0 = no load, L1 CLI storm, L2 MCP storm, L3 browser, L4 agents, L5 12-pane HEAVY
TUI, L6 all; the 15 GB hog is run.py --hog-swap-gb on top), filmed (HARNESS recorder, two 60 s movies) and an -nf copy
(no recorder: in-app marks, echo and keys_check only). Each: a new workspace and terminal named `typing`, echo.py in
it, the load around it (load_profiles.py --keep typing), then the seeded 2-minute typist (typist_play) in two
halves, then the load stops. Judges: typing/keys_check.py (order, lost, merged, PTY arrival) and the video judge.

--switch KEY writes typing-load-l6-sw-<short> (<short>: the key's last part, lowercase): typing-load-l6 with a feature
switch ON (ext_pixel px_switch) right after the relaunch's smoke_ready (a bench build keeps Debug tunables in memory only,
so a switch set before probe_relaunch is gone), every other step and option the same, so its numbers compare with plain
typing-load-l6; the switch back to its default first in finally. A switch that does not take makes the round not run.
A variant is P1 (an A/B run started with --journey): as P0 it would make dogfood-gate.py refuse every build without it.
The stage switches: motion.frameOwner.terminals (S4), motion.frameOwner.timing (S2), motion.frameOwner.contentPolicy (S3).
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
            # HEVC at 60 Mbit/s: ProRes 4444 and (under L3's moving pages) 120 Mbit/s movies did not fetch in time (round
            # tul-l0-feat-film); the judge's threshold (24 levels) is far above HEVC's error on terminal text.
            s.append({"do": "video_start", "name": name, "seconds": 75, "codec": "hevc", "mbps": 60})
        s.append({"do": "typist_play", "seed": SEED, "seconds": 120, "from": lo, "to": hi, "label": name})
        if film:
            s.append({"do": "video_stop", "name": name, "tail": 0.6})
    s.append({"do": "probe_mark", "as": "after"})
    # The app watchdog's main-thread stalls over its threshold, each with its sampled stack: a read only, after every
    # measured key and film, so each round carries the stall behind a slow key (the refactor owner's Ctrl-C key stall).
    s.append({"do": "rpc", "method": "debug.hangs", "params": {"limit": 64},
              "title": "after the typing: the watchdog's main-thread stalls over its threshold, each with its sampled stack "
                       "(finds a key stall such as the Ctrl-C one; reads only)"})
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


def switch_short(key):
    """The journey suffix of a switch key: its last dotted part, lowercase letters and digits."""
    return "".join(c for c in key.split(".")[-1].lower() if c.isalnum()) or "switch"


def switch_variant(key, profile="L6", on=True):
    """typing-load-<profile> with KEY ON (or OFF: an A/B of the same app state in one build) from the relaunch on:
    px_switch right after the relaunch's smoke_ready, read back; a switch that does not take makes the round not run."""
    spec = journey(profile, True)
    steps = spec["steps"]
    i = next(n for n, st in enumerate(steps) if st["do"] == "probe_relaunch")
    assert steps[i + 1]["do"] == "smoke_ready", steps[i + 1]
    state = "ON" if on else "OFF"
    steps.insert(i + 2, {"do": "px_switch", "key": key, "value": bool(on),
                         "title": f"set-up: {key} {state} (after the relaunch: a bench build keeps tunables in memory only)"})
    spec["id"] = f"{spec['id']}-sw-{switch_short(key)}" + ("" if on else "-off")
    # P1: dogfood-gate.py needs every P0 journey to pass on a build, and the switch exists only on its stage's builds.
    spec["priority"] = "P1"
    spec["title"] += f", with {key} {state}"
    spec["finally"] = [{"do": "px_tunable", "key": key, "value": None, "title": f"clean-up: {key} back to its default"}] + spec["finally"]
    return spec


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--switch", help="a boolean Debug tunable: write typing-load-l6-sw-<short> with it ON")
    ap.add_argument("--off", action="store_true", help="with --switch: typing-load-l6-sw-<short>-off, the switch set OFF")
    ap.add_argument("--out", help="the folder for --switch (default the journeys' video folder)")
    a = ap.parse_args()
    if a.off and not a.switch:
        ap.error("--off needs --switch")
    if a.switch:
        spec = switch_variant(a.switch, on=not a.off)
        out = Path(a.out) if a.out else OUT
        out.mkdir(parents=True, exist_ok=True)
        (out / f"{spec['id']}.json").write_text(json.dumps(spec, indent=2) + "\n")
        print(f"{spec['id']} in {out}")
        return 0
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
