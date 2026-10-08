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
