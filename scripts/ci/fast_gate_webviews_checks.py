#!/usr/bin/env python3
"""The webviews checks gate of the cmux-next fast gates, run on a pull request merged with the current tip.

    fast_gate_webviews_checks.py --base BASE [--repo PATH]

Installs webviews' node_modules (bun install --frozen-lockfile) and runs, in webviews/, each check that ci-web's
"Check webviews" step fails on for a feat-cmux-next pull request, except the type check, which compiles rather than
checks. tests/test_cmux_next_fast_gates.py keeps CHECKS equal to ci-web.yml's fail-mode list.

Only findings the pull request adds fail, as in the other diff-scoped gates: a check that fails on the merge runs
again on BASE (a worktree of it, sharing the merge's node_modules), and the gate fails only on output lines BASE
does not print as often (with the checkout root, `path:line` numbers and timings ignored, since the pull request
may move lines; a check's own counts still compare). A
check red on the base and no worse here is the base's red, which this gate never charges to a pull request.
Runs every check and exits 1 when any adds a finding.

cmux_next_fast_gates.py runs this only on a dispatch (pr=N, against the current tip): on a pull_request event
ci-web already ran these checks on the same merge commit. A merger dispatches when a check path
(scripts/ci/check-paths.txt) changed on the base after the pull request's last fast-gates base, so a check that
landed after the pull request's CI runs on it before it merges (2026-10-21: #22967, #22975 and #23094 merged past
the new check:fixed-waits; replayed, #22975 merged with 01ea78b3 adds
"test/agent-pane-queued-images.test.ts: 2 fixed waits, baseline 0" to the two findings the base already had).
"""
from __future__ import annotations

import argparse
from collections import Counter
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CHECKS = ("check:browser-lanes", "check:fixed-waits", "acpmux-protocol:check", "check:catalog-keys")
LINE_REF = re.compile(r"(\S):\d+(?::\d+)?\b")
TIMING = re.compile(r"\b\d+(?:\.\d+)?\s?(?:ms|s)\b")


def run_check(webviews: Path, check: str) -> tuple[int, str]:
    result = subprocess.run(["bun", "run", check], cwd=webviews, capture_output=True, text=True)
    return result.returncode, result.stdout + result.stderr


def key(line: str, root: str = "") -> str:
    """A line as a finding: stripped, its checkout root, `path:line[:col]` numbers and timings dropped."""
    if root:
        line = line.replace(root, "<root>")
    return TIMING.sub("<time>", LINE_REF.sub(r"\1", line.strip()))


def added(merge_output: str, base_output: str, merge_root: str = "", base_root: str = "") -> list[str]:
    """Lines of the merge's output beyond the base's, in the merge's order. Counted, not a set: a second finding
    that reads like one the base already has is still new."""
    left = Counter(key(line, base_root) for line in base_output.splitlines() if line.strip())
    out = []
    for line in merge_output.splitlines():
        found = key(line, merge_root)
        if not found:
            continue
        if left[found] > 0:
            left[found] -= 1
        else:
            out.append(line.rstrip())
    return out


class BaseTree:
    """A worktree of BASE whose webviews/node_modules is the merge's, made on first use."""

    def __init__(self, repo: Path, base: str):
        self.repo, self.base, self.path = repo, base, None

    def webviews(self) -> Path | None:
        if self.path is None:
            holder = Path(tempfile.mkdtemp(prefix="fast-gate-webviews-base-"))
            made = subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "--quiet", "--detach",
                                   str(holder / "base"), self.base], capture_output=True, text=True)
            if made.returncode != 0:
                print(f"webviews checks: could not check out the base {self.base}: {made.stderr.strip()}", flush=True)
                shutil.rmtree(holder, ignore_errors=True)
                self.path = False
                return None
            modules = self.repo / "webviews" / "node_modules"
            if modules.is_dir():
                (holder / "base" / "webviews" / "node_modules").symlink_to(modules.resolve())
            self.path = holder / "base"
        return self.path / "webviews" if self.path else None

    def close(self) -> None:
        if self.path:
            subprocess.run(["git", "-C", str(self.repo), "worktree", "remove", "--force", str(self.path)],
                           capture_output=True)
            shutil.rmtree(self.path.parent, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True, help="the base sha the pull request was merged into")
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    repo = args.repo.resolve()
    webviews = repo / "webviews"
    if subprocess.run(["bun", "install", "--frozen-lockfile"], cwd=webviews).returncode != 0:
        print("webviews checks: bun install --frozen-lockfile failed", flush=True)
        return 1
    base = BaseTree(repo, args.base)
    failed = []
    try:
        for check in CHECKS:
            code, output = run_check(webviews, check)
            print(output, end="", flush=True)
            if code == 0:
                continue
            base_webviews = base.webviews()
            if base_webviews is None:  # no base to compare with: the red is charged here
                failed.append(check)
                continue
            base_code, base_output = run_check(base_webviews, check)
            new = (added(output, base_output, str(repo), str(base_webviews.parent)) if base_code != 0
                   else output.splitlines())
            if not new:
                print(f"webviews checks: {check} fails on the base {args.base[:12]} too and this adds nothing to it",
                      flush=True)
                continue
            failed.append(check)
            print(f"webviews checks: {check} adds, over the base {args.base[:12]}:", flush=True)
            for line in new:
                print(f"  {line}", flush=True)
    finally:
        base.close()
    for check in failed:
        print(f"::error title=webviews {check}::{check} fails on the pull request merged with the current tip")
    print(f"webviews checks: {', '.join(failed) + ' failed' if failed else 'all passed'}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
