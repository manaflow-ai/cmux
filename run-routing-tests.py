from __future__ import annotations
import subprocess
import sys

commands = [
    [sys.executable, "tests/test_ci_portable_job_placement.py"],
    [sys.executable, "tests/test_runner_routing_table.py"],
    [sys.executable, "tests/test_pr_checks_base_only.py"],
    [sys.executable, "tests/test_cmux_next_fast_gates.py"],
    [sys.executable, "tests/test_web_validation.py"],
    [sys.executable, "tests/test_ci_runner_set.py"],
    [sys.executable, "tests/test_ci_fork_runner_routing.py"],
    ["bash", "tests/test_ci_self_hosted_guard.sh"],
    ["actionlint", ".github/workflows/ci-guards.yml", ".github/workflows/pr-red-checks-comment.yml"],
]
for command in commands:
    print("$", " ".join(command), flush=True)
    result = subprocess.run(command)
    if result.returncode:
        raise SystemExit(result.returncode)
