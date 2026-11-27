#!/usr/bin/env python3
"""The local packages the NEXT iOS app builds, read from its manifests, and the
check that the iOS workflows' path filters name exactly those.

The app (cmux-next-ios/project.yml) and its kit (cmux-next-ios/CmuxMobileKit/
Package.swift) pull in local Swift packages by relative path, and those pull in
more. Two workflows that take a Mac per run filter on that set by hand:
ios-review-gate.yml (two reviewer-path Macs, about 24 minutes each) and
cmux-next-ios-kit.yml (one simulator Mac, about 17 minutes). Both lists drifted:
on 2026-11-21 the review gate ran for every `Packages/Shared/**` change (14
shared packages the app never links, CmuxMessagesLab among them) and skipped
four packages it does link; the kit tests skipped eight packages the kit links
(CmuxHomeCore, CmuxDeviceHub, CmuxTheme, ...). `--check` fails when a filter
misses a package the app links or names a package directory it does not.

The CmuxMobileKit tests are also the `ios-kit` step of ci/steps.toml on a feat-cmux-next pull request; its
`inputs` are held to the same set (its `ignore` drops notes and cmux-next-ios/verify/ evidence, as the workflow's
negations do).

The Rust side is held the same way: the kit links CmuxMobileLinkFFI, built from cmux-mobile-link-ffi and every
crate it compiles, read from the Cargo graph by scripts/ci/ios_link_ffi_key.py (its `closure`). Each of those
outside cmux-next-ios/ (the cmux-tui crates and vendored crates, their workspace manifests and locks, the pinned
toolchain) must be a `ios-kit` input, and no cmux-tui crate the FFI does not compile may be one, so a crate an iOS
PR shares with cmux-tui starts the iOS checks (cmux#55399: a cmux-tui crate change broke the iOS build, nothing iOS
ran) and a new shared crate is named here the day the FFI links it.

Usage:
  scripts/ci/ios_app_package_paths.py           print the `<package>/**` lines
  scripts/ci/ios_app_package_paths.py --rust    also print the ios-kit Rust input lines (toml form)
  scripts/ci/ios_app_package_paths.py --check   exit 1 and list each drift
"""

from __future__ import annotations

import posixpath
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_steps  # noqa: E402
import ios_link_ffi_key  # noqa: E402

# The app's manifests: the XcodeGen project and the kit package.
APP_MANIFESTS = ("cmux-next-ios/project.yml", "cmux-next-ios/CmuxMobileKit/Package.swift")

# Workflows whose pull_request and push filters must name exactly the app's packages. cmux-next-ios-kit.yml has
# no path filter left: a feat-cmux-next pull request runs the kit as TABLE_STEP (pr-pipeline.yml's ios job) and the
# push runs it in the post-merge batch (suite pr-pipeline-ios, gated on the same step inputs).
WORKFLOWS = (".github/workflows/ios-review-gate.yml",)
# The triggers each workflow filters (default: both).
WORKFLOW_EVENTS: dict[str, tuple[str, ...]] = {}
# The step table and its step whose `inputs` must name exactly the app's packages.
TABLE = "ci/steps.toml"
TABLE_STEP = "ios-kit"

# Directories whose package paths the filters may only name when the app links them.
PACKAGE_ROOTS = ("Packages/", "vendor/")

_SWIFT_PATH = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)"')
_YAML_PATH = re.compile(r"^\s+path:\s*['\"]?([^'\"\s#]+)")


def _manifest_paths(rel: str, text: str) -> list[str]:
    if rel.endswith(".swift"):
        return _SWIFT_PATH.findall(text)
    # project.yml: only the `packages:` section names packages.
    out: list[str] = []
    in_packages = False
    for line in text.splitlines():
        if re.match(r"^\S", line):
            in_packages = line.startswith("packages:")
            continue
        if in_packages:
            m = _YAML_PATH.match(line)
            if m:
                out.append(m.group(1))
    return out


def app_packages(root: Path = ROOT) -> list[str]:
    """Every local package directory (repo-relative) the app links, transitively, the kit itself left out."""
    seen: set[str] = set()
    found: set[str] = set()
    todo = list(APP_MANIFESTS)
    while todo:
        rel = todo.pop()
        if rel in seen:
            continue
        seen.add(rel)
        path = root / rel
        if not path.is_file():
            continue
        for dep in _manifest_paths(rel, path.read_text()):
            pkg = posixpath.normpath(posixpath.join(posixpath.dirname(rel), dep))
            if (root / pkg / "Package.swift").is_file():
                if not pkg.startswith("cmux-next-ios/"):
                    found.add(pkg)
                todo.append(pkg + "/Package.swift")
    return sorted(found)


def workflow_filters(text: str) -> dict[str, list[str]]:
    """The `paths:` list of each pull_request and push trigger in a workflow's `on:` block."""
    out: dict[str, list[str]] = {}
    event = None
    in_paths = False
    for line in text.splitlines():
        if re.match(r"^\S", line) and not line.startswith("on:"):
            if out or event:
                break
            continue
        m = re.match(r"^  (\w+):", line)
        if m:
            event = m.group(1) if m.group(1) in ("pull_request", "push") else None
            in_paths = False
            continue
        if event and re.match(r"^    paths:\s*$", line):
            in_paths = True
            out[event] = []
            continue
        if event and in_paths:
            item = re.match(r"^\s+-\s*['\"]?([^'\"#]+?)['\"]?\s*(?:#.*)?$", line)
            if item:
                out[event].append(item.group(1))
            elif re.match(r"^    \S", line):
                in_paths = False
    return out


# Rust package directories the filter may only name when the FFI compiles them.
RUST_ROOTS = ("cmux-tui/crates/", "cmux-tui/vendor/")


def rust_inputs(packages: list[str], roots: list[str]) -> list[str]:
    """The ios-kit input patterns the FFI's Cargo closure needs outside cmux-next-ios/ (which `cmux-next-ios/**`
    covers): each package's tree, each workspace root's manifest, the fixed files the build reads. Cargo reads only
    the building workspace's (cmux-next-ios/rust) Cargo.lock, so another root's lock is no input, as in
    ios_link_ffi_key's key: a cmux-tui/Cargo.lock-only change took a Mac for 8 of 95 branches (200 of 2,258 min)
    of the ios fast verdict on 2026-11-27 16-20Z."""
    want = {f"{pkg}/**" for pkg in packages}
    for root in roots:
        want.add(f"{root}/Cargo.toml")
    want |= set(ios_link_ffi_key.FIXED)
    return sorted(p for p in want if not p.startswith("cmux-next-ios/"))


def ffi_closure(root: Path) -> tuple[list[str], list[str]]:
    """ios_link_ffi_key.closure at HEAD, read in ROOT's repository."""
    cwd = Path.cwd()
    try:
        import os
        os.chdir(root)
        return ios_link_ffi_key.closure("HEAD")
    finally:
        os.chdir(cwd)


def check(root: Path = ROOT, rust: tuple[list[str], list[str]] | None = None) -> list[str]:
    """Drift in each filter. RUST is the FFI's (packages, roots); None reads it from ROOT's git HEAD when ROOT is a
    checkout with the FFI (a test's bare tree skips the Rust half)."""
    pkgs = app_packages(root)
    want = {p + "/**" for p in pkgs}
    problems: list[str] = []
    if not pkgs:
        return [f"no local packages found in {', '.join(APP_MANIFESTS)}"]
    filters: list[tuple[str, list[str] | None]] = []
    for wf in WORKFLOWS:
        found = workflow_filters((root / wf).read_text())
        for event in WORKFLOW_EVENTS.get(wf, ("pull_request", "push")):
            filters.append((f"{wf}: {event}", found.get(event)))
    step = None
    if (root / TABLE).is_file():
        step = ci_steps.load(root / TABLE).steps.get(TABLE_STEP)
        filters.append((f"{TABLE}: step {TABLE_STEP}", list(step.inputs) if step else None))
    if rust is None and (root / ".git").exists() and (root / ios_link_ffi_key.FFI / "Cargo.toml").is_file():
        rust = ffi_closure(root)
    if rust is not None and step is not None:
        lines = set(step.inputs)
        rust_want = set(rust_inputs(*rust))
        for pattern in sorted(rust_want - lines):
            problems.append(f"{TABLE}: step {TABLE_STEP} misses {pattern} (CmuxMobileLinkFFI compiles it)")
        for line in sorted(lines):
            if line.startswith(RUST_ROOTS) and line not in rust_want:
                problems.append(f"{TABLE}: step {TABLE_STEP} names {line}, which CmuxMobileLinkFFI does not compile")
    for where, lines in filters:
        if lines is None:
            problems.append(f"{where} has no paths filter")
            continue
        for pattern in sorted(want - set(lines)):
            problems.append(f"{where} misses {pattern} (the app links it)")
        for line in lines:
            if line.startswith("!") or "/Resources/" in line or not line.startswith(PACKAGE_ROOTS):
                continue
            if line not in want:
                problems.append(f"{where} names {line}, which the app does not link")
    return problems


def main(argv: list[str]) -> int:
    if "--check" in argv:
        problems = check()
        for p in problems:
            print(p)
        if problems:
            print(f"fix: paste the lines `{sys.argv[0]}` prints into each filter", file=sys.stderr)
        return 1 if problems else 0
    for pkg in app_packages():
        print(f'      - "{pkg}/**"')
    if "--rust" in argv:
        for line in rust_inputs(*ffi_closure(ROOT)):
            print(f'  "{line}",')
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
