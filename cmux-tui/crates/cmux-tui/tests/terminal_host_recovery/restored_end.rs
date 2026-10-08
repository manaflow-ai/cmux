//! cx-ayt2: a terminal whose host was lost keeps its typed end across an
//! owner restart (R41). Before the fix the restored dead tab had `end: null`
//! and `content_resource_id: null`, so the app banner fell back to "Process
//! exited" instead of "Terminal lost" with its cause.

use super::pty_custody::kill_shell_then_host;
use super::*;

fn sender_tab(harness: &RecoveryHarness) -> serde_json::Value {
    let tree = request(&harness.socket, serde_json::json!({"id":2,"cmd":"list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["name"] == "lost")
        .and_then(first_tab)
        .unwrap_or_else(|| panic!("the dead tab is gone: {tree}"))
}

#[test]
fn a_lost_host_keeps_its_typed_end_after_an_owner_restart() {
    let mut harness = RecoveryHarness::start_without_respawn("restored-end");
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":"lost"}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    kill_shell_then_host(&record_path, &record);
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let before = sender_tab(&harness);
    assert_eq!(before["end"]["kind"], "host_lost", "before the restart: {before}");
    let content = before["content_resource_id"].clone();
    assert!(content.is_string(), "{before}");

    // SIGTERM the owner (a clean stop), then start it again.
    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "the owner did not stop on SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);
    harness.restart();

    let after = sender_tab(&harness);
    assert_eq!(after["dead"], true, "{after}");
    assert_eq!(after["content_resource_id"], content, "the tab keeps its content id: {after}");
    assert_eq!(after["end"]["kind"], "host_lost", "the tab keeps its typed end: {after}");
}
