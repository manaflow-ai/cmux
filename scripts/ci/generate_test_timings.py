#!/usr/bin/env python3
"""Generate cmux-unit-test-timings.json from app-host xcodebuild CI logs.

Feed it the raw logs of all four "app-host unit tests" shard jobs from one
green ci.yml run (``gh run view --job <id> --log > shard.log``):

    python3 scripts/ci/generate_test_timings.py \
        --run-id 12345 shard1.log shard2.log shard3.log shard4.log \
        --output scripts/ci/cmux-unit-test-timings.json

It extracts per-test durations from XCTest lines ("Test Case '-[cmuxTests.X
testY]' passed (N seconds).") and per-suite wall times from Swift Testing
lines ("Suite X passed after N seconds."). XCTest class totals are the sum of
their methods across shards (methods are disjoint). Swift Testing methods run
in parallel within one process batch, so each batch's suite wall time is the
honest partial cost and distinct batches are summed. Per-method entries are
emitted only for classes large enough that the shard planner splits them by
method (LARGE_SUITE_METHOD_THRESHOLD in cmux_unit_test_shard.py).
"""

from __future__ import annotations

import argparse
import collections
import json
import re
from pathlib import Path

# Both scripts live in scripts/ci/, and Python puts the script's own directory
# first on sys.path, so the planner's threshold imports directly: classes at or
# above it are sharded per-method, so only they need per-method timings.
from cmux_unit_test_shard import LARGE_SUITE_METHOD_THRESHOLD

XCTEST_CASE_RE = re.compile(
    r"Test Case '-\[cmuxTests\.(\w+) (\w+)\]' (?:passed|failed) \((\d+(?:\.\d+)?) seconds\)"
)
SWIFT_TESTING_SUITE_RE = re.compile(
    r"Suite (\w+) (?:passed|failed) after (\d+(?:\.\d+)?) seconds"
)
APP_HOST_BATCH_GROUP_RE = re.compile(
    r"##\[group\]Run app-host process batch (batch-\d+\.args)\b"
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("logs", nargs="+", type=Path)
    parser.add_argument("--run-id", required=True, help="CI run id the logs came from")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--default-test-ms", type=int, default=200)
    args = parser.parse_args()

    method_ms: dict[str, dict[str, int]] = collections.defaultdict(dict)
    unbatched_suite_ms: dict[str, int] = {}
    batched_suite_ms: dict[tuple[int, str, str], int] = {}

    for log_index, log_path in enumerate(args.logs):
        current_batch: str | None = None
        for line in log_path.read_text(encoding="utf-8", errors="replace").splitlines():
            batch_group = APP_HOST_BATCH_GROUP_RE.search(line)
            if batch_group:
                current_batch = batch_group.group(1)
                continue
            if current_batch is not None and "##[endgroup]" in line:
                current_batch = None
                continue

            case = XCTEST_CASE_RE.search(line)
            if case:
                suite, method, seconds = case.group(1), case.group(2), float(case.group(3))
                # A retried test reports twice; keep the larger observation.
                ms = int(seconds * 1000)
                if ms > method_ms[suite].get(method, -1):
                    method_ms[suite][method] = ms
                continue
            suite_line = SWIFT_TESTING_SUITE_RE.search(line)
            if suite_line:
                name, seconds = suite_line.group(1), float(suite_line.group(2))
                ms = int(seconds * 1000)
                if current_batch is None:
                    unbatched_suite_ms[name] = max(
                        unbatched_suite_ms.get(name, 0), ms
                    )
                else:
                    key = (log_index, current_batch, name)
                    batched_suite_ms[key] = max(batched_suite_ms.get(key, 0), ms)

    if not method_ms and not unbatched_suite_ms and not batched_suite_ms:
        raise SystemExit("No test timings found in the provided logs")

    # A suite may also appear in a focused gate before the main batched shard.
    # Once batch-scoped observations exist, they are authoritative: sum one
    # maximum observation per distinct batch and ignore the duplicate focused
    # execution. Legacy logs without batch markers retain the previous maximum.
    suites: dict[str, int] = dict(unbatched_suite_ms)
    batched_suite_totals: dict[str, int] = collections.defaultdict(int)
    for (_, _, suite), ms in batched_suite_ms.items():
        batched_suite_totals[suite] += ms
    suites.update(batched_suite_totals)

    methods: dict[str, int] = {}
    for suite, per_method in method_ms.items():
        suites[suite] = max(suites.get(suite, 0), sum(per_method.values()))
        if len(per_method) >= LARGE_SUITE_METHOD_THRESHOLD:
            for method, ms in per_method.items():
                methods[f"{suite}/{method}"] = ms

    manifest = {
        "_comment": (
            "Measured cmuxTests durations used by cmux_unit_test_shard.py to "
            "balance shards by time instead of test count. Regenerate from a "
            "green main run's app-host shard logs with "
            "scripts/ci/generate_test_timings.py. Suites absent here fall "
            "back to method-count estimates, so this file can go stale "
            "without breaking anything."
        ),
        "source_run_id": args.run_id,
        "default_test_ms": args.default_test_ms,
        "suites": dict(sorted(suites.items())),
        "methods": dict(sorted(methods.items())),
    }
    args.output.write_text(json.dumps(manifest, indent=1) + "\n", encoding="utf-8")
    print(
        f"Wrote {args.output}: {len(suites)} suites, {len(methods)} methods "
        f"from {len(args.logs)} log(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
