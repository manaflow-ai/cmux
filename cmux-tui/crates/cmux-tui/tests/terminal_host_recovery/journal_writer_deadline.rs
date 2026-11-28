//! A Cloud VM's disk stalled for minutes (registry commits held the workspace
//! registry for up to 197 s). The session journal writer waited for the
//! registry past its 30 s deadline, failed that batch, and then stopped
//! itself for the rest of the daemon's life: the daemon kept answering, but
//! for hours every exited terminal failed to detach ("could not detach exited
//! terminal ...: session journal writer timed out"), every gap marker and
//! every journal append failed, long after the registry was free again.
//!
//! This test holds the journal writer the way the stalled disk did (the
//! `CMUX_TUI_TEST_HOLD_TERMINAL_JOURNAL` hook), lets a terminal exit while it
//! is held so the exit's journal fence times out in the queue, then releases
//! the writer. The writer then reaches that fence after its deadline (the
//! held batch itself commits: the hook runs before its deadline is taken).
//! That expiry used to stop the writer for good. The exit's retry must still
//! commit and the tab detach.

use super::*;

/// The shortest durable wait the daemon accepts (journal_ingress.rs).
const DURABLE_WAIT_MS: u64 = 5_000;

#[test]
fn exited_terminal_detaches_after_a_journal_stall_past_the_deadline() {
    let mut harness = RecoveryHarness::start_unstarted("journal-writer-deadline");
    harness.terminal_journal_hold = Some(harness.hold_fifo("terminal-journal-hold"));
    harness
        .extra_env
        .push(("CMUX_TUI_JOURNAL_DURABLE_WAIT_MS".into(), DURABLE_WAIT_MS.to_string()));
    harness.restart();

    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/sh","-i"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let workspace_id = created["workspace"].as_u64().unwrap();

    // A geometry change is a terminal-lane journal record: the writer takes
    // it and waits on the hold, as a writer behind a stalled disk does.
    attach_claim_and_resize_surface(&harness.socket, surface, 100, 30, 2);
    let receipts_before = request(
        &harness.socket,
        serde_json::json!({"id":9,"cmd":"server-stats"}),
    )["journal_writer"]["receipt_wait_us"]["count"]
        .as_u64()
        .unwrap_or(0);
    request(
        &harness.socket,
        serde_json::json!({"id":10,"cmd":"send-key","surface":surface,"keys":["ctrl+d"]}),
    );

    // The exit fences the terminal journal before it commits. With the writer
    // held, that fence waits out its whole deadline.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
    loop {
        let stats = request(&harness.socket, serde_json::json!({"id":11,"cmd":"server-stats"}));
        let receipts = &stats["journal_writer"]["receipt_wait_us"];
        let waited = receipts["max"].as_u64().unwrap_or(0);
        let count = receipts["count"].as_u64().unwrap_or(0);
        if count > receipts_before && waited >= (DURABLE_WAIT_MS - 100) * 1_000 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the exit's journal fence never timed out behind the held writer: {stats}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(
        request(
            &harness.socket,
            serde_json::json!({"id":12,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        )["lifecycle"],
        "running",
        "the exit must not commit while its journal fence failed"
    );

    // The stall ends. The exit retries and must commit now.
    harness.release_terminal_journal();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(30));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":13,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "exited" {
            assert_eq!(resolved["surface"], serde_json::Value::Null);
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the exited terminal never detached after the journal writer stall ended: {resolved}"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let tree = request(&harness.socket, serde_json::json!({"id":14,"cmd":"list-workspaces"}));
    let workspace = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["id"].as_u64() == Some(workspace_id))
        .expect("the exit removed the workspace identity");
    assert!(first_tab(workspace).is_none(), "the exited terminal's tab stayed behind");
}
