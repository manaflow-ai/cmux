#!/usr/bin/env python3
"""Does this branch push change anything the cmux-tui tree builds? If not, skip the builds.

interim-coord, 2026-11-21 21:34Z: "have the musl builds path-filtered on PRs and main, and run the full
set only on merge queue or nightly." Leo, 2026-11-21 11:10Z: "we are NOT in a position to be letting
inefficiencies pile up and procrastinating... even 300 vms every fucking hour is a huge fucking luxury"

A non-trunk branch push (a pull request head; lane/* never triggers the workflow) builds its own tree
whenever its tree key is unpublished. Since feat-cmux-next builds one tree per coalesce window, most
feat-cmux-next commits have no published tree, so a branch cut from one built every target (two musl
legs, the macOS legs, the daemon tests) even when it changed nothing the tree builds. Nobody reads that
tree: the pull request's route runs no daemon tier for a change that touches no tree-key input
(scripts/ci/cmux_next_route.py), and every tree reader falls back to the newest published tree.

Unchanged means the head's v2 tree key equals the key of its merge base with feat-cmux-next: the key
covers every input the build reads (scripts/cmux-next/cmux-tui-tree-inputs.txt), so the build would make
the tree of the base. A head that carries the trailer Cmux-Daemon-Tests: run is never unchanged.

Every failure answers "changed": the run builds as before. Undo: vars.CMUX_TUI_BRANCH_INPUT_GATE = '0'.

Git reads, no REST: the commits since --since (default 21 days) of the head and the base with no trees
(--filter=tree:0), then the merge base's trees (--filter=blob:none --depth=1) and the one blob the key
reads (the inputs list). The checkout must be a blob:none partial clone of the repository (origin).

Usage: cmux_tui_branch_inputs.py --ref REF --sha SHA [--base feat-cmux-next] [--since 21.days]
Writes unchanged=true|false to $GITHUB_OUTPUT.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cmux_tui_superseded_push as superseded  # noqa: E402
import cmux_tui_tree_key as tree_key  # noqa: E402

DEADLINE_SECONDS = 150
GIT_TIMEOUT_SECONDS = 60


class Unknown(Exception):
    pass


def git(*args: str, lazy: bool = False, deadline: float) -> str:
    left = deadline - time.monotonic()
    if left <= 1:
        raise Unknown("deadline reached")
    env = dict(os.environ)
    if lazy:
        env.pop("GIT_NO_LAZY_FETCH", None)
    else:
        env["GIT_NO_LAZY_FETCH"] = "1"
    try:
        return subprocess.run(["git", "-C", str(tree_key.ROOT), *args], capture_output=True, text=True, env=env,
                              timeout=min(GIT_TIMEOUT_SECONDS, left), check=True).stdout.strip()
    except subprocess.CalledProcessError as error:
        raise Unknown(f"git {args[0]} failed: {error.stderr.strip()[-300:]}") from error
    except (OSError, subprocess.SubprocessError) as error:
        raise Unknown(f"git {args[0]}: {error}") from error


def verdict(ref: str, sha: str, base: str, since: str) -> tuple[bool, str]:
    if not superseded.needs_open_pull_request(ref) or ref in superseded.PROTECTED:
        return False, f"{ref} is a trunk or integration ref; it builds every changed tree"
    deadline = time.monotonic() + DEADLINE_SECONDS
    # daemon-policy's opt-in, read in this checkout (superseded.asks_for_daemon_tests reads the cwd's repository).
    trailer = git("log", "-1", "--format=%(trailers:key=Cmux-Daemon-Tests,valueonly)", sha, deadline=deadline)
    if "".join(trailer.split()).lower() == "run":
        return False, f"{sha[:12]} carries Cmux-Daemon-Tests: run"
    base_ref = f"refs/remotes/origin/{base}"
    git("fetch", "--no-tags", "--quiet", "--filter=tree:0", f"--shallow-since={since}", "origin",
        f"+refs/heads/{base}:{base_ref}", sha, lazy=True, deadline=deadline)
    try:
        merge_base = git("merge-base", sha, base_ref, deadline=deadline)
    except Unknown as error:
        raise Unknown(f"no merge base with {base} within {since}") from error
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base):
        raise Unknown(f"unexpected merge base {merge_base!r}")
    if merge_base != sha:
        # No haves: the server sends the merge base's whole tree, not just what a shallow have implies.
        git("-c", "fetch.negotiationAlgorithm=noop", "fetch", "--no-tags", "--quiet", "--filter=blob:none",
            "--depth=1", "origin", merge_base, lazy=True, deadline=deadline)
    for revision in {sha, merge_base}:
        # tree_key reads the inputs list blob with lazy fetches off; bring that one blob in.
        git("cat-file", "blob", f"{revision}:{tree_key.INPUTS_PATH}", lazy=True, deadline=deadline)
    try:
        head_key = tree_key.tree_key(sha, "v2")
        base_key = tree_key.tree_key(merge_base, "v2")
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        raise Unknown(f"tree key: {error}") from error
    if head_key == base_key:
        return True, (f"{sha[:12]} has the tree key {head_key[:12]} of its merge base {merge_base[:12]} with {base}: "
                      "it changes no tree-key input")
    return False, f"tree key {head_key[:12]} differs from merge base {merge_base[:12]}'s {base_key[:12]}"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ref", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--base", default="feat-cmux-next")
    parser.add_argument("--since", default="21.days")
    args = parser.parse_args(argv)
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha):
        print("error: --sha must be 40-hex", file=sys.stderr)
        return 2
    try:
        unchanged, reason = verdict(args.ref, args.sha, args.base, args.since)
    except Unknown as error:
        unchanged, reason = False, f"could not tell ({error}); building as before"
        print(f"::warning title=cmux-tui branch inputs::{reason}")
    if unchanged:
        print(f"::notice title=cmux-tui inputs unchanged::{reason}. This run builds and publishes nothing; "
              "readers use the newest published tree. To build anyway add the trailer Cmux-Daemon-Tests: run.")
    else:
        print(f"Building: {reason}")
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"unchanged={'true' if unchanged else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
