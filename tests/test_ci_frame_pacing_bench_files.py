#!/usr/bin/env python3
"""The frame pacing bench job checks out every script it runs.

The bench job (.github/workflows/cmux-next-frame-pacing.yml) checks out a
sparse tree. Its steps ran scripts/ci/run-in-console-session.sh after #15659
deleted it, and bench.sh sources scripts/lib/stop-cmux-tui-owners.sh, which the
sparse list never named. The bench step is continue-on-error, so a run on an
owned Mac came back green with nothing measured (cx-v9hdp).

So: every repository script a bench step runs, and every file bench.sh or golden.sh sources,
must exist in this tree and be inside the sparse checkout.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-frame-pacing.yml"
BENCH = ROOT / "scripts" / "ci" / "frame-pacing" / "bench.sh"
GOLDEN = ROOT / "scripts" / "ci" / "frame-pacing" / "golden.sh"
SCRIPT = re.compile(r"(?<![\w/$.-])((?:\./)?scripts/[\w./-]+\.(?:sh|py))")
SOURCED = re.compile(r'^\s*(?:source|\.)\s+"\$\(dirname "\$\{BASH_SOURCE\[0\]\}"\)/([^"]+)"', re.M)


def bench_job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]["bench"]


def sparse_paths(job: dict) -> list[str]:
    for step in job["steps"]:
        sparse = (step.get("with") or {}).get("sparse-checkout")
        if sparse:
            return [line.strip() for line in sparse.splitlines() if line.strip()]
    raise AssertionError("the bench job has no sparse checkout")


def needed_files(job: dict) -> set[str]:
    needed = set()
    for step in job["steps"]:
        for match in SCRIPT.findall(step.get("run", "")):
            needed.add(match.removeprefix("./"))
    for script in (BENCH, GOLDEN):
        for relative in SOURCED.findall(script.read_text(encoding="utf-8")):
            needed.add((script.parent / relative).resolve().relative_to(ROOT).as_posix())
    return needed


def checked_out(path: str, sparse: list[str]) -> bool:
    return any(path == entry or path.startswith(entry.rstrip("/") + "/") for entry in sparse)


def test_every_script_the_bench_runs_exists() -> None:
    missing = sorted(path for path in needed_files(bench_job()) if not (ROOT / path).is_file())
    assert not missing, f"the bench job runs scripts this tree lacks: {missing}"


def test_every_script_the_bench_runs_is_checked_out() -> None:
    job = bench_job()
    sparse = sparse_paths(job)
    outside = sorted(path for path in needed_files(job) if not checked_out(path, sparse))
    assert not outside, f"the bench job's sparse checkout leaves out: {outside}"


if __name__ == "__main__":
    failures = 0
    for name, test in list(globals().items()):
        if name.startswith("test_") and callable(test):
            try:
                test()
                print(f"ok {name}")
            except AssertionError as error:
                failures += 1
                print(f"FAIL {name}: {error}")
    sys.exit(1 if failures else 0)
