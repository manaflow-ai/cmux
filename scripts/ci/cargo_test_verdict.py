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
                                [--recent-base PUSH.log --recent-base-label LABEL]
        prints GitHub annotations and exits 0 when no red is the change's own, 1 when one is. PUSH.log is the base
        branch's own last whole run of the job: a test red there is the base's, as one red on the merge parent is.

The verdict:
- A test that failed on the head and passed when run again alone is a flake: it warns.
- The rest are judged by scripts/ci/test_reds.py, the one per-test classifier for "red on the base, so not ours":
  a test the base fails too warns as a base red; a test that passes or does not exist on the base, a crash
  (signal, abort) and a cut-short run (a test binary that printed no `test result:`) are the change's own red.
- A red run that names no failing test (a compile error) is the change's own red.
"""
from __future__ import annotations

import argparse
import bisect
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
# Files a crate's tests read at test time, not with include_str! (a path ending in / is a
# directory): acpmux's v2 gate registry tests read the nightly's gate script and its lines.
READ_AT_TEST_TIME = {
    "cmux-tui/crates/acpmux": ("scripts/cmux-next/run-v2-gates.sh", "scripts/cmux-next/v2-gates.d/"),
}
# include!/include_str!/include_bytes! of a literal path, from the source's directory.
INCLUDE = re.compile(r'\binclude(?:_str|_bytes)?!\(\s*"([^"]+)"')
# #[path = "..."] on a module: compiled from that file (cmux#45420 review: cmux-cloud-client's build.rs compiles
# workers/cmux-vm/cli/crates/cmux-vm-codegen/src/normalize.rs this way).
PATH_ATTR = re.compile(r'#\[\s*path\s*=\s*"([^"]+)"\s*\]')
# include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../spec/x.json")) names a path from the crate directory;
# include_str!(concat!("../dir/", $name, ".json")) one from the source's directory. The first literal is the path, or,
# when more pieces follow it (a macro's $name), the directory it opens: its prefix up to the last "/" (cmux#45420
# review P3-F1: the Windows check skipped a change to cmux-tui/spec/browser-host-operations.json). env!("OUT_DIR") and
# other non-literal heads name no file of the tree and are not matched.
INCLUDE_CONCAT = re.compile(r'\binclude(?:_str|_bytes)?!\(\s*concat!\(\s*(env!\(\s*"CARGO_MANIFEST_DIR"\s*\)\s*,\s*)?'
                            r'"([^"]*)"\s*([,)])')


def _concat_includes(tree, crate: str, source: str, text: str) -> list[str]:
    """The paths (files, or the directory a macro-built name opens) TEXT's include_str!(concat!(...)) calls name."""
    found = []
    for match in INCLUDE_CONCAT.finditer(text):
        manifest_dir, literal, after = match.groups()
        if after == ",":
            literal = literal[:literal.rfind("/") + 1] if "/" in literal else ""
        relative = literal.lstrip("/") if manifest_dir else literal
        if not relative.strip("/."):
            continue  # the crate or source directory itself: nothing narrower than what is already counted
        named = _follow(tree, crate if manifest_dir else posixpath.dirname(source), relative.rstrip("/"))
        if named is not None:
            found.append(named)
    return found
DEPENDENCY_TABLES = ("dependencies", "dev-dependencies", "build-dependencies")
PASSED = re.compile(r"^test (\S+) \.\.\. ok$")
FAILED_LINE = re.compile(r"^test (\S+) \.\.\. FAILED$")


def _enabled(manifest: dict, features=(), default: bool = True) -> tuple[set[str], dict[str, set[str]]]:
    """What MANIFEST's default features (when DEFAULT) and FEATURES turn on: the optional dependencies (`dep:x`, `x`,
    `x/feature`) and, per dependency, the features they ask of it (`x/feature`, `x?/feature`)."""
    table = manifest.get("features", {})
    enabled, asked = set(), {}
    queue, seen = (list(table.get("default", [])) if default else []) + list(features), set()
    while queue:
        item = queue.pop()
        if item in seen:
            continue
        seen.add(item)
        if item.startswith("dep:"):
            enabled.add(item[4:])
        elif "/" in item:
            name, feature = item.split("/", 1)
            if not name.endswith("?"):
                enabled.add(name)
            asked.setdefault(name.rstrip("?"), set()).add(feature)
        elif item in table:
            queue += table[item]
        else:
            enabled.add(item)
    return enabled, asked


def _default_optional(manifest: dict) -> set[str]:
    """The optional dependencies MANIFEST's default features turn on (`dep:x`, `x`, `x/feature`)."""
    return _enabled(manifest)[0]


def _dependency_edges(manifest: dict, crate: str, workspace: str, shared: dict, features=(),
                      default: bool = True, dev: bool = True) -> list[tuple[str, frozenset[str], bool]]:
    """(directory, features asked of it, its default features on) for each path dependency a build of the crate with
    FEATURES (plus its defaults when DEFAULT) builds: an optional one only when a turned-on feature turns it on
    (acpmux's `hub-carrier` pulls in cmux-remote only when a build asks for it); dev-dependencies only when DEV (the
    crate's own tests are built). Repository paths."""
    kinds = DEPENDENCY_TABLES if dev else tuple(k for k in DEPENDENCY_TABLES if k != "dev-dependencies")
    tables = [manifest.get(name, {}) for name in kinds]
    tables += [target.get(name, {}) for target in manifest.get("target", {}).values() for name in kinds]
    optional_on, asked = _enabled(manifest, features, default)
    found = []
    for table in tables:
        for name, spec in table.items():
            if not isinstance(spec, dict):
                continue
            if spec.get("optional") and name not in optional_on:
                continue
            inherited = shared.get(name, {}) if spec.get("workspace") else {}
            inherited = inherited if isinstance(inherited, dict) else {}
            wanted = frozenset(spec.get("features", [])) | frozenset(inherited.get("features", [])) \
                | frozenset(asked.get(name, ()))
            uses_default = spec.get("default-features", inherited.get("default-features", True)) is not False
            if "path" in spec:
                found.append((posixpath.normpath(posixpath.join(crate, spec["path"])), wanted, uses_default))
            elif spec.get("workspace") and "path" in inherited:
                found.append((posixpath.normpath(posixpath.join(workspace, inherited["path"])), wanted, uses_default))
    return found


def _path_dependencies(manifest: dict, crate: str, workspace: str, shared: dict) -> list[str]:
    """The path dependencies a plain `cargo test` of the crate builds (_dependency_edges' directories)."""
    return [path for path, _features, _default in _dependency_edges(manifest, crate, workspace, shared)]


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


# A "../" string literal in a crate's source: an include_str!/include_bytes! path, or a test's CARGO_MANIFEST_DIR
# join of a fixture outside the crate (scripts/ci/cargo_affected.py's RELATIVE_REF).
RELATIVE_REF = re.compile(r'"(/?(?:\.\./)+[A-Za-z0-9_.][^"\s{}]*)"')


def _root_package_dirs(tree, manifest: dict) -> set[str]:
    """What the workspace root package (cmux-tui-source-watch) is built from: its targets' directories, never the
    whole workspace directory (scripts/ci/cargo_affected.py's load_members reads it the same way). It exists so
    cmux-build-identity's stamp notices new workspace files, and that stamp is the commit, which every change moves
    anyway: counting all of cmux-tui/ as its input would make every file there an input of every crate that reaches
    cmux-build-identity (cmux-remote, cmux-tui), and route nothing."""
    package = manifest.get("package", {})
    paths = [package.get("build"), manifest.get("lib", {}).get("path")]
    paths += [target.get("path") for kind in ("bin", "test", "bench", "example") for target in manifest.get(kind, [])]
    dirs = {posixpath.normpath(posixpath.join(WORKSPACE, posixpath.dirname(p))) for p in paths if isinstance(p, str)}
    dirs |= {f"{WORKSPACE}/{name}" for name in ("src", "tests", "benches", "examples")
             if tree.files(f"{WORKSPACE}/{name}", ".rs")}
    if package.get("build") is None and tree.is_file(f"{WORKSPACE}/build.rs"):
        dirs.add(f"{WORKSPACE}/build.rs")
    return {d for d in dirs if d != WORKSPACE}


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


# A dependency's targets that a build of the crates depending on it never compiles.
UNBUILT_TARGET_DIRS = ("tests", "benches", "examples")


class _Index:
    """One tree's Rust files, directory children and source texts, read once however many crates ask (a router
    walks a hundred crates for each of several jobs)."""

    def __init__(self, tree):
        self.rust = tree.files("", ".rs")
        self.children: dict[str, set[str]] = {}
        for path in tree.entries():
            parent, _, _name = path.rpartition("/")
            self.children.setdefault(parent, set()).add(path)
        self.texts: dict[str, str] = {}
        # (crate, source) -> (paths its compile reads, "../" paths it reads at run time): every job and crate that
        # builds a source asks the same question, so each is scanned once per tree (a route asks about 30 times).
        self.named: dict[tuple[str, str], tuple[frozenset[str], frozenset[str]]] = {}

    def rust_under(self, directory: str) -> list[str]:
        prefix = directory.rstrip("/") + "/"
        at = bisect.bisect_left(self.rust, prefix)
        found = []
        while at < len(self.rust) and self.rust[at].startswith(prefix):
            found.append(self.rust[at])
            at += 1
        return found


def _index(tree) -> _Index:
    index = getattr(tree, "_tested_inputs_index", None)
    if index is None:
        index = _Index(tree)
        tree._tested_inputs_index = index
    return index


def _source_names(tree, index: "_Index", crate: str, source: str) -> tuple[frozenset[str], frozenset[str]]:
    """What SOURCE (of CRATE) names: (the files its compile reads: include!/include_str!/include_bytes!, plain or
    through concat!, #[path] modules, and a build script's "../" literals; the "../" paths it reads at run time,
    which count only for the tested crate's own tests). Memoized on INDEX."""
    key = (crate, source)
    if key in index.named:
        return index.named[key]
    if source not in index.texts:
        index.texts[source] = tree.text(source, errors="replace")
    text = index.texts[source]
    here = posixpath.dirname(source)
    compiled: set[str] = set()
    if "include" in text:  # most sources include nothing: skip the regexes, which dominate a route's time
        for match in INCLUDE.finditer(text):
            included = _follow(tree, here, match.group(1))
            if included is not None:
                compiled.add(included)
        if "concat!" in text:
            compiled.update(_concat_includes(tree, crate, source, text))
    if "#[path" in text or "# [path" in text:
        for match in PATH_ATTR.finditer(text):
            named = _follow(tree, here, match.group(1))
            if named is not None:
                compiled.add(named)
    at_run_time: set[str] = set()
    if "../" in text:
        for literal in RELATIVE_REF.findall(text):
            for anchor in (here, crate):
                named = _follow(tree, anchor, literal.lstrip("/"))
                # An ancestor of the crate (cmux-tui/, cmux-tui/crates/) is a tree walk, not a fixture: counting it
                # would make the crate an input of every file beside it (cargo_affected.py skips them too).
                if named and not crate.startswith(f"{named}/") and tree.resolve(named) is not None:
                    at_run_time.add(named)
    # A build script reads its "../" paths when the crate builds (cargo:rerun-if-changed, codegen inputs), so they
    # count for a compile-only job and for every dependency, not only for the tested crate's run-time fixtures.
    if source == f"{crate}/build.rs":
        compiled |= at_run_time
    index.named[key] = (frozenset(compiled), frozenset(at_run_time))
    return index.named[key]


def tested_crate_inputs(tree, crate_dir: str, features=(), references: bool = True, binaries: bool = False) -> list[str]:
    """Every path whose change can change a `cargo test -p CRATE` (FEATURES: its `--features`) at TREE's commit, as
    paths and directories of the repository; scripts/ci/affected_jobs.py routes pull-request jobs by them. What cargo
    builds, and so what is read, as precisely as the manifests say and never less:

    - CRATE_DIR, all of it, and the files its sources name outside it: include_str!/include_bytes!, and any "../"
      literal naming an existing path (a test's CARGO_MANIFEST_DIR join of a fixture), unless not REFERENCES (a
      job that only compiles reads no fixture at run time);
    - every crate it reaches by path dependency: its normal and build dependencies with the features each edge asks
      for (`features = [...]`, `x/feature`, `default-features = false`), unified per crate as cargo does, so an
      optional dependency a feature turns on counts; dev-dependencies only of CRATE_DIR itself (cargo builds no
      other crate's tests). Of those crates, everything but their own tests/, benches/ and examples/, and the
      files their include_str!/include_bytes! name;
    - the workspace root package (cmux-tui-source-watch, a build dependency of cmux-build-identity) as its targets
      only (_root_package_dirs), never all of cmux-tui/.

    BINARIES: the job uses only the crate's built library and binaries (cmux-next.yml's daemon-test runs the published
    binaries): CRATE_DIR is read like a dependency (no tests/, benches/, examples/, dev-dependencies or fixtures).

    Raises git_tree.Unreadable as crate_inputs does."""
    shared = tomllib.loads(tree.text(f"{WORKSPACE}/Cargo.toml")).get("workspace", {}).get("dependencies", {})
    root = tree.real(posixpath.normpath(crate_dir))
    # crate directory -> (features, default features on): grown until no edge adds one.
    built: dict[str, tuple[frozenset[str], bool]] = {}
    manifests: dict[str, dict] = {}
    queue = [(root, frozenset(features), True)]
    while queue:
        crate, wanted, uses_default = queue.pop()
        if _outside(crate):
            continue
        crate = tree.real(crate)  # a symlinked crate directory is its target, as Path.resolve gave
        if _outside(crate):
            continue
        if crate not in manifests:
            if not tree.is_file(f"{crate}/Cargo.toml"):
                continue
            manifests[crate] = tomllib.loads(tree.text(f"{crate}/Cargo.toml"))
        had, had_default = built.get(crate, (None, False))
        now = (wanted | (had or frozenset()), uses_default or had_default)
        if had is not None and now == (had, had_default):
            continue
        built[crate] = now
        queue += _dependency_edges(manifests[crate], crate, WORKSPACE, shared, *now, dev=crate == root and not binaries)
    if root not in built:
        raise git_tree.Unreadable(f"{tree.ref}: {crate_dir} has no Cargo.toml")
    index = _index(tree)
    inputs: set[str] = set()
    scanned: list[tuple[str, str, bool]] = []  # (crate, source, its references count)
    for crate in built:
        if crate == WORKSPACE:
            owned = sorted(_root_package_dirs(tree, manifests[crate]))
            inputs |= set(owned)
            scanned += [(crate, source, references and crate == root) for d in owned for source in index.rust_under(d)]
            continue
        if crate == root and not binaries:
            inputs.add(crate)
            scanned += [(crate, source, references) for source in index.rust_under(crate)]
            continue
        prefix = f"{crate}/"
        inputs |= {path for path in index.children.get(crate, ()) if path[len(prefix):] not in UNBUILT_TARGET_DIRS}
        scanned += [(crate, source, False) for source in index.rust_under(crate)
                    if source[len(prefix):].split("/", 1)[0] not in UNBUILT_TARGET_DIRS]
    for crate, source, references in scanned:
        compiled, at_run_time = _source_names(tree, index, crate, source)
        inputs |= compiled
        if references:
            inputs |= at_run_time
    return sorted(inputs)


def touches(repo: Path, crate_dir: str, changed: list[str]) -> list[str]:
    """The changed paths that are inputs of CRATE_DIR's tests."""
    dirs, files = crate_inputs(repo, crate_dir)
    always = ALWAYS + READ_AT_TEST_TIME.get(crate_dir, ())
    prefixes = tuple(f"{d}/" for d in dirs) + tuple(p for p in always if p.endswith("/"))
    exact = set(files) | {p for p in always if not p.endswith("/")}
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


def judge(head: str | None, retry: str | None, base: str | None, job: str, recent: str | None = None,
          recent_label: str = "the base branch's last run") -> tuple[bool, list[str]]:
    """(own, annotations): own is True when a red is the change's own. RECENT: the base branch's own last run of the
    job (a feat-cmux-next push's whole log); a test red there is the base's as one red on the merge parent is
    (test_reds.classify_any), so the job need not rebuild the merge parent to replay it."""
    if head is None or not head.strip():
        return True, [f"::error title={job}::the head's test log is missing or empty, so no test can be judged"]
    found = test_reds.read(head)
    flaky = found.failed & passed_names(retry)
    notes = [f"::warning title={job} (flaky)::{name} failed, then passed run again alone" for name in sorted(flaky)]
    if not found.failed and not found.crashes and not found.truncated:
        return True, notes + [f"::error title={job}::cargo test failed and named no failing test (a compile error?); "
                              "see the step's log"]
    bases = [(label, log) for label, log in (("the merge base", base), (recent_label, recent)) if log is not None]
    verdict = (test_reds.classify_any(without_failures(head, flaky), bases, job) if len(bases) > 1 or recent
               else test_reds.classify(without_failures(head, flaky), base, job, "the merge base"))
    if verdict is None:
        # Every failing test was a flake.
        return False, notes
    if verdict.own:
        return True, notes + [f"::error title={job}::{reason}" for reason in verdict.reasons]
    where = "the merge base" if not recent else "the base"
    return False, notes + [f"::warning title={job} (base red)::{name} fails on {where} too"
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
    one.add_argument("--recent-base", type=Path, help="the base branch's own last whole log of the job")
    one.add_argument("--recent-base-label", default="the base branch's last run")
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
    own, notes = judge(read_text(args.head), read_text(args.retry), read_text(args.base), args.job,
                       read_text(args.recent_base), args.recent_base_label)
    for note in notes:
        print(note)
    print(f"{args.job}: " + ("a red is the change's own" if own else "no red is the change's own"))
    return 1 if own else 0


if __name__ == "__main__":
    sys.exit(main())
