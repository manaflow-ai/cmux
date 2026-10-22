#!/usr/bin/env python3
"""Read scripts/cmux-next/swift-test-shards.json, the shards of cmux-next.yml's swift-test job.

    swift_test_shards.py check
        exit 1, naming each problem, when a CmuxNext test target is in no shard or in two,
        a shard names a target the package does not have, or a serial step names a suite
        its target's sources do not declare.
    swift_test_shards.py matrix --targets "$SWIFT_TARGETS"
        the shards with work for these targets, as one JSON line: {"include": [...]} with
        each shard's name, runner, filter and script_tests. A shard has work when the route
        selected one of its targets, or when it runs the script tests.
    swift_test_shards.py filter --shard NAME --targets "$SWIFT_TARGETS"
        the `swift test --filter` regex for the selected targets in that shard ('' when none).

SWIFT_TARGETS is cmux-next.yml's path_route output: "all", '' (none) or target names
separated by spaces. A filter has scripts/ci/cmux_next_route.py swift_filter()'s form.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "scripts/cmux-next/swift-test-shards.json"
RUNNERS = ("gui", "mac")
SERIAL_FIELDS = {"name", "when_targets", "target", "timeout_minutes", "hang_seconds", "no_parallel",
                 "suite", "filter", "skip", "each_case"}


def load(path: Path = MANIFEST) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def package_test_targets(package_swift: str) -> list[str]:
    """The test target names a Package.swift declares, in file order."""
    return re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"', package_swift)


def all_targets(manifest: dict) -> list[str]:
    return [target for shard in manifest["shards"] for target in shard["targets"]]


def declares(sources: Path, suite: str) -> bool:
    pattern = re.compile(rf"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:final|public|private|fileprivate|internal)\s+)*"
                         rf"(?:struct|class|actor|enum|extension)\s+{re.escape(suite)}\b", re.MULTILINE)
    return any(pattern.search(path.read_text(encoding="utf-8", errors="replace")) for path in sources.rglob("*.swift"))


def problems(manifest: dict, root: Path = ROOT) -> list[str]:
    package = root / manifest["package"]
    declared = package_test_targets((package / "Package.swift").read_text(encoding="utf-8"))
    found: list[str] = []
    seen: dict[str, str] = {}
    names = [shard["name"] for shard in manifest["shards"]]
    for name in {name for name in names if names.count(name) > 1}:
        found.append(f"shard {name} is listed more than once")
    for shard in manifest["shards"]:
        name = shard["name"]
        if shard.get("runner") not in RUNNERS:
            found.append(f"{name}: runner {shard.get('runner')!r} is not one of {', '.join(RUNNERS)}")
        if shard["targets"] != sorted(shard["targets"]):
            found.append(f"{name}: targets are not sorted")
        for target in shard["targets"]:
            if target in seen:
                found.append(f"{target} is in {seen[target]} and {name}")
            seen.setdefault(target, name)
            if target not in declared:
                found.append(f"{name}: {target} is not a test target in {manifest['package']}/Package.swift")
        serial_skips = set()
        for step in shard.get("serial", []):
            label = f"{name}: serial step {step.get('name')!r}"
            unknown = set(step) - SERIAL_FIELDS
            if unknown:
                found.append(f"{label} has unknown fields {sorted(unknown)}")
            if ("suite" in step) == ("filter" in step):
                found.append(f"{label} needs exactly one of suite and filter")
            if step["target"] not in shard["targets"]:
                found.append(f"{label} runs {step['target']}, which is not in {name}")
            for target in step["when_targets"]:
                if target not in declared:
                    found.append(f"{label} waits on {target}, which is not a test target")
            sources = package / "Tests" / step["target"]
            if "suite" in step:
                serial_skips.add(step["suite"])
                if not declares(sources, step["suite"]):
                    found.append(f"{label}: no {step['suite']} in {manifest['package']}/Tests/{step['target']}")
            else:
                serial_skips.add(step["filter"])
            for skipped in step.get("skip", []):
                if not declares(sources, skipped):
                    found.append(f"{label}: skips {skipped}, which {step['target']} does not declare")
        # A suite a serial step skips runs in a serial step of its own, never nowhere; the
        # parallel run leaves out every serial step's filter and every other serial suite.
        step_skips = {skipped for step in shard.get("serial", []) for skipped in step.get("skip", [])}
        for skipped in sorted(step_skips - serial_skips):
            found.append(f"{name}: {skipped} is skipped by a serial step and run by none")
        expected = serial_skips - step_skips
        if set(shard.get("parallel_skip", [])) != expected:
            found.append(f"{name}: parallel_skip {sorted(shard.get('parallel_skip', []))} is not the suites and "
                         f"filters its serial steps run on their own {sorted(expected)}")
    for target in declared:
        if target not in seen:
            found.append(f"{target} is in no shard of {MANIFEST.relative_to(ROOT)}")
    if sum(1 for shard in manifest["shards"] if shard.get("script_tests")) != 1:
        found.append("exactly one shard runs the script tests (script_tests: true)")
    return found


def selected(manifest: dict, targets: str) -> set[str]:
    targets = targets.strip()
    if targets == "all":
        return set(all_targets(manifest))
    return set(targets.split())


def target_filter(names: list[str] | set[str]) -> str:
    return "^(" + "|".join(sorted(names)) + ")\\." if names else ""


def shard(manifest: dict, name: str) -> dict:
    for candidate in manifest["shards"]:
        if candidate["name"] == name:
            return candidate
    raise SystemExit(f"swift_test_shards: no shard {name!r}")


def shard_filter(manifest: dict, name: str, targets: str) -> str:
    return target_filter(selected(manifest, targets) & set(shard(manifest, name)["targets"]))


def matrix(manifest: dict, targets: str) -> dict:
    include = []
    for entry in manifest["shards"]:
        chosen = selected(manifest, targets) & set(entry["targets"])
        if chosen or entry.get("script_tests"):
            include.append({"shard": entry["name"], "runner": entry["runner"], "filter": target_filter(chosen),
                            "script_tests": bool(entry.get("script_tests"))})
    return {"include": include}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--manifest", type=Path, default=MANIFEST)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check")
    for name in ("matrix", "filter"):
        command = commands.add_parser(name)
        command.add_argument("--targets", required=True)
        if name == "filter":
            command.add_argument("--shard", required=True)
    args = parser.parse_args(argv)
    manifest = load(args.manifest)
    if args.command == "check":
        found = problems(manifest)
        for problem in found:
            print(f"swift-test-shards: {problem}", file=sys.stderr)
        return 1 if found else 0
    if args.command == "matrix":
        print(json.dumps(matrix(manifest, args.targets), separators=(",", ":")))
    else:
        print(shard_filter(manifest, args.shard, args.targets))
    return 0


if __name__ == "__main__":
    sys.exit(main())
