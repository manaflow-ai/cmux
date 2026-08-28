#!/usr/bin/env python3
"""dor (account Durable Object relay) engaged soak: verify continuous real use over
the dot transport with ZERO disconnects, ZERO reconnects (not even leg-level
resumes), and <=2s establishment, using the transport's own JSONL journals.

Preconditions (the runner sets these up):
  - tagged Mac (cmux DEV <tag>) running with cmux.dor.enabled, pointed at the
    relay worker via CMUX_PRESENCE_BASE_URL
  - simulator app installed, signed in, paired, foregrounded on a terminal
  - both journals live: /tmp/cmux-dor-journal-mac-<tag>.jsonl and the sim app
    container's Documents/dor-journal.jsonl

Engagement: a repeating command is typed into the phone's terminal via idb
(input exercises phone->Mac), its output streams back (Mac->phone), and
screenshots hash-change every sample as visual proof.

Usage:
  python3 scripts/dor-soak.py --tag dor --udid <sim-udid> --bundle-id <ios-bundle>
      [--minutes 60] [--out /tmp/dor-soak-rounds] [--no-input]

Verdict (written to <out>/<stamp>/verdict.json). PASS requires, over the
whole window:
  1. zero session disconnects and zero reconnects on either side: no
     `engine session-ended` / `auto-redial` / `dial-failed`, no
     `session ended`, no `admission` denial;
  2. zero LEG interruptions: no `leg suspended` / `resumed` / `reset` /
     `closed` on either side (the resume layer exists for the field; the
     soak's bar is that it was never needed);
  3. establishment: the newest pre-window client `admission admitted`
     a_elapsed_ms <= 2000;
  4. leg keepalive pongs flow the whole hour: every pong path is "do:relay",
     no pong gap > 60s (interval is 25s);
  5. long-session auth continuity: >= 3 `leg auth-refreshed` on EACH side
     (in-band token refresh crossed multiple 10-minute boundaries with zero
     connection impact);
  6. engagement was real: inputs typed and screenshots changed between
     samples (unless --no-input).
"""

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", default="dor")
parser.add_argument("--udid", required=True)
parser.add_argument("--bundle-id", required=True)
parser.add_argument("--minutes", type=int, default=60)
parser.add_argument("--out", default="/tmp/dor-soak-rounds")
parser.add_argument("--no-input", action="store_true",
                    help="skip idb typing (output-only engagement)")
parser.add_argument("--type-point", default=None,
                    help="x,y to tap before typing (composer focus)")
parser.add_argument("--send-point", default=None,
                    help="x,y to tap after typing (send button)")
args = parser.parse_args()

round_dir = pathlib.Path(args.out) / time.strftime("%Y%m%d-%H%M%S")
round_dir.mkdir(parents=True, exist_ok=True)
mac_journal_path = pathlib.Path(f"/tmp/cmux-dor-journal-mac-{args.tag}.jsonl")


def sim_journal_path():
    try:
        container = subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", args.udid, args.bundle_id, "data"],
            text=True).strip()
        return pathlib.Path(container) / "Documents" / "dor-journal.jsonl"
    except subprocess.CalledProcessError:
        return None


def read_events(path, since_index):
    """Journal events after the given line index; tolerates partial lines."""
    if path is None or not path.exists():
        return [], since_index
    lines = path.read_text(errors="replace").splitlines()
    events = []
    for line in lines[since_index:]:
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events, len(lines)


def screenshot(label):
    out = round_dir / f"shot-{label}.png"
    subprocess.run(
        ["xcrun", "simctl", "io", args.udid, "screenshot", str(out)],
        capture_output=True)
    if out.exists():
        return hashlib.sha256(out.read_bytes()).hexdigest()
    return None


def tap(point):
    if not point:
        return
    x, y = point.split(",")
    subprocess.run(["idb", "ui", "tap", "--udid", args.udid, x, y],
                   capture_output=True, text=True, timeout=30)


def type_input(text):
    if args.no_input:
        return False
    # The multiline composer autocapitalizes and HID Return inserts a newline
    # instead of sending (see irx soak round 2): tap the composer, type, then
    # tap the send button when coordinates are provided; otherwise fall back
    # to HID Return for classic terminal input fields.
    tap(args.type_point)
    typed = subprocess.run(
        ["idb", "ui", "text", "--udid", args.udid, text],
        capture_output=True, text=True, timeout=30)
    if typed.returncode != 0:
        return False
    if args.send_point:
        tap(args.send_point)
    else:
        subprocess.run(
            ["idb", "ui", "key", "--udid", args.udid, "40"],
            capture_output=True, text=True, timeout=30)
    return True


# Any of these during the window = a reconnect or disconnect = FAIL.
CLIENT_FATAL = {
    ("engine", "session-ended"),
    ("engine", "dial-failed"),
    ("engine", "auto-redial"),
    ("session", "ended"),
    ("admission", "denied"),
    ("admission", "timeout"),
    ("leg", "suspended"),
    ("leg", "resumed"),
    ("leg", "reset"),
    ("leg", "closed"),
}
MAC_FATAL = {
    ("leg", "suspended"),
    ("leg", "resumed"),
    ("leg", "reset"),
    ("leg", "closed"),
    ("session", "ended"),
    ("host-events", "writer-reset"),
    ("host-terminal", "cursor-gap"),
}
# Session-scoped events fail the soak only for the focus device's sessions,
# so a human dogfooding another device in parallel never poisons the verdict.
MAC_FATAL_SESSION_SCOPED = {
    ("host-runtime", "connection-exit"),
}
focus_sessions = set()

sim_path = sim_journal_path()
print(f"[soak] round dir: {round_dir}")
print(f"[soak] mac journal: {mac_journal_path} exists={mac_journal_path.exists()}")
print(f"[soak] sim journal: {sim_path} exists={sim_path.exists() if sim_path else False}")

# Anchor: skip pre-existing journal content; the soak judges only its window,
# except establishment, which uses the newest admission before/at start.
_, mac_index = read_events(mac_journal_path, 0)
pre_client, sim_index = read_events(sim_path, 0)

establish_ms = None
for event in reversed(pre_client):
    if event.get("component") == "admission" and event.get("event") == "admitted":
        try:
            establish_ms = int(event.get("a_elapsed_ms", "999999"))
        except ValueError:
            establish_ms = None
        break

failures = []
observations = {
    "client_pongs": 0, "client_auth_refreshes": 0, "mac_auth_refreshes": 0,
    "non_relay_paths": 0, "screenshot_changes": 0,
    "screenshot_samples": 0, "inputs_typed": 0,
    "max_pong_gap_s": 0.0,
}
t0 = time.time()
deadline = t0 + args.minutes * 60
last_shot_hash = screenshot("t0")
last_pong_wall = time.time()
sample = 0

while time.time() < deadline:
    time.sleep(10)
    sample += 1
    now = time.time()

    client_events, sim_index = read_events(sim_path, sim_index)
    mac_events, mac_index = read_events(mac_journal_path, mac_index)

    for event in client_events:
        key = (event.get("component"), event.get("event"))
        if key == ("admission", "admitted") and event.get("a_session"):
            focus_sessions.add(event["a_session"])
        if key in CLIENT_FATAL:
            failures.append({"side": "client", "at_s": int(now - t0), "event": event})
        if key == ("keepalive", "pong"):
            observations["client_pongs"] += 1
            last_pong_wall = now
            path = event.get("a_path", "")
            if path != "do:relay":
                observations["non_relay_paths"] += 1
                failures.append({"side": "client", "at_s": int(now - t0),
                                 "event": event, "why": "non-relay path"})
        if key == ("leg", "auth-refreshed"):
            observations["client_auth_refreshes"] += 1
    for event in mac_events:
        key = (event.get("component"), event.get("event"))
        if key in MAC_FATAL:
            failures.append({"side": "mac", "at_s": int(now - t0), "event": event})
        if key in MAC_FATAL_SESSION_SCOPED and (
            event.get("a_session") in focus_sessions
            or event.get("a_old_session") in focus_sessions
        ):
            failures.append({"side": "mac", "at_s": int(now - t0), "event": event})
        if key == ("leg", "auth-refreshed"):
            observations["mac_auth_refreshes"] += 1

    # Pong cadence: with a 25s app-level ping interval, >60s of silence means
    # the keepalive loop died silently — an observability failure by itself.
    pong_gap = now - last_pong_wall
    observations["max_pong_gap_s"] = max(observations["max_pong_gap_s"], pong_gap)

    # Engagement: type a command every third sample (~30s cadence).
    if sample % 3 == 1:
        if type_input("date"):
            observations["inputs_typed"] += 1
    # Visual liveness every sixth sample (~60s).
    if sample % 6 == 0:
        shot = screenshot(f"t{int(now - t0)}")
        observations["screenshot_samples"] += 1
        if shot and shot != last_shot_hash:
            observations["screenshot_changes"] += 1
        last_shot_hash = shot

    if failures:
        print(f"[soak] +{int(now - t0)}s FAILURES so far: {len(failures)}")
    else:
        print(f"[soak] +{int(now - t0)}s OK pongs={observations['client_pongs']} "
              f"auth c/m={observations['client_auth_refreshes']}/"
              f"{observations['mac_auth_refreshes']} "
              f"gap={pong_gap:.0f}s")

# Final checks.
if establish_ms is None or establish_ms > 2000:
    failures.append({"why": f"establishment {establish_ms}ms (need <=2000)"})
if observations["max_pong_gap_s"] > 60:
    failures.append({"why": f"pong gap {observations['max_pong_gap_s']:.0f}s > 60s"})
if args.minutes >= 30:
    if observations["client_auth_refreshes"] < 3:
        failures.append({"why": f"client auth refreshes {observations['client_auth_refreshes']} < 3"})
    if observations["mac_auth_refreshes"] < 3:
        failures.append({"why": f"mac auth refreshes {observations['mac_auth_refreshes']} < 3"})
if not args.no_input and observations["inputs_typed"] == 0:
    failures.append({"why": "no input ever typed (engagement broken)"})
if observations["screenshot_samples"] > 0 and observations["screenshot_changes"] == 0:
    failures.append({"why": "screen never changed (stream frozen?)"})

verdict = "PASS" if not failures else "FAIL"
result = {
    "verdict": verdict,
    "minutes": args.minutes,
    "establish_ms": establish_ms,
    "observations": observations,
    "failures": failures,
}
(round_dir / "verdict.json").write_text(json.dumps(result, indent=2, default=str))
# Preserve both journals as evidence.
if mac_journal_path.exists():
    (round_dir / "mac-journal.jsonl").write_text(mac_journal_path.read_text(errors="replace"))
if sim_path and sim_path.exists():
    (round_dir / "sim-journal.jsonl").write_text(sim_path.read_text(errors="replace"))
print(f"[soak] VERDICT: {verdict}")
print(json.dumps(result, indent=2, default=str))
sys.exit(0 if verdict == "PASS" else 1)
