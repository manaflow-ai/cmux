from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

from runs_on_labels import disallowed_labels, linux_runner_values


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
    code, calls, _ = _run_focused_with_output(listing, ignored, extra_env)
    return code, calls


def _run_focused_with_output(
    listing: str, ignored: str, extra_env: dict[str, str] | None = None
) -> tuple[int, str, str]:
    """Like _run_focused, and also return what the script wrote to $GITHUB_OUTPUT."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        github_output = root / "github-output"
        github_output.write_text("", encoding="utf-8")
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
            env={
                "PATH": f"{root}:/usr/bin:/bin",
                "RUNNER_TEMP": str(root),
                "GITHUB_OUTPUT": str(github_output),
                **(extra_env or {}),
            },
        )
        calls = log.read_text(encoding="utf-8") if log.exists() else ""
        outputs = github_output.read_text(encoding="utf-8")
    return result.returncode, calls, outputs


def test_focused_script_fails_when_the_filter_selects_nothing() -> None:
    code, calls = _run_focused("", "")
    assert code == 1
    assert "some_filter -- --test-threads=2" not in calls


def test_a_host_that_compiles_none_of_the_filtered_tests_passes_when_allowed() -> None:
    """Host-only test files (#![cfg(target_os = "linux")], macOS-only tests) compile to nothing elsewhere.

    A focused dispatch for bring_back_journey or cloud_move_journey ran them on Linux
    and then failed macOS with "selected no Rust tests". A macOS-only filter
    (macos_app_support_loads_after_xdg, run 42626993043, 2026-11-09) failed Linux the
    same way. Both jobs allow a host with no matching test and report the count;
    hosted verification fails the run when neither host ran one, so a typo still fails.
    """
    code, calls = _run_focused("", "", {"CMUX_TUI_FOCUSED_ALLOW_NONE_ON_HOST": "1"})
    assert code == 0
    assert "some_filter -- --test-threads=2" not in calls
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    for job_name, allowed in (("macos", "1"), ("test", "1")):
        step = next(
            step
            for step in workflow["jobs"][job_name]["steps"]
            if "cmux-tui-focused-test.sh" in str(step.get("run", ""))
        )
        assert step["env"].get("CMUX_TUI_FOCUSED_ALLOW_NONE_ON_HOST") == allowed, job_name


def test_focused_script_reports_how_many_tests_it_selected() -> None:
    """Each host writes its runnable count to $GITHUB_OUTPUT (selected=N) for hosted verification."""
    code, _, outputs = _run_focused_with_output("tui::a: test\\ntui::b: test\\n", "")
    assert code == 0 and "selected=2" in outputs.splitlines(), outputs
    code, _, outputs = _run_focused_with_output("tui::a: test\\ntui::b: test\\n", "tui::b: test\\n")
    assert code == 0 and "selected=1" in outputs.splitlines(), outputs
    code, _, outputs = _run_focused_with_output("", "", {"CMUX_TUI_FOCUSED_ALLOW_NONE_ON_HOST": "1"})
    assert code == 0 and "selected=0" in outputs.splitlines(), outputs


def _focused_count_step(job: dict) -> dict:
    [step] = [step for step in job["steps"] if "cmux-tui-focused-test.sh" in str(step.get("run", ""))]
    return step


def _run_gate(**env_overrides: str) -> tuple[int, str]:
    """Run hosted verification's gate step with every selected job green, then ENV_OVERRIDES."""
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    gate = workflow["jobs"]["hosted-verification"]
    step = next(s for s in gate["steps"] if s.get("name") == "Require selected verification jobs")
    env = {key: "success" for key, value in gate["env"].items() if key.endswith("_RESULT")}
    env.update({"MODE": "focused", "TEST_FILTER": "some_test", "PATH": "/usr/bin:/bin", **env_overrides})
    with tempfile.TemporaryDirectory() as tmp:
        script = Path(tmp) / "gate.sh"
        script.write_text(step["run"], encoding="utf-8")
        run = subprocess.run(["bash", "-e", str(script)], env=env, capture_output=True, text=True)
    return run.returncode, run.stdout + run.stderr


def test_a_filter_that_one_host_runs_passes_and_one_that_no_host_runs_fails() -> None:
    """A macOS-only or Linux-only filter passes; the run fails only when both hosts selected 0 tests.

    The Linux and macOS jobs run in parallel and each reports its count as a job
    output; hosted verification, which needs both, gives the verdict.
    """
    for linux, macos, want in (("0", "3", 0), ("2", "0", 0), ("1", "1", 0), ("", "0", 0), ("0", "0", 1)):
        code, output = _run_gate(LINUX_FOCUSED_SELECTED=linux, MACOS_FOCUSED_SELECTED=macos)
        assert code == want, (linux, macos, output)
        if want:
            assert "selected no Rust tests on Linux or macOS" in output, output
    # Full mode has no filter: the counts do not apply.
    code, output = _run_gate(MODE="full", TEST_FILTER="", LINUX_FOCUSED_SELECTED="0", MACOS_FOCUSED_SELECTED="0")
    assert code == 0, output

    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    gate_env = workflow["jobs"]["hosted-verification"]["env"]
    for job_name, variable in (("test", "LINUX_FOCUSED_SELECTED"), ("macos", "MACOS_FOCUSED_SELECTED")):
        job = workflow["jobs"][job_name]
        step = _focused_count_step(job)
        assert job["outputs"]["focused_selected"] == "${{ steps.%s.outputs.selected }}" % step["id"], job_name
        assert gate_env[variable] == "${{ needs.%s.outputs.focused_selected }}" % job_name, variable


def test_focused_script_runs_the_selected_tests_with_extra_args() -> None:
    code, calls = _run_focused("tui::a_test: test\\n", "")
    assert code == 0
    assert "test --workspace --locked --no-fail-fast some_filter -- --test-threads=2" in calls


def test_a_test_binary_that_hangs_while_listing_fails_fast_and_is_named() -> None:
    """A cmux_tui test binary hung while listing on macOS and ran into the job's 40 minute
    timeout with only "The operation was canceled." (runs 42458823348, 42461695724). The
    listing now fails once it is quiet past its deadline, naming the last binary cargo ran."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        cargo = root / "cargo"
        cargo.write_text(
            "#!/usr/bin/env bash\n"
            'case "$*" in\n'
            '  *"--list"*) echo "     Running unittests src/main.rs (target/debug/deps/cmux_tui-abc)"; sleep 60 ;;\n'
            "esac\n",
            encoding="utf-8",
        )
        cargo.chmod(0o755)
        result = subprocess.run(
            ["bash", str(FOCUSED_SCRIPT), "some_filter"],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
            env={
                "PATH": f"{root}:/usr/bin:/bin",
                "RUNNER_TEMP": str(root),
                "CMUX_TUI_FOCUSED_LIST_SILENCE_SECONDS": "2",
            },
        )
    output = result.stdout + result.stderr
    assert result.returncode == 124, output
    assert "::error" in output and "target/debug/deps/cmux_tui-abc" in output, output


def test_a_hang_in_the_ignored_listing_still_names_its_binary() -> None:
    """The ignored pass writes to a file; its watchdog report must still reach the log."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        cargo = root / "cargo"
        cargo.write_text(
            "#!/usr/bin/env bash\n"
            'case "$*" in\n'
            '  *"--list --ignored"*) echo "     Running tests/slow.rs (target/debug/deps/slow-abc)"; sleep 60 ;;\n'
            '  *"--list"*) printf "tui::a_test: test\\n" ;;\n'
            "esac\n",
            encoding="utf-8",
        )
        cargo.chmod(0o755)
        result = subprocess.run(
            ["bash", str(FOCUSED_SCRIPT), "some_filter"],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
            env={
                "PATH": f"{root}:/usr/bin:/bin",
                "RUNNER_TEMP": str(root),
                "CMUX_TUI_FOCUSED_LIST_SILENCE_SECONDS": "2",
            },
        )
    output = result.stdout + result.stderr
    assert result.returncode == 124, output
    assert "::error" in output and "target/debug/deps/slow-abc" in output, output


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


def _run_full_step(workspace_fails: bool) -> tuple[int, str]:
    """Run the test job's full-mode `cargo test` step against a fake cargo and python3.

    The fake cargo fails the workspace call when WORKSPACE_FAILS. Returns the exit code
    and every cargo and python3 call, in order.
    """
    steps = {step.get("name"): step for step in _test_job()["steps"]}
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        log = root / "calls.log"
        fail = 'case "$*" in *"--workspace --exclude cmux-tui-core"*) exit 101 ;; esac\n'
        cargo = root / "cargo"
        cargo.write_text(
            "#!/usr/bin/env bash\n"
            f'echo "cargo $*" >> "{log}"\n'
            + (fail if workspace_fails else ""),
            encoding="utf-8",
        )
        python = root / "python3"
        python.write_text(f'#!/usr/bin/env bash\necho "python3 $*" >> "{log}"\n', encoding="utf-8")
        for fake in (cargo, python):
            fake.chmod(0o755)
        script = root / "step.sh"
        script.write_text(steps["cargo test"]["run"], encoding="utf-8")
        work = root / "cmux-tui"
        work.mkdir()
        # GitHub runs `shell: bash` as `bash --noprofile --norc -eo pipefail`.
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
            check=False,
            capture_output=True,
            text=True,
            cwd=work,
            env={"PATH": f"{root}:/usr/bin:/bin", "MODE": "full", "TEST_FILTER": "", "RUNNER_TEMP": str(root)},
        )
        calls = log.read_text(encoding="utf-8") if log.exists() else ""
    return result.returncode, calls


def test_a_red_workspace_still_runs_the_core_tests_and_fails_the_step() -> None:
    """Full mode runs the workspace with --no-fail-fast, then the cmux-tui-core tests.

    Under `bash -e` a red workspace (a base red in any crate) ended the step before the
    cmux-tui-core unit and doc tests, so a PR shipped without them ever running. The core
    tests must still run, and the step must still fail with the workspace status.
    """
    code, calls = _run_full_step(workspace_fails=True)
    assert code == 101, (code, calls)
    assert "python3 ../.github/scripts/run-cmux-tui-core-tests-isolated.py" in calls, calls
    assert "cargo test -p cmux-tui-core --doc --locked" in calls, calls

    code, calls = _run_full_step(workspace_fails=False)
    assert code == 0, (code, calls)
    assert "cargo test -p cmux-tui-core --doc --locked" in calls, calls


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
    [row] = lint["strategy"]["matrix"]["include"]
    assert set(row) == {"os", "runner"} and row["os"] == "linux", row
    # Every label the runner can resolve to is Blacksmith Linux, whatever LINUX_RUNNER holds: a fleet
    # Linux label or the overflow switch's hosted ubuntu-24.04, which the 32vcpu guard keeps out.
    variables = {"LINUX_RUNNER": linux_runner_values()}
    assert disallowed_labels(row["runner"], variables=variables) == {}, row
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
    """Attempt 1 takes the owned minis' side lane; a rerun goes to the macOS 15 pool.

    Never vars.MACOS_RUNNER_PR, the nightly build's 12 vCPU macOS 26 label,
    and neither names the retired glaeda-aws pools. Since #32457 every runner
    selection reads its size's declared pool (fromJSON(vars.RUNNER_POOLS).macos_15,
    declared in .github/runners.json) instead of the Blacksmith literal.
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
            "fromJSON(vars.RUNNER_POOLS).macos_15 }}"
        )
        assert job["with"]["macos_retry_runner"] == (
            "${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || "
            "fromJSON(vars.RUNNER_POOLS).macos_15 }}"
        )


def test_dogfood_artifacts_never_wait_for_the_side_lane() -> None:
    """The release-path dogfood build goes straight to the macOS 15 pool (Blacksmith macOS 15).

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
            "fromJSON(vars.RUNNER_POOLS).macos_15 }}"
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


def main() -> int:
    """Run every test_ function in this file; CI calls the file with plain python3 (no pytest).

    Before this, the file had no entry point, so `python3 tests/test_tui_focused_filter_guard.py`
    (ci-guards.yml) defined the tests, ran none of them, and passed.
    """
    import traceback

    tests = [(name, value) for name, value in globals().items() if name.startswith("test_") and callable(value)]
    failed: list[str] = []
    for name, test in tests:
        try:
            test()
        except Exception:  # noqa: BLE001 - report every failure, then exit non-zero once
            failed.append(name)
            print(f"FAIL: {name}", file=sys.stderr)
            traceback.print_exc()
        else:
            print(f"ok: {name}")
    print(f"{len(tests) - len(failed)} of {len(tests)} tests passed")
    if not tests:
        print("error: no tests found", file=sys.stderr)
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
