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

When a required value is missing or empty, a declared flag is not passed, a
value is unknown, or git cannot read a revision, it prints no key, and the job
runs as without reuse. Prints `key=` and `fingerprint=` lines for
$GITHUB_OUTPUT and the inputs on stderr (`--list-inputs` lists every path).
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
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
# check-stamp --base HEAD^1 reads the base's settings sources and exports.
SETTINGS_BASE = (
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings", "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests",
    "schemas/settings", "schemas/settings-export", "docs/mdm", "scripts/ci/defaults_guard.py",
)


@dataclass(frozen=True)
class Job:
    required: tuple[str, ...]          # toolchain values, never empty
    flags: tuple[str, ...] = ()        # env flags, always passed, '' allowed
    inputs: tuple[str, ...] | None = None  # None: the whole tree
    web: bool = False                  # also the web bundles' inputs
    base_inputs: tuple[str, ...] = ()  # read at --base-rev


JOBS = {
    "fast-tier": Job(MAC_TOOLCHAIN),
    "fast-tier-cargo": Job(("runner", "rustc", "cargo", "zig", "clang")),
    "swift-test": Job(MAC_TOOLCHAIN + ("web_bundles",), ("swift_targets", "swift_filter", "mini", "xcode_app"),
                      SWIFT_TEST, web=True),
    "generated-files": Job(MAC_TOOLCHAIN + ("web_bundles",), ("mini", "xcode_app"), GENERATED, web=True,
                           base_inputs=SETTINGS_BASE),
    "release-compile": Job(MAC_TOOLCHAIN, ("mini", "xcode_app"), ()),
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
        workflow = git(root, "rev-parse", "--verify", f"{rev}:{WORKFLOW}")
        value: dict = {"version": VERSION, "job": job, "workflow": workflow,
                       "toolchain": {name: values[name] for name in spec.required + OPTIONAL if name in values},
                       "flags": {name: values[name] for name in spec.flags}}
        if spec.inputs is None:
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
    print(f"workflow {value['workflow']} {WORKFLOW}", file=sys.stderr)
    for name, text in sorted({**value["toolchain"], **value["flags"]}.items()):
        print(f"{name} {text}", file=sys.stderr)
    print(f"key=job-pass-{args.job}-{digest[:40]}")
    print(f"fingerprint={digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
