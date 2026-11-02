#!/usr/bin/env python3
"""Print a swift-testing filter regex naming the suites that drive the main thread for long stretches.

A suite is main-thread heavy when its file commits Core Animation frames itself (`CATransaction.flush()`,
`displayIfNeeded()`, a bench's `drawFrame(`) or builds a helper type whose own file does (SidebarScrollBench,
SidebarLagBench, ...), or makes real WebKit downloads (`RemoteVideoPageTests`). In the shared swift test
process each such commit lays out every window the process holds, so one of them held the main thread for
5 to 11+ minutes and every main-actor test beside it stalled until the stuck watchdog killed the run
(#26809). The swift-test job skips these in its broad pass and runs them in a process of their own.

Derived from the test sources on every run, so a new frame-driving suite is covered without a list to edit.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

FRAME_DRIVERS = re.compile(r"CATransaction\.flush\(\)|\.displayIfNeeded\(\)|\bdrawFrame\(")
# Suites the frame scan cannot see. RemoteVideoPageTests' real WebKit downloads block the main thread in a kernel
# call. In a shared shard SidebarIncrementalMatchesRebuild(Gaps)Tests held the main thread in layoutSubtreeIfNeeded
# (67 s alone) and ClassicUpgradeHugeSimulationTests in Core Animation commits (412 s alone, its test open 572 s
# when the stuck watchdog ended the shard): #26809 run 40874507839, shards 7 and 11.
ALWAYS = {("CmuxNextBrowserTests", "RemoteVideoPageTests"),
          ("CmuxNextAppTests", "SidebarIncrementalMatchesRebuildTests"),
          ("CmuxNextAppTests", "SidebarIncrementalMatchesRebuildGapsTests"),
          ("CmuxNextAppTests", "ClassicUpgradeHugeSimulationTests")}
# Suites that pass in a process of their own and fail in a shard's shared process, on the base too: each fails
# the same way at feat-cmux-next 52b04522 and at #26809's head when its shard's prefix group runs in one process
# at width 1 (fleet steps 49135e36f49c base and f873ee9fe21e head, `--filter CmuxNextAppTests.M`, `.Sc`, `.B`).
# BackgroundAccessoryPolicyTests fails as the first suite of its process, so the cause is the shared process
# itself rather than a suite run before it, and the Sc process ended with 0 windows open, so it is not the window
# pile-up either. Until each suite's isolation is fixed, the heavy step gives each one a fresh process, the way
# they pass. Remove one from here with its isolation fix.
OWN_PROCESS = {("CmuxNextAppTests", "MarkdownLiveShareTests"),  # aChangeOnDiskSendsReload: no `reload` in 10 s
               ("CmuxNextAppTests", "ScriptPaneFocusTests"),  # the snapshot never names the focused pane (20 s)
               ("CmuxNextAppTests", "BackgroundAccessoryPolicyTests")}  # the restore reopens a closed window
# Suites that hold a wall-clock budget (a fade within 0.33 s, a switch cost ratio), which a shard misses when the
# other shards share the runner's cores: each failed in a shard of #26809 run 41042041227 (cmux-next swift test at
# 84121afc) and passes alone at both the base c66f534b and that head (fleet steps dcbc8328fa4d and 31512d495f11).
# TabHoverCardTimingTests fails the same way in the base's own single-process run too (job 123558222461: the card
# faded in 0.60 s of a 0.33 s budget). The heavy step runs them one at a time with nothing beside them.
OWN_PROCESS |= {("CmuxNextAppTests", "IconPickerMotionTests"),  # the picker is still visible after its close motion
                # Its 50 ms synchronous-present budget must not include other suites' shared-process work.
                ("CmuxNextAppTests", "HomeSheetOpensInstantlyTests"),
                ("CmuxNextAppTests", "SidebarHoverCardDwellTests"),  # the card fades out in 0.51 s of 0.33 s
                ("CmuxNextAppTests", "TabHoverCardTimingTests"),
                ("CmuxNextAppTests", "SpaceSwitchCostTests")}  # p50 at 500 workspaces 133 ms of 124 ms
ALWAYS |= OWN_PROCESS
# Suites the frame scan finds that stay in the shared pass. WindowScreenshotTests commits one frame of its own two
# small windows per test (5 s in all), so it never held the main thread. In the shared pass it passes on CI
# (feat-cmux-next runs 40905054694 and 40914924429); in a fresh process of its own on a CI mini its pane crop reads
# a transparent corner (aPaneIsCroppedFromItsWindow, WindowScreenshotTests.swift:199) on every #26809 run, and in a
# shard its first capture threw .blank: its settledImage now waits for the whole frame.
SHARED = {("CmuxNextDesignTests", "WindowScreenshotTests")}
# The heavy step's watchdog limits for one suite's process (swift-test-with-hang-sampler.sh): the whole run, and
# how long no test may finish. A suite that declares its own `.timeLimit(.minutes(N))` gets limits above it, so
# Swift Testing's own limit reports a slow test first and the watchdog only ends a process that outlives it.
HANG_SECONDS = 600
STUCK_SECONDS = 300
SUITE_TIME_LIMIT = re.compile(r"\.timeLimit\(\.minutes\((\d+)\)\)")
# A top-level declaration only: its attributes may sit on lines of their own, but each such line starts at
# column 0, so a nested (indented) type is never read as a top-level one.
TYPE_DECL = re.compile(r"^(?:@\w+(?:\([^\n]*?\))?(?:[ \t]+|\n))*(?:(?:public|package|internal|private|fileprivate|final|open|nonisolated)[ \t]+)*"
                       r"(?:struct|class|enum|actor)[ \t]+([A-Z][A-Za-z0-9_]*)", re.M)
EXTENSION = re.compile(r"^extension\s+([A-Z][A-Za-z0-9_]*)", re.M)


def top_level_blocks(text: str) -> list[tuple[str, str]]:
    """(type name, body) for each top-level type or extension declaration, in order."""
    starts = sorted([(m.start(), m.group(1)) for m in TYPE_DECL.finditer(text)]
                    + [(m.start(), m.group(1)) for m in EXTENSION.finditer(text)])
    return [(name, text[at:starts[i + 1][0] if i + 1 < len(starts) else len(text)])
            for i, (at, name) in enumerate(starts)]


def heavy_suites(tests_root: Path, targets: str = "all") -> list[tuple[str, str]]:
    """Every main-thread-heavy suite of the selected test targets ('all', or target names space-separated)."""
    found = _heavy_suites(tests_root)
    if targets.strip() == "all":
        return found
    wanted = set(targets.split())
    return [(t, n) for t, n in found if t in wanted]


def _heavy_suites(tests_root: Path) -> list[tuple[str, str]]:
    files = {p: p.read_text(encoding="utf-8", errors="replace") for p in sorted(tests_root.rglob("*.swift"))}
    driving = {p for p, text in files.items() if FRAME_DRIVERS.search(text)}
    # Helper types a driving file declares with no tests of its own (a bench class): their users drive frames too.
    helpers = {name for p in driving for name, body in top_level_blocks(files[p]) if "@Test" not in body}
    if helpers:
        uses = re.compile(r"\b(?:" + "|".join(sorted(map(re.escape, helpers))) + r")\s*[(.]")
        driving |= {p for p, text in files.items() if uses.search(text)}
    found = set(ALWAYS)
    for p in driving:
        target = p.relative_to(tests_root).parts[0]
        for name, body in top_level_blocks(files[p]):
            if "@Test" in body:
                found.add((target, name))
    return sorted(found - SHARED)


def suite_time_limit(tests_root: Path, target: str, name: str) -> int:
    """Seconds of the `.timeLimit(.minutes(N))` on the suite's own declaration (its attributes), 0 when none."""
    for path in sorted((tests_root / target).rglob("*.swift")):
        for block_name, body in top_level_blocks(path.read_text(encoding="utf-8", errors="replace")):
            if block_name == name and (m := SUITE_TIME_LIMIT.search(body.split("{", 1)[0])):
                return int(m.group(1)) * 60
    return 0


def limits(tests_root: Path, target: str, name: str) -> tuple[int, int]:
    """(whole-run seconds, stuck seconds) for the suite's own process in the heavy step."""
    declared = suite_time_limit(tests_root, target, name)
    if not declared:
        return HANG_SECONDS, STUCK_SECONDS
    return max(HANG_SECONDS, declared + 300), max(STUCK_SECONDS, declared + 120)


def pattern(suites: list[tuple[str, str]]) -> str:
    by_target: dict[str, list[str]] = {}
    for target, name in suites:
        by_target.setdefault(target, []).append(name)
    parts = [f"{re.escape(t)}\\.({'|'.join(sorted(set(n)))})" for t, n in sorted(by_target.items())]
    return "(" + "|".join(parts) + ")\\b"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("tests_root", type=Path, help="Packages/macOS/CmuxNext/Tests")
    parser.add_argument("--list", action="store_true", help="one Target.Suite per line instead of the regex")
    parser.add_argument("--runs", action="store_true",
                        help="one 'Target.Suite HANG_SECONDS STUCK_SECONDS' per line: the heavy step's watchdog limits")
    parser.add_argument("--targets", default="all", help="'all' or the selected test targets, space-separated")
    args = parser.parse_args(argv)
    suites = heavy_suites(args.tests_root, args.targets)
    if not suites:
        return 0  # nothing heavy selected: no output, never a pattern that would match every test
    if args.runs:
        print("\n".join(f"{t}.{n} {' '.join(map(str, limits(args.tests_root, t, n)))}" for t, n in suites))
    elif args.list:
        print("\n".join(f"{t}.{n}" for t, n in suites))
    else:
        print(pattern(suites))
    return 0


if __name__ == "__main__":
    sys.exit(main())
