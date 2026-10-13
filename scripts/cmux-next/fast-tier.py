#!/usr/bin/env python3
"""The cmux NEXT PR fast tier (hq#1915): every registered suite, every PR.

Entries live in scripts/cmux-next/fast-tier.json. Each has a name, an owner
lane, an optional bead and one of three kinds:
  swift   {package, filter}: `swift test --skip-build --filter` after one
          `swift build --build-tests` per package
  cargo   {path, package[, filter]}: `cargo test --locked -p` in path
  script  {path[, args]}: python3 -I for a .py path, bash otherwise
An entry must be deterministic, need no window server or gui token, and finish
within --max-seconds (60) after the build. A swift or cargo entry whose filter
runs no test fails.

Flake policy: a failed entry runs once more only to classify it. Fail then pass
is FLAKY, and FLAKY fails the tier like FAIL: it is never silently retried. Its
owner quarantines it (scripts/cmux-next/quarantine.json, with a bead) or fixes
it. A quarantined entry still runs and reports QUARANTINED-PASS/-FAIL but does
not gate. --repeat N is the admission run: an entry gates only after N runs on
one head agree (ADMISSIBLE), and any mixed result is NOT-ADMISSIBLE.

Every result is one line, `FAST-TIER <STATUS> <name> <seconds>s owner=... bead=...`,
then the entry's output on failure. Exit 0 when nothing gating failed, 1 when
something did, 2 for a bad registry.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

KINDS = {"swift": ("package", "filter"), "cargo": ("path", "package"), "script": ("path",)}


def load_entries(path):
    entries = json.loads(Path(path).read_text())["entries"]
    names = set()
    for entry in entries:
        name = entry.get("name") or "<unnamed>"
        problems = []
        if entry.get("kind") not in KINDS:
            problems.append(f"kind must be one of {sorted(KINDS)}")
        else:
            problems += [f"{key} is required" for key in KINDS[entry["kind"]] if not entry.get(key)]
        if not entry.get("owner"):
            problems.append("owner is required (the lane that fixes or quarantines it)")
        if name in names:
            problems.append("duplicate name")
        names.add(name)
        if problems:
            print(f"fast-tier: entry {name}: " + "; ".join(problems), file=sys.stderr)
            raise SystemExit(2)
    return entries


def quarantined(path):
    if not path or not Path(path).exists():
        return set()
    return {e["name"] for e in json.loads(Path(path).read_text()).get("entries", [])}


def command(entry):
    """(argv, working directory relative to the root) for one run of the entry."""
    kind = entry["kind"]
    if kind == "swift":
        return ["swift", "test", "--skip-build", "--package-path", entry["package"], "--filter", entry["filter"]], "."
    if kind == "cargo":
        argv = ["cargo", "test", "--locked", "-p", entry["package"]]
        if entry.get("filter"):
            argv += ["--", entry["filter"]]
        return argv, entry["path"]
    runner = ["python3", "-I"] if entry["path"].endswith(".py") else ["bash"]
    return runner + [entry["path"], *entry.get("args", [])], "."


def describe(argv, cwd):
    text = shlex.join(argv)
    return text if cwd == "." else f"{text} (in {cwd})"


# Test counts in swift test (XCTest, Swift Testing) and cargo test output.
TEST_COUNTS = re.compile(r"Executed (\d+) tests?|Test run with (\d+) tests?|test result: \w+\. (\d+) passed")


def ran_no_test(entry, output):
    """A swift or cargo entry whose filter matched nothing: a renamed test must
    not silently leave the tier as a vacuous pass."""
    if entry["kind"] == "script":
        return False
    return not any(int(n) for match in TEST_COUNTS.findall(output) for n in match if n)


def run_once(root, entry, max_seconds):
    argv, cwd = command(entry)
    started = time.monotonic()
    try:
        done = subprocess.run(argv, cwd=root / cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, timeout=max_seconds)
        ok, output = done.returncode == 0, done.stdout
        if ok and ran_no_test(entry, output):
            ok, output = False, output + "\nmatched no test: check the entry's filter"
    except subprocess.TimeoutExpired as expired:
        output = expired.stdout if isinstance(expired.stdout, str) else (expired.stdout or b"").decode(errors="replace")
        ok, output = False, output + f"\ntimed out after {max_seconds}s"
    return ok, time.monotonic() - started, output


def line(status, entry, seconds, extra=""):
    tail = f" {extra}" if extra else ""
    return f"FAST-TIER {status} {entry['name']} {seconds:.1f}s owner={entry['owner']} bead={entry.get('bead') or 'none'}{tail}"


def build_packages(root, entries, dry_run):
    """Builds every Swift package and cargo test binary once, outside the entries' time cap."""
    builds = [(["swift", "build", "--build-tests", "--package-path", package], ".", package)
              for package in dict.fromkeys(e["package"] for e in entries if e["kind"] == "swift")]
    for path in dict.fromkeys(e["path"] for e in entries if e["kind"] == "cargo"):
        packages = [arg for e in entries if e["kind"] == "cargo" and e["path"] == path for arg in ("-p", e["package"])]
        builds.append((["cargo", "test", "--locked", "--no-run", *packages], path, path))
    for argv, cwd, what in builds:
        print("BUILD " + describe(argv, cwd), flush=True)
        if not dry_run and subprocess.run(argv, cwd=root / cwd).returncode != 0:
            print(f"FAST-TIER FAIL build:{what}: the tests do not build", flush=True)
            return False
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    here = Path(__file__).resolve().parent
    parser.add_argument("--root", default=str(here.parent.parent), help="repository root")
    parser.add_argument("--registry", default=str(here / "fast-tier.json"))
    parser.add_argument("--quarantine", default=str(here / "quarantine.json"))
    parser.add_argument("--max-seconds", type=int, default=60, help="time cap per entry run, after the build")
    parser.add_argument("--only", action="append", default=[], help="run only this entry (repeatable)")
    parser.add_argument("--repeat", type=int, default=0, help="admission: run each entry N times, no classify rerun")
    parser.add_argument("--dry-run", action="store_true", help="print the build and test commands only")
    args = parser.parse_args()

    root = Path(args.root)
    entries = load_entries(args.registry)
    if args.only:
        entries = [e for e in entries if e["name"] in args.only]
    held = quarantined(args.quarantine)
    if args.dry_run:
        build_packages(root, entries, True)
        for entry in entries:
            print(f"RUN {entry['name']}: " + describe(*command(entry)))
        return 0
    if not build_packages(root, entries, False):
        return 1

    gating_failed = False
    results = []
    started = time.monotonic()
    for entry in entries:
        if args.repeat:
            runs = [run_once(root, entry, args.max_seconds) for _ in range(args.repeat)]
            failed = sum(not ok for ok, _, _ in runs)
            seconds = max(s for _, s, _ in runs)
            if failed in (0, args.repeat):
                status, extra = "ADMISSIBLE", f"{args.repeat - failed}/{args.repeat} passed"
                if failed:
                    status, extra = "NOT-ADMISSIBLE", f"{failed}/{args.repeat} failed every time"
            else:
                status, extra = "NOT-ADMISSIBLE", f"{failed}/{args.repeat} failed: the result changes between runs"
            gating_failed |= status != "ADMISSIBLE"
            print(line(status, entry, seconds, extra), flush=True)
            if failed:
                print(next(out for ok, _, out in runs if not ok).rstrip(), flush=True)
            results.append((status, entry, seconds))
            continue
        ok, seconds, output = run_once(root, entry, args.max_seconds)
        status, extra = "PASS", ""
        if not ok:
            again, _, _ = run_once(root, entry, args.max_seconds)
            status = "FLAKY" if again else "FAIL"
            if again:
                extra = "failed, then passed on the classify run: fix it or quarantine it with a bead"
            elif "timed out after" in output:
                extra = f"timed out after {args.max_seconds}s"
            elif "matched no test" in output:
                extra = "matched no test: check the entry's filter"
        if entry["name"] in held:
            status = "QUARANTINED-PASS" if ok else "QUARANTINED-FAIL"
            extra = ""
        else:
            gating_failed |= status != "PASS"
        print(line(status, entry, seconds, extra), flush=True)
        if not ok:
            print(output.rstrip(), flush=True)
        results.append((status, entry, seconds))

    total = time.monotonic() - started
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as out:
            out.write(f"### cmux NEXT fast tier\n\n{len(results)} entries, {total:.0f}s after the build.\n\n")
            out.write("| Entry | Result | Seconds | Owner | Bead |\n| --- | --- | ---: | --- | --- |\n")
            for status, entry, seconds in results:
                out.write(f"| {entry['name']} | {status} | {seconds:.1f} | {entry['owner']} | {entry.get('bead') or 'none'} |\n")
    return 1 if gating_failed else 0


if __name__ == "__main__":
    sys.exit(main())
