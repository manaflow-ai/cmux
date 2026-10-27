#!/usr/bin/env python3
"""Checks the GN args a CEF framework was built with (crash-elimination.md).

  cef_build_flags.py <cef folder> [--require]
                     [--require-official-pgo --manifest <cef-manifest.json> --arch arm64|x86_64]
  cef_build_flags.py --check-manifest <cef-manifest.json>
  cef_build_flags.py --count-pgo-mismatch <build log>

Reads <cef folder>/archive.json, which the fork's build-cmux-cef.sh writes
(cmux.17 and later record "gn_args"). The framework must be built with
dcheck_always_on = false: Chromium turns DCHECKs on for every non-official
build, and a DCHECK that web content reaches aborts the browser process,
which is the app (cmux NIGHTLY, 2026-10-04).

Without --require a missing or wrong flag prints a warning and exits 0
(frameworks before cmux.17 have no gn_args). With --require (the manifest's
"require_dcheck_off": true, set with the cmux.17 pin) it exits 1.

--require-official-pgo (the manifest's "require_official_pgo": true,
chrome-parity task p08-startup-047) first checks the manifest as
--check-manifest does, then refuses a framework unless archive.json records:
  - gn_args is_official_build = true, and chrome_pgo_phase absent or 2
    (Chromium's build/config/compiler/pgo/pgo.gni turns phase 2 on for every
    official Mac build);
  - "pgo_profile" equal to the manifest's "pgo_profile" ("x86_64.pgo_profile"
    for x86_64): the file that chrome/build/mac-arm.pgo.txt (mac.pgo.txt)
    names at the fork's Chromium revision, which checkout_pgo_profiles=True
    fetches. A gn_args pgo_data_path, when set, must name that same file;
  - "pgo_mismatch": {"functions": V, "mismatched": M}, the output of
    --count-pgo-mismatch on that build's ninja log, with M / V below 0.10.

Chromium's pgo_optimization_flags (build/config/compiler/pgo/BUILD.gn) pass
-Wno-profile-instr-out-of-date, so the build that records pgo_mismatch sets
the GN arg cc_wrapper to a script that runs
  "$@" -Wprofile-instr-out-of-date -Wprofile-instr-missing \\
       -Wno-error=profile-instr-out-of-date -Wno-error=profile-instr-missing
Warnings do not change code generation. clang then prints, per translation
unit, "of V functions, M have mismatched data" (and "... have no data").
A unit with neither prints nothing and is left out of V, so the rate is an
upper bound.

--check-manifest refuses a manifest that sets "require_official_pgo": true
without "require_dcheck_off": true, a pgo_profile per pinned arch, and an
"official_pgo_ab" record of the fleet A/B that the pin won (task 047):
CefInitialize and new-tab first paint each >= 10 % faster over >= 20 runs,
a >= 30 minute STRESS soak with no crash, and a passing shim crash-recovery
test.
"""
import json
import os
import re
import sys

MAX_PGO_MISMATCH_RATE = 0.10
PGO_PROFILE_PREFIX = {"arm64": "chrome-mac-arm", "x86_64": "chrome-mac"}
PGO_TXT = {"arm64": "chrome/build/mac-arm.pgo.txt", "x86_64": "chrome/build/mac.pgo.txt"}
MIN_AB_SPEEDUP = 0.10
MIN_AB_RUNS = 20
MIN_SOAK_MINUTES = 30
OUT_OF_DATE = re.compile(r"profile data may be out of date: of (\d+) functions?, (\d+) (?:has|have) mismatched data")
INCOMPLETE = re.compile(r"profile data may be incomplete: of (\d+) functions?, (\d+) (?:has|have) no data")


class UsageError(Exception):
    pass


def profile_name_pattern(arch):
    """tools/update_pgo_profiles.py names: <prefix>-<branch or main>-<time>-<sha1>[-<sha1>].profdata."""
    return re.compile(rf"{re.escape(PGO_PROFILE_PREFIX[arch])}-(?:main|[0-9]+)-[0-9]+-[0-9a-f]{{40}}(?:-[0-9a-f]{{40}})?\.profdata")


def is_count(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def load_json(path):
    """Returns (value, problem)."""
    try:
        with open(path) as f:
            return json.load(f), None
    except (OSError, ValueError) as error:
        return None, f"cannot read {path}: {error}"


def manifest_pgo_profile(manifest, arch):
    section = manifest if arch == "arm64" else manifest.get(arch)
    return section.get("pgo_profile") if isinstance(section, dict) else None


def ab_problem(ab):
    if not isinstance(ab, dict):
        return "no official_pgo_ab record of the fleet A/B"
    if not isinstance(ab.get("job"), str) or not ab["job"]:
        return "official_pgo_ab.job does not name the fleet job"
    runs = ab.get("runs")
    if not is_count(runs) or runs < MIN_AB_RUNS:
        return f"official_pgo_ab.runs {runs!r} is below {MIN_AB_RUNS}"
    for key in ("cef_initialize_speedup", "new_tab_paint_speedup"):
        value = ab.get(key)
        if not is_number(value) or value < MIN_AB_SPEEDUP:
            return f"official_pgo_ab.{key} {value!r} is below {MIN_AB_SPEEDUP} (fraction faster than the pin)"
    minutes = ab.get("stress_soak_minutes")
    if not is_number(minutes) or minutes < MIN_SOAK_MINUTES:
        return f"official_pgo_ab.stress_soak_minutes {minutes!r} is below {MIN_SOAK_MINUTES}"
    if ab.get("stress_soak_crashes") != 0 or isinstance(ab.get("stress_soak_crashes"), bool):
        return f"official_pgo_ab.stress_soak_crashes {ab.get('stress_soak_crashes')!r} is not 0"
    if ab.get("shim_crash_recovery") != "pass":
        return f"official_pgo_ab.shim_crash_recovery {ab.get('shim_crash_recovery')!r} is not \"pass\""
    return None


def manifest_problem(manifest):
    """Returns why a manifest that requires an official PGO framework cannot, or None."""
    if not isinstance(manifest, dict):
        return "the manifest is not a JSON object"
    flag = manifest.get("require_official_pgo", False)
    if not isinstance(flag, bool):
        return "require_official_pgo must be true or false"
    if not flag:
        return None
    if manifest.get("require_dcheck_off") is not True:
        return "require_official_pgo needs require_dcheck_off: true"
    for arch in PGO_PROFILE_PREFIX:
        if arch != "arm64" and arch not in manifest:
            continue
        profile = manifest_pgo_profile(manifest, arch)
        if not isinstance(profile, str) or not profile_name_pattern(arch).fullmatch(profile):
            key = "pgo_profile" if arch == "arm64" else f"{arch}.pgo_profile"
            return f"{key} {profile!r} is not a profile name from {PGO_TXT[arch]}"
    return ab_problem(manifest.get("official_pgo_ab"))


def count_pgo_mismatch(text):
    """Sums clang's per-unit PGO warnings. A unit that has both prints them on adjacent lines."""
    functions = mismatched = 0
    previous_out_of_date = None
    for line in text.splitlines():
        out_of_date = OUT_OF_DATE.search(line)
        if out_of_date:
            functions += int(out_of_date.group(1))
            mismatched += int(out_of_date.group(2))
            previous_out_of_date = out_of_date.group(1)
            continue
        incomplete = INCOMPLETE.search(line)
        if incomplete and incomplete.group(1) != previous_out_of_date:
            functions += int(incomplete.group(1))
        previous_out_of_date = None
    return {"functions": functions, "mismatched": mismatched}


def parse_args(argv):
    if not argv or argv[0].startswith("-"):
        raise UsageError("missing <cef folder>")
    options = {"folder": argv[0], "require": False, "official": False, "manifest": None, "arch": None}
    rest = list(argv[1:])
    while rest:
        flag = rest.pop(0)
        if flag == "--require":
            options["require"] = True
        elif flag == "--require-official-pgo":
            options["official"] = True
        elif flag in ("--manifest", "--arch"):
            if not rest:
                raise UsageError(f"{flag} needs a value")
            options[flag[2:]] = rest.pop(0)
        else:
            raise UsageError(f"unknown argument {flag}")
    if options["official"]:
        if not options["manifest"]:
            raise UsageError("--require-official-pgo needs --manifest <cef-manifest.json>")
        if options["arch"] not in PGO_PROFILE_PREFIX:
            raise UsageError("--require-official-pgo needs --arch arm64 or x86_64")
    return options


def dcheck_problem(path):
    """Returns (archive, problem): problem is None when DCHECKs are recorded off."""
    archive, problem = load_json(path)
    if problem:
        return {}, problem
    args = archive.get("gn_args") if isinstance(archive, dict) else None
    if not isinstance(args, dict):
        return {}, f"{path} records no gn_args (a framework from before cmux.17)"
    if args.get("dcheck_always_on") is not False:
        return archive, f"{path} gn_args do not set dcheck_always_on = false"
    return archive, None


def official_pgo_problem(path, archive, expected_profile, arch):
    """Returns why the framework is not the official build with `expected_profile`, or None."""
    args = archive["gn_args"]
    if args.get("is_official_build") is not True:
        return f"{path} gn_args do not set is_official_build = true"
    phase = args.get("chrome_pgo_phase", 2)
    if isinstance(phase, bool) or phase != 2:
        return f"{path} gn_args set chrome_pgo_phase = {phase!r}, not 2 (PGO off)"
    profile = archive.get("pgo_profile")
    if profile != expected_profile:
        return f"{path} pgo_profile {profile!r} is not the pinned {arch} profile {expected_profile}"
    data_path = args.get("pgo_data_path")
    if data_path and os.path.basename(str(data_path)) != expected_profile:
        return f"{path} gn_args pgo_data_path {data_path!r} is not the pinned {arch} profile {expected_profile}"
    counts = archive.get("pgo_mismatch")
    functions = counts.get("functions") if isinstance(counts, dict) else None
    mismatched = counts.get("mismatched") if isinstance(counts, dict) else None
    if not is_count(functions) or not is_count(mismatched) or functions == 0 or mismatched > functions:
        return (f"{path} pgo_mismatch {counts!r} is not the {{\"functions\", \"mismatched\"}} counts "
                "that --count-pgo-mismatch reads from the build log")
    if mismatched / functions >= MAX_PGO_MISMATCH_RATE:
        return (f"{path} pgo_mismatch: {mismatched} of {functions} functions have mismatched profile data, "
                f"not below {MAX_PGO_MISMATCH_RATE:.0%}")
    return None


def check_manifest(path):
    manifest, problem = load_json(path)
    problem = problem or manifest_problem(manifest)
    if problem:
        print(f"error: {path}: {problem} (plans/cmux-next/chrome-parity/p08-startup.md task 047)", file=sys.stderr)
        return 1
    return 0


def count_log(path):
    try:
        with open(path, errors="replace") as f:
            text = f.read()
    except OSError as error:
        print(f"error: cannot read {path}: {error}", file=sys.stderr)
        return 1
    print(json.dumps(count_pgo_mismatch(text)))
    return 0


def main(argv):
    if argv and argv[0] in ("--check-manifest", "--count-pgo-mismatch"):
        if len(argv) != 2:
            print(f"error: {argv[0]} needs one path\n{__doc__}", file=sys.stderr)
            return 2
        return check_manifest(argv[1]) if argv[0] == "--check-manifest" else count_log(argv[1])
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
        manifest, official = load_json(options["manifest"])
        official = official or manifest_problem(manifest)
        if official is None:
            expected = manifest_pgo_profile(manifest, options["arch"])
            if expected is None:
                official = f"{options['manifest']} pins no {options['arch']} pgo_profile"
            else:
                official = official_pgo_problem(path, archive, expected, options["arch"])
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
