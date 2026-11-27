#!/usr/bin/env python3
"""The input-tree key of a job whose inputs are its workflow's `on.pull_request.paths`, for .github/actions/tree-result.

    paths_tree_key.py --workflow .github/workflows/backend.yml --job api-workerd-3 [--commit HEAD]

A workflow whose `pull_request.paths` already decides whether it runs at all says, by that list, which files its
jobs read. This prints one hash of the git object id of each of those paths at COMMIT (a directory's tree id covers
every file under it; an absent path hashes as absent), the workflow file's own blob and the job id. Two commits with
the same key give the job the same files, so a green result of the job for one is its result for the other
(scripts/ci/tree_result.py), on the same terms the `paths` filter already trusts when it skips the workflow.

The workflow file is always one of the hashed paths: a change to the job's own steps, its matrix or a tool version
pinned there is a new key.

Prints nothing (no key: the job runs, nothing is reused) when the list cannot be read whole: no `pull_request.paths`,
a pattern this reader does not map to a path (a `*` anywhere but a trailing `/**`, a `!` exclusion), or git failing.

Test: tests/test_ci_paths_tree_key.py.
"""
from __future__ import annotations

import argparse
import hashlib
import re
import subprocess
import sys

KEY_VERSION = "paths-tree-key/1"


def pull_request_paths(text: str) -> list[str] | None:
    """The entries of `on: pull_request: paths:` in a workflow's text, or None when there is no such list.
    A line reader, not YAML: it takes the block under `pull_request:` (two-space indent) and its `paths:` list."""
    lines = text.splitlines()
    in_on = in_pr = in_paths = False
    paths: list[str] = []
    found = False
    for line in lines:
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent == 0:
            if in_paths:
                break
            in_on = line.rstrip() in ("on:", '"on":', "'on':")
            in_pr = in_paths = False
            continue
        if not in_on:
            continue
        if indent == 2:
            if in_paths:
                break
            in_pr = line.strip() == "pull_request:"
            continue
        if not in_pr:
            continue
        if indent == 4:
            if in_paths:
                break
            in_paths = line.strip() == "paths:"
            found = found or in_paths
            continue
        if in_paths:
            m = re.fullmatch(r"\s*-\s*(['\"]?)(.*?)\1\s*(#.*)?", line)
            if not m:
                return None
            paths.append(m.group(2))
    return paths if found and paths else None


def pathspec(pattern: str) -> str | None:
    """A `paths` pattern as the path whose object id covers it: `dir/**` is `dir`, a plain file is itself; anything
    else (another glob, an exclusion) is None, so the caller gives no key."""
    if pattern.startswith("!"):
        return None
    if pattern.endswith("/**"):
        pattern = pattern[:-3]
    if not pattern or any(c in pattern for c in "*?[]"):
        return None
    return pattern.rstrip("/")


def object_id(commit: str, path: str, cwd: str | None = None) -> str:
    """`mode type oid` of PATH at COMMIT (`git ls-tree`), or `absent`."""
    done = subprocess.run(["git", "ls-tree", "--full-tree", commit, "--", path], capture_output=True, text=True,
                          check=True, cwd=cwd)
    for row in done.stdout.splitlines():
        meta, _, name = row.partition("\t")
        if name == path:
            return meta
    return "absent"


def key(workflow: str, job: str, commit: str = "HEAD", cwd: str | None = None) -> str | None:
    try:
        text = subprocess.run(["git", "show", f"{commit}:{workflow}"], capture_output=True, text=True, check=True,
                              cwd=cwd).stdout
    except (subprocess.CalledProcessError, OSError):
        return None
    patterns = pull_request_paths(text)
    if patterns is None:
        return None
    specs = [pathspec(p) for p in patterns]
    if any(s is None for s in specs):
        return None
    digest = hashlib.sha256(f"{KEY_VERSION}\0{workflow}\0{job}\0".encode())
    try:
        for path in sorted(set(specs) | {workflow}):
            digest.update(f"{path}\0{object_id(commit, path, cwd)}\n".encode())
    except (subprocess.CalledProcessError, OSError):
        return None
    return digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workflow", required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--commit", default="HEAD")
    args = parser.parse_args(argv)
    found = key(args.workflow, args.job, args.commit)
    if found is None:
        print(f"paths_tree_key: no key for {args.workflow} {args.job}: the job runs", file=sys.stderr)
        return 0
    print(found)
    return 0


if __name__ == "__main__":
    sys.exit(main())
