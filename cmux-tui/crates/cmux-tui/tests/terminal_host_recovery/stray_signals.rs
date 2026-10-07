//! cx-6so.49 L0: a terminal host ends only by its owner's Terminate or its
//! child's exit. A stray TERM, HUP, INT or QUIT is recorded and survived; a
//! host loss is logged with those records; a TERM to the owner daemon leaves
//! every host for the next owner; and a host whose shell exited never lives
//! on forever because a descendant keeps its PTY open.

use super::*;

const STRAY_SIGNALS: [libc::c_int; 4] = [libc::SIGTERM, libc::SIGHUP, libc::SIGINT, libc::SIGQUIT];

/// A `run` of `/bin/cat` in a new workspace: (terminal id, incarnation, surface).
fn run_cat(socket: &Path, id: u64, name: &str) -> (String, String, u64) {
    let created = request(
        socket,
        serde_json::json!({"id":id,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,"name":name}),
    );
    (
        created["terminal_id"].as_str().unwrap().to_string(),
        created["terminal_incarnation"].as_str().unwrap().to_string(),
        created["surface"].as_u64().unwrap(),
    )
}

fn signal_pid(pid: u32, signal: libc::c_int) {
    // SAFETY: the PID is a terminal host this test started (its discovery
    // record's locked nonce proves it live); the signal is a constant.
    assert_eq!(unsafe { libc::kill(pid as libc::pid_t, signal) }, 0);
}

/// The JSON lines of a host's signal breadcrumbs, once there are `count`.
fn wait_for_signal_lines(record_path: &Path, count: usize) -> Vec<serde_json::Value> {
    let path = record_path.with_extension("signals");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    loop {
        let lines = fs::read_to_string(&path)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .collect::<Vec<_>>();
        if lines.len() >= count {
            return lines;
        }
        assert!(Instant::now() < deadline, "host recorded {} of {count} signals", lines.len());
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn echo_round_trip(socket: &Path, surface: u64, marker: &str) {
    request(
        socket,
        serde_json::json!({"cmd":"send","surface":surface,"text":format!("{marker}\n")}),
    );
    let screen = wait_for_screen(socket, surface, marker);
    assert!(screen.contains(marker), "terminal did not echo {marker}: {screen}");
}

#[test]
fn stray_signals_to_a_terminal_host_are_recorded_and_survived() {
    let harness = RecoveryHarness::start("stray-host-signals");
    let (terminal_id, incarnation, surface) = run_cat(&harness.socket, 1, "stray");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    for signal in STRAY_SIGNALS {
        signal_pid(record.host_pid, signal);
    }
    let lines = wait_for_signal_lines(&record_path, STRAY_SIGNALS.len());
    // The kernel delivers pending signals in its own order.
    let mut recorded =
        lines.iter().map(|line| line["signal"].as_i64().unwrap()).collect::<Vec<_>>();
    recorded.sort_unstable();
    let mut sent = STRAY_SIGNALS.map(i64::from).to_vec();
    sent.sort_unstable();
    assert_eq!(recorded, sent, "{lines:?}");
    for line in &lines {
        assert_eq!(line["sender_pid"], std::process::id(), "{line}");
        assert_eq!(line["terminal_id"], terminal_id.as_str(), "{line}");
        assert_eq!(line["incarnation"], incarnation.as_str(), "{line}");
        assert_eq!(line["action"], "ignored", "{line}");
    }
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live
    );
    echo_round_trip(&harness.socket, surface, "after-stray-signals");
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");
}

#[test]
fn host_loss_is_logged_with_the_signals_its_host_recorded() {
    let harness = RecoveryHarness::start("host-loss-log");
    let (terminal_id, _, _) = run_cat(&harness.socket, 1, "lost");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    signal_pid(record.host_pid, libc::SIGTERM);
    wait_for_signal_lines(&record_path, 1);
    signal_pid(record.host_pid, libc::SIGKILL);
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");

    let log = harness.host_root().parent().unwrap().join("terminal-losses.jsonl");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    let line = loop {
        let found = fs::read_to_string(&log)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .find(|line| line["terminal_id"] == terminal_id.as_str());
        if let Some(line) = found {
            break line;
        }
        assert!(Instant::now() < deadline, "no loss line for {terminal_id} in {log:?}");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(line["end"]["kind"], "host_lost", "{line}");
    assert_eq!(line["signals"][0]["signal"], libc::SIGTERM, "{line}");
    assert_eq!(line["signals"][0]["sender_pid"], std::process::id(), "{line}");
    assert!(!record_path.with_extension("signals").exists(), "breadcrumbs outlived the loss");
}

/// hq-ed's cleanup sweeps send TERM to owner daemons only. A daemon stop by
/// TERM must leave every host running for the next owner, never end it.
#[test]
fn owner_sigterm_leaves_terminal_hosts_for_readoption() {
    let mut harness = RecoveryHarness::start("owner-sigterm-readopt");
    let (terminal_id, incarnation, first_surface) = run_cat(&harness.socket, 1, "survivor");
    echo_round_trip(&harness.socket, first_surface, "before-owner-term");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    harness.signal_daemon(libc::SIGTERM);
    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live,
        "an owner TERM ended its terminal host"
    );
    let _ = fs::remove_file(&harness.socket);
    harness.restart();

    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let (resolved, surface) = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break (resolved, surface);
        }
        assert!(Instant::now() < deadline, "terminal was not re-adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    };
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");
    assert!(
        wait_for_screen(&harness.socket, surface, "before-owner-term")
            .contains("before-owner-term")
    );
    echo_round_trip(&harness.socket, surface, "after-owner-term");
    let records = wait_for_host_records(&harness.host_root(), 1);
    assert_eq!(records[0].1.host_pid, record.host_pid, "the terminal got a new host");
}

/// A shell that exited while a descendant (which ignores the hangup) still
/// holds the PTY: with no owner attached, the host must still write the exit
/// record and end within the bounded drain.
#[test]
fn exited_shell_with_a_descendant_holding_the_pty_ends_its_host_without_an_owner() {
    let mut harness = RecoveryHarness::start_unstarted("exited-drain-orphan");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_HOST_EXITED_DRAIN_LIMIT_MS", "300");
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);

    request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","new_workspace":true,"name":"orphan",
            "argv":["/bin/sh","-c","trap '' HUP; sleep 25 & echo started; sleep 0.5"],
        }),
    );
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    // No owner from here on.
    harness.sigkill();

    let deadline = Instant::now() + test_timeout(Duration::from_secs(8));
    while terminal_host_record_liveness(&record_path, &record).ok()
        != Some(TerminalHostLiveness::Dead)
    {
        assert!(
            Instant::now() < deadline,
            "a host whose shell exited outlived its bounded drain with no owner"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    let exits = load_terminal_host_exit_records(&harness.host_root()).unwrap();
    assert_eq!(exits.len(), 1, "the orphaned host ended without its exit record");
    assert_eq!(exits[0].1.terminal_id, record.terminal_id);
}
