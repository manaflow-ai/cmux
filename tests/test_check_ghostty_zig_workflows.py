#!/usr/bin/env python3
"""Behavior tests for the Ghostty Zig workflow guard."""

from __future__ import annotations

import tempfile
import textwrap
from pathlib import Path

from check_ghostty_zig_workflows import workflow_failures


def failures_for(workflow: str, *, name: str = "fixture.yml") -> list[str]:
    with tempfile.TemporaryDirectory() as directory:
        workflow_dir = Path(directory)
        (workflow_dir / name).write_text(
            textwrap.dedent(workflow), encoding="utf-8",
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


def test_wrapped_and_prefixed_consumer_execution_fails() -> None:
    failures = failures_for(
        """\
        name: fixture
        on: workflow_dispatch
        jobs:
          sudo:
            runs-on: ubuntu-latest
            steps:
              - run: sudo -u root ./scripts/install-zig-ci.sh
          workspace:
            runs-on: ubuntu-latest
            steps:
              - run: $GITHUB_WORKSPACE/scripts/build-ghostty-cli-helper.sh
          shell-command:
            runs-on: ubuntu-latest
            steps:
              - run: bash -c './scripts/ghostty-zig-version.sh --flag'
          shell-long-option:
            runs-on: ubuntu-latest
            steps:
              - run: bash --norc ./scripts/install-zig-ci.sh
          shell-long-option-value:
            runs-on: ubuntu-latest
            steps:
              - run: bash --rcfile /dev/null -c './scripts/install-zig-ci.sh'
        """
    )

    assert len(failures) == 5, failures
    assert all("before Ghostty submodule init" in failure for failure in failures)


def test_submodule_update_without_init_does_not_satisfy_guard() -> None:
    failures = failures_for(
        """\
        name: fixture
        on: workflow_dispatch
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - run: git submodule update ghostty
              - run: ./scripts/install-zig-ci.sh
        """
    )

    assert len(failures) == 1, failures
    assert "install-zig-ci.sh" in failures[0], failures


def test_function_body_runs_at_invocation_not_definition() -> None:
    failures = failures_for(
        """\
        name: fixture
        on: workflow_dispatch
        jobs:
          initialized-before-call:
            runs-on: ubuntu-latest
            steps:
              - run: |
                  install_zig() { ./scripts/install-zig-ci.sh; }
                  git submodule update --init ghostty
                  install_zig
          never-called:
            runs-on: ubuntu-latest
            steps:
              - run: |
                  install_zig() { ./scripts/install-zig-ci.sh; }
          called-before-init:
            runs-on: ubuntu-latest
            steps:
              - run: |
                  install_zig() { ./scripts/install-zig-ci.sh; }
                  install_zig
                  git submodule update --init ghostty
        """
    )

    assert len(failures) == 1, failures
    assert "called-before-init" in failures[0], failures


def test_bash_conditional_path_check_is_not_execution() -> None:
    failures = failures_for(
        """\
        name: fixture
        on: workflow_dispatch
        jobs:
          inspect:
            runs-on: ubuntu-latest
            steps:
              - run: |
                  if [[ -x ./scripts/install-zig-ci.sh ]]; then
                    echo "available"
                  fi
        """
    )

    assert failures == [], failures


def test_setup_zig_ignores_non_run_mentions() -> None:
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
              - name: Resolve Ghostty Zig version
                id: ghostty-zig-version
                run: |
                  version="$(bash ./scripts/ghostty-zig-version.sh)"
                  echo "version=$version" >> "$GITHUB_OUTPUT"
              - uses: actions/github-script@v7
                with:
                  script: |
                    const helper = 'scripts/ghostty-zig-version.sh';
              - uses: mlugg/setup-zig@v2
                with:
                  version: ${{ steps.ghostty-zig-version.outputs.version }}
        """,
        name="cmux-tui.yml",
    )

    assert failures == [], failures


def test_setup_zig_resolver_must_execute_helper() -> None:
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
              - uses: actions/github-script@v7
                id: ghostty-zig-version
                with:
                  script: |
                    const helper = 'scripts/ghostty-zig-version.sh';
              - uses: mlugg/setup-zig@v2
                with:
                  version: ${{ steps.ghostty-zig-version.outputs.version }}
        """,
        name="cmux-tui.yml",
    )

    assert any(
        "resolver must execute scripts/ghostty-zig-version.sh exactly once" in failure
        for failure in failures
    ), failures


def test_non_tui_setup_zig_is_not_ghostty_specific() -> None:
    failures = failures_for(
        """\
        name: fixture
        on: workflow_dispatch
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - uses: mlugg/setup-zig@v2
                with:
                  version: 0.14.0
        """
    )

    assert failures == [], failures


def test_setup_zig_resolver_must_propagate_multiline_helper_failure() -> None:
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
              - id: ghostty-zig-version
                run: |
                  echo "$(
                    bash ./scripts/ghostty-zig-version.sh
                  )"
              - uses: mlugg/setup-zig@v2
                with:
                  version: ${{ steps.ghostty-zig-version.outputs.version }}
        """,
        name="cmux-tui.yml",
    )

    assert any(
        "must propagate version helper failures" in failure for failure in failures
    )


def test_consumer_diagnostic_uses_run_content_line() -> None:
    failures = failures_for(
        """\
        name: fixture
        on: workflow_dispatch
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - name: Execute
                run: |
                  echo preparing
                  ./scripts/install-zig-ci.sh
        """
    )

    assert failures == [
        (
            "fixture.yml:10: build executes scripts/install-zig-ci.sh "
            "before Ghostty submodule init"
        )
    ], failures


if __name__ == "__main__":
    test_non_executing_mentions_do_not_require_ghostty()
    test_executing_consumer_before_init_fails()
    test_initialized_consumer_passes()
    test_wrapped_and_prefixed_consumer_execution_fails()
    test_submodule_update_without_init_does_not_satisfy_guard()
    test_function_body_runs_at_invocation_not_definition()
    test_bash_conditional_path_check_is_not_execution()
    test_setup_zig_ignores_non_run_mentions()
    test_setup_zig_resolver_must_execute_helper()
    test_non_tui_setup_zig_is_not_ghostty_specific()
    test_setup_zig_resolver_must_propagate_multiline_helper_failure()
    test_consumer_diagnostic_uses_run_content_line()
    print("all Ghostty Zig workflow guard tests passed")
