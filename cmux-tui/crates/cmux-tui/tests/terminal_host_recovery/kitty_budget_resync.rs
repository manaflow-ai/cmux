//! A Kitty image quota change that evicts nothing must not reopen the host
//! stream (nx-scale step 1b). The daemon divides one process image budget by
//! a power-of-two capacity of terminals. When the terminal count passed 2^k,
//! every existing host got smaller limits and answered with ResyncRequired,
//! so the daemon reconnected all N hosts at each doubling (1,024 hosts at
//! once at the 1,025th terminal). A reconnect leaves a `terminal.output.gap`
//! record with reason `host_reconnect` in the terminal's lane.

use super::reconnect_checkpoints::gap_reasons;
use super::*;

fn run_cat(socket: &Path, id: u64) -> u64 {
    let run = request(
        socket,
        serde_json::json!({
            "id":id,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"cols":80,"rows":24,
        }),
    );
    run["surface"].as_u64().unwrap()
}

fn terminal_ids(socket: &Path) -> std::collections::HashSet<String> {
    let terminals = resource_request(
        socket,
        "kitty-budget-terminals",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    terminals
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|terminal| terminal["id"].as_str().map(str::to_string))
        .collect()
}

fn reconnects_of(socket: &Path, terminals: &std::collections::HashSet<String>) -> usize {
    gap_reasons(socket)
        .iter()
        .filter(|(terminal, reason)| reason == "host_reconnect" && terminals.contains(terminal))
        .count()
}

#[test]
fn kitty_budget_doubling_does_not_reconnect_existing_hosts() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("kitty-doubling");
    let mut surfaces = vec![run_cat(&harness.socket, 1), run_cat(&harness.socket, 2)];
    wait_for_host_records(&harness.host_root(), 2);
    // Let both launches apply their first quota.
    std::thread::sleep(Duration::from_secs(3));
    let existing = terminal_ids(&harness.socket);
    assert_eq!(existing.len(), 2);
    let before = reconnects_of(&harness.socket, &existing);

    // A third quota owner: capacity 2 -> 4, so both existing hosts get half
    // their limits. Neither holds an image, so nothing is evicted.
    surfaces.push(run_cat(&harness.socket, 3));
    wait_for_host_records(&harness.host_root(), 3);
    std::thread::sleep(Duration::from_secs(3));

    let reconnects = reconnects_of(&harness.socket, &existing) - before;
    assert_eq!(
        reconnects, 0,
        "a Kitty quota change that evicts nothing must not reconnect the existing hosts"
    );

    for (index, surface) in surfaces.into_iter().enumerate() {
        close_terminal_surface(&harness.socket, surface, 10 + index as u64);
    }
    wait_for_no_host_records(&harness.host_root());
}

/// Hosts launched by `first`, adopted by `second`, then a quota change from
/// `second` (a third terminal doubles the capacity). The limits payload on
/// ResyncRequired must not break an older peer: an older daemon reconnects
/// on it, an older host never sends it. Both terminals keep working.
fn kitty_budget_change_across_builds(name: &str, first: Option<PathBuf>, second: Option<PathBuf>) {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted(name);
    harness.binary = first;
    harness.restart();
    let mut terminals = Vec::new();
    for index in 0..2_u64 {
        let created = request(
            &harness.socket,
            serde_json::json!({"id": 1 + index, "cmd": "run", "argv": ["/bin/cat"], "new_workspace": true}),
        );
        terminals.push((
            created["terminal_id"].as_str().unwrap().to_string(),
            created["terminal_incarnation"].as_str().unwrap().to_string(),
        ));
    }
    wait_for_host_records(&harness.host_root(), 2);

    let mut daemon = harness.child.take().unwrap();
    // SAFETY: signalling this test's own child process.
    assert_eq!(unsafe { libc::kill(daemon.id() as libc::pid_t, libc::SIGTERM) }, 0);
    daemon.wait().unwrap();
    let _ = fs::remove_file(&harness.socket);
    harness.binary = second;
    harness.restart();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let mut adopted = Vec::new();
    for (index, (terminal_id, incarnation)) in terminals.iter().enumerate() {
        adopted.push(loop {
            let resolved = request(
                &harness.socket,
                serde_json::json!({"id": 10 + index, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
            );
            if resolved["lifecycle"] == "running"
                && resolved["terminal_incarnation"].as_str() == Some(incarnation.as_str())
                && let Some(surface) = resolved["surface"].as_u64()
            {
                break surface;
            }
            assert!(Instant::now() < deadline, "the second build did not adopt: {resolved}");
            std::thread::sleep(Duration::from_millis(50));
        });
    }
    let third = run_cat(&harness.socket, 20);
    wait_for_host_records(&harness.host_root(), 3);
    std::thread::sleep(Duration::from_secs(3));

    for (index, surface) in adopted.iter().enumerate() {
        let marker = format!("after-quota-{index}-{}", std::process::id());
        request(
            &harness.socket,
            serde_json::json!({"id": 30 + index, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
        );
        assert!(wait_for_screen(&harness.socket, *surface, &marker).contains(&marker));
    }
    for (index, surface) in adopted.into_iter().chain([third]).enumerate() {
        close_terminal_surface(&harness.socket, surface, 40 + index as u64);
    }
    wait_for_no_host_records(&harness.host_root());
}

fn previous_build() -> PathBuf {
    PathBuf::from(
        std::env::var("CMUX_TUI_PREVIOUS_BIN").expect("CMUX_TUI_PREVIOUS_BIN is required"),
    )
}

#[test]
#[ignore = "needs CMUX_TUI_PREVIOUS_BIN, a cmux-tui binary from an earlier build"]
fn a_new_daemon_changes_the_kitty_quota_of_older_hosts() {
    kitty_budget_change_across_builds("kitty-new-daemon-old-hosts", Some(previous_build()), None);
}

#[test]
#[ignore = "needs CMUX_TUI_PREVIOUS_BIN, a cmux-tui binary from an earlier build"]
fn an_older_daemon_changes_the_kitty_quota_of_newer_hosts() {
    kitty_budget_change_across_builds("kitty-old-daemon-new-hosts", None, Some(previous_build()));
}
