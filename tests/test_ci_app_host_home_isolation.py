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
APP_HOST_ISOLATION = (ROOT / "scripts/ci/app-host-isolation.sh").read_text(
    encoding="utf-8"
)
UNIT_SCHEME = (
    ROOT / "cmux.xcodeproj/xcshareddata/xcschemes/cmux-unit.xcscheme"
).read_text(encoding="utf-8")
APP_HOST_POLICY_TESTS = (
    ROOT / "cmuxTests/MacSentryStartupPolicyTests.swift"
).read_text(encoding="utf-8")

TEST_RUNNER_ENVIRONMENT_KEYS = (
    "HOME",
    "CFFIXED_USER_HOME",
    "XDG_CONFIG_HOME",
    "SSH_AUTH_SOCK",
    "CMUX_APP_HOST_ISOLATION_REQUIRED",
    "CMUX_APP_HOST_EXPECTED_HOME",
    "CMUX_APP_HOST_EXPECTED_XDG_CONFIG_HOME",
)
FORBIDDEN_SCHEME_ENVIRONMENT_KEYS = {
    f"TEST_RUNNER_{key}" for key in TEST_RUNNER_ENVIRONMENT_KEYS
}


def require(text: str, needle: str, context: str) -> None:
    if needle not in text:
        raise SystemExit(f"FAIL: {context} is missing {needle!r}")


def scheme_environment_override_keys(scheme: str) -> set[str]:
    try:
        root = ET.fromstring(scheme)
    except ET.ParseError as error:
        raise SystemExit(f"FAIL: cmux-unit scheme is malformed: {error}") from error

    return {
        key
        for element in root.iter("EnvironmentVariable")
        if (key := element.get("key")) in FORBIDDEN_SCHEME_ENVIRONMENT_KEYS
    }


def require_no_test_runner_scheme_overrides(scheme: str) -> None:
    overrides = sorted(scheme_environment_override_keys(scheme))
    if overrides:
        raise SystemExit(
            "FAIL: cmux-unit scheme must not override " + ", ".join(overrides)
        )


def require_job(job_name: str) -> dict:
    if not isinstance(WORKFLOW, dict):
        raise SystemExit("FAIL: workflow must be a mapping")

    jobs = WORKFLOW.get("jobs")
    if not isinstance(jobs, dict):
        raise SystemExit("FAIL: workflow jobs must be a mapping")

    job = jobs.get(job_name)
    if not isinstance(job, dict):
        raise SystemExit(f"FAIL: workflow job {job_name!r} is missing")
    return job


def require_step(job_name: str, step_name: str) -> dict:
    job = require_job(job_name)

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
    override_fixture = """\
<Scheme>
  <EnvironmentVariables>
    <EnvironmentVariable key="TEST_RUNNER_HOME" value="/tmp/ambient"/>
  </EnvironmentVariables>
</Scheme>
"""
    if scheme_environment_override_keys(override_fixture) != {"TEST_RUNNER_HOME"}:
        raise SystemExit(
            "FAIL: scheme guard must reject TEST_RUNNER_HOME overrides"
        )

    setup_step = require_step(
        "app-host-unit-tests", "Prepare isolated app-host home"
    )
    setup_run = setup_step.get("run")
    if not isinstance(setup_run, str):
        raise SystemExit("FAIL: isolated app-host setup step has no run script")

    requirements = {
        "fixed-width app-host key": (
            "APP_HOST_KEY=\"$(printf '%s' "
            "\"${GITHUB_RUN_ID}:${GITHUB_RUN_ATTEMPT}:${{ matrix.shard }}\" "
            "| shasum -a 256 | cut -c1-12)\""
        ),
        "short per-shard app-host home": (
            'APP_HOST_HOME="${RUNNER_TEMP}/ah-${APP_HOST_KEY}"'
        ),
        "neutral app-host home": (
            'echo "CMUX_APP_HOST_HOME=$APP_HOST_HOME" >> "$GITHUB_ENV"'
        ),
        "neutral app-host XDG home": (
            'echo "CMUX_APP_HOST_XDG_CONFIG_HOME=$APP_HOST_HOME/.config" '
            '>> "$GITHUB_ENV"'
        ),
        "owner-only app-host access": (
            'chmod -R u+rwX,go-rwx "$APP_HOST_HOME"'
        ),
        "real Cargo toolchain home": 'echo "CARGO_HOME=${HOME}/.cargo" >> "$GITHUB_ENV"',
        "real rustup toolchain home": 'echo "RUSTUP_HOME=${HOME}/.rustup" >> "$GITHUB_ENV"',
    }
    for context, needle in requirements.items():
        require(setup_run, needle, context)

    for leaked_redirect in ("CFFIXED_USER_HOME=", "XDG_CONFIG_HOME="):
        if leaked_redirect in setup_run:
            raise SystemExit(
                "FAIL: isolated app-host setup must not export runtime redirect "
                f"{leaked_redirect!r} to intervening workflow steps"
            )

    app_host_job = require_job("app-host-unit-tests")
    app_host_job_environment = app_host_job.get("env")
    if not isinstance(app_host_job_environment, dict) or (
        app_host_job_environment.get("CMUX_CI_APP_HOST_ISOLATION_REQUIRED") != "1"
    ):
        raise SystemExit(
            "FAIL: app-host job must independently require user configuration "
            "isolation"
        )

    cleanup_step = require_step(
        "app-host-unit-tests", "Clean up isolated app-host home"
    )
    if cleanup_step.get("if") != "${{ always() }}":
        raise SystemExit("FAIL: app-host home cleanup must run after failures")
    if cleanup_step.get("run") != (
        "scripts/ci/run-in-console-session.sh "
        "scripts/ci/cleanup-app-host-home.sh"
    ):
        raise SystemExit("FAIL: app-host home cleanup must run as the console user")

    # RemoteTmuxHost appends a fixed 55-byte suffix to HOME before OpenSSH
    # binds its transient control socket. Keep deterministic headroom on the
    # self-hosted runner instead of relying on today's decimal run-id length.
    representative_home = "/Users/runner/work/_temp/ah-" + ("a" * 12)
    remote_tmux_bound_path = (
        representative_home
        + "/.cmux/ssh/tmux-"
        + "-"
        + ("0" * 16)
        + ".sock."
        + ("x" * 16)
    )
    if len(remote_tmux_bound_path.encode("utf-8")) > 103:
        raise SystemExit("FAIL: isolated app-host home exceeds AF_UNIX path budget")

    guard_step = require_step(
        "workflow-guard-tests", "Validate app-host user configuration isolation"
    )
    if guard_step.get("run") != "python3 tests/test_ci_app_host_home_isolation.py":
        raise SystemExit("FAIL: workflow-guard-tests does not run this guard")

    require(
        CONSOLE_WRAPPER,
        "CMUX_CI_APP_HOST_ISOLATION_REQUIRED CMUX_APP_HOST_HOME "
        "CMUX_APP_HOST_XDG_CONFIG_HOME CFFIXED_USER_HOME XDG_CONFIG_HOME "
        "CARGO_HOME RUSTUP_HOME",
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
    require(
        CONSOLE_WRAPPER,
        '"$runner_temp"/*',
        "console-session app-host path boundary",
    )
    require(
        CONSOLE_WRAPPER,
        'sudo -n chown -R "$console_user" "$app_host_home"',
        "console-user app-host ownership",
    )
    require(
        CONSOLE_WRAPPER,
        'sudo -n chmod -R u+rwX,go-rwx "$app_host_home"',
        "console-user app-host permissions",
    )
    require(
        CONSOLE_WRAPPER,
        'source "$ci_script_dir/app-host-isolation.sh"',
        "console-session isolation path validation",
    )
    require(
        APP_HOST_WRAPPER,
        'source "$ci_script_dir/app-host-isolation.sh"',
        "app-host wrapper isolation path validation",
    )
    require(
        APP_HOST_WRAPPER,
        'if [ "${CMUX_CI_APP_HOST_ISOLATION_REQUIRED:-0}" = "1" ]',
        "mandatory app-host isolation check",
    )
    require(
        APP_HOST_WRAPPER,
        "FAIL: required app-host isolation environment is incomplete",
        "missing app-host isolation failure",
    )
    require(
        APP_HOST_WRAPPER,
        "CMUX_APP_HOST_HOME",
        "neutral app-host home input",
    )
    require(
        APP_HOST_WRAPPER,
        "CMUX_APP_HOST_XDG_CONFIG_HOME",
        "neutral app-host XDG input",
    )
    require(
        APP_HOST_WRAPPER,
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) "
        "CMUX_CI_APP_HOST_ISOLATION_REQUIRED",
        "independent compiled isolation assertion",
    )
    require(
        APP_HOST_POLICY_TESTS,
        "#if CMUX_CI_APP_HOST_ISOLATION_REQUIRED",
        "compiled app-host isolation assertion",
    )
    require(
        APP_HOST_ISOLATION,
        'expected_xdg_config_home="${resolved_home%/}/.config"',
        "canonical XDG isolation boundary",
    )

    require_no_test_runner_scheme_overrides(UNIT_SCHEME)

    for context, needle in {
        "app-host HOME test-runner redirect": (
            '"TEST_RUNNER_HOME=$app_host_home"'
        ),
        "app-host Core Foundation test-runner redirect": (
            '"TEST_RUNNER_CFFIXED_USER_HOME=$app_host_home"'
        ),
        "app-host XDG test-runner redirect": (
            '"TEST_RUNNER_XDG_CONFIG_HOME=$app_host_xdg_config_home"'
        ),
        "app-host SSH agent removal": '"TEST_RUNNER_SSH_AUTH_SOCK="',
        "app-host expected HOME marker": (
            '"TEST_RUNNER_CMUX_APP_HOST_EXPECTED_HOME=$app_host_home"'
        ),
        "app-host expected XDG marker": (
            '"TEST_RUNNER_CMUX_APP_HOST_EXPECTED_XDG_CONFIG_HOME=$app_host_xdg_config_home"'
        ),
        "Ghostty app-support path validation": (
            "validate_app_host_config_paths"
        ),
    }.items():
        require(APP_HOST_WRAPPER, needle, context)

    cleanup_path = ROOT / "scripts/ci/cleanup-app-host-home.sh"
    if not cleanup_path.is_file():
        raise SystemExit("FAIL: isolated app-host cleanup script is missing")
    cleanup_script = cleanup_path.read_text(encoding="utf-8")
    for context, needle in {
        "cleanup isolation requirement": "CMUX_CI_APP_HOST_ISOLATION_REQUIRED",
        "cleanup canonical path validation": (
            'source "$ci_script_dir/app-host-isolation.sh"'
        ),
        "cleanup runner boundary": '"$runner_temp"/*',
        "cleanup scoped process termination": "CMUX_DERIVED_DATA_PATH",
        "cleanup unlimited-width process discovery": (
            "ps -axww -o pid=,command="
        ),
        "cleanup exact target removal": 'rm -rf -- "$app_host_home"',
    }.items():
        require(cleanup_script, needle, context)

    require(
        CONSOLE_WRAPPER,
        "cleanup_app_host_home_requested",
        "console-session cleanup preparation mode",
    )
    if "*/scripts/ci/cleanup-app-host-home.sh" in CONSOLE_WRAPPER:
        raise SystemExit(
            "FAIL: console-session cleanup mode must match only the repository "
            "cleanup command"
        )

    print("PASS: app-host XCTest receives an isolated launch home")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
