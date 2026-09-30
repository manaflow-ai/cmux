#!/usr/bin/env python3
"""Replay a cmux-next desync report's input into a tagged app and report the
first divergence (plans/cmux-next/input-spec.md section 5).

Reads the report's journal (or `--journal`, a `debug.journal` answer saved as
JSON), sends its mouse input through `debug.mouse` and its key chords and named
keys through `debug.key`, and after each input compares `debug.focus` with the
focus digest the journal recorded after it. Plain typing is replayed only with
`--typing` (it types into the live terminal). Best effort: the live layout must
match the recorded one for pane ids to agree; by default only the kind of the
resolved target is compared (`--strict` also compares pane ids).

Usage:
  scripts/cmux-next/input-replay.py REPORT.json --tag TAG [--window ID]
      [--socket PATH] [--typing] [--strict] [--settle-ms 400]

Exit status: 0 no divergence, 1 divergence, 2 setup error.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_cli_storm import Client  # noqa: E402

# US key codes debug.key can express (it takes names or characters).
KEY_NAMES = {
    36: "return", 48: "tab", 53: "escape", 49: " ",
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q",
    13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
    25: "9", 26: "7", 28: "8", 29: "0", 31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k",
    45: "n", 46: "m",
}
MODIFIER_BITS = [(1, "cmd"), (2, "shift"), (4, "option"), (8, "ctrl")]


def payload(kind):
    """(case name, associated values) of a Swift-synthesized enum encoding."""
    (name, value), = kind.items()
    return name, value


def modifiers(bits):
    return [name for bit, name in MODIFIER_BITS if bits & bit]


def live_focus(client, window):
    result = client.call("debug.focus").get("result") or {}
    for entry in result.get("windows", []):
        if window is None or entry.get("id") == window:
            return entry
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("report", nargs="?")
    parser.add_argument("--journal", help="a saved debug.journal answer instead of a report")
    parser.add_argument("--tag")
    parser.add_argument("--socket")
    parser.add_argument("--window", help="live window id (default: the first window)")
    parser.add_argument("--typing", action="store_true", help="also replay plain typing")
    parser.add_argument("--strict", action="store_true", help="compare pane ids too")
    parser.add_argument("--settle-ms", type=int, default=400)
    args = parser.parse_args()
    if not (args.report or args.journal) or not (args.tag or args.socket):
        parser.error("pass a report (or --journal) and --tag or --socket")
    path = args.socket or f"/tmp/cmux-debug-{args.tag}.sock"
    if os.path.realpath(path) in {"/tmp/cmux-debug.sock", "/private/tmp/cmux-debug.sock"}:
        print("refusing the default socket", file=sys.stderr)
        return 2
    with open(args.report or args.journal) as handle:
        document = json.load(handle)
    entries = document.get("journal") or document.get("entries") or (document.get("result") or {}).get("entries") or []
    try:
        client = Client(path)
        window = args.window or (live_focus(client, None) or {}).get("id")
    except (OSError, ConnectionError) as error:
        print(f"cannot reach {path}: {error}", file=sys.stderr)
        return 2
    if window is None:
        print("no live window", file=sys.stderr)
        return 2

    recorded_window = None
    replayed = 0
    expected = None
    pending_down = None

    def check(after_seq):
        nonlocal expected
        if expected is None:
            return None
        deadline = time.monotonic() + args.settle_ms / 1000
        while True:
            live = live_focus(client, window) or {}
            model = live.get("model") or {}
            same = model.get("resolved") == expected.get("resolved")
            if args.strict:
                same = same and model.get("resolved_pane") == expected.get("pane")
            if same or time.monotonic() > deadline:
                break
            time.sleep(0.02)
        if not same:
            return {"after_seq": after_seq, "recorded": expected, "live": model, "mismatches": live.get("mismatches")}
        expected = None
        return None

    last_input = None

    def send(method, params):
        """Checks the previous input's recorded outcome, then sends this one."""
        nonlocal replayed, last_input
        if last_input is not None:
            divergence = check(last_input)
            if divergence:
                return divergence
        expected_reset()
        client.call(method, params)
        replayed += 1
        last_input = seq
        return None

    def expected_reset():
        nonlocal expected
        expected = None

    for entry in entries:
        kind, value = payload(entry["kind"])
        seq = entry.get("seq")
        if kind == "focus" and (recorded_window is None or entry.get("window") == recorded_window):
            expected = value.get("after")
            continue
        call = None
        if kind == "mouse":
            mouse = value["_0"]
            recorded_window = recorded_window or entry.get("window")
            base = {"window": window, "x": mouse["x"], "y": mouse["y"], "modifiers": modifiers(mouse["modifiers"]),
                    "button": "right" if mouse["button"] == 1 else "left"}
            if mouse["phase"] == "down":
                pending_down = base
            elif mouse["phase"] == "up" and pending_down:
                call = ("debug.mouse", {**pending_down, "action": "click"})
                pending_down = None
            elif mouse["phase"] == "drag" and pending_down:
                call = ("debug.mouse", {**pending_down, "action": "drag", "to_x": mouse["x"], "to_y": mouse["y"]})
                pending_down = None
            elif mouse["phase"] == "scroll":
                call = ("debug.mouse", {**base, "action": "scroll", "dx": mouse.get("dx", 0), "dy": mouse.get("dy", 0)})
        elif kind == "key":
            key = value["_0"]
            chord = key["modifiers"] & (1 | 8)
            name = key.get("characters") or KEY_NAMES.get(key["keyCode"])
            if key["phase"] == "down" and name and (chord or args.typing or name in ("return", "tab", "escape")):
                recorded_window = recorded_window or entry.get("window")
                call = ("debug.key", {"window": window, "key": name, "modifiers": modifiers(key["modifiers"])})
        if call:
            divergence = send(*call)
            if divergence:
                print(json.dumps({"replayed_inputs": replayed, "first_divergence": divergence}, indent=2))
                return 1
    divergence = check(last_input) if last_input is not None else None
    print(json.dumps({"replayed_inputs": replayed, "first_divergence": divergence}, indent=2))
    return 1 if divergence else 0


if __name__ == "__main__":
    sys.exit(main())
