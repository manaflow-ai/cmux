#!/usr/bin/env python3
"""Perf lab check: the first keys typed into a new terminal all reach it (dogfood v2.1, 2026-10-27).

Lawrence: "new terminals when i type in it feels laggy". On v2.1 a key typed right after a new terminal was asked for
from Home's dock was lost in about one new tab in four (fleet job 60714874e2a4c22808a89094): the creation's key hold
(cx-wb5.76) ended when the tab had the focus in the dock, before HomeDockOpens moved it beside the dock, and the key
went to the window, which had no responder then.

Launches the app (bench_launch.BenchApp, typing probe on) on its launch window, which shows Home with its dock, and
--tabs times: runs `newSurface` (origin script, focus on) from the dock, types --keys letters from the action's reply
on at --interval (no wait for the terminal: the person types at once), reads the new terminal's last line
(`debug.surfaces` text), and closes the tab. A tab whose line does not end in the typed letters lost keys.

Reports, per tab, what it showed and the first key's key-to-frame (the typing probe's contents_ms), then the counts
and the first key's p50/p95/p99/max. Exits 1 when any tab lost a key (--max-lost, default 0), 2 when the app did not
come up. The app is active, as for a person (keys it holds for a new terminal go on to the key window). Keys are
debug.key (labelled automation) or, with --input real, HID key events.

  new-terminal-first-keys.py --app APP --out DIR [--json FILE] [--tabs 40] [--keys 5]
  split-spring.sh --suite=first-keys --tabs=40      (on a perf lab Mac, through cmux-ci)
"""
import argparse, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hid_input  # noqa: E402
import typing_report  # noqa: E402
from bench_launch import BenchApp, LaunchError, shipping_env  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--tag")  # split-spring passes its own; the bundle names the tag
parser.add_argument("--tabs", type=int, default=40)
parser.add_argument("--keys", type=int, default=5)
parser.add_argument("--interval", type=float, default=0.06)
parser.add_argument("--settle", type=float, default=1.5, help="seconds after the last key before the line is read")
parser.add_argument("--input", choices=("debug", "real"), default="debug",
                    help="debug: debug.key (labelled automation); real: HID key events (needs the Accessibility grant)")
parser.add_argument("--background", action="store_true",
                    help="keep the app inactive (CMUX_NEXT_NO_ACTIVATE): a key the app holds and sends again then has no key "
                         "window to go to, so only the inactive-window path is measured")
parser.add_argument("--max-lost", type=int, default=0, help="tabs that may lose keys before the check fails")
opts, _unknown = parser.parse_known_args()

OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
APP = os.path.abspath(opts.app.rstrip("/"))
PROBE = os.path.join(OUT, "first-keys-typing.csv")
CONTROL = hid_input.Control("", os.path.join(APP, "Contents/Resources/bin/cmux"), None)
result = {"app": os.path.basename(APP), "host": os.uname().nodename, "opts": vars(opts), "input": opts.input, "tabs": []}


def note(text):
    print(text, flush=True)


def save():
    if opts.json:
        with open(opts.json, "w") as handle:
            json.dump(result, handle, indent=1)


def focused_line():
    """The focused terminal's last non-empty line (debug.surfaces with its viewport text)."""
    found = []

    def walk(node):
        if isinstance(node, dict):
            if node.get("focused") is True and isinstance(node.get("text"), str):
                found.append(node["text"])
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(CONTROL.rpc("debug.surfaces", {"text": True}, timeout=20))
    lines = [line for line in (found[-1] if found else "").splitlines() if line.strip()]
    return lines[-1] if lines else ""


def first_key_ms(rows, base):
    """The first typed key's key-to-frame: the probe row of press `base` (each launch numbers presses from 0)."""
    for row in rows:
        if (row.get("index") or "") == str(base) and row.get("complete") == "1" and row.get("contents_ms"):
            return float(row["contents_ms"])
    return None


def main():
    # Active by default, as for a person: keys the app holds for a new terminal go on through NSApp.sendEvent to the key
    # window, which an inactive app does not have.
    env = {"CMUX_NEXT_TYPING_PROBE": PROBE, **({} if opts.background else shipping_env(draw=False))}
    bench = BenchApp(APP, out=OUT, config={"browser": {"defaultEngine": "chromium"}}, window=(40, 40, 1400, 900),
                     log_name="app-first-keys.log", env=env)
    try:
        try:
            bench.launch(timeout=180)
        except LaunchError as error:
            note(f"first-keys: the app did not come up: {error.reason}")
            result["launch_failure"] = error.reason
            return 2
        CONTROL.socket_path, CONTROL.config = bench.socket, os.path.join(bench.scratch, "cmux.json")
        time.sleep(6)  # the launch settles
        if not opts.background:
            result["activate"] = bench.activate()
            note(f"first-keys: activate {result['activate']}")
            if opts.input == "real":
                hid_input.bring_front(bench.process.pid)
        poster = hid_input.poster_for(opts.input, control=CONTROL)
        typed = "".join(hid_input.LETTERS[i % 26] for i in range(opts.keys))
        for index in range(opts.tabs):
            before = hid_input.probe_rows(PROBE)
            base = max([int(r["index"]) for r in before if (r.get("index") or "").isdigit()], default=-1) + 1
            t0 = time.perf_counter()
            reply = CONTROL.action("newSurface", focus=True)
            reply_ms = round((time.perf_counter() - t0) * 1000, 2)
            for key in range(opts.keys):
                k0 = time.perf_counter()
                poster.key(typed[key])
                rest = opts.interval - (time.perf_counter() - k0)
                if rest > 0 and key + 1 < opts.keys:
                    time.sleep(rest)  # one key in flight, at a typist's pace
            time.sleep(opts.settle)
            line = focused_line()
            tab = {"tab": index, "reply_ms": reply_ms, "reply": json.dumps(reply)[:160], "line": line[-120:],
                   "all": line.endswith(typed), "first_key_ms": first_key_ms(hid_input.probe_rows(PROBE), base)}
            result["tabs"].append(tab)
            note(f"  tab {index}: {'ok  ' if tab['all'] else 'LOST'} {line[-40:]!r} first key {tab['first_key_ms']} ms")
            CONTROL.action("terminal.sendText", {"text": "\x15"})
            CONTROL.action("closeTab")
            time.sleep(1.0)  # the close settles
            save()
    finally:
        save()
        bench.stop()
    lost = sum(not t["all"] for t in result["tabs"])
    first = typing_report.distribution([t["first_key_ms"] for t in result["tabs"] if t["first_key_ms"] is not None])
    result["summary"] = {"tabs": len(result["tabs"]), "lost": lost, "first_key_ms": first}
    save()
    note(f"FIRST-KEYS {result['app']}: {lost} of {len(result['tabs'])} new terminals lost keys; first key-to-frame "
         f"{json.dumps(first)}")
    if lost > opts.max_lost:
        note(f"FIRST-KEYS: FAIL ({lost} > --max-lost {opts.max_lost})")
        return 1
    note("FIRST-KEYS: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
