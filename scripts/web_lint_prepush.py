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
* cmux-tui/frontends/web/ imports `cmux` from cmux-tui/bindings/typescript, whose exports
  point at a tsc-built dist/. That package is installed and built first, as CI does (npm ci,
  npm run build; bun when npm is missing), and only when its inputs changed since the last
  build. Without it the check printed a TS2307 "cannot find module" for every import.
* web/: ESLint, errors only, on the changed files, with a cache. web/ as a whole
  is not lint-clean, so only the files a change touches are held to it.

Which files: a push's own range (scripts/cmux-next/push_range.py, the definition the
cmux-next gate, guardrails and arch ratchet share), so a branch rebased onto
origin/feat-cmux-next and force pushed lints its own commits' files, never the
web files of the upstream commits the rebase brought in; a merge of
origin/feat-cmux-next lints the files it changes over both the merged upstream
and the branch's last pushed head. The hook reads the installed copy
(--trusted-scripts-dir); a push whose own commits nothing bounds is refused
with what to fetch.

A push, or --head SHA, is linted as that commit: when the checkout is not exactly
that commit (another branch is checked out, or it has uncommitted or untracked
files), the checks run in a temporary worktree of it, reusing the checkout's
node_modules where the commit's bun.lock is the same. Linting the working tree
let a commit with an error through when its fix sat uncommitted (0b115ab).

--new-only (the fast gates, on a pull request merged with its base): a package
check that fails runs again on BASE, and only findings BASE does not have fail,
per error (scripts/ci/fast_gate_webviews_checks.py compares them); the rest
are the base's red and print as warnings. A red base hid #23763's TS2339.

Usage:
    scripts/web-lint.sh                 # lint what HEAD's own commits and the working tree change
    scripts/web-lint.sh --fix           # autofix (Oxfmt, Oxlint --fix, ESLint --fix), then re-check
    scripts/web-lint.sh --base REF --head SHA   # a commit range (CI)
    git push                            # the hook runs it on the pushed range

Skip once, with a reason that names the evidence (logged in the push output):
    CMUX_WEB_LINT_SKIP_REASON="webviews check:text-focus is red on base 1a2b3c4" git push
"""
from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path

ESLINT_EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
FIX_COMMAND = "scripts/web-lint.sh --fix"
MIN_SKIP_REASON = 20


@dataclass(frozen=True)
class LocalBuild:
    """A file: dependency whose exports point at build output, built before the packages that import it."""

    directory: str
    # The name the importing packages install it under (node_modules/<name>).
    name: str
    # Files and folders, relative to `directory`, whose content decides the build.
    inputs: tuple[str, ...]
    output: str = "dist"


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
    # Local packages built before this package installs and checks.
    builds: tuple[LocalBuild, ...] = ()


@dataclass(frozen=True)
class EslintPackage:
    """A package linted with ESLint on its changed files only."""

    directory: str
    executed: tuple[str, ...]


TUI_BINDINGS = LocalBuild(
    directory="cmux-tui/bindings/typescript",
    name="cmux",
    # bun.lock / bun.lockb: the bun fallback installs from one when it is there.
    inputs=("package.json", "package-lock.json", "bun.lock", "bun.lockb", "tsconfig.json", "src/", "test/", "e2e/"),
)
BUILD_STAMP = ".web-lint-build"
# In a dependent package: node_modules/<INSTALLED_STAMPS>/<build name> holds the digest of the build its
# node_modules copy came from, written only after that install succeeded. Not inside the copy: bun copies
# the build's own stamp along with dist/, even on an install that then fails.
INSTALLED_STAMPS = ".web-lint-builds"
SCRIPT_PACKAGES = (
    ScriptPackage(
        directory="webviews",
        triggers=("webviews/", "config/vite-plus/", "scripts/cmux-next/", "cmux-tui/crates/acpmux/spec/"),
        executed=("webviews/", "config/vite-plus/", "scripts/cmux-next/"),
    ),
    ScriptPackage(
        directory="cmux-tui/frontends/web",
        triggers=("cmux-tui/frontends/web/", "config/vite-plus/", f"{TUI_BINDINGS.directory}/"),
        # Every file input of the bindings build (manifest, lockfiles, tsconfig) picks code the build runs;
        # its source folders are only compiled.
        executed=("cmux-tui/frontends/web/", "config/vite-plus/",
                  *(f"{TUI_BINDINGS.directory}/{name}" for name in TUI_BINDINGS.inputs if not name.endswith("/"))),
        builds=(TUI_BINDINGS,),
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


PUSH_RANGE = "push_range.py"


def load_push_range(trusted_scripts: Path | None):
    """scripts/cmux-next/push_range.py: which commits a push owns, the one definition the cmux-next gate,
    guardrails and arch ratchet use too. The hook passes the installed reviewed copy (--trusted-scripts-dir,
    the cmux-next-checks snapshot); a manual or CI run reads the one next to this file. Exits with what to do
    when it is missing (the hook then refuses the push)."""
    import importlib.util  # noqa: PLC0415

    name = "cmux_next_push_range"  # the gate's name too: one copy per process
    if name in sys.modules:
        return sys.modules[name]
    path = (trusted_scripts or Path(__file__).resolve().parent / "cmux-next") / PUSH_RANGE
    if not path.is_file():
        raise SystemExit(f"web-lint: {path} is missing; rerun scripts/install-git-hooks.sh")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # dataclasses look their module up
    writes, sys.dont_write_bytecode = sys.dont_write_bytecode, True  # no __pycache__ left in the checkout
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = writes
    return module


def own_files(repo: Path, own, head: str | None) -> list[str]:
    """The files the own range OWN (push_range.OwnRange) changes at HEAD (a commit, or None: the working tree):
    over its base, and for a merge also since the head of every range it does not own (a file only upstream
    changed is the merged upstream's; a file only the branch's earlier push changed is that push's)."""
    files = set(changed_files(repo, own.base, head))
    for _, already in own.before:
        files &= set(changed_files(repo, already, head))
    return sorted(files)


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


def snapshot(repo: Path, sha: str | None):
    """(exists, read) for repository paths in commit `sha`, from git objects, so a plan needs no checkout;
    the working tree for None."""
    if sha is None:
        return (lambda rel: (repo / rel).is_file()), (lambda rel: (repo / rel).read_text(encoding="utf-8"))
    directories = [p.directory for p in SCRIPT_PACKAGES] + [p.directory for p in ESLINT_PACKAGES]
    names = set(git(repo, "ls-tree", "-r", "--name-only", sha, "--", *directories).splitlines())
    return names.__contains__, (lambda rel: git(repo, "show", f"{sha}:{rel}"))


def make_plan(repo: Path, files: list[str], guard_executed: bool, exists=None) -> Plan:
    exists = exists or (lambda rel: (repo / rel).is_file())
    plan = Plan()
    for package in SCRIPT_PACKAGES:
        if not exists(f"{package.directory}/package.json"):
            continue
        if not any(under(f, package.triggers) for f in files):
            continue
        risky = executed_changes(package, files) if guard_executed else []
        if risky:
            plan.untrusted.append((package.directory, risky))
        else:
            plan.script_packages.append(package)
    for package in ESLINT_PACKAGES:
        if not exists(f"{package.directory}/package.json"):
            continue
        targets = [f for f in files if f.startswith(f"{package.directory}/") and f.endswith(ESLINT_EXTENSIONS)
                   and exists(f)]
        if not targets:
            continue
        risky = [f for f in files if f in package.executed] if guard_executed else []
        if risky:
            plan.untrusted.append((package.directory, risky))
        else:
            plan.eslint_files[package.directory] = targets
    return plan


def check_pieces(repo: Path, package: ScriptPackage, script: str, read=None) -> list[str]:
    read = read or (lambda rel: (repo / rel).read_text(encoding="utf-8"))
    scripts = json.loads(read(f"{package.directory}/package.json")).get("scripts", {})
    body = scripts.get(script)
    if not body:
        return []
    return [piece.strip() for piece in body.split("&&") if piece.strip()]


def package_env(repo: Path, directory: str) -> dict[str, str]:
    # A hook's GIT_DIR names the checkout's repository; a check run in a lint tree must see that tree.
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
    env["PATH"] = f"{repo / directory / 'node_modules' / '.bin'}{os.pathsep}{env.get('PATH', '')}"
    return env


def run_leaving_no_lockfile(command: list[str], cwd: Path, env: dict[str, str] | None = None):
    """Run `command`; remove a bun.lock it wrote where there was none (bun writes one when it migrates a
    package-lock.json, even with --no-save), so a lint leaves the checkout as it found it."""
    lock = cwd / "bun.lock"
    had_lock = lock.exists()
    try:
        return subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
    finally:
        if not had_lock:
            lock.unlink(missing_ok=True)


def ensure_deps(repo: Path, directory: str, force: bool = False) -> Result | None:
    """Install the package's pinned dependencies (fast when they are current). A package with no lockfile
    keeps the node_modules it has (unless `force`), else gets a plain install."""
    locked = (repo / directory / "bun.lock").is_file()
    if not locked and not force and (repo / directory / "node_modules").is_dir():
        return None
    bun = shutil.which("bun")
    if bun is None:
        return Result(directory, "bun install", 127, "bun is not on PATH; install bun 1.4 to run the web lint.", 0)
    started = time.monotonic()
    command = ["install", "--frozen-lockfile", "--silent"] if locked else ["install", "--silent", "--no-save"]
    result = run_leaving_no_lockfile([bun, *command], repo / directory)
    if result.returncode == 0:
        return None
    return Result(directory, f"bun {' '.join(c for c in command if c != '--silent')}", result.returncode,
                  result.stdout + result.stderr, time.monotonic() - started)


def build_digest(repo: Path, build: LocalBuild) -> str:
    """A hash of the build's inputs: their paths and contents."""
    root = repo / build.directory
    digest = hashlib.sha256()
    for item in build.inputs:
        path = root / item
        files = sorted(p for p in path.rglob("*") if p.is_file()) if path.is_dir() else [path] * path.is_file()
        for file in files:
            digest.update(file.relative_to(root).as_posix().encode() + b"\0" + file.read_bytes() + b"\0")
    return digest.hexdigest()


def read_stamp(path: Path) -> str | None:
    return path.read_text(encoding="utf-8").strip() if path.is_file() else None


def installed_stamp(repo: Path, directory: str, build: LocalBuild) -> Path:
    return repo / directory / "node_modules" / INSTALLED_STAMPS / build.name


def ensure_build(repo: Path, build: LocalBuild, dependents: list[str]) -> tuple[str | None, Result | None]:
    """Install and build `build` unless its output was built from the same inputs; returns (the digest of
    its inputs, failure). A failure is one Result that names the build and the checks it holds back."""
    root = repo / build.directory
    stamp = root / build.output / BUILD_STAMP
    digest = build_digest(repo, build)
    if read_stamp(stamp) == digest:
        return digest, None
    held = f"Not checked until this builds: {', '.join(dependents)} (it imports {build.name} from this build)."
    npm, bun = shutil.which("npm"), shutil.which("bun")
    if npm:  # what CI runs (cmux-tui.yml, "Build TypeScript SDK")
        steps = [[npm, "ci", "--no-audit", "--no-fund"], [npm, "run", "build"]]
    elif bun:  # tsc's node shebang runs on bun
        steps = [[bun, "install", "--silent", "--no-save"], [bun, "run", "--bun", "build"]]
    else:
        return None, Result(build.directory, "npm ci && npm run build", 127,
                             f"neither npm nor bun is on PATH, so {build.directory} can't be built.\n{held}", 0)
    stamp.unlink(missing_ok=True)
    started = time.monotonic()
    env = package_env(repo, build.directory)
    for step in steps:
        result = run_leaving_no_lockfile(step, root, env)
        if result.returncode != 0:
            shown = " ".join([Path(step[0]).name, *(c for c in step[1:] if c != "--silent")])
            return None, Result(build.directory, f"{shown} (the {build.name} bindings)", result.returncode,
                                 f"{result.stdout}{result.stderr}\n{held}", time.monotonic() - started)
    stamp.parent.mkdir(parents=True, exist_ok=True)
    stamp.write_text(digest + "\n", encoding="utf-8")
    return digest, None


def prepare_builds(repo: Path, packages: list[ScriptPackage]) -> tuple[dict[str, dict[LocalBuild, str]], list[Result]]:
    """Build each local package the planned packages import; returns, per package to reinstall, the builds
    whose node_modules copy did not come from the current build (with that build's digest), and the failures."""
    builds: dict[LocalBuild, list[str]] = {}
    for package in packages:
        for build in package.builds:
            builds.setdefault(build, []).append(package.directory)
    digests, failures = {}, []
    for build, dependents in builds.items():
        digest, failure = ensure_build(repo, build, dependents)
        if failure:
            failures.append(failure)
        else:
            digests[build] = digest
    # bun copies a file: dependency into node_modules at install time, so a new build needs a new install;
    # a copy is current only when an install from this exact build succeeded.
    stale: dict[str, dict[LocalBuild, str]] = {}
    for package in packages:
        for build in package.builds:
            if build in digests and read_stamp(installed_stamp(repo, package.directory, build)) != digests[build]:
                stale.setdefault(package.directory, {})[build] = digests[build]
    return stale, failures


def install(repo: Path, directory: str, stale: dict[LocalBuild, str] | None) -> Result | None:
    """ensure_deps, forced when the package's copy of a local build is stale; that copy's stamp is
    cleared first and written back only once the install succeeds."""
    for build in stale or {}:
        installed_stamp(repo, directory, build).unlink(missing_ok=True)
    failure = ensure_deps(repo, directory, force=bool(stale))
    if failure is None:
        for build, digest in (stale or {}).items():
            path = installed_stamp(repo, directory, build)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(digest + "\n", encoding="utf-8")
    return failure


def run(label: str, command: list[str] | str, cwd: Path, env: dict[str, str]) -> Result:
    started = time.monotonic()
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True,
                            shell=isinstance(command, str))
    shown = command if isinstance(command, str) else " ".join(command)
    return Result(label, shown, result.returncode, result.stdout + result.stderr, time.monotonic() - started)


def eslint_command(repo: Path, directory: str, files: list[str], fix: bool, cache: bool = True) -> list[str]:
    relative = [f[len(directory) + 1:] for f in files]
    command = [str(repo / directory / "node_modules" / ".bin" / "eslint"), "--quiet", "--no-warn-ignored"]
    if cache:  # keyed by absolute path: a lint tree's random path would only miss and prune the checkout's
        command += ["--cache", "--cache-location", "node_modules/.cache/eslint-web-lint/"]
    if fix:
        command.append("--fix")
    return command + relative


def run_plan(repo: Path, plan: Plan, fix: bool, cache: bool = True) -> list[Result]:
    stale, failures = prepare_builds(repo, plan.script_packages)
    if failures:
        return failures
    directories = [p.directory for p in plan.script_packages] + list(plan.eslint_files)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(directories))) as pool:
        installs = [r for r in pool.map(lambda d: install(repo, d, stale.get(d)), directories) if r]
    if installs:
        return installs
    if fix:
        for package in plan.script_packages:
            for piece in check_pieces(repo, package, "check:fix"):
                run(package.directory, piece, repo / package.directory, package_env(repo, package.directory))
        for directory, files in plan.eslint_files.items():
            run(directory, eslint_command(repo, directory, files, True, cache), repo / directory,
                package_env(repo, directory))
    jobs = []
    for package in plan.script_packages:
        for piece in check_pieces(repo, package, "check"):
            jobs.append((package.directory, piece, repo / package.directory, package_env(repo, package.directory)))
    for directory, files in plan.eslint_files.items():
        jobs.append((directory, eslint_command(repo, directory, files, False, cache), repo / directory,
                     package_env(repo, directory)))
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(8, len(jobs)))) as pool:
        return list(pool.map(lambda job: run(*job), jobs))


def is_checked_out(repo: Path, sha: str) -> bool:
    """The checkout is exactly `sha`: HEAD is it and nothing is modified or untracked."""
    return (git(repo, "rev-parse", "HEAD").strip() == git(repo, "rev-parse", f"{sha}^{{commit}}").strip()
            and not git(repo, "status", "--porcelain", "--untracked-files=normal").strip())


@contextlib.contextmanager
def tree_of(repo: Path, sha: str | None, directories: list[str]):
    """A directory holding exactly commit `sha` (the checkout when it already is), or the checkout for None.
    Full, not sparse: the webviews checks read the whole repository (check-dialog-key-hints.py ..)."""
    if sha is None or is_checked_out(repo, sha):
        yield repo
        return
    holder = Path(tempfile.mkdtemp(prefix="cmux-web-lint-"))
    tree = holder / "tree"
    try:
        # No hooks: a checkout hook must not run for a lint tree.
        git(repo, "-c", "core.hooksPath=/dev/null", "worktree", "add", "--quiet", "--detach", str(tree), sha)
        for directory in directories:
            if (tree / directory).is_dir() and shares_deps(repo, sha, directory):
                (tree / directory / "node_modules").symlink_to(repo / directory / "node_modules")
        yield tree  # a package that can't share gets its own install (ensure_deps)
    finally:
        if tree.exists():
            git(repo, "worktree", "remove", "--force", str(tree), check=False)
        shutil.rmtree(holder, ignore_errors=True)


def shares_deps(repo: Path, sha: str, directory: str) -> bool:
    """The checkout's node_modules for `directory` holds what commit `sha` would install: the same
    package.json and bun.lock (or neither), and each file: dependency's folder as the commit has it."""
    if not (repo / directory / "node_modules").is_dir():
        return False
    for name in ("package.json", "bun.lock"):
        mine = repo / directory / name
        theirs = subprocess.run(["git", "-C", str(repo), "show", f"{sha}:{directory}/{name}"], capture_output=True)
        if (theirs.returncode == 0) != mine.is_file() or (mine.is_file() and mine.read_bytes() != theirs.stdout):
            return False
    try:
        manifest = json.loads((repo / directory / "package.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    for group in ("dependencies", "devDependencies", "optionalDependencies"):
        for spec in (manifest.get(group) or {}).values():
            if isinstance(spec, str) and spec.startswith(("file:", "link:")):
                target = os.path.relpath((repo / directory / spec.split(":", 1)[1]).resolve(), repo.resolve())
                if target.startswith("..") or subprocess.run(
                        ["git", "-C", str(repo), "diff", "--quiet", sha, "--", target]).returncode != 0:
                    return False
    return True


def load_compare():
    import importlib.util  # noqa: PLC0415  (only --new-only needs it; the hook's trusted copy never does)
    path = Path(__file__).resolve().parent / "ci" / "fast_gate_webviews_checks.py"
    spec = importlib.util.spec_from_file_location("fast_gate_webviews_checks", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def charge_new_only(repo: Path, base: str, plan: Plan, tree: Path, results: list[Result]) -> None:
    """--new-only: each failed package check runs again on BASE. A red whose every finding BASE has too passes
    with a warning; otherwise the result keeps only the findings it adds."""
    packages = {p.directory: p for p in plan.script_packages}
    failed = [r for r in results if r.returncode != 0 and r.label in packages]
    if not failed:
        return
    compare = load_compare()
    with tree_of(repo, base, sorted({r.label for r in failed})) as base_tree:
        for result in failed:
            if ensure_deps(base_tree, result.label):
                continue  # no base to compare with: the red stays this change's
            compare.generate_strings(base_tree / result.label)
            again = run(result.label, result.command, base_tree / result.label, package_env(base_tree, result.label))
            if again.returncode == 0:
                continue
            new, old = compare.compare(result.output, again.output, str(tree), str(base_tree))
            if old:
                print(f"::warning title=web lint (base)::{result.label}: {result.command}: {len(old)} finding(s) "
                      f"the base {base[:12]} has too", file=sys.stderr)
            if not new and not old:  # both red with no finding to compare: unexplained, so the change's
                new = [f"{result.command} failed (exit {result.returncode}) and printed no finding to compare "
                       "with the base"]
            if not new:
                result.returncode = 0
                continue
            result.output = f"{len(new)} finding(s) this change adds over the base {base[:12]}:\n" + "\n".join(
                f"  {line}" for line in new)


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
    parser.add_argument("--base", help="base ref (default: the push's own range, scripts/cmux-next/push_range.py)")
    parser.add_argument("--head", help="head ref (default: the working tree, uncommitted edits included)")
    parser.add_argument("--fix", action="store_true", help="autofix what the tools can, then re-check")
    parser.add_argument("--pre-push", action="store_true", help="read pre-push stdin (used by the hook)")
    parser.add_argument("--remote", default="origin", help="the pushed remote (the hook's first argument)")
    parser.add_argument("--trusted-scripts-dir", type=Path,
                        help="the installed cmux-next-checks snapshot that holds push_range.py (the hook passes it)")
    parser.add_argument("--dry-run", action="store_true", help="print what would run, run nothing")
    parser.add_argument("--timings", action="store_true", help="print each check's time")
    parser.add_argument("--all", action="store_true",
                        help="run every package check, whatever changed (CI, when the push base is unknown)")
    parser.add_argument("--new-only", action="store_true",
                        help="fail only on findings --base does not have (a pull request merged with its base)")
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
    if args.new_only and (not args.base or args.pre_push or args.fix):
        parser.error("--new-only needs --base and no --pre-push or --fix")
    # One lint per pushed commit, in a tree holding exactly that commit. --fix edits the working tree itself.
    heads: dict[str | None, list[str]] = {}
    if args.base:
        heads[None if args.fix else args.head] = changed_files(repo, args.base, args.head)
    else:
        push_range = load_push_range(args.trusted_scripts_dir.resolve() if args.trusted_scripts_dir else None)
        try:
            if args.pre_push:
                ranges, errors = push_range.pushed_ranges(repo, sys.stdin.read().splitlines(), args.remote)
            else:
                # The working tree (no --head) is linted over the own range of HEAD.
                ranges, errors = [push_range.own_range(repo, args.head or "HEAD", remote=args.remote)], []
        except ValueError as error:  # a git call failed (a commit gone between two reads)
            ranges, errors = [], [str(error)]
        if errors:
            for error in errors:
                print(f"{mode}: cannot tell which commits are this push's own: {error}", file=sys.stderr)
            print(f"{mode}: refused; nothing was linted. Fix the clone as said above and push again.", file=sys.stderr)
            return 1
        for own in ranges:
            head = own.head if args.pre_push else args.head
            heads.setdefault(None if args.fix else head, []).extend(own_files(repo, own, head))

    started = time.monotonic()
    results: list[Result] = []
    for head, changed in heads.items():
        files = sorted(set(changed))
        if args.all:
            files = [f"{package.directory}/package.json" for package in SCRIPT_PACKAGES]
        # Planned from the commit's objects: a full lint tree is written only when something needs linting.
        exists, read = snapshot(repo, head)
        plan = make_plan(repo, files, guard_executed=args.pre_push, exists=exists)
        for directory, risky in plan.untrusted:
            print(f"{mode}: {directory}: not linted here: this push changes code the lint runs "
                  f"({', '.join(risky[:5])}{' …' if len(risky) > 5 else ''}). The `web lint` CI job checks it; "
                  f"run `{FIX_COMMAND}` yourself if you trust this branch.", file=sys.stderr)
        if not plan.script_packages and not plan.eslint_files:
            if args.dry_run:
                print("nothing to lint")
            continue
        if args.dry_run:
            for package in plan.script_packages:
                for build in package.builds:
                    print(f"{build.directory}: install and build, unless current (for {package.directory})")
                print(f"{package.directory}: {' && '.join(check_pieces(repo, package, 'check', read))}")
            for directory, targets in plan.eslint_files.items():
                print(f"{directory}: eslint {' '.join(targets)}")
            continue
        # A package that imports a local build gets its own install in a lint tree: bun copies the build
        # into node_modules, so the checkout's copy holds the checkout's build, not this commit's.
        directories = [p.directory for p in plan.script_packages if not p.builds] + list(plan.eslint_files)
        with tree_of(repo, head, directories) as tree:
            found = run_plan(tree, plan, args.fix, cache=tree == repo)
            if args.new_only:
                charge_new_only(repo, args.base, plan, tree, found)
            results += found
    if not results:
        return 0
    return report(results, time.monotonic() - started, mode, args.timings)

if __name__ == "__main__":
    sys.exit(main())
