from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui.yml"

FOCUSED_SENTINEL_STEPS = (
    "focused Linux journal process-fence test",
    "focused macOS journal process-fence tests",
    "focused journal writer shutdown test",
    "focused final journal ownership tests",
)


def _test_job() -> dict:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return workflow["jobs"]["test"]


def test_ignored_only_listing_has_no_runnable_test_names() -> None:
    listing = "test tui::slow_network_test: test\n"
    normal_names = {line for line in listing.splitlines() if line}
    ignored_names = {line for line in listing.splitlines() if line}

    assert normal_names
    assert ignored_names
    assert not normal_names - ignored_names


def test_workflow_rejects_ignored_only_filter_from_name_difference() -> None:
    workflow = WORKFLOW.read_text(encoding="utf-8")

    assert 'comm -23 "$normal_names" "$ignored_names"' in workflow
    assert 'if [[ ! -s "$runnable_names" && -s "$ignored_names" ]]; then' in workflow


def test_ignored_only_guard_returns_failure() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        normal_names = root / "normal"
        ignored_names = root / "ignored"
        runnable_names = root / "runnable"
        normal_names.write_text("test tui::slow_network_test: test\n", encoding="utf-8")
        ignored_names.write_text("test tui::slow_network_test: test\n", encoding="utf-8")
        script = """
set -euo pipefail
comm -23 "$1" "$2" > "$3"
if [[ ! -s "$3" && -s "$2" ]]; then
  exit 17
fi
"""
        result = subprocess.run(
            [
                "bash",
                "-eu",
                "-c",
                script,
                "guard",
                str(normal_names),
                str(ignored_names),
                str(runnable_names),
            ],
            check=False,
        )

    assert result.returncode == 17


def test_journal_sentinels_are_focused_only_and_full_uses_isolated_core_runner() -> None:
    job = _test_job()
    steps = {step.get("name"): step for step in job["steps"]}

    linux_condition = str(steps[FOCUSED_SENTINEL_STEPS[0]]["if"])
    assert "inputs.mode == 'focused'" in linux_condition
    assert "runner.os == 'Linux'" in linux_condition

    macos_condition = str(steps[FOCUSED_SENTINEL_STEPS[1]]["if"])
    assert "inputs.mode == 'focused'" in macos_condition
    assert "runner.os == 'macOS'" in macos_condition

    for name in FOCUSED_SENTINEL_STEPS[2:]:
        condition = str(steps[name]["if"])
        assert "inputs.mode == 'focused'" in condition
        assert "full" not in condition

    final_sentinels = steps[FOCUSED_SENTINEL_STEPS[3]]["run"]
    assert "cargo test -p cmux-tui-core --test browser_runtime" in final_sentinels
    assert "socket_browser_attach_streams_frames_input_and_cell_pixels" in final_sentinels

    cargo_test = steps["cargo test"]["run"]
    assert 'if [[ "$MODE" == "full" ]]; then' in cargo_test
    assert "run-cmux-tui-core-tests-isolated.py" in cargo_test
    assert "crates/cmux-tui-core" in cargo_test


def test_tui_status_names_remain_stable() -> None:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    assert workflow["jobs"]["test"]["name"] == "test (${{ matrix.os }})"
    assert (
        workflow["jobs"]["hosted-verification"]["name"]
        == "${{ inputs.mode == 'full' && 'hosted verification' || 'focused hosted verification' }}"
    )


def test_lint_is_one_required_job_and_os_matrix_only_runs_behavior_tests() -> None:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    lint = workflow["jobs"]["lint"]
    macos = workflow["jobs"]["macos"]
    test = workflow["jobs"]["test"]
    gate = workflow["jobs"]["hosted-verification"]

    lint_commands = "\n".join(str(step.get("run", "")) for step in lint["steps"])
    test_commands = "\n".join(str(step.get("run", "")) for step in test["steps"])
    gate_commands = "\n".join(str(step.get("run", "")) for step in gate["steps"])

    assert lint["needs"] == "validate-inputs"
    assert lint["name"] == "lint (${{ matrix.os }})"
    assert lint["strategy"]["fail-fast"] is False
    assert lint["strategy"]["matrix"]["include"] == [
        {
            "os": "linux",
            "runner": "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || 'blacksmith-32vcpu-ubuntu-2404' }}",
        },
    ]
    assert test["strategy"]["matrix"]["include"] == lint["strategy"]["matrix"]["include"]
    assert "cargo fmt --check" in lint_commands
    assert "cargo clippy --workspace --all-targets --locked -- -D warnings" in lint_commands
    assert "cargo fmt --check" in test_commands
    assert "cargo clippy --workspace --all-targets --locked -- -D warnings" not in test_commands
    macos_commands = "\n".join(str(step.get("run", "")) for step in macos["steps"])
    assert macos["name"] == "macOS lint and tests"
    # Formatting is host-independent and runs once, on Linux (#17095).
    assert "cargo fmt --check" not in macos_commands
    assert "cargo clippy --workspace --all-targets --locked -- -D warnings" in macos_commands
    assert "platform::tests::" in macos_commands
    assert "mac_process_scope" in macos_commands
    assert "macos_pty_" in macos_commands
    assert "lint" in gate["needs"]
    assert "macos" in gate["needs"]
    assert gate["env"]["LINT_RESULT"] == "${{ needs.lint.result }}"
    assert gate["env"]["MACOS_RESULT"] == "${{ needs.macos.result }}"
    assert 'require_success "lint" "$LINT_RESULT"' in gate_commands
    assert 'require_success "macOS lint and tests" "$MACOS_RESULT"' in gate_commands


def test_lint_matrix_runs_clippy_with_each_host_cfg() -> None:
    """Model the matrix expansion and runner guards that control lint coverage."""
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    lint = workflow["jobs"]["lint"]
    steps = lint["steps"]
    matrix = lint["strategy"]["matrix"]["include"]

    assert {entry["os"] for entry in matrix} == {"linux"}
    for entry in matrix:
        runner_os = "Linux"
        linux_dependency_steps = [
            step
            for step in steps
            if step.get("name") == "Install Linux build dependencies"
        ]
        assert len(linux_dependency_steps) == 1
        assert linux_dependency_steps[0]["if"] == "runner.os == 'Linux'"
        if runner_os == "Linux":
            assert "ubuntu-2404" in entry["runner"]

        clippy_steps = [step for step in steps if step.get("name") == "cargo clippy"]
        assert len(clippy_steps) == 1
        assert clippy_steps[0]["working-directory"] == "cmux-tui"
        assert "cargo clippy --workspace --all-targets --locked -- -D warnings" in clippy_steps[0]["run"]


MACOS_RELAY_RUNNER = (
    "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
    "vars.CI_PR_POOL_OWNED == '1' && "
    "contains(fromJSON('[\"pull_request\",\"push\",\"schedule\",\"workflow_dispatch\"]'), github.event_name) && "
    "github.run_attempt == 1 && (vars.CI_AWS_SIDE_RUNNER || vars.CI_SIDE_LANE_RUNNER) || "
    "vars.MACOS_RUNNER_BACKGROUND || 'blacksmith-6vcpu-macos-15' }}"
)


def test_macos_runs_the_chatmux_relay_tests() -> None:
    """The relay crate's tests run on macOS again.

    9f4acf5b2787 (#17051) dropped the `test (macos)` matrix entry, and with it
    the only macOS run of `cargo test -p chatmux-relay` (full mode, and focused
    mode with the chatmux_relay selector). The relay job takes the owned AWS
    minis through CI_AWS_SIDE_RUNNER on attempt 1 (CI_SIDE_LANE_RUNNER when it
    is empty), and a rerun returns to the background lane.
    """
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    job = workflow["jobs"]["macos-relay"]
    gate = workflow["jobs"]["hosted-verification"]

    assert job["name"] == "chatmux-relay tests (macOS)"
    assert job["needs"] == "validate-inputs"
    assert job["runs-on"] == MACOS_RELAY_RUNNER
    condition = str(job["if"])
    assert "inputs.mode == 'full'" in condition
    assert "inputs.test_filter == 'chatmux_relay'" in condition
    assert "inputs.test_filter == 'chatmux-relay'" in condition

    steps = {step.get("name"): step for step in job["steps"]}
    assert steps["Require exact checkout"]["run"] == 'test "$(git rev-parse HEAD)" = "$EXACT_COMMIT"'
    relay = steps["cargo test -p chatmux-relay"]
    assert relay["working-directory"] == "cmux-tui"
    assert "cargo test -p chatmux-relay --locked" in relay["run"]

    gate_commands = "\n".join(str(step.get("run", "")) for step in gate["steps"])
    assert "macos-relay" in gate["needs"]
    assert gate["env"]["MACOS_RELAY_RESULT"] == "${{ needs.macos-relay.result }}"
    assert gate["env"]["TEST_FILTER"] == "${{ inputs.test_filter }}"
    assert 'require_success "macOS chatmux-relay tests" "$MACOS_RELAY_RESULT"' in gate_commands


ARTIFACTS_WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"


def test_artifacts_macos_legs_take_the_aws_side_runner_on_attempt_one() -> None:
    workflow = yaml.safe_load(ARTIFACTS_WORKFLOW.read_text(encoding="utf-8"))
    builds = [
        job for job in workflow["jobs"].values()
        if isinstance(job, dict) and "macos_runner" in (job.get("with") or {})
    ]
    assert builds
    for job in builds:
        runner = job["with"]["macos_runner"]
        assert runner.startswith("${{ inputs.macos_runner || ")
        assert MACOS_RELAY_RUNNER.removeprefix("${{ ") in runner
        assert job["with"]["macos_retry_runner"] == (
            "${{ vars.MACOS_RUNNER_BACKGROUND || 'blacksmith-6vcpu-macos-15' }}"
        )
