#!/usr/bin/env python3
"""Classify a PR diff from the declarative CI area table."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Iterable, Optional


REPO_ROOT = Path(__file__).resolve().parents[2]
AREA_TABLE_PATH = REPO_ROOT / ".github" / "ci-areas.yml"
AREA_NAMES = (
    "force_all",
    "macos",
    "web",
    "agent_session_web",
    "release_build",
)


@dataclass(frozen=True)
class ChangeAreas:
    macos: bool
    web: bool
    agent_session_web: bool
    release_build: bool

    @classmethod
    def all(cls) -> "ChangeAreas":
        return cls(macos=True, web=True, agent_session_web=True, release_build=True)

    def as_output_lines(self) -> list[str]:
        return [
            f"macos={bool_output(self.macos)}",
            f"web={bool_output(self.web)}",
            f"agent_session_web={bool_output(self.agent_session_web)}",
            f"release_build={bool_output(self.release_build)}",
        ]


@dataclass(frozen=True)
class AreaRule:
    default: bool
    include: tuple[str, ...]
    neutral: tuple[str, ...]


def bool_output(value: bool) -> str:
    return "true" if value else "false"


def normalize_path(path: str) -> str:
    normalized = path.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def load_area_table(path: Optional[Path] = None) -> dict[str, AreaRule]:
    """Read the repository's intentionally small, dependency-free YAML subset."""
    table_path = path or AREA_TABLE_PATH
    raw: dict[str, dict[str, object]] = {}
    version: Optional[int] = None
    area: Optional[str] = None
    list_name: Optional[str] = None

    for number, source_line in enumerate(
        table_path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        line = source_line.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        if line.startswith("version:"):
            if line != "version: 1" or version is not None:
                raise ValueError(f"{table_path}:{number}: expected one 'version: 1'")
            version = 1
            area = None
            list_name = None
            continue
        if not line.startswith(" ") and line.endswith(":"):
            area = line[:-1]
            if area not in AREA_NAMES or area in raw:
                raise ValueError(f"{table_path}:{number}: unknown or duplicate area {area!r}")
            raw[area] = {"include": [], "neutral": []}
            list_name = None
            continue
        if area is None:
            raise ValueError(f"{table_path}:{number}: entry outside an area")
        if line.startswith("  default: "):
            value = line[len("  default: "):]
            if value not in {"run", "skip"} or "default" in raw[area]:
                raise ValueError(f"{table_path}:{number}: default must be run or skip")
            raw[area]["default"] = value == "run"
            list_name = None
            continue
        if line in {"  include:", "  neutral:"}:
            list_name = line.strip()[:-1]
            continue
        if line.startswith("    - ") and list_name is not None:
            try:
                pattern = json.loads(line[len("    - "):])
            except json.JSONDecodeError as error:
                raise ValueError(
                    f"{table_path}:{number}: patterns must be double-quoted strings"
                ) from error
            if not isinstance(pattern, str) or not pattern:
                raise ValueError(f"{table_path}:{number}: empty or non-string pattern")
            values = raw[area][list_name]
            assert isinstance(values, list)
            if pattern in values:
                raise ValueError(f"{table_path}:{number}: duplicate pattern {pattern!r}")
            values.append(pattern)
            continue
        raise ValueError(f"{table_path}:{number}: unsupported table syntax: {line!r}")

    if version != 1 or set(raw) != set(AREA_NAMES):
        raise ValueError(f"{table_path}: expected version 1 and areas {AREA_NAMES!r}")

    parsed: dict[str, AreaRule] = {}
    for name in AREA_NAMES:
        data = raw[name]
        if "default" not in data:
            raise ValueError(f"{table_path}: area {name!r} is missing default")
        parsed[name] = AreaRule(
            default=bool(data["default"]),
            include=tuple(data["include"]),
            neutral=tuple(data["neutral"]),
        )
    return parsed


@lru_cache(maxsize=None)
def _glob_regex(pattern: str) -> re.Pattern[str]:
    regex = ["^"]
    index = 0
    while index < len(pattern):
        if pattern.startswith("**/", index):
            regex.append("(?:.*/)?")
            index += 3
            continue
        if pattern.startswith("**", index):
            regex.append(".*")
            index += 2
            continue
        char = pattern[index]
        if char == "*":
            regex.append("[^/]*")
        elif char == "?":
            regex.append("[^/]")
        else:
            regex.append(re.escape(char))
        index += 1
    regex.append("$")
    return re.compile("".join(regex))


def path_matches(pattern: str, path: str) -> bool:
    return _glob_regex(pattern).fullmatch(path) is not None


def _matches(patterns: tuple[str, ...], path: str) -> bool:
    return any(path_matches(pattern, path) for pattern in patterns)


def rule_runs(rule: AreaRule, path: str) -> bool:
    if _matches(rule.include, path):
        return True
    if _matches(rule.neutral, path):
        return False
    return rule.default


def _force_all(table: dict[str, AreaRule], path: str) -> bool:
    rule = table["force_all"]
    # Known dedicated control-plane helpers are explicit exceptions to the
    # broad scripts/ci/** fail-open rule. Unknown CI helpers still force all.
    if _matches(rule.neutral, path):
        return False
    if _matches(rule.include, path):
        return True
    return rule.default


def is_web_change(path: str) -> bool:
    path = normalize_path(path)
    table = load_area_table()
    return _force_all(table, path) or rule_runs(table["web"], path)


def is_agent_session_web_change(path: str) -> bool:
    path = normalize_path(path)
    table = load_area_table()
    return _force_all(table, path) or rule_runs(table["agent_session_web"], path)


def is_macos_change(path: str) -> bool:
    path = normalize_path(path)
    table = load_area_table()
    return _force_all(table, path) or rule_runs(table["macos"], path)


def is_macos_neutral(path: str) -> bool:
    return not is_macos_change(path)


def is_test_only_source(path: str) -> bool:
    path = normalize_path(path)
    table = load_area_table()
    return is_macos_change(path) and not rule_runs(table["release_build"], path)


def classify_files(paths: Iterable[str]) -> ChangeAreas:
    table = load_area_table()
    macos = False
    web = False
    agent_session_web = False
    release_build = False

    for raw_path in paths:
        path = normalize_path(raw_path)
        if not path:
            continue
        if _force_all(table, path):
            return ChangeAreas.all()

        path_macos = rule_runs(table["macos"], path)
        macos = macos or path_macos
        web = web or rule_runs(table["web"], path)
        agent_session_web = (
            agent_session_web or rule_runs(table["agent_session_web"], path)
        )
        if path_macos and rule_runs(table["release_build"], path):
            release_build = True

    return ChangeAreas(
        macos=macos,
        web=web,
        agent_session_web=agent_session_web,
        release_build=release_build,
    )


def run_git(args: list[str]) -> str:
    return subprocess.check_output(
        ["git", *args], text=True, stderr=subprocess.STDOUT
    ).strip()


def changed_files(base_sha: str, head_sha: str) -> list[str]:
    merge_base = run_git(["merge-base", base_sha, head_sha])
    output = run_git(["diff", "--name-only", merge_base, head_sha])
    return [line for line in output.splitlines() if line.strip()]


def write_outputs(areas: ChangeAreas, output_path: Optional[str]) -> None:
    if not output_path:
        return
    with Path(output_path).open("a", encoding="utf-8") as handle:
        for line in areas.as_output_lines():
            handle.write(f"{line}\n")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event-name", default=os.environ.get("GITHUB_EVENT_NAME", ""))
    parser.add_argument("--base-sha", default="")
    parser.add_argument("--head-sha", default="")
    parser.add_argument(
        "--github-output",
        default=os.environ.get("GITHUB_OUTPUT"),
        help="Path to append GitHub Actions step outputs to.",
    )
    parser.add_argument(
        "--files-from",
        type=Path,
        help="Read changed files from this newline-delimited file instead of git.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if args.event_name not in {"pull_request", "merge_group"}:
        areas = ChangeAreas.all()
        print(f"Non-PR event '{args.event_name or 'unknown'}'; running all CI areas.")
        write_outputs(areas, args.github_output)
        print("Resolved areas: " + " ".join(areas.as_output_lines()))
        return 0

    files: list[str] = []
    try:
        if args.files_from:
            files = args.files_from.read_text(encoding="utf-8").splitlines()
        else:
            if not args.base_sha or not args.head_sha:
                raise RuntimeError("pull_request event is missing base/head SHA")
            files = changed_files(args.base_sha, args.head_sha)
        if files:
            areas = classify_files(files)
        else:
            areas = ChangeAreas.all()
            print("PR diff is empty; running all CI areas.")
    except Exception as error:
        areas = ChangeAreas.all()
        print(f"Could not classify diff, running all CI areas: {error}", file=sys.stderr)

    if files:
        print("Changed files:")
        for path in files:
            print(path)
    else:
        print("Changed files: (none)")

    write_outputs(areas, args.github_output)
    print("Resolved areas: " + " ".join(areas.as_output_lines()))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
