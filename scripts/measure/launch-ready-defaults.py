#!/usr/bin/env python3
"""launch-ready-defaults.py aside|load|save|restore BUNDLE [PLIST]: launch-ready's app defaults, through
fresh_home_launch_smoke.DefaultsAside, the one set-aside for a bundle's real-account defaults domain.

cfprefsd keeps an app's defaults in the console user's real ~/Library/Preferences whatever HOME and
CFFIXED_USER_HOME say, and both of an A/B's sides share one bundle id. So without this, every launch read
cmuxNext.launchSnapshotPath.<session> as the other side left it and restored the other side's launch snapshot
(cmux#44204's A/B, 2026-11-17).

  aside BUNDLE        once per run: put back a copy a killed run left, set the account's domain aside, clear it
  load BUNDLE PLIST   before each launch: clear the domain (fails unless it reads back empty), import PLIST if any
  save BUNDLE PLIST   after each launch: export the domain to PLIST (this side's own copy)
  restore BUNDLE      once at the end: put the account's domain back as it was before the run
  check PLIST PREFIX  every cmuxNext.launchSnapshotPath.* in PLIST under PREFIX (the side's home); prints the
                      others as JSON and exits 1, so a launch that read the other side's snapshot fails the step

DefaultsAside alone keeps a run apart from the account. Load and save keep the two sides apart from each other,
because the sides take turns within one run. Run as the console user (console-session.sh). Exits 0, or 1 with
the reason on stderr.
"""
import json
import os
import pathlib
import plistlib
import sys

here = pathlib.Path(__file__).resolve().parent
sys.path[:0] = [str(here), str(here.parent / "ci")]  # copied beside this file in a run; scripts/ci in a checkout
from fresh_home_launch_smoke import CannotRun, DefaultsAside  # noqa: E402


def check(plist: pathlib.Path, prefix: str) -> int:
    try:
        with open(plist, "rb") as handle:
            domain = plistlib.load(handle)
    except FileNotFoundError:
        return 0
    except Exception as error:  # unread is not clean
        print(json.dumps({"unreadable": f"{plist}: {error}"}))
        return 1
    homes = (prefix, os.path.realpath(prefix) + "/")
    other = {key: value for key, value in domain.items() if key.startswith("cmuxNext.launchSnapshotPath")
             and not (isinstance(value, str) and (value.startswith(homes) or os.path.realpath(value).startswith(homes)))}
    if other:
        print(json.dumps(other, sort_keys=True, default=str))
    return 1 if other else 0


def main(argv: list[str]) -> int:
    verbs = ("aside", "load", "save", "restore", "check")
    if len(argv) < 2 or argv[0] not in verbs or (argv[0] in ("load", "save", "check") and len(argv) < 3):
        print(__doc__.splitlines()[0], file=sys.stderr)
        return 2
    if argv[0] == "check":
        return check(pathlib.Path(argv[1]), argv[2])
    verb, bundle = argv[0], argv[1]
    plist = pathlib.Path(argv[2]) if len(argv) > 2 else None
    aside = DefaultsAside(bundle, pathlib.Path("/tmp"))
    if not aside.tool:
        print("launch-ready-defaults: no defaults tool", file=sys.stderr)
        return 1
    try:
        if verb == "aside":
            aside.__enter__()
            aside.release()  # the step runs alone on its Mac; the copy on disk is what a killed run leaves
        elif verb == "restore":
            aside.put_back()
        elif verb == "load":
            aside.clear()
            if plist.exists() and aside.defaults("import", bundle, str(plist)) != 0:
                raise CannotRun(f"could not import {plist} into {bundle}")
        elif aside.defaults("export", bundle, str(plist)) != 0:
            raise CannotRun(f"could not export {bundle} to {plist}")
    except CannotRun as error:
        print(f"launch-ready-defaults {verb}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
