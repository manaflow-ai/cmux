#!/usr/bin/env python3
"""Run the web lints on what a push (or a working tree) changes.

The pre-push hook (scripts/git-hooks/pre-push) runs a trusted copy of this file;
`scripts/web-lint.sh` runs it by hand, and the `web lint` job of
cmux-next-web.yml runs it on every feat-cmux-next push. One file, so the hook,
the manual command and CI cannot drift.

What runs, per area touched by the change:

* webviews/ and cmux-tui/frontends/web/: the package's own `check` script from
  its package.json (the exact step CI runs: Oxfmt, Oxlint with the type check,
  and webviews' source checks such as check:browser-lanes). The `&&` pieces of
  that script run at once, so the hook costs the slowest piece, not the sum.
* web/: ESLint, errors only, on the changed files, with a cache. web/ as a whole
  is not lint-clean, so only the files a change touches are held to it.

Usage:
    scripts/web-lint.sh                 # lint what differs from origin/feat-cmux-next
    scripts/web-lint.sh --fix           # autofix (Oxfmt, Oxlint --fix, ESLint --fix), then re-check
    scripts/web-lint.sh --base REF --head SHA   # a commit range (CI)
    git push                            # the hook runs it on the pushed range

Skip once, with a reason that names the evidence (logged in the push output):
    CMUX_WEB_LINT_SKIP_REASON="webviews check:text-focus is red on base 1a2b3c4" git push
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

ZERO_SHA = "0" * 40
DEFAULT_BASE_REFS = ("origin/feat-cmux-next", "origin/main")
ESLINT_EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
FIX_COMMAND = "scripts/web-lint.sh --fix"
MIN_SKIP_REASON = 20


@dataclass(frozen=True)
class ScriptPackage:
    """A package whose package.json `check` script is the lint CI runs."""

    directory: str
    # Paths whose change makes this package's check run.
    triggers: tuple[str, ...]
    # Paths that hold code the check executes (configs, scripts, the lockfile).
    # A push that changes one is not linted by the hook: the hook would run code
    # from the pushed branch, so CI's sandboxed run is the check for it.
    executed: tuple[str, ...]


@dataclass(frozen=True)
class EslintPackage:
    """A package linted with ESLint on its changed files only."""

    directory: str
    executed: tuple[str, ...]


SCRIPT_PACKAGES = (
    ScriptPackage(
        directory="webviews",
        triggers=("webviews/", "config/vite-plus/", "scripts/cmux-next/", "cmux-tui/crates/acpmux/spec/"),
        executed=("webviews/", "config/vite-plus/", "scripts/cmux-next/"),
    ),
    ScriptPackage(
        directory="cmux-tui/frontends/web",
        triggers=("cmux-tui/frontends/web/", "config/vite-plus/"),
        executed=("cmux-tui/frontends/web/", "config/vite-plus/"),
    ),
)
ESLINT_PACKAGES = (
    EslintPackage(
        directory="web",
        executed=("web/eslint.config.mjs", "web/package.json", "web/bun.lock"),
    ),
)
# Source directories of a script package: their files are type-checked and
# linted, never executed by the check, so changing them is safe in the hook.
SOURCE_DIRS = ("src/", "test/", "tests/")


@dataclass
class Result:
    label: str
    command: str
    returncode: int
    output: str
    seconds: float


@dataclass
class Plan:
    script_packages: list[ScriptPackage] = field(default_factory=list)
    eslint_files: dict[str, list[str]] = field(default_factory=dict)
    untrusted: list[tuple[str, list[str]]] = field(default_factory=list)


def git(repo: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], text=True, capture_output=True)
    if check and result.returncode != 0:
        raise SystemExit(f"web-lint: git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def ref_exists(repo: Path, ref: str) -> bool:
    return subprocess.run(["git", "-C", str(repo), "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                          capture_output=True).returncode == 0


def default_base(repo: Path, head: str) -> str:
    for ref in DEFAULT_BASE_REFS:
        if ref_exists(repo, ref):
            base = git(repo, "merge-base", head, ref, check=False).strip()
            if base:
                return base
    return f"{head}~1" if ref_exists(repo, f"{head}~1") else head


def pushed_ranges(repo: Path, lines: list[str]) -> list[tuple[str, str]]:
    """Read pre-push stdin (`<local ref> <local sha> <remote ref> <remote sha>`)."""
    ranges = []
    for line in lines:
        parts = line.split()
        if len(parts) != 4:
            continue
        _local_ref, local_sha, _remote_ref, remote_sha = parts
        if local_sha == ZERO_SHA:
            continue  # a branch deletion pushes no files
        if remote_sha != ZERO_SHA and ref_exists(repo, remote_sha):
            base = git(repo, "merge-base", local_sha, remote_sha, check=False).strip() or remote_sha
        else:
            base = default_base(repo, local_sha)
        ranges.append((base, local_sha))
    return ranges


def changed_files(repo: Path, base: str, head: str | None) -> list[str]:
    """Files added, copied, modified or renamed from base to head (or the working tree)."""
    args = ["diff", "--name-only", "--no-renames", "--diff-filter=ACMRT", base]
    if head is not None:
        args.append(head)
    names = git(repo, *args).splitlines()
    if head is None:
        names += git(repo, "ls-files", "--others", "--exclude-standard").splitlines()
    return sorted(set(n for n in names if n))


def under(path: str, prefixes: tuple[str, ...]) -> bool:
    return any(path == p.rstrip("/") or path.startswith(p) for p in prefixes)


def executed_changes(package: ScriptPackage, files: list[str]) -> list[str]:
    hits = []
    sources = tuple(f"{package.directory}/{d}" for d in SOURCE_DIRS)
    for path in files:
        if under(path, package.executed) and not under(path, sources):
            hits.append(path)
    return hits


def make_plan(repo: Path, files: list[str], guard_executed: bool) -> Plan:
    plan = Plan()
    for package in SCRIPT_PACKAGES:
        if not (repo / package.directory / "package.json").is_file():
            continue
        if not any(under(f, package.triggers) for f in files):
            continue
        risky = executed_changes(package, files) if guard_executed else []
        if risky:
            plan.untrusted.append((package.directory, risky))
        else:
            plan.script_packages.append(package)
    for package in ESLINT_PACKAGES:
        if not (repo / package.directory / "package.json").is_file():
            continue
        targets = [f for f in files if f.startswith(f"{package.directory}/") and f.endswith(ESLINT_EXTENSIONS)
                   and (repo / f).is_file()]
        if not targets:
            continue
        risky = [f for f in files if f in package.executed] if guard_executed else []
        if risky:
            plan.untrusted.append((package.directory, risky))
        else:
            plan.eslint_files[package.directory] = targets
    return plan


def check_pieces(repo: Path, package: ScriptPackage, script: str) -> list[str]:
    scripts = json.loads((repo / package.directory / "package.json").read_text(encoding="utf-8")).get("scripts", {})
    body = scripts.get(script)
    if not body:
        return []
    return [piece.strip() for piece in body.split("&&") if piece.strip()]


def package_env(repo: Path, directory: str) -> dict[str, str]:
    env = dict(os.environ)
    env["PATH"] = f"{repo / directory / 'node_modules' / '.bin'}{os.pathsep}{env.get('PATH', '')}"
    return env


def ensure_deps(repo: Path, directory: str) -> Result | None:
    """Install the package's pinned dependencies (fast when they are current)."""
    if not (repo / directory / "bun.lock").is_file():
        return None
    bun = shutil.which("bun")
    if bun is None:
        return Result(directory, "bun install", 127, "bun is not on PATH; install bun 1.4 to run the web lint.", 0)
    started = time.monotonic()
    result = subprocess.run([bun, "install", "--frozen-lockfile", "--silent"], cwd=repo / directory,
                            text=True, capture_output=True)
    if result.returncode == 0:
        return None
    return Result(directory, "bun install --frozen-lockfile", result.returncode,
                  result.stdout + result.stderr, time.monotonic() - started)


def run(label: str, command: list[str] | str, cwd: Path, env: dict[str, str]) -> Result:
    started = time.monotonic()
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True,
                            shell=isinstance(command, str))
    shown = command if isinstance(command, str) else " ".join(command)
    return Result(label, shown, result.returncode, result.stdout + result.stderr, time.monotonic() - started)


def eslint_command(repo: Path, directory: str, files: list[str], fix: bool) -> list[str]:
    relative = [f[len(directory) + 1:] for f in files]
    command = [str(repo / directory / "node_modules" / ".bin" / "eslint"), "--quiet", "--no-warn-ignored",
               "--cache", "--cache-location", "node_modules/.cache/eslint-web-lint/"]
    if fix:
        command.append("--fix")
    return command + relative


def run_plan(repo: Path, plan: Plan, fix: bool) -> list[Result]:
    directories = [p.directory for p in plan.script_packages] + list(plan.eslint_files)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(directories))) as pool:
        installs = [r for r in pool.map(lambda d: ensure_deps(repo, d), directories) if r]
    if installs:
        return installs
    if fix:
        for package in plan.script_packages:
            for piece in check_pieces(repo, package, "check:fix"):
                run(package.directory, piece, repo / package.directory, package_env(repo, package.directory))
        for directory, files in plan.eslint_files.items():
            run(directory, eslint_command(repo, directory, files, True), repo / directory,
                package_env(repo, directory))
    jobs = []
    for package in plan.script_packages:
        for piece in check_pieces(repo, package, "check"):
            jobs.append((package.directory, piece, repo / package.directory, package_env(repo, package.directory)))
    for directory, files in plan.eslint_files.items():
        jobs.append((directory, eslint_command(repo, directory, files, False), repo / directory,
                     package_env(repo, directory)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(8, len(jobs)))) as pool:
        return list(pool.map(lambda job: run(*job), jobs))


def report(results: list[Result], seconds: float, mode: str, timings: bool = False) -> int:
    failed = [r for r in results if r.returncode != 0]
    if timings:
        for result in sorted(results, key=lambda r: -r.seconds):
            print(f"  {result.seconds:5.1f}s  {result.label}: {result.command}", file=sys.stderr)
    areas = sorted({r.label for r in results})
    if not failed:
        print(f"{mode}: web lint passed in {seconds:.1f}s ({', '.join(areas)}).", file=sys.stderr)
        return 0
    for result in failed:
        print(f"\n--- {result.label}: {result.command} (exit {result.returncode}, {result.seconds:.1f}s)",
              file=sys.stderr)
        print(result.output.rstrip()[-6000:], file=sys.stderr)
    print(f"\n{mode}: web lint failed in {seconds:.1f}s: "
          + ", ".join(f"{r.label}: {r.command}" for r in failed), file=sys.stderr)
    print(f"Fix: run `{FIX_COMMAND}`, review and commit the changes, then push again.", file=sys.stderr)
    print("     It autofixes formatting and fixable lint rules; type errors and source checks need a manual edit.",
          file=sys.stderr)
    print("     Reproduce one failure: (cd <area> && bun run check), or for web/: (cd web && bunx eslint <file>).",
          file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, help="checkout root (default: the current one)")
    parser.add_argument("--base", help="base ref (default: merge-base with origin/feat-cmux-next)")
    parser.add_argument("--head", help="head ref (default: the working tree, uncommitted edits included)")
    parser.add_argument("--fix", action="store_true", help="autofix what the tools can, then re-check")
    parser.add_argument("--pre-push", action="store_true", help="read pre-push stdin (used by the hook)")
    parser.add_argument("--dry-run", action="store_true", help="print what would run, run nothing")
    parser.add_argument("--timings", action="store_true", help="print each check's time")
    parser.add_argument("--all", action="store_true",
                        help="run every package check, whatever changed (CI, when the push base is unknown)")
    args = parser.parse_args(argv)

    mode = "pre-push" if args.pre_push else "web-lint"
    if args.pre_push:
        reason = os.environ.get("CMUX_WEB_LINT_SKIP_REASON", "").strip()
        if reason:
            if len(reason) < MIN_SKIP_REASON:
                print(f"pre-push: CMUX_WEB_LINT_SKIP_REASON must be a sentence of at least {MIN_SKIP_REASON} "
                      "characters that names the evidence (the failing check and the base SHA).", file=sys.stderr)
                return 1
            print(f"pre-push: web lint skipped: {reason}", file=sys.stderr)
            return 0

    repo = (args.repo or Path(git(Path.cwd(), "rev-parse", "--show-toplevel").strip())).resolve()
    if args.pre_push:
        ranges = pushed_ranges(repo, sys.stdin.read().splitlines())
        files = sorted({f for base, head in ranges for f in changed_files(repo, base, head)})
        heads = {head for _base, head in ranges}
    else:
        head = args.head
        base = args.base or default_base(repo, head or "HEAD")
        files = changed_files(repo, base, head)
        heads = {head} if head else set()

    if args.all:
        files = [f"{package.directory}/package.json" for package in SCRIPT_PACKAGES]
    plan = make_plan(repo, files, guard_executed=args.pre_push)
    for directory, risky in plan.untrusted:
        print(f"{mode}: {directory}: not linted here: this push changes code the lint runs "
              f"({', '.join(risky[:5])}{' …' if len(risky) > 5 else ''}). The `web lint` CI job checks it; "
              f"run `{FIX_COMMAND}` yourself if you trust this branch.", file=sys.stderr)
    if not plan.script_packages and not plan.eslint_files:
        if args.dry_run:
            print("nothing to lint")
        return 0
    if args.dry_run:
        for package in plan.script_packages:
            print(f"{package.directory}: {' && '.join(check_pieces(repo, package, 'check'))}")
        for directory, targets in plan.eslint_files.items():
            print(f"{directory}: eslint {' '.join(targets)}")
        return 0

    head_sha = git(repo, "rev-parse", "HEAD").strip()
    if args.pre_push and any(git(repo, "rev-parse", h).strip() != head_sha for h in heads):
        print(f"{mode}: warning: the pushed commit is not HEAD; the lint reads the working tree.", file=sys.stderr)
    started = time.monotonic()
    results = run_plan(repo, plan, args.fix)
    return report(results, time.monotonic() - started, mode, args.timings)


if __name__ == "__main__":
    sys.exit(main())
