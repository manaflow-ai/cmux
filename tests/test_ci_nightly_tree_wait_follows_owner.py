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
    # The wait and the resolver that decides to wait share one reading of the publisher
    # (2026-11-18: the resolver alone still took a stalled owner as a publisher).
    for script in (AWAIT, ROOT / "scripts/ci/nightly-steps/resolve-tree-pending.sh"):
        assert "pin-cmux-tui.sh tree-publisher" in script.read_text(), f"{script.name} judges the publisher on its own"
    pin = PIN.read_text()
    reading = pin.split("tree_publisher() {", 1)[1].split("\n}\n", 1)[0]
    assert "artifacts_run_progress" in reading, "tree-publisher counts any not-completed run as building"
    assert "CMUX_TUI_TREE_SKIP_PUBLISHERS" in reading, "a stuck owner is not passed over for another same-key run"
    progress = pin.split("artifacts_run_progress() {", 1)[1].split("\n}\n", 1)[0]
    assert "/jobs?" in progress, "run-progress must read the run's jobs"
    assert "CMUX_TUI_TREE_RUNNER_STALL_SECONDS" in progress
    assert "runner_name" in progress, "a queued job is one no runner has taken"
    stall = re.search(r'CMUX_TUI_TREE_RUNNER_STALL_SECONDS:-(\d+)', progress)
    limit = re.search(r'CMUX_TUI_TREE_CLIENT_WAIT_SECONDS:-(\d+)', wait)
    assert stall and limit and int(stall.group(1)) < int(limit.group(1)) // 2, (
        "the runner stall bound must end the wait well before its limit")


def _bundle_await_tree(bundle: str) -> str:
    # Every tree wait in the signer step goes through await_tree(), which sets the step's limits: the
    # no-fallback wait and the wait after a refused fallback once used await-tree-client.sh's own
    # 2700 s bound plus its rebuild grace (NIGHTLY 46157002388 held ultra1 past 50 min, 2026-11-28).
    body = re.search(r"^await_tree\(\) \{\n(.*?)^\}", bundle, re.S | re.M)
    assert body, "the bundle step must define await_tree()"
    calls = [line for line in bundle.splitlines()
             if "scripts/cmux-next/await-tree-client.sh" in line and not line.lstrip().startswith("#")]
    assert len(calls) == 1 and calls[0] in body.group(1), (
        "only await_tree() may call await-tree-client.sh, so no wait runs on its default bound")
    assert 'CMUX_TUI_TREE_CLIENT_WAIT_SECONDS="$(wait_left)"' in body.group(1), (
        "each wait must get what is left of the step's one budget")
    return body.group(1)


def test_the_signer_bundle_step_bounds_an_unreadable_runs_list() -> None:
    # The bundle step runs inside nightly-next-one on the one signing Mac; with a fallback tree in
    # hand an unreadable runs list must not hold that Mac for the whole bound (2026-11-28, NIGHTLY
    # 46105117438 held it 1568 s on five "could not all be read" checks).
    bundle = (ROOT / "scripts/ci/nightly-steps/app-bundle-cmux-tui-client.sh").read_text()
    await_tree = _bundle_await_tree(bundle)
    assert 'CMUX_TUI_TREE_CLIENT_UNREADABLE_CHECKS="$unreadable_checks"' in await_tree, (
        "every tree wait in the signer step must set an unreadable-checks limit")
    limit = re.search(r'CMUX_TUI_TREE_CLIENT_UNREADABLE_CHECKS:-(\d+)', bundle)
    assert limit and 0 < int(limit.group(1)) <= 2, "the signer step's unreadable-checks limit must be 1 or 2"
    wait = AWAIT.read_text()
    assert "unreadable_checks >= unreadable_limit" in wait, "the wait must count unreadable checks in a row"


def test_the_signer_bundle_step_does_not_wait_out_a_macos_rebuild() -> None:
    # A publisher rebuilding its failed primary macOS leg lands the tree about 30 min late; with a
    # fallback tree in hand the signer step must not hold the one signing Mac for it (2026-11-28,
    # NIGHTLY 46123570780 held it 1869 s, then bundled the fallback tree anyway).
    bundle = (ROOT / "scripts/ci/nightly-steps/app-bundle-cmux-tui-client.sh").read_text()
    await_tree = _bundle_await_tree(bundle)
    assert 'CMUX_TUI_TREE_CLIENT_REBUILD_ENDS="$rebuild_ends"' in await_tree, (
        "every tree wait in the signer step must end on a rebuilding publisher")
    assert re.search(r'CMUX_TUI_TREE_CLIENT_REBUILD_ENDS:-1\}', bundle), "the signer step must default it on"
    wait = AWAIT.read_text()
    assert '"$rebuilding" == true && "$rebuild_ends" == 1' in wait, "the wait must end on a rebuild when asked"


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
                 "a preflight queued under the stall bound keeps the wait",
                 "unreadable runs keep waiting when no limit is set", "unreadable runs end the wait at the set limit",
                 "a malformed unreadable-checks limit is a usage error"):
        assert any(line.startswith("ok   ") and case in line for line in result.stdout.splitlines()), (case, result.stdout)


if __name__ == "__main__":
    for name, test in sorted(globals().items()):
        if name.startswith("test_") and callable(test):
            test()
            print(f"ok {name}")
