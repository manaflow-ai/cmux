#!/usr/bin/env python3
"""Behavior tests for the Ghostty Zig workflow guard."""

from __future__ import annotations

import tempfile
import textwrap
from pathlib import Path

from check_ghostty_zig_workflows import workflow_failures


def failures_for(workflow: str) -> list[str]:
    with tempfile.TemporaryDirectory() as directory:
        workflow_dir = Path(directory)
        (workflow_dir / "fixture.yml").write_text(
            textwrap.dedent(workflow),
            encoding="utf-8",
        )
        return workflow_failures(workflow_dir)


def test_non_executing_mentions_do_not_require_ghostty() -> None:
    failures = failures_for(
        """\
        name: fixture
        on:
          push:
            paths:
              - scripts/install-zig-ci.sh
        jobs:
          decide:
            runs-on: ubuntu-latest
            env:
              GHOSTTY_ZIG_HELPER: scripts/ghostty-zig-version.sh
            steps:
              - uses: actions/github-script@v7
                with:
                  script: |
                    const changedPaths = [
                      'scripts/install-zig-ci.sh',
                      'scripts/build-ghostty-cli-helper.sh',
                      'scripts/ghostty-zig-version.sh',
                    ];
              - name: Render documentation
                run: |
                  # ./scripts/install-zig-ci.sh is intentionally documentation.
                  cat <<'EOF'
                  ./scripts/build-ghostty-cli-helper.sh
                  EOF
        """
    )

    assert failures == [], failures


def test_executing_consumer_before_init_fails() -> None:
    failures = failures_for(
        """\
        name: fixture
        on: workflow_dispatch
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - name: Install Zig
                run: ./scripts/install-zig-ci.sh
        """
    )

    assert len(failures) == 1, failures
    assert "build" in failures[0], failures
    assert "install-zig-ci.sh" in failures[0], failures


def test_initialized_consumer_passes() -> None:
    failures = failures_for(
        """\
        name: fixture
        on: workflow_dispatch
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - uses: actions/checkout@v6
                with:
                  submodules: recursive
              - name: Install Zig
                run: ./scripts/install-zig-ci.sh
        """
    )

    assert failures == [], failures


if __name__ == "__main__":
    test_non_executing_mentions_do_not_require_ghostty()
    test_executing_consumer_before_init_fails()
    test_initialized_consumer_passes()
    print("all Ghostty Zig workflow guard tests passed")
