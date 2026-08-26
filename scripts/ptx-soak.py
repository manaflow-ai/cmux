#!/usr/bin/env python3
"""15-minute engaged relay-only soak for the v2 peer transport (ptx).

Drives real use of the iOS app in an isolated simulator against a tagged Mac
build while every byte of app traffic rides the ptx transport through the
relay, then classifies EVERY structured event both sides emitted and issues a
verdict against the acceptance gate:

  1. zero session-end events without an expected attributed reason
  2. any reconnection completes in <= RECONNECT_BUDGET_MS
  3. zero disconnects (no unattributed session-end at all)
  4. initial connection (dial-start -> session-ready) <= INITIAL_BUDGET_MS
  5. credential rotations are zero-gap (no session-end around rotation)

Usage:
  scripts/ptx-soak.py --tag trx --udid <sim-udid> [--minutes 15]
      [--phase engage|verdict-only] [--events-dir artifacts/ptx-soak]

The harness expects:
  - tagged Mac app running (ptx host enabled, default-on in DEBUG)
  - tagged iOS app installed + signed in on the simulator via
    mobile-dev-launch.sh (agent profile), with defaults keys set:
      dev.cmux.ptx.enabled = 1, dev.cmux.ptx.relayOnly = 1
  - bootstrap already completed once (routing flipped to ptx), so this run's
    launch dials ptx from the start.
"""

import argparse
import json
import os
import pathlib
import subprocess
import sys
import time

EXPECTED_END_REASONS = {
    # Deliberate, attributed closes that do not fail the soak.
    "superseded",
    "user-requested",
    "host-stopping",
    "explicit-redial",
}
INITIAL_BUDGET_MS = 3000
RECONNECT_BUDGET_MS = 3000


def sh(cmd, check=True, capture=True):
    result = subprocess.run(
        cmd, shell=isinstance(cmd, str), capture_output=capture, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"command failed ({result.returncode}): {cmd}\n{result.stderr}")
    return result.stdout.strip() if capture else ""


def ios_events_path(udid, bundle_id):
    container = sh(f"xcrun simctl get_app_container {udid} {bundle_id} data")
    return pathlib.Path(container) / "Documents" / "ptx-events.jsonl"


def mac_events_path(tag):
    base = pathlib.Path.home() / "Library" / "Application Support"
    candidates = sorted(base.glob(f"cmux*{tag}*/ptx-events.jsonl")) + sorted(
        base.glob("cmux*/ptx-events.jsonl"))
    for candidate in candidates:
        if candidate.exists():
            return candidate
    return None


def read_events(path):
    events = []
    if not path or not pathlib.Path(path).exists():
        return events
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                events.append({"kind": "harness-parse-error", "raw": line[:200]})
    return events


def type_text(udid, text):
    """Keystrokes into the frontmost app on the sim (terminal input)."""
    subprocess.run(
        ["idb", "ui", "text", "--udid", udid, text],
        capture_output=True, text=True, timeout=30)


def press_key(udid, keycode):
    subprocess.run(
        ["idb", "ui", "key", "--udid", udid, str(keycode)],
        capture_output=True, text=True, timeout=15)


def mac_burst(tag, workspace, surface, size):
    """Streamed output burst in the surface the phone is viewing."""
    env = os.environ.copy()
    env["CMUX_TAG"] = tag
    subprocess.run(
        ["scripts/cmux-debug-cli.sh", "send", "--workspace", workspace,
         "--surface", surface, f"seq 1 {size}"],
        capture_output=True, text=True, timeout=30, env=env,
        cwd=str(pathlib.Path(__file__).resolve().parent.parent))


def engage(args, deadline):
    """The engagement loop: typing, output bursts, until the deadline."""
    i = 0
    while time.time() < deadline:
        i += 1
        stamp = time.strftime("%H:%M:%S")
        try:
            type_text(args.udid, f"echo soak-{i}-{stamp}")
            press_key(args.udid, 40)  # return
        except Exception as error:  # noqa: BLE001 - engagement is best-effort
            print(f"[engage] typing failed: {error}", flush=True)
        if i % 3 == 0 and args.mac_workspace and args.mac_surface:
            try:
                mac_burst(args.tag, args.mac_workspace, args.mac_surface, 2000)
            except Exception as error:  # noqa: BLE001
                print(f"[engage] burst failed: {error}", flush=True)
        remaining = int(deadline - time.time())
        print(f"[engage] round {i} done, {remaining}s left", flush=True)
        time.sleep(args.interval)


def classify(events, side):
    """Returns (rows, failures). Every event gets a classification row."""
    rows = []
    failures = []
    dial_started_at = {}
    admitted_count = 0
    first_admit_ms = None
    last_end_mono = None

    for event in events:
        kind = event.get("kind", "?")
        mono = event.get("mono", 0)
        reason = event.get("reason") or ""
        cls = "ok"
        note = ""

        if kind == "dial-start":
            dial_started_at[event.get("detail", {}).get("attempt", "?")] = mono
            if admitted_count > 0:
                # A redial after we were connected: needs an expected cause.
                if not any(tag in reason for tag in ("bootstrap", "launch", "explicit")):
                    cls = "reconnect"
                    note = f"redial after {admitted_count} admissions, reason={reason}"
        elif kind == "dial-admitted":
            admitted_count += 1
            ms = event.get("ms")
            if admitted_count == 1:
                first_admit_ms = ms
                if ms is not None and ms > INITIAL_BUDGET_MS:
                    cls = "FAIL"
                    note = f"initial connect {ms}ms > {INITIAL_BUDGET_MS}ms"
                    failures.append(f"{side}: {note}")
            else:
                if last_end_mono is not None and mono - last_end_mono > RECONNECT_BUDGET_MS:
                    cls = "FAIL"
                    note = (f"reconnect took {mono - last_end_mono}ms "
                            f"(end->ready) > {RECONNECT_BUDGET_MS}ms")
                    failures.append(f"{side}: {note}")
        elif kind == "session-end":
            last_end_mono = mono
            if reason in EXPECTED_END_REASONS:
                cls = "expected-end"
            else:
                cls = "FAIL"
                note = f"unattributed/unexpected session end: {reason or 'NONE'}"
                failures.append(f"{side}: {note} (mono={mono})")
        elif kind == "dial-failed":
            cls = "FAIL" if admitted_count else "warn"
            note = f"dial failed: {reason}"
            if cls == "FAIL":
                failures.append(f"{side}: dial-failed mid-soak: {reason}")
        elif kind in ("credential-error", "frame-error", "endpoint-failed",
                      "admission-denied", "harness-parse-error"):
            cls = "FAIL"
            note = json.dumps(event.get("detail", {}))[:160]
            failures.append(f"{side}: {kind} {reason} {note}")
        elif kind == "livenessDegraded" or kind == "liveness-degraded":
            cls = "warn"
            note = "missed pongs (diagnostic)"

        rows.append((event.get("ts", 0), side, kind, reason, cls, note))

    if admitted_count == 0:
        failures.append(f"{side}: no admission at all")
    return rows, failures, first_admit_ms


def verdict(args):
    ios_path = ios_events_path(args.udid, args.bundle_id) if args.udid else None
    mac_path = mac_events_path(args.tag)
    print(f"[verdict] ios events: {ios_path}")
    print(f"[verdict] mac events: {mac_path}")
    ios_events = read_events(ios_path)
    mac_events = read_events(mac_path)

    out_dir = pathlib.Path(args.events_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, events in (("ios", ios_events), ("mac", mac_events)):
        with open(out_dir / f"{name}-events.jsonl", "w") as f:
            for event in events:
                f.write(json.dumps(event) + "\n")

    all_rows = []
    all_failures = []
    ios_rows, ios_failures, ios_first_ms = classify(ios_events, "ios")
    mac_rows, mac_failures, _ = classify(mac_events, "mac")
    all_rows = sorted(ios_rows + mac_rows)
    all_failures = ios_failures + mac_failures

    print(f"\n{'='*80}\nEVENT CLASSIFICATION ({len(all_rows)} events)\n{'='*80}")
    for ts, side, kind, reason, cls, note in all_rows:
        stamp = time.strftime("%H:%M:%S", time.localtime(ts))
        flag = "" if cls == "ok" else f"  <-- {cls.upper()} {note}"
        print(f"{stamp} [{side:>3}] {kind:<22} {reason:<28}{flag}")

    print(f"\n{'='*80}\nVERDICT\n{'='*80}")
    print(f"initial connect (phone): {ios_first_ms}ms (budget {INITIAL_BUDGET_MS}ms)")
    if all_failures:
        print(f"FAIL: {len(all_failures)} finding(s):")
        for failure in all_failures:
            print(f"  - {failure}")
        return 1
    print("PASS: every event classified, no unattributed reconnects/disconnects.")
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--udid", default=None)
    parser.add_argument("--bundle-id", default=None)
    parser.add_argument("--minutes", type=float, default=15)
    parser.add_argument("--interval", type=int, default=20)
    parser.add_argument("--phase", choices=["engage", "verdict-only", "full"],
                        default="full")
    parser.add_argument("--events-dir", default="artifacts/ptx-soak")
    parser.add_argument("--mac-workspace", default=None)
    parser.add_argument("--mac-surface", default=None)
    args = parser.parse_args()

    if args.bundle_id is None and args.udid:
        listed = sh(f"xcrun simctl listapps {args.udid} | grep -o "
                    f"'dev.cmux.ios[a-z0-9.]*' | head -1", check=False)
        args.bundle_id = listed or "dev.cmux.ios"
        print(f"[soak] bundle id: {args.bundle_id}")

    if args.phase in ("engage", "full"):
        deadline = time.time() + args.minutes * 60
        print(f"[soak] engaging for {args.minutes} minutes...")
        engage(args, deadline)
    if args.phase in ("verdict-only", "full"):
        sys.exit(verdict(args))


if __name__ == "__main__":
    main()
