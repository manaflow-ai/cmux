from __future__ import annotations
import subprocess
import sys
for test in ["test_ci_portable_job_placement.py", "test_runner_routing_table.py", "test_pr_red_checks_comment.py", "test_ci_runner_set.py", "test_ci_fork_runner_routing.py"]:
    print("$ python3 tests/" + test, flush=True)
    subprocess.run([sys.executable, "tests/" + test], check=True)
