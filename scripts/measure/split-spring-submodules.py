#!/usr/bin/env python3
"""Populate exact Ghostty gitlinks from a reusable shallow mirror, without alternates.

The fleet supplies CI_SHARED_CACHE_DIR; ephemeral runners restore this directory
with actions/cache. Only missing pins contact the upstream. Each URL has its own
locked mirror; a local clone copies its objects so later cache eviction is safe.
"""

import argparse
import fcntl
import hashlib
from pathlib import Path
import subprocess


def git(*args, cwd=None, capture=False):
    return subprocess.run(
        ["git", *map(str, args)], cwd=cwd, check=True, text=True,
        stdout=subprocess.PIPE if capture else None,
    ).stdout


def has_commit(repo, sha):
    return subprocess.run(
        ["git", "-C", str(repo), "cat-file", "-e", f"{sha}^{{commit}}"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode == 0


def prepare(cache, sub):
    # This helper accepts only a gitlink declared by the superproject.
    entry = git("ls-tree", "HEAD", "--", sub, capture=True).split()
    if len(entry) != 4 or entry[0:2] != ["160000", "commit"] or entry[3] != sub:
        raise ValueError(f"not a gitlink: {sub}")
    pin = entry[2]
    git("submodule", "sync", "--", sub)
    git("submodule", "init", "--", sub)
    # init resolves relative URLs against the superproject's origin.
    url = git("config", "--get", f"submodule.{sub}.url", capture=True).strip()
    mirror = cache / hashlib.sha256(url.encode()).hexdigest()
    with mirror.with_suffix(".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not (mirror / "HEAD").exists():
            git("init", "--bare", mirror)
        if not has_commit(mirror, pin):
            print(f"split-spring: fetching {sub} {pin} into warm mirror", flush=True)
            git("-C", mirror, "fetch", "--depth=1", "--no-tags", url,
                f"{pin}:refs/heads/pin-{pin}")
        # A shallow mirror cannot serve as --reference. A local clone copies
        # only the cached objects and never needs the remote's history.
        git("-C", mirror, "update-ref", f"refs/heads/pin-{pin}", pin)
        git("-C", mirror, "symbolic-ref", "HEAD", f"refs/heads/pin-{pin}")
        if not (Path(sub) / ".git").exists():
            git("clone", "--no-checkout", "--no-hardlinks", mirror, sub)
            git("-C", sub, "remote", "set-url", "origin", url)
            git("submodule", "absorbgitdirs", "--", sub)
        elif not has_commit(sub, pin):
            git("-C", sub, "fetch", "--update-shallow", mirror, pin)
        # Also materialize a clone interrupted before its first checkout:
        # submodule update alone sees matching HEAD and leaves it empty.
        git("-C", sub, "checkout", "--detach", pin)
        git("submodule", "update", "--init", "--checkout", "--", sub)
        actual = git("-C", sub, "rev-parse", "HEAD", capture=True).strip()
        if actual != pin:
            raise RuntimeError(f"{sub}: expected {pin}, got {actual}")
        print(f"split-spring: {sub} ready at {pin}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cache", required=True, type=Path)
    parser.add_argument("submodules", nargs="+")
    args = parser.parse_args()
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    for sub in args.submodules:
        prepare(cache, sub)


if __name__ == "__main__":
    main()
