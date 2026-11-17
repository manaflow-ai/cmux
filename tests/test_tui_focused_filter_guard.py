from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui.yml"

FOCUSED_SENTINEL_STEPS = (
    "focused Linux journal process-fence test",
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

    # The sentinels run in focused mode on Linux only: a focused run holds a Mac
    # only for setup, clippy and the filtered tests (2026-11-09 Mac queue).
    for name in FOCUSED_SENTINEL_STEPS:
        condition = str(steps[name]["if"])
        assert "inputs.mode == 'focused'" in condition
        assert "runner.os == 'Linux'" in condition
        assert "full" not in condition
    focused_only = [step.get("name") for step in job["steps"] if "inputs.mode == 'focused'" in str(step.get("if", ""))]
    assert sorted(focused_only) == sorted(FOCUSED_SENTINEL_STEPS)

    final_sentinels = steps[FOCUSED_SENTINEL_STEPS[2]]["run"]
    assert "cargo-test-deadline.sh -p cmux-tui-core --test browser_runtime" in final_sentinels
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
    # The runners are expressions: the macOS row takes the owned side lane on
    # attempt 1 and Blacksmith macOS 15 otherwise; the Linux row is Blacksmith Linux.
    rows = lint["strategy"]["matrix"]["include"]
    assert [row["os"] for row in rows] == ["macos", "linux"]
    assert all(set(row) == {"os", "runner"} for row in rows), rows
    assert "vars.CI_SIDE_LANE_RUNNER" in rows[0]["runner"], rows[0]
    assert rows[0]["runner"].endswith("'blacksmith-6vcpu-macos-15' }}"), rows[0]
    assert "ubuntu-2404" in rows[1]["runner"], rows[1]
    assert "cargo fmt --check" in lint_commands
    assert "cargo clippy --workspace --all-targets --locked -- -D warnings" in lint_commands
    assert "cargo fmt --check" not in test_commands
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
        runner_os = "Linux" if entry["os"] == "linux" else "macOS"
        linux_dependency_steps = [
            step
            for step in steps
            if step.get("name") == "Install Linux build dependencies"
        ]
        assert len(linux_dependency_steps) == 1
        assert linux_dependency_steps[0]["if"] == "runner.os == 'Linux'"
        if runner_os == "Linux":
            assert "ubuntu-2404" in entry["runner"]
        else:
            assert "macos-15" in entry["runner"]

        clippy_steps = [step for step in steps if step.get("name") == "cargo clippy"]
        assert len(clippy_steps) == 1
        assert clippy_steps[0]["working-directory"] == "cmux-tui"
        assert "cargo clippy --workspace --all-targets --locked -- -D warnings" in clippy_steps[0]["run"]


def _cargo_test_step() -> dict:
    [step] = [step for step in _test_job()["steps"] if step.get("name") == "cargo test"]
    return step


def _run_cargo_test_step(host_os: str, listing: str, ignored: str) -> tuple[int, str, str]:
    """Run the test job's `cargo test` step in focused mode against a fake cargo.

    The fake prints LISTING for `--list` and IGNORED for `--list --ignored`.
    Returns the exit code, the cargo calls and what the step wrote to $GITHUB_OUTPUT.
    """
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        log = root / "cargo.log"
        github_output = root / "github-output"
        github_output.write_text("", encoding="utf-8")
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
        script = root / "step.sh"
        script.write_text(_cargo_test_step()["run"], encoding="utf-8")
        # The step runs in cmux-tui/ and calls ../scripts/ci/cargo-test-deadline.sh, as in the checkout.
        work = root / "cmux-tui"
        work.mkdir()
        (root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        result = subprocess.run(
            ["bash", "-e", "-o", "pipefail", str(script)],
            check=False,
            capture_output=True,
            text=True,
            cwd=work,
            env={
                "PATH": f"{root}:/usr/bin:/bin",
                "RUNNER_TEMP": str(root),
                "GITHUB_OUTPUT": str(github_output),
                "MODE": "focused",
                "TEST_FILTER": "some_filter",
                "HOST_OS": host_os,
            },
        )
        calls = log.read_text(encoding="utf-8") if log.exists() else ""
        outputs = github_output.read_text(encoding="utf-8")
    return result.returncode, calls, outputs


def test_a_host_with_no_matching_test_passes_and_reports_its_count() -> None:
    """Host-only tests (Linux-only files, macOS-only tests) compile to nothing on the other host.

    A macOS-only filter (macos_app_support_loads_after_xdg, feat run 42626993043)
    failed the Linux leg with "selected no Rust tests". Each leg now passes a host
    with no matching test and writes selected_<os>=N; hosted verification fails the
    run only when both hosts selected 0 (port of #39706).
    """
    two = "tui::a: test\\ntui::b: test\\n"
    code, calls, outputs = _run_cargo_test_step("linux", two, "")
    assert code == 0 and "selected_linux=2" in outputs.splitlines(), (code, outputs)
    assert "test --workspace --locked --no-fail-fast some_filter\n" in calls, calls
    code, _, outputs = _run_cargo_test_step("macos", two, "tui::b: test\\n")
    assert code == 0 and "selected_macos=1" in outputs.splitlines(), (code, outputs)
    code, calls, outputs = _run_cargo_test_step("macos", "", "")
    assert code == 0 and "selected_macos=0" in outputs.splitlines(), (code, outputs)
    assert "test --workspace --locked --no-fail-fast some_filter\n" not in calls, calls
    # A filter that matches only ignored tests still fails on its host.
    code, _, _ = _run_cargo_test_step("linux", "tui::a: test\\n", "tui::a: test\\n")
    assert code == 1


def _run_full_step(workspace_red: bool, core_red: bool) -> tuple[int, str]:
    """Run the test job's full-mode `cargo test` step with a fake cargo and a fake core binary.

    The real wrapper, deadline runner and isolated core runner run (python3 is real). The
    fake cargo fails the workspace call when WORKSPACE_RED, and reports one fake
    cmux-tui-core test binary for `--no-run`; that binary fails `a_core_test` when
    CORE_RED. Returns the exit code and the log of cargo calls and core tests run.
    """
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        log = root / "calls.log"
        work = root / "cmux-tui"
        core_src = work / "crates" / "cmux-tui-core" / "src"
        core_src.mkdir(parents=True)
        core = root / "cmux_tui_core-fake"
        core.write_text(
            "#!/usr/bin/env bash\n"
            'if [ "$1" = --list ]; then [ "$2" = --ignored ] && exit 0; '
            "printf 'a_core_test: test\\nb_core_test: test\\n'; exit 0; fi\n"
            f'echo "core $1" >> "{log}"\n'
            + ('[ "$1" = a_core_test ] && { echo "test $1 ... FAILED"; exit 101; }\n' if core_red else "")
            + 'echo "test $1 ... ok"\n',
            encoding="utf-8",
        )
        artifact = (
            '{"reason":"compiler-artifact","profile":{"test":true},'
            f'"target":{{"kind":["lib"],"src_path":"{core_src}/lib.rs"}},"executable":"{core}"}}'
        )
        cargo = root / "cargo"
        cargo.write_text(
            "#!/usr/bin/env bash\n"
            f'echo "cargo $*" >> "{log}"\n'
            'case "$*" in\n'
            + ('  *"--workspace --exclude cmux-tui-core"*) exit 101 ;;\n' if workspace_red else "")
            + f"  *--no-run*) echo '{artifact}' ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        for fake in (core, cargo):
            fake.chmod(0o755)
        script = root / "step.sh"
        script.write_text(_cargo_test_step()["run"], encoding="utf-8")
        # The step runs in cmux-tui/ and calls ../scripts and ../.github, as in the checkout.
        (root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        (root / ".github").symlink_to(ROOT / ".github", target_is_directory=True)
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
            check=False,
            capture_output=True,
            text=True,
            cwd=work,
            env={
                "PATH": f"{root}:/usr/bin:/bin",
                "RUNNER_TEMP": str(root),
                "MODE": "full",
                "TEST_FILTER": "",
                "CMUX_TEST_DEADLINE_SECONDS": "60",
            },
        )
        calls = log.read_text(encoding="utf-8") if log.exists() else ""
    return result.returncode, calls + result.stdout + result.stderr


def test_full_mode_runs_every_test_group_and_fails_with_the_first_red() -> None:
    """A red workspace or a red core test must not skip the tests after it.

    Under `bash -e` a red workspace ended the step before the cmux-tui-core tests (port
    of feat #41233), and a red core test ended it before the core doc tests. Every group
    must run, and the step must fail with the first red status.
    """
    doc = "cargo test -p cmux-tui-core --doc --locked"

    code, log = _run_full_step(workspace_red=True, core_red=False)
    assert code == 101, (code, log)
    assert "core a_core_test" in log and "core b_core_test" in log, log
    assert doc in log, log

    code, log = _run_full_step(workspace_red=False, core_red=True)
    assert code != 0, (code, log)
    assert "core b_core_test" in log, log
    assert doc in log, log

    code, log = _run_full_step(workspace_red=False, core_red=False)
    assert code == 0, (code, log)
    assert doc in log, log


def test_the_relay_filter_runs_every_relay_test_binary() -> None:
    """The chatmux_relay focused path must not stop at its first red test binary."""
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        log = root / "cargo.log"
        cargo = root / "cargo"
        cargo.write_text(f'#!/usr/bin/env bash\necho "$*" >> "{log}"\n', encoding="utf-8")
        cargo.chmod(0o755)
        script = root / "step.sh"
        script.write_text(_cargo_test_step()["run"], encoding="utf-8")
        work = root / "cmux-tui"
        work.mkdir()
        (root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)],
            check=False,
            capture_output=True,
            text=True,
            cwd=work,
            env={"PATH": f"{root}:/usr/bin:/bin", "RUNNER_TEMP": str(root), "MODE": "focused",
                 "TEST_FILTER": "chatmux_relay", "HOST_OS": "linux"},
        )
        calls = log.read_text(encoding="utf-8") if log.exists() else ""
    assert result.returncode == 0, (result.returncode, calls, result.stderr)
    assert "test -p chatmux-relay --locked --no-fail-fast" in calls, calls


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
    """The run fails only when both hosts selected 0 tests.

    The two matrix legs run in parallel. Each sets only its own output key
    (selected_linux or selected_macos), so neither leg overwrites the other's
    count in the job's combined outputs; hosted verification gives the verdict.
    """
    for linux, macos, want in (("0", "3", 0), ("2", "0", 0), ("1", "1", 0), ("0", "0", 1)):
        code, output = _run_gate(LINUX_FOCUSED_SELECTED=linux, MACOS_FOCUSED_SELECTED=macos)
        assert code == want, (linux, macos, output)
        # The gate prints both counts, so a run log shows what each host ran.
        assert f"focused tests selected: linux={linux} macos={macos}" in output, output
        if want:
            assert "selected no Rust tests on Linux or macOS" in output, output
        else:
            for host, name, count in (("linux", "Linux", linux), ("macos", "macOS", macos)):
                warned = f"::warning::test_filter 'some_test' selected no Rust test on {name}" in output
                assert warned == (count == "0"), (host, output)
    code, output = _run_gate(MODE="full", TEST_FILTER="", LINUX_FOCUSED_SELECTED="0", MACOS_FOCUSED_SELECTED="0")
    assert code == 0, output


def test_a_green_test_job_must_report_both_counts_unless_the_filter_is_reserved() -> None:
    """Broken output wiring must not let a typo filter pass.

    When the matrix outputs do not arrive (an overwritten or renamed key), both
    counts are empty, and an empty count is never read as 0. So in focused mode a
    successful test job must report a count for each host, unless the filter is a
    reserved selector that runs a package instead of a listing (chatmux_relay).
    """
    for linux, macos in (("", "3"), ("2", ""), ("", "")):
        code, output = _run_gate(LINUX_FOCUSED_SELECTED=linux, MACOS_FOCUSED_SELECTED=macos)
        assert code == 1, (linux, macos, output)
        assert "reported no focused test count" in output, output
    for reserved in ("chatmux_relay", "chatmux-relay"):
        code, output = _run_gate(TEST_FILTER=reserved, LINUX_FOCUSED_SELECTED="", MACOS_FOCUSED_SELECTED="")
        assert code == 0, (reserved, output)


def test_each_test_matrix_leg_owns_one_count_key() -> None:
    """The test matrix keeps exactly one linux and one macos row, each with its own output key."""
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    job = workflow["jobs"]["test"]
    rows = job["strategy"]["matrix"]["include"]
    assert sorted(row["os"] for row in rows) == ["linux", "macos"], rows
    step = _cargo_test_step()
    assert step["env"]["HOST_OS"] == "${{ matrix.os }}"
    gate_env = workflow["jobs"]["hosted-verification"]["env"]
    for host, variable in (("linux", "LINUX_FOCUSED_SELECTED"), ("macos", "MACOS_FOCUSED_SELECTED")):
        assert job["outputs"][f"focused_selected_{host}"] == (
            "${{ steps.%s.outputs.selected_%s }}" % (step["id"], host)
        ), host
        assert gate_env[variable] == "${{ needs.test.outputs.focused_selected_%s }}" % host, variable


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
