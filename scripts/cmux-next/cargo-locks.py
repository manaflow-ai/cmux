#!/usr/bin/env python3
"""Every tracked Cargo.lock matches its workspace's manifests; `fix` regenerates the ones that do not.

The repository has many Cargo workspaces, each with its own Cargo.lock, and they share crates through path
dependencies: cmux-tui/crates/cmux-app-ffi and cmux-layout-reducer-ffi build cmux-tui's crates in workspaces of
their own. A manifest change in one workspace can leave another workspace's lock stale, and every `--locked`
cargo step there stops with "cannot update the lock file". 2026-11-10: eb4f3eb1d94 turned on rusqlite's `cache`
feature in cmux-tui/Cargo.toml and updated cmux-tui/Cargo.lock only; it was a direct push, so no pull request
check ran, and every feat-cmux-next pull request went red on the app FFI build until #40883. Its revert
(5af8bd4e61b) repeated it the other way round (#40898). A check that reads only the workspace the change is in
cannot see this; this one reads every tracked lock, whatever changed.

check   For each tracked Cargo.lock, `cargo update --workspace --locked` in its directory (offline first, then
        with the network): it resolves from the registry index alone, downloads no crate and builds nothing (all
        30 workspaces in about 4 s on a CI runner). Prints `stale: DIR/Cargo.lock: ...` for each lock cargo would have
        to rewrite and exits 1 when there is one. A workspace cargo could not judge (no cargo, a network error,
        a timeout) prints `unchecked: DIR (...)` and does not fail, unless --strict.
fix     The same check, then `cargo update --workspace` in each stale workspace: it rewrites only what the
        manifests now need (the workspace's own entries and new or dropped dependencies; no other version
        moves). Prints `fixed: ...` or `left: ...` lines (scripts/cmux-next/base-autofix.sh's format) and exits 0.
        Only Cargo.lock files are written: a run that would touch anything else is undone and reported.

Every workspace runs on one toolchain (RUSTUP_TOOLCHAIN, else the one active at the repository root, with no
toolchain installs): a lock's consistency does not depend on the toolchain, and a pinned toolchain the host
lacks would otherwise leave that workspace unchecked.

Callers: the pre-push gate (prepush-gate.py, CARGO_LOCK_CHECK) on any push that changes a Cargo.toml or
Cargo.lock; rust-workspaces.yml's plan job on every pull request and push, with --strict (CI is the backstop: an
unchecked workspace is red there); the base autofix (base-autofix.sh --locks) after a feat-cmux-next push that does.

Usage: scripts/cmux-next/cargo-locks.py check|fix [--repo DIR] [--strict] [--jobs N]
"""
from __future__ import annotations

import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Both of cargo's spellings of a stale lock under --locked (check-cargo-locks.py STALE reads the same two).
DRIFT = "cannot update the lock file"
STALE = re.compile(r"cannot (?:update|create) the lock file .* because --locked was passed"
                   r"|the lock file .* needs to be updated but --locked was passed")
TIMEOUT = 120


def tracked_roots(repo: Path) -> list[str]:
    """Repository-relative directories of the tracked Cargo.lock files that sit beside a Cargo.toml ('' for the root)."""
    out = subprocess.run(["git", "-C", str(repo), "ls-files", "-z", "--", "*Cargo.lock"],
                         capture_output=True, check=True).stdout.decode()
    roots = []
    for path in out.split("\0"):
        if path.rpartition("/")[2] != "Cargo.lock":
            continue
        root = path.rpartition("/")[0]
        if (repo / root / "Cargo.toml").is_file():
            roots.append(root)
    return sorted(roots)


def cargo_env(repo: Path) -> dict[str, str]:
    env = {**os.environ, "RUSTUP_AUTO_INSTALL": "0", "CARGO_TERM_COLOR": "never", "CARGO_NET_RETRY": "2"}
    if not env.get("RUSTUP_TOOLCHAIN") and shutil.which("rustup"):
        try:
            active = subprocess.run(["rustup", "show", "active-toolchain"], cwd=repo, env=env, text=True,
                                    capture_output=True, timeout=30).stdout.split()
        except (OSError, subprocess.TimeoutExpired):
            active = []
        if active:
            env["RUSTUP_TOOLCHAIN"] = active[0]
    return env


def cargo(args: list[str], cwd: Path, env: dict[str, str]) -> tuple[int, str]:
    try:
        run = subprocess.run(["cargo", *args], cwd=cwd, env=env, text=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {TIMEOUT}s"
    except OSError as error:
        return 127, str(error)
    return run.returncode, run.stderr


def judge(repo: Path, root: str, env: dict[str, str]) -> tuple[str, str]:
    """('ok' | 'stale' | 'unchecked', detail) for the workspace at ROOT."""
    last = ""
    for network in (["--offline"], []):
        code, err = cargo(["update", "--workspace", "--locked", *network], repo / root, env)
        if code == 0:
            return "ok", ""
        if DRIFT in err or STALE.search(err):
            return "stale", ""
        last = err.strip().splitlines()[-1] if err.strip() else f"exit {code}"
    return "unchecked", last


def label(root: str) -> str:
    return root or "."


def check(repo: Path, jobs: int) -> dict[str, tuple[str, str]]:
    if shutil.which("cargo") is None:
        return {root: ("unchecked", "no cargo on PATH") for root in tracked_roots(repo)}
    env = cargo_env(repo)
    roots = tracked_roots(repo)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        verdicts = list(pool.map(lambda root: judge(repo, root, env), roots))
    return dict(zip(roots, verdicts))


def changed(repo: Path) -> set[str]:
    out = subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "-z", "--untracked-files=all"],
                         capture_output=True, check=True).stdout.decode()
    return {entry[3:] for entry in out.split("\0") if len(entry) > 3}


def fix(repo: Path, results: dict[str, tuple[str, str]]) -> list[str]:
    lines = []
    stale = [root for root, (verdict, _) in results.items() if verdict == "stale"]
    if not stale:
        return lines
    env = cargo_env(repo)
    before = changed(repo)
    for root in stale:
        lock = f"{root}/Cargo.lock" if root else "Cargo.lock"
        done = False
        for network in (["--offline"], []):
            code, _ = cargo(["update", "--workspace", *network], repo / root, env)
            if code == 0 and judge(repo, root, env)[0] == "ok":
                done = True
                break
        lines.append(f"fixed: {lock} (cargo update --workspace in {label(root)})" if done
                     else f"left: {lock} is stale and cargo update --workspace could not rewrite it (run it there by hand)")
    stray = sorted(p for p in changed(repo) - before if p.rpartition("/")[2] != "Cargo.lock")
    if stray:
        subprocess.run(["git", "-C", str(repo), "checkout", "--", *stray], capture_output=True)
        subprocess.run(["git", "-C", str(repo), "clean", "-fdq", "--", *stray], capture_output=True)
        lines.append("left: cargo update touched files other than Cargo.lock (undone): " + ", ".join(stray))
    return lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=("check", "fix"))
    parser.add_argument("--repo", default=".", help="the repository's top directory (default: .)")
    parser.add_argument("--strict", action="store_true", help="a workspace cargo could not judge fails the check")
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve()

    results = check(repo, args.jobs)
    stale = [root for root, (verdict, _) in results.items() if verdict == "stale"]
    unchecked = {root: detail for root, (verdict, detail) in results.items() if verdict == "unchecked"}
    for root, detail in sorted(unchecked.items()):
        print(f"unchecked: {label(root)} ({detail})")
    if args.mode == "fix":
        for line in fix(repo, results):
            print(line)
        return 0
    for root in stale:
        print(f"stale: {root + '/' if root else ''}Cargo.lock: does not match its manifests (cargo update --workspace "
              f"--locked: {DRIFT})")
    print(f"cargo-locks: {len(results)} workspaces, {len(stale)} stale, {len(unchecked)} unchecked", file=sys.stderr)
    if stale:
        return 1
    return 2 if args.strict and unchecked else 0


if __name__ == "__main__":
    sys.exit(main())
