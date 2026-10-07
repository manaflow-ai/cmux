//! cx-6so.49 L2: a placed terminal whose shell is gone with its host (a
//! SIGKILL of both, a host that died while no daemon ran) gets a new shell
//! under the same terminal id and a new incarnation. Its tab never reads
//! dead, the new shell starts below the previous screen and one dim marker
//! line, an agent session it ran is offered for resume on the prompt
//! (typed, never run), and a real process end, a close, or a terminal that
//! keeps losing its host stays ended.

use std::io::Write as _;

use super::pty_custody::{kill_shell_then_host, send_line};
use super::*;

const MARKER: &str = "session restored (previous process ended)";

/// A terminal running the user's default shell, with shell integration, in
/// a new workspace named `name`: (internal terminal id, incarnation,
/// surface).
fn start_default_shell(harness: &RecoveryHarness, name: &str) -> (String, String, u64) {
    let created =
        request(&harness.socket, serde_json::json!({"id":1,"cmd":"new-workspace","name":name}));
    let surface = created["surface"].as_u64().expect("new-workspace returned no surface");
    let tab = tab_named(harness, name);
    let terminal_id = tab["terminal_id"].as_str().expect("tab has no terminal id").to_string();
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default().to_string();
    (terminal_id, incarnation, surface)
}

fn tab_named(harness: &RecoveryHarness, name: &str) -> serde_json::Value {
    let tree = request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == name)
        .and_then(first_tab)
        .cloned()
        .unwrap_or_else(|| panic!("workspace {name} has no tab: {tree}"))
}

fn screen(harness: &RecoveryHarness, surface: u64) -> String {
    request(&harness.socket, serde_json::json!({"cmd":"read-screen","surface":surface}))["text"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

/// The number the shell prints after `<tag>-` for `echo <tag>-<expr>`.
fn echo_value(harness: &RecoveryHarness, surface: u64, tag: &str, expr: &str) -> String {
    send_line(&harness.socket, surface, &format!("echo {tag}-{expr}-end"));
    let needle = format!("{tag}-");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let text = screen(harness, surface);
        // The echoed command line shows the expression; the output does not.
        let value = text.match_indices(&needle).find_map(|(at, _)| {
            let rest = &text[at + needle.len()..];
            let value = rest.split("-end").next()?;
            (!value.contains(expr) && !value.is_empty()).then(|| value.to_string())
        });
        if let Some(value) = value {
            return value;
        }
        assert!(Instant::now() < deadline, "the shell printed no {needle}: {text}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Wait until `terminal_id` runs an incarnation other than `old`.
fn wait_for_respawn(harness: &RecoveryHarness, terminal_id: &str, old: &str) -> String {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default();
        if resolved["lifecycle"] == "running" && !incarnation.is_empty() && incarnation != old {
            return incarnation.to_string();
        }
        assert!(Instant::now() < deadline, "{terminal_id} was not respawned: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn respawn_lines(harness: &RecoveryHarness, terminal_id: &str) -> Vec<serde_json::Value> {
    let log = harness.host_root().parent().map(|dir| dir.join("terminal-losses.jsonl"));
    log.and_then(|log| fs::read_to_string(log).ok())
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter(|line| line["terminal_id"] == terminal_id && line["event"] == "terminal_respawned")
        .collect()
}

fn kill_current_shell_and_host(harness: &RecoveryHarness, terminal_id: &str) {
    let (record_path, record) = load_terminal_host_records(&harness.host_root())
        .unwrap_or_default()
        .into_iter()
        .find(|(_, record)| record.terminal_id == terminal_id)
        .expect("the terminal has no host record");
    kill_shell_then_host(&record_path, &record);
}

/// a. Shell and host SIGKILLed under a running daemon: the same terminal
/// runs a new shell in the old directory, below the old screen and the
/// marker, and its tab is never removed.
#[test]
fn a_killed_shell_and_host_respawn_the_terminal_in_place() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("respawn-live");
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "live");
    // Short, so `echo` of it never wraps on an 80-column screen.
    let cwd = PathBuf::from(format!("/tmp/cmux-rsp-{}", std::process::id()));
    fs::create_dir_all(&cwd).expect("create the shell's directory");
    let cwd = fs::canonicalize(&cwd).expect("canonical directory");
    let cwd_text = cwd.to_string_lossy().into_owned();
    send_line(&harness.socket, surface, &format!("cd '{cwd_text}'"));
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while tab_named(&harness, "live")["cwd"].as_str() != Some(cwd_text.as_str()) {
        assert!(Instant::now() < deadline, "the shell never reported {cwd_text}");
        std::thread::sleep(Duration::from_millis(50));
    }
    send_line(&harness.socket, surface, "echo before-respawn-marker");
    wait_for_screen(&harness.socket, surface, "before-respawn-marker\n");
    let old_pid = echo_value(&harness, surface, "first", "$$");

    kill_current_shell_and_host(&harness, &terminal_id);
    let new_incarnation = wait_for_respawn(&harness, &terminal_id, &incarnation);

    let tab = tab_named(&harness, "live");
    assert_eq!(tab["dead"], false, "{tab}");
    let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, MARKER);
    assert!(text.contains("before-respawn-marker"), "the old screen is gone: {text}");
    let new_pid = echo_value(&harness, surface, "second", "$$");
    assert_ne!(new_pid, old_pid, "the same shell answered");
    assert_eq!(echo_value(&harness, surface, "dir", "$PWD"), cwd_text);
    let lines = respawn_lines(&harness, &terminal_id);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["old_incarnation"], incarnation.as_str());
    assert_eq!(lines[0]["new_incarnation"], new_incarnation.as_str());
    assert_eq!(lines[0]["cause"], "died_without_exit_status");
    assert_eq!(lines[0]["prefilled"], "none");
    let _ = fs::remove_dir_all(&cwd);
}

/// b. The host dies while no daemon runs (a reboot): the next daemon
/// respawns the terminal with the screen of its last checkpoint.
#[test]
fn a_host_that_died_without_a_daemon_is_respawned_at_the_next_start() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("respawn-restart");
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "reboot");
    send_line(&harness.socket, surface, "echo checkpoint-marker");
    wait_for_screen(&harness.socket, surface, "checkpoint-marker\n");
    let checkpoint = request_response(
        &harness.socket,
        serde_json::json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":"respawn-checkpoint",
            "operation":"session.journal.checkpoint.create",
            "idempotency_key":"respawn-checkpoint",
            "params":{"machine":"current","session":"current"},
        }),
    );
    assert_eq!(checkpoint["ok"], true, "{checkpoint}");
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    harness.sigkill();
    // SAFETY: the record PID is the harness-owned terminal host.
    assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    harness.restart();

    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "reboot");
    assert_eq!(tab["dead"], false, "{tab}");
    let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, MARKER);
    assert!(text.contains("checkpoint-marker"), "the checkpoint screen is gone: {text}");
    let lines = respawn_lines(&harness, &terminal_id);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["cause"], "dead_before_adoption");
}

/// c. An agent session the terminal ran is typed on the new prompt for the
/// user to resume; it does not run.
#[test]
fn a_respawned_terminal_offers_its_agent_session_for_resume_without_running_it() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("respawn-agent");
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "agent");
    let public_id = tab_named(&harness, "agent")["terminal_resource_id"]
        .as_str()
        .expect("tab has no public terminal id")
        .to_string();
    let mut hook = Command::new(bin())
        .args(["__agent-hook", "claude", "SessionStart"])
        .env("CMUX_TUI_SOCKET", &harness.socket)
        .env("CMUX_TUI_TERMINAL_ID", &public_id)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn the agent hook");
    hook.stdin
        .take()
        .expect("hook stdin")
        .write_all(b"{\"session_id\":\"abc-123\"}\n")
        .expect("write the hook payload");
    assert!(hook.wait().expect("wait for the hook").success());
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let agents = request(&harness.socket, serde_json::json!({"cmd":"list-agents"}));
        let claimed =
            agents["agents"].as_array().into_iter().flatten().any(|agent| {
                agent["surface"].as_u64() == Some(surface) && agent["agent"] == "claude"
            });
        if claimed {
            break;
        }
        assert!(Instant::now() < deadline, "the hook never reached the terminal: {agents}");
        std::thread::sleep(Duration::from_millis(50));
    }

    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let surface = tab_named(&harness, "agent")["surface"].as_u64().expect("surface");
    // The screen after the marker, unwrapped (an 80-column prompt wraps).
    let after_marker = |text: &str| {
        text.rsplit_once(MARKER).map(|(_, tail)| tail.replace('\n', "")).unwrap_or_default()
    };
    let command = "claude --resume abc-123";
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while !after_marker(&screen(&harness, surface)).contains(command) {
        assert!(Instant::now() < deadline, "no resume offer: {}", screen(&harness, surface));
        std::thread::sleep(Duration::from_millis(50));
    }
    std::thread::sleep(Duration::from_secs(1));
    let text = screen(&harness, surface);
    assert!(!text.contains("not found"), "the resume command ran: {text}");
    assert!(after_marker(&text).trim_end().ends_with(command), "not on the prompt line: {text}");
    let lines = respawn_lines(&harness, &terminal_id);
    assert_eq!(lines.first().map(|line| line["prefilled"].clone()), Some("harness".into()));
}

/// d. A real process end is never respawned: the terminal stays exited
/// with its code and its tab goes as before.
#[test]
fn a_shell_that_exits_is_not_respawned() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("respawn-exit");
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/sh"],"new_workspace":true,"name":"exit"}),
    );
    let terminal_id = created["terminal_id"].as_str().expect("terminal id").to_string();
    let surface = created["surface"].as_u64().expect("surface");
    send_line(&harness.socket, surface, "exit 3");
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    assert_eq!(resolved["exit"]["outcome"], serde_json::json!({"kind":"exit","code":3}));
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let tree = request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}));
        let left = tree["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|workspace| workspace["name"] == "exit")
            .and_then(first_tab)
            .is_some();
        if !left {
            break;
        }
        assert!(Instant::now() < deadline, "the exited terminal kept its tab: {tree}");
        std::thread::sleep(Duration::from_millis(50));
    }
    std::thread::sleep(Duration::from_secs(1));
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    assert_eq!(resolved["exit"]["outcome"]["code"], 3, "{resolved}");
    assert!(respawn_lines(&harness, &terminal_id).is_empty());
}

/// e. The crash-loop bound: a terminal that loses its host again right after
/// a respawn stays ended.
#[test]
fn a_terminal_that_keeps_losing_its_host_stays_ended() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("respawn-loop");
    let (terminal_id, incarnation, _) = start_default_shell(&harness, "loop");
    kill_current_shell_and_host(&harness, &terminal_id);
    let respawned = wait_for_respawn(&harness, &terminal_id, &incarnation);
    // Let the new shell come up, then lose it again inside the bound.
    let surface = tab_named(&harness, "loop")["surface"].as_u64().expect("surface");
    wait_for_screen(&harness.socket, surface, MARKER);
    kill_current_shell_and_host(&harness, &terminal_id);
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    assert_eq!(resolved["terminal_incarnation"], respawned.as_str(), "{resolved}");
    std::thread::sleep(Duration::from_secs(2));
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    assert_eq!(resolved["terminal_incarnation"], respawned.as_str(), "{resolved}");
    assert_eq!(tab_named(&harness, "loop")["dead"], true);
    assert_eq!(respawn_lines(&harness, &terminal_id).len(), 1);
}

/// f. A close that lands after the host died and before the respawn starts
/// wins: the terminal is never respawned.
#[test]
fn a_close_after_a_host_loss_is_never_respawned() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("respawn-close");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_RESPAWN_DELAY_MS", "2000");
    harness.child = Some(command.spawn().expect("spawn the daemon"));
    wait_for_socket(&harness.socket);
    let (terminal_id, incarnation, _) = start_default_shell(&harness, "close");
    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let closed = request_response(
        &harness.socket,
        serde_json::json!({
            "cmd":"close-terminal","terminal_id":terminal_id,
            "terminal_incarnation":incarnation,
        }),
    );
    assert_eq!(closed["ok"], true, "{closed}");
    std::thread::sleep(Duration::from_secs(3));
    assert!(respawn_lines(&harness, &terminal_id).is_empty(), "a closed terminal respawned");
    let resolved = request_response(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    assert_ne!(resolved["data"]["lifecycle"], "running", "{resolved}");
    wait_for_no_host_records(&harness.host_root());
}
