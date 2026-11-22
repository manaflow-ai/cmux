//! `session current shutdown` against an interactive client whose daemon is
//! a detached owner.

use super::*;

#[test]
// Quarantined after hosted Linux run 37069452699: the detached-owner client
// once exited 1 during an orderly shutdown; the rerun passed.
#[ignore = "hosted lifecycle flake: detached-owner shutdown exit race"]
fn session_shutdown_exits_an_interactive_detached_owner_client() {
    let dir = TestTempDir::create("interactive-session-shutdown");
    let socket = dir.path().join("mux.sock");
    let socket_arg = socket.to_str().unwrap();
    let state = dir.path().join("state");
    let state_arg = state.to_str().unwrap();
    let config = dir.path().join("config.json");
    fs::write(&config, r#"{"server":{"detached_owner":true}}"#).unwrap();
    let mut client = PtyChild::start_with_env(
        &[
            "--session",
            "interactive-session-shutdown",
            "--socket",
            socket_arg,
            "--state",
            state_arg,
        ],
        &[("CMUX_TUI_CONFIG", config.as_os_str())],
    );
    wait_for_socket_path(&socket);
    wait_for_owner_server_ready(&socket, &mut client);

    let shutdown =
        lifecycle_cli(&["--json", "--socket", socket_arg, "session", "current", "shutdown"]);
    assert_success(&shutdown);
    assert_eq!(json_output(&shutdown)["value"]["accepted"], true);

    let status = client.wait_for_exit(Duration::from_secs(5));
    let output = client.output_tail();
    let status = status.unwrap_or_else(|| {
        panic!(
            "interactive client remained alive after detached owner shutdown; output:\n{output:?}"
        )
    });
    assert!(
        status.success(),
        "interactive client exited unsuccessfully: {status}; output:\n{output:?}"
    );
    // session.shutdown keeps durable terminal hosts alive on purpose (the
    // next daemon adopts them), and no daemon is left to close them. End this
    // test's own hosts so a run leaves no process behind.
    stop_fixture_terminal_hosts(&cmux_tui_core::terminal_host_runtime::terminal_host_root(
        &state,
        "interactive-session-shutdown",
    ));
}

/// Ends every terminal host recorded under `host_root` (a test's private
/// state root) after its daemon is gone, then removes the records. A host is
/// a session leader, so its group signal also reaches nothing outside it;
/// its shell gets SIGHUP when the host's PTY closes.
fn stop_fixture_terminal_hosts(host_root: &std::path::Path) {
    let records = cmux_tui_core::terminal_host_runtime::load_terminal_host_records(host_root)
        .expect("load the fixture's terminal-host records");
    let pids = records.iter().map(|(_, record)| record.host_pid).collect::<Vec<_>>();
    for signal in [libc::SIGTERM, libc::SIGKILL] {
        if wait_for_processes_to_exit(&pids, Duration::from_millis(100)) {
            break;
        }
        for pid in &pids {
            signal_test_process_group(*pid, signal);
        }
        if wait_for_processes_to_exit(&pids, Duration::from_secs(2)) {
            break;
        }
    }
    assert!(
        wait_for_processes_to_exit(&pids, Duration::from_secs(2)),
        "fixture could not end its terminal hosts {pids:?}"
    );
    for (record_path, record) in &records {
        let _ = cmux_tui_core::terminal_host_runtime::remove_stale_terminal_host_record(
            record_path,
            record,
        );
    }
}
