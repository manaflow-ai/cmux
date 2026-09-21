#!/usr/bin/env python3
"""Classify a PR diff into CI areas that should run."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional


@dataclass(frozen=True)
class ChangeAreas:
    macos: bool
    web: bool
    agent_session_web: bool
    release_build: bool

    @classmethod
    def all(cls) -> ChangeAreas:
        return cls(macos=True, web=True, agent_session_web=True, release_build=True)

    def as_output_lines(self) -> list[str]:
        return [
            f"macos={bool_output(self.macos)}",
            f"web={bool_output(self.web)}",
            f"agent_session_web={bool_output(self.agent_session_web)}",
            f"release_build={bool_output(self.release_build)}",
        ]


def bool_output(value: bool) -> str:
    return "true" if value else "false"


def normalize_path(path: str) -> str:
    normalized = path.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
GUARD_WORKFLOW_PATH = ".github/workflows/ci-guards.yml"
WEB_WORKFLOW_PATH = ".github/workflows/ci-web.yml"


def is_other_workflow_config(path: str) -> bool:
    # ci.yml's macOS and web jobs read no other workflow file. An edit to one is
    # checked by the reusable guard workflow and by that workflow's own triggers.
    if path == CI_WORKFLOW_PATH:
        return False
    return path.startswith(".github/workflows/") or path == ".github/actionlint.yaml"


def forces_all_areas(path: str) -> bool:
    ci_script_prefix = "scripts/ci/"
    is_direct_ci_python = path.startswith(ci_script_prefix) and path.endswith(".py")
    if is_direct_ci_python:
        is_direct_ci_python = "/" not in path[len(ci_script_prefix) :]
    return path == CI_WORKFLOW_PATH or is_direct_ci_python or path == "tests/test_ci_change_areas.py"


_TEST_REFERENCE_RE = re.compile(r"tests/[A-Za-z0-9_./-]*")


def is_plainly_linux_runner(runs_on: str) -> bool:
    # Anything else counts as macOS: a matrix or needs expression, a list or
    # group on the following lines, or a label this does not recognize.
    value = runs_on.strip()
    if not value or re.search(r"macos|matrix\.|needs\.|inputs\.", value, re.IGNORECASE):
        return False
    return bool(re.search(r"LINUX_RUNNER|LINUX_ARM64_RUNNER|ubuntu", value))


_JOB_SPLIT_RE = re.compile(r"(?m)^  (?=[A-Za-z0-9_-]+:\s*$)")

# `changes` routes every other job and `ci-status` is the required gate, so an
# edit to either always runs every area.
_ROUTING_JOBS = frozenset({"changes", "ci-status"})


def split_workflow_jobs(workflow: str) -> Optional[tuple[str, dict[str, str]]]:
    """Return the text before `jobs:` and each job's block, or None if unreadable."""
    preamble, found, body = workflow.partition("\njobs:\n")
    if not found:
        return None
    jobs: dict[str, str] = {}
    for block in _JOB_SPLIT_RE.split(body):
        name, _, _ = block.partition(":")
        if not block.strip():
            continue
        if not re.fullmatch(r"[A-Za-z0-9_-]+", name) or name in jobs:
            return None
        jobs[name] = block
    return (preamble, jobs) if jobs else None


def job_is_plainly_linux(block: str) -> bool:
    runs_on = re.search(r"(?m)^    runs-on:[ \t]*(.*)$", block)
    return bool(runs_on) and is_plainly_linux_runner(runs_on.group(1))


def ci_workflow_change_is_linux_only(base: str, head: str) -> bool:
    """True when base and head ci.yml differ only in jobs that run on Linux.

    Triggers, env, permissions and concurrency live before `jobs:` and reach
    every job, so any change there is not Linux-only. Unreadable input and an
    unchanged file are not Linux-only either, so the caller fails open.
    """
    base_parts = split_workflow_jobs(base)
    head_parts = split_workflow_jobs(head)
    if base_parts is None or head_parts is None:
        return False
    (base_preamble, base_jobs), (head_preamble, head_jobs) = base_parts, head_parts
    if base_preamble != head_preamble:
        return False
    changed = {
        name
        for name in base_jobs.keys() | head_jobs.keys()
        if base_jobs.get(name) != head_jobs.get(name)
    }
    if not changed or changed & _ROUTING_JOBS:
        return False
    return all(
        job_is_plainly_linux(jobs[name])
        for name in changed
        for jobs in (base_jobs, head_jobs)
        if name in jobs
    )


def macos_job_test_references(workflow: str) -> Optional[tuple[frozenset[str], frozenset[str]]]:
    """Return the tests/ paths ci.yml names in non-Linux jobs and in all jobs.

    A macOS job that runs tests through a glob yields the glob's literal prefix.
    Returns None when the jobs cannot be read, so the caller fails open.
    """
    _, found, body = workflow.partition("\njobs:\n")
    if not found:
        return None
    macos: set[str] = set()
    everywhere: set[str] = set()
    jobs = 0
    for block in re.split(r"(?m)^  (?=[A-Za-z0-9_-]+:\s*$)", body):
        runs_on = re.search(r"(?m)^    runs-on:[ \t]*(.*)$", block)
        if not runs_on:
            continue
        jobs += 1
        references = set(_TEST_REFERENCE_RE.findall(block))
        everywhere |= references
        if not is_plainly_linux_runner(runs_on.group(1)):
            macos |= references
    if jobs == 0:
        return None
    return frozenset(macos), frozenset(everywhere)


def load_macos_job_test_references() -> Optional[tuple[frozenset[str], frozenset[str]]]:
    macos: set[str] = set()
    everywhere: set[str] = set()
    try:
        for workflow_path in (CI_WORKFLOW_PATH, GUARD_WORKFLOW_PATH, WEB_WORKFLOW_PATH):
            references = macos_job_test_references(Path(workflow_path).read_text(encoding="utf-8"))
            if references is None:
                return None
            workflow_macos, workflow_everywhere = references
            macos.update(workflow_macos)
            everywhere.update(workflow_everywhere)
    except OSError:
        return None
    return frozenset(macos), frozenset(everywhere)


def is_guard_only_test(path: str, references: Optional[tuple[frozenset[str], frozenset[str]]]) -> bool:
    # A tests/ file is macOS-neutral only when a CI workflow names it and every
    # job that names it runs on Linux. An unnamed file may be imported by a test a
    # macOS job runs, so it stays macOS-relevant.
    if references is None or not path.startswith("tests/"):
        return False
    macos, everywhere = references
    if path not in everywhere:
        return False
    return not any(path.startswith(reference) for reference in macos)


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
    # `cmux-tui/` is the standalone cmux-tui Rust project, gated by its own
    # workflow. Packages/iOS stays macOS-relevant because the desktop app
    # links CmuxMobileRPC, CmuxMobileTransport, and their package dependencies.
    if path.startswith(
        (
            "docs/",
            "design/",
            "plans/",
            "ios/",
            "web/",
            "webviews/",
            "cmux-tui/",
        )
    ):
        return True
    if path == "README.md" or (path.startswith("README.") and path.endswith(".md")):
        return True
    # Agent instructions at any depth, and skill documentation. The app bundles
    # skills/cmux-cua as a folder resource, and skill scripts and manifests are
    # executable inputs, so only Markdown outside that folder is neutral.
    if path.rsplit("/", 1)[-1] in {"CLAUDE.md", "AGENTS.md"}:
        return True
    return path.startswith("skills/") and path.endswith(".md") and not path.startswith("skills/cmux-cua/")


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


_PACKAGE_TESTS_RE = re.compile(r"Packages/[^/]+/[^/]+/Tests/")


def is_test_only_source(path: str) -> bool:
    # The Release app builds only the cmux target, so test sources cannot reach
    # it. A new test file also edits project.pbxproj, which is not matched here.
    return path.startswith(("cmuxTests/", "cmuxUITests/")) or bool(_PACKAGE_TESTS_RE.match(path))


def classify_files(paths: Iterable[str], *, ci_workflow_linux_only: bool = False) -> ChangeAreas:
    macos = False
    web = False
    agent_session_web = False
    release_build = False
    test_references = load_macos_job_test_references()

    for raw_path in paths:
        path = normalize_path(raw_path)
        if not path:
            continue
        if path == CI_WORKFLOW_PATH and ci_workflow_linux_only:
            continue
        if forces_all_areas(path):
            macos = True
            web = True
            agent_session_web = True
            release_build = True
            continue
        if is_other_workflow_config(path) or is_guard_only_test(path, test_references):
            continue
        if is_web_change(path):
            web = True
        if is_agent_session_web_change(path):
            agent_session_web = True
        if is_macos_change(path):
            macos = True
            if not is_test_only_source(path):
                release_build = True

    return ChangeAreas(
        macos=macos,
        web=web,
        agent_session_web=agent_session_web,
        release_build=release_build,
    )


def ci_workflow_linux_only(base_path: Optional[Path]) -> bool:
    if base_path is None:
        return False
    try:
        base = base_path.read_text(encoding="utf-8")
        head = Path(CI_WORKFLOW_PATH).read_text(encoding="utf-8")
    except OSError:
        return False
    linux_only = ci_workflow_change_is_linux_only(base, head)
    print(f"ci.yml changed; only Linux jobs differ: {bool_output(linux_only)}")
    return linux_only


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
        "--ci-workflow-base",
        type=Path,
        help="The base revision of ci.yml, to compare its jobs with the checked-out one.",
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
            areas = classify_files(files, ci_workflow_linux_only=ci_workflow_linux_only(args.ci_workflow_base))
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
