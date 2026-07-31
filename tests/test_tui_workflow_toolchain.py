from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui.yml"
VALGRIND_PIDFD_SKIPS = ROOT / "cmux-tui" / "dist" / "valgrind-pidfd-skips.txt"
RUST_JOBS = (
    "valgrind-leak-check",
    "test",
    "bindings-e2e",
    "windows-experimental",
)
BROWSER_RUNTIME_PIDFD_TESTS = {
    "browser_capture_scale_applies_to_metrics_screencast_and_input",
    "browser_tab_creation_is_async_and_surfaces_bootstrap_failure",
    "control_command_reports_backpressure_when_worker_queue_is_full",
    "queued_back_and_forward_do_not_collapse_while_worker_is_blocked",
    "socket_browser_attach_streams_frames_input_and_cell_pixels",
    "stalled_external_browser_nudges_target_once_before_interaction",
    "wedged_browser_navigate_does_not_block_same_socket_connection",
}
CMUX_TUI_CORE_VALGRIND_INCOMPATIBLE_TESTS = {
    "browser::tests::ordinary_repaint_preserves_captured_drag_motion",
    "browser::tests::server_shutdown_bounds_external_target_confirmation",
    "mux::tests::bulk_surface_close_uses_one_shared_termination_deadline",
    "mux::tests::ordinary_browser_close_terminates_the_owner_staged_during_removal",
    "mux::tests::shutdown_fanout_does_not_claim_another_batch_after_the_deadline",
    "mux::tests::surface_creation_fence_has_a_bounded_wait",
    "mux::tests::terminal_adoption_rescan_uses_one_registry_snapshot",
    "server::tests::clear_history_does_not_block_unrelated_surface_input_on_one_connection",
}


def job_block(workflow: str, job: str) -> str:
    marker = f"\n  {job}:\n"
    remainder = workflow.split(marker, 1)[1]
    next_job = re.search(r"\n  [a-zA-Z0-9_-]+:\n", remainder)
    return remainder[: next_job.start()] if next_job else remainder


def test_tui_rust_jobs_install_the_release_toolchain() -> None:
    workflow = WORKFLOW.read_text()
    assert '\nenv:\n  RUST_TOOLCHAIN: "1.95.0"\n' in workflow

    for job in RUST_JOBS:
        block = job_block(workflow, job)
        assert "rustup toolchain install \"$RUST_TOOLCHAIN\" --profile minimal" in block
        assert "rustup default \"$RUST_TOOLCHAIN\"" in block
        assert "if ! command -v cargo" not in block

    test_job = job_block(workflow, "test")
    assert "--component clippy,rustfmt" in test_job


def test_valgrind_fallback_keeps_non_pidfd_tests() -> None:
    entries = [
        tuple(line.split(maxsplit=1))
        for line in VALGRIND_PIDFD_SKIPS.read_text().splitlines()
        if line and not line.startswith("#")
    ]
    assert all(len(entry) == 2 for entry in entries)
    assert len(entries) == len(set(entries))
    assert {scope for scope, _ in entries} == {
        "browser_runtime",
        "cmux_tui",
        "cmux_tui_core",
        "pty",
        "websocket_transport",
    }
    assert {
        test_name for scope, test_name in entries if scope == "browser_runtime"
    } == BROWSER_RUNTIME_PIDFD_TESTS
    assert CMUX_TUI_CORE_VALGRIND_INCOMPATIBLE_TESTS <= {
        test_name for scope, test_name in entries if scope == "cmux_tui_core"
    }

    valgrind_job = job_block(WORKFLOW.read_text(), "valgrind-leak-check")
    assert "Skipping pidfd-dependent test binary" not in valgrind_job
    assert "dist/valgrind-pidfd-skips.txt" in valgrind_job
    assert "test_scope=browser_runtime" in valgrind_job
    assert 'test_args+=(--skip "$test_name")' in valgrind_job


def test_macos_serializes_process_barrier_tests() -> None:
    test_job = job_block(WORKFLOW.read_text(), "test")
    assert 'if [[ "$RUNNER_OS" == "macOS" ]]; then' in test_job
    assert 'export CMUX_TEST_TIMEOUT_SCALE="4"' in test_job
    assert "args+=(-- --test-threads=1)" in test_job
    assert 'cargo test --workspace --locked "${args[@]}"' in test_job


if __name__ == "__main__":
    test_tui_rust_jobs_install_the_release_toolchain()
    test_valgrind_fallback_keeps_non_pidfd_tests()
    test_macos_serializes_process_barrier_tests()
