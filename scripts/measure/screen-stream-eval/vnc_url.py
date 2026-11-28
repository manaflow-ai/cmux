#!/usr/bin/env python3
"""The vnc:// URL the apple-high and apple-standard targets open Screen Sharing.app with.

    vnc_url.py HOST     prints vnc://USER:PASS@HOST, or vnc://HOST when no login is found

`open vnc://HOST` with no login stops at Screen Sharing's login sheet unless the viewer account
saved the host's password ("Remember this password"), so the window never shows the host's scene
and the run ends "no GO_FILE within 120 s" (the 2026-11-26 and 11-28 cmux20/cmux22 pairs). The
login comes from, first to last:

1. $CMUX_CI_VNC_LOGIN_FILE, the file the worker writes for a `cmux-ci run --vnc-login HOST` step;
2. ~/.config/screen-stream-eval/login in the account's real home (a step's $HOME is scratch);
3. the fleet login in this Mac's login keychain (`manaflow-fleet-login`, as
   `fleet-sudo --login-keychain HOST` stores it, the item stage-table.sh reads; never the sudo
   item), for the account with this account's name (the fleet Macs share one).

A file holds the password, or a user name line and then the password, and must be mode 0600.
Where each source stood goes to stderr, never the secret. The URL, which holds the password, is
stdout only: the caller hands it to `open` (as screen-share-vs.py does) and never logs it.
"""
from __future__ import annotations

import os
import pwd
import stat
import subprocess
import sys
from urllib.parse import quote

ITEM = "manaflow-fleet-login"


def read_file(path: str, user: str) -> tuple[str, str] | str:
    """(user, password) from PATH, or why not."""
    try:
        info = os.stat(path)
    except OSError:
        return f"{path}: no such file"
    if stat.S_IMODE(info.st_mode) & 0o077:
        return f"{path}: readable by others (chmod 600 it)"
    try:
        lines = [line for line in open(path, encoding="utf8").read().splitlines() if line]
    except OSError as error:
        return f"{path}: unreadable ({error.strerror})"
    if len(lines) == 1:
        return user, lines[0]
    if len(lines) == 2:
        return lines[0], lines[1]
    return f"{path}: holds {len(lines)} lines, not a password or a user name and a password"


def keychain(user: str, home: str, run=subprocess.run) -> tuple[str, str] | str:
    """(user, password) from the fleet login keychain item, or why not."""
    why = []
    for kc in ("", os.path.join(home, "Library/Keychains/login.keychain-db")):
        if kc and not os.path.isfile(kc):
            why.append(f"{kc}: no such file")
            continue
        try:
            p = run(["security", "find-generic-password", "-s", ITEM, "-w", *([kc] if kc else [])],
                    capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError) as error:
            why.append(f"{kc or 'default search list'}: {type(error).__name__}")
            continue
        password = p.stdout.rstrip("\n")
        if p.returncode == 0 and password and "\n" not in password:
            return user, password
        where = kc or "default search list"
        why.append(f"{where}: no {ITEM} item" if p.returncode == 44 else
                   f"{where}: locked or no access (security exit {p.returncode}: {p.stderr.strip()[:120]})")
    return "; ".join(why)


def login(run=subprocess.run) -> tuple[tuple[str, str] | None, list[str]]:
    account = pwd.getpwuid(os.getuid())
    why = []
    env_file = os.environ.get("CMUX_CI_VNC_LOGIN_FILE", "")
    for path in ([env_file] if env_file else []) + [os.path.join(account.pw_dir, ".config/screen-stream-eval/login")]:
        got = read_file(path, account.pw_name)
        if isinstance(got, tuple):
            return got, [f"login from {path}"]
        why.append(got)
    got = keychain(account.pw_name, account.pw_dir, run)
    if isinstance(got, tuple):
        return got, [f"login from this Mac's keychain ({ITEM})"]
    why.append(got)
    return None, why


def url(host: str, found: tuple[str, str] | None) -> str:
    if not found:
        return f"vnc://{host}"
    return f"vnc://{quote(found[0], safe='')}:{quote(found[1], safe='')}@{host}"


def main(argv: list[str]) -> int:
    if len(argv) != 1 or not argv[0] or any(c in argv[0] for c in "/@: \t\n"):
        print("usage: vnc_url.py HOST", file=sys.stderr)
        return 2
    found, why = login()
    if found:
        print(f"vnc_url.py: {why[0]}", file=sys.stderr)
    else:
        print("vnc_url.py: no login (" + "; ".join(why) + "); Screen Sharing.app uses the login it saved for the host, "
              "else stops at its login sheet; next: send the viewer half with --vnc-login HOST", file=sys.stderr)
    print(url(argv[0], found))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
