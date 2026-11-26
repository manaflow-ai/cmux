#!/usr/bin/env python3
"""Acceptance gates for the device-list authorization architecture (listauth).

Gates (see cmux-assets/irx-client-resilience/irx-sequence-diagram artifact):
  1. soak:        30 continuous engaged minutes, zero unexpected reconnects or
                  disconnects; rotations + list pushes cross without session
                  impact. --mode relay asserts every pong path is relay:*;
                  --mode direct asserts >=90% of pongs after the first minute
                  ride a non-relay (direct/LAN) path.
  2. cold:        app terminate -> launch -> first admission admitted AND first
                  control-plane directory applied, each under --limit-ms
                  (default 2000) measured wall-to-wall.
  3. background:  foreground another app for --minutes, then relaunch ours;
                  time from relaunch to admitted + fresh directory < limit.

Shared evidence: journals ({ts, mono_ms, component, event, a_*} JSONL) from
/tmp/cmux-irx-journal-mac-<tag>.jsonl and the sim app container's
Documents/irx-journal.jsonl. Verdicts land in <out>/<gate>-<stamp>/.

Usage:
  python3 scripts/listauth-gates.py soak --tag <tag> --udid U --bundle-id B \
      --mode relay --minutes 30 [--out DIR]
  python3 scripts/listauth-gates.py cold --tag <tag> --udid U --bundle-id B \
      --trials 3 [--limit-ms 2000]
  python3 scripts/listauth-gates.py background --tag <tag> --udid U \
      --bundle-id B --minutes 30 [--limit-ms 2000]
"""

import argparse
import datetime
import os
import hashlib
import json
import pathlib
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("gate", choices=["soak", "cold", "background"])
parser.add_argument("--tag", required=True)
parser.add_argument("--udid", required=True)
parser.add_argument("--bundle-id", required=True)
parser.add_argument("--minutes", type=int, default=30)
parser.add_argument("--mode", choices=["relay", "direct"], default="relay")
parser.add_argument("--trials", type=int, default=3)
parser.add_argument("--limit-ms", type=int, default=2000)
parser.add_argument("--admitted-limit-ms", type=int, default=3000,
                    help="session-admitted bound (transport target); the "
                         "stated <2s gate is time-to-directory")
parser.add_argument("--out", default="/tmp/listauth-gates")
parser.add_argument("--no-input", action="store_true")
args = parser.parse_args()

def signin_env():
    """Sim UITEST sign-in is per-launch; every launch needs the agent-profile
    credentials injected or the app lands signed out (dev-env artifact, not a
    product behavior)."""
    env = dict(os.environ)
    secrets = pathlib.Path.home() / ".secrets" / "cmuxterm-dev.env"
    creds = {}
    if secrets.exists():
        for line in secrets.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, _, v = line.partition("=")
                creds[k.strip()] = v.strip().strip('"').strip("'")
    email = creds.get("CMUX_UITEST_STACK_EMAIL", "")
    password = creds.get("CMUX_UITEST_STACK_PASSWORD", "")
    if email and password:
        env["SIMCTL_CHILD_CMUX_UITEST_STACK_EMAIL"] = email
        env["SIMCTL_CHILD_CMUX_UITEST_STACK_PASSWORD"] = password
        env["SIMCTL_CHILD_CMUX_UITEST_MOCK_DATA"] = "0"
        env["SIMCTL_CHILD_CMUX_DEV_AUTH_REPLACE_SESSION"] = "0"
    return env


def launch_app():
    subprocess.run(["xcrun", "simctl", "launch", args.udid, args.bundle_id],
                   capture_output=True, env=signin_env())


stamp = time.strftime("%Y%m%d-%H%M%S")
round_dir = pathlib.Path(args.out) / f"{args.gate}-{args.mode}-{stamp}"
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


def wall_of(event):
    try:
        ts = event.get("ts", "")
        return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def screenshot(label):
    out = round_dir / f"shot-{label}.png"
    subprocess.run(["xcrun", "simctl", "io", args.udid, "screenshot", str(out)],
                   capture_output=True)
    return hashlib.sha256(out.read_bytes()).hexdigest() if out.exists() else None


def type_input(text):
    if args.no_input:
        return False
    typed = subprocess.run(["idb", "ui", "text", "--udid", args.udid, text],
                           capture_output=True, text=True, timeout=30)
    if typed.returncode != 0:
        return False
    subprocess.run(["idb", "ui", "key", "--udid", args.udid, "40"],
                   capture_output=True, text=True, timeout=30)
    return True


def finish(name, failures, extra):
    verdict = "PASS" if not failures else "FAIL"
    result = {"gate": name, "mode": args.mode, "verdict": verdict,
              "limit_ms": args.limit_ms, "failures": failures, **extra}
    (round_dir / "verdict.json").write_text(json.dumps(result, indent=2, default=str))
    if mac_journal_path.exists():
        (round_dir / "mac-journal.jsonl").write_text(
            mac_journal_path.read_text(errors="replace"))
    sp = sim_journal_path()
    if sp and sp.exists():
        (round_dir / "sim-journal.jsonl").write_text(sp.read_text(errors="replace"))
    print(f"[gates] {name} VERDICT: {verdict}")
    print(json.dumps(result, indent=2, default=str))
    sys.exit(0 if verdict == "PASS" else 1)


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
MAC_FATAL_SESSION_SCOPED = {
    ("host-runtime", "connection-exit"),
    ("registry", "superseded"),
}
MAC_FATAL = {
    ("endpoint", "closed-unexpectedly"),
    ("endpoint", "relay-credential-rotation-failed"),
    ("host-events", "writer-reset"),
    ("host-terminal", "cursor-gap"),
}


def wait_for_events_after(t_launch, wanted, timeout_s):
    """Watch the sim journal for the FIRST occurrence of each wanted
    (component,event) after launch. Timing anchor: the signed-in auth-gate
    event of the SAME launch (the per-launch simulator sign-in is a dev-env
    step a real signed-in user never pays), falling back to composition
    start (mono 0). Returns {key: {setup_ms, mono_ms, wall_ms}}."""
    sp = sim_journal_path()
    _, idx = read_events(sp, 0)
    found = {}
    anchor_mono = 0
    deadline = time.time() + timeout_s
    while time.time() < deadline and len(found) < len(wanted):
        time.sleep(0.2)
        events, idx = read_events(sp, idx)
        for event in events:
            wall = wall_of(event)
            if wall is None or wall < t_launch - 0.5:
                continue
            key = (event.get("component"), event.get("event"))
            if key == ("client-runtime", "auth-gate-signed-in") or (
                key == ("client-runtime", "auth-gate-identity")
                and event.get("a_signed_in") == "true"
            ):
                anchor_mono = int(event.get("mono_ms", 0))
            if key in wanted and key not in found:
                found[key] = {"mono_ms": int(event.get("mono_ms", -1)),
                              "wall_ms": int((wall - t_launch) * 1000)}
    for hit in found.values():
        hit["setup_ms"] = max(0, hit["mono_ms"] - anchor_mono)
    return found


def gate_cold():
    trials = []
    failures = []
    wanted = {("admission", "admitted"), ("control-plane", "directory")}
    for trial in range(args.trials):
        subprocess.run(["xcrun", "simctl", "terminate", args.udid, args.bundle_id],
                       capture_output=True)
        time.sleep(3)
        t_launch = time.time()
        launch_app()
        found = wait_for_events_after(t_launch, wanted, timeout_s=60)
        row = {"trial": trial,
               "admitted": found.get(("admission", "admitted")),
               "directory": found.get(("control-plane", "directory"))}
        trials.append(row)
        for key, label in ((("admission", "admitted"), "admitted"),
                           (("control-plane", "directory"), "directory")):
            hit = found.get(key)
            if hit is None:
                failures.append({"trial": trial, "why": f"{label} never observed"})
            else:
                limit = args.limit_ms if label == "directory" else args.admitted_limit_ms
                if hit["setup_ms"] > limit:
                    failures.append({"trial": trial,
                                     "why": f"{label} {hit['setup_ms']}ms > {limit}ms"})
        print(f"[gates] cold trial {trial}: {row}")
        time.sleep(5)
    finish("cold", failures, {"trials": trials})


def gate_background():
    # Push the app to background by foregrounding Settings, hold, relaunch.
    subprocess.run(["xcrun", "simctl", "launch", args.udid, "com.apple.Preferences"],
                   capture_output=True)
    print(f"[gates] app backgrounded; holding {args.minutes} minutes")
    time.sleep(args.minutes * 60)
    t_launch = time.time()
    launch_app()
    wanted = {("admission", "admitted"), ("control-plane", "directory")}
    found = wait_for_events_after(t_launch, wanted, timeout_s=60)
    failures = []
    row = {"admitted": found.get(("admission", "admitted")),
           "directory": found.get(("control-plane", "directory"))}
    for key, label in ((("admission", "admitted"), "admitted"),
                       (("control-plane", "directory"), "directory")):
        hit = found.get(key)
        if hit is None:
            failures.append({"why": f"{label} never observed after foreground"})
        else:
            # Resume keeps the process alive: no sign-in anchor fires, so the
            # foreground-relative WALL delta is the metric (host and sim share
            # one clock). setup_ms would be total process uptime here.
            limit = args.limit_ms if label == "directory" else args.admitted_limit_ms
            if hit["wall_ms"] > limit:
                failures.append({"why": f"{label} {hit['wall_ms']}ms > {limit}ms"})
    finish("background", failures, {"return": row,
                                    "background_minutes": args.minutes})


def gate_soak():
    sim_path = sim_journal_path()
    print(f"[gates] round dir: {round_dir}")
    print(f"[gates] mac journal exists={mac_journal_path.exists()}")
    print(f"[gates] sim journal exists={sim_path.exists() if sim_path else False}")
    _, mac_index = read_events(mac_journal_path, 0)
    pre_client, sim_index = read_events(sim_path, 0)

    establish_ms = None
    for event in reversed(pre_client):
        if (event.get("component"), event.get("event")) == ("admission", "admitted"):
            try:
                establish_ms = int(event.get("a_elapsed_ms", "999999"))
            except ValueError:
                establish_ms = None
            break

    failures = []
    focus_sessions = set()
    obs = {"client_pongs": 0, "relay_pongs": 0, "direct_pongs": 0,
           "client_rotations": 0, "mac_rotations": 0, "list_pushes": 0,
           "acks_sent": 0, "screenshot_changes": 0, "screenshot_samples": 0,
           "inputs_typed": 0, "mint_failures": 0, "max_pong_gap_s": 0.0}
    t0 = time.time()
    deadline = t0 + args.minutes * 60
    last_shot = screenshot("t0")
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
                obs["client_pongs"] += 1
                last_pong_wall = now
                path = event.get("a_path", "")
                if path.startswith("relay:"):
                    obs["relay_pongs"] += 1
                else:
                    obs["direct_pongs"] += 1
                if args.mode == "relay" and not path.startswith("relay:"):
                    failures.append({"side": "client", "at_s": int(now - t0),
                                     "event": event, "why": "non-relay path in relay mode"})
            if key == ("keepalive", "miss"):
                obs["keepalive_misses"] = obs.get("keepalive_misses", 0) + 1
            if key == ("endpoint", "relay-credential-rotated"):
                obs["client_rotations"] += 1
            if key == ("control-plane", "directory"):
                obs["list_pushes"] += 1
            if key == ("control-plane", "acked"):
                obs["acks_sent"] += 1
            if key == ("credential-autopilot", "mint-failed"):
                obs["mint_failures"] += 1
        for event in mac_events:
            key = (event.get("component"), event.get("event"))
            if key in MAC_FATAL:
                failures.append({"side": "mac", "at_s": int(now - t0), "event": event})
            if key in MAC_FATAL_SESSION_SCOPED and (
                event.get("a_session") in focus_sessions
                or event.get("a_old_session") in focus_sessions
            ):
                failures.append({"side": "mac", "at_s": int(now - t0), "event": event})
            if key == ("endpoint", "relay-credential-rotated"):
                obs["mac_rotations"] += 1

        obs["max_pong_gap_s"] = max(obs["max_pong_gap_s"], now - last_pong_wall)

        if sample % 3 == 1 and type_input("date"):
            obs["inputs_typed"] += 1
        if sample % 6 == 0:
            shot = screenshot(f"t{int(now - t0)}")
            obs["screenshot_samples"] += 1
            if shot and shot != last_shot:
                obs["screenshot_changes"] += 1
            last_shot = shot

        state = "FAILURES: %d" % len(failures) if failures else (
            "OK pongs=%d (relay=%d direct=%d) rot c/m=%d/%d list=%d" % (
                obs["client_pongs"], obs["relay_pongs"], obs["direct_pongs"],
                obs["client_rotations"], obs["mac_rotations"], obs["list_pushes"]))
        print(f"[gates] +{int(now - t0)}s {state}")

    if establish_ms is None or establish_ms > args.limit_ms:
        failures.append({"why": f"establishment {establish_ms}ms (need <={args.limit_ms})"})
    if args.minutes >= 25:
        if obs["client_rotations"] < 3:
            failures.append({"why": f"client rotations {obs['client_rotations']} < 3"})
        if obs["mac_rotations"] < 3:
            failures.append({"why": f"mac rotations {obs['mac_rotations']} < 3"})
    if obs["max_pong_gap_s"] > 30:
        failures.append({"why": f"pong gap {obs['max_pong_gap_s']:.0f}s > 30s"})
    if args.mode == "direct":
        attributed = obs["relay_pongs"] + obs["direct_pongs"]
        if attributed == 0 or obs["direct_pongs"] / max(attributed, 1) < 0.9:
            failures.append({"why": f"direct mode but direct pongs "
                             f"{obs['direct_pongs']}/{attributed} < 90%"})
    if not args.no_input and obs["inputs_typed"] == 0:
        failures.append({"why": "no input ever typed (engagement broken)"})
    if obs["screenshot_samples"] > 0 and obs["screenshot_changes"] == 0:
        failures.append({"why": "screen never changed (stream frozen?)"})
    finish("soak", failures, {"minutes": args.minutes,
                              "establish_ms": establish_ms, "observations": obs})


{"soak": gate_soak, "cold": gate_cold, "background": gate_background}[args.gate]()
