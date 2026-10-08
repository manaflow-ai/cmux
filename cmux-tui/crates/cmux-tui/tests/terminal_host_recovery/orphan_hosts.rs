//! cx-0tgl LC: a starting owner never ends a live terminal host it cannot
//! place. A host whose registry row is gone (a lost or reset registry) is
//! recovered into a workspace of its own. Only a terminal the user closed
//! (tombstoned) or one that already exited has its leftover host ended.

use super::*;

/// A `/bin/cat` terminal with one echoed line: (terminal id, host record).
fn start_cat(
    harness: &RecoveryHarness,
    name: &str,
    marker: &str,
) -> (String, PathBuf, TerminalHostRecord) {
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":name}),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let surface = created["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker));
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    (terminal_id, record_path, record)
}

/// Stop the owner with SIGTERM (hosts stay for the next owner).
fn stop_owner(harness: &mut RecoveryHarness) {
    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);
}

fn registry_path(state: &Path) -> PathBuf {
    walk_files(state)
        .into_iter()
        .find(|path| path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3"))
        .expect("workspace registry")
}

/// The running terminal `terminal_id` resolves to, once adopted.
fn wait_for_running(harness: &RecoveryHarness, terminal_id: &str) -> (serde_json::Value, u64) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            return (resolved, surface);
        }
        assert!(Instant::now() < deadline, "terminal was not adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn assert_same_live_host(
    harness: &RecoveryHarness,
    record_path: &Path,
    record: &TerminalHostRecord,
) {
    assert_eq!(
        terminal_host_record_liveness(record_path, record).unwrap(),
        TerminalHostLiveness::Live,
        "the owner ended a live terminal host it could not place"
    );
    let records = wait_for_host_records(&harness.host_root(), 1);
    assert_eq!(records[0].1.host_pid, record.host_pid, "the terminal got a new host");
}

#[test]
fn a_live_host_of_a_lost_registry_is_recovered_not_terminated() {
    let mut harness = RecoveryHarness::start("orphan-lost-registry");
    let (terminal_id, record_path, record) = start_cat(&harness, "lost", "before-registry-loss");
    stop_owner(&mut harness);
    let registry = registry_path(&harness.state);
    for suffix in ["", "-wal", "-shm"] {
        let _ = fs::remove_file(format!("{}{suffix}", registry.display()));
    }
    harness.restart();

    let (_, surface) = wait_for_running(&harness, &terminal_id);
    assert_same_live_host(&harness, &record_path, &record);
    assert!(
        wait_for_screen(&harness.socket, surface, "before-registry-loss")
            .contains("before-registry-loss"),
        "the recovered terminal lost its screen"
    );
    request(
        &harness.socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":"after-recovery\n"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "after-recovery").contains("after-recovery"));
    let tree = request(&harness.socket, serde_json::json!({"id":3,"cmd":"list-workspaces"}));
    assert!(
        tree["workspaces"]
            .as_array()
            .unwrap()
            .iter()
            .any(|workspace| workspace["name"] == "Recovered terminals"),
        "no recovery workspace: {tree}"
    );
}
