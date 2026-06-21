#!/usr/bin/env python3
"""Classify a PR diff into CI areas that should run."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional


@dataclass(frozen=True)
class ChangeAreas:
    macos: bool
    web: bool
    go: bool
    agent_session_web: bool

    @classmethod
    def all(cls) -> ChangeAreas:
        return cls(macos=True, web=True, go=True, agent_session_web=True)

    def as_output_lines(self) -> list[str]:
        return [
            f"macos={bool_output(self.macos)}",
            f"web={bool_output(self.web)}",
            f"go={bool_output(self.go)}",
            f"agent_session_web={bool_output(self.agent_session_web)}",
        ]


def bool_output(value: bool) -> str:
    return "true" if value else "false"


def normalize_path(path: str) -> str:
    normalized = path.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def is_workflow(path: str) -> bool:
    return path.startswith(".github/workflows/")


def forces_all_areas(path: str) -> bool:
    ci_script_prefix = "scripts/ci/"
    is_direct_ci_python = path.startswith(ci_script_prefix) and path.endswith(".py")
    if is_direct_ci_python:
        is_direct_ci_python = "/" not in path[len(ci_script_prefix) :]
    return is_workflow(path) or is_direct_ci_python or path == "tests/test_ci_change_areas.py"


def is_web_change(path: str) -> bool:
    if path.startswith(
        (
            "web/",
            "webviews/",
            "Resources/agent-session-react/",
            "Resources/agent-session-solid/",
            "Resources/markdown-viewer/",
        )
    ):
        return True
    if path == "CHANGELOG.md":
        return True
    return path in {
        "package.json",
        "bun.lock",
        "biome.json",
        "scripts/build-agent-session-web.sh",
        "scripts/build-webviews-app.sh",
        "scripts/check-webviews-react-compiler.mjs",
    }


def is_go_change(path: str) -> bool:
    return path.startswith("daemon/remote/") or path in {
        "scripts/build_remote_daemon_release_assets.sh",
        "tests/test_remote_daemon_release_assets.sh",
    }


def is_agent_session_web_change(path: str) -> bool:
    if path.startswith(
        (
            "webviews/src/agent-session/",
            "Resources/agent-session-react/",
            "Resources/agent-session-solid/",
        )
    ):
        return True
    return path in {
        "package.json",
        "bun.lock",
        "webviews/package.json",
        "webviews/bun.lock",
        "scripts/build-agent-session-web.sh",
        "Resources/markdown-viewer/marked.min.js",
    }


def is_macos_neutral(path: str) -> bool:
    if path.startswith(("docs/", "design/", "plans/", "ios/", "web/", "webviews/", "daemon/remote/")):
        return True
    return path == "README.md" or (path.startswith("README.") and path.endswith(".md"))


def is_macos_change(path: str) -> bool:
    if path.startswith("webviews/src/agent-session/"):
        return True
    if path == "docs/cli-contract.md":
        return True
    if path in {"package.json", "bun.lock", "biome.json"}:
        return True
    if path.startswith(("Resources/agent-session-react/", "Resources/agent-session-solid/")):
        return True
    return not is_macos_neutral(path)


def classify_files(paths: Iterable[str]) -> ChangeAreas:
    macos = False
    web = False
    go = False
    agent_session_web = False

    for raw_path in paths:
        path = normalize_path(raw_path)
        if not path:
            continue
        if forces_all_areas(path):
            macos = True
            web = True
            go = True
            agent_session_web = True
            continue
        if is_web_change(path):
            web = True
        if is_go_change(path):
            go = True
        if is_agent_session_web_change(path):
            agent_session_web = True
        if is_macos_change(path):
            macos = True

    return ChangeAreas(
        macos=macos,
        web=web,
        go=go,
        agent_session_web=agent_session_web,
    )


def run_git(args: list[str]) -> str:
    return subprocess.check_output(["git", *args], text=True, stderr=subprocess.STDOUT).strip()


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

    if args.event_name != "pull_request":
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
