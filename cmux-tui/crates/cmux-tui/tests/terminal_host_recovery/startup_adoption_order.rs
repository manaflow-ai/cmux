//! After a daemon restart, the terminals of the workspace the user sees adopt
//! first, and at most a few first attempts run at once (perf100 tui lane,
//! cx-p00l3.1). Every surviving host used to adopt at once when the owner
//! said ready: 100 threads took the registry and state locks one after
//! another, and the app's first requests waited behind all of them (0.96 s
//! of a 1.41 s start for 100 terminals).
//!
//! A debug seam holds each first attempt for HOLD_MS inside its turn, so
//! adoptions finish in waves of the gate's slots. The test selects a
//! workspace in the middle, restarts the daemon, and records the order in
//! which terminals become running: the selected workspace's terminal is in
//! the first wave, and no wave is larger than the gate allows.

use super::*;

const TERMINALS: usize = 24;
/// Gate slots (mux/startup_adoption_gate.rs STARTUP_ADOPTION_SLOTS).
const SLOTS: usize = 8;
const HOLD_MS: u64 = 1_000;

/// Needs the debug-build seam that holds a first attempt.
#[cfg(debug_assertions)]
#[test]
fn a_restart_adopts_the_visible_workspace_first_in_bounded_waves() {
    let mut harness = RecoveryHarness::start_unstarted("startup-adoption-order");
    harness.restart();
    let mut terminals = Vec::new();
    for index in 0..TERMINALS {
        let created = request(
            &harness.socket,
            serde_json::json!({"id": 100 + index, "cmd": "run", "argv": ["/bin/cat"],
                "new_workspace": true, "name": format!("order-{index}")}),
        );
        terminals.push(created["terminal_id"].as_str().unwrap().to_string());
    }
    wait_for_host_records(&harness.host_root(), TERMINALS);
    // The user looks at a workspace in the middle (not the last one made).
    let visible_index = TERMINALS / 2;
    request(
        &harness.socket,
        serde_json::json!({"id": 300, "cmd": "select-workspace", "index": visible_index}),
    );
    let tree = request(&harness.socket, serde_json::json!({"id": 301, "cmd": "list-workspaces"}));
    let visible_name = tree["workspaces"][visible_index]["name"].as_str().unwrap().to_string();
    let visible = &terminals[visible_name.trim_start_matches("order-").parse::<usize>().unwrap()];

    harness.sigkill();
    harness.extra_env = vec![("CMUX_TUI_TEST_ADOPT_TURN_DELAY_MS".into(), HOLD_MS.to_string())];
    harness.restart();

    // Poll each terminal's lifecycle; note when it first reads running.
    let started = Instant::now();
    let deadline = started + test_timeout(Duration::from_secs(60));
    let mut running_at: std::collections::HashMap<String, Duration> = Default::default();
    while running_at.len() < TERMINALS {
        assert!(Instant::now() < deadline, "only {} terminals adopted", running_at.len());
        for (index, terminal) in terminals.iter().enumerate() {
            if running_at.contains_key(terminal) {
                continue;
            }
            let resolved = request(
                &harness.socket,
                serde_json::json!({"id": 400 + index, "cmd": "resolve-terminal", "terminal_id": terminal}),
            );
            if resolved["lifecycle"] == "running" && resolved["surface"].is_u64() {
                running_at.insert(terminal.clone(), started.elapsed());
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut order: Vec<(Duration, &String)> =
        running_at.iter().map(|(terminal, at)| (*at, terminal)).collect();
    order.sort();
    let first_done = order[0].0;
    // A wave is every terminal that became running within half a hold of the
    // first one (the next wave comes a full hold later).
    let first_wave: Vec<&String> = order
        .iter()
        .filter(|(at, _)| *at < first_done + Duration::from_millis(HOLD_MS / 2))
        .map(|(_, terminal)| *terminal)
        .collect();
    eprintln!(
        "startup adoption: first wave {} terminals at {:?}, last at {:?}",
        first_wave.len(),
        first_done,
        order.last().unwrap().0
    );
    assert!(
        first_wave.contains(&visible),
        "the visible workspace's terminal was not in the first wave ({} of {TERMINALS})",
        first_wave.len()
    );
    assert!(
        first_wave.len() <= SLOTS,
        "{} terminals adopted at once; the gate allows {SLOTS}",
        first_wave.len()
    );
}
