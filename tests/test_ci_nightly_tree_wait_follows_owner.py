#!/usr/bin/env python3
"""A NEXT nightly never waits blind on another run for its cmux-tui tree.

Leo, 2026-11-18: "why does cmux-tui artifacts keep sitting pending?" and "will new nightly come soon".

Nightly 44243166776 (a69bd327d5) sat in "Bundle the cmux-tui client" for its tree 453a2f94:
- the nightly-next push's cmux-tui artifacts run 44243166694 sat run-level "pending" in the
  push-<sha> concurrency group behind the feat-cmux-next push run of the same commit
  (44242726208); both then deferred to an owner run;
- the owner, 44240874997, had a failed Linux build, and the same-key takeover run 44243309941
  had its Linux builds queued on blacksmith-16vcpu-ubuntu-2404 with no runner;
- await-tree-client.sh counted any not-completed run as "building" and waited the whole 45 min
  (the earlier nightlies 44232805509 and 44235456054 failed exactly so).

1. cmux-tui-artifacts.yml: a nightly-next push and a feat-cmux-next push of one commit never
   share a concurrency group (one never sits pending behind the other).
2. The nightly's "Bundle the cmux-tui client" waits through await-tree-client.sh, and that wait
   reads the publisher's jobs (pin-cmux-tui.sh run-progress): a failed build or a job with no
   runner past CMUX_TUI_TREE_RUNNER_STALL_SECONDS ends the wait at its run checks, not at the limit.
3. scripts/cmux-next/tests/nightly-tree-at-install.test.sh runs those cases against fake runs.

Run: python3 tests/test_ci_nightly_tree_wait_follows_owner.py (a few seconds; part 3 needs
bash, git and sha256sum).
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))
from nightly_workflow_text import expand  # noqa: E402

ARTIFACTS = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
AWAIT = ROOT / "scripts/cmux-next/await-tree-client.sh"
PIN = ROOT / "scripts/cmux-next/pin-cmux-tui.sh"
SHELL_TEST = ROOT / "scripts/cmux-next/tests/nightly-tree-at-install.test.sh"


def concurrency_group() -> str:
    text = ARTIFACTS.read_text()
    match = re.search(r"^concurrency:\n(?:  #.*\n)*  group: (?P<group>.+)$", text, re.MULTILINE)
    assert match, "cmux-tui-artifacts.yml has no top-level concurrency group"
    return match.group("group")


def test_nightly_next_and_feat_cmux_next_never_share_a_group() -> None:
    group = concurrency_group()
    # Each branch's per-commit group is its own expression, with its own name.
    branch_groups = re.findall(r"github\.ref == 'refs/heads/([\w-]+)' && github\.event_name == 'push' && format\('([\w-]+)\{0\}', github\.sha\)", group)
    names = dict(branch_groups)
    assert "feat-cmux-next" in names and "nightly-next" in names, (
        "each of feat-cmux-next and nightly-next needs its own per-commit push group", group)
    assert names["feat-cmux-next"] != names["nightly-next"], (
        "a nightly-next push of a feat-cmux-next commit would sit pending behind that commit's run", group)
    # The old combined form put both branches in one push-<sha> group.
    assert "|| github.ref == 'refs/heads/nightly-next')" not in group, group


def test_the_bundle_step_waits_through_the_owner_aware_wait() -> None:
    nightly = expand((ROOT / ".github/workflows/nightly.yml").read_text())
    step = nightly.split("name: Bundle the cmux-tui client", 1)
    assert len(step) == 2, "nightly.yml has no 'Bundle the cmux-tui client' step"
    body = step[1].split("\n      - ", 1)[0]
    assert "scripts/cmux-next/await-tree-client.sh" in body, body


def test_the_wait_reads_the_publishers_jobs_and_bounds_a_stall() -> None:
    wait = AWAIT.read_text()
    assert "run-progress" in wait, "await-tree-client.sh counts any not-completed run as building"
    assert "CMUX_TUI_TREE_SKIP_PUBLISHERS" in wait, "a stuck owner is not passed over for another same-key run"
    pin = PIN.read_text()
    progress = pin.split("artifacts_run_progress() {", 1)[1].split("\n}\n", 1)[0]
    assert "/jobs?" in progress, "run-progress must read the run's jobs"
    assert "CMUX_TUI_TREE_RUNNER_STALL_SECONDS" in progress
    assert "runner_name" in progress, "a queued job is one no runner has taken"
    stall = re.search(r'CMUX_TUI_TREE_RUNNER_STALL_SECONDS:-(\d+)', progress)
    limit = re.search(r'CMUX_TUI_TREE_CLIENT_WAIT_SECONDS:-(\d+)', wait)
    assert stall and limit and int(stall.group(1)) < int(limit.group(1)) // 2, (
        "the runner stall bound must end the wait well before its limit")


def test_the_wait_cases_pass_against_fake_runs() -> None:
    missing = [tool for tool in ("bash", "git", "sha256sum") if shutil.which(tool) is None]
    if missing:
        print(f"skip: {SHELL_TEST.name} needs {', '.join(missing)}")
        return
    result = subprocess.run(["bash", str(SHELL_TEST)], capture_output=True, text=True, timeout=600)
    assert result.returncode == 0, result.stdout + result.stderr
    for case in ("whose build failed on its last attempt fails fast", "no runner past the stall bound fails fast",
                 "queued under the stall bound keeps the wait", "a retry will re-run keeps the wait",
                 "the fallback rebuilds it) keeps the wait", "holds no tree back keeps the wait",
                 "failed owner is passed over", "a preflight with no runner past the stall bound fails fast",
                 "a terminal preflight failure fails fast", "a preflight failure with active retry grace",
                 "a preflight queued under the stall bound keeps the wait"):
        assert any(line.startswith("ok   ") and case in line for line in result.stdout.splitlines()), (case, result.stdout)


if __name__ == "__main__":
    for name, test in sorted(globals().items()):
        if name.startswith("test_") and callable(test):
            test()
            print(f"ok {name}")
