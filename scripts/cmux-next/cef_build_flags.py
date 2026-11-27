#!/usr/bin/env python3
"""Checks the GN args a CEF framework was built with (crash-elimination.md).

  cef_build_flags.py <cef folder> [--require]

Reads <cef folder>/archive.json, which the fork's build-cmux-cef.sh writes
(cmux.17 and later record "gn_args"). The framework must be built with
dcheck_always_on = false: Chromium turns DCHECKs on for every non-official
build, and a DCHECK that web content reaches aborts the browser process,
which is the app (cmux NIGHTLY, 2026-10-04).

Without --require a missing or wrong flag prints a warning and exits 0
(frameworks before cmux.17 have no gn_args). With --require (the manifest's
"require_dcheck_off": true, set with the cmux.17 pin) it exits 1.
"""
import json
import os
import sys


def main(argv):
    if not argv or argv[0].startswith("-"):
        print(__doc__, file=sys.stderr)
        return 2
    folder, require = argv[0], "--require" in argv[1:]
    path = os.path.join(folder, "archive.json")
    try:
        with open(path) as f:
            args = json.load(f).get("gn_args")
    except (OSError, ValueError) as error:
        problem = f"cannot read {path}: {error}"
    else:
        if not isinstance(args, dict):
            problem = f"{path} records no gn_args (a framework from before cmux.17)"
        elif args.get("dcheck_always_on") is not False:
            problem = f"{path} gn_args do not set dcheck_always_on = false"
        else:
            return 0
    if require:
        print(f"error: {problem}; this CEF framework has DCHECKs on, and a DCHECK that web content "
              "reaches aborts cmux (plans/cmux-next/crash-elimination.md)", file=sys.stderr)
        return 1
    print(f"warning: {problem}; DCHECKs may be on (plans/cmux-next/crash-elimination.md)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
