//! A terminal closed right after an owner restart, with the owner stopped at
//! once after the close, must not leave its host running. Dogfood repro on
//! feat d2e95d56: a terminal flooded output, went idle, the owner stopped and
//! started again, and `terminal close` (rc 0) plus `server stop` within about
//! 2 s of the start left the idle host alive with its shell. Its sample shows
//! only the accept loop: the host never got Terminate. The fix must end the
//! host in the same owner life, not at the next start.

use cmux_tui_core::terminal_host_runtime::wait_for_terminal_host_exit;

use super::*;

#[test]
fn a_closed_terminal_host_ends_when_the_close_comes_right_after_a_restart() {
    let mut harness = RecoveryHarness::start("close-after-restart");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                "i=0; while [ $i -lt 50000 ]; do echo flood $i; i=$((i+1)); done; \
                 echo FLOOD-DONE; exec cat",
            ],
            "new_workspace": true,
            "name": "close-after-restart",
        }),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let surface = created["surface"].as_u64().unwrap();
    let screen = wait_for_screen(&harness.socket, surface, "FLOOD-DONE");
    assert!(screen.contains("FLOOD-DONE"), "the flood did not end: {screen}");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    // The host holds its live marker's lease for its whole life, so taking
    // the lease is its exit event.
    let (exited, host_exit) = mpsc::channel();
    {
        let record = record.clone();
        std::thread::spawn(move || {
            let result = wait_for_terminal_host_exit(&record_path, &record);
            let _ = exited.send(result.map_err(|error| format!("{error:#}")));
        });
    }

    // An orderly owner stop keeps the host. The next owner holds its
    // adoption open (debug seam), so the close and the stop below both come
    // while the terminal still adopts, as in the repro.
    harness.terminate();
    harness.extra_env.push(("CMUX_TUI_TEST_ADOPTION_DELAY_MS".into(), "3000".into()));
    harness.restart();
    let closed = request(
        &harness.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "close-terminal",
            "terminal_id": &terminal_id,
            "terminal_incarnation": &incarnation,
        }),
    );
    assert_eq!(closed["terminal_id"].as_str(), Some(terminal_id.as_str()), "{closed}");
    harness.terminate();

    let ended = host_exit.recv_timeout(test_timeout(Duration::from_secs(30)));
    assert!(
        matches!(ended, Ok(Ok(()))),
        "the host of a terminal closed right after a restart outlived its owner: {ended:?} \
         (host pid {})",
        record.host_pid
    );
}
