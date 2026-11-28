#!/usr/bin/env python3
"""The step's agent session (`cmux-ci run --sign-in agent`, CMUX_CI_SIGNIN_FILE) as a stage-table DEV app's sign-in.

    stage-signin.py store APP OUT

Writes the session's refresh token into APP's own token store (the file the app restores its session from at
launch), as scripts/ci/cmux_next_pair_e2e.py does for its Mac app, prints that store's path, and makes OUT an
empty 0600 file for the app's CMUX_AUTH_CREDENTIALS_FILE (the app then signs in from the store, not from an
ambient file). stage-table.sh removes the store when its step ends. The token never goes to argv, environment,
stdout or logs; a refusal prints only its reason, on stderr, and exits 1.
"""
import os
import plistlib
import pwd
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts", "ci"))
import cmux_next_pair_e2e as e2e  # noqa: E402


def store(app, out):
    session = e2e.signin_session()
    if session is None:
        raise SystemExit("no CMUX_CI_SIGNIN_FILE: send the step with cmux-ci run --sign-in agent")
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            info = plistlib.load(f)
        bundle, exe = info["CFBundleIdentifier"], info["CFBundleExecutable"]
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        raise SystemExit(f"the app's Info.plist: {type(error).__name__}") from None
    env = {k: v for k, v in os.environ.items() if k != "CMUX_CI_SIGNIN_FILE"}
    path = e2e.mac_token_store(app, bundle, os.path.join(app, "Contents", "MacOS", exe), env,
                               session["project"], pwd.getpwuid(os.getuid()).pw_dir)
    e2e.write_mac_session(path, session["refresh_token"])
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)
    os.close(fd)
    return path


def main(argv):
    if len(argv) != 4 or argv[1] != "store":
        print("usage: stage-signin.py store APP OUT", file=sys.stderr)
        return 2
    try:
        print(store(argv[2], argv[3]))
    except SystemExit as stop:
        print(f"stage-signin: {stop.code}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
