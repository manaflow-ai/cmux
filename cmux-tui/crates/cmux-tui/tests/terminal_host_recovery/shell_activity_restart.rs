//! cx-6so.59: the shell facts of `terminal-activity-v1` survive a daemon
//! restart. The terminal host keeps the OSC 133 state and hands it to the
//! adopting daemon, so a shell at its prompt still reads `extra.prompt`
//! (what `cmux terminal wait --until prompt|idle` waits on) and a running
//! command still reads as running, with the times they began.

use super::*;

/// `extra` of the harness's only terminal record.
fn terminal_extra(harness: &RecoveryHarness) -> serde_json::Value {
    let terminals = resource_request(
        &harness.socket,
        "shell-activity-list",
        "terminal.list",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    let terminals = terminals.as_array().unwrap();
    assert_eq!(terminals.len(), 1, "expected one terminal: {terminals:?}");
    terminals[0]["extra"].clone()
}

/// Waits until `ready` holds for the terminal's `extra`.
fn wait_for_extra(
    harness: &RecoveryHarness,
    what: &str,
    ready: impl Fn(&serde_json::Value) -> bool,
) -> serde_json::Value {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let extra = terminal_extra(harness);
        if ready(&extra) {
            return extra;
        }
        assert!(Instant::now() < deadline, "never {what}: {extra}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn ms(value: &serde_json::Value) -> u64 {
    value.as_u64().or_else(|| value.as_str()?.parse().ok()).expect("a Unix ms value")
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64
}

/// Starts `script` (sh), waits for `marker`, then SIGKILLs the daemon and
/// waits until a replacement adopted the same terminal host. Returns the
/// Unix ms just before the kill.
fn run_then_restart(
    harness: &mut RecoveryHarness,
    name: &str,
    script: &str,
    marker: &str,
    before: impl Fn(&serde_json::Value) -> bool,
) -> (serde_json::Value, u64, String, String) {
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", script],
            "new_workspace": true,
            "name": name,
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, surface, marker).contains(marker));
    let extra = wait_for_extra(harness, "the state before the restart", before);
    wait_for_host_records(&harness.host_root(), 1);

    let killed_at = now_ms();
    harness.sigkill();
    harness.restart();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": &terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && resolved["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && resolved["surface"].as_u64().is_some()
        {
            break;
        }
        assert!(Instant::now() < deadline, "replacement daemon did not adopt the terminal");
        std::thread::sleep(Duration::from_millis(50));
    }
    (extra, killed_at, terminal_id, incarnation)
}

fn close(harness: &RecoveryHarness, terminal_id: String, incarnation: String) {
    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
}

/// The fact's `since_ms` after the restart is from before the kill: carried
/// from the host, not stamped again by the new daemon.
fn assert_kept_since(after: &serde_json::Value, killed_at: u64, what: &str) {
    let since = ms(after);
    assert!(since <= killed_at, "{what} began again at the restart ({since} > {killed_at})");
}

#[test]
fn reattach_keeps_shell_prompt_across_a_daemon_restart() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("shell-activity-prompt");
    let (before, killed_at, terminal_id, incarnation) = run_then_restart(
        &mut harness,
        "shell-activity-prompt",
        "printf '\\033]133;A\\007prompt\\r\\n'; sleep 600",
        "prompt",
        |extra| extra["prompt"]["since_ms"].is_string(),
    );
    assert!(before.get("activity").is_none(), "{before}");

    let after = wait_for_extra(&harness, "a prompt after the restart", |extra| {
        extra["prompt"]["since_ms"].is_string()
    });
    assert!(after.get("activity").is_none(), "a prompt is no command: {after}");
    assert_kept_since(&after["prompt"]["since_ms"], killed_at, "the prompt");
    // The new daemon did not see the input written since that prompt: the
    // shell is not idle until its next prompt.
    assert!(after.get("shell_idle").is_none(), "input since the prompt is unknown: {after}");
    close(&harness, terminal_id, incarnation);
}

#[test]
fn reattach_keeps_running_command_across_a_daemon_restart() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("shell-activity-running");
    let (_, killed_at, terminal_id, incarnation) = run_then_restart(
        &mut harness,
        "shell-activity-running",
        "printf '\\033]133;A\\007\\033]133;C\\007started\\r\\n'; sleep 600",
        "started",
        |extra| extra["activity"]["state"] == "running",
    );

    let after = wait_for_extra(&harness, "a running command after the restart", |extra| {
        extra["activity"]["state"] == "running"
    });
    assert!(after.get("prompt").is_none(), "a running command is no prompt: {after}");
    assert!(after["busy"]["since_ms"].is_string(), "a plain command keeps busy: {after}");
    assert_kept_since(&after["activity"]["since_ms"], killed_at, "the command");
    close(&harness, terminal_id, incarnation);
}

#[test]
fn reattach_keeps_in_use_command_across_a_daemon_restart() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("shell-activity-in-use");
    let (_, killed_at, terminal_id, incarnation) = run_then_restart(
        &mut harness,
        "shell-activity-in-use",
        // A command that takes the alternate screen, like htop.
        "printf '\\033]133;C\\007started\\r\\n\\033[?1049hfullscreen'; sleep 600",
        "fullscreen",
        |extra| extra["activity"]["state"] == "in_use",
    );

    let after = wait_for_extra(&harness, "an in-use command after the restart", |extra| {
        extra["activity"]["state"] == "in_use"
    });
    assert!(after.get("busy").is_none(), "an in-use command is not busy: {after}");
    assert_kept_since(&after["activity"]["since_ms"], killed_at, "the command");
    close(&harness, terminal_id, incarnation);
}
