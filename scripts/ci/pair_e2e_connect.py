"""pair-e2e's connect leg: how long a paired iPhone takes to be usable, launch after launch.

cmux_next_pair_e2e.py runs it once the phone has paired with the rig Mac. Each sample is the app's
own marks (ConnectTimeline and LaunchMarks: `timing <attempt> <step> +<ms in the attempt> (<ms since
process start>)` and `timing launch <mark> (<ms>ms)`, subsystem dev.cmux.mobile, category timing),
so `log stream`'s delivery lag (tens of seconds on a busy host) never enters a number.

- cold: terminate, launch on the Workspaces tab; the sample is process start to the first live
  workspace row (`workspace_row_live`), with the first cached row and every connect step beside it.
- foreground: the app sent to the background (Settings in front) for BACKGROUND_S, then brought
  back; the sample is the foreground attempt's begin to its first step that says the link is up
  (`link_alive` when the link survived, else the redial's `link connected`/`connected`).

CMUX_PAIR_E2E_CONNECT_RUNS (default 6, 0 leaves the leg out) sets the samples of each kind.
Writes connect.json beside SUMMARY.md and returns one summary line per kind.
"""
import json
import os
import re
import subprocess
import time

LINE = re.compile(r"timing (\w+) (.+?) \+?(\d+)ms(?: \((\d+)ms\))?")
LAUNCH_MARK = re.compile(r"timing launch (\w+) \((\d+)ms\)")
BEGIN = re.compile(r"timing (\w+) begin \((\d+)ms since process start\)")
LIVE = re.compile(r"timing launch workspace_row_live \((\d+)ms\)")
UP_STEPS = ("link_alive", "link connected", "connected", "link_up", "workspace_row_live")
BACKGROUND_S = 20


def runs():
    try:
        return max(0, min(20, int(os.environ.get("CMUX_PAIR_E2E_CONNECT_RUNS", "6"))))
    except ValueError:
        return 6


def pct(values, p):
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    k = max(0, min(len(vals) - 1, int(round(p / 100 * (len(vals) - 1)))))
    return vals[k]


def lines_since(stream, since):
    with stream.cond:
        return [line for at, line in zip(stream.times, stream.lines) if at >= since]


def parse(lines, attempt):
    """{step: (ms in the attempt, ms since process start)} of one attempt's lines, first of each."""
    steps = {}
    for line in lines:
        m = LAUNCH_MARK.search(line)
        if m and attempt == "launch":
            steps.setdefault(m.group(1), (int(m.group(2)), int(m.group(2))))
            continue
        m = LINE.search(line)
        if m and m.group(1) == attempt and m.group(2) != "begin":
            total = int(m.group(4)) if m.group(4) else None
            steps.setdefault(m.group(2).strip(), (int(m.group(3)), total))
    return steps


def connect_leg(simctl, udid, bundle_id, phone_env, phone_log, phone_shot, out, note):
    n = runs()
    if n == 0:
        return "left out (CMUX_PAIR_E2E_CONNECT_RUNS=0)"
    cold, fg = [], []
    for i in range(n):
        subprocess.run(simctl + ["terminate", udid, bundle_id], capture_output=True, timeout=60)
        time.sleep(1.0)
        since = time.monotonic()
        subprocess.run(simctl + ["launch", udid, bundle_id, "-cmux-mobile-tab", "workspaces"],
                       env=phone_env, capture_output=True, timeout=60)
        hit = phone_log.wait_at(LIVE, 45, since=since)
        time.sleep(2.0)  # bounded: the steps logged just after the live row
        steps = parse(lines_since(phone_log, since), "launch")
        live = steps.get("workspace_row_live")
        cold.append({"run": i + 1, "usable_ms": live[0] if live else None,
                     "cached_row_ms": (steps.get("workspace_row_cached") or (None,))[0],
                     "steps": {k: v[0] for k, v in steps.items()}, "timed_out": hit is None})
        if i == 0:
            seen = lines_since(phone_log, since)
            timing = [line for line in seen if " timing " in f" {line}" or "timing " in line]
            note(f"- connect leg, first cold launch: {len(seen)} phone log lines, {len(timing)} timing lines, "
                 f"launch steps {sorted(steps)}; last timing lines: {[t[-140:] for t in timing[-4:]]}; "
                 f"{phone_shot('connect-cold-1')}")
    for i in range(n):
        subprocess.run(simctl + ["launch", udid, "com.apple.Preferences"], capture_output=True, timeout=60)
        time.sleep(BACKGROUND_S)
        since = time.monotonic()
        subprocess.run(simctl + ["launch", udid, bundle_id], env=phone_env, capture_output=True, timeout=60)
        phone_log.wait_at(re.compile(r"timing foreground (link_alive|link connected|connected)"), 30, since=since)
        time.sleep(1.0)
        steps = parse(lines_since(phone_log, since), "foreground")
        up = next(((k, steps[k][0]) for k in UP_STEPS if k in steps), (None, None))
        fg.append({"run": i + 1, "back_ms": up[1], "by": up[0], "steps": {k: v[0] for k, v in steps.items()}})
    subprocess.run(simctl + ["terminate", udid, bundle_id], capture_output=True, timeout=60)
    usable = [r["usable_ms"] for r in cold]
    cached = [r["cached_row_ms"] for r in cold]
    back = [r["back_ms"] for r in fg]
    result = {"harness": "scripts/ci/pair_e2e_connect.py (cmux-next-ios-sim.sh pair-e2e)",
              "background_s": BACKGROUND_S, "cold": cold, "foreground": fg,
              "summary": {"cold_usable_ms": {"p50": pct(usable, 50), "p90": pct(usable, 90), "samples": usable},
                          "cold_cached_row_ms": {"p50": pct(cached, 50), "p90": pct(cached, 90), "samples": cached},
                          "foreground_back_ms": {"p50": pct(back, 50), "p90": pct(back, 90), "samples": back}}}
    with open(os.path.join(out, "connect.json"), "w") as f:
        json.dump(result, f, indent=1)
    s = result["summary"]
    note(f"- connect, cold launch to first live workspace row (ms since process start): "
         f"p50 {s['cold_usable_ms']['p50']}, p90 {s['cold_usable_ms']['p90']}, samples {usable}; "
         f"first cached row p50 {s['cold_cached_row_ms']['p50']}")
    note(f"- connect, foreground after {BACKGROUND_S} s in the background to the link up: "
         f"p50 {s['foreground_back_ms']['p50']}, p90 {s['foreground_back_ms']['p90']}, samples {back} "
         f"(by {[r['by'] for r in fg]})")
    return "connect.json"
