#!/usr/bin/env python3
"""Check that this runner can bring an app to the front before UI tests run.

XCUIApplication.launch() waits about 60 seconds for the app to activate and
then fails with "Failed to activate application ... (current state: Running
Background)". When the runner's console session cannot activate apps (screen
locked or asleep, a screensaver, a system dialog holding focus), every UI test
fails that way, one minute each, and the log reads like a test bug.

This probe activates Finder in the console user's session and checks it became
the frontmost app. On a miss it tries the repairs below, probes again, and
fails in seconds with the runner's state when the session still cannot
activate apps. `--diagnose` prints the same state without probing, for a test
run that hit the activation error anyway.
"""

import argparse
import os
import plistlib
import re
import subprocess
import sys
import time

FINDER = 'com.apple.finder'
# System agents that can own the front of the session and keep an app from
# activating. Each is relaunched by launchd on demand, so stopping one only
# dismisses what it is showing.
FOCUS_HOLDING_AGENTS = {
    'com.apple.ScreenSaver.Engine': 'ScreenSaverEngine',
    'com.apple.coreservices.uiagent': 'CoreServicesUIAgent',
    'com.apple.UserNotificationCenter': 'UserNotificationCenter',
    'com.apple.SecurityAgent': 'SecurityAgent',
}


def run(command, timeout=10):
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        return 1, '', str(error)
    return result.returncode, result.stdout, result.stderr


def console_user():
    _, user, _ = run(['stat', '-f', '%Su', '/dev/console'])
    user = user.strip()
    if not user or user in ('root', 'loginwindow'):
        return None, None
    _, uid, _ = run(['id', '-u', user])
    uid = uid.strip()
    return (user, uid) if uid.isdecimal() else (None, None)


def in_session(user, uid, command):
    """Runs `command` in the console user's GUI bootstrap, as the tests do."""
    if user == os.environ.get('USER') and run(['id', '-u'])[1].strip() == uid:
        # Already the console user; sudo may be unavailable (a laptop).
        return run(['launchctl', 'asuser', uid] + command)
    return run(['sudo', '-n', 'launchctl', 'asuser', uid, 'sudo', '-n', '-H', '-u', user] + command)


def front_bundle(user, uid):
    status, asn, _ = in_session(user, uid, ['lsappinfo', 'front'])
    asn = asn.strip()
    if status or not asn:
        return None
    _, info, _ = in_session(user, uid, ['lsappinfo', 'info', '-only', 'bundleid', asn])
    match = re.search(r'"CFBundleIdentifier"\s*=\s*"([^"]*)"', info)
    return match.group(1) if match else (info.strip() or None)


def session_state():
    """The console session's lock and on-console flags from IORegistry."""
    status, out, _ = run(['ioreg', '-n', 'Root', '-d1', '-a'])
    if status:
        return {}
    try:
        users = plistlib.loads(out.encode()).get('IOConsoleUsers', [])
    except Exception:
        return {}
    for entry in users:
        if entry.get('kCGSSessionOnConsoleKey'):
            return {
                'user': entry.get('kCGSSessionUserNameKey'),
                'locked': bool(entry.get('CGSSessionScreenIsLocked')),
                'on_console': True,
            }
    return {'on_console': False}


def display_asleep():
    status, out, _ = run(['pmset', '-g', 'powerstate', 'IODisplayWrangler'])
    # Power state 4 is on; lower is dimmed or asleep. No wrangler (a VM with
    # only a virtual display) reads as awake.
    match = re.search(r'IODisplayWrangler\s+(\d+)', out)
    return bool(match) and int(match.group(1)) < 4 if status == 0 else False


def describe(user, uid):
    state = session_state()
    parts = [
        f'runner {os.environ.get("RUNNER_NAME", "?")}',
        f'console user {user or "none"}',
        f'screen locked {state.get("locked", "unknown")}',
        f'display asleep {display_asleep()}',
    ]
    if user:
        parts.append(f'frontmost app {front_bundle(user, uid) or "none"}')
    return ', '.join(parts)


def probe(user, uid, timeout=5):
    in_session(user, uid, ['open', '-b', FINDER])
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if front_bundle(user, uid) == FINDER:
            return True
        time.sleep(0.25)
    return False


def repair(user, uid):
    """Tries each repair once; returns what it did."""
    done = []
    front = front_bundle(user, uid)
    agent = FOCUS_HOLDING_AGENTS.get(front or '')
    if agent:
        in_session(user, uid, ['killall', agent])
        done.append(f'stopped {agent}, which held the front')
    # Declaring user activity wakes a sleeping display and ends a screensaver.
    in_session(user, uid, ['caffeinate', '-u', '-t', '2'])
    done.append('declared user activity')
    return done


def annotate(level, message):
    print(f'::{level}::{message}')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as handle:
            handle.write(f'**GUI activation {level}:** {message}\n\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--diagnose', action='store_true',
                        help='print the session state; never fails')
    args = parser.parse_args()

    user, uid = console_user()
    if args.diagnose:
        print(f'GUI session state: {describe(user, uid)}')
        return 0
    if not user:
        annotate('error', f'No logged-in console user, so no app can activate; no UI tests ran. {describe(user, uid)}')
        return 1
    if probe(user, uid):
        print(f'GUI activation preflight passed ({describe(user, uid)}).')
        return 0
    before = describe(user, uid)
    repairs = repair(user, uid)
    if probe(user, uid):
        annotate('warning', f'This runner could not activate apps until the preflight {", ".join(repairs)}. Before: {before}.')
        return 0
    annotate('error', 'This runner cannot bring an app to the front, so every UI test would fail with '
             '"Failed to activate application"; no UI tests ran. Re-run to take another runner. '
             f'Tried: {", ".join(repairs)}. State: {describe(user, uid)}.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
