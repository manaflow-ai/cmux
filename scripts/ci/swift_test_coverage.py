#!/usr/bin/env python3
"""Every Swift test target a package declares is run by a pull request check, or says why not (hq#11644).

A test target that compiles in CI is not a test that ran. cmux#43937 added CmuxNextAgentListTests (seven
tests); every check was green, the fast tier built the target and printed its test plan, and no check ran
it. This script finds that class in two places:

  tree   every `.testTarget(name:)` in Packages/*/*/Package.swift has a runner a pull request check
         uses on the paths the target covers, or an entry in scripts/ci/swift-test-targets.json:
           - scripts/ci/swift-linux-packages.txt (swift-linux-packages.yml `listed`, Linux);
           - a swift-linux-packages.yml group with whole packages and no test filter (Linux);
           - package-test-lane.sh's PACKAGES (ci-macos.yml swift-package-tests, owned Macs), which
             runs a package's whole `swift test` when the pull request changes one of its inputs;
           - Packages/macOS/CmuxNext: a test target in ci-target-graph.json. The PR swift test runs
             it with full-ci; a new one also needs the diff check below.
         A registry entry either names the workflow that runs the whole package on its pull requests
         (`run_by`, checked: it triggers on pull_request and runs `swift test --package-path DIR`
         with no filter) or says why no PR check runs it (`not_run`).
  diff   (--base REV) a CmuxNext test target the change adds that no fast-tier.json swift entry
         covers fails unless the pull request carries full-ci: without one, the first run of its
         tests is the tip suite on feat-cmux-next. A new test file in an existing CmuxNext target
         that no fast-tier entry covers is a warning.

Exit 0 when nothing failed, 1 when something did, 2 for a bad registry.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REGISTRY = "scripts/ci/swift-test-targets.json"
LINUX_LIST = "scripts/ci/swift-linux-packages.txt"
LINUX_WORKFLOW = ".github/workflows/swift-linux-packages.yml"
PACKAGE_LANE = "scripts/ci/package-test-lane.sh"
CMUXNEXT = "Packages/macOS/CmuxNext"
GRAPH = f"{CMUXNEXT}/ci-target-graph.json"
FAST_TIER = "scripts/cmux-next/fast-tier.json"

# `.testTarget(` then its `name:` argument, comments allowed between them.
TEST_TARGET = re.compile(r'\.testTarget\(\s*(?:(?://[^\n]*|/\*.*?\*/)\s*)*name:\s*"([^"]+)"', re.S)
LANE_PACKAGES = re.compile(r"^select_packages\(\)\s*\{\s*\n\s*PACKAGES=\(\n(.*?)\n\s*\)", re.S | re.M)
SWIFT_TESTS = re.compile(r"^\s*(?:@Test\b|func\s+test[A-Za-z0-9_]*\s*\()", re.M)

FIX = ("add it to a runner (scripts/ci/swift-linux-packages.txt for Linux, PACKAGES in "
       "scripts/ci/package-test-lane.sh for the owned-Mac package lane) or list it in "
       f"{REGISTRY} with run_by (the workflow that runs it on pull requests) or not_run (why none does)")


@dataclass(frozen=True)
class Target:
    package: str  # repository-relative package directory
    name: str


def manifest_targets(text: str) -> list[str]:
    return TEST_TARGET.findall(text)


def discover(root: Path) -> list[Target]:
    found = []
    for manifest in sorted(root.glob("Packages/*/*/Package.swift")):
        package = manifest.parent.relative_to(root).as_posix()
        found += [Target(package, name) for name in manifest_targets(manifest.read_text(encoding="utf-8"))]
    return found


def linux_listed(root: Path) -> set[Target]:
    found = set()
    for line in (root / LINUX_LIST).read_text(encoding="utf-8").splitlines():
        fields = line.split()
        if fields and not fields[0].startswith("#") and len(fields) >= 2:
            found |= {Target(fields[0].rstrip("/"), name) for name in fields[1].split(",") if name}
    return found


def linux_groups(root: Path) -> dict[str, str]:
    """Package directory -> group, for swift-linux-packages.yml groups that test whole packages."""
    groups: dict[str, str] = {}
    current: dict[str, str] = {}
    key = None

    def close():
        if current.get("group") and current.get("packages") and not current.get("test_filter"):
            for package in current["packages"].split():
                groups.setdefault(package.rstrip("/"), current["group"])

    for line in (root / LINUX_WORKFLOW).read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        start = re.match(r"^\s*- group:\s*(\S+)", line)
        if start:
            close()
            current, key = {"group": start.group(1)}, None
            continue
        if not current:
            continue
        field = re.match(r"^\s*(packages|test_filter):\s*(.*)$", line)
        if field:
            key = field.group(1)
            value = field.group(2).strip()
            current[key] = "" if value in (">-", ">", "|") else value
            continue
        if key == "packages" and stripped and not stripped.startswith("#") and ":" not in stripped:
            current["packages"] += " " + stripped
            continue
        if stripped.startswith("#"):
            continue
        if stripped and not line.startswith(" " * 12):
            close()
            current, key = {}, None
    close()
    return groups


def lane_packages(root: Path) -> set[str]:
    match = LANE_PACKAGES.search((root / PACKAGE_LANE).read_text(encoding="utf-8"))
    if not match:
        raise SystemExit(f"swift-test-coverage: no PACKAGES=( ... ) in {PACKAGE_LANE} select_packages")
    return {line.split("#")[0].strip() for line in match.group(1).splitlines() if line.split("#")[0].strip()}


def graph_tests(root: Path) -> dict[str, str]:
    """CmuxNext test target -> its source directory."""
    graph = json.loads((root / GRAPH).read_text(encoding="utf-8"))
    return {name: target.get("path") or "" for name, target in graph["targets"].items() if target.get("kind") == "test"}


def load_registry(root: Path) -> list[dict]:
    path = root / REGISTRY
    try:
        entries = json.loads(path.read_text(encoding="utf-8"))["targets"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"swift-test-coverage: {REGISTRY} is unreadable: {error}", file=sys.stderr)
        raise SystemExit(2)
    problems = []
    seen = set()
    for entry in entries:
        label = f"{entry.get('package')}:{entry.get('target')}"
        if not entry.get("package") or not entry.get("target"):
            problems.append(f"{label}: package and target are required")
        if bool(entry.get("run_by")) == bool(entry.get("not_run")):
            problems.append(f"{label}: exactly one of run_by (a workflow) or not_run (a reason) is required")
        if label in seen:
            problems.append(f"{label}: listed twice")
        seen.add(label)
    if problems:
        for problem in problems:
            print(f"swift-test-coverage: {REGISTRY}: {problem}", file=sys.stderr)
        raise SystemExit(2)
    return entries


def runs_whole_package_on_pr(root: Path, workflow: str, package: str) -> str | None:
    """None when `workflow` runs `swift test --package-path PACKAGE` (no filter) on pull requests, else why not."""
    try:
        text = (root / workflow).read_text(encoding="utf-8")
    except OSError:
        return f"{workflow} does not exist"
    if not re.search(r"^\s*pull_request:", text, re.M):
        return f"{workflow} does not run on pull requests"
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        if "swift test" in line and re.search(rf"--package-path\s+\"?{re.escape(package)}\"?(\s|$)", line) \
                and "--filter" not in line:
            return None
    return f"{workflow} has no `swift test --package-path {package}` line without a --filter"


def runners(root: Path) -> dict[Target, str]:
    """Every target an automatic runner covers -> the check that runs it."""
    found: dict[Target, str] = {}
    targets = discover(root)
    listed = linux_listed(root)
    groups = linux_groups(root)
    lane = lane_packages(root)
    graph = graph_tests(root) if (root / GRAPH).is_file() else {}
    for target in targets:
        if target in listed:
            found[target] = "Swift packages on Linux (listed)"
        elif target.package in groups:
            found[target] = f"Swift packages on Linux ({groups[target.package]})"
        elif target.package.rsplit("/", 1)[-1] in lane:
            found[target] = "CI macOS swift-package-tests (package-test-lane.sh)"
        elif target.package == CMUXNEXT and target.name in graph:
            found[target] = "cmux-next swift test (full-ci; a new target needs a fast-tier entry)"
    return found


def check_tree(root: Path) -> list[str]:
    errors = []
    targets = discover(root)
    known = set(targets)
    covered = runners(root)
    registry = load_registry(root)
    registered = set()
    for entry in registry:
        target = Target(entry["package"].rstrip("/"), entry["target"])
        registered.add(target)
        if target not in known:
            errors.append(f"{REGISTRY}: {target.package} declares no test target {target.name}: remove the entry")
        elif target in covered:
            errors.append(f"{REGISTRY}: {target.package} {target.name} already runs in {covered[target]}:"
                          " remove the entry")
        elif entry.get("run_by"):
            why = runs_whole_package_on_pr(root, entry["run_by"], target.package)
            if why:
                errors.append(f"{REGISTRY}: {target.package} {target.name}: run_by {why}")
    for target in targets:
        if target not in covered and target not in registered:
            errors.append(f"{target.package}: test target {target.name} is run by no pull request check: {FIX}")
    return errors


def git(root: Path, *args: str) -> str | None:
    result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def fast_tier_filters(root: Path) -> list[str]:
    entries = json.loads((root / FAST_TIER).read_text(encoding="utf-8"))["entries"]
    return [str(e.get("filter") or "") for e in entries
            if e.get("kind") == "swift" and str(e.get("package") or "").rstrip("/") == CMUXNEXT]


def suites_in(directory: Path) -> set[str]:
    names = set()
    for source in directory.rglob("*.swift"):
        names.add(source.stem)
        try:
            names |= set(re.findall(r"\b(?:struct|class|actor|enum)\s+([A-Za-z_][A-Za-z0-9_]*)",
                                    source.read_text(encoding="utf-8")))
        except (OSError, UnicodeDecodeError):
            continue
    return names


def covered_by_fast_tier(target: str, suites: set[str], filters: list[str]) -> bool:
    for flt in filters:
        head = re.split(r"[./]", flt, maxsplit=1)[0]
        if head == target or head in suites:
            return True
    return False


def target_directory(root: Path, path: str) -> Path:
    """A ci-target-graph.json path (repository-relative, or relative to the CmuxNext package) as a directory."""
    path = path.rstrip("/")
    return root / path if path.startswith(CMUXNEXT + "/") else root / CMUXNEXT / path


def count_tests(directory: Path) -> int:
    total = 0
    for source in directory.rglob("*.swift"):
        try:
            total += len(SWIFT_TESTS.findall(source.read_text(encoding="utf-8")))
        except (OSError, UnicodeDecodeError):
            continue
    return total


def check_diff(root: Path, base: str, full_ci: bool) -> tuple[list[str], list[str]]:
    """(errors, warnings) for the CmuxNext test targets and test files the change adds."""
    base_manifest = git(root, "show", f"{base}:{CMUXNEXT}/Package.swift")
    if base_manifest is None:
        return [], [f"{CMUXNEXT}/Package.swift is not readable at {base}: the new-target check is skipped"]
    head_manifest = (root / CMUXNEXT / "Package.swift").read_text(encoding="utf-8")
    added = [name for name in manifest_targets(head_manifest) if name not in set(manifest_targets(base_manifest))]
    graph = graph_tests(root)
    filters = fast_tier_filters(root)
    errors: list[str] = []
    warnings: list[str] = []
    for name in added:
        directory = target_directory(root, graph.get(name) or f"Tests/{name}")
        if covered_by_fast_tier(name, suites_in(directory), filters):
            continue
        tests = count_tests(directory)
        what = f"{CMUXNEXT}: the new test target {name} ({tests} test{'s' if tests != 1 else ''})"
        entry = (f"a {FAST_TIER} swift entry for it (admitted with `fast-tier.py --only NAME --repeat 20`) runs it"
                 " on every pull request")
        if full_ci:
            warnings.append(f"{what} runs here only because of full-ci (`cmux-next swift test`): {entry}")
        else:
            errors.append(f"{what} is run by no pull request check (the fast tier builds it and runs only its"
                          f" registry's filters): add {entry.removesuffix(' runs it on every pull request')}, or"
                          " label the pull request full-ci and push again so `cmux-next swift test` runs it")
    new_files = git(root, "diff", "--name-only", "--diff-filter=A", base, "HEAD", "--", f"{CMUXNEXT}/Tests") or ""
    prefixes = sorted(((name, target_directory(root, directory).relative_to(root).as_posix() + "/")
                       for name, directory in graph.items() if directory), key=lambda item: -len(item[1]))
    for path in new_files.splitlines():
        if not path.endswith(".swift"):
            continue
        owner = next((name for name, prefix in prefixes if path.startswith(prefix)), None)
        if owner is None or owner in added:
            continue
        stem = Path(path).stem
        if covered_by_fast_tier(owner, {stem}, filters) or full_ci:
            continue
        warnings.append(f"{path}: a new test file in {owner}, which no fast-tier entry covers: its tests run only"
                        " with full-ci (`cmux-next swift test`) or on feat-cmux-next after merge")
    return errors, warnings


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--base", help="the pull request's base commit: also check the test targets it adds")
    parser.add_argument("--full-ci", action="store_true", help="the pull request carries the full-ci label")
    parser.add_argument("--list", action="store_true", help="print every test target and what runs it")
    args = parser.parse_args(argv)
    root = Path(args.root)
    if args.list:
        covered = runners(root)
        registry = {Target(e["package"].rstrip("/"), e["target"]): e for e in load_registry(root)}
        for target in discover(root):
            entry = registry.get(target, {})
            runner = covered.get(target) or (entry.get("run_by") and f"{entry['run_by']}") \
                or (entry.get("not_run") and f"not run: {entry['not_run']}") or "NOTHING"
            print(f"{target.package} {target.name}: {runner}")
        return 0
    errors = check_tree(root)
    warnings: list[str] = []
    if args.base:
        diff_errors, warnings = check_diff(root, args.base, args.full_ci)
        errors += diff_errors
    for warning in warnings:
        print(f"::warning title=Swift test target coverage::{warning}")
    for error in errors:
        print(f"::error title=Swift test target coverage::{error}")
    if errors:
        print(f"swift-test-coverage: {len(errors)} problem(s); see {REGISTRY} and hq#11644", file=sys.stderr)
        return 1
    print(f"swift-test-coverage: every Swift test target ({len(discover(root))}) has a pull request runner or a"
          " registry entry")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
