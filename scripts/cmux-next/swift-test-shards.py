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
SUITE = re.compile(r"^(?:@\w+(?:\([^\n]*?\))?(?:[ \t]+|\n))*(?:(?:public|package|internal|private|fileprivate|final)[ \t]+)*"
                   r"(?:struct|class|enum|actor|extension)[ \t]+([A-Za-z_][A-Za-z0-9_]*)", re.M)
TEST = re.compile(r"@Test\b|\bfunc test[A-Z0-9_]\w*\(")
# Memory one test process takes at its peak (the whole test bundle, AppKit and WebKit loaded): it bounds the width.
PROCESS_GB = 4
# A process costs seconds to start (the whole test bundle loads), so a shard holds at least this many tests.
MIN_SHARD_TESTS = 150


def test_targets(package: Path) -> list[str]:
    return sorted(set(TEST_TARGET.findall(package.read_text(encoding="utf-8"))))


def suite_counts(target_dir: Path) -> dict[str, int]:
    """Tests per top-level suite name in a target's sources (a suite split over extensions counts once)."""
    counts: dict[str, int] = {}
    for path in sorted(target_dir.rglob("*.swift")):
        text = path.read_text(encoding="utf-8", errors="replace")
        starts = [(m.start(), m.group(1)) for m in SUITE.finditer(text)]
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
    if total <= share or not longer or len(prefix) >= 4:
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
    out = []
    for index, b in enumerate(sorted((b for b in bins if b["units"]), key=lambda b: -b["tests"]), 1):
        out.append({"name": f"shard {index}", "filter": "^(" + "|".join(sorted(b["units"])) + ")", "tests": b["tests"]})
    return out


def width(cores: int, memory_gb: float, override: str = "") -> int:
    """Test processes to run at once: half the cores (each process also runs its own worker threads) and no more
    than memory holds at PROCESS_GB each. CMUX_NEXT_SWIFT_TEST_WIDTH overrides it."""
    if override.strip():
        return max(1, int(override))
    return max(1, min(cores // 2, int(memory_gb // PROCESS_GB)))


def runner_width() -> int:
    cores = os.cpu_count() or 2
    try:
        memory_gb = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, check=True)
                        .stdout.strip()) / 2**30
    except (OSError, ValueError, subprocess.CalledProcessError):
        memory_gb = PROCESS_GB * 2
    return width(cores, memory_gb, os.environ.get("CMUX_NEXT_SWIFT_TEST_WIDTH", ""))


def run(shards: list[dict], at_once: int, wrapper: str, extra: list[str], deadline: float) -> int:
    """Runs every shard, at most `at_once` at a time, largest first. Each shard's hang limit is the time left to
    `deadline` when it starts; a shard with less than a minute left still starts, so its stacks are sampled."""
    pending = list(shards)
    running: list[tuple[dict, subprocess.Popen, Path, float]] = []
    failed: list[str] = []
    rows: list[str] = []
    with tempfile.TemporaryDirectory(prefix="swift-test-shards-", dir=os.environ.get("RUNNER_TEMP")) as tmp:
        while pending or running:
            while pending and len(running) < at_once:
                shard = pending.pop(0)
                log = Path(tmp) / f"{shard['name'].replace(' ', '-')}.log"
                env = dict(os.environ, CMUX_NEXT_TEST_HANG_SECONDS=str(max(60, int(deadline - time.time()))))
                args = [wrapper, "--skip-build", "--ignore-lock", "--filter", shard["filter"], *extra]
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
    shards = plan(args.tests_root, args.package, args.targets, at_once * 2, set(args.exclude))
    if args.command == "plan":
        print(json.dumps({"width": at_once, "shards": shards}, indent=2))
        return 0
    extra = args.extra[1:] if args.extra[:1] == ["--"] else args.extra
    print(f"{len(shards)} shards, {at_once} at once", flush=True)
    return run(shards, at_once, args.wrapper, extra, args.deadline)


if __name__ == "__main__":
    sys.exit(main())
