#!/usr/bin/env python3
"""Guard app-host XCTest against persistent console-user configuration."""

from pathlib import Path
import os
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github/workflows/ci.yml"
GUARD_WORKFLOW_PATH = ROOT / ".github/workflows/ci-guards.yml"
MACOS_WORKFLOW_PATH = ROOT / ".github/workflows/ci-macos.yml"
E2E_WORKFLOW_PATH = ROOT / ".github/workflows/test-e2e.yml"
WORKFLOW_PATHS = [
    WORKFLOW_PATH,
    GUARD_WORKFLOW_PATH,
    MACOS_WORKFLOW_PATH,
    E2E_WORKFLOW_PATH,
]
WORKFLOWS = [
    yaml.safe_load(path.read_text(encoding="utf-8")) for path in WORKFLOW_PATHS
]
# test-e2e.yml runs its tests through this composite action, from its build
# job or from its fallback test job.
E2E_TEST_ACTION_PATH = ROOT / ".github/actions/e2e-run-tests/action.yml"
ACTION_PATHS = sorted((ROOT / ".github/actions").glob("*/action.yml"))
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
APP_ENTRYPOINT = (ROOT / "Sources/CmuxMain.swift" if (ROOT / "Sources/CmuxMain.swift").exists() else ROOT / "Sources/cmuxApp.swift").read_text(encoding="utf-8")
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
    matches = []
    for workflow in WORKFLOWS:
        if not isinstance(workflow, dict):
            raise SystemExit("FAIL: workflow must be a mapping")
        jobs = workflow.get("jobs")
        if not isinstance(jobs, dict):
            raise SystemExit("FAIL: workflow jobs must be a mapping")
        job = jobs.get(job_name)
        if isinstance(job, dict):
            matches.append(job)
    if len(matches) != 1:
        raise SystemExit(
            f"FAIL: workflow job {job_name!r} must exist in exactly one CI workflow"
        )
    return matches[0]


def action_as_job(path: Path) -> dict:
    """A composite action's steps as a job, with the env its steps publish.

    An action has no job env; it exports through GITHUB_ENV, and those values
    reach every later step, which is what a job env guarantees here.
    """
    action = yaml.safe_load(path.read_text(encoding="utf-8"))
    steps = ((action or {}).get("runs") or {}).get("steps") or []
    environment: dict[str, str] = {}
    for step in steps:
        run = str(step.get("run", ""))
        if "GITHUB_ENV" not in run:
            continue
        for match in re.finditer(
            r'^\s*echo "(?P<key>[A-Z_][A-Z0-9_]*)=(?P<value>[^"$]*)"\s*$',
            run,
            re.MULTILINE,
        ):
            environment.setdefault(match.group("key"), match.group("value"))
    return {"env": environment, "steps": steps}


def every_job():
    """Every workflow job, and every composite action as a job of its own."""
    for path, workflow in zip(WORKFLOW_PATHS, WORKFLOWS):
        for job_name, job in (workflow.get("jobs") or {}).items():
            yield path.name, job_name, job
    for path in ACTION_PATHS:
        yield f"{path.parent.name}/action.yml", "steps", action_as_job(path)


def require_action_step(path: Path, step_name: str) -> dict:
    matches = [
        step for step in action_as_job(path)["steps"]
        if step.get("name") == step_name
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"FAIL: {path.relative_to(ROOT)} must contain exactly one "
            f"{step_name!r} step"
        )
    return matches[0]


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


def bun_setup_gate_ok(condition: object) -> bool:
    """Whether a condition is `!cancelled() && (<one parenthesized group>)`."""
    if not isinstance(condition, str):
        return False
    expression = condition.replace(" ", "")
    prefix = "${{!cancelled()&&("
    if not (expression.startswith(prefix) and expression.endswith(")}}")):
        return False
    group = expression[len(prefix) - 1 : -2]
    depth = 0
    for index, character in enumerate(group):
        depth += {"(": 1, ")": -1}.get(character, 0)
        if depth == 0 and index != len(group) - 1:
            return False
    return depth == 0


def node_setup_gate_ok(condition: object) -> bool:
    """Whether node setup covers every notification gate shard."""
    if not isinstance(condition, str):
        return False
    expression = condition.replace(" ", "")
    prefix = "${{!cancelled()&&("
    if not (expression.startswith(prefix) and expression.endswith(")}}")):
        return False
    required_terms = (
        "matrix.shard==fromJSON(env.CMUX_APP_HOST_CLI_REGRESSION_SHARD)",
        "matrix.shard==fromJSON(env.CMUX_APP_HOST_FOCUSED_REGRESSION_SHARD)",
        "contains(inputs.unit_strict_steps,'|Runagentnotificationsemantics|')",
    )
    return all(term in expression for term in required_terms)


def acceptance_gate_problem(condition: object, preparation_id: str) -> str:
    """Return why a step condition is not gated on preparation, or ""."""
    if not isinstance(condition, str):
        return "has no condition"
    expression = condition.strip()
    if expression.startswith("${{") and expression.endswith("}}"):
        expression = expression[3:-2]
    # Split on the top-level `&&` only. An `||` inside a parenthesized term
    # chooses which worker runs the step; one outside offers a way around
    # the gates themselves.
    top_level: list[str] = []
    depth = 0
    term = ""
    index = 0
    while index < len(expression):
        character = expression[index]
        depth += {"(": 1, ")": -1}.get(character, 0)
        if depth == 0 and expression.startswith("||", index):
            return "must not offer an alternative to its gates"
        if depth == 0 and expression.startswith("&&", index):
            top_level.append(term)
            term = ""
            index += 2
            continue
        term += character
        index += 1
    top_level.append(term)
    terms = {"".join(term.split()) for term in top_level}
    if "always()" in terms:
        return "must not run after a cancelled job"
    if "!cancelled()" not in terms:
        return "must keep !cancelled() so it still runs after an earlier test failure"
    if f"steps.{preparation_id}.outcome=='success'" not in terms:
        return "must require successful app-host preparation"
    return ""


def published_derived_data_value(job, steps) -> str | None:
    """Return the CMUX_DERIVED_DATA_PATH a job publishes, before expansion.

    Both callers compute the path in a shell variable and export it through
    `GITHUB_ENV`, so the literal that matters is the assignment, not the echo.
    """
    environment = job.get("env")
    if isinstance(environment, dict) and environment.get("CMUX_DERIVED_DATA_PATH"):
        return str(environment["CMUX_DERIVED_DATA_PATH"])
    for step in steps:
        script = str(step.get("run", ""))
        export = re.search(
            r'CMUX_DERIVED_DATA_PATH=(?P<value>[^"\n]*)"?\s*>>\s*"?\$(?:\{)?GITHUB_ENV',
            script,
        )
        if export is None:
            continue
        value = export.group("value").strip()
        name = re.fullmatch(r"\$\{?(?P<name>[A-Za-z_][A-Za-z0-9_]*)\}?", value)
        if name is None:
            return value
        assignment = re.search(
            rf'^\s*{name.group("name")}="(?P<path>[^"]*)"', script, re.MULTILINE
        )
        return assignment.group("path") if assignment else None
    return None


def require_derived_data_under_runner_temp(where, job, steps) -> None:
    """Hold app-host callers to the boundary cleanup enforces at runtime.

    `cleanup-app-host-home.sh` refuses to inspect a host whose DerivedData
    lives outside `RUNNER_TEMP`, and it runs under `if: always()`, so a job
    that parks DerivedData anywhere else goes red *after* its tests pass.
    `test-e2e.yml` shipped exactly that: the split lane inherited a
    workspace-rooted path from the single-job form, which no other check
    looked at because no earlier version of that lane cleaned up at all.
    """
    value = published_derived_data_value(job, steps)
    if value is None:
        raise SystemExit(
            f"FAIL: {where} prepares an app-host home without publishing "
            "CMUX_DERIVED_DATA_PATH; cleanup requires it"
        )
    if not re.match(r"\$\{?RUNNER_TEMP\}?/", value):
        raise SystemExit(
            f"FAIL: {where} puts DerivedData at {value!r}; app-host cleanup "
            "only inspects hosts whose DerivedData is under RUNNER_TEMP"
        )


def check_every_app_host_home_is_identified_and_cleaned() -> None:
    """Hold every job that prepares an app-host home to the same contract.

    The rest of this guard names `app-host-unit-tests` directly, so a second
    lane could adopt the pattern and be checked by nothing. One did:
    `test-e2e.yml` gained a `Prepare isolated app-host home` step whose job set
    no `CMUX_APP_HOST_SHARD`, and `cmux_resolve_app_host_identity` rejects a
    shard that is not a decimal integer -- so every dispatch of that lane would
    have failed before running a test, with this file still green.

    Check the pattern rather than the instance: find the callers, composite
    actions included, since test-e2e.yml's tests moved into one.
    """
    checked = set()
    for file_name, job_name, job in every_job():
        steps = job.get("steps") or []
        prepares = [
            step for step in steps
            if "prepare-app-host-home.sh" in str(step.get("run", ""))
        ]
        if not prepares:
            continue
        checked.add(file_name)
        where = f"{file_name} job {job_name}"
        environment = job.get("env")
        if not isinstance(environment, dict):
            raise SystemExit(f"FAIL: {where} prepares an app-host home with no job env")
        if environment.get("CMUX_CI_APP_HOST_ISOLATION_REQUIRED") != "1":
            raise SystemExit(
                f"FAIL: {where} must require app-host configuration isolation"
            )
        shard = environment.get("CMUX_APP_HOST_SHARD")
        if not isinstance(shard, str) or not shard.strip():
            raise SystemExit(
                f"FAIL: {where} must publish CMUX_APP_HOST_SHARD; "
                "cmux_resolve_app_host_identity rejects an empty shard"
            )
        require_derived_data_under_runner_temp(where, job, steps)
        cleanups = [
            step for step in steps
            if "cleanup-app-host-home.sh" in str(step.get("run", ""))
        ]
        if not cleanups:
            raise SystemExit(
                f"FAIL: {where} prepares an app-host home and never cleans it up"
            )
        for cleanup in cleanups:
            gate = str(cleanup.get("if", ""))
            if "always()" not in gate and "cancelled()" not in gate:
                raise SystemExit(
                    f"FAIL: {where} app-host cleanup must run after failures"
                )
    e2e = f"{E2E_TEST_ACTION_PATH.parent.name}/action.yml"
    if e2e not in checked:
        raise SystemExit(
            f"FAIL: {e2e} must prepare the app-host home test-e2e.yml's tests use"
        )


def check_e2e_test_derived_data_scope() -> None:
    """Execute the E2E test steps' preparation/cleanup path in a temp scope."""
    preparation = require_action_step(E2E_TEST_ACTION_PATH, "Prepare isolated DerivedData")
    cleanup = require_action_step(E2E_TEST_ACTION_PATH, "Clean owned DerivedData")
    preparation_run = preparation.get("run")
    cleanup_run = cleanup.get("run")
    if not isinstance(preparation_run, str) or not isinstance(cleanup_run, str):
        raise SystemExit("FAIL: E2E test DerivedData steps must use shell scripts")

    with tempfile.TemporaryDirectory() as root:
        root_path = Path(root)
        workspace = root_path / "workspace"
        runner_temp = root_path / "runner-temp"
        tool_bin = root_path / "bin"
        github_env = root_path / "github-env"
        github_output = root_path / "github-output"
        workspace.mkdir()
        runner_temp.mkdir()
        tool_bin.mkdir()
        workspace_derived_data = workspace / "DerivedData" / "cmux-e2e"
        workspace_derived_data.mkdir(parents=True)
        workspace_sentinel = workspace_derived_data / "ownership-sentinel.txt"
        workspace_sentinel.write_text("workspace-owned", encoding="utf-8")
        (tool_bin / "xcodebuild").write_text(
            "#!/bin/sh\necho 'Xcode 26.0'\n", encoding="utf-8"
        )
        (tool_bin / "xcodebuild").chmod(0o755)

        environment = os.environ.copy()
        environment.update(
            {
                "GITHUB_WORKSPACE": str(workspace),
                "RUNNER_TEMP": str(runner_temp),
                "GITHUB_RUN_ID": "9000000000",
                "GITHUB_RUN_ATTEMPT": "1",
                "GITHUB_ENV": str(github_env),
                "GITHUB_OUTPUT": str(github_output),
                "PATH": f"{tool_bin}:{environment.get('PATH', '')}",
            }
        )
        prepared = subprocess.run(
            ["/bin/bash", "-e", "-o", "pipefail", "-c", preparation_run],
            cwd=workspace,
            env=environment,
            capture_output=True,
            text=True,
        )
        if prepared.returncode != 0:
            raise SystemExit(
                "FAIL: E2E test DerivedData preparation failed in the ownership "
                f"fixture: {prepared.stderr}"
            )

        prefix = "CMUX_DERIVED_DATA_PATH="
        derived_data_values = [
            line[len(prefix) :]
            for line in github_env.read_text(encoding="utf-8").splitlines()
            if line.startswith(prefix)
        ]
        if len(derived_data_values) != 1:
            raise SystemExit(
                "FAIL: E2E test DerivedData preparation must publish one path"
            )
        derived_data_raw = derived_data_values[0]
        derived_data = Path(derived_data_raw).resolve()
        expected = (
            runner_temp / "cmux-e2e-products-9000000000-1"
        ).resolve()
        if derived_data != expected:
            raise SystemExit(
                "FAIL: E2E test DerivedData must be owned under RUNNER_TEMP; "
                f"got {derived_data}, expected {expected}"
            )
        if not Path(derived_data_raw).is_dir():
            raise SystemExit(
                f"FAIL: E2E test DerivedData target was not created: {derived_data}"
            )
        if workspace_sentinel.read_text(encoding="utf-8") != "workspace-owned":
            raise SystemExit(
                "FAIL: E2E test DerivedData preparation touched the workspace root"
            )

        cleanup_environment = {
            **environment,
            "CMUX_DERIVED_DATA_PATH": derived_data_raw,
            "CMUX_E2E_COMPILATION_CACHE": "",
        }
        cleaned = subprocess.run(
            ["/bin/bash", "-e", "-o", "pipefail", "-c", cleanup_run],
            cwd=workspace,
            env=cleanup_environment,
            capture_output=True,
            text=True,
        )
        if cleaned.returncode != 0:
            raise SystemExit(
                "FAIL: E2E test DerivedData cleanup rejected its prepared target: "
                f"{cleaned.stderr}"
            )
        if Path(derived_data_raw).exists() or derived_data.exists():
            raise SystemExit(
                "FAIL: E2E test DerivedData cleanup left its owned target behind"
            )
        if workspace_sentinel.read_text(encoding="utf-8") != "workspace-owned":
            raise SystemExit(
                "FAIL: E2E test DerivedData cleanup touched the workspace root"
            )

        rejected_cleanup = subprocess.run(
            ["/bin/bash", "-e", "-o", "pipefail", "-c", cleanup_run],
            cwd=workspace,
            env={
                **cleanup_environment,
                "CMUX_DERIVED_DATA_PATH": str(workspace_derived_data),
            },
            capture_output=True,
            text=True,
        )
        if rejected_cleanup.returncode == 0:
            raise SystemExit(
                "FAIL: E2E test DerivedData cleanup accepted a workspace-root candidate"
            )
        if workspace_sentinel.read_text(encoding="utf-8") != "workspace-owned":
            raise SystemExit(
                "FAIL: rejected E2E test DerivedData cleanup touched the workspace root"
            )

def check_every_test_executing_lane_pins_its_home() -> None:
    """Hold every lane that runs XCTest to the same home pinning.

    The sibling guard above keys on `prepare-app-host-home.sh`, so a host-free
    lane that runs no app host is invisible to it. One was: `cli-product-tests`
    isolated itself with a bare `HOME` in the job environment, which reaches
    xcodebuild and stops there -- xcodebuild forwards only TEST_RUNNER_-prefixed
    variables into the test process. Every fixture in that lane read the
    runner's real home, and on a reused self-hosted runner that is shared,
    persistent state between runs.

    CFFIXED_USER_HOME is required alongside HOME because Foundation resolves
    NSHomeDirectory() through getpwuid unless it is set, so HOME alone moves
    nothing for Swift code.
    """
    required = ("TEST_RUNNER_HOME", "TEST_RUNNER_CFFIXED_USER_HOME")
    for file_name, job_name, job in every_job():
        for step in job.get("steps") or []:
            run = str(step.get("run", ""))
            if "xcodebuild test" not in run:
                continue
            # Enumeration lists test identifiers without running them, so
            # it reads no configuration and needs no home of its own.
            if "-enumerate-tests" in run:
                continue
            if "run-app-host-xcodebuild.sh" in run:
                continue
            where = (
                f"{file_name} job {job_name} step {step.get('name')!r}"
            )
            missing = [key for key in required if key not in run]
            if missing:
                raise SystemExit(
                    f"FAIL: {where} runs XCTest without {', '.join(missing)}; "
                    "xcodebuild forwards only TEST_RUNNER_-prefixed variables "
                    "into the test process"
                )


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
    preparation_id = setup_step.get("id")
    if not preparation_id or cleanup_step.get("env", {}).get(
        "CMUX_APP_HOST_PREPARATION_OUTCOME"
    ) != "${{ steps." + preparation_id + ".outcome }}":
        raise SystemExit("FAIL: cleanup must receive the actual preparation outcome")

    # The acceptance gate overrides the implicit success() so an earlier test
    # failure cannot hide it. It must then name preparation itself, or it would
    # also run after a failed checkout with no app-host home to test against.
    for rejected, fixture in {
        "a missing condition": None,
        "an implicit success() gate": (
            "${{ steps." + preparation_id + ".outcome == 'success' }}"
        ),
        "a gate without preparation": "${{ !cancelled() && matrix.shard == 1 }}",
        "another step's outcome": (
            "${{ !cancelled() && steps.other.outcome == 'success' }}"
        ),
        "a failed preparation": (
            "${{ !cancelled() && steps." + preparation_id + ".outcome != 'success' }}"
        ),
        "an always() gate": (
            "${{ always() && steps." + preparation_id + ".outcome == 'success' }}"
        ),
        "an alternative gate": (
            "${{ !cancelled() && steps."
            + preparation_id
            + ".outcome == 'success' || matrix.shard == 1 }}"
        ),
        "a parenthesized alternative to a gate": (
            "${{ !cancelled() && (steps."
            + preparation_id
            + ".outcome == 'success' || matrix.shard == 1) }}"
        ),
    }.items():
        if not acceptance_gate_problem(fixture, preparation_id):
            raise SystemExit(f"FAIL: acceptance gate guard must reject {rejected}")
    for acceptance_name in (
        "Run Cloud machine ordering acceptance",
        "Run agent notification semantics",
    ):
        acceptance_step = require_step("app-host-unit-tests", acceptance_name)
        acceptance_problem = acceptance_gate_problem(
            acceptance_step.get("if"), preparation_id
        )
        if acceptance_problem:
            raise SystemExit(f"FAIL: {acceptance_name} {acceptance_problem}")
    # The notification gate resolves `bun`, so its setup must survive the
    # same earlier failures the gate does.
    bun_condition = require_step(
        "app-host-unit-tests", "Set up Bun for Pi extension dispatch regression"
    ).get("if")
    if not bun_setup_gate_ok(bun_condition):
        raise SystemExit("FAIL: Bun setup must run after an earlier failure")
    for rejected in (
        "${{ matrix.shard == 4 || matrix.shard == 6 }}",
        "${{ !cancelled() && matrix.shard == 4 || matrix.shard == 6 }}",
        "${{ !cancelled() && (matrix.shard == 4) || (matrix.shard == 6) }}",
    ):
        if bun_setup_gate_ok(rejected):
            raise SystemExit(f"FAIL: Bun setup gate guard must reject {rejected}")

    node_condition = require_step(
        "app-host-unit-tests", "Ensure node for app-host wrapper regressions"
    ).get("if")
    if not node_setup_gate_ok(node_condition):
        raise SystemExit(
            "FAIL: node setup must cover CLI, focused, and notification strict shards"
        )

    # Once preparation starts, the console-user cleanup must still run even if
    # preparation fails or is cancelled, and its failures must remain visible.
    with tempfile.TemporaryDirectory() as workspace:
        for outcome in ("skipped", ""):
            result = subprocess.run(
                ["/bin/bash", "-e", "-o", "pipefail", "-c", cleanup_step["run"]],
                cwd=workspace,
                env={**os.environ, "CMUX_APP_HOST_PREPARATION_OUTCOME": outcome},
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                raise SystemExit(
                    f"FAIL: cleanup with preparation {outcome!r} must skip an "
                    f"empty checkout: {result.stderr}"
                )

        wrapper = Path(workspace) / "scripts/ci/run-in-console-session.sh"
        wrapper.parent.mkdir(parents=True)
        wrapper.write_text(
            '#!/bin/bash\n'
            'printf "%s\\n" "$@" > cleanup-invocation\n'
            'exit "${CLEANUP_TEST_EXIT_CODE:-0}"\n',
            encoding="utf-8",
        )
        wrapper.chmod(0o755)
        invocation = Path(workspace) / "cleanup-invocation"
        for outcome in ("success", "failure", "cancelled"):
            for exit_code in (0, 23):
                invocation.unlink(missing_ok=True)
                result = subprocess.run(
                    ["/bin/bash", "-e", "-o", "pipefail", "-c", cleanup_step["run"]],
                    cwd=workspace,
                    env={
                        **os.environ,
                        "CMUX_APP_HOST_PREPARATION_OUTCOME": outcome,
                        "CLEANUP_TEST_EXIT_CODE": str(exit_code),
                    },
                    capture_output=True,
                    text=True,
                )
                if result.returncode != exit_code or not invocation.is_file():
                    raise SystemExit(
                        f"FAIL: cleanup after preparation {outcome} must run "
                        f"and preserve exit {exit_code}: {result.stderr}"
                    )
                if invocation.read_text() != "scripts/ci/cleanup-app-host-home.sh\n":
                    raise SystemExit("FAIL: cleanup must run as the console user")

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

    check_every_app_host_home_is_identified_and_cleaned()
    check_e2e_test_derived_data_scope()
    check_every_test_executing_lane_pins_its_home()

    print("PASS: app-host XCTest receives an isolated launch home")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
