#!/usr/bin/env python3
"""The arch-counts lab story: the F13 architecture counts of one commit as cmux-perf-result/v1 (Linux, no Mac).

The perf cron counts these rows in its report step (scripts/cmux-next/perf-cron-arch-report.py) and keeps its own
trend and issue. This story takes the same count on every lab batch and writes one result per row, so the counts
become lab series: stored, shown and alerted like every other metric. Chrome does the same with its static sizes:
`build/android/resource_sizes.py --output-format histograms` runs on the perf builders and uploads lower-is-better
counts to chromeperf as one more benchmark, judged by the same anomaly and sheriff pipeline as the timing stories.

The count is the cron report's own: this imports perf-cron-arch-report.py by path and calls its ensure_commit,
list_tree, count_files and counts_at, so the measured commit's own scripts/cmux-next/arch_counts.py runs in a
subprocess under `python3 -I`, with the job's secrets left out of its environment, after at most two blob fetches in
a blobless checkout. The rows are therefore exactly the cron report's rows, and one count contract has one reader.

Each row of the counts is one result: story `arch-counts`, metric `arch.<row>`, unit `count`, better `lower`, one
sample (the count is deterministic: a repeat measures nothing). `build.measure_version` is the count's
`method_version`, because a new method changes the numbers, as a new harness does. A ratcheted row of
plans/cmux-next/arch-ratchet.json at that commit gets `target_ref` {path: that file, key: /totals/<row>}: the limit
is referenced, never copied. The host is a Linux host of class `linux-static` (a count does not depend on the
machine, so every Linux host feeds the same series); its fingerprint still names the machine.

Once scripts/perf-lab/OWNS_MEASUREMENT exists the perf cron stops its arch report (task p12-perf-process-026), and the
lab's alerts (alerts.py, subscriptions.json) replace its issue.

    scripts/perf-lab/stories/arch_counts.py --out DIR [--sha SHA] [--root REPO] [--run-id ID] [--seconds N]

--sha defaults to PERF_LAB_SHA, then CMUX_CI_SHA, then HEAD of --root (the repository this file is in). Exit codes:
0 results written, 1 not measured (the reason is on stderr; nothing is written), 2 usage.

Stdlib only; runs under `python3 -I`. Tests: python3 -I scripts/perf-lab/tests/test_arch_counts_story.py.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import os
import platform
import re
import subprocess
import sys
from typing import Dict, List, Optional, Sequence

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.dirname(HERE)
ROOT = os.path.dirname(os.path.dirname(LAB))
REPORT_PATH = os.path.join(ROOT, "scripts", "cmux-next", "perf-cron-arch-report.py")
PERF_RESULT_PATH = os.path.join(LAB, "perf_result.py")

STORY = "arch-counts"
METRIC_PREFIX = "arch."
UNIT = "count"
BETTER = "lower"
CONFIG = "release"
ENGINE = "none"
SESSION = "light"
HOST_CLASS = "linux-static"
SHA_ENV = ("PERF_LAB_SHA", "CMUX_CI_SHA")
EXIT_OK, EXIT_NOT_MEASURED, EXIT_USAGE = 0, 1, 2


def load_by_path(name: str, path: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: a dataclass resolves its module through sys.modules
    spec.loader.exec_module(module)
    return module


report = load_by_path("perf_cron_arch_report", REPORT_PATH)
perf_result = load_by_path("perf_result", PERF_RESULT_PATH)


class NotMeasured(Exception):
    """The counts at the commit could not be taken; nothing is written."""


def linux_host() -> "perf_result.Host":
    machine = platform.machine() or "unknown"
    identity = "\0".join((platform.system(), platform.node(), machine, platform.release()))
    return perf_result.Host(fingerprint=hashlib.sha256(identity.encode()).hexdigest(), host_class=HOST_CLASS,
                            chip=machine, macos=None, macos_build=None, display_hz=None)


def ratcheted_rows(dl, root: str, sha: str) -> set:
    """The rows plans/cmux-next/arch-ratchet.json at sha ratchets and has a total for (empty when it has none)."""
    ratchet, _ = report.ratchet_at(dl, root, sha)
    if ratchet is None:
        return set()
    return {row for row in ratchet["ratcheted"] if row in ratchet["totals"]}


def count(root: str, sha: str, seconds: float):
    """(full sha, the checked counts record, the ratcheted rows) at sha, counted as the cron report counts."""
    dl = report.Deadline(seconds)
    try:
        report.ensure_commit(dl, root, sha)
        full = report.resolve_sha(dl, root, sha)
        listing = report.list_tree(dl, root, full)
        counts = report.counts_at(dl, root, full, report.count_files(dl, root, full, listing))
        return full, counts, ratcheted_rows(dl, root, full)
    except report.CountError as error:
        raise NotMeasured(str(error)) from None
    except (subprocess.SubprocessError, OSError, ValueError) as error:
        raise NotMeasured(report.failure_text(error)) from None


def results_for(sha: str, counts: dict, ratcheted: set, run, host) -> List["perf_result.Result"]:
    """One result-v1 per row of the counts, in row order."""
    build = perf_result.Build(sha=sha, config=CONFIG, measure_version=counts["method_version"])
    results = []
    for row in sorted(counts["totals"]):
        target = (perf_result.TargetRef(path=report.RATCHET_PATH, key=f"/totals/{row}") if row in ratcheted
                  else None)
        results.append(perf_result.Result(
            story=STORY, metric=METRIC_PREFIX + row, unit=UNIT, better=BETTER, samples=[counts["totals"][row]],
            build=build, host=host, engine=ENGINE, session=SESSION, run=run, target_ref=target))
    return results


def default_sha(environ: Dict[str, str]) -> Optional[str]:
    return next((environ[name] for name in SHA_ENV if environ.get(name)), None)


def measure(out: str, sha: str, *, root: str = ROOT, run=None, host=None,
            seconds: float = report.REPORT_SECONDS) -> str:
    """Counts sha and writes its results as one .ndjson file in out; returns the file's path. Raises NotMeasured."""
    full, counts, ratcheted = count(root, sha, seconds)
    results = results_for(full, counts, ratcheted, run or perf_result.Run.start(), host or linux_host())
    if not results:
        raise NotMeasured(f"{report.COUNTS_SCRIPT} at {full[:12]} counted no row")
    try:
        return str(perf_result.write_ndjson(out, results))
    except perf_result.ResultError as error:
        raise NotMeasured(f"the counts at {full[:12]} are not valid result-v1: {error}") from None


def main(argv: Optional[Sequence[str]] = None, environ: Optional[Dict[str, str]] = None) -> int:
    environ = dict(os.environ if environ is None else environ)
    parser = argparse.ArgumentParser(description="Write the F13 architecture counts of one commit as result-v1.")
    parser.add_argument("--out", required=True, help="the result directory (the runner's {out})")
    parser.add_argument("--sha", default=default_sha(environ), help="the commit to count (PERF_LAB_SHA, CMUX_CI_SHA)")
    parser.add_argument("--root", default=ROOT, help="the git checkout to read the commit from")
    parser.add_argument("--run-id", help="a stable attempt id, so a retry rewrites the same file")
    parser.add_argument("--seconds", type=float, default=report.REPORT_SECONDS, help="the deadline of the count")
    try:
        args = parser.parse_args(argv)
    except SystemExit as error:
        return EXIT_OK if error.code in (0, None) else EXIT_USAGE
    if args.seconds <= 0:
        parser.print_usage(sys.stderr)
        print("arch-counts: --seconds must be > 0", file=sys.stderr)
        return EXIT_USAGE
    if args.run_id is not None and not re.fullmatch(perf_result.NAME_PATTERN, args.run_id):
        parser.print_usage(sys.stderr)
        print(f"arch-counts: --run-id must match {perf_result.NAME_PATTERN}", file=sys.stderr)
        return EXIT_USAGE
    sha = args.sha or "HEAD"
    try:
        path = measure(args.out, sha, root=args.root, run=perf_result.Run.start(run_id=args.run_id),
                       seconds=args.seconds)
    except NotMeasured as error:
        print(f"arch-counts: not measured at {sha}: {error}", file=sys.stderr)
        return EXIT_NOT_MEASURED
    for result in perf_result.read_file(path):
        print(f"{result.metric} {result.samples[0]:g}")
    print(f"arch-counts: wrote {path}")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
