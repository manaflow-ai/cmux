#!/usr/bin/env python3
"""Guard app-host XCTest against persistent console-user configuration."""

from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/ci.yml"
WORKFLOW = yaml.safe_load(WORKFLOW_PATH.read_text(encoding="utf-8"))
CONSOLE_WRAPPER = (ROOT / "scripts/ci/run-in-console-session.sh").read_text(
    encoding="utf-8"
)


def require(text: str, needle: str, context: str) -> None:
    if needle not in text:
        raise SystemExit(f"FAIL: {context} is missing {needle!r}")


def require_step(job_name: str, step_name: str) -> dict:
    jobs = WORKFLOW.get("jobs")
    if not isinstance(jobs, dict):
        raise SystemExit("FAIL: workflow jobs must be a mapping")

    job = jobs.get(job_name)
    if not isinstance(job, dict):
        raise SystemExit(f"FAIL: workflow job {job_name!r} is missing")

    steps = job.get("steps")
    if not isinstance(steps, list):
        raise SystemExit(f"FAIL: workflow job {job_name!r} steps must be a list")

    matches = [step for step in steps if step.get("name") == step_name]
    if len(matches) != 1:
        raise SystemExit(
            f"FAIL: workflow job {job_name!r} must contain exactly one "
            f"{step_name!r} step"
        )
    return matches[0]


def main() -> int:
    setup_step = require_step(
        "app-host-unit-tests", "Prepare isolated app-host home"
    )
    setup_run = setup_step.get("run")
    if not isinstance(setup_run, str):
        raise SystemExit("FAIL: isolated app-host setup step has no run script")

    requirements = {
        "per-shard app-host home": (
            "APP_HOST_HOME=\"${RUNNER_TEMP}/cmux-app-host-home-"
            "${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-shard-${{ matrix.shard }}\""
        ),
        "Core Foundation home redirect": (
            'echo "CFFIXED_USER_HOME=$APP_HOST_HOME" >> "$GITHUB_ENV"'
        ),
        "XDG configuration redirect": (
            'echo "XDG_CONFIG_HOME=$APP_HOST_HOME/.config" >> "$GITHUB_ENV"'
        ),
        "console-user write access": 'chmod -R a+rwX "$APP_HOST_HOME"',
        "real Cargo toolchain home": 'echo "CARGO_HOME=${HOME}/.cargo" >> "$GITHUB_ENV"',
        "real rustup toolchain home": 'echo "RUSTUP_HOME=${HOME}/.rustup" >> "$GITHUB_ENV"',
    }
    for context, needle in requirements.items():
        require(setup_run, needle, context)

    guard_step = require_step(
        "workflow-guard-tests", "Validate app-host user configuration isolation"
    )
    if guard_step.get("run") != "python3 tests/test_ci_app_host_home_isolation.py":
        raise SystemExit("FAIL: workflow-guard-tests does not run this guard")

    require(
        CONSOLE_WRAPPER,
        "CFFIXED_USER_HOME XDG_CONFIG_HOME CARGO_HOME RUSTUP_HOME",
        "console-session environment forwarding",
    )
    require(
        CONSOLE_WRAPPER,
        "unset SSH_AUTH_SOCK",
        "ambient SSH agent removal",
    )
    require(
        CONSOLE_WRAPPER,
        'env HOME="$console_home"',
        "console-session Unix home preservation",
    )

    print("PASS: app-host XCTest uses isolated Apple state and preserved toolchains")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
