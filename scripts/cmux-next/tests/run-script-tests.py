#!/usr/bin/env python3
"""Run every scripts/cmux-next test_*.py the cmux-next checks job has no line of its own for.

The checks job used to name each of these tests on its own line. A new test missing from that
hand list ran nowhere, and tests/test_cmux_next_checks_workflow.py (ScriptTestsAreListed) then
turned feat-cmux-next red (#43986, #44113, #44407). This runner finds them by glob, so a new
test runs with no workflow edit. A test some other line runs is in EXCLUDED with that reason.

    python3 scripts/cmux-next/tests/run-script-tests.py [--root DIR] [--jobs N] [--list]

Each test runs as `python3 PATH` from the root with stdin closed, a few at a time (--jobs, by
default the job's CPU grant CMUX_CI_CPU_BUDGET or the CPU count). Every test runs even after one
fails; each one's output is printed whole, in path order, then the failed ones are named again and
the exit status is 1. On TERM (the check pool's deadline) it names the tests still running.
"""
from __future__ import annotations

import argparse
import os
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FOLDER = "scripts/cmux-next"
SKIP_PARTS = {"node_modules", "__pycache__"}

CHECKS_JOB = "its own line in the cmux-next checks job"
EXCLUDED: dict[str, str] = {
    # Run by a line of their own in the checks job (.github/workflows/cmux-next.yml).
    "scripts/cmux-next/tests/test_hot_apply.py": f"{CHECKS_JOB}: about four minutes, so it starts first",
    "scripts/cmux-next/tests/test_check_package_dependency_lists.py": f"{CHECKS_JOB}, beside the check it tests",
    "scripts/cmux-next/tests/test_bundle_size.py": f"{CHECKS_JOB} (python3 -I)",
    "scripts/cmux-next/tests/test_bundle_size_pr.py": f"{CHECKS_JOB} (python3 -I)",
    "scripts/cmux-next/tests/test_fetch_nightly_dmg.py": f"{CHECKS_JOB} (python3 -I)",
    "scripts/cmux-next/tests/test_cef_pak_drop.py": f"{CHECKS_JOB} (python3 -I)",
    "scripts/cmux-next/tests/test_herdr_sync.py": f"{CHECKS_JOB}, after herdr-sync.py check (python3 -I)",
    "scripts/cmux-next/tests/test_build_names.py": f"{CHECKS_JOB} (python3 -I)",
    "scripts/cmux-next/tests/test_hot_verify_ci.py": f"{CHECKS_JOB} (python3 -I)",
    "scripts/cmux-next/tests/test_rj_rows.py": f"{CHECKS_JOB} (python3 -I)",
    "scripts/cmux-next/tests/test_rj_update.py": f"{CHECKS_JOB} (python3 -I)",
    "scripts/cmux-next/tests/test_sidebar_perf_validate.py": f"{CHECKS_JOB} (python3 -I)",
    "scripts/cmux-next/tests/test_motion_inventory.py": f"{CHECKS_JOB}: the motion inventory step",
    "scripts/cmux-next/tests/test_settings_export_keys.py": f"{CHECKS_JOB}: the settings export step",
    # Run by the workflow that owns what they test.
    "scripts/cmux-next/degenerate-lab/test_lab.py": "cmux-next-degenerate-lab.yml",
    "scripts/cmux-next/notices/test_check_bundle_notices.py": "cmux-next-guards.yml",
    "scripts/cmux-next/notices/test_check_first_party_licenses.py": "cmux-next-guards.yml",
    "scripts/cmux-next/notices/test_check_ghostty_vt_notices.py": "cmux-next-guards.yml",
    "scripts/cmux-next/notices/test_compose_notices.py": "cmux-next-guards.yml",
    "scripts/cmux-next/notices/test_ghostty_source_archive.py": "cmux-next-source-archive.yml",
    "scripts/cmux-next/notices/test_ghostty_themes_notice.py": "cmux-next-guards.yml",
    "scripts/cmux-next/notices/test_ios_notices.py": "cmux-next-guards.yml",
    "scripts/cmux-next/notices/test_ios_source_archive.py": "cmux-next-guards.yml",
    "scripts/cmux-next/notices/test_vt_link_graph.py": "cmux-next-source-archive.yml",
    "scripts/cmux-next/tests/test_quality_report.py": "cmux-next-quality-report.yml",
}


def script_tests(root: Path) -> list[str]:
    """Every test_*.py under scripts/cmux-next, as root-relative paths in order."""
    folder = root / FOLDER
    return sorted(path.relative_to(root).as_posix() for path in folder.rglob("test_*.py")
                  if path.is_file() and not SKIP_PARTS & set(path.relative_to(folder).parts))


def selected(tests: list[str]) -> list[str]:
    """The tests this runner runs: each one EXCLUDED does not name."""
    return [test for test in tests if test not in EXCLUDED]


def default_jobs() -> int:
    budget = os.environ.get("CMUX_CI_CPU_BUDGET", "")
    return int(budget) if budget.isdigit() and int(budget) > 0 else (os.cpu_count() or 2)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--jobs", type=int, default=default_jobs())
    parser.add_argument("--list", action="store_true", help="print the tests it would run and exit")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    tests = selected(script_tests(root))
    if args.list:
        print("\n".join(tests))
        return 0
    if not tests:
        print(f"error: no test_*.py under {root / FOLDER}", file=sys.stderr)
        return 2

    started: dict[str, float] = {}

    def on_term(signum, _frame):
        now = time.monotonic()
        for test, at in sorted(started.items()):
            print(f"{test}: still running after {now - at:.0f}s when the runner was stopped", flush=True)
        os._exit(128 + signum)

    signal.signal(signal.SIGTERM, on_term)

    def run(test: str) -> tuple[int, str, float]:
        started[test] = time.monotonic()
        result = subprocess.run([sys.executable, test], cwd=root, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        took = time.monotonic() - started.pop(test)
        return result.returncode, result.stdout, took

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        results = list(pool.map(run, tests))
    failed = []
    for test, (code, output, took) in zip(tests, results):
        verdict = "ok" if code == 0 else f"FAILED (exit {code})"
        print(f"---- {test}: {verdict} ({took:.1f}s)\n{output.rstrip()}", flush=True)
        if code != 0:
            failed.append(test)
    print(f"{len(tests) - len(failed)} of {len(tests)} script tests passed")
    for test in failed:
        print(f"::error title=script test failed::{test}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
