//! After a daemon restart, every surviving terminal adopts without waiting
//! for the Kitty image budget. The first adoption to reserve used to take the
//! whole budget (it was alone), so each later one waited for that first
//! adoption to finish and give part of its share back. When the first one was
//! still connecting to its host (a slow handshake or a long replay), the
//! others waited the full reservation timeout (500 ms) and then started with
//! Kitty graphics off: on the fleet, about half the restarts of 6 terminals
//! took 600-800 ms to adopt all of them instead of about 120 ms.
//!
//! A debug seam holds each adoption for HOLD_MS between its Kitty reservation
//! and its host connect. Adoptions that never wait on each other's
//! reservations all finish together; the old wait put the adoptions after
//! the first one 400-600 ms behind it.

use super::*;

const TERMINALS: usize = 4;
const HOLD_MS: u64 = 800;
/// Well below what the 500 ms reservation timeout (mux/kitty_reservation.rs
/// KITTY_RESERVATION_WAIT) put between adoptions (400-600 ms on the fleet),
/// well above the spread of adoptions that do not wait (0.5-84 ms on a
/// loaded fleet host).
const SPREAD_LIMIT: Duration = Duration::from_millis(250);

/// Needs the debug-build seam that holds an adoption after its reservation.
#[cfg(debug_assertions)]
#[test]
fn a_restart_adopts_every_terminal_without_a_kitty_budget_wait() {
    let mut harness = RecoveryHarness::start_unstarted("startup-kitty-wave");
    harness.restart();
    let mut terminals = Vec::new();
    for index in 0..TERMINALS {
        let created = request(
            &harness.socket,
            serde_json::json!({"id": 100 + index, "cmd": "run", "argv": ["/bin/cat"],
                "new_workspace": true, "name": format!("kitty-wave-{index}")}),
        );
        terminals.push(created["terminal_id"].as_str().unwrap().to_string());
    }
    wait_for_host_records(&harness.host_root(), TERMINALS);

    harness.sigkill();
    harness.extra_env = vec![("CMUX_TUI_TEST_ADOPT_CONNECT_DELAY_MS".into(), HOLD_MS.to_string())];
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
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut times = running_at.values().copied().collect::<Vec<_>>();
    times.sort();
    let spread = times[TERMINALS - 1] - times[0];
    eprintln!("startup kitty wave: adopted at {times:?}, spread {spread:?}");
    assert!(
        spread < SPREAD_LIMIT,
        "the last terminal adopted {spread:?} after the first (adopted at {times:?}): \
         a later adoption waited for the first one's Kitty share"
    );
}
