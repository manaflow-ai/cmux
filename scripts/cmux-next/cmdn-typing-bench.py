#!/usr/bin/env python3
"""Keys typed right after Cmd-N, on a tagged cmux-next app that a person's keys reach: how many the new workspace's
New Tab field lost (Lawrence 2026-11-19: "i did cmd n and started typing and it didnt have focus").

The app is launched as a person's app (no CMUX_NEXT_NO_ACTIVATE: it is the active app and its window is key). Each
run plays ONE `debug.key` sequence: Cmd-N, then the text at --rate keys/s, the first key --delay-ms after the N.
The app posts each key to its own event queue with its press time (DebugKey+Sequence), so the keys take the path a
keyboard's do: `nextEvent`, the key router, `sendEvent`, the key window, its first responder. The new page's field
must then hold the whole text. Not the HID tap: a fleet display worker grants no post-event access to a fresh binary.

Where the keyboard is before Cmd-N (`--starts`, default all):
  terminal  a terminal tab of the shown workspace has the keyboard
  page      the last run's New Tab page has the keyboard (its field)
When the keys come (`--arms`, default all):
  now       --delay-ms after the N (default 40: a person who types on at once)
  late      --late-ms after the N (default 1500): the page is settled; its field must have the keyboard by then
  cold      the first Cmd-N of a fresh launch, typed --delay-ms after the N

A run's `lost_keys`: the keys of the text not in the field, `None` (a missed run, counted apart) when the focused tab
is not a new page. A run passes when the field holds the text exactly and has the keyboard. Each failed run prints
the key hold's log (`debug.focus` `new_tab_key_log`) and the window's first responder.

One `CMDN-TYPING {json}` line per run, then `ARM cmdn-typing/<arm>-<start> lost_keys {n, missed, p50, p95, max}` per
group (bench_arms.stats), one `CMDN-TYPING-SUMMARY` line, and the report as --json. Exit 0 when every run kept every key.

Fleet (a display worker; scripts/measure/instant-new-surfaces.sh builds the app at the step's commit):
  cmux-ci run --class exclusive --label gui-session-v1 --label measure --script scripts/measure/instant-new-surfaces.sh \\
    --ref <sha> --arg=--bench=cmdn-typing --arg=--allow-no-chromium --artifact artifacts/instant-new-surfaces.json
  (--build=SHA as the entry says: the app at another commit, this bench at the step's)

Usage: cmdn-typing-bench.py --tag TAG --app PATH [--runs 10] [--cold 5] [--starts terminal,page] [--arms now,late,cold]
       [--text "hello world 123"] [--rate 30] [--delay-ms 40] [--late-ms 1500] [--json PATH] [--out DIR]
"""
import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import BenchApp  # noqa: E402
import bench_arms  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=None)
parser.add_argument("--json", default=None)
parser.add_argument("--runs", type=int, default=10, help="runs of each start in the now and late arms")
parser.add_argument("--cold", type=int, default=5, help="fresh launches in the cold arm")
parser.add_argument("--starts", default="terminal,page")
parser.add_argument("--arms", default="now,late,cold")
parser.add_argument("--text", default="hello world 123")
parser.add_argument("--rate", type=float, default=30.0)
parser.add_argument("--delay-ms", type=float, default=40.0)
parser.add_argument("--late-ms", type=float, default=1500.0)
parser.add_argument("--settle-s", type=float, default=6.0, help="the longest wait for the field to hold the text")
parser.add_argument("--page-engine", default=None, help="ignored (instant-new-surfaces.sh passes it to every bench)")
opts, _unknown = parser.parse_known_args()
STARTS = [s for s in opts.starts.split(",") if s]
ARMS = [a for a in opts.arms.split(",") if a]

# ANSI virtual key codes (DebugKey's table), shifted letters with Shift (56).
CODES = {"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
         "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26,
         "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49,
         "-": 27, "=": 24, ".": 47, ",": 43, "/": 44}
COMMAND, SHIFT = 55, 56


def sequence(delay_ms):
    """Cmd-N, then the text: one `debug.key` sequence, each step's gap from the step before it."""
    steps = [{"key_code": COMMAND, "down": True}, {"key_code": CODES["n"], "down": True, "after_ms": 8},
             {"key_code": CODES["n"], "down": False, "after_ms": 40}, {"key_code": COMMAND, "down": False, "after_ms": 10}]
    gap = 1000.0 / opts.rate
    first = max(0.0, delay_ms - 58)  # from the command key's up, 58 ms after the N went down
    for index, character in enumerate(opts.text):
        code = CODES.get(character.lower())
        if code is None:
            continue
        shifted = character.isupper()
        if shifted:
            steps.append({"key_code": SHIFT, "down": True, "after_ms": first if index == 0 else gap / 2})
        steps.append({"key_code": code, "down": True, "after_ms": 0 if shifted else (first if index == 0 else gap / 2)})
        steps.append({"key_code": code, "down": False, "after_ms": gap / 2})
        if shifted:
            steps.append({"key_code": SHIFT, "down": False, "after_ms": 1})
    return steps


def wait(check, seconds, step=0.05):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # bench: polling a live app's debug socket
    return None


class Bench:
    def __init__(self):
        self.app = None

    def launch(self):
        if self.app:
            self.app.stop()
        # A person's app: it activates and its window is key (None removes BASE_ENV's NO_ACTIVATE).
        self.app = BenchApp(opts.app, out=opts.out, env={"CMUX_NEXT_NO_ACTIVATE": None})
        self.app.launch()
        if not wait(lambda: (self.rpc("debug.focus") or {}).get("app_active"), 10):
            # A binary started from a script may not become the active app on a display Mac: one LaunchServices open.
            subprocess.run(["/usr/bin/open", self.app.app], check=False)
            wait(lambda: (self.rpc("debug.focus") or {}).get("app_active"), 10)
        focus = self.rpc("debug.focus") or {}
        print(f"LAUNCH app_active={focus.get('app_active')} key_window={focus.get('key_window')}", flush=True)
        return focus.get("app_active") is True

    def rpc(self, method, params=None, timeout=30):
        try:
            reply = self.app.rpc(method, params, timeout=timeout)
        except Exception as error:  # noqa: BLE001  a socket fault is this read's answer
            return {"error": repr(error)}
        return reply if isinstance(reply, dict) else {"value": reply}

    def key_window_word(self):
        focus = self.rpc("debug.focus") or {}
        windows = [w for w in focus.get("windows") or [] if isinstance(w, dict)]
        page = any((w.get("appkit") or {}).get("child_window_page") for w in windows)
        return "page" if page and not any(w.get("is_key") for w in windows) else "shell"

    def window(self):
        windows = (self.rpc("debug.focus") or {}).get("windows") or []
        return windows[0] if windows else {}

    def focused_tab(self):
        return (self.window().get("model") or {}).get("resolved_tab")

    def spare_ready(self):
        """The New Tab spare is built and ready (debug.new_tab state): what a Cmd-N takes."""
        return any(s.get("ready") for s in (self.rpc("debug.new_tab", {"action": "state"}) or {}).get("spares") or [])

    def settled(self, what):
        """Until the New Tab spare is ready (the launch's or the last run's work is done); best effort, logged."""
        if not wait(self.spare_ready, 15):
            print(f"no ready New Tab spare after 15 s: {what}", flush=True)

    def field(self):
        reply = self.rpc("debug.new_tab", {"action": "field"})
        return None if "error" in reply else reply

    def set_start(self, start):
        """The keyboard where `start` says, in the shown workspace. True when it is there."""
        if start == "terminal":
            self.rpc("action.run", {"action": "newSurface", "args": {}, "focus": True})
            return bool(wait(lambda: self.field() is None and (self.rpc("debug.focus").get("context") or {}).get("terminal_focused"), 8))
        if start == "page":
            # The last run's page (or a fresh one): its field has the keyboard.
            if (self.field() or {}).get("focused"):
                return True
            before = self.focused_tab()
            self.rpc("debug.key", {"key": "n", "modifiers": ["command"]})
            return bool(wait(lambda: self.focused_tab() not in (None, before) and (self.field() or {}).get("focused"), 8))
        return False

    def run(self, name, arm, start, delay_ms):
        before = self.focused_tab()
        # The keys go to the window that has them, as a keyboard's do: the page's Chromium window when a page has the
        # keyboard, else the shell (held-new-tab.py's key_window_word).
        word = self.key_window_word()
        sent = self.rpc("debug.key", {"sequence": sequence(delay_ms), "key_window": word})
        if "error" in sent:
            row = {"run": name, "arm": arm, "start": start, "pass": False, "lost_keys": None, "error": sent["error"], "keys_to": word}
            print("CMDN-TYPING", json.dumps(row), flush=True)
            return row
        # sleep-ok: the app plays the sequence by its own clock for duration_ms; no reads while it plays
        time.sleep((sent.get("duration_ms") or 0) / 1000)
        new_page = lambda: self.focused_tab() not in (None, before)
        got = wait(lambda: (lambda f: f if f and f.get("text") == opts.text and new_page() else None)(self.field()), opts.settle_s)
        field = got or self.field() or {}
        text = field.get("text")
        focus = self.rpc("debug.focus") or {}
        window = (focus.get("windows") or [{}])[0]
        missed = not new_page() or text is None
        lost = None if missed else len(opts.text) - common_count(opts.text, text)
        ok = got is not None and field.get("focused") is True
        row = {"run": name, "arm": arm, "start": start, "pass": ok, "lost_keys": lost, "field": text,
               "field_focused": field.get("focused"), "tab_before": before, "tab_after": self.focused_tab(),
               "first_responder": (window.get("appkit") or {}).get("first_responder"),
               "app_active": focus.get("app_active"), "key_window": focus.get("key_window"),
               "planned_ms": round(sent.get("duration_ms") or 0, 1), "keys_to": word}
        if not ok:
            row["hold_log"] = (focus.get("new_tab_key_log") or [])[-14:]
            row["recent_focus"] = window.get("recent_events")
        print("CMDN-TYPING", json.dumps(row), flush=True)
        return row


def common_count(want, got):
    """How many keys of `want` reached `got`, in order (the longest common subsequence)."""
    previous = [0] * (len(got) + 1)
    for a in want:
        row = [0]
        for j, b in enumerate(got):
            row.append(previous[j] + 1 if a == b else max(previous[j + 1], row[j]))
        previous = row
    return previous[-1]


def main():
    bench = Bench()
    rows = []
    try:
        if "cold" in ARMS:
            for index in range(opts.cold):
                if not bench.launch():
                    rows.append({"run": f"cold-{index + 1}", "arm": "cold", "start": "terminal", "pass": False, "lost_keys": None,
                                 "error": "the app is not active"})
                    continue
                bench.settled("the cold launch")  # the launch's own work settles; its first Cmd-N is the measured one
                bench.set_start("terminal")
                rows.append(bench.run(f"cold-{index + 1}", "cold", "terminal", opts.delay_ms))
        warm = [a for a in ARMS if a in ("now", "late")]
        if warm:
            bench.launch()
            bench.settled("the warm launch")  # the launch settles before the warm runs
            for arm in warm:
                for start in STARTS:
                    for index in range(opts.runs):
                        name = f"{arm}-{start}-{index + 1}"
                        if not bench.set_start(start):
                            row = {"run": name, "arm": arm, "start": start, "pass": False, "lost_keys": None, "error": "start not reached"}
                            print("CMDN-TYPING", json.dumps(row), flush=True)
                            rows.append(row)
                            continue
                        bench.settled(name)  # the start settles: the New Tab spare refilled
                        rows.append(bench.run(name, arm, start, opts.delay_ms if arm == "now" else opts.late_ms))
    finally:
        if bench.app:
            bench.app.stop()
    print("", flush=True)
    groups = {}
    for row in rows:
        groups.setdefault(row["arm"] if row["arm"] == "cold" else f"{row['arm']}-{row['start']}", []).append(row.get("lost_keys"))
    for name, samples in groups.items():
        print(f"ARM cmdn-typing/{name} lost_keys {json.dumps(bench_arms.stats(samples))}", flush=True)
    passed = sum(1 for row in rows if row.get("pass"))
    summary = {"text": opts.text, "rate": opts.rate, "delay_ms": opts.delay_ms, "late_ms": opts.late_ms,
               "runs": len(rows), "passed": passed,
               "missed_runs": sum(1 for row in rows if row.get("lost_keys") is None),
               "lost_keys_total": sum(row.get("lost_keys") or 0 for row in rows),
               "by_group": {name: {"runs": len(v), "missed": sum(1 for x in v if x is None), "lost": sum(x or 0 for x in v)}
                            for name, v in groups.items()},
               "rows": rows}
    print("CMDN-TYPING-SUMMARY", json.dumps({k: v for k, v in summary.items() if k != "rows"}), flush=True)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        with open(opts.json, "w") as handle:
            json.dump(summary, handle, indent=1)
    print(f"RESULT {'PASS' if rows and passed == len(rows) else 'FAIL'} ({passed}/{len(rows)})", flush=True)
    sys.exit(0 if rows and passed == len(rows) else 1)


main()
