#!/usr/bin/env python3
"""scripts/measure/build-flags.py RELOAD_OUTPUT --out FILE: what the tagged reload's build says of its own form.

A measure script builds its app with scripts/reload.sh and keeps what the reload printed (RELOAD_OUTPUT). The reload
prints the path of its own log there (`==> reload starting (tag: T, log: PATH)`) and writes each other line into
that log: its `bench configuration` line, xcodebuild's `Build settings from command line`, and each compile command.
A step's log and artifact had none of them, so a report did not say with which optimization its app was compiled.

This reads that log and gives:
  bench_configuration  the reload's `==> bench configuration: ...` line, or null when the log has no such line
  settings             the optimization settings of xcodebuild's command line: SWIFT_OPTIMIZATION_LEVEL,
                       OTHER_SWIFT_FLAGS, and for each value of a `CMUX_SWIFT_OPT_<target>` setting its targets
  swift.lines          the count of the Swift compiler's command lines with -Onone, with -O, with -Osize, with
                       another -O word (`other`) and with no -O word (`none`)
  swift.modules        for each of them, the modules (`-module-name`) of those lines
  limit                what these fields do not say

Prints one `BUILD-FLAGS {json}` line and writes the same JSON to --out. The exit is 0 also when the log is not
there: `log_read` is then false with the cause, so the report says that the build's form was not read, and the
measure goes on. The exit is 0 also when --out cannot be written: the line is printed first, and the cause goes to
the error output.
Test: python3 -I scripts/measure/tests/build-flags.test.py"""
import argparse
import json
import re
import sys

STARTING = re.compile(r"^==> reload starting \(tag: .*, log: (.+)\)\s*$")
BENCH = "==> bench configuration:"
SETTING = re.compile(r"^\s+(SWIFT_OPTIMIZATION_LEVEL|OTHER_SWIFT_FLAGS|CMUX_SWIFT_OPT_(\w+)) = (.*)$")
COMPILERS = ("swiftc", "swift-frontend")
LEVELS = ("-Onone", "-O", "-Osize")
LEVEL_WORD = re.compile(r"^-O(none|size|unchecked|playground)?$")  # the Swift compiler's own: not -Os, not -ObjC
LIMIT = ("the counts are of the Swift compiler's command lines in the reload's log, and Xcode writes more than one "
         "such line for a module; a build on a warm folder compiles only what changed, so a module with no line "
         "here was not compiled in this build and has the flags of the build that compiled it: `settings` says "
         "what this build asked for; a flag in a response file (`@file`) is not read; C and Rust are not counted")


def log_path(reload_output):
    """The path of the reload's own log, from the last `reload starting` line of what the reload printed."""
    found = None
    with open(reload_output, errors="replace") as f:
        for line in f:
            match = STARTING.match(line)
            if match:
                found = match.group(1)
    return found


def level_of(tokens):
    """The -O word of a compiler command line: one of LEVELS, `other`, or `none`. The last one counts, as the
    compiler takes it."""
    words = [token for token in tokens if LEVEL_WORD.match(token)]
    if not words:
        return "none"
    return words[-1] if words[-1] in LEVELS else "other"


def read_log(lines):
    """The fields of the docstring from the lines of a reload log."""
    bench, settings, by_value = None, {}, {}
    counts = {level: 0 for level in LEVELS + ("other", "none")}
    modules = {level: set() for level in counts}
    for raw in lines:
        line = raw.rstrip("\n")
        if line.startswith(BENCH):
            bench = line
            continue
        match = SETTING.match(line)
        if match:
            if match.group(2):
                by_value.setdefault(match.group(3), set()).add(match.group(2))
            else:
                settings[match.group(1)] = match.group(3)
            continue
        tokens = line.split()
        if "-module-name" not in tokens or not any(token.rsplit("/", 1)[-1] in COMPILERS for token in tokens[:4]):
            continue
        level, at = level_of(tokens), tokens.index("-module-name") + 1
        counts[level] += 1
        if at < len(tokens):
            modules[level].add(tokens[at])
    settings["CMUX_SWIFT_OPT"] = {value: sorted(targets) for value, targets in sorted(by_value.items())}
    return {"bench_configuration": bench, "settings": settings,
            "swift": {"lines": counts, "modules": {level: sorted(names) for level, names in modules.items()}}}


def read(reload_output):
    """The whole record for a report: the log's fields, or `log_read` false with the cause."""
    out = {"log": None, "log_read": False, "limit": LIMIT}
    try:
        out["log"] = log_path(reload_output)
        if out["log"] is None:
            out["not_read"] = f"{reload_output} has no `reload starting` line with the log's path"
            return out
        with open(out["log"], errors="replace") as f:
            out.update(read_log(f))
        out["log_read"] = True
    except OSError as error:
        out["not_read"] = repr(error)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("reload_output", help="the file with what scripts/reload.sh printed")
    parser.add_argument("--out", help="a file for the JSON")
    opts = parser.parse_args()
    record = read(opts.reload_output)
    print("BUILD-FLAGS " + json.dumps(record), flush=True)
    if opts.out:
        try:
            with open(opts.out, "w") as f:
                json.dump(record, f, indent=1)
        except OSError as error:
            print(f"build-flags: no file {opts.out}: {error!r}", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
