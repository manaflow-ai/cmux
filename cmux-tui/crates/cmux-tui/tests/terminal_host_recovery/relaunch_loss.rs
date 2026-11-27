//! The Mac app's update relaunch: the app finds the daemon of the previous build, premigrates
//! the registry beside it with the bundled binary, and hands off (`shutdown-daemon` with the
//! owner's pid and generation, no `end_terminals`); the next daemon adopts the hosts
//! (DaemonVersionHandoff.swift, `mux/terminal_adoption.rs`). No live terminal may end.
//!
//! Reproduction attempt for the 2026-11-24 05:34Z loss (20 terminal agents ended with status
//! 143 at a `cmux app quit --keep-sessions` update).

use super::*;

const TERMINALS: usize = 36;

fn lifecycles(harness: &RecoveryHarness, terminals: &[String]) -> Vec<String> {
    terminals
        .iter()
        .map(|terminal_id| {
            request_response(
                &harness.socket,
                serde_json::json!({"id": 1, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
            )["data"]["lifecycle"]
                .as_str()
                .unwrap_or("unresolved")
                .to_string()
        })
        .collect()
}

/// The handoff of `handOffIfStale`: premigrate beside the running owner, fenced shutdown,
/// wait for the exit, start the next owner on the same state.
fn hand_off(harness: &mut RecoveryHarness) {
    let mut premigrate = Command::new(bin());
    premigrate.env_remove("CMUX_BUNDLE_ID").env_remove("CMUX_TAG").args([
        "--session",
        &harness.session,
        "--json",
        "server",
        "premigrate-registry",
    ]);
    let premigrated =
        private_state::use_private_state(&mut premigrate, &harness.dir).output().unwrap();
    eprintln!(
        "relaunch-loss: premigrate exit {:?}: {}",
        premigrated.status.code(),
        String::from_utf8_lossy(&premigrated.stdout).trim()
    );
    let identify = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "identify"}));
    let accepted = request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "shutdown-daemon",
            "pid": identify["pid"],
            "generation": identify["generation"],
        }),
    );
    assert_eq!(accepted["accepted"], true, "{accepted}");
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "the owner did not exit after the handoff");
        std::thread::sleep(Duration::from_millis(10));
    }
    let _ = fs::remove_file(&harness.socket);
    harness.restart();
}

/// 36 live terminals in tabs, one of them attached by a frontend, across the update handoff:
/// every host keeps running under the next owner, twice in a row.
#[test]
fn relaunch_loss_update_handoff_adopts_every_live_terminal_host() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_with_args(
        "relaunch-loss-handoff",
        &["--terminal-reap-grace-seconds", "30"],
    );
    let terminals: Vec<String> = (0..TERMINALS)
        .map(|index| run_cat_workspace(&harness.socket, 10 + index, &format!("agent-{index}")).0)
        .collect();
    let before: std::collections::BTreeMap<String, u32> =
        wait_for_host_records(&harness.host_root(), TERMINALS)
            .into_iter()
            .map(|(_, record)| (record.terminal_id, record.host_pid))
            .collect();
    assert_eq!(before.len(), TERMINALS);

    for round in 1..=2 {
        hand_off(&mut harness);
        // Adoption settles: every terminal reads running or ended.
        let deadline = Instant::now() + test_timeout(Duration::from_secs(60));
        let states = loop {
            let states = lifecycles(&harness, &terminals);
            let settled = states
                .iter()
                .all(|state| matches!(state.as_str(), "running" | "exited" | "tombstoned"));
            if settled || Instant::now() >= deadline {
                break states;
            }
            std::thread::sleep(Duration::from_millis(100));
        };
        // Past the adoption threads' cleanup of records this start did not adopt (the
        // terminate is SIGHUP, 2 s, SIGTERM).
        std::thread::sleep(Duration::from_secs(5));
        let states_later = lifecycles(&harness, &terminals);
        let alive: Vec<&String> = before
            .iter()
            .filter(|(_, pid)| process_running(**pid as libc::pid_t))
            .map(|(terminal_id, _)| terminal_id)
            .collect();
        let same_host = load_terminal_host_records(&harness.host_root())
            .unwrap()
            .into_iter()
            .filter(|(_, record)| before.get(&record.terminal_id) == Some(&record.host_pid))
            .count();
        let running = states_later.iter().filter(|state| *state == "running").count();
        let mut counts = std::collections::BTreeMap::<&str, usize>::new();
        for state in &states_later {
            *counts.entry(state.as_str()).or_default() += 1;
        }
        eprintln!(
            "relaunch-loss: handoff round={round} terminals={TERMINALS} running={running} \
             hosts_alive={} same_host_records={same_host} lifecycles={counts:?} first_settled={:?}",
            alive.len(),
            states.iter().filter(|state| *state == "running").count(),
        );
        assert_eq!(
            (running, alive.len(), same_host),
            (TERMINALS, TERMINALS, TERMINALS),
            "handoff {round} lost terminals: {running} of {TERMINALS} running, {} hosts alive, \
             {same_host} records of the original hosts; lifecycles {counts:?}",
            alive.len(),
        );
    }
}
