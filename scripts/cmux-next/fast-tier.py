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

--kind KIND (repeatable) runs only the entries of those kinds, so one registry
feeds two CI jobs: cmux-next.yml's `fast-tier-cargo` job runs
`--kind cargo --kind script` and the Mac `fast-tier` job runs `--kind swift`.
A --kind that selects no entry is a bad registry (exit 2), never an empty pass.

Flake policy: a failed entry runs once more only to classify it. Fail then pass
is FLAKY, and FLAKY fails the tier like FAIL: it is never silently retried. Its
owner quarantines it (scripts/cmux-next/quarantine.json, with a bead) or fixes
it. A quarantined entry still runs and reports QUARANTINED-PASS/-FAIL but does
not gate. --repeat N is the admission run: an entry gates only after N runs on
one head agree (ADMISSIBLE), and any mixed result is NOT-ADMISSIBLE.

Every result is one line, `FAST-TIER <STATUS> <name> <seconds>s owner=... bead=...`,
then the entry's output on failure. With `--receipt PATH`, the same run also
writes a compact JSON timing receipt for CI artifacts. Exit 0 when nothing
gating failed, 1 when something did, 2 for a bad registry.
"""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import shlex
import subprocess
import sys
import threading
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


def descendants(pid):
    """Every live process below pid, from one ps table (macOS and Linux)."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,pgid="], capture_output=True, text=True,
                             timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    rows = [tuple(int(x) for x in line.split()) for line in out.splitlines() if len(line.split()) == 3]
    children = {}
    for child, parent, pgid in rows:
        children.setdefault(parent, []).append((child, pgid))
    found, todo = [], [pid]
    while todo:
        for child, pgid in children.get(todo.pop(), []):
            found.append((child, pgid))
            todo.append(child)
    return found


def stop_tree(pid):
    """SIGKILL the entry's process group and every process below it, in whatever
    group it sits: SwiftPM starts xctest in a group of its own. Never our own group."""
    mine = os.getpgrp()
    targets = descendants(pid)
    for group in {pid, *(pgid for _, pgid in targets)} - {mine}:
        try:
            os.killpg(group, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
    for child, _ in targets:
        try:
            os.kill(child, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def run_once(root, entry, max_seconds):
    argv, cwd = command(entry)
    started = time.monotonic()
    # Its own session, so a timeout stops everything the entry started: swift test
    # runs the tests in an xctest child that outlives it (cmux19, run 39360407187:
    # six orphan xctest processes after three timed-out entries).
    proc = subprocess.Popen(argv, cwd=root / cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, start_new_session=True)
    try:
        output, _ = proc.communicate(timeout=max_seconds)
        ok = proc.returncode == 0
        if ok and ran_no_test(entry, output):
            ok, output = False, output + "\nmatched no test: check the entry's filter"
    except subprocess.TimeoutExpired:
        stop_tree(proc.pid)
        try:
            output, _ = proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:  # something outside the tree still holds the pipe
            proc.stdout.close()
            proc.wait()
            output = "(output cut off: a process outside the entry still held it)"
        ok, output = False, (output or "") + f"\ntimed out after {max_seconds}s"
    finally:
        # A child that outlived a finished entry dies with it too.
        stop_tree(proc.pid)
    return ok, time.monotonic() - started, output


def line(status, entry, seconds, extra=""):
    tail = f" {extra}" if extra else ""
    return f"FAST-TIER {status} {entry['name']} {seconds:.1f}s owner={entry['owner']} bead={entry.get('bead') or 'none'}{tail}"


def run_build(root, argv, cwd, what, log_lock):
    """One build, its output streamed line by line under a `[what]` prefix so a
    build running beside another stays readable. Returns (returncode, seconds)."""
    started = time.monotonic()
    proc = subprocess.Popen(argv, cwd=root / cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace")
    for output_line in proc.stdout:
        with log_lock:
            print(f"[{what}] {output_line.rstrip()}", flush=True)
    return proc.wait(), time.monotonic() - started


def build_packages(root, entries, dry_run, timing):
    """Builds every Swift package and cargo test binary once, outside the entries' time cap.

    The Swift builds and the cargo builds share no outputs, so the two groups run
    side by side (each group in order): on a warm runner the CmuxNext build
    (~160 s) and the cmux-tui test build (~115 s) used to run one after the other.
    """
    swift = [(["swift", "build", "--build-tests", "--package-path", package], ".", package)
             for package in dict.fromkeys(e["package"] for e in entries if e["kind"] == "swift")]
    cargo = []
    for path in dict.fromkeys(e["path"] for e in entries if e["kind"] == "cargo"):
        packages = [arg for e in entries if e["kind"] == "cargo" and e["path"] == path for arg in ("-p", e["package"])]
        cargo.append((["cargo", "test", "--locked", "--no-run", *packages], path, path))
    builds = swift + cargo
    if dry_run:
        for argv, cwd, what in builds:
            print("BUILD " + describe(argv, cwd), flush=True)
            timing.append({"name": what, "command": describe(argv, cwd), "seconds": 0.0, "status": "dry-run"})
        return True

    log_lock = threading.Lock()
    results = {}

    def run_group(group):
        for argv, cwd, what in group:
            with log_lock:
                print("BUILD " + describe(argv, cwd), flush=True)
            returncode, seconds = run_build(root, argv, cwd, what, log_lock)
            results[what] = (returncode, seconds)
            if returncode != 0:
                return

    threads = [threading.Thread(target=run_group, args=(group,)) for group in (swift, cargo) if group]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    ok = True
    for argv, cwd, what in builds:
        if what not in results:
            continue
        returncode, seconds = results[what]
        status = "pass" if returncode == 0 else "fail"
        timing.append({"name": what, "command": describe(argv, cwd), "seconds": round(seconds, 3), "status": status})
        if returncode != 0:
            print(f"FAST-TIER FAIL build:{what}: the tests do not build", flush=True)
            ok = False
    return ok


def write_receipt(path, *, status, started_wall, builds, results, total_seconds, kinds=None):
    if not path:
        return
    cache = {}
    for kind in ("swift", "cargo"):
        key = os.environ.get(f"CMUX_FAST_{kind.upper()}_CACHE_KEY")
        hit = os.environ.get(f"CMUX_FAST_{kind.upper()}_CACHE_HIT")
        if key or hit:
            cache[kind] = {"key": key or "", "exact_hit": hit == "true"}
    # The seed a restore by prefix picked (cmux-next.yml fast-tier): a warm run
    # is told apart from a cold one even when no exact key hit.
    matched = os.environ.get("CMUX_FAST_CACHE_MATCHED_KEY")
    if matched:
        cache["matched_key"] = matched
    payload = {
        "schema": "cmux-next-fast-tier-receipt.v1",
        "status": status,
        "kinds": sorted(kinds) if kinds else sorted(KINDS),
        "started_at": started_wall,
        "total_seconds": round(total_seconds, 3),
        "build_seconds": round(sum(item["seconds"] for item in builds), 3),
        "builds": builds,
        "entries": [
            {"name": entry["name"], "status": result, "seconds": round(seconds, 3),
             "owner": entry["owner"], "bead": entry.get("bead") or "none"}
            for result, entry, seconds in results
        ],
        "cache": cache,
        "github": {
            key: os.environ[key]
            for key in ("GITHUB_EVENT_NAME", "GITHUB_SHA", "GITHUB_REF", "GITHUB_RUN_ID", "RUNNER_NAME")
            if os.environ.get(key)
        },
    }
    receipt = Path(path)
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    here = Path(__file__).resolve().parent
    parser.add_argument("--root", default=str(here.parent.parent), help="repository root")
    parser.add_argument("--registry", default=str(here / "fast-tier.json"))
    parser.add_argument("--quarantine", default=str(here / "quarantine.json"))
    parser.add_argument("--max-seconds", type=int, default=60, help="time cap per entry run, after the build")
    parser.add_argument("--only", action="append", default=[], help="run only this entry (repeatable)")
    parser.add_argument("--kind", action="append", default=[], choices=sorted(KINDS),
                        help="run only the entries of this kind (repeatable)")
    parser.add_argument("--repeat", type=int, default=0, help="admission: run each entry N times, no classify rerun")
    parser.add_argument("--dry-run", action="store_true", help="print the build and test commands only")
    parser.add_argument("--receipt", help="write a JSON timing receipt at this path")
    args = parser.parse_args()

    root = Path(args.root)
    entries = load_entries(args.registry)
    if args.only:
        entries = [e for e in entries if e["name"] in args.only]
    if args.kind:
        entries = [e for e in entries if e["kind"] in args.kind]
        if not entries:
            print(f"fast-tier: no entry of kind {', '.join(sorted(set(args.kind)))} to run", file=sys.stderr)
            return 2
    held = quarantined(args.quarantine)
    started = time.monotonic()
    started_wall = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    builds = []
    if args.dry_run:
        build_packages(root, entries, True, builds)
        for entry in entries:
            print(f"RUN {entry['name']}: " + describe(*command(entry)))
        return 0
    if not build_packages(root, entries, False, builds):
        write_receipt(args.receipt, status="fail", started_wall=started_wall, builds=builds, results=[],
                      total_seconds=time.monotonic() - started, kinds=args.kind)
        return 1

    gating_failed = False
    results = []
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
    write_receipt(args.receipt, status="fail" if gating_failed else "pass", started_wall=started_wall,
                  builds=builds, results=results, total_seconds=total, kinds=args.kind)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as out:
            build_total = sum(item["seconds"] for item in builds)
            heading = f"cmux NEXT fast tier ({', '.join(sorted(set(args.kind)))})" if args.kind else "cmux NEXT fast tier"
            out.write(f"### {heading}\n\n{len(results)} entries, {total:.0f}s total ({build_total:.0f}s build).\n\n")
            out.write("| Entry | Result | Seconds | Owner | Bead |\n| --- | --- | ---: | --- | --- |\n")
            for status, entry, seconds in results:
                out.write(f"| {entry['name']} | {status} | {seconds:.1f} | {entry['owner']} | {entry.get('bead') or 'none'} |\n")
    return 1 if gating_failed else 0


if __name__ == "__main__":
    sys.exit(main())
