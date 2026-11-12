#!/usr/bin/env python3
"""A pull request's red `cargo test` run, judged per test: a flake, the base's red, or the change's own.

cmux-tui-spec.yml's `acpmux tests` job runs acpmux's lib tests and hub_integration on every pull request that
touches acpmux. Before it, those suites ran only in Fast checks and the fleet, so #27921 and #27868 landed red tests
and base stayed red for hours (2026-10-30). When the head's run is red, the job runs each failing test again alone
on the head (the retry) and on the merge parent (the base), then asks this script:

    git diff --name-only BASE HEAD | cargo_test_verdict.py touches cmux-tui/crates/acpmux
        whether the change touches the crate's inputs: its directory, every path dependency's (followed through
        `workspace = true` to the workspace's table), the files they include_str!/include_bytes! from elsewhere,
        and the workspace manifest, lockfile, toolchain and this job's own files. Prints the touched paths and
        exits 0, or exits 1 when none is touched.
    cargo_test_verdict.py failed HEAD.log
        prints the head's failing test names, one per line, for the retry and the base replay.
    cargo_test_verdict.py judge --head HEAD.log [--retry RETRY.log] [--base BASE.log] [--job NAME]
        prints GitHub annotations and exits 0 when no red is the change's own, 1 when one is.

The verdict:
- A test that failed on the head and passed when run again alone is a flake: it warns.
- The rest are judged by scripts/ci/test_reds.py, the one per-test classifier for "red on the base, so not ours":
  a test the base fails too warns as a base red; a test that passes or does not exist on the base, a crash
  (signal, abort) and a cut-short run (a test binary that printed no `test result:`) are the change's own red.
- A red run that names no failing test (a compile error) is the change's own red.
"""
from __future__ import annotations

import argparse
import importlib.util
import posixpath
import re
import sys
import tomllib
from pathlib import Path

_spec = importlib.util.spec_from_file_location("test_reds", Path(__file__).with_name("test_reds.py"))
test_reds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(test_reds)
# By name, never by path: one module object (and one Unreadable class) for a caller that also imports it, such as
# tests/test_base_red_excuse.py, which hands crate_inputs a GitTree of its own.
if str(Path(__file__).resolve().parent) not in sys.path:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
import git_tree  # noqa: E402

# Inputs of every crate in the cmux-tui workspace, and this job's own files.
WORKSPACE = "cmux-tui"
ALWAYS = (
    f"{WORKSPACE}/Cargo.toml", f"{WORKSPACE}/Cargo.lock", f"{WORKSPACE}/rust-toolchain.toml",
    f"{WORKSPACE}/rust-toolchain", f"{WORKSPACE}/.cargo/", ".github/workflows/cmux-tui-spec.yml",
    ".github/actions/setup-cmux-tui-rust/", ".github/actions/runner-cargo-home/",
    "scripts/ci/cargo_test_verdict.py", "scripts/ci/git_tree.py", "scripts/ci/test_reds.py",
    "tests/test_cargo_test_verdict.py",
)
INCLUDE = re.compile(r'include_(?:str|bytes)!\(\s*"([^"]+)"')
DEPENDENCY_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")
PASSED = re.compile(r"^test (\S+) \.\.\. ok$")
FAILED_LINE = re.compile(r"^test (\S+) \.\.\. FAILED$")


def _default_optional(manifest: dict) -> set[str]:
    """The optional dependencies MANIFEST's default features turn on (`dep:x`, `x`, `x/feature`)."""
    features = manifest.get("features", {})
    enabled, queue, seen = set(), list(features.get("default", [])), set()
    while queue:
        item = queue.pop()
        if item in seen:
            continue
        seen.add(item)
        if item.startswith("dep:"):
            enabled.add(item[4:])
        elif "/" in item:
            name = item.split("/", 1)[0]
            if not name.endswith("?"):
                enabled.add(name)
        elif item in features:
            queue += features[item]
        else:
            enabled.add(item)
    return enabled


def _path_dependencies(manifest: dict, crate: str, workspace: str, shared: dict) -> list[str]:
    """The path dependencies a plain `cargo test` of the crate builds: an optional one only when a default feature
    turns it on (acpmux's `hub-carrier` pulls in cmux-remote only when a build asks for it). Repository paths."""
    tables = [manifest.get(name, {}) for name in DEPENDENCY_TABLES]
    tables += [target.get(name, {}) for target in manifest.get("target", {}).values() for name in DEPENDENCY_TABLES]
    default_optional = _default_optional(manifest)
    found = []
    for table in tables:
        for name, spec in table.items():
            if not isinstance(spec, dict):
                continue
            if spec.get("optional") and name not in default_optional:
                continue
            if "path" in spec:
                found.append(posixpath.normpath(posixpath.join(crate, spec["path"])))
            elif spec.get("workspace") and isinstance(shared.get(name), dict) and "path" in shared[name]:
                found.append(posixpath.normpath(posixpath.join(workspace, shared[name]["path"])))
    return found


def _outside(path: str) -> bool:
    """PATH (normalized, from the repository root) leaves the repository: `..` up, or absolute (`path = "/dep"`)."""
    return path == ".." or path.startswith("../") or path.startswith("/")


def _follow(tree, directory: str, relative: str) -> str | None:
    """DIRECTORY/RELATIVE in the tree with each symlink followed before a `..` (as the filesystem resolves it), or
    None when it leaves the repository."""
    if relative.startswith("/"):
        return None  # include_str!("/x") names the filesystem's /x, outside the repository
    try:
        return _walk(tree, directory, relative)
    except git_tree.NeedsFullTree:
        raise
    except git_tree.Unreadable:
        return None  # a symlink out of the tree or a loop: outside the repository, as resolve() left it


def _walk(tree, directory: str, relative: str) -> str | None:
    at = directory
    for part in relative.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            at = tree.real(at) if at else at
            if not at:
                return None
            at = posixpath.dirname(at)
        else:
            at = f"{at}/{part}" if at else part
    if _outside(at):
        return None
    return tree.real(at)


def crate_inputs(repo: Path, crate_dir: str, tree=None) -> tuple[list[str], list[str]]:
    """The directories of CRATE_DIR and of every crate it reaches by path dependency, and the files under none of
    them that their Rust sources include_str!/include_bytes!, all relative to REPO.

    Read from the commit's tree (git_tree.GitTree of REPO at HEAD, or TREE), never the working tree: a sparse
    checkout that leaves a crate's directory out still has the crate (tests/test_base_red_excuse.py's
    SparseTreeReads). So a local run reads committed files only, not uncommitted edits. Raises git_tree.Unreadable when the workspace manifest cannot be read, and its NeedsFullTree
    when a partial clone lacks a blob the answer needs."""
    if tree is None:
        with git_tree.GitTree(repo) as owned:
            return crate_inputs(repo, crate_dir, owned)
    shared = tomllib.loads(tree.text(f"{WORKSPACE}/Cargo.toml")).get("workspace", {}).get("dependencies", {})
    seen: set[str] = set()
    queue = [posixpath.normpath(crate_dir)]
    while queue:
        crate = queue.pop()
        if _outside(crate):
            continue
        crate = tree.real(crate)  # a symlinked crate directory is its target, as Path.resolve gave
        if crate in seen or _outside(crate) or not tree.is_file(f"{crate}/Cargo.toml"):
            continue
        seen.add(crate)
        queue += _path_dependencies(tomllib.loads(tree.text(f"{crate}/Cargo.toml")), crate, WORKSPACE, shared)
    dirs = sorted(seen)
    files = set()
    for crate in seen:
        for source in tree.files(crate, ".rs"):
            for match in INCLUDE.finditer(tree.text(source, errors="replace")):
                included = _follow(tree, posixpath.dirname(source), match.group(1))
                if included is not None:
                    files.add(included)
    return dirs, sorted(path for path in files if not any(path.startswith(f"{d}/") for d in dirs))


def touches(repo: Path, crate_dir: str, changed: list[str]) -> list[str]:
    """The changed paths that are inputs of CRATE_DIR's tests."""
    dirs, files = crate_inputs(repo, crate_dir)
    prefixes = tuple(f"{d}/" for d in dirs) + tuple(p for p in ALWAYS if p.endswith("/"))
    exact = set(files) | {p for p in ALWAYS if not p.endswith("/")}
    return [path for path in changed if path in exact or path.startswith(prefixes)]


def read_text(path: Path | None) -> str | None:
    """The log at PATH, its colour codes stripped here, once, so no parser of it sees raw colour (#41329's review F2)."""
    if path is None or not path.exists():
        return None
    return test_reds.plain(path.read_text(errors="replace"))


def failed_names(log: str) -> list[str]:
    return sorted(test_reds.read(log).failed)


def passed_names(log: str | None) -> set[str]:
    if not log:
        return set()
    return {m.group(1) for line in test_reds.lines_of(log) for m in [PASSED.match(line)] if m}


# A binary's closing line, its counts rewritten when its flakes are taken out (without_failures).
RESULT_COUNTS = re.compile(r"test result: FAILED\. (\d+) passed; (\d+) failed;")


def without_failures(log: str, names: set[str]) -> str:
    """The head's log with the FAILED lines of NAMES taken out: its crashes and cut-short binaries still count. Each
    binary's `test result:` line counts them as passed, so its total still matches the failures it names: test_reds
    reads a total above its names as a failure no parser names (cmux#41244), which a flake that passed alone is not.
    Every line is matched as test_reds reads it (log_lines: no stamp, no colour), and a rewritten summary is written
    in that form: matched on the raw line, colour around FAILED kept the count while its name went (#41329's review
    F2)."""
    raw = log.splitlines()
    texts = test_reds.log_lines(log)  # one per raw line
    skip = test_reds.echoed(texts)
    kept, taken = [], 0
    for n, (line, text) in enumerate(zip(raw, texts)):
        if n in skip:
            kept.append(line)
            continue
        if (match := FAILED_LINE.match(text)) and match.group(1) in names:
            taken += 1
            continue
        if text.startswith("test result: "):
            if taken and (counts := RESULT_COUNTS.search(text)):
                passed, failed = int(counts.group(1)) + taken, max(int(counts.group(2)) - taken, 0)
                state = "FAILED" if failed else "ok"
                line = RESULT_COUNTS.sub(f"test result: {state}. {passed} passed; {failed} failed;", text, count=1)
            taken = 0
        kept.append(line)
    return "\n".join(kept)


def judge(head: str | None, retry: str | None, base: str | None, job: str) -> tuple[bool, list[str]]:
    """(own, annotations): own is True when a red is the change's own."""
    if head is None or not head.strip():
        return True, [f"::error title={job}::the head's test log is missing or empty, so no test can be judged"]
    found = test_reds.read(head)
    flaky = found.failed & passed_names(retry)
    notes = [f"::warning title={job} (flaky)::{name} failed, then passed run again alone" for name in sorted(flaky)]
    if not found.failed and not found.crashes and not found.truncated:
        return True, notes + [f"::error title={job}::cargo test failed and named no failing test (a compile error?); "
                              "see the step's log"]
    verdict = test_reds.classify(without_failures(head, flaky), base, job, "the merge base")
    if verdict is None:
        # Every failing test was a flake.
        return False, notes
    if verdict.own:
        return True, notes + [f"::error title={job}::{reason}" for reason in verdict.reasons]
    return False, notes + [f"::warning title={job} (base red)::{name} fails on the merge base too"
                           for name in verdict.shared]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    failed = sub.add_parser("failed", help="print the failing test names of a cargo test log")
    failed.add_argument("log", type=Path)
    scope = sub.add_parser("touches", help="whether the changed paths on stdin touch a crate's test inputs")
    scope.add_argument("crate", help="the crate's directory, relative to the repository")
    scope.add_argument("--repo", type=Path, default=Path("."))
    one = sub.add_parser("judge", help="judge a red head run against its retry and the base replay")
    one.add_argument("--head", required=True, type=Path)
    one.add_argument("--retry", type=Path)
    one.add_argument("--base", type=Path)
    one.add_argument("--job", default="cargo test")
    args = parser.parse_args(argv)
    if args.command == "touches":
        hits = touches(args.repo, args.crate, [line.strip() for line in sys.stdin if line.strip()])
        for path in hits[:20]:
            print(path)
        if len(hits) > 20:
            print(f"... and {len(hits) - 20} more")
        return 0 if hits else 1
    if args.command == "failed":
        print("\n".join(failed_names(args.log.read_text(errors="replace"))))
        return 0
    own, notes = judge(read_text(args.head), read_text(args.retry), read_text(args.base), args.job)
    for note in notes:
        print(note)
    print(f"{args.job}: " + ("a red is the change's own" if own else "no red is the change's own"))
    return 1 if own else 0


if __name__ == "__main__":
    sys.exit(main())
