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
            # HEVC at 60 Mbit/s: ProRes 4444 and (under L3's moving pages) 120 Mbit/s movies did not fetch in time (round
            # tul-l0-feat-film); the judge's threshold (24 levels) is far above HEVC's error on terminal text.
            s.append({"do": "video_start", "name": name, "seconds": 75, "codec": "hevc", "mbps": 60})
        s.append({"do": "typist_play", "seed": SEED, "seconds": 120, "from": lo, "to": hi, "label": name})
        if film:
            s.append({"do": "video_stop", "name": name, "tail": 0.6})
    s.append({"do": "probe_mark", "as": "after"})
    if profile != "L0":
        s.append({"do": "load_stop"})
    s.append({"do": "expect", "title": "after the typing: the terminal still shows its last typed text (the frame kept)",
              "since": "term", "timeout": 10, "all": [{"smoke_key_window": {}}, {"smoke_frame": {}}]})
    # echo.py writes its records when it ends (no log write between reads): end it and wait for them.
    s.append({"do": "echo_stop"})
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
            "finally": [{"do": "echo_stop"}, {"do": "video_close_open"}, {"do": "load_stop"},
                        {"do": "env_windows", "at": "end"}, {"do": "smoke_close_all"}],
            "steps": steps(profile, film)}


def rds_journey(arm, target="new_tab"):
    """R-DAEMON-STATE stage S1 typing A/B (STATUS 10117): typing-load-l6 with a NEW daemon at the probe relaunch,
    the input lane switch on (CMUX_NEXT_TUI_RDS_INPUT=1, which the app hands its daemon as CMUX_TUI_RDS_INPUT=1) or
    absent, and the arm proven from the daemon's environment before and after the typing. P1: run with --journey
    (as P0 the dogfood gate would ask every build for it).

    The typed terminal is a NEW tab (Ctrl-`) in the typing pane, made after the relaunch: its terminal host is
    spawned by the new daemon, so it has the reopen's CMUX_TRACE_FLOWS (R-DAEMON-STATE STATUS 10740: the set-up
    terminal's host is an old host the new daemon adopts, with no flow trace). The set-up terminal stays as the
    first tab, so the relaunch still settles on a shown terminal. server-stats with the lock holds by code site is
    kept right after load_start and right after the last typist_play.

    target "adopted" (typing-load-l6-rds-adopted-<arm>, R-DAEMON-STATE STATUS 10927): the typed terminal is the
    set-up terminal itself, as in runs 1-6 (STATUS 10595): its host was spawned by the OLD daemon, before the
    relaunch, and the new daemon adopts it (so it has no CMUX_TRACE_FLOWS). Everything else is the same."""
    assert target in ("new_tab", "adopted"), target
    spec = journey("L6", True)
    if target == "new_tab":
        spec.update(id=f"typing-load-l6-rds-{arm}", priority="P1",
                    title=f"Typing under load L6, R-DAEMON-STATE S1 input lane {arm.upper()} (new daemon, arm proven)",
                    source="REWRITE R-DAEMON-STATE S1 typing A/B (STATUS 10117, 10740)")
    else:
        spec.update(id=f"typing-load-l6-rds-adopted-{arm}", priority="P1",
                    title=f"Typing under load L6, R-DAEMON-STATE S1 input lane {arm.upper()}, typed into the set-up "
                          "terminal whose host the new daemon adopted (new daemon, arm proven)",
                    source="REWRITE R-DAEMON-STATE S1 typing A/B (STATUS 10117, 10740, 10927: the adopted-host test)")
    steps, out = spec["steps"], []
    relaunch = next(i for i, step in enumerate(steps) if step["do"] == "probe_relaunch")
    last_play = max(i for i, step in enumerate(steps) if step["do"] == "typist_play")
    for i, step in enumerate(steps):
        if i == relaunch:
            # Both arms set the switch: an OFF arm that left it unset would be ON once S1.7 makes on the default
            # (REWRITE R-DAEMON-STATE, 2026-11-04); 0 is off on every build.
            step = dict(step, new_daemon=True, env={"CMUX_NEXT_TUI_RDS_INPUT": "1" if arm == "on" else "0"})
        if step["do"] == "load_start":
            # 12 L1 workers, not 8: at ~66 ms a call, 120 calls/s keeps ~7.9 workers busy, so 8 workers were all busy
            # 79-82 % of the time and the storm reached 108.9-112.4 of 120 (build-2 rounds, 2026-11-04). The rate, the
            # seeds and each worker's call sequence stay the same; only the cap (workers / call latency) rises.
            step = dict(step, args=list(step["args"]) + ["--workers", "12"])
        if step["do"] == "echo_start" and target == "new_tab":
            # The set-up terminal is adopted (above) so the key window and its pane are the typing pane's; the
            # typed terminal is a new tab there, from the new daemon.
            out += [{"do": "smoke_key", "key": "`", "modifiers": ["control"], "mark": "term2"},
                    {"do": "outwait_hold"},
                    {"do": "smoke_type", "text": "echo rds-${nonce}", "enter": True},
                    {"do": "expect", "title": "set-up: the new daemon's typing terminal runs its line", "since": "term2",
                     "timeout": 30, "all": [{"smoke_daemon_lines": {"lines": ["rds-${nonce}"]}}]},
                    {"do": "smoke_adopt_line", "line": "rds-${nonce}", "as": "typing"}]
        out.append(step)
        if step["do"] == "echo_start":
            out.append({"do": "daemon_arm", "as": "before", "want": arm, "value": "1" if arm == "on" else "0"})
        if step["do"] == "load_start":
            out.append({"do": "server_stats", "as": "before", "include": ["locks"]})
        if i == last_play:
            out.append({"do": "server_stats", "as": "after", "include": ["locks"]})
        if step["do"] == "probe_mark" and step["as"] == "after":
            out.append({"do": "daemon_arm", "as": "after", "want": arm, "value": "1" if arm == "on" else "0"})
    spec["steps"] = out
    return spec


def unset_journey():
    """typing-load-l6-unset (REWRITE R-DAEMON-STATE, S1.7 typing pair): typing-load-l6 as the smoke gate runs it (film,
    the same daemon from the lease's first launch, the set-up terminal, 8 L1 workers), each build at its own default
    of the input lane, plus two read-only steps that prove it: the daemon's `ps -wwE` has neither
    CMUX_TUI_RDS_INPUT nor CMUX_NEXT_TUI_RDS_INPUT, after echo_start and after the typing. P1 (run with --journey).
    Its daemon starts before the probe relaunch sets the trace knob, so it writes no flow file."""
    spec = journey("L6", True)
    spec.update(id="typing-load-l6-unset", priority="P1",
                title="Typing under load L6 as the gate runs it, the input lane at the build's default (no switch set; proven)",
                source="REWRITE R-DAEMON-STATE S1.7 typing pair (BASE vs HEAD, each at its default)")
    proof = {"names": ["CMUX_TUI_RDS_INPUT", "CMUX_NEXT_TUI_RDS_INPUT"], "want": "unset"}
    out = []
    for step in spec["steps"]:
        out.append(step)
        if step["do"] == "echo_start":
            out.append(dict(proof, do="daemon_arm", **{"as": "before"}))
        if step["do"] == "probe_mark" and step["as"] == "after":
            out.append(dict(proof, do="daemon_arm", **{"as": "after"}))
    spec["steps"] = out
    return spec


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    bad = 0
    specs = [journey(profile, film) for profile in PROFILES for film in (True, False)]
    for spec in specs + [rds_journey("off"), rds_journey("on"), rds_journey("on", target="adopted"), unset_journey()]:
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
