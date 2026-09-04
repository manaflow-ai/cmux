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
