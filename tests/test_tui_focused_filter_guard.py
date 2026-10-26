from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui.yml"
FOCUSED_SCRIPT = ROOT / "scripts" / "ci" / "cmux-tui-focused-test.sh"

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
    script = FOCUSED_SCRIPT.read_text(encoding="utf-8")

    assert 'comm -23 "$normal_names" "$ignored_names"' in script
    assert 'if [[ ! -s "$runnable_names" && -s "$ignored_names" ]]; then' in script


def test_macos_job_runs_the_focused_filter() -> None:
    """cx-jcfoz: a filtered dispatch ran the filter on Linux only and reported macOS green."""
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    for job_name in ("test", "macos"):
        steps = workflow["jobs"][job_name]["steps"]
        runs = [step for step in steps if "cmux-tui-focused-test.sh" in str(step.get("run", ""))]
        assert len(runs) == 1, job_name
        step = runs[0]
        assert step["working-directory"] == "cmux-tui"
        assert '"$TEST_FILTER"' in step["run"]
        assert step["env"]["TEST_FILTER"] == "${{ inputs.test_filter }}"
    macos_step = next(step for step in workflow["jobs"]["macos"]["steps"] if "cmux-tui-focused-test.sh" in str(step.get("run", "")))
    # Chief's real-daemon selector has its own Linux job; other filters still
    # execute on macOS after Clippy has run, including when it reports a red.
    assert macos_step["if"] == (
        "${{ !cancelled() && steps.clippy.outcome != 'skipped' && "
        "inputs.mode == 'focused' && inputs.test_filter != 'optchat_chief' }}"
    )


def _run_focused(listing: str, ignored: str, extra_env: dict[str, str] | None = None) -> tuple[int, str]:
    """Run the focused script against a fake cargo that prints LISTING / IGNORED for --list."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        log = root / "cargo.log"
        cargo = root / "cargo"
        cargo.write_text(
            "#!/usr/bin/env bash\n"
            f'echo "$*" >> "{log}"\n'
            'case "$*" in\n'
            f'  *"--list --ignored"*) printf "%b" "{ignored}" ;;\n'
            f'  *"--list"*) printf "%b" "{listing}" ;;\n'
            "esac\n",
            encoding="utf-8",
        )
        cargo.chmod(0o755)
        result = subprocess.run(
            ["bash", str(FOCUSED_SCRIPT), "some_filter", "--test-threads=2"],
            check=False,
            capture_output=True,
            text=True,
            env={"PATH": f"{root}:/usr/bin:/bin", "RUNNER_TEMP": str(root), **(extra_env or {})},
        )
        calls = log.read_text(encoding="utf-8") if log.exists() else ""
    return result.returncode, calls


def test_focused_script_fails_when_the_filter_selects_nothing() -> None:
    code, calls = _run_focused("", "")
    assert code == 1
    assert "some_filter -- --test-threads=2" not in calls


def test_a_host_that_compiles_none_of_the_filtered_tests_passes_when_allowed() -> None:
    """Linux-only test files (#![cfg(target_os = "linux")]) compile to nothing on macOS.

    A focused dispatch for bring_back_journey or cloud_move_journey ran them on Linux
    and then failed macOS with "selected no Rust tests". The macOS job allows a host
    with no matching test; Linux stays strict, so a typo still fails the dispatch.
    """
    code, calls = _run_focused("", "", {"CMUX_TUI_FOCUSED_ALLOW_NONE_ON_HOST": "1"})
    assert code == 0
    assert "some_filter -- --test-threads=2" not in calls
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    for job_name, allowed in (("macos", "1"), ("test", None)):
        step = next(
            step
            for step in workflow["jobs"][job_name]["steps"]
            if "cmux-tui-focused-test.sh" in str(step.get("run", ""))
        )
        assert step["env"].get("CMUX_TUI_FOCUSED_ALLOW_NONE_ON_HOST") == allowed, job_name


def test_focused_script_runs_the_selected_tests_with_extra_args() -> None:
    code, calls = _run_focused("tui::a_test: test\\n", "")
    assert code == 0
    assert "test --workspace --locked --no-fail-fast some_filter -- --test-threads=2" in calls


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
    # fc36c16ddea8: hand-picked selections go through cargo-test-selected.sh (fails on zero tests).
    assert "cargo-test-selected.sh -p cmux-tui-core --test browser_runtime" in final_sentinels
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
            "runner": "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 'blacksmith-4vcpu-ubuntu-2404' || contains(vars.LINUX_RUNNER, '32vcpu') && vars.LINUX_RUNNER || 'blacksmith-32vcpu-ubuntu-2404' }}",
        },
    ]
    # Same OS matrix; only lint honors a LINUX_RUNNER override.
    oses = lambda job: [row["os"] for row in job["strategy"]["matrix"]["include"]]
    assert oses(test) == oses(lint) == ["linux"]
    assert "cargo fmt --check" in lint_commands
    assert "cargo clippy --workspace --exclude cmux-holder-v3 --all-targets --locked --keep-going -- -D warnings" in lint_commands
    # Formatting is gated once, by lint; a format diff must not stop the tests.
    assert "cargo fmt --check" not in test_commands
    assert "cargo clippy --workspace --exclude cmux-holder-v3 --all-targets --locked --keep-going -- -D warnings" not in test_commands
    macos_commands = "\n".join(str(step.get("run", "")) for step in macos["steps"])
    assert macos["name"] == "macOS lint and tests"
    # Formatting is host-independent and runs once, on Linux (#17095).
    assert "cargo fmt --check" not in macos_commands
    assert "cargo clippy --workspace --exclude cmux-holder-v3 --all-targets --locked --keep-going -- -D warnings" in macos_commands
    assert "platform::tests::" in macos_commands
    # mac_process_scope / macos_pty_ unit tests were deleted with the unit suites (c38b54db5a6e, cx-034r).
    assert "a_daemon_integrated_zsh_titles_a_long_command_with_every_argument" in macos_commands
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
        assert "cargo clippy --workspace --exclude cmux-holder-v3 --all-targets --locked --keep-going -- -D warnings" in clippy_steps[0]["run"]


def test_relay_filter_runs_on_the_linux_test_job() -> None:
    """The focused relay selector is handled by the Linux test job.

    The full Linux workspace test already covers chatmux-relay. Keeping a
    separate Mac-only invocation duplicated that work and spent a Mac runner.
    """
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    test_job = workflow["jobs"]["test"]
    gate = workflow["jobs"]["hosted-verification"]
    test_commands = "\n".join(str(step.get("run", "")) for step in test_job["steps"])
    assert 'cmux-tui-focused-test.sh "$TEST_FILTER"' in test_commands
    assert "macos-relay" not in workflow["jobs"]
    assert "macos-relay" not in gate["needs"]
    gate_commands = "\n".join(str(step.get("run", "")) for step in gate["steps"])
    assert "MACOS_RELAY_RESULT" not in gate_commands


ARTIFACTS_WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-artifacts.yml"


def test_artifacts_macos_legs_take_the_side_lane_on_attempt_one() -> None:
    """Attempt 1 takes the owned minis' side lane; a rerun goes to Blacksmith macOS 15.

    Never vars.MACOS_RUNNER_PR, the nightly build's 12 vCPU macOS 26 label,
    and neither names the retired glaeda-aws pools.
    """
    workflow = yaml.safe_load(ARTIFACTS_WORKFLOW.read_text(encoding="utf-8"))
    builds = [
        job for job in workflow["jobs"].values()
        if isinstance(job, dict) and "macos_runner" in (job.get("with") or {})
    ]
    assert builds
    for job in builds:
        assert job["with"]["macos_runner"] == (
            "${{ inputs.macos_runner || github.repository_owner != 'manaflow-ai' && 'macos-26' || "
            "vars.CI_PR_POOL_OWNED == '1' && "
            "contains(fromJSON('[\"pull_request\",\"push\",\"schedule\",\"workflow_dispatch\"]'), github.event_name) && "
            "github.run_attempt == 1 && vars.CI_SIDE_LANE_RUNNER || "
            "'blacksmith-6vcpu-macos-15' }}"
        )
        assert job["with"]["macos_retry_runner"] == (
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
            "'blacksmith-6vcpu-macos-15' }}"
        )


def test_dogfood_artifacts_never_wait_for_the_side_lane() -> None:
    """The release-path dogfood build goes straight to Blacksmith macOS 15.

    On the owned side lane, focused runs' dogfood builds sat queued until the
    run was cancelled (up to 120 min; one success waited 92 min for a 25 min
    build) while the fast tier queued behind them (#20612). They no longer take
    the PR pool either: vars.MACOS_RUNNER_PR names the 12 vCPU macOS 26 label
    the nightly app build needs.
    """
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    build = workflow["jobs"]["build-artifacts"]["with"]

    for route in (build["macos_runner"], build["macos_retry_runner"]):
        assert "CI_SIDE_LANE_RUNNER" not in route
        assert "glaeda-" not in route
        assert "MACOS_RUNNER_PR" not in route
        assert route == (
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
            "'blacksmith-6vcpu-macos-15' }}"
        )


def test_focused_dogfood_builds_the_macos_target_on_linux() -> None:
    """Focused runs cross-compile the macOS target on a Linux runner.

    The Mac leg queued 23-84 min and ran 17-20 min on 2026-10-20 and was the
    focused run's critical path. Full runs keep the Mac build: the Linux path
    packages neither npm nor PyPI, and cmux-tui-build-package.yml refuses
    build_agent_plugin with it (the Linux path builds the plugin into its tree).
    """
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    build = workflow["jobs"]["build-artifacts"]["with"]

    assert build["darwin_builder"] == "${{ inputs.mode == 'full' && 'mac' || 'linux' }}"
    assert build["build_agent_plugin"] == "${{ inputs.mode == 'full' }}"
    assert build["package_npm"] == "${{ inputs.mode == 'full' }}"
    assert build["package_pypi"] == "${{ inputs.mode == 'full' }}"


def test_hosted_verification_gate_reports_every_selected_job_before_failing() -> None:
    """A red lint (often a base clippy red) must not hide whether the
    filtered Rust tests passed: the gate lists each selected job's result
    and fails once, at the end."""
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    gate = workflow["jobs"]["hosted-verification"]
    step = next(s for s in gate["steps"] if s.get("name") == "Require selected verification jobs")
    env = {key: "success" for key, value in gate["env"].items() if key.endswith("_RESULT")}
    env.update({"MODE": "focused", "TEST_FILTER": "some_test", "LINT_RESULT": "failure",
                "MACOS_RESULT": "failure", "PATH": "/usr/bin:/bin"})
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / "gate.sh"
        script.write_text(step["run"], encoding="utf-8")
        run = subprocess.run(["bash", str(script)], env=env, capture_output=True, text=True)
    output = run.stdout + run.stderr
    assert run.returncode == 1, output
    assert "lint finished with result 'failure'" in output, output
    assert "macOS lint and tests finished with result 'failure'" in output, output
    assert "Rust tests: success" in output, output
