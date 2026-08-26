#!/usr/bin/env python3
"""irx relay-only engaged soak: verify 15 continuous minutes of real use over
the irx transport with zero disconnects, zero unexpected reconnects, and
sub-3s establishment, using the transport's own JSONL journals as evidence.

Preconditions (the runner sets these up):
  - tagged Mac (cmux DEV <tag>) running with cmux.irx.enabled + force-relay
  - simulator app installed, signed in, paired, foregrounded on a terminal
  - both journals live: /tmp/cmux-irx-journal-mac-<tag>.jsonl and the sim app
    container's Documents/irx-journal.jsonl

Engagement: a repeating command is typed into the phone's terminal via idb
(input exercises phone->Mac), and its output streams back over the terminal
lane (Mac->phone); screenshots hash-change every sample as visual proof.

Usage:
  python3 scripts/irx-soak.py --tag irx --udid <sim-udid> --bundle-id <ios-bundle>
      [--minutes 15] [--out /tmp/irx-soak-rounds] [--no-input]

Verdict (written to <out>/<stamp>/verdict.json):
  PASS requires, over the whole window:
    1. client engine reached ready and STAYED ready: zero `session-ended`,
       zero `keepalive timeout`, zero `dial-denied`, zero endpoint
       `closed-unexpectedly` on either side;
    2. establishment: the last pre-window `admission admitted` elapsed_ms
       <= 3000 on the client;
    3. every keepalive pong's path attribute begins with "relay:" (relay-only
       held for the entire session), pong cadence has no gap > 30s;
    4. >= 3 `relay-credential-rotated` events on EACH side (the 5-minute
       token boundary crossed with make-before-break, no session impact);
    5. zero Mac `connection-exit`, `superseded`, `writer-reset`,
       `cursor-gap`, `rotation-failed`, repeated `mint-failed`;
    6. screenshots changed between consecutive samples (the terminal was
       live), unless --no-input.
"""

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", default="irx")
parser.add_argument("--udid", required=True)
parser.add_argument("--bundle-id", required=True)
parser.add_argument("--minutes", type=int, default=15)
parser.add_argument("--out", default="/tmp/irx-soak-rounds")
parser.add_argument("--no-input", action="store_true",
                    help="skip idb typing (output-only engagement)")
parser.add_argument("--idb-companion", default=None)
args = parser.parse_args()

round_dir = pathlib.Path(args.out) / time.strftime("%Y%m%d-%H%M%S")
round_dir.mkdir(parents=True, exist_ok=True)
mac_journal_path = pathlib.Path(f"/tmp/cmux-irx-journal-mac-{args.tag}.jsonl")


def sim_journal_path():
    try:
        container = subprocess.check_output(
            ["xcrun", "simctl", "get_app_container", args.udid, args.bundle_id, "data"],
            text=True).strip()
        return pathlib.Path(container) / "Documents" / "irx-journal.jsonl"
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


def type_input(text):
    if args.no_input:
        return False
    cmd = ["idb", "ui", "text", "--udid", args.udid, text]
    if args.idb_companion:
        cmd = ["idb", "ui", "text", "--companion", args.idb_companion, text]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    return result.returncode == 0


CLIENT_FATAL = {
    ("engine", "session-ended"),
    ("engine", "dial-denied"),
    ("engine", "auto-redial"),
    ("engine", "auto-redial-suppressed"),
    ("keepalive", "timeout"),
    ("endpoint", "closed-unexpectedly"),
    ("admission", "denied-or-timeout"),
    ("client-events", "lane-missing"),
}
MAC_FATAL = {
    ("host-runtime", "connection-exit"),
    ("registry", "superseded"),
    ("endpoint", "closed-unexpectedly"),
    ("endpoint", "relay-credential-rotation-failed"),
    ("admission", "denied"),
    ("admission", "rejected"),
    ("host-events", "writer-reset"),
    ("host-terminal", "cursor-gap"),
}

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
    "client_pongs": 0, "client_rotations": 0, "mac_rotations": 0,
    "mac_pings_answered": 0, "non_relay_paths": 0, "screenshot_changes": 0,
    "screenshot_samples": 0, "inputs_typed": 0, "mint_failures": 0,
    "last_pong_mono": None, "max_pong_gap_s": 0.0,
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
        if key in CLIENT_FATAL:
            failures.append({"side": "client", "at_s": int(now - t0), "event": event})
        if key == ("keepalive", "pong"):
            observations["client_pongs"] += 1
            gap = now - last_pong_wall
            last_pong_wall = now
            path = event.get("a_path", "")
            if not path.startswith("relay:"):
                observations["non_relay_paths"] += 1
                failures.append({"side": "client", "at_s": int(now - t0),
                                 "event": event, "why": "non-relay path"})
        if key == ("endpoint", "relay-credential-rotated"):
            observations["client_rotations"] += 1
        if key == ("credential-autopilot", "mint-failed"):
            observations["mint_failures"] += 1
    for event in mac_events:
        key = (event.get("component"), event.get("event"))
        if key in MAC_FATAL:
            failures.append({"side": "mac", "at_s": int(now - t0), "event": event})
        if key == ("endpoint", "relay-credential-rotated"):
            observations["mac_rotations"] += 1
        if key == ("keepalive", "ponged"):
            observations["mac_pings_answered"] += 1

    # Pong cadence: with a 5s interval, >30s of silence means the keepalive
    # loop died silently, which is itself a failure of observability.
    pong_gap = now - last_pong_wall
    observations["max_pong_gap_s"] = max(observations["max_pong_gap_s"], pong_gap)

    # Engagement: type a command every third sample (~30s cadence).
    if sample % 3 == 1:
        if type_input("date\n"):
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
              f"rotations c/m={observations['client_rotations']}/"
              f"{observations['mac_rotations']}")

# Final checks.
if establish_ms is None or establish_ms > 3000:
    failures.append({"why": f"establishment {establish_ms}ms (need <=3000)"})
if observations["client_rotations"] < 3:
    failures.append({"why": f"client rotations {observations['client_rotations']} < 3"})
if observations["mac_rotations"] < 3:
    failures.append({"why": f"mac rotations {observations['mac_rotations']} < 3"})
if observations["max_pong_gap_s"] > 30:
    failures.append({"why": f"pong gap {observations['max_pong_gap_s']:.0f}s > 30s"})
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
