#!/usr/bin/env python3
"""Run cmuxterm-hq's private_names.py check-pr with the pull request's file contents read from a local git
object store instead of one REST `contents` read per changed file.

usage: private_names_local.py CHECKER.py GIT_DIR HEAD_SHA OWNER/REPO N

private-names.yml fetches the head commit over git (not the REST API, so it costs no REST quota) into GIT_DIR.
The checker's `get(path, token, raw)` hook is wrapped here: a `contents/PATH?ref=HEAD_SHA` raw read is answered
from `git cat-file`, everything else (the pull request's file list, its patches) goes to the checker's own
retrying `_get`. A blob git does not have falls back to the REST read, so the check never gets weaker. Reads
that went to REST are counted and printed (`private-names: REST reads: N, from git: M`), so the cost shows in the log.
"""
from __future__ import annotations

import importlib.util
import subprocess
import sys
import urllib.parse
from pathlib import Path

REST_READS = 0
GIT_READS = 0


def load(path: str):
    spec = importlib.util.spec_from_file_location("private_names", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def prefetch(git_dir: str, sha: str, paths: list[str]) -> None:
    """One batched blob fetch for every changed path (a promisor clone would fetch them one by one)."""
    if not paths:
        return
    try:
        tree = subprocess.run(["git", "-C", git_dir, "ls-tree", "-r", "-z", "--format=%(objecttype) %(objectname)\t%(path)",
                               sha, "--", *paths], capture_output=True, text=True, timeout=120, check=True).stdout
    except (subprocess.SubprocessError, OSError):
        return
    oids = [row.split("\t", 1)[0].split(" ")[1] for row in tree.split("\0") if row.startswith("blob ")]
    if not oids:
        return
    subprocess.run(["git", "-C", git_dir, "-c", "fetch.negotiationAlgorithm=noop", "fetch", "--quiet", "--no-tags",
                    "--no-write-fetch-head", "--recurse-submodules=no", "--filter=blob:none", "--stdin", "origin"],
                   input="\n".join(oids) + "\n", text=True, capture_output=True, timeout=300, check=False)


def local_blob(git_dir: str, sha: str, path: str) -> bytes | None:
    try:
        done = subprocess.run(["git", "-C", git_dir, "cat-file", "blob", f"{sha}:{path}"], capture_output=True,
                              timeout=60, check=True)
    except (subprocess.SubprocessError, OSError):
        return None
    return done.stdout


def main(argv: list[str]) -> int:
    global REST_READS, GIT_READS
    if len(argv) != 5:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    checker, git_dir, sha, repo, number = argv
    pn = load(checker)
    real_get = pn._get

    def get(path: str, token: str, raw: bool = False, **kwargs):
        global REST_READS, GIT_READS
        parsed = urllib.parse.urlsplit(path)
        marker = "/contents/"
        if raw and marker in parsed.path and urllib.parse.parse_qs(parsed.query).get("ref") == [sha]:
            blob = local_blob(git_dir, sha, urllib.parse.unquote(parsed.path.split(marker, 1)[1]))
            if blob is not None:
                GIT_READS += 1
                return blob
        REST_READS += 1
        result = real_get(path, token, raw, **kwargs)
        if parsed.path.endswith(f"/pulls/{number}/files") and isinstance(result, list):
            prefetch(git_dir, sha, [f["filename"] for f in result if f.get("status") != "removed"])
        return result

    pn._get = get
    code = pn.main(["check-pr", repo, number])
    print(f"private-names: REST reads: {REST_READS}, from git: {GIT_READS}")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
