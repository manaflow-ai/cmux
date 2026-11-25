#!/usr/bin/env python3
"""New tab startup: Cmd-T to the new tab visible, and Cmd-T to a key typed into it echoing (goal startup-every-path).

Leo, 2026-11-22: "i hope we're still pursuing startup times for the app itself aka percieved time and percieved
interactive time as well as general cloud startup time for any and every path we have".

On a tagged cmux-next app with the debug control surface (a DEBUG or bench build: scripts/measure/instant-new-surfaces.sh
builds one), from a shown terminal, `--runs` rounds (default 10), each two presses of Cmd-T through the app's key path:

  key_to_visible_ms        perceived: `debug.new_tab {action: bench_create, command: new_tab}`, the same press and clock
                           as instant-new-surfaces' new_tab rows and the perf cron's cmd_t.idle.key_to_visible: the key's
                           press to the display frame that shows the new tab (the app's own `visible_ms`).
  typed_key_accepted_ms    interactive: Cmd-T (`debug.key`), then at once one letter (`debug.key`, as a person who types
                           on at once: the new tab's key hold takes it until its field can), to the New Tab page's
                           omnibar field holding that letter (`debug.new_tab {action: field}`, read every few ms). This
                           clock is the bench's own (monotonic, from before the Cmd-T is sent to the reply of the first
                           read that shows the letter), so it is an upper bound by one read (`read_ms` in each round).

Each press is undone (Cmd-W) back to the terminal, and the next press waits `--settle` seconds, as a warm press (the
New Tab spare refilled). A round whose press gave no value has None for it (a missed round, counted apart).

Prints one `NEW-TAB-STARTUP {json}` line per round, `FIELD new-tab-startup/<field> {n, missed, p50, p95, p99, max}`
(bench_arms.stats) per field, and writes the report as --json:
  {"bench": "new-tab-startup", "runs": N, "rounds": [{round, key_to_visible_ms, typed_key_accepted_ms, ...}],
   "samples": {field: [each round's value]}, "stats": {field: {...}}, "missed": {field: n}}
Exit 0 when every round gave both values.

Fleet (cmux-ci; the entry builds the app at the step's commit):
  cmux-ci run --class exclusive --label measure --script scripts/measure/instant-new-surfaces.sh --ref <sha> \\
    --arg=--bench=new-tab-startup --arg=--config=bench --arg=--runs=10 --artifact artifacts/instant-new-surfaces.json

Usage: new-tab-startup-bench.py --tag TAG --app PATH [--runs 10] [--letter q] [--settle 1.0] [--json PATH] [--out DIR]
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_arms  # noqa: E402

BENCH = "new-tab-startup"
FIELDS = ("key_to_visible_ms", "typed_key_accepted_ms")


def number(value):
    """A finite non-negative number of ms, else None."""
    if isinstance(value, (int, float)) and not isinstance(value, bool) and value == value and 0 <= value < 1e9:
        return round(float(value), 1)
    return None


def report(rounds, runs, extra=None):
    """The bench's JSON report from its rounds (each a dict with FIELDS, None for a miss)."""
    samples = {field: [number(r.get(field)) for r in rounds] for field in FIELDS}
    out = {"bench": BENCH, "runs": runs, "rounds": rounds, "samples": samples,
           "stats": {field: bench_arms.stats(values) for field, values in samples.items()},
           "missed": {field: sum(1 for v in values if v is None) for field, values in samples.items()}}
    out.update(extra or {})
    return out


def passed(out):
    return bool(out["rounds"]) and len(out["rounds"]) == out["runs"] and not any(out["missed"].values())


def wait(check, seconds, step=0.05):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # bench: polling a live app's debug socket
    return None


class Bench:
    def __init__(self, opts):
        from bench_launch import BenchApp  # noqa: E402  (macOS only: the tests import this file without it)
        self.opts = opts
        self.app = BenchApp(opts.app, out=opts.out)

    def rpc(self, method, params=None, timeout=30):
        try:
            reply = self.app.rpc(method, params, timeout=timeout)
        except Exception as error:  # noqa: BLE001  a socket fault is this read's answer
            return {"error": repr(error)}
        return reply if isinstance(reply, dict) else {"value": reply}

    def panes(self):
        return [p for w in (self.rpc("debug.surfaces").get("windows") or []) for p in w.get("panes", [])]

    def focused_kind(self):
        return next((p.get("kind") for p in self.panes() if p.get("focused")), None)

    def window(self):
        return ((self.rpc("debug.windows") or {}).get("windows") or [{}])[0].get("id")

    def field(self):
        reply = self.rpc("debug.new_tab", {"action": "field"}, timeout=10)
        return None if "error" in reply else reply

    def terminal(self):
        """A shown terminal has the keyboard (instant-new-surfaces-bench.py's ensure_terminal)."""
        if self.focused_kind() == "terminal":
            return True
        self.rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": BENCH}, "wait": True})
        return bool(wait(lambda: self.focused_kind() == "terminal", 30, step=0.25))

    def close_tab(self, before):
        """Cmd-W on the new tab, back to the terminal."""
        self.rpc("debug.key", {"key": "w", "modifiers": ["command"], "window": self.window()})
        wait(lambda: len(self.panes()) <= before and self.focused_kind() == "terminal", 10)

    def visible(self):
        before = len(self.panes())
        result = self.rpc("debug.new_tab", {"action": "bench_create", "command": "new_tab"}, timeout=20)
        self.close_tab(before)
        return result

    def typed(self):
        letter, before, window = self.opts.letter, len(self.panes()), self.window()
        start = time.monotonic()
        tab = self.rpc("debug.key", {"key": "t", "modifiers": ["command"], "window": window})
        key = self.rpc("debug.key", {"key": letter})
        sent_ms = (time.monotonic() - start) * 1000
        seen = {}

        def echoed():
            asked = time.monotonic()
            got = self.field()
            now = time.monotonic()
            if got and letter in (got.get("text") or ""):
                seen.update(got=got, at=now, read_ms=(now - asked) * 1000)
                return True
            seen["last"] = got
            return False

        wait(echoed, self.opts.type_timeout, step=0.004)
        out = {"typed_key_accepted_ms": round((seen["at"] - start) * 1000, 1) if "at" in seen else None,
               "read_ms": round(seen["read_ms"], 1) if "read_ms" in seen else None,
               "sent_ms": round(sent_ms, 1),
               "field": (seen.get("got") or seen.get("last") or {}).get("text"),
               "field_focused": (seen.get("got") or seen.get("last") or {}).get("focused")}
        errors = [str(r["error"])[:160] for r in (tab, key) if isinstance(r, dict) and r.get("error")]
        if errors:
            out["key_error"] = "; ".join(errors)
        self.close_tab(before)
        return out

    def round(self, index):
        row = {"round": index + 1}
        if not self.terminal():
            return {**row, "error": "no focused terminal", "key_to_visible_ms": None, "typed_key_accepted_ms": None}
        time.sleep(self.opts.settle)  # bench: a warm press (the New Tab spare refilled)
        made = self.visible()
        row.update({"key_to_visible_ms": number(made.get("visible_ms")), "key_ms": number(made.get("key_ms")),
                    "frames_to_visible": made.get("frames_to_visible"), "confirmed_ms": number(made.get("confirmed_ms"))})
        if made.get("error"):
            row["visible_error"] = str(made["error"])[:200]
        if not self.terminal():
            return {**row, "error": "no focused terminal after the first press", "typed_key_accepted_ms": None}
        time.sleep(self.opts.settle)  # bench: the same warm state for the typed press
        row.update(self.typed())
        return row


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", default=None)
    parser.add_argument("--json", default=None)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--letter", default="q", help="the key typed into the new tab (a letter debug.key knows)")
    parser.add_argument("--settle", type=float, default=1.0, help="seconds from a shown terminal to each press")
    parser.add_argument("--type-timeout", type=float, default=10.0, help="the longest wait for the letter in the field")
    opts, _unknown = parser.parse_known_args(argv)  # instant-new-surfaces.sh passes every bench its arguments
    if opts.runs < 1:
        parser.error("--runs must be 1 or more")
    bench = Bench(opts)
    rounds = []
    try:
        bench.app.launch()
        time.sleep(2)  # bench: the launch settles before the first round
        for index in range(opts.runs):
            row = bench.round(index)
            print("NEW-TAB-STARTUP", json.dumps(row), flush=True)
            rounds.append(row)
    finally:
        bench.app.stop()
    out = report(rounds, opts.runs, {"letter": opts.letter, "settle_s": opts.settle, "app": os.path.realpath(opts.app)})
    for field in FIELDS:
        print(f"FIELD {BENCH}/{field} {json.dumps(out['stats'][field])}", flush=True)
    if opts.json:
        os.makedirs(os.path.dirname(os.path.abspath(opts.json)), exist_ok=True)
        with open(opts.json, "w") as handle:
            json.dump(out, handle, indent=1)
    ok = passed(out)
    print(f"RESULT {'PASS' if ok else 'FAIL'} ({opts.runs - max(out['missed'].values())}/{opts.runs} rounds with both values)", flush=True)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
