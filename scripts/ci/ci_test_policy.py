#!/usr/bin/env python3
"""Load and validate the explicit PR test-suite execution policy."""

from __future__ import annotations

import argparse
import fnmatch
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / "config" / "ci-test-suites.json"
PLATFORMS = frozenset({"shared", "macos", "ios", "web"})
AGGREGATES = {"shared": "Shared", "macos": "macOS", "ios": "iOS", "web": "Web"}
MODES = frozenset({"off", "selective", "always"})
REQUIRED_FIELDS = frozenset(
    {"id", "platform", "aggregate", "pr_mode", "test_paths", "source_paths", "budget_seconds"}
)
OPTIONAL_FIELDS = frozenset({"selector_prefix", "source_exclude_paths"})
TEST_ROOTS = (
    "cmuxTests/",
    "cmuxCLITests/",
    "cmuxCLITestSupport/",
    "cmuxUITests/",
    "ios/cmuxUITests/",
    "ios/tests/",
    "ios/cmuxPackage/Tests/",
    "web/tests/",
    "webviews/test/",
)
PRODUCT_ROOTS = (
    "Sources/",
    "CLI/",
    "TunnelExtension/",
    "Packages/",
    "ios/",
    "web/",
    "webviews/",
    "vendor/",
    "Examples/",
)


@dataclass(frozen=True)
class SuitePolicy:
    id: str
    platform: str
    aggregate: str
    pr_mode: str
    test_paths: tuple[str, ...]
    source_paths: tuple[str, ...]
    source_exclude_paths: tuple[str, ...]
    budget_seconds: int
    selector_prefix: str = ""

    def matches_test(self, path: str) -> bool:
        return any(path_matches(path, pattern) for pattern in self.test_paths)

    def matches_source(self, path: str) -> bool:
        return (
            any(path_matches(path, pattern) for pattern in self.source_paths)
            and not any(path_matches(path, pattern) for pattern in self.source_exclude_paths)
        )


class PolicyError(ValueError):
    """The policy is malformed or leaves a test without an owner."""


def path_matches(path: str, pattern: str) -> bool:
    """Match a repository path, treating a trailing slash as a directory root."""
    path = normalize_path(path)
    pattern = normalize_path(pattern)
    if pattern.endswith("/"):
        return path.startswith(pattern)
    return fnmatch.fnmatchcase(path, pattern)


def normalize_path(path: str) -> str:
    value = path.strip().replace("\\", "/")
    while value.startswith("./"):
        value = value[2:]
    return value


def _string_list(value: object, *, field: str, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value or not all(isinstance(item, str) for item in value):
        raise PolicyError(f"{label}: {field} must be a non-empty list of strings")
    normalized = tuple(normalize_path(item) for item in value)
    if any(not item or item.startswith("/") or ".." in item.split("/") for item in normalized):
        raise PolicyError(f"{label}: {field} contains an invalid repository path")
    return normalized


def load_policy(path: Path = DEFAULT_MANIFEST) -> tuple[SuitePolicy, ...]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PolicyError(f"{path}: cannot read policy JSON: {error}") from error
    if not isinstance(document, dict):
        raise PolicyError(f"{path}: expected a JSON object")
    unknown_top_level = set(document) - {"version", "comment", "suite"}
    if unknown_top_level:
        raise PolicyError(f"{path}: unknown top-level fields: {', '.join(sorted(unknown_top_level))}")
    if document.get("version") != 1:
        raise PolicyError(f"{path}: expected version = 1")
    raw_suites = document.get("suite")
    if not isinstance(raw_suites, list) or not raw_suites:
        raise PolicyError(f"{path}: expected at least one suite entry")

    policies: list[SuitePolicy] = []
    ids: set[str] = set()
    for index, raw in enumerate(raw_suites, start=1):
        label = f"{path}:suite[{index}]"
        if not isinstance(raw, dict):
            raise PolicyError(f"{label}: expected a table")
        unknown = set(raw) - REQUIRED_FIELDS - OPTIONAL_FIELDS
        missing = REQUIRED_FIELDS - set(raw)
        if unknown:
            raise PolicyError(f"{label}: unknown fields: {', '.join(sorted(unknown))}")
        if missing:
            raise PolicyError(f"{label}: missing fields: {', '.join(sorted(missing))}")
        values = {field: raw[field] for field in REQUIRED_FIELDS}
        suite_id = values["id"]
        if not isinstance(suite_id, str) or not suite_id or suite_id in ids:
            raise PolicyError(f"{label}: id must be a unique non-empty string")
        ids.add(suite_id)
        platform = values["platform"]
        mode = values["pr_mode"]
        aggregate = values["aggregate"]
        if not isinstance(platform, str) or platform not in PLATFORMS:
            raise PolicyError(f"{label}: unsupported platform {platform!r}")
        if not isinstance(mode, str) or mode not in MODES:
            raise PolicyError(f"{label}: unsupported pr_mode {mode!r}")
        if not isinstance(aggregate, str) or aggregate != AGGREGATES[platform]:
            raise PolicyError(
                f"{label}: aggregate must be {AGGREGATES[platform]!r} for platform {platform!r}"
            )
        budget = values["budget_seconds"]
        if not isinstance(budget, int) or isinstance(budget, bool) or budget < 0:
            raise PolicyError(f"{label}: budget_seconds must be a non-negative integer")
        if mode == "selective" and budget == 0:
            raise PolicyError(f"{label}: selective suites need a positive budget")
        test_paths = _string_list(values["test_paths"], field="test_paths", label=label)
        source_paths = _string_list(values["source_paths"], field="source_paths", label=label)
        raw_source_excludes = raw.get("source_exclude_paths", [])
        source_exclude_paths = (
            () if raw_source_excludes == [] else _string_list(
                raw_source_excludes, field="source_exclude_paths", label=label
            )
        )
        selector_prefix = raw.get("selector_prefix", "")
        if not isinstance(selector_prefix, str):
            raise PolicyError(f"{label}: selector_prefix must be a string")
        policies.append(
            SuitePolicy(
                id=suite_id,
                platform=platform,
                aggregate=aggregate,
                pr_mode=mode,
                test_paths=test_paths,
                source_paths=source_paths,
                source_exclude_paths=source_exclude_paths,
                budget_seconds=budget,
                selector_prefix=normalize_path(selector_prefix),
            )
        )
    return tuple(policies)


def candidate_test_path(path: str) -> bool:
    """Whether a path is a product test that needs an explicit policy owner."""
    path = normalize_path(path)
    if path.startswith(TEST_ROOTS):
        return True
    if path.startswith(("Packages/", "Examples/", "vendor/")):
        components = path.split("/")[:-1]
        return "Tests" in components or any(component.endswith("Tests") for component in components)
    return False


def unmatched_product_paths(paths: Iterable[str], *, manifest: Path = DEFAULT_MANIFEST) -> tuple[str, ...]:
    """Changed product paths that no suite can safely classify."""
    policies = load_policy(manifest)
    unmatched: list[str] = []
    for raw_path in paths:
        path = normalize_path(raw_path)
        if not path.startswith(PRODUCT_ROOTS):
            continue
        if not any(policy.matches_test(path) or policy.matches_source(path) for policy in policies):
            unmatched.append(path)
    return tuple(sorted(set(unmatched)))


def matching_suites(
    paths: Iterable[str], *, manifest: Path = DEFAULT_MANIFEST, include_sources: bool = True
) -> dict[str, tuple[str, ...]]:
    policies = load_policy(manifest)
    matched: dict[str, list[str]] = {policy.id: [] for policy in policies}
    for policy in policies:
        if policy.pr_mode == "always":
            matched[policy.id].append("<always>")
    for raw_path in paths:
        path = normalize_path(raw_path)
        for policy in policies:
            if policy.pr_mode == "off":
                continue
            if policy.matches_test(path) or (include_sources and policy.matches_source(path)):
                matched[policy.id].append(path)
    return {suite_id: tuple(values) for suite_id, values in matched.items() if values}


def unmatched_test_paths(paths: Iterable[str], *, manifest: Path = DEFAULT_MANIFEST) -> tuple[str, ...]:
    policies = load_policy(manifest)
    unmatched: list[str] = []
    for raw_path in paths:
        path = normalize_path(raw_path)
        if candidate_test_path(path) and not any(policy.matches_test(path) for policy in policies):
            unmatched.append(path)
    return tuple(sorted(set(unmatched)))


def selector_pr_mode(selector: str, *, manifest: Path = DEFAULT_MANIFEST) -> str | None:
    selector = normalize_path(selector)
    for policy in load_policy(manifest):
        if policy.selector_prefix and selector.startswith(policy.selector_prefix):
            return policy.pr_mode
    return None


def repository_test_paths(root: Path = ROOT) -> list[str]:
    paths: list[str] = []
    for candidate in root.rglob("*"):
        if not candidate.is_file():
            continue
        relative = candidate.relative_to(root).as_posix()
        if candidate_test_path(relative):
            paths.append(relative)
    return sorted(paths)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--files-from", type=Path, help="changed repository paths, one per line")
    parser.add_argument("--check-test-paths", action="store_true", help="check all product test paths")
    parser.add_argument("--json", action="store_true", help="emit the selected policy as JSON")
    args = parser.parse_args(argv)
    try:
        load_policy(args.manifest)
        paths: list[str] = []
        if args.files_from:
            paths = args.files_from.read_text(encoding="utf-8").splitlines()
        elif args.check_test_paths:
            paths = repository_test_paths()
        if args.files_from or args.check_test_paths:
            missing = unmatched_test_paths(paths, manifest=args.manifest)
            if missing:
                raise PolicyError("test paths have no PR suite policy: " + ", ".join(missing))
            if args.files_from:
                missing_product = unmatched_product_paths(paths, manifest=args.manifest)
                if missing_product:
                    raise PolicyError(
                        "product paths have no PR suite policy: " + ", ".join(missing_product)
                    )
            selected = matching_suites(paths, manifest=args.manifest)
            payload = {"suites": selected, "platforms": sorted({
                policy.platform
                for policy in load_policy(args.manifest)
                if policy.id in selected
            })}
            if args.json:
                print(json.dumps({
                    "suites": sorted(payload["suites"]),
                    "platforms": payload["platforms"],
                }, sort_keys=True))
            elif args.check_test_paths:
                print(
                    f"PASS: {len(paths)} product test paths have explicit PR policy "
                    f"({len(selected)} suites available)"
                )
            else:
                for suite_id, suite_paths in selected.items():
                    print(f"{suite_id}: {', '.join(suite_paths)}")
        else:
            print(f"PASS: {args.manifest} is valid")
    except (OSError, PolicyError) as error:
        print(f"FAIL: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
