#!/usr/bin/env python3
"""The inputs of a cmux-next job as one key, so a pass can be reused.

With `vars.CI_NEXT_JOB_REUSE == '1'`, cmux-next.yml's fast-tier, fast-tier-cargo,
swift test, Release compile and generated files jobs look up a pass recorded
under `job-pass-<job>-<key>` (an Actions artifact, scripts/ci/job_reuse.py)
before they build. A hit skips the build and the tests and names the run that
passed; a job that passes records its own.

The key covers:

- what the job reads:
  - fast-tier and fast-tier-cargo: the commit's full tree hash
    (`git rev-parse <rev>^{tree}`), so a pass is reused only on an identical
    tree (a rerun, or a re-push of the same tree);
  - swift-test, release-compile and generated-files: the git object id of
    each path on an explicit input list (`git ls-tree <rev> -- <paths>`; an
    absent path counts as absent). The list is derived from the router
    (scripts/ci/cmux_next_route.py), the CI target graph's `reads`
    (Packages/macOS/CmuxNext/ci-target-graph.json), the web bundles' inputs
    (scripts/cmux-next/web-bundle-key.py) and the scripts each job runs, and
    over-includes: the whole Packages and vendor trees, scripts/cmux-next,
    schemas, plans/cmux-next and the submodule gitlinks. A base move that
    touches none of these keeps the key. generated-files also keys its base's
    (`--base-rev`, HEAD^1) settings sources, which its stamp check reads;
- the blob hash of the whole .github/workflows/cmux-next.yml;
- the toolchain the workflow step names with `--extra`: Xcode (the
  `xcodebuild -version` output), the macOS version and build, arch and the
  runner pool (owned, Blacksmith or hosted) for the Mac jobs; the runner,
  `rustc -Vv`, `cargo -V`, the Zig version and the clang that bindgen uses for
  fast-tier-cargo; and the runner image (`image`) when the runner names one;
- the env flags a Mac job's result depends on (`--extra`, '' is a value):
  the selected Swift targets and filter, whether the label is a mini (the GUI
  requirement, the CEF steps), the configured Xcode app and the web bundles'
  source key.

dev-release-product keys the compiled DEV Release app itself (scripts/ci/dev_release_product_reuse.py
moves the bytes), so its closure is broad: every path in the tree except PRODUCT_EXCLUDES, the paths
that cannot reach the app bundle (docs, tests, other platforms' apps, CI files other than this
workflow). A path no rule names is an input, so a new directory invalidates reuse until it is
classified; a path another job's input list names inside an excluded area stays an input.

When a required value is missing or empty, a declared flag is not passed, a
value is unknown, or git cannot read a revision, it prints no key, and the job
runs as without reuse. Prints `key=` and `fingerprint=` lines for
$GITHUB_OUTPUT and the inputs on stderr (`--list-inputs` lists every path).
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import cmux_next_route as route  # noqa: E402

VERSION = 3  # 2 keyed only full trees in actions/cache; no key of it may match.
WORKFLOW = ".github/workflows/cmux-next.yml"
MAC_TOOLCHAIN = ("xcode", "macos", "macos_build", "arch", "pool")
# Keyed when given; not every runner image sets ImageOS/ImageVersion.
OPTIONAL = ("image",)

# Every Mac job: the package graph and its local packages, the toolchain pins, the workflow and the
# actions it uses, the scripts it runs, the files the package tests and resources read, and the
# submodule gitlinks.
MAC_COMMON = (
    "Packages", "vendor", ".xcode-version", ".gitmodules", "ghostty", "ghostty-next",
    WORKFLOW, ".github/actions", "scripts/cmux-next", "scripts/select-ci-xcode.sh",
    "scripts/ci/xcode-pins.txt", "scripts/ci/cmux_next_route.py", "scripts/ci/select_package_tests.py",
    "scripts/ci/reset-stale-submodules.sh", "scripts/ci/owned_spm_scratch.py",
    "scripts/ci/swiftpm_build_metrics.py", "scripts/ci/build_metrics.py",
    "scripts/ci/run-xcodebuild-with-diagnostics.sh", "scripts/ci/job_input_fingerprint.py",
    "scripts/ci/job_reuse.py", "schemas", "plans/cmux-next",
) + route.FULL_INPUTS + route.VENDORED_PINS + route.GENERATED_INPUTS


def web_bundle_inputs() -> tuple[str, ...]:
    """The web bundles' source pathspecs (web-bundle-key.py INPUTS), without pathspec magic."""
    path = HERE.parent / "cmux-next" / "web-bundle-key.py"
    spec = importlib.util.spec_from_file_location("web_bundle_key", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return tuple(item for item in module.INPUTS if not item.startswith(":"))


SWIFT_TEST = (
    # The sidebar layout reducer's cargo test and the pinned CCmuxAppFFI check: the workspace
    # manifest, lockfile, toolchain and cargo config, besides the crates SWIFT_JOB_INPUTS names.
    "cmux-tui/Cargo.toml", "cmux-tui/Cargo.lock", "cmux-tui/rust-toolchain.toml", "cmux-tui/.cargo",
    # Read by the bundle-server-helper and signing script tests.
    "cmux-tui/crates/cmux-server-core/tests/fixtures/app-service-agent.plist", "cmux-helper.entitlements",
    "scripts/sign-cmux-bundle-helpers.sh",
) + route.SWIFT_JOB_INPUTS + route.BUNDLE_INPUTS
GENERATED = ("scripts/ci/defaults_guard.py", "docs/mdm", "docs/configuration.md") + route.BUNDLE_INPUTS
# generated-files compares the exports with the base's (HEAD^1) settings sources and exports.
SETTINGS_BASE = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings", "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests",
    "schemas/settings", "schemas/settings-export", "docs/mdm", "scripts/ci/defaults_guard.py",
)


# Paths that cannot reach the DEV Release app (the cmux scheme: cmux.xcodeproj, its build phases'
# scripts and the packages it links), as fnmatch patterns over whole path segments. Everything else
# in the tree is an input. Keep this exact: a wrong entry here ships a stale app.
PRODUCT_EXCLUDES = (
    # Docs, plans and design notes (only their prose; plans/cmux-next's JSON stays an input). Not
    # top-level Markdown: the app bundles THIRD_PARTY_LICENSES.md.
    "docs", "design", "release-notes", "plans/*.md", "plans/*/*.md", "plans/*/*/*.md",
    # Tests: the repository's, the scripts', and each package's test targets (`xcodebuild build`
    # of the app scheme compiles no test target).
    "tests", "tests_v2", "scripts/cmux-next/tests", "scripts/tests", "Packages/*/Tests", "Packages/*/*/Tests",
    # CI and agent configuration; .github/workflows/cmux-next.yml and .github/actions stay inputs
    # (the keep rule below), the rest of .github is other workflows.
    ".github", ".claude", ".codex", ".agents", ".greptile", ".coderabbit.yaml",
    # Benchmarks and developer tooling no build phase or compile step runs.
    "scripts/fuzz", "scripts/measure", "scripts/perf-bench", "scripts/git-hooks", "scripts/install-git-hooks.sh",
    # The classic iOS app. Not cmux-next-ios, web or backend: the app bundles files from each
    # (build-mobile-host.sh, the model catalog, bundle-cli-resources.sh's cloud catalogs).
    "ios",
)


def product_excluded(path: str) -> bool:
    parts = path.split("/")
    return any(len(pattern.split("/")) == len(parts)
               and all(fnmatch.fnmatchcase(part, glob) for part, glob in zip(parts, pattern.split("/")))
               for pattern in PRODUCT_EXCLUDES)


def product_may_exclude_below(path: str) -> bool:
    """Whether a pattern could exclude something under the directory `path`."""
    parts = path.split("/")
    return any(len(pattern.split("/")) > len(parts)
               and all(fnmatch.fnmatchcase(part, glob) for part, glob in zip(parts, pattern.split("/")))
               for pattern in PRODUCT_EXCLUDES)


# nightly.yml's `decide` outputs that build-nightly-app passes to (or around) xcodebuild. Every one is
# keyed, '' included; tests/test_nightly_release_product_reuse.py checks the build steps read no other.
NIGHTLY_PRODUCT_FLAGS = (
    "track", "channel", "bundle_id", "app_name", "url_scheme", "entitlements", "icon_name", "variants",
    "compile_archs", "import_variant", "swift_import_flags", "empty_browser_sources", "password_readers_out",
)


@dataclass(frozen=True)
class Job:
    required: tuple[str, ...]          # toolchain values, never empty
    flags: tuple[str, ...] = ()        # env flags, always passed, '' allowed
    inputs: tuple[str, ...] | None = None  # None: the whole tree
    web: bool = False                  # also the web bundles' inputs
    base_inputs: tuple[str, ...] = ()  # read at --base-rev
    product: bool = False              # the whole tree minus PRODUCT_EXCLUDES
    workflow: str = WORKFLOW           # the workflow file keyed whole (the one that builds it)


JOBS = {
    "fast-tier": Job(MAC_TOOLCHAIN),
    "fast-tier-cargo": Job(("runner", "rustc", "cargo", "zig", "clang")),
    "swift-test": Job(MAC_TOOLCHAIN + ("web_bundles",), ("swift_targets", "swift_filter", "mini", "xcode_app",
                                                         "layout_reducer"),
                      SWIFT_TEST, web=True),
    "generated-files": Job(MAC_TOOLCHAIN + ("web_bundles",), ("mini", "xcode_app"), GENERATED, web=True,
                           base_inputs=SETTINGS_BASE),
    "release-compile": Job(MAC_TOOLCHAIN, ("mini", "xcode_app"), (
        "LICENSE", "cmux-tui/build-support/notices", "cmux-tui/crates/ghostty-vt-sys/build.rs",
        "cmux-tui/rust-toolchain.toml", "scripts/verify-app-bundle-licenses.sh",
    )),
    # The unsigned DEV Release app (scripts/ci/dev_release_product_reuse.py): Xcode, the SDK, the arch,
    # that script's RECIPE and the cmux-tui tree it bundles (CMUX_TUI_TREE_KEY, or `own`: the tree's
    # own key is a function of TUI_TREE_INPUTS, which the closure keeps). The build
    # settings are the compile step's env (this workflow) and check-cmux-scheme-compile.sh's flags.
    "dev-release-product": Job(("xcode", "sdk", "arch", "recipe", "tui_tree"), product=True),
    # The unsigned cmux NEXT Nightly app before stamping (scripts/ci/nightly_release_product_reuse.py):
    # the same closure, but keyed by nightly.yml (its build steps and their flags), never cmux-next.yml
    # alone, and by `decide`'s outputs that reach the build (NIGHTLY_PRODUCT_FLAGS): the identity, the
    # icon, the arches and the browser-import variant. The job name is part of the key, so a nightly
    # key never equals a DEV key.
    # The runner's macOS too (`sw_vers` version and build): the SDK alone does not name the host
    # tools and system libraries a build runs.
    "nightly-release-product": Job(("xcode", "sdk", "arch", "recipe", "tui_tree", "macos", "macos_build"),
                                   NIGHTLY_PRODUCT_FLAGS, product=True,
                                   workflow=".github/workflows/nightly.yml"),
}
GRAPH = route.GRAPH


class Unresolved(Exception):
    """The key cannot name one of the job's inputs."""


def git(root: str, *args: str) -> str:
    return subprocess.run(["git", "-C", root, *args], capture_output=True, text=True, check=True,
                          timeout=120).stdout.strip()


def normalize(path: str) -> str:
    """A route pattern as a git path: `webviews/src/*` -> `webviews/src`, `x*` -> its directory."""
    for magic in "*?[":
        if magic in path:
            path = path[:path.index(magic)]
            path = path if path.endswith("/") else path.rsplit("/", 1)[0] if "/" in path else ""
    return path.strip("/")


def graph_reads(root: str, rev: str) -> set[str]:
    try:
        text = git(root, "show", f"{rev}:{GRAPH}")
    except subprocess.CalledProcessError:
        return set()
    try:
        graph = json.loads(text)
        return {read for target in graph["targets"].values() for read in target.get("reads", [])}
    except (ValueError, KeyError, AttributeError, TypeError) as error:
        raise Unresolved(f"{GRAPH} at {rev} does not parse: {error}") from error


def input_paths(root: str, rev: str, job: str) -> list[str]:
    spec = JOBS[job]
    paths = set(MAC_COMMON) | set(spec.inputs or ()) | graph_reads(root, rev)
    if spec.web:
        paths |= set(web_bundle_inputs())
    paths = {normalize(path) for path in paths}
    if "" in paths:
        raise Unresolved("an input pattern names the whole tree")
    # A path under a listed directory is covered by that directory's tree id (and git ls-tree would
    # list the inner entry instead of the directory).
    return sorted(path for path in paths if not any(path.startswith(other + "/") for other in paths))


TUI_TREE_INPUTS = "scripts/cmux-next/cmux-tui-tree-inputs.txt"


def tui_tree_inputs(root: str, rev: str) -> set[str]:
    """The paths the bundled cmux-tui tree is keyed by (cmux_tui_tree_key.py), so the app's key
    covers its cmux-tui without computing that key: a fixture under tests or backend stays an input."""
    try:
        text = git(root, "show", f"{rev}:{TUI_TREE_INPUTS}")
    except subprocess.CalledProcessError:
        return set()
    paths = set()
    for line in text.splitlines():
        fields = line.split("#", 1)[0].split()
        if len(fields) == 2:
            paths.add(normalize(fields[1]))
    return paths


PROJECT = "cmux.xcodeproj/project.pbxproj"


def project_files(root: str, rev: str) -> set[str]:
    """The files the Xcode project names relative to the repository root (sourceTree SOURCE_ROOT)."""
    try:
        text = git(root, "show", f"{rev}:{PROJECT}")
    except subprocess.CalledProcessError:
        return set()
    return {normalize(path) for path in re.findall(r'path = "?([^";]+)"?; sourceTree = SOURCE_ROOT;', text)}


def product_inputs(root: str, rev: str) -> dict[str, str]:
    """`mode type oid` of every top-most tree entry outside PRODUCT_EXCLUDES.

    Inside an excluded directory a path another job's input list names stays an input (the
    Release compile's list and the web bundles' inputs: this workflow, .github/actions, docs/mdm,
    tests/fixtures/classic-to-next, web/data/model-catalog). Outside one a listed directory is
    still split, so Packages' test targets never count."""
    listing = subprocess.run(["git", "-C", root, "ls-tree", "-r", "-t", "--full-tree", rev],
                             capture_output=True, text=True, timeout=120)
    if listing.returncode != 0:
        raise Unresolved(listing.stderr.strip() or f"git ls-tree {rev} failed")
    keeps = set(input_paths(root, rev, "release-compile")) | {normalize(path) for path in web_bundle_inputs()}
    keeps |= {normalize(path) for path in route.BUNDLE_INPUTS} | tui_tree_inputs(root, rev) | project_files(root, rev)
    keeps = {path for path in keeps if path}
    found: dict[str, str] = {}
    done = None  # a directory recorded or dropped whole: skip what the listing shows under it
    for line in listing.stdout.splitlines():
        meta, _, path = line.partition("\t")
        if done and path.startswith(done):
            continue
        is_tree = meta.split()[1] == "tree"
        parts = path.split("/")
        ancestors = ["/".join(parts[:index]) for index in range(1, len(parts))]
        roots = [parent for parent in ancestors + [path] if product_excluded(parent)]
        if roots:
            # Kept: a listed path at or under the excluded directory, never one above it ("Packages"
            # does not keep Packages/*/Tests).
            if any(parent in keeps and len(parent) >= len(roots[0]) for parent in ancestors + [path]):
                found[path] = meta
            elif is_tree and any(keep.startswith(path + "/") for keep in keeps):
                continue  # only the kept entries under it, as the listing reaches them
            done = path + "/"
            continue
        if is_tree and product_may_exclude_below(path):
            continue  # entry by entry
        found[path] = meta
        done = path + "/"
    return found


def object_ids(root: str, rev: str, paths: list[str]) -> dict[str, str]:
    """`mode type oid` of each path at `rev` (submodule gitlinks included), or '-' when absent."""
    listing = subprocess.run(["git", "-C", root, "ls-tree", "--full-tree", rev, "--", *paths],
                             capture_output=True, text=True, timeout=120)
    if listing.returncode != 0:
        raise Unresolved(listing.stderr.strip() or f"git ls-tree {rev} failed")
    found = {}
    for line in listing.stdout.splitlines():
        meta, _, path = line.partition("\t")
        found[path] = meta
    return {path: found.get(path, "-") for path in paths}


def fingerprint(root: str, rev: str, job: str, extra: list[str], base_rev: str | None = None) -> tuple[str, dict]:
    spec = JOBS[job]
    values: dict[str, str] = {}
    for item in extra:
        name, sep, value = item.partition("=")
        if not sep:
            raise Unresolved(f"--extra {item!r} is not NAME=VALUE")
        values[name] = " ".join(value.split())
    unknown = sorted(set(values) - set(spec.required) - set(spec.flags) - set(OPTIONAL))
    if unknown:
        raise Unresolved(f"unknown toolchain value {', '.join(unknown)}")
    missing = [name for name in spec.required if not values.get(name)]
    missing += [name for name in spec.flags if name not in values]
    if missing:
        raise Unresolved(f"no toolchain value for {', '.join(missing)}")
    try:
        commit = git(root, "rev-parse", "--verify", f"{rev}^{{commit}}")
        workflow = git(root, "rev-parse", "--verify", f"{rev}:{spec.workflow}")
        value: dict = {"version": VERSION, "job": job, "workflow": workflow,
                       "toolchain": {name: values[name] for name in spec.required + OPTIONAL if name in values},
                       "flags": {name: values[name] for name in spec.flags}}
        if spec.product:
            value["inputs"] = product_inputs(root, commit)
        elif spec.inputs is None:
            value["tree"] = git(root, "rev-parse", "--verify", f"{rev}^{{tree}}")
        else:
            value["inputs"] = object_ids(root, commit, input_paths(root, commit, job))
        if spec.base_inputs:
            if not base_rev:
                raise Unresolved(f"{job} keys its base's settings sources: pass --base-rev")
            base = git(root, "rev-parse", "--verify", f"{base_rev}^{{commit}}")
            value["base_inputs"] = object_ids(root, base, sorted(spec.base_inputs))
    except subprocess.CalledProcessError as error:
        raise Unresolved(error.stderr.strip() or str(error)) from error
    raw = json.dumps(value, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(raw.encode()).hexdigest(), value


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("job", choices=sorted(JOBS))
    parser.add_argument("--root", default=".")
    parser.add_argument("--rev", default="HEAD")
    parser.add_argument("--base-rev", help="the base commit (HEAD^1); generated-files keys its settings sources")
    parser.add_argument("--extra", action="append", default=[], help="NAME=VALUE of the toolchain or a flag (repeatable)")
    parser.add_argument("--list-inputs", action="store_true", help="print every keyed path on stderr")
    args = parser.parse_args(argv)
    if args.list_inputs and JOBS[args.job].product:
        try:
            for path in product_inputs(args.root, args.rev):
                print(f"input {path}", file=sys.stderr)
        except (Unresolved, subprocess.CalledProcessError) as why:
            print(f"::notice title=No input list for {args.job}::{why}", file=sys.stderr)
        return 0
    if args.list_inputs and JOBS[args.job].inputs is not None:
        # Only the paths: no toolchain needed (tests check the job's scripts are on the list).
        try:
            for path in input_paths(args.root, args.rev, args.job):
                print(f"input {path}", file=sys.stderr)
            for path in sorted(JOBS[args.job].base_inputs):
                print(f"base-input {path}", file=sys.stderr)
        except (Unresolved, subprocess.CalledProcessError) as why:
            print(f"::notice title=No input list for {args.job}::{why}", file=sys.stderr)
        return 0
    try:
        digest, value = fingerprint(args.root, args.rev, args.job, args.extra, args.base_rev)
    except Unresolved as why:
        print(f"::notice title=No reuse for {args.job}::{why}", file=sys.stderr)
        return 0
    if "tree" in value:
        print(f"tree {value['tree']}", file=sys.stderr)
    else:
        present = sum(1 for meta in value["inputs"].values() if meta != "-")
        print(f"inputs {len(value['inputs'])} paths, {present} present", file=sys.stderr)
        for path, meta in value["inputs"].items():
            print(f"  {meta} {path}", file=sys.stderr)
        for path, meta in value.get("base_inputs", {}).items():
            print(f"  base {meta} {path}", file=sys.stderr)
    print(f"workflow {value['workflow']} {JOBS[args.job].workflow}", file=sys.stderr)
    for name, text in sorted({**value["toolchain"], **value["flags"]}.items()):
        print(f"{name} {text}", file=sys.stderr)
    print(f"key=job-pass-{args.job}-{digest[:40]}")
    print(f"fingerprint={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
