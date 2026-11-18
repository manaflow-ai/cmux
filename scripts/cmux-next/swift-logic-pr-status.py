#!/usr/bin/env python3
"""A pull request's own Swift logic growth, as the `swift-logic` section of its status comment (scripts/ci/pr_status.py).

Goal swift-share-falls (Lawrence 2026-11-02: "move as much from swift into rust as possible"; Leo 2026-11-07: "swift to
anything but swift"): every pull request that touches a *.swift file sees what it adds to swift-logic-lines.py's count,
next to its other status lines. It is a report, never a gate: it exits 0 on growth and when it cannot count (the section
then says "not counted" and why).

  python3 -I scripts/cmux-next/swift-logic-pr-status.py --url URL --base-ref feat-cmux-next --head SHA \
      --work DIR --out FILE

It needs no checkout of the pull request and runs none of its code. In DIR it fetches from URL (git, no API call):
  1. history.git: commits only (--filter=tree:0) of BASE-REF and HEAD, back 14 days and then 90 if that holds no
     merge base; BASE is their merge base (swift-logic-delta.py's docstring: the pull request's own share, not what
     landed on the base branch since it forked).
  2. objects.git: BASE and HEAD at depth 1 without blobs, then every *.swift blob of the two trees in one fetch.
Then swift-logic-delta.py's --status text of BASE..HEAD goes to FILE. FILE is left empty when the pull request changes
no *.swift file (the workflow clears the section). The facts cache lives in objects.git/cmux-arch-counts (the workflow
keeps it per pull request, so a later push reads only the Swift files it changed).

Tests: scripts/cmux-next/tests/test_swift_logic_lines.py (SwiftLogicPrStatusTests).
"""

from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HISTORY_DAYS = (14, 90)
FETCH_TIMEOUT = 300


def load_delta():
    name = "cmux_next_swift_logic_delta"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, HERE / "swift-logic-delta.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class NotCounted(Exception):
    pass


def git(repo: Path, *args: str, stdin: str | None = None) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], input=stdin, capture_output=True, text=True,
                          timeout=FETCH_TIMEOUT)
    if done.returncode:
        raise NotCounted(f"git {args[0]} failed: {(done.stderr or done.stdout).strip()[-200:]}")
    return done.stdout


def partial_repo(path: Path, url: str) -> Path:
    git(path.parent, "init", "-q", "--bare", str(path))
    git(path, "remote", "add", "origin", url)
    return path


def merge_base(work: Path, url: str, base_ref: str, head: str) -> str:
    history = partial_repo(work / "history.git", url)
    for days in HISTORY_DAYS:
        git(history, "fetch", "-q", "--no-tags", "--filter=tree:0", f"--shallow-since={days} days ago", "origin",
            f"+refs/heads/{base_ref}:refs/base", f"+{head}:refs/head")
        found = subprocess.run(["git", "-C", str(history), "merge-base", "refs/base", "refs/head"],
                               capture_output=True, text=True)
        if found.returncode == 0 and found.stdout.strip():
            return found.stdout.strip()
    raise NotCounted(f"no merge base of {head[:7]} and {base_ref} in the last {HISTORY_DAYS[-1]} days")


def swift_trees(work: Path, url: str, base: str, head: str) -> tuple[Path, list[str]]:
    """objects.git with BASE's and HEAD's trees and their Swift blobs; the *.swift paths the change touches."""
    objects = partial_repo(work / "objects.git", url)
    git(objects, "fetch", "-q", "--no-tags", "--depth=1", "--filter=blob:none", "origin", base, head)
    touched = git(objects, "diff", "--no-renames", "--name-only", base, head, "--", "*.swift").split()
    if touched:
        blobs = set()
        for rev in (base, head):
            for entry in git(objects, "ls-tree", "-r", "-z", rev).split("\0"):
                meta, _, path = entry.partition("\t")
                fields = meta.split()
                if path.endswith(".swift") and len(fields) == 3 and fields[1] == "blob":
                    blobs.add(fields[2])
        # One fetch of every Swift blob: the count's `cat-file --batch` would fetch each missing one on its own.
        git(objects, "-c", "fetch.negotiationAlgorithm=noop", "fetch", "-q", "--no-tags", "--no-write-fetch-head",
            "--filter=blob:none", "--stdin", "origin", stdin="".join(f"{b}\n" for b in sorted(blobs)))
    return objects, touched


def section(url: str, base_ref: str, head: str, work: Path, top: int = 15) -> str:
    """The section text ("" when the change touches no *.swift file)."""
    work.mkdir(parents=True, exist_ok=True)
    delta = load_delta()
    try:
        base = merge_base(work, url, base_ref, head)
        objects, touched = swift_trees(work, url, base, head)
    except (NotCounted, OSError, subprocess.SubprocessError) as error:
        return delta.not_counted(str(error))
    if not touched:
        return ""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        delta.main(["--repo", str(objects), "--base", base, "--head", head, "--top", str(top), "--status"])
    return out.getvalue()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--url", required=True, help="the repository to fetch from")
    parser.add_argument("--base-ref", required=True, help="the pull request's base branch")
    parser.add_argument("--head", required=True, help="the pull request's head commit")
    parser.add_argument("--work", type=Path, required=True, help="a directory for the two fetched repositories")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--top", type=int, default=15)
    args = parser.parse_args(argv)
    try:
        text = section(args.url, args.base_ref, args.head, args.work, args.top)
    except Exception as error:  # noqa: BLE001 - a report never fails its job
        text = load_delta().not_counted(f"{type(error).__name__}: {error}")
    args.out.write_text(text)
    print(text or "swift-logic: no *.swift file changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
