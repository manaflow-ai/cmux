//! A daemon handoff (an update, a crash restart) adopts its terminal hosts
//! at once, not one after another (perf100 tui lane, bead cx-p00l3.1). The
//! new daemon answers only after the startup adoption pass, and each host's
//! handshake (connect, then replay its snapshot) used to run in turn: 113
//! terminals kept every terminal blank for 8 to 20 s after an update. The
//! handshakes now run at once and commit in record order.
//!
//! A debug seam makes every handshake take HANDSHAKE_MS, so the serial pass
//! would take TERMINALS x HANDSHAKE_MS. The test measures from the new
//! daemon's spawn to its socket answering, checks every terminal is running
//! with its screen and its input intact, and that nothing was reordered.

use super::*;

const TERMINALS: usize = 16;
const HANDSHAKE_MS: u64 = 400;
/// Serial adoption would take TERMINALS x HANDSHAKE_MS = 6.4 s.
const MAX_HANDOFF: Duration = Duration::from_millis(3_000);

#[test]
fn daemon_handoff_adopts_terminal_hosts_in_parallel_with_screens_and_input_intact() {
    let mut harness = RecoveryHarness::start_unstarted("parallel-handoff");
    harness.extra_env.push(("CMUX_TUI_TEST_ADOPT_HANDSHAKE_DELAY_MS".into(), "0".into()));
    harness.restart();
    let mut terminals = Vec::new();
    for index in 0..TERMINALS {
        let created = request(
            &harness.socket,
            serde_json::json!({
                "id": 100 + index,
                "cmd": "run",
                "argv": ["/bin/cat"],
                "new_workspace": true,
                "name": format!("handoff-{index}"),
            }),
        );
        let surface = created["surface"].as_u64().unwrap();
        let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
        let marker = format!("before-handoff-{index}-{}", std::process::id());
        request(
            &harness.socket,
            serde_json::json!({"id": 200 + index, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
        );
        terminals.push((terminal_id, marker, surface));
    }
    for (_, marker, surface) in &terminals {
        assert!(wait_for_screen(&harness.socket, *surface, marker).contains(marker.as_str()));
    }
    let hosts = wait_for_host_records(&harness.host_root(), TERMINALS);

    harness.sigkill();
    harness.extra_env = vec![(
        "CMUX_TUI_TEST_ADOPT_HANDSHAKE_DELAY_MS".into(),
        HANDSHAKE_MS.to_string(),
    )];
    let started = Instant::now();
    harness.restart();
    // Until its answer: the socket may accept before the daemon serves.
    request(&harness.socket, serde_json::json!({"id": 299, "cmd": "identify"}));
    let handoff = started.elapsed();
    eprintln!(
        "handoff: {TERMINALS} terminals with {HANDSHAKE_MS} ms handshakes answered in {:.2} s \
         (serial: {:.1} s)",
        handoff.as_secs_f64(),
        (TERMINALS as u64 * HANDSHAKE_MS) as f64 / 1000.0
    );

    // Every terminal is running on its own host, with its screen.
    for (index, (terminal_id, marker, _)) in terminals.iter().enumerate() {
        let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
        let surface = loop {
            let resolved = request(
                &harness.socket,
                serde_json::json!({"id": 300 + index, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
            );
            if resolved["lifecycle"] == "running"
                && let Some(surface) = resolved["surface"].as_u64()
            {
                break surface;
            }
            assert!(Instant::now() < deadline, "terminal {terminal_id} not adopted: {resolved}");
            std::thread::sleep(Duration::from_millis(25));
        };
        assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker.as_str()));
        // Input after the handoff lands after the old screen, in order.
        let after = format!("after-handoff-{index}-{}", std::process::id());
        request(
            &harness.socket,
            serde_json::json!({"id": 400 + index, "cmd": "send", "surface": surface, "text": format!("{after}\n")}),
        );
        let screen = wait_for_screen(&harness.socket, surface, &after);
        let before_at = screen.find(marker.as_str()).expect("old screen kept");
        let after_at = screen.find(&after).expect("new input shown");
        assert!(before_at < after_at, "output reordered on {terminal_id}: {screen}");
    }
    let adopted = wait_for_host_records(&harness.host_root(), TERMINALS);
    let mut before_pids: Vec<u32> = hosts.iter().map(|(_, record)| record.host_pid).collect();
    let mut after_pids: Vec<u32> = adopted.iter().map(|(_, record)| record.host_pid).collect();
    before_pids.sort_unstable();
    after_pids.sort_unstable();
    assert_eq!(before_pids, after_pids, "the handoff replaced terminal hosts");
    assert!(
        handoff <= test_timeout(MAX_HANDOFF),
        "the handoff took {:.2} s for {TERMINALS} terminals (budget {:.1} s; serial is {:.1} s)",
        handoff.as_secs_f64(),
        MAX_HANDOFF.as_secs_f64(),
        (TERMINALS as u64 * HANDSHAKE_MS) as f64 / 1000.0
    );
}
