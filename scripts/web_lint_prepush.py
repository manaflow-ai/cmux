#!/usr/bin/env python3
"""Run the web lints on what a push (or a working tree) changes.

The pre-push hook (scripts/git-hooks/pre-push) runs a trusted copy of this file;
`scripts/web-lint.sh` runs it by hand, and the `web lint` job of
cmux-next-web-lint.yml runs it on every feat-cmux-next push. One file, so the hook,
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

The trust boundary (docs/contributor-verification.md): the hook runs only check code the push did not change; a
push that changes it is not linted here, and CI's sandboxed `web lint` job is the check for it. "Changed" is
measured from where the pushed commit meets the reviewed branches (<remote>/feat-cmux-next, the remote's HEAD),
not from the branch's last pushed head, so an earlier push of the same branch that changed check code keeps every
later push of it out too (trust_base()). It counts deletes and type changes, and a change to a parent folder of
check code (a folder turned into a symlink). Check code may hold no symlink in the pushed commit, at its paths or
any parent folder (executed_symlinks()). A file directly in a folder above a package, or in a node_modules there,
is check code too: tools search upward for their config (above_package()); and so is a node_modules anywhere, whose
programs and modules tools run (in_node_modules()). Before anything runs every executed folder and every script a check
names must resolve, symlinks followed, to that same path in the tree being linted (escaping_paths()).

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

Hosts that run no heavy checks: a shared agent host or a laptop sets CMUX_LOCAL_HEAVY_CHECKS=0.
There the hook installs nothing, builds nothing, compares nothing against a base, and runs only
an allowlist: `vp fmt --check` exactly (LIGHT_COMMANDS), source-check scripts run as
`python3 [-I] PATH.py` or `bun PATH.ts` from a scripts/ folder the hook guards (light_script;
no -m, -c or bare interpreter), and ESLint on changed web/ files. It resolves `bun run NAME` to NAME's
pieces and runs only the allowlisted ones. Everything else is skipped with a named note: the
type-aware lint and type check (tsgolint, about 9 GB and 5 GB on webviews), every unknown command,
and a package with no node_modules. CI's `web lint` job and the PR's fast gates run them, or
`cmux-ci test` on a build box. Elsewhere, every command this script spawns (installs, builds,
checks) goes through spawn(), which outside CI runs it under `nice` with capped Go threads, Go
heap and Node heap.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import hashlib
import json
import os
import posixpath
import re
import unicodedata
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

ESLINT_EXTENSIONS = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
FIX_COMMAND = "scripts/web-lint.sh --fix"
MIN_SKIP_REASON = 20
# "0" (or false/no/off/skip): this host runs no heavy check. Set by the host, e.g. from a fleet registry.
LOCAL_HEAVY_ENV = "CMUX_LOCAL_HEAVY_CHECKS"
# The only check pieces such a host runs, by their leading words: the formatter's check (Oxfmt, no type
# information), the python3 source checks, and bun running a source-check script from the package's scripts/.
# Exactly these argument lists, and source-check scripts (light_script): `python3 [-I] SCRIPT.py ARGS` or
# `bun SCRIPT.ts ARGS`, where SCRIPT lies in a `scripts/` folder the hook already guards for this package (one of its
# `executed` paths: a push that changes it is never linted by the hook). No `-m`, `-c`, other flags or bare tool.
LIGHT_COMMANDS = (("vp", "fmt", "--check"),)
LIGHT_SCRIPT_TOOLS = {"python3": (".py", ("-I",)), "bun": (".ts", ())}
# `bun run NAME`: a piece that runs another script of the same package.json; resolved, never run as a whole.
SCRIPT_RUNNER = ("bun", "run")
# Characters that make a piece more than one plain command: such a piece is never light.
SHELL_SYNTAX = frozenset(";|&$`()<>*?[]{}~!#'\"\\\n\r\t")
MAX_SCRIPT_DEPTH = 8
# Outside CI every spawned command runs at lower priority with these caps, each only when the caller set none:
# Go threads (tsgolint's checkers run one per thread) and its soft heap goal, and Node's old-space heap.
HEAVY_NICE = 10
HEAVY_GOMEMLIMIT = "6GiB"
HEAVY_NODE_HEAP_MB = 4096


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
    # .npmrc and bunfig.toml: npm and bun read them when they install and build the package.
    inputs=("package.json", "package-lock.json", "bun.lock", "bun.lockb", ".npmrc", "bunfig.toml", "tsconfig.json",
            "src/", "test/", "e2e/"),
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
        # ESLint takes the first eslint.config.{js,mjs,cjs,ts,mts,cts} it finds, Babel (through the Next parser) its
        # own configs, and bun and npm the package's bunfig.toml and .npmrc: all code or settings the lint runs.
        executed=("web/package.json", "web/bun.lock", "web/bunfig.toml", "web/.npmrc",
                  *(f"web/eslint.config.{ext}" for ext in ("js", "mjs", "cjs", "ts", "mts", "cts")),
                  *(f"web/babel.config.{ext}" for ext in ("js", "mjs", "cjs", "json", "ts", "mts", "cts")),
                  *(f"web/.babelrc{ext}" for ext in ("", ".js", ".mjs", ".cjs", ".json"))),
    ),
)
# Source directories of a script package: their files are type-checked and linted, not executed by the check, so
# changing them is safe in the hook; except the ones check code imports, which are check code (executed_sources()).
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


def fold(path: str) -> str:
    """PATH as a case-insensitive, normalization-insensitive file system (macOS) sees it: two paths with one fold
    are one file there, so the trust checks compare folds."""
    normal = unicodedata.normalize("NFC", path)
    # HFS+ ignores some format characters (U+200C, U+FEFF ...) in names: drop every one of that category.
    return "".join(char for char in normal if unicodedata.category(char) != "Cf").casefold()


def folded(prefixes: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(fold(p) for p in prefixes)


def above(path: str, prefixes: tuple[str, ...]) -> bool:
    """PATH is a parent folder of one of PREFIXES: changing it (a folder turned into a symlink) changes them."""
    return any(p.startswith(f"{path.rstrip('/')}/") and p.rstrip("/") != path.rstrip("/") for p in prefixes)


def folders_above(directories: tuple[str, ...]) -> tuple[str, ...]:
    """The folders above each of DIRECTORIES, up to the repository root ("")."""
    found = []
    for directory in directories:
        parts = directory.strip("/").split("/")
        found += ["/".join(parts[:n]) for n in range(len(parts))]
    return tuple(dict.fromkeys(found))


def above_package(path: str, directories: tuple[str, ...]) -> bool:
    """PATH lies directly in a folder above one of DIRECTORIES, or in a node_modules there. Tools search upward from
    a package for what they load: Vite a PostCSS config up to the workspace root (which a root package.json or
    pnpm-workspace.yaml moves), TypeScript and bun their configs, Node node_modules. So every such file is check
    code; no push to these folders' own files is common (2 in 410 web pushes, both .gitignore)."""
    path = fold(path)
    for folder in folded(folders_above(directories)):
        inside = path[len(folder) + 1:] if folder else path
        if folder and not path.startswith(f"{folder}/"):
            continue
        if "/" not in inside or inside.startswith("node_modules/"):
            return True
    return False


def in_node_modules(path: str) -> bool:
    """PATH, folded, has a node_modules folder in it: whatever it holds, tools run (a package's .bin/eslint, a module a
    bare import finds walking up), so a node_modules a push carries is check code wherever it is."""
    return "node_modules" in fold(path).split("/")[:-1] or fold(path).split("/")[-1] == "node_modules"


def is_check_code(path: str, executed: tuple[str, ...], sources: tuple[str, ...] = (),
                  directories: tuple[str, ...] = ()) -> bool:
    """PATH, folded, is in a node_modules (in_node_modules()), at, inside (outside SOURCES) or a parent folder of an
    EXECUTED path, or directly in a folder above one of DIRECTORIES (the package and its local builds;
    above_package())."""
    if in_node_modules(path) or (directories and above_package(path, directories)):
        return True
    path, executed, sources = fold(path), folded(executed), folded(sources)
    return (under(path, executed) and not under(path, sources)) or above(path, executed)


def package_directories(package) -> tuple[str, ...]:
    """The folders a package's check runs tools in: its own and its local builds'."""
    return (package.directory, *(build.directory for build in getattr(package, "builds", ())))


def executed_changes(package: ScriptPackage, files: list[str]) -> list[str]:
    sources = tuple(f"{package.directory}/{d}" for d in SOURCE_DIRS)
    return [path for path in files if is_check_code(path, package.executed, sources, package_directories(package))]


def eslint_executed_changes(package: EslintPackage, files: list[str]) -> list[str]:
    executed = folded(package.executed)
    return [f for f in files if fold(f) in executed or above(fold(f), executed) or in_node_modules(f)
            or above_package(f, package_directories(package))]


# The branches whose history is reviewed: check code that matches where a pushed commit meets one of them is
# reviewed code. The remote's HEAD (main) counts too, for a main-based branch. Only on a reviewed remote
# (reviewed_remotes()): a fork's feat-cmux-next is whatever its owner pushed.
REVIEWED_BRANCHES = ("feat-cmux-next", "HEAD")
REVIEWED_URL = re.compile(r"^(?:(?:https|ssh|git)://(?:[^@/]+@)?|[^@/:]+@)github\.com[:/]manaflow-ai/cmux(?:\.git)?/?$")
# `git config --add cmux.reviewedRemote NAME`: a remote of this clone whose branches are reviewed though its URL is not
# manaflow-ai/cmux's (a mirror). Local config, which no push can set.
REVIEWED_REMOTE_CONFIG = "cmux.reviewedRemote"
# A branch more commits than this past where it meets feat-cmux-next is not based on it (a main-based branch): the
# remote's HEAD may then meet it nearer. Counted with a cap, so a feat-based push pays for its own commits only.
FAR = 2000


def reviewed_remotes(repo: Path) -> list[str]:
    """The remotes of this clone whose branches are reviewed: those whose URL is manaflow-ai/cmux, and the ones local
    config names (REVIEWED_REMOTE_CONFIG). Never the pushed remote for being pushed to."""
    names = git(repo, "remote", check=False).split()
    reviewed = [name for name in names
                if REVIEWED_URL.search(git(repo, "remote", "get-url", name, check=False).strip())]
    configured = git(repo, "config", "--get-all", REVIEWED_REMOTE_CONFIG, check=False).split()
    return list(dict.fromkeys(reviewed + [name for name in configured if name in names]))


def trust_base(repo: Path, head: str) -> str | None:
    """Where HEAD meets a reviewed branch of a reviewed remote, or None when this clone has none (the caller then
    fails closed). The hook measures check-code changes from here, never from the branch's own last pushed head nor
    from the pushed remote's branches. Any such merge base holds only reviewed code, so the choice changes how much
    the hook lints, never what it trusts: feat-cmux-next first (one cheap merge base), the remote's HEAD only for a
    branch far past it or a clone without it."""
    found = []
    for branch in REVIEWED_BRANCHES:
        for remote in reviewed_remotes(repo):
            ref = f"refs/remotes/{remote}/{branch}"
            if subprocess.run(["git", "-C", str(repo), "rev-parse", "-q", "--verify", f"{ref}^{{commit}}"],
                              capture_output=True).returncode != 0:
                continue
            base = git(repo, "merge-base", head, ref, check=False).strip()
            if not base:
                continue
            distance = len(git(repo, "rev-list", f"--max-count={FAR}", f"{base}..{head}").split())
            if distance < FAR:
                return base
            found.append((distance, base))
    return min(found)[1] if found else None


def trust_files(repo: Path, base: str, head: str) -> list[str]:
    """Every path that differs between BASE and HEAD: added, changed, deleted or changed in type (a file or folder
    turned into a symlink), so no change to check code hides from executed_changes()."""
    return sorted(set(n for n in git(repo, "diff", "--name-only", "--no-renames", base, head).splitlines() if n))


SYMLINK_MODE = "120000"


def executed_symlinks(repo: Path, sha: str, executed: tuple[str, ...], sources: tuple[str, ...] = (),
                      directories: tuple[str, ...] = ()) -> list[str]:
    """The symlinks commit SHA holds at check code: at an EXECUTED path, inside one (outside SOURCES, which the
    check never runs), or at a parent folder of one. One `git ls-tree` over their top-level folders."""
    links = tree_symlinks(repo, sha)
    candidates = [path for path in links if is_check_code(path, executed, sources, directories)]
    if not candidates:
        return []
    # A link at check code is safe only when it points at another file that is itself check code (inside the
    # repository, not a link): any change to that target is then a change to check code (AGENTS.md -> CLAUDE.md).
    names = set(links)
    files = CommitFiles(repo, sha)
    try:
        found = []
        for path in candidates:
            target_text = (files.read(path) or b"").decode("utf-8", "surrogateescape")
            target = posixpath.normpath(posixpath.join(posixpath.dirname(path), target_text))
            if (target_text.startswith("/") or target.startswith("../") or target == ".." or target in names
                    or files.read(target) is None or not is_check_code(target, executed, sources, directories)):
                found.append(path)
    finally:
        files.close()
    return sorted(found)


_LISTINGS: dict[tuple[str, str], tuple[list[str], list[str]]] = {}


def tree_listing(repo: Path, sha: str) -> tuple[list[str], list[str]]:
    """(every symlink, every path in a node_modules) of commit SHA, from one `git ls-tree -r` of the whole tree kept
    per commit: git's pathspecs can't match a folder whose case differs, so the trust checks filter the full list
    with fold(). Raises when git fails: an empty list must mean none, never that the listing failed."""
    key = (str(repo), sha)
    if key not in _LISTINGS:
        listed = subprocess.run(["git", "-C", str(repo), "ls-tree", "-r", "-z", sha], capture_output=True)
        if listed.returncode != 0:
            raise SystemExit(f"web-lint: git ls-tree {sha} failed: {listed.stderr.decode(errors='replace').strip()}")
        entries = [entry for entry in listed.stdout.decode("utf-8", "surrogateescape").split("\0") if entry]
        _LISTINGS[key] = ([entry.partition("\t")[2] for entry in entries if entry.split(" ", 1)[0] == SYMLINK_MODE],
                          [entry.partition("\t")[2] for entry in entries if in_node_modules(entry.partition("\t")[2])])
    return _LISTINGS[key]


def tree_symlinks(repo: Path, sha: str) -> list[str]:
    """Every symlink in commit SHA (tree_listing())."""
    return tree_listing(repo, sha)[0]


def tracked_node_modules(repo: Path, sha: str, directories: tuple[str, ...]) -> list[str]:
    """The node_modules paths commit SHA tracks in a package folder in DIRECTORIES, under it, or in a folder above
    it: what that package's tools would run. Always refused, whatever a reviewed branch holds (none does)."""
    found = []
    for path in tree_listing(repo, sha)[1]:
        folded_path = fold(path)
        inside = any(folded_path.startswith(f"{fold(d)}/") for d in directories)
        if inside or above_package(path, directories):
            found.append(path)
    return sorted(found)


JS_EXTENSIONS = (".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs")
# What a module names as code it loads: an import or export from, a side-effect import, import(), require() and
# new URL(..., import.meta.url) (a loader path handed to a tool), with a quoted literal.
IMPORT_SPEC = re.compile(r"""(?:\bfrom|(?<![@\w.$])import|\brequire\s*\(|\bimport\s*\(|\bnew\s+URL\s*\()\s*(["'`])([^"'`\n]+)\1""")
# import(...) or require(...) of anything but one plain string literal (a name built with + or ${} too): the module
# it loads can't be told from the source.
COMPUTED_IMPORT = re.compile(r"""(?<![@\w.$])(?:import|require)\s*\(\s*(?!(["'])[^"'\n]*\1\s*[,)])(?!`[^`$\n]*`\s*[,)])""")
# A line that is all comment: an import() it mentions loads nothing.
COMMENT_LINE = re.compile(r"^\s*(?://|/\*|\*)")
# In a JSON config a tool reads (an Oxlint `jsPlugins` list): a relative path string names a module it loads.
JSON_MODULE = re.compile(r'"(\.{1,2}/[^"\n]+(?:%s))"' % "|".join(re.escape(e) for e in JS_EXTENSIONS))
LIFECYCLE_SCRIPTS = ("preinstall", "install", "postinstall", "prepare")
MAX_CLOSURE = 5000


class CommitFiles:
    """The files of commit SHA, read from git objects with one `git cat-file --batch` (never a checkout)."""

    def __init__(self, repo: Path, sha: str):
        self.sha = sha
        self.process = subprocess.Popen(["git", "-C", str(repo), "cat-file", "--batch"], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE)
        self.cache: dict[str, bytes | None] = {}

    def read(self, path: str) -> bytes | None:
        """PATH's content in the commit, or None when it is no file there (through a symlinked folder neither)."""
        if path not in self.cache:
            self.process.stdin.write(f"{self.sha}:{path}\n".encode("utf-8", "surrogateescape"))
            self.process.stdin.flush()
            line = self.process.stdout.readline()
            if not line:  # git died: never read that as "no such file"
                raise SystemExit(f"web-lint: git cat-file stopped while reading {self.sha}; nothing was linted")
            header = line.split()
            if len(header) == 3 and header[1] == b"blob":
                data = self.process.stdout.read(int(header[2]))
                self.process.stdout.read(1)
                self.cache[path] = data
            else:
                if len(header) == 3:  # a tree or commit: skip its body
                    self.process.stdout.read(int(header[2]) + 1)
                self.cache[path] = None
        return self.cache[path]

    def close(self) -> None:
        self.process.stdin.close()
        self.process.wait()


def package_entry_points(text: str) -> list[str]:
    """The files a folder's package.json names as what importing the folder loads (main, module, browser, exports),
    as specifiers relative to the package.json; an unreadable one names none (its folder's index files still count)."""
    try:
        manifest = json.loads(text)
    except ValueError:
        return []
    found = []

    def walk(value):
        if isinstance(value, str):
            found.append(value if value.startswith(("./", "../")) else f"./{value}")
        elif isinstance(value, dict):
            for item in value.values():
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)
    if isinstance(manifest, dict):
        for key in ("main", "module", "browser", "exports"):
            walk(manifest.get(key))
    return found


def module_candidates(importer: str, spec: str) -> list[str]:
    """The repository paths a relative SPEC in IMPORTER may load: every file Node, bun, Vite or TypeScript may try
    (a folder's package.json is read for the files it names)."""
    path = posixpath.normpath(posixpath.join(posixpath.dirname(importer), spec.split("?", 1)[0]))
    found = [path, *(path + ext for ext in JS_EXTENSIONS), f"{path}/package.json",
             *(f"{path}/index{ext}" for ext in JS_EXTENSIONS)]
    for js, typed in ((".js", (".ts", ".tsx")), (".mjs", (".mts",)), (".cjs", (".cts",)), (".jsx", (".tsx",))):
        if path.endswith(js):
            found += [path[:-len(js)] + ext for ext in typed]
    return found


def executed_sources(repo: Path, sha: str, package: ScriptPackage, scripts: dict) -> tuple[set[str], list[str]]:
    """(the folded paths of every file the package's check code loads as a module in commit SHA, the reasons the hook
    can't trust that set). It starts from the files the check and fix scripts and the install lifecycle scripts name,
    and the config files the tools load from the package folder (`*.config.*`), and follows every relative import,
    export, import(), require() and new URL() literal, and every module path a JSON config names. A computed
    import(), a `#` import, or a module in the set that is a symlink or sits below one makes the set untrustworthy."""
    entries = set()
    for script in ("check", "check:fix", *LIFECYCLE_SCRIPTS):
        entries.update(named_scripts(package, scripts, script))
    top = git(repo, "ls-tree", "-z", "--name-only", sha, "--", f"{package.directory}/")
    entries.update(name for name in top.split("\0") if re.search(r"\.config\.[cm]?[jt]s$", name))
    files = CommitFiles(repo, sha)
    reached, problems, unresolved = set(), [], set()
    todo = sorted(e for e in entries if e.endswith(JS_EXTENSIONS + (".json",)))
    try:
        while todo and len(reached) < MAX_CLOSURE:
            path = todo.pop()
            if path in reached:
                continue
            data = files.read(path)
            if data is None:
                unresolved.add(path)
                continue
            reached.add(path)
            text = data.decode("utf-8", "replace")
            if path.endswith("/package.json"):
                specs = package_entry_points(text)
            elif path.endswith(".json"):
                specs = JSON_MODULE.findall(text)
            else:
                # The raw text, comments too: a literal in a comment only adds a module, never hides one (a regex
                # literal that looks like a comment opener can't blank code). An import() whose argument is not one
                # literal refuses the package, unless its line is all comment.
                specs = [match.group(2) for match in IMPORT_SPEC.finditer(text)]
                if any(COMPUTED_IMPORT.search(line) and not COMMENT_LINE.match(line) for line in text.splitlines()):
                    problems.append(f"{path} (loads a module whose name is computed)")
            for spec in specs:
                if spec.startswith("#"):
                    problems.append(f"{path} (loads {spec}, a package import the hook does not follow)")
                elif spec.startswith(("./", "../")):
                    # Every candidate that exists, not only the first: resolvers try them in different orders (Vite
                    # .mjs before .ts), so a file a push adds beside the one this walk would pick is reached too.
                    candidates = module_candidates(path, spec)
                    hits = [c for c in candidates if files.read(c) is not None]
                    todo += hits
                    if not hits:
                        unresolved.add(candidates[0])
        if todo:
            problems.append(f"{package.directory} (its check code loads more than {MAX_CLOSURE} modules)")
    finally:
        files.close()
    # A module that is a symlink, or a path that resolves to no file because a folder above it is one.
    wanted = {fold(p) for p in reached | unresolved}
    wanted |= {"/".join(p.split("/")[:n]) for p in wanted for n in range(1, p.count("/") + 1)}
    problems += [f"{name} (a symlink check code reaches)" for name in tree_symlinks(repo, sha) if fold(name) in wanted]
    return {fold(p) for p in reached}, problems


def escaping_paths(tree: Path, paths: list[str]) -> list[str]:
    """The PATHS (relative to TREE) that do not resolve, symlinks followed, to that same path in TREE: run from
    there, they would run something other than the tree's own reviewed file. A path the tree lacks is skipped."""
    root = Path(os.path.realpath(tree))
    escaped = []
    for rel in paths:
        lexical = Path(os.path.normpath(tree / rel))
        if not os.path.lexists(lexical):
            continue
        if Path(os.path.realpath(lexical)) != root / os.path.normpath(rel):
            escaped.append(rel)
    return escaped


def named_scripts(package: ScriptPackage, scripts: dict, script: str = "check") -> list[str]:
    """The repository paths of the files SCRIPT's pieces name (each `bun run NAME` resolved, as light_leaves()
    does), for escaping_paths(): every word of a piece that names a file of the package or above it."""
    found, seen, todo = [], set(), [script]
    while todo:
        name = todo.pop()
        if name in seen:
            continue
        seen.add(name)
        body = scripts.get(f"{name}:pieces") or scripts.get(name)
        if not isinstance(body, str):
            continue
        for piece in (p.strip() for p in body.split("&&") if p.strip()):
            try:
                words = shlex.split(piece)
            except ValueError:
                words = piece.split()
            if tuple(words[:2]) == SCRIPT_RUNNER and len(words) == 3:
                todo.append(words[2])
                continue
            for word in words[1:]:
                if "/" in word or word.endswith((".py", ".ts", ".mjs", ".js", ".sh", ".json")):
                    path = posixpath.normpath(posixpath.join(package.directory, word))
                    if not path.startswith("../") and not path.startswith("/"):
                        found.append(path)
    return sorted(set(found))


def snapshot(repo: Path, sha: str | None):
    """(exists, read) for repository paths in commit `sha`, from git objects, so a plan needs no checkout;
    the working tree for None."""
    if sha is None:
        return (lambda rel: (repo / rel).is_file()), (lambda rel: (repo / rel).read_text(encoding="utf-8"))
    directories = [p.directory for p in SCRIPT_PACKAGES] + [p.directory for p in ESLINT_PACKAGES]
    names = set(git(repo, "ls-tree", "-r", "--name-only", sha, "--", *directories).splitlines())
    return names.__contains__, (lambda rel: git(repo, "show", f"{sha}:{rel}"))


def make_plan(repo: Path, files: list[str], guard_executed: bool, exists=None, trusted_files: list[str] | None = None,
              sha: str | None = None, read=None) -> Plan:
    """What to lint for FILES. With GUARD_EXECUTED (the hook), a package whose check code TRUSTED_FILES (default:
    FILES; the hook passes every path changed since trust_base()) changes, or whose check code commit SHA holds a
    symlink at, is not linted: the hook never runs code a push controls."""
    exists = exists or (lambda rel: (repo / rel).is_file())
    trusted_files = files if trusted_files is None else trusted_files
    plan = Plan()
    for package in SCRIPT_PACKAGES:
        if not exists(f"{package.directory}/package.json"):
            continue
        if not any(under(f, package.triggers) for f in files):
            continue
        risky = executed_changes(package, trusted_files) if guard_executed else []
        if guard_executed and sha:
            sources = tuple(f"{package.directory}/{d}" for d in SOURCE_DIRS)
            risky += [f"{path} (a symlink)" for path in
                      executed_symlinks(repo, sha, package.executed, sources, package_directories(package))]
            risky += [f"{path} (a tracked node_modules)" for path in
                      tracked_node_modules(repo, sha, package_directories(package)) if path not in risky]
            loaded, problems = executed_sources(repo, sha, package, package_scripts(repo, package, read))
            risky += [f for f in trusted_files if fold(f) in loaded and f not in risky] + problems
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
        risky = eslint_executed_changes(package, trusted_files) if guard_executed else []
        if guard_executed and sha:
            risky += [f"{path} (a symlink)" for path in
                      executed_symlinks(repo, sha, package.executed, (), package_directories(package))]
            risky += [f"{path} (a tracked node_modules)" for path in
                      tracked_node_modules(repo, sha, package_directories(package)) if path not in risky]
        if risky:
            plan.untrusted.append((package.directory, risky))
        else:
            plan.eslint_files[package.directory] = targets
    return plan


def check_pieces(repo: Path, package: ScriptPackage, script: str, read=None) -> list[str]:
    read = read or (lambda rel: (repo / rel).read_text(encoding="utf-8"))
    scripts = json.loads(read(f"{package.directory}/package.json")).get("scripts", {})
    # webviews' `check` runs its `check:pieces` chain through run-check-pieces.py; the pieces are the list.
    body = scripts.get(f"{script}:pieces") or scripts.get(script)
    if not body:
        return []
    return [piece.strip() for piece in body.split("&&") if piece.strip()]


def package_scripts(repo: Path, package: ScriptPackage, read=None) -> dict[str, str]:
    read = read or (lambda rel: (repo / rel).read_text(encoding="utf-8"))
    try:
        scripts = json.loads(read(f"{package.directory}/package.json")).get("scripts", {})
    except (OSError, ValueError, SystemExit):
        return {}
    return scripts if isinstance(scripts, dict) else {}


def light_argv(piece: str) -> list[str] | None:
    """PIECE as an argument list, or None when it holds anything a shell would read as more than one plain
    command (`;`, `|`, `&`, `$`, backticks, redirections, globs, quotes, escapes, newlines). An allowlisted piece
    runs as this list with no shell, so nothing after its leading words can start another command."""
    if any(ch in SHELL_SYNTAX for ch in piece):
        return None
    try:
        return shlex.split(piece)
    except ValueError:
        return None


def light_script(package: ScriptPackage, argv: list[str]) -> bool:
    """ARGV runs a source-check script: `python3 [-I] PATH.py ARGS` or `bun PATH.ts ARGS`, PATH (relative to the
    package) inside a `scripts/` folder, and a path the hook refuses to lint when a push changes it: the same
    executed_changes() test the hook applies, so a script under the package's src/, test/ or tests/ (which a push
    may change and still be linted) is never light (review of bead8b5: `bun src/scripts/evil.ts`)."""
    tool = LIGHT_SCRIPT_TOOLS.get(argv[0]) if argv else None
    if tool is None:
        return False
    suffix, flags = tool
    rest = argv[1:]
    while rest and rest[0] in flags:
        rest = rest[1:]
    if not rest or rest[0].startswith("-") or not rest[0].endswith(suffix):
        return False
    if rest[0].startswith("/"):
        return False
    path = posixpath.normpath(posixpath.join(package.directory, rest[0]))
    return (not path.startswith("../") and "scripts" in path.split("/")[:-1]
            and executed_changes(package, [path]) == [path])


def is_light(piece: str, package: ScriptPackage) -> bool:
    """PIECE is on the allowlist a host that runs no heavy checks runs, as one plain command: an exact
    LIGHT_COMMANDS list or a guarded source-check script (light_script)."""
    argv = light_argv(piece)
    if not argv:
        return False
    return tuple(argv) in LIGHT_COMMANDS or light_script(package, argv)


def light_leaves(package: ScriptPackage, pieces: list[str], scripts: dict[str, str],
                 depth: int = 0) -> tuple[list[str], list[str]]:
    """(the allowlisted commands PIECES come to, the rest): `bun run NAME` is replaced by NAME's own pieces
    (`NAME:pieces` when it has one); an unknown or too deep NAME is in the rest, whole."""
    light, rest = [], []
    for piece in pieces:
        words = piece.split()
        if tuple(words[:2]) == SCRIPT_RUNNER and len(words) == 3:
            # A NAME run through run-check-pieces.py (webviews' `check`) is resolved to its `NAME:pieces` chain,
            # as check_pieces() does, never run whole as one opaque runner command.
            body = scripts.get(f"{words[2]}:pieces") or scripts.get(words[2])
            if isinstance(body, str) and depth < MAX_SCRIPT_DEPTH:
                inner = light_leaves(package, [p.strip() for p in body.split("&&") if p.strip()], scripts, depth + 1)
                light += inner[0]
                rest += inner[1]
                continue
        (light if is_light(piece, package) else rest).append(piece)
    return light, rest


def light_pieces(repo: Path, package: ScriptPackage, script: str, mode: str, read=None) -> list[str]:
    """The allowlisted commands package SCRIPT comes to, saying which pieces this host leaves to CI."""
    light, rest = light_leaves(package, check_pieces(repo, package, script, read), package_scripts(repo, package, read))
    if rest:
        print(f"{mode}: {package.directory}: not run on this host ({LOCAL_HEAVY_ENV}=0): {', '.join(rest)}. "
              "CI's `web lint` job and the pull request's fast gates run them; to run them before the push, "
              f"use a build box: cmux-ci test -- bash -c 'cd {package.directory} && bun install --frozen-lockfile "
              f"&& bun run {script}'.", file=sys.stderr)
    return light


def local_heavy_checks() -> bool:
    """False when the host said it runs no heavy piece (CMUX_LOCAL_HEAVY_CHECKS=0). CI always runs every piece:
    a runner that inherits the host setting still runs the full type-aware check."""
    if in_ci():
        return True
    return os.environ.get(LOCAL_HEAVY_ENV, "").strip().lower() not in ("0", "false", "no", "off", "skip")


def in_ci() -> bool:
    return os.environ.get("GITHUB_ACTIONS") == "true" or os.environ.get("CI", "").lower() in ("1", "true")


def capped_env(env: dict[str, str] | None) -> dict[str, str]:
    """ENV outside CI: half the cores (at most 8) for Go, a soft Go heap goal, a capped Node heap. A value the
    caller already set is kept."""
    env = dict(os.environ if env is None else env)
    env.setdefault("GOMAXPROCS", str(max(1, min(8, (os.cpu_count() or 2) // 2))))
    env.setdefault("GOMEMLIMIT", HEAVY_GOMEMLIMIT)
    node = env.get("NODE_OPTIONS", "")
    if "--max-old-space-size" not in node:
        env["NODE_OPTIONS"] = f"{node} --max-old-space-size={HEAVY_NODE_HEAP_MB}".strip()
    return env


def spawn(command: list[str] | str, cwd: Path, env: dict[str, str] | None):
    """The one way this script starts a tool (git aside): installs, builds and checks alike. Outside CI it runs
    under `nice` with capped_env, so no path spawns an uncapped type check or build."""
    if not in_ci():
        env = capped_env(env)
        nice = shutil.which("nice")
        if nice:
            # A shell string runs as `nice sh -c STRING`: the shell itself is niced, so a leading VAR=value and every
            # command of a compound string keep their meaning and inherit the priority.
            argv = ["/bin/sh", "-c", command] if isinstance(command, str) else list(command)
            return subprocess.run([nice, "-n", str(HEAVY_NICE), *argv], cwd=cwd, env=env, text=True,
                                  capture_output=True)
    return subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True,
                          shell=isinstance(command, str))


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
        return spawn(command, cwd, env)
    finally:
        if not had_lock:
            lock.unlink(missing_ok=True)


@dataclass(frozen=True)
class TreeState:
    """What the tree a run happens in holds before it starts: setup_steps() reads it, so a --dry-run plans the run's
    own tree. in_place_state() reads a real tree; lint_tree_state() predicts the fresh worktree tree_of() makes."""

    locked: Callable[[str], bool]  # the area has a bun.lock
    has_modules: Callable[[str], bool]  # the area has node_modules (its own, or the checkout's linked in)
    build_current: Callable[[LocalBuild], bool]  # the local build's output was built from its current inputs
    installed: Callable[[str, LocalBuild], str | None]  # the build digest the area's node_modules copy came from


def in_place_state(repo: Path) -> TreeState:
    return TreeState(locked=lambda d: (repo / d / "bun.lock").is_file(),
                     has_modules=lambda d: (repo / d / "node_modules").is_dir(),
                     build_current=lambda build: build_current(repo, build),
                     installed=lambda d, build: read_stamp(installed_stamp(repo, d, build)))


def lint_tree_state(exists, shared: set[str]) -> TreeState:
    """The fresh worktree of a commit (EXISTS: its files): no build output (dist/ is never committed), and
    node_modules only where tree_of() links the checkout's in (SHARED); a linked copy is never one a build installs
    into (tree_of() does not link a package with local builds on a host that builds)."""
    return TreeState(locked=lambda d: exists(f"{d}/bun.lock"), has_modules=lambda d: d in shared,
                     build_current=lambda build: False, installed=lambda d, build: None)


def deps_command(repo: Path, directory: str, force: bool = False, state: TreeState | None = None) -> list[str] | None:
    """The `bun install` ensure_deps runs for DIRECTORY, or None when it runs none: a package with no lockfile keeps
    the node_modules it has (unless FORCE). `bun` stays a bare name when bun is not on PATH (ensure_deps reports it)."""
    state = state or in_place_state(repo)
    locked = state.locked(directory)
    if not locked and not force and state.has_modules(directory):
        return None
    command = ["install", "--frozen-lockfile", "--silent"] if locked else ["install", "--silent", "--no-save"]
    return [shutil.which("bun") or "bun", *command]


def ensure_deps(repo: Path, directory: str, force: bool = False) -> Result | None:
    """Install the package's pinned dependencies (fast when they are current), with deps_command's command."""
    command = deps_command(repo, directory, force)
    if command is None:
        return None
    if shutil.which(command[0]) is None:  # a relative PATH entry (node_modules/.bin/bun) is a real bun
        return Result(directory, "bun install", 127, "bun is not on PATH; install bun 1.4 to run the web lint.", 0)
    started = time.monotonic()
    result = run_leaving_no_lockfile(command, repo / directory)
    if result.returncode == 0:
        return None
    return Result(directory, f"bun {' '.join(c for c in command[1:] if c != '--silent')}", result.returncode,
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


def build_commands() -> list[list[str]]:
    """The commands ensure_build runs for a local build that is not current: npm's, else bun's; [] without either."""
    npm, bun = shutil.which("npm"), shutil.which("bun")
    if npm:  # what CI runs (cmux-tui.yml, "Build TypeScript SDK")
        return [[npm, "ci", "--no-audit", "--no-fund"], [npm, "run", "build"]]
    if bun:  # tsc's node shebang runs on bun
        return [[bun, "install", "--silent", "--no-save"], [bun, "run", "--bun", "build"]]
    return []


def build_current(repo: Path, build: LocalBuild) -> bool:
    return read_stamp(repo / build.directory / build.output / BUILD_STAMP) == build_digest(repo, build)


def setup_steps(repo: Path, plan: Plan, state: TreeState | None = None) -> list[tuple]:
    """run()-shaped (area, argv) steps prepare_builds() and install() will spawn for PLAN on a host that runs heavy
    checks, in their order, from the same deps_command() and build_commands(), for the tree STATE describes (default:
    REPO as it is): builds that are not current, then each area's install (forced where its copy of a build is
    stale)."""
    state = state or in_place_state(repo)
    steps, digests = [], {}
    for package in plan.script_packages:
        for build in package.builds:
            if build in digests:
                continue
            digests[build] = build_digest(repo, build)
            if not state.build_current(build):
                commands = build_commands()
                if not commands:  # ensure_build() fails here and the run stops: nothing after it runs
                    return [(build.directory, f"{NO_BUILD_TOOL}: refused, no check runs")]
                steps += [(build.directory, step) for step in commands]
    for directory in [p.directory for p in plan.script_packages] + list(plan.eslint_files):
        package = next((p for p in plan.script_packages if p.directory == directory), None)
        stale = package is not None and any(state.installed(directory, build) != digests[build]
                                            for build in package.builds)
        command = deps_command(repo, directory, force=stale, state=state)
        if command:
            steps.append((directory, command))
    return steps


NO_BUILD_TOOL = "neither npm nor bun is on PATH"


def ensure_build(repo: Path, build: LocalBuild, dependents: list[str]) -> tuple[str | None, Result | None]:
    """Install and build `build` unless its output was built from the same inputs; returns (the digest of
    its inputs, failure). A failure is one Result that names the build and the checks it holds back."""
    root = repo / build.directory
    stamp = root / build.output / BUILD_STAMP
    digest = build_digest(repo, build)
    if build_current(repo, build):  # setup_steps() asks the same
        return digest, None
    held = f"Not checked until this builds: {', '.join(dependents)} (it imports {build.name} from this build)."
    steps = build_commands()
    if not steps:
        return None, Result(build.directory, "npm ci && npm run build", 127,
                             f"{NO_BUILD_TOOL}, so {build.directory} can't be built.\n{held}", 0)
    stamp.unlink(missing_ok=True)
    started = time.monotonic()
    env = package_env(repo, build.directory)
    for step in steps:  # spawn() nices and caps them outside CI: the build is tsc
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


def run(label: str, command: list[str] | str, cwd: Path, env: dict[str, str], shown: str | None = None) -> Result:
    started = time.monotonic()
    result = spawn(command, cwd, env)
    if shown is None:
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


def light_plan(repo: Path, plan: Plan, mode: str, has_modules=None) -> Plan:
    """PLAN for a host that runs no heavy check: no package is installed or built, so one with no node_modules yet
    (HAS_MODULES(directory), default: in REPO) is dropped with a note (CI checks it), and a package's local builds
    are skipped, said once."""
    has_modules = has_modules or (lambda directory: (repo / directory / "node_modules").is_dir())
    kept = Plan(untrusted=plan.untrusted)
    ci = f"CI's `web lint` job and the pull request's fast gates check it ({LOCAL_HEAVY_ENV}=0: no install or build here)"
    for package in plan.script_packages:
        if not has_modules(package.directory):
            print(f"{mode}: {package.directory}: not linted here, it has no node_modules; {ci}.", file=sys.stderr)
            continue
        for build in package.builds:
            print(f"{mode}: {build.directory}: not built here, so {package.directory} is checked against the "
                  f"bindings it already has; {ci}.", file=sys.stderr)
        kept.script_packages.append(package)
    for directory, files in plan.eslint_files.items():
        if not has_modules(directory):
            print(f"{mode}: {directory}: not linted here, it has no node_modules; {ci}.", file=sys.stderr)
            continue
        kept.eslint_files[directory] = files
    return kept


def check_jobs(repo: Path, plan: Plan, script: str, fix: bool, cache: bool, heavy: bool, mode: str,
               read=None) -> list[tuple]:
    """run()'s arguments for every command of PLAN's SCRIPT ("check" or "check:fix") and its ESLint runs: shell
    strings, or with heavy checks off the allowlisted pieces as argument lists (no shell). The one list both a run
    and a --dry-run use. With heavy checks off, PLAN is already light_plan()'s."""
    jobs = []
    for package in plan.script_packages:
        pieces = (check_pieces(repo, package, script, read) if heavy
                  else [light_argv(piece) for piece in light_pieces(repo, package, script, mode, read)])
        for piece in pieces:
            jobs.append((package.directory, piece, repo / package.directory, package_env(repo, package.directory)))
    for directory, files in plan.eslint_files.items():
        jobs.append((directory, eslint_command(repo, directory, files, fix, cache), repo / directory,
                     package_env(repo, directory)))
    return jobs


def plan_steps(repo: Path, plan: Plan, fix: bool, cache: bool, heavy: bool, mode: str, read=None,
               state: TreeState | None = None) -> tuple[Plan, list[tuple], list[tuple], list[tuple]]:
    """Everything a run of PLAN does, in order: (the plan it runs, setup steps, fix jobs, check jobs). With heavy
    checks off the plan is light_plan()'s (over the areas STATE says have node_modules) and there is no setup; with
    them on, setup_steps() lists the builds and installs STATE's tree needs (default: REPO as it is). run_plan()
    executes it and --dry-run prints it, so the two can't list different commands."""
    state = state or in_place_state(repo)
    if heavy:
        setup = setup_steps(repo, plan, state)
    else:
        plan, setup = light_plan(repo, plan, mode, state.has_modules), []
    if any(isinstance(step[1], str) for step in setup):  # a build that can't run stops the run (ensure_build)
        return plan, setup, [], []
    fixes = check_jobs(repo, plan, "check:fix", True, cache, heavy, mode, read) if fix else []
    return plan, setup, fixes, check_jobs(repo, plan, "check", False, cache, heavy, mode, read)


def shown(job: tuple) -> str:
    """How a check_jobs() job reads in a --dry-run and in a report: `<area>: <command>`."""
    command = job[1] if isinstance(job[1], str) else shlex.join(job[1])
    return f"{job[0]}: {command}"


def refuse_escapes(tree: Path, plan: Plan, mode: str, read=None) -> bool:
    """Drop from PLAN, saying so, each package whose check code does not resolve to itself in TREE (escaping_paths():
    its executed folders and every file its check names). False when nothing is left to run."""
    kept = []
    for package in plan.script_packages:
        scripts = package_scripts(tree, package, read)
        escaped = escaping_paths(tree, [p.rstrip("/") for p in package.executed]
                                 + named_scripts(package, scripts) + named_scripts(package, scripts, "check:fix"))
        if escaped:
            print(f"{mode}: {package.directory}: not linted here: its check code resolves outside itself in the "
                  f"tree ({', '.join(escaped[:5])}); the hook runs only the tree's own reviewed files. The `web lint` "
                  "CI job checks it.", file=sys.stderr)
        else:
            kept.append(package)
    plan.script_packages = kept
    for directory in list(plan.eslint_files):
        package = next(p for p in ESLINT_PACKAGES if p.directory == directory)
        escaped = escaping_paths(tree, list(package.executed))
        if escaped:
            print(f"{mode}: {directory}: not linted here: its check code resolves outside itself in the tree "
                  f"({', '.join(escaped)}). The `web lint` CI job checks it.", file=sys.stderr)
            del plan.eslint_files[directory]
    return bool(plan.script_packages or plan.eslint_files)


def run_plan(repo: Path, plan: Plan, fix: bool, cache: bool = True, heavy: bool = True,
             mode: str = "web-lint") -> list[Result]:
    # With heavy checks off: no install or build (the bindings build is `npm ci` plus tsc), only the allowlist,
    # against the node_modules a package already has; a package with none is left to CI, named.
    plan, setup, fixes, jobs = plan_steps(repo, plan, fix, cache, heavy, mode)
    # Always, with heavy checks on, even when setup_steps() spawns nothing: prepare_builds() is the build-freshness
    # check, and a stale build that can't be rebuilt must fail here, not let the checks see the old build.
    if heavy:  # the steps setup_steps() listed, run with their stamp bookkeeping
        stale, failures = prepare_builds(repo, plan.script_packages)
        if failures:
            return failures
        directories = [p.directory for p in plan.script_packages] + list(plan.eslint_files)
        with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(directories))) as pool:
            installs = [r for r in pool.map(lambda d: install(repo, d, stale.get(d)), directories) if r]
        if installs:
            return installs
    for job in fixes:
        run(*job)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, min(8, len(jobs)))) as pool:
        return list(pool.map(lambda job: run(*job), jobs))


def in_place_cache(repo: Path, head: str | None) -> bool:
    """ESLint's cache is used only in the checkout itself, as run_plan's caller decides (cache=tree == repo)."""
    return head is None or is_checked_out(repo, head)


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
                if os.path.lexists(tree / directory / "node_modules"):
                    # make_plan() refuses a package whose commit holds a node_modules (in_node_modules()); never link
                    # over one, and never run with it.
                    raise SystemExit(f"web-lint: {sha[:12]} holds {directory}/node_modules, which the lint would "
                                     "run; nothing was linted. The `web lint` CI job checks this commit.")
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


def charge_new_only(repo: Path, base: str, plan: Plan, tree: Path, results: list[Result], heavy: bool = True) -> None:
    """--new-only: each failed package check runs again on BASE. A red whose every finding BASE has too passes
    with a warning; otherwise the result keeps only the findings it adds. A host that runs no heavy checks makes
    no base tree and runs nothing again: every red stays the change's."""
    packages = {p.directory: p for p in plan.script_packages}
    failed = [r for r in results if r.returncode != 0 and r.label in packages]
    if not failed:
        return
    if not heavy:
        print(f"::warning title=web lint::no base comparison on this host ({LOCAL_HEAVY_ENV}=0); every red counts",
              file=sys.stderr)
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
    heavy = local_heavy_checks()
    results: list[Result] = []
    for head, changed in heads.items():
        files = sorted(set(changed))
        if args.all:
            files = [f"{package.directory}/package.json" for package in SCRIPT_PACKAGES]
        # Planned from the commit's objects: a full lint tree is written only when something needs linting.
        exists, read = snapshot(repo, head)
        trusted_files = None
        if args.pre_push and head is not None:
            # Check code is measured from where the commit meets the reviewed branches, never from the branch's last
            # pushed head: an earlier push that changed it keeps this one out too. No reviewed branch in the clone:
            # every own file and, failing closed, every path the commit has.
            base = trust_base(repo, head)
            trusted_files = (trust_files(repo, base, head) if base else
                             git(repo, "ls-tree", "-r", "--name-only", head).splitlines())
        plan = make_plan(repo, files, guard_executed=args.pre_push, exists=exists, trusted_files=trusted_files,
                         sha=head if args.pre_push else None, read=read)
        for directory, risky in plan.untrusted:
            print(f"{mode}: {directory}: not linted here: this push changes, or reaches through a symlink, code the "
                  f"lint runs "
                  f"({', '.join(risky[:5])}{' …' if len(risky) > 5 else ''}). The `web lint` CI job checks it; "
                  f"run `{FIX_COMMAND}` yourself if you trust this branch.", file=sys.stderr)
        if not plan.script_packages and not plan.eslint_files:
            if args.dry_run:
                print("nothing to lint")
            continue
        # A package that imports a local build gets its own install in a lint tree: bun copies the build
        # into node_modules, so the checkout's copy holds the checkout's build, not this commit's.
        # A host that runs no heavy checks builds nothing, so every package may share the checkout's node_modules.
        directories = [p.directory for p in plan.script_packages if not p.builds or not heavy] + list(plan.eslint_files)
        if args.dry_run:
            # The run's own plan_steps(), for the tree it would run in: the checkout as it is, or the fresh lint tree
            # tree_of() makes (no build output, node_modules only where it links the checkout's): setup, fix passes,
            # then checks, one command per line.
            in_place = in_place_cache(repo, head)
            state = in_place_state(repo) if in_place else lint_tree_state(
                exists, {d for d in directories if shares_deps(repo, head, d)})
            _, setup, fixes, jobs = plan_steps(repo, plan, args.fix, in_place, heavy, mode, read, state)
            for job in setup + fixes + jobs:
                print(shown(job))
            continue
        with tree_of(repo, head, directories) as tree:
            if args.pre_push and not refuse_escapes(tree, plan, mode, read):
                continue
            found = run_plan(tree, plan, args.fix, cache=tree == repo, heavy=heavy, mode=mode)
            if args.new_only:
                charge_new_only(repo, args.base, plan, tree, found, heavy)
            results += found
    if not results:
        return 0
    return report(results, time.monotonic() - started, mode, args.timings)

if __name__ == "__main__":
    sys.exit(main())
