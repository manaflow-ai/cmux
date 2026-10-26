#!/usr/bin/env python3
"""Checks the GN args a CEF framework was built with (crash-elimination.md).

  cef_build_flags.py <cef folder> [--require]
                     [--require-official-pgo --chromium <version> --arch arm64|x86_64]

Reads <cef folder>/archive.json, which the fork's build-cmux-cef.sh writes
(cmux.17 and later record "gn_args"). The framework must be built with
dcheck_always_on = false: Chromium turns DCHECKs on for every non-official
build, and a DCHECK that web content reaches aborts the browser process,
which is the app (cmux NIGHTLY, 2026-10-04).

Without --require a missing or wrong flag prints a warning and exits 0
(frameworks before cmux.17 have no gn_args). With --require (the manifest's
"require_dcheck_off": true, set with the cmux.17 pin) it exits 1.

--require-official-pgo (the manifest's "require_official_pgo": true, set
only with a pin that won the official A/B, chrome-parity task p08-startup-047)
also refuses a framework unless it is the build Google ships, with the PGO
profile of its own Chromium revision:
  - gn_args is_official_build = true, and chrome_pgo_phase absent or 2
    (Chromium's build/config/compiler/pgo/pgo.gni turns phase 2 on for every
    official Mac build);
  - archive.json "pgo_profile" names the profile that the fork's
    checkout_pgo_profiles=True fetched from chrome/build/mac-arm.pgo.txt
    (mac.pgo.txt for x86_64): chrome-mac-arm-<build>-<time>-<sha1>.profdata,
    whose <build> is the third part of --chromium (tools/update_pgo_profiles.py).
    A gn_args pgo_data_path, when set, must name that same file;
  - archive.json "pgo_mismatch_rate" (functions clang reported with
    mismatched profile data, -Wprofile-instr-out-of-date, over profiled
    functions, summed over the build) is below 0.10.
"""
import json
import os
import re
import sys

MAX_PGO_MISMATCH_RATE = 0.10
PGO_PROFILE_PREFIX = {"arm64": "chrome-mac-arm", "x86_64": "chrome-mac"}


class UsageError(Exception):
    pass


def parse_args(argv):
    if not argv or argv[0].startswith("-"):
        raise UsageError("missing <cef folder>")
    options = {"folder": argv[0], "require": False, "official": False, "chromium": None, "arch": None}
    rest = list(argv[1:])
    while rest:
        flag = rest.pop(0)
        if flag == "--require":
            options["require"] = True
        elif flag == "--require-official-pgo":
            options["official"] = True
        elif flag in ("--chromium", "--arch"):
            if not rest:
                raise UsageError(f"{flag} needs a value")
            options[flag[2:]] = rest.pop(0)
        else:
            raise UsageError(f"unknown argument {flag}")
    if options["official"]:
        parts = (options["chromium"] or "").split(".")
        if len(parts) != 4 or not all(part.isdigit() for part in parts):
            raise UsageError("--require-official-pgo needs --chromium <major.minor.build.patch>")
        if options["arch"] not in PGO_PROFILE_PREFIX:
            raise UsageError("--require-official-pgo needs --arch arm64 or x86_64")
    return options


def dcheck_problem(path):
    """Returns (archive, problem): problem is None when DCHECKs are recorded off."""
    try:
        with open(path) as f:
            archive = json.load(f)
    except (OSError, ValueError) as error:
        return {}, f"cannot read {path}: {error}"
    args = archive.get("gn_args") if isinstance(archive, dict) else None
    if not isinstance(args, dict):
        return {}, f"{path} records no gn_args (a framework from before cmux.17)"
    if args.get("dcheck_always_on") is not False:
        return archive, f"{path} gn_args do not set dcheck_always_on = false"
    return archive, None


def official_pgo_problem(path, archive, chromium, arch):
    """Returns why the framework is not an official PGO build of `chromium`, or None."""
    args = archive["gn_args"]
    if args.get("is_official_build") is not True:
        return f"{path} gn_args do not set is_official_build = true"
    phase = args.get("chrome_pgo_phase", 2)
    if isinstance(phase, bool) or phase != 2:
        return f"{path} gn_args set chrome_pgo_phase = {phase!r}, not 2 (PGO off)"
    build = chromium.split(".")[2]
    prefix = PGO_PROFILE_PREFIX[arch]
    profile = archive.get("pgo_profile")
    pattern = re.compile(rf"{re.escape(prefix)}-{re.escape(build)}-[0-9]+-[0-9a-f]{{40}}\.profdata")
    if not isinstance(profile, str) or not pattern.fullmatch(profile):
        return (f"{path} pgo_profile {profile!r} is not the {arch} profile of Chromium {chromium} "
                f"({prefix}-{build}-<time>-<sha1>.profdata)")
    data_path = args.get("pgo_data_path")
    if data_path and os.path.basename(str(data_path)) != profile:
        return f"{path} gn_args pgo_data_path {data_path!r} is not the recorded pgo_profile {profile}"
    rate = archive.get("pgo_mismatch_rate")
    if isinstance(rate, bool) or not isinstance(rate, (int, float)) or not 0 <= rate < MAX_PGO_MISMATCH_RATE:
        return (f"{path} pgo_mismatch_rate {rate!r} is not a measured rate below {MAX_PGO_MISMATCH_RATE} "
                "(-Wprofile-instr-out-of-date functions over profiled functions)")
    return None


def main(argv):
    try:
        options = parse_args(argv)
    except UsageError as error:
        print(f"error: {error}\n{__doc__}", file=sys.stderr)
        return 2
    path = os.path.join(options["folder"], "archive.json")
    archive, problem = dcheck_problem(path)
    if problem is None:
        if not options["official"]:
            return 0
        official = official_pgo_problem(path, archive, options["chromium"], options["arch"])
        if official is None:
            return 0
        print(f"error: {official}; the manifest pins an official PGO framework (require_official_pgo, "
              "plans/cmux-next/chrome-parity/p08-startup.md task 047)", file=sys.stderr)
        return 1
    if options["require"] or options["official"]:
        print(f"error: {problem}; this CEF framework has DCHECKs on, and a DCHECK that web content "
              "reaches aborts cmux (plans/cmux-next/crash-elimination.md)", file=sys.stderr)
        return 1
    print(f"warning: {problem}; DCHECKs may be on (plans/cmux-next/crash-elimination.md)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
