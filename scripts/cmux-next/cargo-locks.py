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

check   For each tracked Cargo.lock, `cargo update --workspace --locked` in its directory: it resolves from the
        registry index alone, downloads no crate and builds nothing (all 30 workspaces in about 4 s on a CI runner
        with a warm index). Every workspace first resolves offline, in parallel; the ones the cached index cannot
        answer then resolve with the network one at a time (touched workspaces first), since cargo holds its
        package cache lock for a whole resolve and parallel resolves only queue on it. Prints `stale: DIR/Cargo.lock:
        ...` for each lock cargo would have to rewrite and exits 1 when there is one. A workspace cargo could not
        judge (no cargo, a network error, a timeout) prints `unchecked: DIR (...)` and does not fail, unless --strict.
        Under --strict a timed-out workspace is retried once with a longer limit; if it still times out it fails
        only when the change touches it (--base: a Cargo.toml or Cargo.lock in it or in a package it reaches by
        path; with no --base every workspace counts as touched), and otherwise prints a `warning:` line. A busy
        runner makes the check slower, never red: cmux#41586, run 43124136001, 2026-11-12, 30 workspaces, 0 stale,
        5 timed out after 120 s waiting on each other on a 2-vCPU runner with an empty cargo home.
fix     The same check, then `cargo update --workspace` in each stale workspace: it rewrites only what the
        manifests now need (the workspace's own entries and new or dropped dependencies; no other version
        moves). Prints `fixed: ...` or `left: ...` lines (scripts/cmux-next/base-autofix.sh's format) and exits 0.
        Only Cargo.lock files are written: a run that would touch anything else is undone and reported.

Every workspace runs on one toolchain (RUSTUP_TOOLCHAIN, else the one active at the repository root, with no
toolchain installs): a lock's consistency does not depend on the toolchain, and a pinned toolchain the host
lacks would otherwise leave that workspace unchecked.

Callers: the pre-push gate (prepush-gate.py, CARGO_LOCK_CHECK) on any push that changes a Cargo.toml or
Cargo.lock; rust-workspaces.yml's plan job on every pull request and push, with --strict and --base (CI is the
backstop: an unchecked workspace is red there, a timeout only in a workspace the change touches); the base autofix
(base-autofix.sh --locks) after a feat-cmux-next push that does.

Usage: scripts/cmux-next/cargo-locks.py check|fix [--repo DIR] [--strict] [--base SHA] [--jobs N]
"""
from __future__ import annotations

import argparse
import concurrent.futures
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath

# Both of cargo's spellings of a stale lock under --locked (check-cargo-locks.py STALE reads the same two).
DRIFT = "cannot update the lock file"
STALE = re.compile(r"cannot (?:update|create) the lock file .* because --locked was passed"
                   r"|the lock file .* needs to be updated but --locked was passed")
TIMEOUT = 120
# --strict: a timed-out workspace's second try.
RETRY_TIMEOUT = 300
# Seconds the network pass and the retries may spend on workspaces the change does not touch; past it they are not
# started (and only warn). Touched workspaces always run to their limits.
BUDGET = 300
# cargo's line while another cargo holds the package cache lock.
LOCK_WAIT = "Blocking waiting for file lock on package cache"


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


def cargo(args: list[str], cwd: Path, env: dict[str, str], timeout: float = TIMEOUT) -> tuple[int, str]:
    try:
        run = subprocess.run(["cargo", *args], cwd=cwd, env=env, text=True, stdin=subprocess.DEVNULL,
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired as expired:
        err = expired.stderr.decode(errors="replace") if isinstance(expired.stderr, bytes) else expired.stderr or ""
        waited = ", waiting on cargo's package cache lock" if LOCK_WAIT in err else ""
        return 124, f"timed out after {timeout:g}s{waited}"
    except OSError as error:
        return 127, str(error)
    return run.returncode, run.stderr


def judge(repo: Path, root: str, env: dict[str, str], passes: tuple[list[str], ...] = (["--offline"], []),
          timeout: float = TIMEOUT) -> tuple[str, str]:
    """('ok' | 'stale' | 'unchecked' | 'timeout', detail) for the workspace at ROOT."""
    verdict, last = "unchecked", ""
    for network in passes:
        code, err = cargo(["update", "--workspace", "--locked", *network], repo / root, env, timeout=timeout)
        if code == 0:
            return "ok", ""
        if DRIFT in err or STALE.search(err):
            return "stale", ""
        verdict = "timeout" if code == 124 else "unchecked"
        last = err.strip().splitlines()[-1] if err.strip() else f"exit {code}"
    return verdict, last


def label(root: str) -> str:
    return root or "."


def check(repo: Path, jobs: int, strict: bool = False, touched: set[str] | None = None) -> dict[str, tuple[str, str]]:
    """Every workspace's verdict. TOUCHED: the workspaces the change touches (None: all of them)."""
    if shutil.which("cargo") is None:
        return {root: ("unchecked", "no cargo on PATH") for root in tracked_roots(repo)}
    started = time.monotonic()
    env = cargo_env(repo)
    roots = tracked_roots(repo)
    is_touched = (lambda root: True) if touched is None else (lambda root: root in touched)

    def over_budget(root: str) -> bool:
        return not is_touched(root) and time.monotonic() - started > BUDGET

    # Offline, in parallel: from the cached index alone, each resolve holds cargo's lock only briefly.
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        verdicts = list(pool.map(lambda root: judge(repo, root, env, passes=(["--offline"],)), roots))
    results = dict(zip(roots, verdicts))
    # With the network, one at a time: cargo holds the package cache lock for a whole resolve, so parallel resolves
    # queue on it and the queue counts against each one's limit. The index entries one fetches serve the next.
    pending = sorted((root for root, (verdict, _) in results.items() if verdict in ("unchecked", "timeout")),
                     key=lambda root: (not is_touched(root), root))
    for root in pending:
        if over_budget(root):
            results[root] = ("timeout", f"not started: the {BUDGET}s budget for untouched workspaces was spent")
            continue
        results[root] = judge(repo, root, env, passes=([],))
    if strict:
        for root in pending:
            verdict, first = results[root]
            if verdict != "timeout" or over_budget(root):
                continue
            verdict, detail = judge(repo, root, env, passes=([],), timeout=RETRY_TIMEOUT)
            results[root] = (verdict, f"{first}; then {detail}" if verdict == "timeout" else detail)
    return results


DEPENDENCY_KEYS = ("dependencies", "dev-dependencies", "build-dependencies", "patch", "replace")


def path_specs(table: object, in_dependencies: bool = False) -> list[str]:
    """Every `path = "..."` a manifest table names as a dependency (not [lib] or [[bin]] paths)."""
    found: list[str] = []
    if isinstance(table, dict):
        if in_dependencies and isinstance(table.get("path"), str):
            found.append(table["path"])
        for key, value in table.items():
            found += path_specs(value, in_dependencies or key in DEPENDENCY_KEYS)
    elif isinstance(table, list):
        for value in table:
            found += path_specs(value, in_dependencies)
    return found


def touched_roots(repo: Path, roots: list[str], base: str) -> set[str] | None:
    """The workspaces whose lock the change since BASE can reach: a Cargo.toml or Cargo.lock under the workspace, in
    a package it reaches by path, or a workspace manifest above one of those. None (all of them) with no usable base.
    An over-count only keeps a workspace strict."""
    if not base or set(base) == {"0"}:
        return None
    try:
        subprocess.run(["git", "-C", str(repo), "cat-file", "-e", f"{base}^{{commit}}"], check=True,
                       capture_output=True)
        out = subprocess.run(["git", "-C", str(repo), "diff", "--name-only", "--no-renames", "-z", base, "HEAD"],
                             capture_output=True, check=True).stdout.decode("utf-8", "surrogateescape")
    except subprocess.CalledProcessError:
        print(f"cargo-locks: base {base} is not in this checkout; every workspace counts as touched", file=sys.stderr)
        return None
    cargo_files = [path for path in out.split("\0") if PurePosixPath(path).name in ("Cargo.toml", "Cargo.lock")]
    if not cargo_files:
        return set()
    import tomllib  # Python 3.11; only CI passes --base

    listed = subprocess.run(["git", "-C", str(repo), "ls-files", "-z", "--", "*Cargo.toml"], capture_output=True,
                            check=True).stdout.decode("utf-8", "surrogateescape")
    manifests: dict[str, dict] = {}
    for path in listed.split("\0"):
        if PurePosixPath(path).name == "Cargo.toml" and (repo / path).is_file():
            try:
                manifests[str(PurePosixPath(path).parent)] = tomllib.loads((repo / path).read_text(encoding="utf-8"))
            except (tomllib.TOMLDecodeError, UnicodeDecodeError):
                manifests[str(PurePosixPath(path).parent)] = {}

    def under(path: str, directory: str) -> bool:
        return directory in ("", ".") or path == directory or path.startswith(directory + "/")

    def reach(root: str) -> set[str]:
        seen = {root or "."}
        queue = [directory for directory in manifests if under(directory, root)]
        while queue:
            directory = queue.pop()
            for spec in path_specs(manifests.get(directory, {})):
                target = os.path.normpath(str(PurePosixPath(directory) / spec))
                if target.startswith("..") or any(under(target, known) for known in seen):
                    continue
                seen.add(target)
                queue += [other for other in manifests if under(other, target)]
                # A package that inherits from its own workspace reads that workspace's manifest.
                seen |= {str(parent) for parent in PurePosixPath(target).parents
                         if "workspace" in manifests.get(str(parent), {})}
        return seen

    found = set()
    for root in roots:
        watched = reach(root)
        if any(under(str(PurePosixPath(path).parent), directory) for path in cargo_files for directory in watched):
            found.add(root)
    return found


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
    parser.add_argument("--base", default="", help="the change's base commit: under --strict, a timed-out "
                        "workspace the change does not touch only warns")
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args(argv)
    repo = Path(args.repo).resolve()

    touched = touched_roots(repo, tracked_roots(repo), args.base) if args.mode == "check" and args.strict else None
    results = check(repo, args.jobs, strict=args.strict and args.mode == "check", touched=touched)
    stale = [root for root, (verdict, _) in results.items() if verdict == "stale"]
    unchecked = {root: (verdict, detail) for root, (verdict, detail) in results.items()
                 if verdict in ("unchecked", "timeout")}
    # A busy runner makes the check slower, never red: a timeout in a workspace the change does not touch warns.
    excused = {root for root, (verdict, _) in unchecked.items()
               if verdict == "timeout" and touched is not None and root not in touched}
    for root, (_, detail) in sorted(unchecked.items()):
        print(f"unchecked: {label(root)} ({detail})")
    prefix = "::warning::" if os.environ.get("GITHUB_ACTIONS") == "true" else "warning: "
    for root in sorted(excused):
        print(f"{prefix}cargo-locks: {label(root)} timed out on this runner and is not checked; this change touches "
              "no manifest or lock it reads, so it does not fail the check")
    if args.mode == "fix":
        for line in fix(repo, results):
            print(line)
        return 0
    for root in stale:
        print(f"stale: {root + '/' if root else ''}Cargo.lock: does not match its manifests (cargo update --workspace "
              f"--locked: {DRIFT})")
    print(f"cargo-locks: {len(results)} workspaces, {len(stale)} stale, {len(unchecked)} unchecked"
          f"{f' ({len(excused)} untouched, warned)' if excused else ''}", file=sys.stderr)
    if stale:
        return 1
    return 2 if args.strict and set(unchecked) - excused else 0


if __name__ == "__main__":
    sys.exit(main())
