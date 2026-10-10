//! cx-7e7b: the manual restart of a dead terminal tab (`restart-tab`,
//! `tab-restart-v1`, plans/cmux-next/ownership.md section 3.2). It reuses
//! the L2 respawn worker: the same terminal id gets a new shell and a new
//! incarnation, also after the respawn supervisor gave up
//! (`restart_exhausted`), and after a process end the tab kept (`on_exit` keep), also
//! from the CLI (`cmux tab <id> restart`). A tab whose terminal still runs
//! is a typed reject.

use super::*;

fn restart_tab(harness: &RecoveryHarness, tab: serde_json::Value) -> serde_json::Value {
    request_response(&harness.socket, serde_json::json!({"id":1,"cmd":"restart-tab","surface":tab}))
}

/// a. The supervisor used every attempt (two here) and the tab reads dead
/// with `restart_exhausted`; Restart brings the same terminal back with a
/// new shell, and the supervisor starts over: the next loss respawns again.
#[test]
fn a_manual_restart_brings_back_a_terminal_the_supervisor_gave_up_on() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("restart-after-exhausted");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_RESPAWN_BACKOFF_MS", "0,0");
    harness.child = Some(command.spawn().expect("spawn the daemon"));
    wait_for_socket(&harness.socket);
    let (terminal_id, mut incarnation, _) = start_default_shell(&harness, "bound");
    for _ in 0..2 {
        kill_current_shell_and_host(&harness, &terminal_id);
        incarnation = wait_for_respawn(&harness, &terminal_id, &incarnation);
        let surface = tab_named(&harness, "bound")["surface"].as_u64().expect("surface");
        wait_for_screen(&harness.socket, surface, MARKER);
    }
    let surface = tab_named(&harness, "bound")["surface"].as_u64().expect("surface");
    let old_pid = echo_value(&harness, surface, "first", "$$");
    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let dead = loop {
        let tab = tab_named(&harness, "bound");
        if tab["end"]["reason"] == "restart_exhausted" {
            break tab;
        }
        assert!(Instant::now() < deadline, "the supervisor never gave up: {tab}");
        std::thread::sleep(Duration::from_millis(25));
    };
    assert_eq!(dead["dead"], true, "{dead}");

    let restarted = restart_tab(&harness, dead["tab_resource_id"].clone());
    assert_eq!(restarted["ok"], true, "{restarted}");
    assert_eq!(restarted["data"]["terminal"], dead["terminal_resource_id"], "{restarted}");
    let manual = wait_for_respawn(&harness, &terminal_id, &incarnation);

    let tab = tab_named(&harness, "bound");
    assert_eq!(tab["dead"], false, "{tab}");
    assert_eq!(tab["terminal_id"], terminal_id.as_str(), "the restart made a new terminal");
    assert_eq!(tab["tab_resource_id"], dead["tab_resource_id"], "the restart made a new tab");
    let surface = tab["surface"].as_u64().expect("the restarted tab has a surface");
    wait_for_screen(&harness.socket, surface, MARKER);
    assert_ne!(echo_value(&harness, surface, "second", "$$"), old_pid, "the same shell answered");
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 3);
    assert_eq!(lines.len(), 3, "{lines:?}");
    assert_eq!(lines[2]["cause"], "user_restart");
    assert_eq!(lines[2]["new_incarnation"], manual.as_str());

    // The restart reset the supervisor: the next loss respawns at once.
    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_respawn(&harness, &terminal_id, &manual);
    assert_eq!(tab_named(&harness, "bound")["dead"], false);
}

/// b. A process end under `on_exit` keep leaves the tab dead with its
/// final screen; Restart starts a shell under the same terminal id.
#[test]
fn a_manual_restart_brings_back_a_kept_process_exit() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("restart-kept-exit");
    let workspace = &create_empty_workspace(&harness.socket, "restart-kept", "Restart kept");
    let run = resource_request(
        &harness.socket,
        "restart-kept-run",
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
            "argv":["/bin/sh","-c","printf 'kept-exit-marker\\n'; exit 9"],
            "on_exit":"keep",
        }),
        Some("restart-kept-run"),
    );
    let public_terminal = run["value"]["terminal_id"].as_str().expect("terminal").to_string();
    let tab = run["value"]["tab_id"].as_str().expect("tab").to_string();
    let terminal_id = tab_named(&harness, "Restart kept")["terminal_id"]
        .as_str()
        .expect("the run tab names its terminal")
        .to_string();
    let exited = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let incarnation = exited["terminal_incarnation"].as_str().unwrap_or_default().to_string();
    let dead = tab_named(&harness, "Restart kept");
    assert_eq!(dead["dead"], true, "{dead}");

    // Through the CLI: `cmux tab <tab_…> restart` sends the same command.
    let restarted = Command::new(bin())
        .args(["--json", "--session", &harness.session, "tab", &tab, "restart", "--socket"])
        .arg(&harness.socket)
        .output()
        .expect("run the CLI");
    let stdout = String::from_utf8_lossy(&restarted.stdout);
    assert!(
        restarted.status.success(),
        "tab restart failed: {stdout} {}",
        String::from_utf8_lossy(&restarted.stderr)
    );
    assert!(stdout.contains(&public_terminal), "the CLI did not name the terminal: {stdout}");
    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "Restart kept");
    assert_eq!(tab["dead"], false, "{tab}");
    assert_eq!(tab["terminal_resource_id"], public_terminal.as_str(), "{tab}");
    let surface = tab["surface"].as_u64().expect("the restarted tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, "kept-exit-marker");
    assert!(text.contains("kept-exit-marker"), "the final screen is gone: {text}");
    echo_value(&harness, surface, "alive", "$$");
}

/// c. A tab whose terminal runs is a typed reject and keeps its shell.
#[test]
fn a_restart_of_a_running_tab_is_a_typed_reject() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("restart-live");
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "live");
    let refused = restart_tab(&harness, serde_json::json!(surface));
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error_code"], "tab-not-dead", "{refused}");
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    assert_eq!(resolved["terminal_incarnation"], incarnation.as_str(), "{resolved}");
    assert!(respawn_lines(&harness, &terminal_id).is_empty());
}
