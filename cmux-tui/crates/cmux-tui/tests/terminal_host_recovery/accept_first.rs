//! R81 stage A: `new-tab` replies after its durable accept commit, before
//! the host is Ready (plans/cmux-next/new-tab-accept-first.md). The tab is
//! in the tree with lifecycle `launching`; input is queued until the shell
//! runs; a failed launch keeps the tab and its input; a restart reconciles
//! every accepted create.
//!
//! Test hooks (daemon environment, test builds of the protocol only):
//! - `CMUX_TUI_TEST_LAUNCH_JOB_DELAY_MS`: the launch job waits this long
//!   after the accept commit, so the terminal stays `launching`.
//! - `CMUX_TUI_TEST_ACCEPT_COMMIT_DELAY_MS`: the accept waits this long
//!   before its commit (the prelaunched host runs meanwhile).
//! - `CMUX_TUI_TEST_ACTIVATE_DELAY_MS`: the launch job waits this long
//!   between the `running` commit and Activate.
//! - `CMUX_TUI_TEST_ADOPT_HOLD_MS`: the launch job waits this long between
//!   adopting the host and the `running` commit.

use super::super::*;

fn start_with_env(name: &str, env: &[(&str, &str)]) -> RecoveryHarness {
    let mut harness = RecoveryHarness::start_unstarted(name);
    let mut command = harness.daemon_command();
    for (key, value) in env {
        command.env(key, value);
    }
    harness.child = Some(command.spawn().unwrap());
    wait_for_socket(&harness.socket);
    harness
}

/// A workspace with one cat terminal; returns its pane.
fn cat_pane(harness: &RecoveryHarness) -> u64 {
    run_cat_workspace(&harness.socket, 1, "accept-first");
    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    tree["workspaces"][0]["screens"][0]["panes"][0]["id"].as_u64().unwrap()
}

/// A `new-tab` running `/bin/cat` under `/bin/sh`, with a caller-chosen id.
fn new_cat_tab(harness: &RecoveryHarness, id: u64, pane: u64) -> (serde_json::Value, String) {
    let terminal_id = TerminalId::random().unwrap().to_hex();
    let reply = request(
        &harness.socket,
        serde_json::json!({
            "id": id,
            "cmd": "new-tab",
            "pane": pane,
            "terminal_id": terminal_id,
            "env": {"SHELL": "/bin/sh"},
            "shell_args": ["-c", "exec /bin/cat"],
        }),
    );
    (reply, terminal_id)
}

fn daemon_pid(harness: &RecoveryHarness) -> libc::pid_t {
    harness.child.as_ref().unwrap().id() as libc::pid_t
}

/// Host processes the daemon started, by pid.
fn host_children(daemon: libc::pid_t) -> std::collections::BTreeSet<u32> {
    let output = Command::new("pgrep")
        .args(["-P", &daemon.to_string(), "-f", "__terminal-host"])
        .output()
        .expect("run pgrep");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| line.trim().parse().ok())
        .collect()
}

fn record_of(harness: &RecoveryHarness, terminal: &str) -> Option<TerminalHostRecord> {
    load_terminal_host_records(&harness.host_root())
        .unwrap()
        .into_iter()
        .map(|(_, record)| record)
        .find(|record| record.terminal_id == terminal)
}

/// Test 1: the reply comes before host Ready, with lifecycle `launching`.
#[test]
fn new_tab_replies_before_its_host_is_ready() {
    let harness = RecoveryHarness::start_with_host_ready_delay("accept-reply", 3_000);
    let pane = cat_pane(&harness);
    let started = Instant::now();
    let (reply, terminal) = new_cat_tab(&harness, 3, pane);
    let elapsed = started.elapsed();
    assert!(elapsed < Duration::from_millis(1_500), "new-tab waited for host Ready: {elapsed:?}");
    assert_eq!(reply["lifecycle"], "launching", "{reply}");
    assert_eq!(reply["terminal_id"], terminal.as_str());
    assert!(tree_terminal_ids(&harness.socket).contains(&terminal), "tab is in the tree");
    wait_for_terminal_lifecycle(&harness.socket, &terminal, "running");
}

/// Test 2 and R4: input sent while launching is acked `queued` and reaches
/// the shell before later input.
#[test]
fn input_sent_while_launching_reaches_the_shell_first_and_in_order() {
    let harness = start_with_env("accept-queue", &[("CMUX_TUI_TEST_LAUNCH_JOB_DELAY_MS", "1500")]);
    let pane = cat_pane(&harness);
    let (reply, terminal) = new_cat_tab(&harness, 3, pane);
    let surface = reply["surface"].as_u64().unwrap();
    let first = format!("first-{}", std::process::id());
    let queued = request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "send", "surface": surface, "text": format!("{first}\n")}),
    );
    assert_eq!(queued["delivery"], "queued", "{queued}");
    wait_for_terminal_lifecycle(&harness.socket, &terminal, "running");
    request(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "send", "surface": surface, "text": "second-line\n"}),
    );
    let screen = wait_for_screen(&harness.socket, surface, "second-line");
    let first_at = screen.find(&first).expect("queued input reached the shell");
    assert!(first_at < screen.find("second-line").unwrap(), "{screen}");
}

/// Test 3 and R4: a write over the launch budget is refused whole.
#[test]
fn input_over_the_launch_budget_is_refused_whole() {
    let harness = start_with_env("accept-budget", &[("CMUX_TUI_TEST_LAUNCH_JOB_DELAY_MS", "1500")]);
    let pane = cat_pane(&harness);
    let (reply, terminal) = new_cat_tab(&harness, 3, pane);
    let surface = reply["surface"].as_u64().unwrap();
    let large = format!("{}\n", "x".repeat(70 * 1024));
    let refused = request_response(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "send", "surface": surface, "text": large}),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error_code"], "terminal.launch_input_budget", "{refused}");
    request(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "send", "surface": surface, "text": "after-refusal\n"}),
    );
    wait_for_terminal_lifecycle(&harness.socket, &terminal, "running");
    let screen = wait_for_screen(&harness.socket, surface, "after-refusal");
    assert!(!screen.contains(&"x".repeat(64)), "part of the refused write reached the shell");
}

/// Test 4 and R5: a launch that fails after accept keeps the tab, the
/// cause and the queued input; relaunch starts a clean shell with no
/// replay; `send-kept-input` sends the kept bytes once.
#[test]
fn a_launch_that_fails_after_accept_keeps_the_tab_and_its_input() {
    let harness =
        start_with_env("accept-failure", &[("CMUX_TUI_TEST_LAUNCH_JOB_DELAY_MS", "1000")]);
    let pane = cat_pane(&harness);
    let terminal = TerminalId::random().unwrap().to_hex();
    let missing = format!("/tmp/cmux-accept-missing-shell-{}", std::process::id());
    let reply = request(
        &harness.socket,
        serde_json::json!({
            "id": 3, "cmd": "new-tab", "pane": pane, "terminal_id": terminal,
            "env": {"SHELL": missing},
        }),
    );
    assert_eq!(reply["lifecycle"], "launching", "{reply}");
    let surface = reply["surface"].as_u64().unwrap();
    let kept = "echo kept-marker\n";
    let queued = request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "send", "surface": surface, "text": kept}),
    );
    assert_eq!(queued["delivery"], "queued");
    let exited = wait_for_terminal_lifecycle(&harness.socket, &terminal, "exited");
    assert!(exited.to_string().contains("launch-failed"), "exit cause: {exited}");
    assert_eq!(exited["kept_input_bytes"], kept.len(), "{exited}");
    assert!(tree_terminal_ids(&harness.socket).contains(&terminal), "the tab stays");

    let relaunched = request(
        &harness.socket,
        serde_json::json!({
            "id": 5, "cmd": "relaunch-terminal", "terminal_id": terminal,
            "env": {"SHELL": "/bin/sh"}, "shell_args": ["-c", "exec /bin/cat"],
        }),
    );
    assert_ne!(relaunched["terminal_incarnation"], exited["terminal_incarnation"]);
    wait_for_terminal_lifecycle(&harness.socket, &terminal, "running");
    std::thread::sleep(Duration::from_millis(300));
    let clean = request(
        &harness.socket,
        serde_json::json!({"id": 6, "cmd": "read-screen", "surface": surface}),
    );
    assert!(!clean.to_string().contains("kept-marker"), "relaunch replayed kept input");
    request(
        &harness.socket,
        serde_json::json!({"id": 7, "cmd": "send-kept-input", "terminal_id": terminal}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "kept-marker").contains("kept-marker"));
    let again = request_response(
        &harness.socket,
        serde_json::json!({"id": 8, "cmd": "send-kept-input", "terminal_id": terminal}),
    );
    assert_eq!(again["ok"], false, "kept input is sent once: {again}");
}

/// Test 5 and R6: a daemon killed after the reply and before `running`
/// relaunches the tab in place with a new incarnation.
#[test]
fn a_daemon_killed_before_running_relaunches_the_tab_with_a_new_incarnation() {
    let mut harness =
        start_with_env("accept-restart", &[("CMUX_TUI_TEST_LAUNCH_JOB_DELAY_MS", "5000")]);
    let pane = cat_pane(&harness);
    let (reply, terminal) = new_cat_tab(&harness, 3, pane);
    assert_eq!(reply["lifecycle"], "launching");
    assert!(record_of(&harness, &terminal).is_none(), "no host adopted yet");
    harness.sigkill();
    harness.restart();
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal, "running");
    let incarnation = resolved["terminal_incarnation"].as_str().unwrap().to_string();
    let stale = TerminalId::random().unwrap().to_hex();
    let refused = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 4, "cmd": "close-terminal", "terminal_id": terminal,
            "terminal_incarnation": stale,
        }),
    );
    assert_eq!(refused["ok"], false, "an op with a stale incarnation is refused: {refused}");
    let surface = resolved["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "send", "surface": surface, "text": "relaunched\n"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "relaunched").contains("relaunched"));
    assert_eq!(record_of(&harness, &terminal).unwrap().incarnation, incarnation);
}

/// Test 6: closing a launching tab kills its prelaunched host and leaves
/// no `launching` row.
#[test]
fn closing_a_launching_tab_kills_its_host_and_leaves_no_launching_row() {
    let harness = start_with_env("accept-close", &[("CMUX_TUI_TEST_LAUNCH_JOB_DELAY_MS", "2000")]);
    let pane = cat_pane(&harness);
    let before = host_children(daemon_pid(&harness));
    let (reply, terminal) = new_cat_tab(&harness, 3, pane);
    let surface = reply["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "close-surface", "surface": surface}),
    );
    std::thread::sleep(Duration::from_millis(2_500));
    let resolved = request_response(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "resolve-terminal", "terminal_id": terminal}),
    );
    assert_ne!(resolved["data"]["lifecycle"], "launching", "{resolved}");
    assert_ne!(resolved["data"]["lifecycle"], "running", "{resolved}");
    assert!(record_of(&harness, &terminal).is_none(), "the closed tab's host published a record");
    // Only the spare host (R81, no record) may be new.
    let records: std::collections::BTreeSet<u32> = load_terminal_host_records(&harness.host_root())
        .unwrap()
        .into_iter()
        .map(|(_, record)| record.host_pid)
        .collect();
    let new_hosts: Vec<u32> = host_children(daemon_pid(&harness))
        .difference(&before)
        .copied()
        .filter(|pid| records.contains(pid))
        .collect();
    assert!(new_hosts.is_empty(), "hosts left by the closed tab: {new_hosts:?}");
}

/// R1 (test 8): a daemon killed between the prelaunch and the accept
/// commit leaves no host process, record or endpoint after restart.
#[test]
fn a_daemon_killed_before_the_accept_commit_leaves_no_host_behind() {
    let mut harness =
        start_with_env("accept-r1", &[("CMUX_TUI_TEST_ACCEPT_COMMIT_DELAY_MS", "3000")]);
    let pane = cat_pane(&harness);
    let known: std::collections::BTreeSet<String> =
        load_terminal_host_records(&harness.host_root())
            .unwrap()
            .into_iter()
            .map(|(_, record)| record.terminal_id)
            .collect();
    let socket = harness.socket.clone();
    let terminal = TerminalId::random().unwrap().to_hex();
    let request_terminal = terminal.clone();
    let pending = std::thread::spawn(move || {
        request_response(
            &socket,
            serde_json::json!({
                "id": 3, "cmd": "new-tab", "pane": pane, "terminal_id": request_terminal,
                "env": {"SHELL": "/bin/sh"}, "shell_args": ["-c", "exec /bin/cat"],
            }),
        )
    });
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let orphan = loop {
        if let Some(record) = record_of(&harness, &terminal) {
            break record;
        }
        assert!(Instant::now() < deadline, "the prelaunched host never published its record");
        std::thread::sleep(Duration::from_millis(20));
    };
    harness.sigkill();
    let _ = pending.join();
    harness.restart();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while process_exists(orphan.host_pid as libc::pid_t) || record_of(&harness, &terminal).is_some()
    {
        assert!(Instant::now() < deadline, "the unaccepted host or its record survived restart");
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(!Path::new(&orphan.endpoint).exists(), "the unaccepted host's endpoint survived");
    assert!(!tree_terminal_ids(&harness.socket).contains(&terminal));
    for record in load_terminal_host_records(&harness.host_root()).unwrap() {
        assert!(
            known.contains(&record.1.terminal_id),
            "unexpected record {}",
            record.1.terminal_id
        );
    }
}

/// R2 (test 9): a daemon killed between the `running` commit and Activate
/// adopts the host after restart and activates it, so the shell runs.
#[test]
fn a_daemon_killed_before_activate_adopts_and_activates_the_host() {
    let mut harness = start_with_env("accept-r2", &[("CMUX_TUI_TEST_ACTIVATE_DELAY_MS", "5000")]);
    let pane = cat_pane(&harness);
    let (_, terminal) = new_cat_tab(&harness, 3, pane);
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal, "running");
    let host = record_of(&harness, &terminal).expect("the running terminal's record").host_pid;
    harness.sigkill();
    harness.restart();
    let resolved_again = wait_for_terminal_lifecycle(&harness.socket, &terminal, "running");
    assert_eq!(resolved_again["terminal_incarnation"], resolved["terminal_incarnation"]);
    assert_eq!(record_of(&harness, &terminal).unwrap().host_pid, host, "the same host is adopted");
    let surface = resolved_again["surface"].as_u64().unwrap();
    request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "send", "surface": surface, "text": "activated\n"}),
    );
    assert!(wait_for_screen(&harness.socket, surface, "activated").contains("activated"));
}

/// A1 (test 11): a close during adoption leaves no host and no `running`
/// row.
#[test]
fn a_close_during_adoption_leaves_no_host_and_no_running_row() {
    let harness = start_with_env("accept-a1", &[("CMUX_TUI_TEST_ADOPT_HOLD_MS", "2000")]);
    let pane = cat_pane(&harness);
    let (reply, terminal) = new_cat_tab(&harness, 3, pane);
    let surface = reply["surface"].as_u64().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    let host = loop {
        if let Some(record) = record_of(&harness, &terminal) {
            break record.host_pid;
        }
        assert!(Instant::now() < deadline, "the launch job never reached adoption");
        std::thread::sleep(Duration::from_millis(20));
    };
    request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "close-surface", "surface": surface}),
    );
    std::thread::sleep(Duration::from_millis(2_500));
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while process_exists(host as libc::pid_t) {
        assert!(Instant::now() < deadline, "the closed tab's host is still running");
        std::thread::sleep(Duration::from_millis(25));
    }
    let resolved = request_response(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "resolve-terminal", "terminal_id": terminal}),
    );
    assert_ne!(resolved["data"]["lifecycle"], "running", "{resolved}");
}
