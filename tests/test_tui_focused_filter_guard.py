from __future__ import annotations

import importlib.util
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui.yml"
GATE_VERDICT = ROOT / "scripts" / "ci" / "gate_verdict.py"

_GATE_SPEC = importlib.util.spec_from_file_location("tui_gate_verdict", GATE_VERDICT)
assert _GATE_SPEC is not None and _GATE_SPEC.loader is not None
_GATE_VERDICT = importlib.util.module_from_spec(_GATE_SPEC)
sys.modules["tui_gate_verdict"] = _GATE_VERDICT
_GATE_SPEC.loader.exec_module(_GATE_VERDICT)

FOCUSED_SENTINEL_STEPS = (
    "focused Linux journal process-fence test",
    "focused macOS journal process-fence tests",
    "focused journal writer shutdown test",
    "focused final journal ownership tests",
)


def _test_job() -> dict:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return workflow["jobs"]["test"]


def _runner_context(
    *,
    repository_owner: str = "manaflow-ai",
    event_name: str = "push",
    head_repository: str = "manaflow-ai/cmux",
    run_attempt: int = 1,
    variables: dict[str, str] | None = None,
) -> dict:
    context_variables = {
        "CI_PR_POOL_OWNED": "",
        "CI_SIDE_LANE_RUNNER": "",
        "LINUX_RUNNER": "",
    }
    context_variables.update(variables or {})
    return {
        "github": {
            "repository_owner": repository_owner,
            "repository": "manaflow-ai/cmux",
            "event_name": event_name,
            "run_attempt": run_attempt,
            "event": {
                "pull_request": {
                    "head": {"repo": {"full_name": head_repository}},
                },
            },
        },
        "vars": context_variables,
    }


def _evaluate_runner(entry: dict, context: dict) -> str:
    expression = _GATE_VERDICT.strip_expression(entry["runner"])
    return str(_GATE_VERDICT.evaluate(expression, context, {}))


def _assert_runner_routing(matrix: list[dict]) -> None:
    """Evaluate every matrix expression through the same routing semantics as CI."""
    by_os = {entry["os"]: entry for entry in matrix}
    assert set(by_os) == {"linux", "macos"}

    owned_mac_runner = "owned-macos-lint"
    scenarios = (
        (
            "hosted",
            _runner_context(repository_owner="contributor"),
            {"linux": "ubuntu-24.04", "macos": "macos-26"},
        ),
        (
            "fork",
            _runner_context(
                event_name="pull_request",
                head_repository="contributor/cmux",
                variables={"LINUX_RUNNER": "linux-32vcpu-override"},
            ),
            {
                "linux": "blacksmith-4vcpu-ubuntu-2404",
                "macos": "blacksmith-6vcpu-macos-15",
            },
        ),
        (
            "repository Linux override",
            _runner_context(variables={"LINUX_RUNNER": "linux-32vcpu-override"}),
            {"linux": "linux-32vcpu-override"},
        ),
        (
            "owned macOS first attempt",
            _runner_context(
                variables={"CI_PR_POOL_OWNED": "1", "CI_SIDE_LANE_RUNNER": owned_mac_runner},
            ),
            {"macos": owned_mac_runner},
        ),
        (
            "owned macOS retry",
            _runner_context(
                run_attempt=2,
                variables={"CI_PR_POOL_OWNED": "1", "CI_SIDE_LANE_RUNNER": owned_mac_runner},
            ),
            {"macos": "blacksmith-6vcpu-macos-15"},
        ),
    )
    for scenario, context, expected in scenarios:
        for os_name, expected_runner in expected.items():
            assert _evaluate_runner(by_os[os_name], context) == expected_runner, scenario


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
    test = workflow["jobs"]["test"]
    gate = workflow["jobs"]["hosted-verification"]

    lint_commands = "\n".join(str(step.get("run", "")) for step in lint["steps"])
    test_commands = "\n".join(str(step.get("run", "")) for step in test["steps"])
    gate_commands = "\n".join(str(step.get("run", "")) for step in gate["steps"])

    assert lint["needs"] == "validate-inputs"
    assert lint["name"] == "lint (${{ matrix.os }})"
    assert lint["strategy"]["fail-fast"] is False
    matrix = lint["strategy"]["matrix"]["include"]
    assert len(matrix) == 2
    _assert_runner_routing(matrix)
    assert "cargo fmt --check" in lint_commands
    assert "cargo clippy --workspace --all-targets --locked -- -D warnings" in lint_commands
    # Keep the formatting check in both hosted OS lanes as the workflow does;
    # clippy remains owned by the dedicated lint matrix below.
    assert "cargo fmt --check" in test_commands
    assert "cargo clippy --workspace --all-targets --locked -- -D warnings" not in test_commands
    assert "lint" in gate["needs"]
    assert gate["env"]["LINT_RESULT"] == "${{ needs.lint.result }}"
    assert 'require_success "lint" "$LINT_RESULT"' in gate_commands


def test_lint_matrix_runs_clippy_with_each_host_cfg() -> None:
    """Model the matrix expansion and runner guards that control lint coverage."""
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    lint = workflow["jobs"]["lint"]
    steps = lint["steps"]
    matrix = lint["strategy"]["matrix"]["include"]

    assert {entry["os"] for entry in matrix} == {"linux", "macos"}
    for entry in matrix:
        linux_dependency_steps = [
            step
            for step in steps
            if step.get("name") == "Install Linux build dependencies"
        ]
        assert len(linux_dependency_steps) == 1
        assert linux_dependency_steps[0]["if"] == "runner.os == 'Linux'"

        clippy_steps = [step for step in steps if step.get("name") == "cargo clippy"]
        assert len(clippy_steps) == 1
        assert "if" not in clippy_steps[0]
        assert clippy_steps[0]["working-directory"] == "cmux-tui"
        assert "cargo clippy --workspace --all-targets --locked -- -D warnings" in clippy_steps[0]["run"]
