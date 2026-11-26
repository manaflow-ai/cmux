#!/usr/bin/env python3
"""Generate cmux-unit-test-timings.json from app-host xcodebuild CI logs.

Feed it the raw logs of every "app-host unit tests (N/7)" job from a few
recent green ci.yml runs, one directory per run named after its run id
(``gh run view --job <id> --log > <run-id>/shard-N.log``):

    python3 scripts/ci/generate_test_timings.py \
        runs/36043411778 runs/36056804560 runs/36062245739 \
        --output scripts/ci/cmux-unit-test-timings.json

It extracts per-test durations from XCTest lines ("Test Case '-[cmuxTests.X
testY]' passed (N seconds).") and per-suite wall times from Swift Testing
lines ("Suite X passed after N seconds."). The app-host batch runs its Swift
Testing suites one after another (a batch's suite walls add up to its "Test
run ... passed after" total), so a suite's wall time is its honest cost.

Swift Testing names a suite declared with ``@Suite("Display name")`` by that
display name, so the display name is mapped back to the declared type the
shard planner selects. Without that mapping those suites were never
measured and fell back to a per-test estimate, however long they ran.

Within one run, XCTest class totals are the sum of their methods across
shards (methods are disjoint) and a Swift Testing suite split across batches
sums its batches. Across runs, every duration is the median of the runs that
measured it, so one slow runner or one retried test does not skew a suite.
Per-method entries are emitted only for suites large enough that the shard
planner splits them by method (LARGE_SUITE_METHOD_THRESHOLD in
cmux_unit_test_shard.py).
"""

from __future__ import annotations

import argparse
import collections
import json
import re
import statistics
import sys
from pathlib import Path

# Both scripts live in scripts/ci/, and Python puts the script's own directory
# first on sys.path, so the planner's threshold imports directly: classes at or
# above it are sharded per-method, so only they need per-method timings.
from cmux_unit_test_shard import LARGE_SUITE_METHOD_THRESHOLD

XCTEST_CASE_RE = re.compile(
    r"Test Case '-\[cmuxTests\.(\w+) (\w+)\]' (?:passed|failed) \((\d+(?:\.\d+)?) seconds\)"
)
SWIFT_TESTING_SUITE_RE = re.compile(
    r"Suite (\w+|\"(?:[^\"\\]|\\.)*\") (?:passed|failed) after (\d+(?:\.\d+)?) seconds"
)
SWIFT_TESTING_TEST_RE = re.compile(
    r"Test (\w+)\(\) (?:passed|failed) after (\d+(?:\.\d+)?) seconds"
)
# Each batch is a separate xcodebuild invocation. A suite split by method
# across batches reports once per batch, and its cost is the sum.
BATCH_START_RE = re.compile(r"Running app-host unit-test batch \d+/\d+")
SUITE_ATTRIBUTE_RE = re.compile(r"@Suite\(\s*\"((?:[^\"\\]|\\.)*)\"")
DECLARATION_RE = re.compile(
    r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*"
    r"(?:(?:final|private|fileprivate|internal|public)\s+)*"
    r"(?:struct|class|actor|enum|extension)\s+(\w+)\b"
)


def suite_display_names(root: Path) -> dict[str, str]:
    """Map each unambiguous ``@Suite("Display name")`` to its declared type."""
    candidates: dict[str, set[str]] = collections.defaultdict(set)
    for path in sorted((root / "cmuxTests").glob("**/*.swift")):
        pending: str | None = None
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            attribute = SUITE_ATTRIBUTE_RE.search(line)
            if attribute:
                pending = attribute.group(1)
            if pending is None:
                continue
            declaration = DECLARATION_RE.match(line)
            if declaration:
                candidates[pending].add(declaration.group(1))
                pending = None
    return {
        display: next(iter(types))
        for display, types in candidates.items()
        if len(types) == 1
    }


def run_timings(
    log_paths: list[Path], display_names: dict[str, str]
) -> tuple[dict[str, dict[str, int]], dict[str, int], dict[str, dict[str, int]]]:
    """Return one run's XCTest method, Swift Testing suite and Swift Testing method ms."""
    method_ms: dict[str, dict[str, int]] = collections.defaultdict(dict)
    suite_ms: dict[str, int] = collections.defaultdict(int)
    swift_method_ms: dict[str, dict[str, int]] = collections.defaultdict(dict)
    for log_path in log_paths:
        batch_suite_ms: dict[str, int] = {}

        def close_batch() -> None:
            for name, ms in batch_suite_ms.items():
                suite_ms[name] += ms
            batch_suite_ms.clear()

        open_suites: list[str] = []
        for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
            if BATCH_START_RE.search(line):
                close_batch()
                continue
            case = XCTEST_CASE_RE.search(line)
            if case:
                suite, method, seconds = case.group(1), case.group(2), float(case.group(3))
                # A retried test reports twice; keep the larger observation.
                ms = int(seconds * 1000)
                if ms > method_ms[suite].get(method, -1):
                    method_ms[suite][method] = ms
                continue
            started = re.search(r"Suite (\w+|\"(?:[^\"\\]|\\.)*\") started\.", line)
            if started:
                open_suites.append(started.group(1))
                continue
            test_line = SWIFT_TESTING_TEST_RE.search(line)
            if test_line and open_suites:
                owner = open_suites[-1]
                name = display_names.get(owner.strip('"'), owner) if owner.startswith('"') else owner
                ms = int(float(test_line.group(2)) * 1000)
                if ms > swift_method_ms[name].get(test_line.group(1), -1):
                    swift_method_ms[name][test_line.group(1)] = ms
                continue
            suite_line = SWIFT_TESTING_SUITE_RE.search(line)
            if suite_line:
                raw, seconds = suite_line.group(1), float(suite_line.group(2))
                if raw in open_suites:
                    open_suites.remove(raw)
                name = raw
                if raw.startswith('"'):
                    name = display_names.get(raw[1:-1], "")
                    if not name:
                        continue
                ms = int(seconds * 1000)
                # A restarted host can report a suite twice in one batch.
                batch_suite_ms[name] = max(batch_suite_ms.get(name, 0), ms)
        close_batch()
    return method_ms, dict(suite_ms), swift_method_ms


def median_ms(values: list[int]) -> int:
    return int(statistics.median(values))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "runs",
        nargs="+",
        type=Path,
        help="One directory per green CI run holding every app-host shard log; named by run id",
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--default-test-ms", type=int, default=200)
    args = parser.parse_args()

    display_names = suite_display_names(args.root)
    method_samples: dict[str, dict[str, list[int]]] = collections.defaultdict(
        lambda: collections.defaultdict(list)
    )
    suite_samples: dict[str, list[int]] = collections.defaultdict(list)
    run_ids: list[str] = []
    for run_dir in args.runs:
        logs = sorted(run_dir.glob("*.log")) if run_dir.is_dir() else [run_dir]
        if not logs:
            raise SystemExit(f"No shard logs in {run_dir}")
        method_ms, swift_suite_ms, swift_method_ms = run_timings(logs, display_names)
        if not method_ms and not swift_suite_ms:
            raise SystemExit(f"No test timings found in {run_dir}")
        run_ids.append(run_dir.name if run_dir.is_dir() else run_dir.stem)
        run_suites: dict[str, int] = dict(swift_suite_ms)
        for suite, per_method in method_ms.items():
            run_suites[suite] = max(run_suites.get(suite, 0), sum(per_method.values()))
            for method, ms in per_method.items():
                method_samples[suite][method].append(ms)
        for suite, per_method in swift_method_ms.items():
            for method, ms in per_method.items():
                method_samples[suite][method].append(ms)
        for suite, ms in run_suites.items():
            suite_samples[suite].append(ms)

    suites = {suite: median_ms(values) for suite, values in suite_samples.items()}
    methods: dict[str, int] = {}
    for suite, per_method in method_samples.items():
        if suite not in suites or len(per_method) < LARGE_SUITE_METHOD_THRESHOLD:
            continue
        for method, values in per_method.items():
            methods[f"{suite}/{method}"] = median_ms(values)

    manifest = {
        "_comment": (
            "Measured cmuxTests durations used by cmux_unit_test_shard.py to "
            "balance shards by time instead of test count. Each value is the "
            "median over source_run_ids. Regenerate from recent green runs' "
            "app-host shard logs with scripts/ci/generate_test_timings.py. "
            "Suites absent here fall back to method-count estimates, so this "
            "file can go stale without breaking anything."
        ),
        "source_run_ids": run_ids,
        "default_test_ms": args.default_test_ms,
        "suites": dict(sorted(suites.items())),
        "methods": dict(sorted(methods.items())),
    }
    args.output.write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
    print(
        f"Wrote {args.output}: {len(suites)} suites, {len(methods)} methods "
        f"from {len(run_ids)} run(s)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
