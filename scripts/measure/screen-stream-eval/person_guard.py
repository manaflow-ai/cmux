"""Refuses targets that open windows or post input on a Mac a person uses.

An Apple Screen Sharing run on an owner's own Mac took focus with AppleScript, hung, and left a
window he could not quit (2026-11-16). Such targets now run only on dedicated fleet Macs, or on an
unknown Mac nobody has touched for a while. There is no override: a person's Mac is refused.

  python3 -I person_guard.py check TARGETS_CSV [viewer]   (exit 0 allowed, 2 refused with one stderr line)

`viewer` says this Mac only views (viewer-of=). apple-rfb's viewer is a headless protocol client
that opens no window and posts nothing on the Mac it runs on, so it may view from a person's Mac;
its input lands on the host Mac, which is checked like any other.
"""
import glob
import json
import os
import pwd
import re
import subprocess
import sys

# The roles the fleet's own reboot and heartbeat tools already refuse to touch.
PERSON_ROLES = {"attended", "leo-mac", "interactive"}
IDLE_REQUIRED_S = 600
NEXT_STEP = 'run it with the viewer and host on dedicated fleet Macs (README.md, "Two Macs")'


def opens_windows(target, viewer=False):
    # Every Apple viewer variant and Moonlight drive a GUI viewer; cmux's own viewers and capture
    # probes do not. apple-rfb posts RFB input to the host's screen, so only its viewer is headless.
    if target == "apple-rfb" and viewer:
        return False
    return target.startswith("apple") or target == "moonlight"


def find_registry(env_path, home):
    if env_path:
        return env_path if os.path.isfile(env_path) else None
    for path in sorted(glob.glob(os.path.join(home, "Projects", "*", "machines", "fleet-registry.json"))):
        if os.path.isfile(path):
            return path
    return None


def load_registry(path):
    if not path:
        return None
    try:
        with open(path) as f:
            machines = json.load(f).get("machines")
    except (OSError, ValueError, AttributeError):
        return None
    return machines if isinstance(machines, dict) else None


def _run(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def local_names(run=_run):
    # scutil is macOS only; elsewhere hostname -s alone names the machine.
    names = []
    for argv in (["scutil", "--get", "LocalHostName"], ["scutil", "--get", "ComputerName"], ["hostname", "-s"]):
        name = run(argv).strip().lower()
        if name and name not in names:
            names.append(name)
    return names


def _entry_names(key, entry):
    names = {key.lower()}
    names.update(a.lower() for a in entry.get("aliases") or [] if isinstance(a, str))
    for value in (entry.get("address") or {}).values():
        # An IP's first octet names nothing.
        if isinstance(value, str) and not re.match(r"^[0-9.]+$|.*:", value):
            names.add(value.split(".")[0].lower())
    return names


def match_entries(machines, names):
    wanted = set(names)
    return [(key, entry) for key, entry in sorted(machines.items())
            if isinstance(entry, dict) and _entry_names(key, entry) & wanted]


def idle_seconds(ioreg_output):
    # The smallest HIDIdleTime is the most recent input on any device; none read means unknown.
    values = [int(v) for v in re.findall(r'"HIDIdleTime"\s*=\s*(\d+)', ioreg_output or "")]
    return min(values) / 1e9 if values else None


def decide(targets, names, machines, idle_s, viewer=False):
    """(None, None) when allowed, else (target, reason) for the first refused target."""
    gui = [t for t in targets if opens_windows(t, viewer)]
    if not gui:
        return None, None
    matches = match_entries(machines, names) if machines else []
    for key, entry in matches:
        roles = sorted(PERSON_ROLES & set(entry.get("roles") or []))
        if roles:
            return gui[0], f"a person's Mac (fleet registry {key}, role {', '.join(roles)})"
    if matches:
        return None, None
    where = "not in the fleet registry" if machines else "not known (no fleet registry found)"
    if idle_s is None:
        return gui[0], f"{where} and its console idle time is unreadable"
    if idle_s < IDLE_REQUIRED_S:
        return gui[0], f"{where} and its console was used {int(idle_s)} s ago (needs {IDLE_REQUIRED_S} s idle)"
    return None, None


def message(target, host, reason):
    return f"screen-stream-eval: refused: {target} opens windows or posts input, and {host} is {reason}; next: {NEXT_STEP}"


def check(targets_csv, env_path, home, run=_run, viewer=False):
    targets = [t for t in targets_csv.split(",") if t]
    if not any(opens_windows(t, viewer) for t in targets):
        return None
    names = local_names(run)
    machines = load_registry(find_registry(env_path, home))
    # ioreg only when the registry does not decide, so a known Mac pays nothing for it.
    known = machines and match_entries(machines, names)
    idle_s = None if known else idle_seconds(run(["ioreg", "-c", "IOHIDSystem", "-d", "4"]))
    target, reason = decide(targets, names, machines, idle_s, viewer)
    if target is None:
        return None
    return message(target, names[0] if names else "this Mac", reason)


def main(argv):
    if len(argv) not in (3, 4) or argv[1] != "check" or argv[3:] not in ([], ["viewer"]):
        print("usage: person_guard.py check TARGETS_CSV [viewer]", file=sys.stderr)
        return 2
    # The account's real home: a CI step's $HOME is scratch and would hide the registry.
    refusal = check(argv[2], os.environ.get("CMUX_FLEET_REGISTRY", ""), pwd.getpwuid(os.getuid()).pw_dir,
                    viewer=len(argv) == 4)
    if refusal:
        print(refusal, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
