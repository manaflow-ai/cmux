#!/usr/bin/env python3
"""Guard app-host XCTest against persistent console-user configuration."""

from pathlib import Path
import subprocess
import tempfile
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
APP_HOST_PROCESSES_PATH = ROOT / "scripts/ci/app-host-processes.sh"
APP_HOST_PROCESSES = (
    APP_HOST_PROCESSES_PATH.read_text(encoding="utf-8")
    if APP_HOST_PROCESSES_PATH.is_file()
    else ""
)
PREPARE_APP_HOST_PATH = ROOT / "scripts/ci/prepare-app-host-home.sh"
APP_HOST_RECEIPT_CONSTRUCTOR = (
    ROOT / "cmuxTests/CmuxTestWindowReleaseGuard.m"
).read_text(encoding="utf-8")
APP_HOST_RECEIPT_WRITER_PATH = ROOT / "Sources/AppHostProcessReceipt.swift"
APP_HOST_RECEIPT_WRITER = (
    APP_HOST_RECEIPT_WRITER_PATH.read_text(encoding="utf-8")
    if APP_HOST_RECEIPT_WRITER_PATH.is_file()
    else ""
)
APP_ENTRYPOINT = (ROOT / "Sources/cmuxApp.swift").read_text(encoding="utf-8")
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
    "CMUX_APP_HOST_KEY",
    "CMUX_APP_HOST_RECEIPT_DIR",
)
FORBIDDEN_SCHEME_ENVIRONMENT_KEYS = {
    f"TEST_RUNNER_{key}" for key in TEST_RUNNER_ENVIRONMENT_KEYS
}


def require(text: str, needle: str, context: str) -> None:
    if needle not in text:
        raise SystemExit(f"FAIL: {context} is missing {needle!r}")


def require_atomic_receipt_publication(
    source: str, context: str, retained_descriptor: str
) -> None:
    if "O_TRUNC" in source:
        raise SystemExit(
            f"FAIL: {context} must not truncate the published receipt in place"
        )
    for needle, detail in (
        ("O_EXCL", "exclusive temporary receipt creation"),
        (".receipt.tmp", "non-published temporary receipt suffix"),
        ("fsync(", "persisted temporary receipt contents"),
        ("rename(", "atomic final receipt publication"),
        ("unlink(", "failed temporary receipt cleanup"),
        (retained_descriptor, "retained process-incarnation descriptor"),
    ):
        require(source, needle, f"{context} {detail}")
    if source.index("rename(") > source.index(retained_descriptor):
        raise SystemExit(
            f"FAIL: {context} must publish the receipt before retaining its descriptor"
        )


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
    if setup_step.get("run") != "scripts/ci/prepare-app-host-home.sh":
        raise SystemExit(
            "FAIL: workflow must delegate app-host identity and setup to one script"
        )
    if not PREPARE_APP_HOST_PATH.is_file():
        raise SystemExit("FAIL: app-host preparation script is missing")
    prepare_app_host = PREPARE_APP_HOST_PATH.read_text(encoding="utf-8")
    for context, needle in {
        "shared identity derivation": "cmux_resolve_app_host_identity",
        "published run-derived key": "CMUX_APP_HOST_KEY",
        "external process receipt directory": "CMUX_APP_HOST_RECEIPT_DIR",
        "target-bound cleanup confirmation": "CMUX_APP_HOST_CLEANUP_CONFIRMATION",
        "external confirmation record": "CMUX_APP_HOST_CONFIRMATION_FILE",
        "structured Ghostty config sentinel": "cmux CI app-host isolation sentinel",
        "owner-only app-host access": 'chmod -R u+rwX,go-rwx "$app_host_home"',
        "shared confirmation record": "cmux_app_host_confirmation_record",
    }.items():
        require(prepare_app_host, needle, context)
    require(
        prepare_app_host,
        '>> "$GITHUB_ENV"',
        "published app-host environment",
    )
    require(
        prepare_app_host,
        'mkdir -m 700 "$app_host_home"',
        "exclusive app-host home claim",
    )
    publish = prepare_app_host.index('>> "$GITHUB_ENV"')
    first_home_mutation = prepare_app_host.index('mkdir -m 700 "$app_host_home"')
    if publish > first_home_mutation:
        raise SystemExit(
            "FAIL: identity and cleanup target must be published before mutation"
        )
    confirmation_claim = prepare_app_host.index(
        'ln -- "$confirmation_tmp" "$app_host_confirmation_file"'
    )
    if confirmation_claim > first_home_mutation:
        raise SystemExit(
            "FAIL: cleanup authority must be durable before mutable scope setup"
        )
    for destructive_preparation in (
        'rm -rf -- "$app_host_home"',
        'rm -rf -- "$app_host_receipt_dir"',
        'rm -f -- "$app_host_confirmation_file"',
    ):
        if destructive_preparation in prepare_app_host:
            raise SystemExit(
                "FAIL: preparation must not erase existing app-host authority: "
                f"{destructive_preparation}"
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
    if app_host_job_environment.get("CMUX_APP_HOST_SHARD") != "${{ matrix.shard }}":
        raise SystemExit(
            "FAIL: app-host job must publish the shard as independent identity input"
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

    # Resolve the real shell identity format, then rebase its system-temp-relative
    # suffix under macOS /private/tmp when this guard runs on Linux.
    with tempfile.TemporaryDirectory() as runner_temp:
        identity = subprocess.run(
            [
                "/bin/bash",
                "-c",
                'source "$1"; cmux_resolve_app_host_identity; '
                'printf "%s\\n%s\\n" "$CMUX_RESOLVED_SYSTEM_TEMP_ROOT" '
                '"$CMUX_RESOLVED_APP_HOST_HOME"',
                "bash",
                str(ROOT / "scripts/ci/app-host-isolation.sh"),
            ],
            check=True,
            capture_output=True,
            text=True,
            env={
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "RUNNER_TEMP": runner_temp,
                "GITHUB_REPOSITORY_ID": "1234567",
                "GITHUB_RUN_ID": "9000000000",
                "GITHUB_RUN_ATTEMPT": "1",
                "CMUX_APP_HOST_SHARD": "1",
            },
        ).stdout.splitlines()
    if len(identity) != 2:
        raise SystemExit("FAIL: app-host identity guard returned unexpected output")
    system_temp_root, resolved_home = identity
    relative_home = Path(resolved_home).relative_to(system_temp_root)
    representative_home = str(Path("/private/tmp") / relative_home)

    # RemoteTmuxHost appends a fixed 55-byte suffix to HOME before OpenSSH
    # binds its transient control socket.
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
    identity_guard_step = require_step(
        "workflow-guard-tests", "Validate app-host identity and cleanup confirmation"
    )
    if identity_guard_step.get("run") != "bash tests/test_ci_app_host_identity.sh":
        raise SystemExit("FAIL: workflow-guard-tests does not run the identity guard")
    process_guard_step = require_step(
        "workflow-guard-tests", "Validate app-host process receipts"
    )
    if process_guard_step.get("run") != "bash tests/test_ci_app_host_processes.sh":
        raise SystemExit("FAIL: workflow-guard-tests does not run the process receipt guard")

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
        "cmux_validate_published_app_host_identity",
        "console-session run-derived path boundary",
    )
    require(
        CONSOLE_WRAPPER,
        'sudo -n chown -R -P "$console_user" "$app_host_home"',
        "console-user app-host ownership",
    )
    require(
        CONSOLE_WRAPPER,
        'sudo -n chmod -R u+rwX,go-rwx "$app_host_home"',
        "console-user app-host permissions",
    )
    require(
        CONSOLE_WRAPPER,
        'sudo -n chown -R -P "$console_user" "$app_host_receipt_dir"',
        "console-user process receipt ownership",
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
        "SWIFT_ACTIVE_COMPILATION_CONDITIONS=\\$(inherited) "
        "CMUX_CI_APP_HOST_ISOLATION_REQUIRED",
        "independent compiled isolation assertion",
    )
    require(
        APP_HOST_WRAPPER,
        "FAIL: app-host configuration evidence is missing",
        "missing structured Ghostty evidence failure",
    )
    require(
        APP_HOST_WRAPPER,
        '${app_host_lock_root%/}/cmux-app-host-test.lock',
        "canonical machine-wide app-host lock",
    )
    require(
        APP_HOST_POLICY_TESTS,
        "#if CMUX_CI_APP_HOST_ISOLATION_REQUIRED",
        "compiled app-host isolation assertion",
    )
    require(
        APP_HOST_ISOLATION,
        "cmux_validate_app_host_cleanup_confirmation",
        "target-bound cleanup confirmation validation",
    )
    require(
        APP_HOST_ISOLATION,
        "cmux_app_host_confirmation_record",
        "shared cleanup confirmation record",
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
        "app-host process receipt directory": (
            '"TEST_RUNNER_CMUX_APP_HOST_RECEIPT_DIR=$app_host_receipt_dir"'
        ),
        "app-host run-derived key": (
            '"TEST_RUNNER_CMUX_APP_HOST_KEY=$app_host_key"'
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
    if not APP_HOST_PROCESSES_PATH.is_file():
        raise SystemExit("FAIL: app-host process receipt helper is missing")
    for context, needle in {
        "cleanup isolation requirement": "CMUX_CI_APP_HOST_ISOLATION_REQUIRED",
        "cleanup canonical path validation": (
            'source "$ci_script_dir/app-host-isolation.sh"'
        ),
        "cleanup run-derived identity": "cmux_validate_published_app_host_identity",
        "cleanup target-bound confirmation": (
            "cmux_validate_app_host_cleanup_confirmation"
        ),
        "cleanup root symlink refusal": (
            "FAIL: refusing app-host cleanup through a home symlink"
        ),
        "cleanup external process receipts": "CMUX_RESOLVED_APP_HOST_RECEIPT_DIR",
        "cleanup exact target removal": 'rm -rf -- "$app_host_home"',
        "cleanup resolved XDG target": 'xdg_target="${app_host_xdg_config_home%/}"',
        "cleanup original DerivedData validation": (
            'cmux_validate_app_host_derived_data "$CMUX_DERIVED_DATA_PATH"'
        ),
        "cleanup stored canonical DerivedData": (
            'derived_data_path="$CMUX_VALIDATED_APP_HOST_DERIVED_DATA"'
        ),
    }.items():
        require(cleanup_script, needle, context)
    require(APP_HOST_PROCESSES, "/usr/sbin/lsof", "cleanup executable-vnode identity")
    require(
        APP_HOST_ISOLATION,
        "Confirmed app-host cleanup target:",
        "cleanup target preview",
    )
    require(
        APP_HOST_PROCESSES,
        "has no verified receipt",
        "unreceipted live app-host refusal",
    )
    require(
        APP_HOST_PROCESSES,
        "cmux_app_host_receipt_descriptor_is_open",
        "process-incarnation receipt verification",
    )
    require(
        APP_HOST_PROCESSES,
        "cmux_run_app_host_lsof",
        "lsof stdout and stderr separation",
    )
    require(
        APP_HOST_PROCESSES,
        "cmux_recover_owned_app_host_attempt",
        "current-run retry recovery",
    )
    require(
        APP_HOST_PROCESSES,
        "cmux_reclaim_abandoned_app_host_scopes",
        "age-bounded process-free scope reclamation",
    )

    for forbidden_process_authority in (
        "ps -axww -o pid=,command=",
        "pkill -f",
    ):
        if forbidden_process_authority in cleanup_script or (
            forbidden_process_authority in APP_HOST_WRAPPER
        ) or forbidden_process_authority in APP_HOST_PROCESSES:
            raise SystemExit(
                "FAIL: destructive app-host cleanup must not trust process argv: "
                f"{forbidden_process_authority}"
            )

    for context, needle in {
        "test-bundle process receipt hook": "CmuxWriteAppHostProcessReceipt",
        "receipt isolation marker": "CMUX_APP_HOST_ISOLATION_REQUIRED",
        "receipt external directory": "CMUX_APP_HOST_RECEIPT_DIR",
        "receipt run-derived key": "CMUX_APP_HOST_KEY",
        "receipt process-incarnation descriptor": "CmuxAppHostReceiptFD",
        "receipt descriptor field": "receipt_fd=",
        "receipt no-follow open": "O_NOFOLLOW",
    }.items():
        require(APP_HOST_RECEIPT_CONSTRUCTOR, needle, context)
    require_atomic_receipt_publication(
        APP_HOST_RECEIPT_CONSTRUCTOR,
        "test-bundle process receipt",
        "CmuxAppHostReceiptFD = descriptor",
    )

    for context, needle in {
        "early receipt isolation marker": "CMUX_APP_HOST_ISOLATION_REQUIRED",
        "early receipt external directory": "CMUX_APP_HOST_RECEIPT_DIR",
        "early receipt run-derived key": "CMUX_APP_HOST_KEY",
        "early retained receipt descriptor": "retainedReceiptDescriptor",
        "early receipt descriptor field": "receipt_fd=",
        "early receipt no-follow open": "O_NOFOLLOW",
    }.items():
        require(APP_HOST_RECEIPT_WRITER, needle, context)
    require_atomic_receipt_publication(
        APP_HOST_RECEIPT_WRITER,
        "early app process receipt",
        "return descriptor",
    )
    require(
        APP_ENTRYPOINT,
        "AppHostProcessReceipt.writeIfRequired()",
        "pre-XCTest app-host receipt hook",
    )
    require(
        APP_ENTRYPOINT,
        "CmuxWorkerEntrypoint(arguments: CommandLine.arguments).runIfRequested()",
        "worker dispatch",
    )
    if APP_ENTRYPOINT.index("AppHostProcessReceipt.writeIfRequired()") > APP_ENTRYPOINT.index(
        "CmuxWorkerEntrypoint(arguments: CommandLine.arguments).runIfRequested()"
    ):
        raise SystemExit("FAIL: app-host receipt must be written before worker dispatch")

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
