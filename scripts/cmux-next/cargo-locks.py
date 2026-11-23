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
        5 timed out after 120 s waiting on each other on a 2-vCPU runner with an empty cargo home. A workspace's
        tree stops at a Cargo.toml below it with a [workspace] of its own or in its `exclude`: that is another
        workspace, so a change only there does not touch the outer one (cmux#41742 review F1). A package reached by
        path brings its `{ workspace = true }` dependencies' paths from its own workspace's [workspace.dependencies]
        (cmux#41767 review: cmux-next-ios/rust reaches cmux-tui crates, which inherit paths from cmux-tui).
        The whole check ends by --deadline seconds (default with no usable --base: NO_BASE_DEADLINE): past it no
        resolve starts, a running one is cut at it, and what is left is `unchecked` (a timeout). Every caller
        without a base has an outer limit of its own: the pre-push gate's (it passes --deadline below it), the
        base autofix job's, CI's job's (cmux#41742 review F2: with no base there was no budget at all, serial
        resolves ran past the gate's limit, and the gate then skipped the lock check).
fix     The same check, then `cargo update --workspace` in each stale workspace: it rewrites only what the
        manifests now need (the workspace's own entries and new or dropped dependencies; no other version
        moves). Prints `fixed: ...` or `left: ...` lines (scripts/cmux-next/base-autofix.sh's format) and exits 0.
        The deadline is one absolute time for the whole run: the rewrites and their re-checks stop at it too, and
        a lock they did not reach is `left:` (cmux#41767 review F3: `fix --deadline 1.1` ran 1.44 s).
        Only Cargo.lock files are written: a run that would touch anything else is undone and reported.

Every workspace runs on one toolchain (RUSTUP_TOOLCHAIN, else the one active at the repository root, with no
toolchain installs): a lock's consistency does not depend on the toolchain, and a pinned toolchain the host
lacks would otherwise leave that workspace unchecked.

explain FILE|-   Reads a log (FILE, or stdin with `-`) of a cargo run that failed. When it holds cargo's refusal of a stale
        lock under --locked (any of the three spellings below), prints one cause-and-fix block on stderr (the lock,
        repository-relative when it is in the repository; the repair; that a rerun does not help), plus a GitHub
        `::error title=stale Cargo.lock::` line on stdout under GITHUB_ACTIONS, and exits 0. Otherwise (no refusal,
        an empty log, a missing or unreadable file) it prints nothing and exits 1. Every CI wrapper that runs cargo
        with --locked and prints a cause of its own on failure asks this first, so the reader of a red check sees
        the stale lock and not a lint, a build break or a test failure that did not happen (2026-11-12: a pull
        request went red on 15 checks for one stale lock; the clippy job said "fix each lint", the author reran
        twice and stopped). The log is read line by line: a multi-megabyte log never backtracks.

Callers: the pre-push gate (prepush-gate.py, CARGO_LOCK_CHECK) on any push that changes a Cargo.toml or
Cargo.lock; rust-workspaces.yml's plan job on every pull request and push, with --strict and --base (CI is the
backstop: an unchecked workspace is red there, a timeout only in a workspace the change touches); the base autofix
(base-autofix.sh --locks) after a feat-cmux-next push that does.

Usage: scripts/cmux-next/cargo-locks.py check|fix [--repo DIR] [--strict] [--base SHA] [--deadline S] [--jobs N]
       scripts/cmux-next/cargo-locks.py explain FILE|- [--repo DIR]
"""
from __future__ import annotations

import argparse
import concurrent.futures
import fnmatch
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path, PurePosixPath

# Both of cargo's spellings of a stale lock under --locked.
DRIFT = "cannot update the lock file"
STALE = re.compile(r"cannot (?:update|create) the lock file .* because --locked was passed"
                   r"|the lock file .* needs to be updated but --locked was passed")
TIMEOUT = 120
# --strict: a timed-out workspace's second try.
RETRY_TIMEOUT = 300
# Seconds the network pass and the retries may spend on workspaces the change does not touch; past it they are not
# started (and only warn). Touched workspaces always run to their limits.
BUDGET = 300
# Seconds the whole check may take when there is no usable --base and no --deadline: below the pre-push gate's own
# limit on it (prepush-gate.py CARGO_LOCKS_TIMEOUT), the base autofix job's and CI's.
NO_BASE_DEADLINE = 240
# The clock the budget and the deadline read (tests replace it).
clock = time.monotonic
# cargo's line while another cargo holds the package cache lock.
LOCK_WAIT = "Blocking waiting for file lock on package cache"
# explain: the same three spellings, with the lock's path (which can hold spaces). Only a line that holds
# REFUSED is matched against it, and one line at a time.
REFUSED = "--locked was passed"
NAMES_LOCK = "the lock file "
# What stands between the lock's path and REFUSED, and what must stand before NAMES_LOCK (None: anything).
REFUSAL_ENDS = ((" because ", ("cannot update ", "cannot create ")), (" needs to be updated but ", None))
# Characters a lock's path can span: up to PATH_MAX.
REFUSAL_WINDOW = 4200


def refused_lock(line: str) -> str | None:
    """The lock's path in the first of cargo's refusals LINE holds, else None. Each REFUSED is judged against the
    NAMES_LOCK nearest before it, and both are found in one pass, so one long line (a progress bar, a minified dump,
    the same words a million times) costs its length, not its length times a window."""
    named, ahead = -1, line.find(NAMES_LOCK)
    at = line.find(REFUSED)
    while at != -1:
        while ahead != -1 and ahead < at:
            named, ahead = ahead, line.find(NAMES_LOCK, ahead + 1)
        start = named + len(NAMES_LOCK)
        if named != -1 and at - start <= REFUSAL_WINDOW:
            for end, before in REFUSAL_ENDS:
                if (at - len(end) > start and line.endswith(end, start, at)
                        and (before is None or line.endswith(before, 0, named))):
                    return line[start:at - len(end)]
        at = line.find(REFUSED, at + 1)
    return None


def refused_locks(lines, repo: Path) -> list[str]:
    """The lock files cargo refused to write under --locked in LINES, in order, repository-relative when inside
    REPO."""
    found: list[str] = []
    for line in lines:
        raw = refused_lock(line)
        if raw is None:
            continue
        raw = raw.strip().strip("`'\"")
        try:
            lock = Path(raw).resolve().relative_to(repo.resolve()).as_posix()
        except (ValueError, OSError):
            lock = raw
        if lock not in found:
            found.append(lock)
    return found


def explain(source: str, repo: Path) -> int:
    """0 and the cause-and-fix block when the log at SOURCE (`-`: stdin) holds cargo's stale-lock refusal, else 1
    and nothing."""
    try:
        if source == "-":
            import io
            locks = refused_locks(io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace"), repo)
        else:
            with open(source, encoding="utf-8", errors="replace") as handle:
                locks = refused_locks(handle, repo)
    except OSError:
        return 1
    if not locks:
        return 1
    named = ", ".join(locks)
    verb = "does not match its" if len(locks) == 1 else "do not match their"
    cause = (f"{named} {verb} manifests on this ref, often because the base changed a dependency "
             "after the branch was cut, so cargo --locked stopped before building or testing anything")
    steps = ("merge the base branch into the branch",
             "run `scripts/cmux-next/cargo-locks.py fix` from the repository root",
             "commit the Cargo.lock files it changed")
    block = [f"stale Cargo.lock: {cause}.", "Fix:"]
    block += [f"  {n}. {step}" for n, step in enumerate(steps, 1)]
    block.append("A rerun does not help.")
    sys.stdout.flush()
    print("\n".join(block), file=sys.stderr, flush=True)
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::error title=stale Cargo.lock::{cause}. Fix: {'; '.join(steps)}. A rerun does not help.", flush=True)
    return 0


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
    """cargo's exit code and stderr; 124 past TIMEOUT, when cargo and everything it started (git, a registry
    fetch) are stopped as one process group, so nothing of it outlives the limit or the deadline: SIGTERM, a
    grace period, then SIGKILL to the group whether or not cargo itself has exited, since a child that ignores
    SIGTERM and has closed stderr would otherwise outlive it unseen."""
    try:
        process = subprocess.Popen(["cargo", *args], cwd=cwd, env=env, text=True, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
    except OSError as error:
        return 127, str(error)
    try:
        _, err = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        err = ""
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            _, err = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            _, rest = process.communicate(timeout=5)
            err = (err or "") + (rest or "")
        except (subprocess.TimeoutExpired, ValueError):
            pass
        # SIGKILL lands asynchronously: return once the group is empty (bounded), so nothing of it is still
        # running when the caller retries or the deadline is reported.
        until = time.monotonic() + 5
        while time.monotonic() < until:
            try:
                os.killpg(process.pid, 0)
            except (ProcessLookupError, PermissionError):
                break
            time.sleep(0.02)
        waited = ", waiting on cargo's package cache lock" if LOCK_WAIT in (err or "") else ""
        return 124, f"timed out after {timeout:g}s{waited}"
    return process.returncode, err


def remaining(end: float | None, wanted: float) -> float:
    """WANTED seconds, cut to what is left before END (a `clock()` time; None: no end)."""
    return wanted if end is None else min(wanted, end - clock())


def judge(repo: Path, root: str, env: dict[str, str], passes: tuple[list[str], ...] = (["--offline"], []),
          timeout: float = TIMEOUT, end: float | None = None) -> tuple[str, str]:
    """('ok' | 'stale' | 'unchecked' | 'timeout', detail) for the workspace at ROOT; no pass starts past END."""
    verdict, last = "unchecked", ""
    for network in passes:
        limit = remaining(end, timeout)
        if limit <= 1:
            return "timeout", "not started: the deadline was spent"
        code, err = cargo(["update", "--workspace", "--locked", *network], repo / root, env, timeout=limit)
        if code == 0:
            return "ok", ""
        if DRIFT in err or STALE.search(err):
            return "stale", ""
        verdict = "timeout" if code == 124 else "unchecked"
        last = err.strip().splitlines()[-1] if err.strip() else f"exit {code}"
    return verdict, last


def label(root: str) -> str:
    return root or "."


def check(repo: Path, jobs: int, strict: bool = False, touched: set[str] | None = None,
          deadline: float | None = None, end: float | None = None) -> dict[str, tuple[str, str]]:
    """Every workspace's verdict. TOUCHED: the workspaces the change touches (None: all of them). DEADLINE: seconds
    the whole check may take (default NO_BASE_DEADLINE when TOUCHED is None, else none); past it nothing starts,
    and a running resolve is cut at it. END: the `clock()` time the deadline runs out, when the caller has one for
    a longer run (main: check and fix share it)."""
    if shutil.which("cargo") is None:
        return {root: ("unchecked", "no cargo on PATH") for root in tracked_roots(repo)}
    started = clock()
    if deadline is None and touched is None:
        deadline = NO_BASE_DEADLINE
    if end is None and deadline is not None:
        end = started + deadline
    env = cargo_env(repo)
    roots = tracked_roots(repo)
    is_touched = (lambda root: True) if touched is None else (lambda root: root in touched)

    def over_budget(root: str) -> bool:
        return not is_touched(root) and clock() - started > BUDGET

    def left() -> float:
        return float("inf") if end is None else end - clock()

    def limit(wanted: float) -> float:
        return min(wanted, left())

    def spent() -> tuple[str, str]:
        return "timeout", ("not started: the deadline was spent" if deadline is None
                           else f"not started: the check's {deadline:g}s deadline was spent")

    # Offline, in parallel: from the cached index alone, each resolve holds cargo's lock only briefly.
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        verdicts = list(pool.map(lambda root: judge(repo, root, env, passes=(["--offline"],), timeout=limit(TIMEOUT))
                                 if left() > 1 else spent(), roots))
    results = dict(zip(roots, verdicts))
    # With the network, one at a time: cargo holds the package cache lock for a whole resolve, so parallel resolves
    # queue on it and the queue counts against each one's limit. The index entries one fetches serve the next.
    pending = sorted((root for root, (verdict, _) in results.items() if verdict in ("unchecked", "timeout")),
                     key=lambda root: (not is_touched(root), root))
    for root in pending:
        if over_budget(root):
            results[root] = ("timeout", f"not started: the {BUDGET}s budget for untouched workspaces was spent")
            continue
        if left() <= 1:
            results[root] = spent()
            continue
        results[root] = judge(repo, root, env, passes=([],), timeout=limit(TIMEOUT))
    if strict:
        for root in pending:
            verdict, first = results[root]
            if verdict != "timeout" or over_budget(root) or first.startswith("not started") or left() <= 1:
                continue
            verdict, detail = judge(repo, root, env, passes=([],), timeout=limit(RETRY_TIMEOUT))
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


def inherited_names(table: object) -> list[str]:
    """The dependencies a manifest table takes from its workspace (`name = { workspace = true }` or
    `name.workspace = true`) in [dependencies], [dev-dependencies], [build-dependencies] and their
    [target.*] forms."""
    found: list[str] = []
    if isinstance(table, dict):
        for key, value in table.items():
            if not isinstance(value, dict):
                continue
            if key in DEPENDENCY_KEYS[:3]:
                found += [name for name, spec in value.items()
                          if isinstance(spec, dict) and spec.get("workspace") is True]
            elif key == "target":
                for platform in value.values():
                    found += inherited_names(platform)
    return found


def touched_roots(repo: Path, roots: list[str], base: str) -> set[str] | None:
    """The workspaces whose lock the change since BASE can reach: a Cargo.toml or Cargo.lock under the workspace, in
    a package it reaches by path (directly or through a `{ workspace = true }` dependency's path), or a workspace
    manifest above one of those. None (all of them) with no usable base. An over-count only keeps a workspace
    strict."""
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
    try:
        import tomllib  # Python 3.11; only CI passes --base (the pre-push hook's python3 can be macOS's 3.9)
    except ImportError:
        print(f"cargo-locks: --base needs Python 3.11+ (tomllib), not {sys.version.split()[0]}; every workspace "
              "counts as touched", file=sys.stderr)
        return None

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

    # Where one workspace's tree ends: a manifest with a [workspace] of its own, or a directory a workspace
    # manifest excludes (cargo makes each its own workspace, with its own lock).
    boundaries = {directory for directory, manifest in manifests.items() if "workspace" in manifest}
    for directory, manifest in list(manifests.items()):
        table = manifest.get("workspace")
        if isinstance(table, dict):
            boundaries |= {os.path.normpath(str(PurePosixPath(directory) / str(entry)))
                           for entry in table.get("exclude", []) if isinstance(entry, str)}
    boundaries.discard(".")

    def nearest(path: str) -> str | None:
        """The deepest boundary at or above PATH."""
        for candidate in (path, *map(str, PurePosixPath(path).parents)):
            if candidate in boundaries:
                return candidate
        return None

    def owns(directory: str, path: str) -> bool:
        """PATH is in DIRECTORY's tree with no other workspace in between."""
        if not under(path, directory):
            return False
        inner = nearest(path)
        return inner is None or inner == directory or not under(inner, directory)

    def workspace_of(directory: str) -> str | None:
        """The workspace whose manifest DIRECTORY's package inherits from: the nearest one at or above it, never
        one past a nested workspace or an exclude."""
        own = nearest(directory) or "."
        return own if "workspace" in manifests.get(own, {}) and owns(own, directory) else None

    def targets(directory: str) -> list[str]:
        """The package directories DIRECTORY's manifest uses by path: its own `path =` entries, and each
        `{ workspace = true }` dependency's path in its workspace's [workspace.dependencies] (cmux#41767 review:
        cmux-next-ios/rust reaches cmux-tui crates, and they inherit paths from cmux-tui's manifest)."""
        manifest = manifests.get(directory, {})
        found = [os.path.normpath(str(PurePosixPath(directory) / spec)) for spec in path_specs(manifest)]
        own = workspace_of(directory)
        if own is not None:
            table = manifests[own]["workspace"]
            shared = table.get("dependencies", {}) if isinstance(table, dict) else {}
            for name in inherited_names(manifest):
                spec = shared.get(name) if isinstance(shared, dict) else None
                if isinstance(spec, dict) and isinstance(spec.get("path"), str):
                    found.append(os.path.normpath(str(PurePosixPath(own) / spec["path"])))
        return found

    def reach(root: str) -> set[str]:
        # seen: directories whose whole tree the workspace watches. read: those whose manifests are queued. A
        # workspace a reached package inherits from is watched (its manifest is read for the package) but not read:
        # its other members are followed only when something names them, so a member there that reaches out of
        # the tree, or into a nested workspace, is still followed.
        seen = {root or "."}
        read = {root or "."}
        queue = [directory for directory in manifests if owns(root or ".", directory)]
        # Members outside the root's tree ("../cmux-rd-ffi" in cmux-app-ffi's workspace) share its lock too.
        table = manifests.get(root or ".", {}).get("workspace")
        for member in table.get("members", []) if isinstance(table, dict) else []:
            pattern = os.path.normpath(str(PurePosixPath(root or ".") / str(member)))
            for directory in manifests:
                if fnmatch.fnmatch(directory, pattern) and not under(directory, root or "."):
                    seen.add(directory)
                    read.add(directory)
                    queue += [other for other in manifests if owns(directory, other)]
        while queue:
            directory = queue.pop()
            for target in targets(directory):
                if target.startswith("..") or any(owns(known, target) for known in read):
                    continue
                seen.add(target)
                read.add(target)
                queue += [other for other in manifests if owns(target, other)]
                own = workspace_of(target)
                if own is not None and own != target:
                    seen.add(own)
        return seen

    found = set()
    for root in roots:
        watched = reach(root)
        if any(owns(directory, str(PurePosixPath(path).parent)) for path in cargo_files for directory in watched):
            found.add(root)
    return found


def changed(repo: Path) -> set[str]:
    out = subprocess.run(["git", "-C", str(repo), "status", "--porcelain", "-z", "--untracked-files=all"],
                         capture_output=True, check=True).stdout.decode()
    return {entry[3:] for entry in out.split("\0") if len(entry) > 3}


def fix(repo: Path, results: dict[str, tuple[str, str]], end: float | None = None) -> list[str]:
    """Rewrite each stale lock; no rewrite or re-check starts past END, and a running one is cut at it."""
    lines = []
    stale = [root for root, (verdict, _) in results.items() if verdict == "stale"]
    if not stale:
        return lines
    env = cargo_env(repo)
    before = changed(repo)
    for root in stale:
        lock = f"{root}/Cargo.lock" if root else "Cargo.lock"
        done = spent = False
        for network in (["--offline"], []):
            limit = remaining(end, TIMEOUT)
            if limit <= 1:
                spent = True
                break
            code, _ = cargo(["update", "--workspace", *network], repo / root, env, timeout=limit)
            if code == 0 and judge(repo, root, env, end=end)[0] == "ok":
                done = True
                break
        if done:
            lines.append(f"fixed: {lock} (cargo update --workspace in {label(root)})")
        elif spent:
            lines.append(f"left: {lock} is stale and the deadline was spent before cargo update --workspace could "
                         "rewrite it (run it there by hand)")
        else:
            lines.append(f"left: {lock} is stale and cargo update --workspace could not rewrite it (run it there by hand)")
    stray = sorted(p for p in changed(repo) - before if p.rpartition("/")[2] != "Cargo.lock")
    if stray:
        subprocess.run(["git", "-C", str(repo), "checkout", "--", *stray], capture_output=True)
        subprocess.run(["git", "-C", str(repo), "clean", "-fdq", "--", *stray], capture_output=True)
        lines.append("left: cargo update touched files other than Cargo.lock (undone): " + ", ".join(stray))
    return lines


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("mode", choices=("check", "fix", "explain"))
    parser.add_argument("log", nargs="?", help="explain: the log to read (`-`: stdin)")
    parser.add_argument("--repo", default=None, help="the repository's top directory (default: .; for explain, "
                        "the repository this script is in)")
    parser.add_argument("--strict", action="store_true", help="a workspace cargo could not judge fails the check")
    parser.add_argument("--base", default="", help="the change's base commit: under --strict, a timed-out "
                        "workspace the change does not touch only warns")
    parser.add_argument("--deadline", type=float, default=None,
                        help=f"seconds the whole check may take (default with no usable --base: {NO_BASE_DEADLINE})")
    parser.add_argument("--jobs", type=int, default=8)
    args = parser.parse_args(argv)
    if args.mode == "explain":
        if args.log is None:
            parser.error("explain needs a log file (or - for stdin)")
        return explain(args.log, Path(args.repo or Path(__file__).resolve().parents[2]))
    if args.log is not None:
        parser.error(f"unrecognized arguments: {args.log}")
    repo = Path(args.repo or ".").resolve()

    touched = touched_roots(repo, tracked_roots(repo), args.base) if args.mode == "check" and args.strict else None
    # One absolute deadline for the whole run: check, then fix's rewrites and their re-checks.
    deadline = NO_BASE_DEADLINE if args.deadline is None and touched is None else args.deadline
    end = None if deadline is None else clock() + deadline
    results = check(repo, args.jobs, strict=args.strict and args.mode == "check", touched=touched,
                    deadline=deadline, end=end)
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
        for line in fix(repo, results, end=end):
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
