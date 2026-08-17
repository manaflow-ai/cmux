#!/usr/bin/env python3
"""Contract tests for the web-only pull request workflow."""

from __future__ import annotations

import fnmatch
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "web-ci.yml"


def _workflow_text() -> str:
    assert WORKFLOW.is_file(), f"missing web workflow: {WORKFLOW}"
    return WORKFLOW.read_text(encoding="utf-8")


def _top_level_section(text: str, name: str) -> str:
    lines = text.splitlines()
    marker = f"{name}:"
    try:
        start = lines.index(marker)
    except ValueError as error:
        raise AssertionError(f"missing top-level {name} section") from error

    body: list[str] = []
    for line in lines[start + 1 :]:
        if line and not line.startswith((" ", "\t")):
            break
        body.append(line)
    return "\n".join(body)


def _pull_request_paths(text: str) -> list[str]:
    trigger = _top_level_section(text, "on")
    lines = trigger.splitlines()
    try:
        start = next(index for index, line in enumerate(lines) if line == "  pull_request:")
    except StopIteration as error:
        raise AssertionError("web workflow must declare a pull_request trigger") from error

    paths: list[str] = []
    for line in lines[start + 1 :]:
        if line.startswith("  ") and not line.startswith("    ") and line.strip():
            break
        match = re.fullmatch(r'\s+-\s+"([^"]+)"', line)
        if match:
            paths.append(match.group(1))
    return paths


def _job_block(text: str, job_name: str) -> str:
    lines = text.splitlines()
    marker = f"  {job_name}:"
    try:
        start = lines.index(marker)
    except ValueError as error:
        raise AssertionError(f"missing {job_name} job") from error

    body = [lines[start]]
    for line in lines[start + 1 :]:
        if line and line.startswith("  ") and not line.startswith("    "):
            break
        body.append(line)
    return "\n".join(body)


def test_web_pull_request_path_runs_web_typecheck() -> None:
    text = _workflow_text()
    paths = _pull_request_paths(text)

    assert any(fnmatch.fnmatch("web/app/page.tsx", pattern) for pattern in paths), paths
    assert not any(fnmatch.fnmatch("Sources/AppDelegate.swift", pattern) for pattern in paths), paths

    job = _job_block(text, "web-typecheck")
    assert "runs-on: ubuntu-24.04" in job
    assert "bun run typecheck" in job
    assert "bun install --frozen-lockfile" in job
    assert "working-directory: web" in job
    assert "if:" not in job


def test_web_workflow_is_pr_only_and_read_only() -> None:
    text = _workflow_text()
    trigger = _top_level_section(text, "on")

    assert "pull_request:" in trigger
    assert "push:" not in trigger
    assert "workflow_dispatch:" not in trigger
    assert "permissions:\n  contents: read" in text
    assert "persist-credentials: false" in text


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("PASS: web CI workflow contract")
