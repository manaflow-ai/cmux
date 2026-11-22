//! An app or daemon update replaces the daemon binary while terminals run:
//! the new build must adopt hosts that an earlier build spawned (their
//! processes keep running the old binary), keep their screens and input, and
//! end them on close (docs/cloud-guest-upgrades.md, durable-sessions.md 4).

use super::*;

/// Runs only with `CMUX_TUI_PREVIOUS_BIN` set to a cmux-tui binary from an
/// earlier build (the verify job builds the merge base). Ignored otherwise,
/// so it never passes without exercising two builds.
#[test]
#[ignore = "needs CMUX_TUI_PREVIOUS_BIN, a cmux-tui binary from an earlier build"]
fn hosts_of_a_previous_build_survive_an_upgrade_restart_and_are_adopted() {
    let previous = PathBuf::from(
        std::env::var("CMUX_TUI_PREVIOUS_BIN").expect("CMUX_TUI_PREVIOUS_BIN is required"),
    );
    assert_ne!(
        fs::canonicalize(&previous).unwrap(),
        fs::canonicalize(bin()).unwrap(),
        "the previous build must be a different binary"
    );
    let mut harness = RecoveryHarness::start_unstarted("upgrade-adopt");
    harness.binary = Some(previous);
    harness.restart();
    let old = request(&harness.socket, serde_json::json!({"id": 1, "cmd": "identify"}));

    let marker = format!("before-upgrade-{}", std::process::id());
    let created = request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "run", "argv": ["/bin/cat"], "new_workspace": true}),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    request(
        &harness.socket,
        serde_json::json!({"id": 3, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    let host_pid = wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid;

    // The update stops the old daemon the way supervisors do: SIGTERM.
    let mut daemon = harness.child.take().unwrap();
    // SAFETY: signalling this test's own child process.
    assert_eq!(unsafe { libc::kill(daemon.id() as libc::pid_t, libc::SIGTERM) }, 0);
    daemon.wait().unwrap();
    let _ = fs::remove_file(&harness.socket);
    assert!(process_exists(host_pid as libc::pid_t), "SIGTERM ended the old build's host");

    harness.binary = None;
    harness.restart();
    let new = request(&harness.socket, serde_json::json!({"id": 4, "cmd": "identify"}));
    eprintln!(
        "upgrade: {} -> {}",
        old["build_commit"].as_str().unwrap_or("?"),
        new["build_commit"].as_str().unwrap_or("?")
    );
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let adopted = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id": 5, "cmd": "resolve-terminal", "terminal_id": terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && resolved["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "this build did not adopt the old host: {resolved}");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(wait_for_screen(&harness.socket, adopted, &marker).contains(&marker));
    assert_eq!(wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid, host_pid);

    let after = format!("after-upgrade-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({"id": 6, "cmd": "send", "surface": adopted, "text": format!("{after}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, adopted, &after).contains(&after));
    request(
        &harness.socket,
        serde_json::json!({
            "id": 7,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
}
