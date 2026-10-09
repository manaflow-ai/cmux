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
        .cloned()
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
    // A child of this test sends the host SIGTERM first, so the loss has a
    // recorded cause (the sender) to keep across the restart.
    let mut sender = Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("kill -TERM {}; sleep 30; :", record.host_pid))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let signals = record_path.with_extension("signals");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    while !fs::read_to_string(&signals).unwrap_or_default().contains("\"signal\"") {
        assert!(Instant::now() < deadline, "the host recorded no signal");
        std::thread::sleep(Duration::from_millis(20));
    }
    kill_shell_then_host(&record_path, &record);
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let _ = sender.kill();
    let _ = sender.wait();
    let before = sender_tab(&harness);
    assert_eq!(before["end"]["kind"], "host_lost", "before the restart: {before}");
    let content = before["content_resource_id"].clone();
    let cause = before["end"]["cause"].clone();
    assert!(cause.is_object(), "the loss names its cause before the restart: {before}");
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
    assert_eq!(after["end"]["cause"], cause, "the restored end keeps the loss cause: {after}");
}
