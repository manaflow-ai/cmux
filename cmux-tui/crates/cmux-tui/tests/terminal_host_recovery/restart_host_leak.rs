//! P0 TERMINAL-HOST LEAK (feat-cmux-next #29476; restore fuzz row h,
//! 2026-10-31): a closed workspace's terminals live until the reap grace
//! ends, and each daemon start counted that grace again from zero, so under
//! restarts faster than the grace none was ever reaped and the closed
//! terminals' hosts held the machine's PTYs. The rule: closed terminals end
//! within the grace counted from their close, whatever the restarts, the
//! placed terminal keeps running, and a new terminal opens.

use super::*;

/// Hosts with a discovery record, by pid, with their terminal ids.
fn recorded_hosts(harness: &RecoveryHarness) -> std::collections::BTreeMap<u32, String> {
    load_terminal_host_records(&harness.host_root())
        .unwrap()
        .into_iter()
        .map(|(_, record)| (record.host_pid, record.terminal_id))
        .collect()
}

/// Creates a `/bin/cat` terminal in a new workspace; returns its host id.
fn run_cat_workspace(socket: &Path, id: u64, name: &str) -> String {
    let created = request(
        socket,
        serde_json::json!({
            "id": id,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "name": name,
        }),
    );
    created["terminal_id"].as_str().expect("run omitted terminal id").to_string()
}

/// The leak: a plain workspace close keeps its terminals until the reap
/// grace ends, and each daemon start used to count that grace again from
/// zero. With restarts faster than the grace (a crash loop) no closed
/// terminal was ever reaped, and their PTYs ran out. The grace runs across
/// restarts: closed terminals end, the placed one keeps running, and a new
/// terminal opens.
#[test]
fn terminal_reap_survives_daemon_restarts_faster_than_the_grace() {
    let mut harness = RecoveryHarness::start_with_args(
        "restart-reap-grace",
        &["--terminal-reap-grace-seconds", "4"],
    );
    let placed = run_cat_workspace(&harness.socket, 1, "placed");
    let closed: Vec<String> = (0..3)
        .map(|index| run_cat_workspace(&harness.socket, 10 + index, &format!("closed-{index}")))
        .collect();
    wait_for_host_records(&harness.host_root(), 4);
    let tree = request(&harness.socket, serde_json::json!({"id": 20, "cmd": "list-workspaces"}));
    for workspace in tree["workspaces"].as_array().unwrap() {
        if workspace["name"].as_str().is_some_and(|name| name.starts_with("closed-")) {
            request(
                &harness.socket,
                serde_json::json!({"id": 21, "cmd": "close-workspace", "key": workspace["key"]}),
            );
        }
    }
    // Every daemon lives 2 s, half the grace, for 16 s: four graces.
    for _ in 0..8 {
        std::thread::sleep(Duration::from_secs(2));
        harness.sigkill();
        harness.restart();
    }
    // Checked within a quarter of the grace after the last start: a grace
    // counted from that start is not over yet.
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let recorded: std::collections::BTreeSet<String> =
            recorded_hosts(&harness).into_values().collect();
        let left: Vec<&String> = closed.iter().filter(|id| recorded.contains(*id)).collect();
        if left.is_empty() {
            assert!(recorded.contains(&placed), "the placed terminal was reaped: {recorded:?}");
            break;
        }
        assert!(
            Instant::now() < deadline,
            "{} of 3 terminals closed 16 s ago (reap grace 4 s, 8 daemon restarts) still \
             hold a host and a PTY: {left:?}",
            left.len()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let identify = request(&harness.socket, serde_json::json!({"id": 30, "cmd": "identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "terminal-reaper-active-v1"),
        "an owner started with --terminal-reap-grace-seconds does not advertise its reaper: \
         {identify}"
    );
    let after = run_cat_workspace(&harness.socket, 900, "after-restarts");
    assert!(!after.is_empty(), "a new terminal opens");
}

/// The socket answers `identify` from its bind, while the owner still starts
/// (`lifecycle_ready` false): an owner started with the reap option lists
/// `terminal-reaper-active-v1` in that first answer. A change that starts or
/// announces the reaper only after the bind fails here. It needs the
/// debug-only `CMUX_TUI_TEST_STARTUP_DELAY_AFTER_BIND_MS` hook.
#[test]
#[cfg_attr(not(debug_assertions), ignore = "needs a debug-only startup hook")]
fn terminal_reap_identify_during_owner_startup_lists_the_reaper() {
    let mut harness = RecoveryHarness::start_unstarted("reaper-identify-startup");
    harness.extra_args =
        ["--terminal-reap-grace-seconds", "30"].iter().map(|arg| (*arg).to_string()).collect();
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_STARTUP_DELAY_AFTER_BIND_MS", "3000");
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    let identify = request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));
    assert_eq!(
        identify["lifecycle_ready"], false,
        "identify was not answered during the owner's startup: {identify}"
    );
    assert!(
        identify["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == "terminal-reaper-active-v1"),
        "an owner started with --terminal-reap-grace-seconds answered identify during its \
         startup without terminal-reaper-active-v1: {identify}"
    );
}
