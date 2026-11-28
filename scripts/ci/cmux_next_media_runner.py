#!/usr/bin/env python3
"""Pick the runner for cmux-next-media.yml's tour: an owned Mac's gui runner, or none.

The tour launches cmux-next and screenshots it, so it needs a logged-in
console session that can come to the front and be captured. Blacksmith's
macOS sessions sit at a locked screen (e2e_runner_pool.py on main has the
runs), so the tour never falls back to Blacksmith: with no owned gui runner it
does not run, and the comment says why.

The label is the gui runner of the owned pool for the pull request lane's
Xcode pin (pr_runner_pool.gui_label(), `glaeda-gui-<class>-xcode-<version>`),
one per mini, the runner that holds the mini's console session. Workflows
never name an owned label (tests/test_ci_self_hosted_guard.sh), so it reaches
runs-on only as this script's output.

Rules, in order: a fork head gets nothing (owned Macs run trusted code only);
CI_PR_POOL_OWNED must be 1; the first owned pool class whose gui label has
machines in CI_OWNED_POOL_SLOTS wins.

Writes `runs_on` (a label, or "") and `reason` to $GITHUB_OUTPUT, and prints them.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_runner_pool  # noqa: E402


def pick(*, same_repo: bool, owned: str | None, owned_slots: str | None,
         pr_xcode_app: str | None) -> tuple[str, str]:
    """(label, reason); the label is "" when the tour should not run."""
    if not same_repo:
        return "", "a fork head never runs on an owned Mac"
    if (owned or "").strip() != "1":
        return "", "owned Macs are off (CI_PR_POOL_OWNED is not 1)"
    pools = pr_runner_pool.owned_pools(pr_xcode_app)
    if not pools:
        return "", f"no owned pool for the lane's Xcode pin ({pr_xcode_app or 'unset'})"
    slots = pr_runner_pool.slots(owned_slots, pr_xcode_app)
    for pool in pools:
        gui = pr_runner_pool.gui_label(pool)
        if gui and slots.get(gui, 0) > 0:
            return gui, f"{slots[gui]} gui runner(s) on {pool}"
    return "", "no owned pool has gui runners in CI_OWNED_POOL_SLOTS"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--same-repo", required=True, choices=("true", "false"))
    args = parser.parse_args(argv)
    label, reason = pick(
        same_repo=args.same_repo == "true",
        owned=os.environ.get("POOL_OWNED"),
        owned_slots=os.environ.get("OWNED_SLOTS"),
        pr_xcode_app=os.environ.get("PR_XCODE_APP"),
    )
    lines = [f"runs_on={label}", f"reason={reason}"]
    print("\n".join(lines))
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
