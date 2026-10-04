//! R81: the one host process started ahead of the next new tab. The second
//! `new-tab` of a session adopts it (its terminal's host is that process),
//! each tab sees only its own environment, and a spare killed before
//! adoption leaves the next tab launching as before, with no error.

use super::super::*;
use super::wait_for_process_and_group_absent;

/// Host processes the daemon started (`__terminal-host`), by pid.
fn daemon_host_pids(daemon: libc::pid_t) -> std::collections::BTreeSet<u32> {
    let output = std::process::Command::new("pgrep")
        .args(["-P", &daemon.to_string(), "-f", "__terminal-host"])
        .output()
        .expect("run pgrep");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse().ok())
        .collect()
}

fn record_pids(harness: &RecoveryHarness) -> std::collections::BTreeSet<u32> {
    load_terminal_host_records(&harness.host_root())
        .unwrap()
        .into_iter()
        .map(|(_, record)| record.host_pid)
        .collect()
}

/// The spare: a daemon host process with no published record yet.
fn wait_for_spare(harness: &RecoveryHarness, daemon: libc::pid_t) -> u32 {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let published = record_pids(harness);
        if let Some(spare) =
            daemon_host_pids(daemon).into_iter().find(|pid| !published.contains(pid))
        {
            return spare;
        }
        assert!(
            Instant::now() < deadline,
            "no spare host process appeared after the first new tab"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn new_tab(harness: &RecoveryHarness, id: u64, pane: u64, value: &str) -> (u64, String) {
    let reply = request(
        &harness.socket,
        serde_json::json!({
            "id": id,
            "cmd": "new-tab",
            "pane": pane,
            "env": {"CMUX_R81": value},
            "shell_args": ["/bin/sh", "-c", "printf 'R81=[%s]\\n' \"$CMUX_R81\"; exec /bin/cat"],
        }),
    );
    let surface = reply["surface"].as_u64().unwrap_or_else(|| panic!("new-tab failed: {reply}"));
    let terminal = reply["terminal_id"].as_str().unwrap().to_string();
    (surface, terminal)
}

fn host_pid_of(harness: &RecoveryHarness, terminal: &str) -> u32 {
    load_terminal_host_records(&harness.host_root())
        .unwrap()
        .into_iter()
        .find(|(_, record)| record.terminal_id == terminal)
        .map(|(_, record)| record.host_pid)
        .expect("the new tab's host record")
}

#[test]
fn the_second_new_tab_adopts_the_spare_host_with_its_own_environment() {
    let harness = RecoveryHarness::start("standby-host-adopt");
    let daemon = harness.child.as_ref().unwrap().id() as libc::pid_t;
    run_cat_workspace(&harness.socket, 1, "standby");
    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    let pane = tree["workspaces"][0]["screens"][0]["panes"][0]["id"].as_u64().unwrap();

    let (first, _) = new_tab(&harness, 3, pane, "first");
    assert!(wait_for_screen(&harness.socket, first, "R81=[first]").contains("R81=[first]"));
    let spare = wait_for_spare(&harness, daemon);

    let (second, terminal) = new_tab(&harness, 4, pane, "second");
    let screen = wait_for_screen(&harness.socket, second, "R81=[second]");
    assert!(screen.contains("R81=[second]"), "{screen}");
    assert!(
        !screen.contains("first"),
        "the spare must not carry a previous tab's environment: {screen}"
    );
    assert_eq!(
        host_pid_of(&harness, &terminal),
        spare,
        "the second tab's host is the spare process"
    );
}

#[test]
fn a_spare_killed_before_adoption_leaves_the_next_tab_launching_as_before() {
    let harness = RecoveryHarness::start("standby-host-killed");
    let daemon = harness.child.as_ref().unwrap().id() as libc::pid_t;
    run_cat_workspace(&harness.socket, 1, "standby");
    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    let pane = tree["workspaces"][0]["screens"][0]["panes"][0]["id"].as_u64().unwrap();

    let (first, _) = new_tab(&harness, 3, pane, "first");
    assert!(wait_for_screen(&harness.socket, first, "R81=[first]").contains("R81=[first]"));
    let spare = wait_for_spare(&harness, daemon);
    // SAFETY: SIGKILL to the spare host process this daemon started.
    unsafe { libc::kill(spare as libc::pid_t, libc::SIGKILL) };
    wait_for_process_and_group_absent(spare as libc::pid_t);

    let (second, terminal) = new_tab(&harness, 4, pane, "second");
    let screen = wait_for_screen(&harness.socket, second, "R81=[second]");
    assert!(screen.contains("R81=[second]"), "{screen}");
    assert_ne!(host_pid_of(&harness, &terminal), spare);
}
