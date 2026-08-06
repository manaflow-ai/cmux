#!/usr/bin/env python3
"""Guard app-host XCTest against persistent console-user configuration."""

from pathlib import Path
import xml.etree.ElementTree as ET

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/ci.yml"
WORKFLOW = yaml.safe_load(WORKFLOW_PATH.read_text(encoding="utf-8"))
CONSOLE_WRAPPER = (ROOT / "scripts/ci/run-in-console-session.sh").read_text(
    encoding="utf-8"
)
APP_HOST_WRAPPER = (ROOT / "scripts/ci/run-app-host-xcodebuild.sh").read_text(
    encoding="utf-8"
)
UNIT_SCHEME_PATH = (
    ROOT / "cmux.xcodeproj/xcshareddata/xcschemes/cmux-unit.xcscheme"
)
PROJECT = (ROOT / "cmux.xcodeproj/project.pbxproj").read_text(encoding="utf-8")


def require(text: str, needle: str, context: str) -> None:
    if needle not in text:
        raise SystemExit(f"FAIL: {context} is missing {needle!r}")


def require_step(job_name: str, step_name: str) -> dict:
    if not isinstance(WORKFLOW, dict):
        raise SystemExit("FAIL: workflow must be a mapping")

    jobs = WORKFLOW.get("jobs")
    if not isinstance(jobs, dict):
        raise SystemExit("FAIL: workflow jobs must be a mapping")

    job = jobs.get(job_name)
    if not isinstance(job, dict):
        raise SystemExit(f"FAIL: workflow job {job_name!r} is missing")

    steps = job.get("steps")
    if not isinstance(steps, list):
        raise SystemExit(f"FAIL: workflow job {job_name!r} steps must be a list")

    matches = []
    for index, step in enumerate(steps):
        if not isinstance(step, dict):
            raise SystemExit(
                f"FAIL: workflow job {job_name!r} step {index} must be a mapping"
            )
        if step.get("name") == step_name:
            matches.append(step)
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

    scheme_root = ET.parse(UNIT_SCHEME_PATH).getroot()
    test_action = scheme_root.find("TestAction")
    if test_action is None:
        raise SystemExit("FAIL: cmux-unit scheme has no TestAction")
    environment_variables = test_action.find("EnvironmentVariables")
    if environment_variables is None:
        raise SystemExit("FAIL: cmux-unit TestAction has no environment variables")
    scheme_environment = {
        item.get("key"): item.get("value")
        for item in environment_variables.findall("EnvironmentVariable")
        if item.get("isEnabled") == "YES"
    }
    expected_scheme_environment = {
        "HOME": "$(CMUX_APP_HOST_HOME)",
        "CFFIXED_USER_HOME": "$(CMUX_APP_HOST_HOME)",
        "XDG_CONFIG_HOME": "$(CMUX_APP_HOST_XDG_CONFIG_HOME)",
        "CMUX_APP_HOST_EXPECTED_HOME": "$(CMUX_APP_HOST_HOME)",
        "CMUX_APP_HOST_EXPECTED_XDG_CONFIG_HOME": (
            "$(CMUX_APP_HOST_XDG_CONFIG_HOME)"
        ),
    }
    for key, value in expected_scheme_environment.items():
        if scheme_environment.get(key) != value:
            raise SystemExit(
                f"FAIL: cmux-unit TestAction must set {key}={value}"
            )

    for context, needle in {
        "app-host HOME build-setting default": 'CMUX_APP_HOST_HOME = "$(HOME)";',
        "app-host XDG build-setting default": (
            'CMUX_APP_HOST_XDG_CONFIG_HOME = '
            '"$(XDG_CONFIG_HOME:default=$(HOME)/.config)";'
        ),
    }.items():
        if PROJECT.count(needle) < 2:
            raise SystemExit(
                f"FAIL: Debug and Release app targets need {context}: {needle}"
            )

    for context, needle in {
        "app-host HOME xcodebuild override": (
            '"CMUX_APP_HOST_HOME=$CFFIXED_USER_HOME"'
        ),
        "app-host XDG xcodebuild override": (
            '"CMUX_APP_HOST_XDG_CONFIG_HOME=$XDG_CONFIG_HOME"'
        ),
        "Ghostty app-support path validation": (
            "validate_app_host_config_paths"
        ),
    }.items():
        require(APP_HOST_WRAPPER, needle, context)

    print("PASS: app-host XCTest receives an isolated launch home")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
