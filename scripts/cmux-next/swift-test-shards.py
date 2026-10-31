#!/usr/bin/env python3
"""Run the CmuxNext broad Swift test pass as several test processes at once, split by target and suite.

One `swift test` process ran every selected suite: about 6,300 tests started at once and queued on its one main
thread, and the windows its tests left open piled up (3 -> 428 over run 40705037968's pass), so each Core Animation
commit walked more of them and throughput fell from about 2,000 to about 100 tests a minute. The pass hit its
1,500 s limit with 466 tests unfinished. Several processes give each its own main thread and its own windows.

`plan` splits the selected targets into shards: a target is one unit, and a target holding more than its share of
the tests is split by suite-name prefix, each level ending in a negated class so every suite falls in exactly one
shard. Units are packed largest first into about twice as many shards as run at once. `run` runs the
shards through swift-test-with-hang-sampler.sh, at most `width` at a time (from the runner's cores and memory),
each with the same skips, prints each shard's log as one group when it ends, and fails when any shard failed.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

TEST_TARGET = re.compile(r'\.testTarget\(\s*name:\s*"([A-Za-z0-9_]+)"')
SUITE = re.compile(r"^(?:@\w+(?:\([^\n]*?\))?(?:[ \t]+|\n))*(?:(?:public|package|internal|private|fileprivate|final|open|nonisolated)[ \t]+)*"
                   r"(?:struct|class|enum|actor|extension)[ \t]+([A-Za-z_][A-Za-z0-9_]*)", re.M)
TEST = re.compile(r"@Test\b|\bfunc test[A-Z0-9_]\w*\(")
FUNC = re.compile(r"\bfunc[ \t]+([A-Za-z_][A-Za-z0-9_]*)")
# Memory one test process takes at its peak (the whole test bundle, AppKit and WebKit loaded): it bounds the width.
PROCESS_GB = 4
# Suite families that run in a shard of their own, never packed beside other suites: (target, suite-name
# prefix). The Cloud suites drive brokers and daemons under 30-60 s deadlines; packed with CmuxNextAppTests'
# Cl/I/Sw suites and five other targets, three of them sat 300 s until the stuck watchdog ended the shard
# (#26809, run 40723548016, shard 4), and the same three pass alone (cmux-ci 67ca029f and f020c796).
OWN_SHARDS = (("CmuxNextAppTests", "Cloud"),)
# A process costs seconds to start (the whole test bundle loads), so a shard holds at least this many tests.
MIN_SHARD_TESTS = 150
# Shards to split the selected targets into at the least: about 700 tests each for all targets, the size that ran
# without the window pile-up in run 40874507839 (14 packed shards and the Cloud one).
SHARDS = 14


def test_targets(package: Path) -> list[str]:
    return sorted(set(TEST_TARGET.findall(package.read_text(encoding="utf-8"))))


def suite_counts(target_dir: Path) -> dict[str, int]:
    """Tests per top-level suite name in a target's sources (a suite split over extensions counts once)."""
    counts: dict[str, int] = {}
    for path in sorted(target_dir.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        starts = [(m.start(), m.group(1)) for m in SUITE.finditer(text)]
        # A free @Test function before any suite (AgentPageOpsBtwTests.swift) is named Target.function().
        head = text[:starts[0][0]] if starts else text
        for m in TEST.finditer(head):
            if func := FUNC.search(head, m.start()):
                counts[func.group(1)] = counts.get(func.group(1), 0) + 1
        for i, (at, name) in enumerate(starts):
            body = text[at:starts[i + 1][0] if i + 1 < len(starts) else len(text)]
            if n := len(TEST.findall(body)):
                counts[name] = counts.get(name, 0) + n
    return counts


def prefix_units(counts: dict[str, int], share: float, prefix: str = "") -> list[tuple[str, int]]:
    """Regex fragments over suite-name prefixes, each at most about `share` tests where a longer prefix can split
    it. Each level lists one fragment per next character the names use, then a negated class of those characters,
    so every suite (any first character, or a name that ends at the prefix) falls in exactly one fragment."""
    names = {n: c for n, c in counts.items() if n.startswith(prefix)}
    total = sum(names.values())
    longer = {n: c for n, c in names.items() if len(n) > len(prefix)}
    # No depth cap: a family that shares a long prefix (CmuxNextAgentPaneTests' AgentPane*, 489 of its 737 tests
    # under a 4-character cap) still splits; it stops where one suite holds the rest.
    if total <= share or not longer:
        return [(re.escape(prefix), total)]
    chars = sorted({n[len(prefix)] for n in longer})
    units: list[tuple[str, int]] = []
    for c in chars:
        units += prefix_units(names, share, prefix + c)
    rest = total - sum(n for _, n in units)
    units.append((re.escape(prefix) + "[^" + "".join(re.escape(c) for c in chars) + "]", rest))
    return units


def plan(tests_root: Path, package: Path, selected: str, shards: int, exclude: set[str] = frozenset()) -> list[dict]:
    targets = [t for t in test_targets(package) if t not in exclude]
    if selected.strip() != "all":
        wanted = set(selected.split())
        targets = [t for t in targets if t in wanted]
    counts = {t: suite_counts(tests_root / t) for t in targets}
    own: list[dict] = []
    for target, prefix in OWN_SHARDS:
        if target not in counts:
            continue
        family = {n: c for n, c in counts[target].items() if n.startswith(prefix)}
        if family:
            counts[target] = {n: c for n, c in counts[target].items() if n not in family}
            own.append({"filter": rf"^({re.escape(target)}\.{re.escape(prefix)})", "tests": sum(family.values()),
                        "skip": []})
    # Every other shard skips the families, whose names its prefix fragments could also match.
    skip = [rf"{re.escape(t)}\.{re.escape(p)}" for t, p in OWN_SHARDS if t in counts]
    total = sum(sum(c.values()) for c in counts.values())
    shards = max(1, min(shards, total // MIN_SHARD_TESTS))
    share = max(total / shards, 1)
    units: list[tuple[str, int]] = []
    for target in targets:
        if sum(counts[target].values()) <= share:
            units.append((rf"{re.escape(target)}\.", sum(counts[target].values())))
        else:
            units += [(rf"{re.escape(target)}\.{frag}", n) for frag, n in prefix_units(counts[target], share)]
    bins: list[dict] = [{"units": [], "tests": 0} for _ in range(min(shards, len(units)) or 1)]
    for unit, n in sorted(units, key=lambda u: -u[1]):
        lightest = min(bins, key=lambda b: b["tests"])
        lightest["units"].append(unit)
        lightest["tests"] += n
    packed = [{"filter": "^(" + "|".join(sorted(b["units"])) + ")", "tests": b["tests"], "skip": skip}
              for b in bins if b["units"]]
    out = sorted(packed + own, key=lambda shard: -shard["tests"])
    for index, shard in enumerate(out, 1):
        shard["name"] = f"shard {index}"
    return out


def width(cores: int, memory_gb: float, override: str = "") -> int:
    """Test processes to run at once: a quarter of the cores and no more than memory holds at PROCESS_GB each.
    CMUX_NEXT_SWIFT_TEST_WIDTH overrides it.

    Half the cores (7 on a 14-core mini, each process running up to 6 tests at once) was too many for one window
    server: suites that pass alone at the base turned red only in the shards, on waits that ran out
    (WorkspaceGroupPinLiveTests, WorkspaceNothingToDoRefusalTests, ClickedLinkFocusTests), a focus intent another
    process moved (RapidWorkspaceCreateTests) and a scroll restore (BrowserEngineStateRestoreTests): #26809 run
    40874507839 against cmux-ci at the base, 62f2281957e0."""
    if override.strip():
        return max(1, int(override))
    return max(1, min(cores // 4, int(memory_gb // PROCESS_GB)))


def runner_width() -> int:
    cores = os.cpu_count() or 2
    try:
        memory_gb = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, check=True)
                        .stdout.strip()) / 2**30
    except (OSError, ValueError, subprocess.CalledProcessError):
        memory_gb = PROCESS_GB * 2
    return width(cores, memory_gb, os.environ.get("CMUX_NEXT_SWIFT_TEST_WIDTH", ""))


LOCKED = "database is locked"
# The test helper is running: Swift Testing or XCTest has printed its first line.
RAN = re.compile(r"^(?:[◇✔✘↪━] Test |Test Suite ')", re.M)
# How long a shard may take to get its helper running before the next one starts anyway.
START_SECONDS = 180


def starting(item: tuple) -> bool:
    """Whether a just-started shard's `swift test` may still be reading the build database."""
    _, proc, log, began = item
    if proc.poll() is not None or time.time() - began > START_SECONDS:
        return False
    try:
        return not RAN.search(log.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return True


def run(shards: list[dict], at_once: int, wrapper: str, extra: list[str], deadline: float) -> int:
    """Runs every shard, at most `at_once` at a time, largest first. Each shard's hang limit is the time left to
    `deadline` when it starts; a shard with less than a minute left still starts, so its stacks are sampled."""
    pending = list(shards)
    running: list[tuple[dict, subprocess.Popen, Path, float]] = []
    failed: list[str] = []
    rows: list[str] = []
    retried: set[str] = set()
    with tempfile.TemporaryDirectory(prefix="swift-test-shards-", dir=os.environ.get("RUNNER_TEMP")) as tmp:
        while pending or running:
            # One SwiftPM start at a time: each `swift test` opens .build/build.db before it runs the test
            # helper, and two at once fail with "database is locked" and run no test (run 40734897241).
            # The next shard starts once the last one's helper is running (or the last one ended).
            while pending and len(running) < at_once and not (running and starting(running[-1])):
                shard = pending.pop(0)
                log = Path(tmp) / f"{shard['name'].replace(' ', '-')}.log"
                env = dict(os.environ, CMUX_NEXT_TEST_HANG_SECONDS=str(max(60, int(deadline - time.time()))))
                skips = [arg for pattern in shard.get("skip", []) for arg in ("--skip", pattern)]
                args = [wrapper, "--skip-build", "--ignore-lock", "--filter", shard["filter"], *skips, *extra]
                with log.open("w") as out:
                    proc = subprocess.Popen(args, stdout=out, stderr=subprocess.STDOUT, env=env)
                running.append((shard, proc, log, time.time()))
                print(f"started {shard['name']} (~{shard['tests']} tests): {shard['filter']}", flush=True)
            time.sleep(1)
            for item in [r for r in running if r[1].poll() is not None]:
                shard, proc, log, began = item
                running.remove(item)
                seconds = time.time() - began
                print(f"::group::{shard['name']}: exit {proc.returncode} after {seconds:.0f} s", flush=True)
                sys.stdout.write(log.read_text(encoding="utf-8", errors="replace"))
                print("::endgroup::", flush=True)
                text = log.read_text(encoding="utf-8", errors="replace")
                if proc.returncode != 0 and shard["name"] not in retried and LOCKED in text and not RAN.search(text):
                    # Lost the build database to another SwiftPM before any test ran: run it again, once.
                    retried.add(shard["name"])
                    pending.insert(0, shard)
                    print(f"{shard['name']}: the build database was locked before any test ran; starting it again",
                          flush=True)
                    continue
                rows.append(f"| {shard['name']} | {shard['tests']} | {seconds:.0f} | {proc.returncode} |")
                if proc.returncode != 0:
                    failed.append(shard["name"])
                    print(f"::error title=cmux-next swift test shard red::{shard['name']} exited {proc.returncode}: "
                          f"{shard['filter']}", flush=True)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as out:
            out.write(f"### Swift test shards ({at_once} at once)\n\n| shard | tests | seconds | exit |\n| --- | --- | --- | --- |\n")
            out.write("\n".join(rows) + "\n\n")
    return 1 if failed else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("plan", "run"):
        p = sub.add_parser(name)
        p.add_argument("--package", type=Path, default=Path("Package.swift"))
        p.add_argument("--tests-root", type=Path, default=Path("Tests"))
        p.add_argument("--targets", default="all", help="'all' or the selected test targets, space-separated")
        p.add_argument("--exclude", action="append", default=[], help="a test target a step of its own runs")
    sub.choices["run"].add_argument("--wrapper", required=True)
    sub.choices["run"].add_argument("--deadline", type=float, required=True, help="epoch seconds the pass must end by")
    sub.choices["run"].add_argument("extra", nargs=argparse.REMAINDER, help="-- then arguments every shard gets")
    sub.add_parser("width")
    args = parser.parse_args(argv)
    if args.command == "width":
        print(runner_width())
        return 0
    at_once = runner_width()
    # The shard count stays at least SHARDS whatever the width: a process's windows pile up over its run, so a
    # bigger shard slows down (one process of ~6,300 tests fell from ~2,000 to ~100 tests a minute).
    shards = plan(args.tests_root, args.package, args.targets, max(at_once * 2, SHARDS), set(args.exclude))
    if args.command == "plan":
        print(json.dumps({"width": at_once, "shards": shards}, indent=2))
        return 0
    extra = args.extra[1:] if args.extra[:1] == ["--"] else args.extra
    print(f"{len(shards)} shards, {at_once} at once", flush=True)
    return run(shards, at_once, args.wrapper, extra, args.deadline)


if __name__ == "__main__":
    sys.exit(main())
