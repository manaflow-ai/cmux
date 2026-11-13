//! `cmux terminal <t> wait --until idle|prompt [--timeout D]` through a real
//! daemon (cx-6so.14, plans/cmux-next/status-indicators.md section 5): the
//! wait blocks on the session's event stream until the terminal's shell
//! facts hold, returns the terminal record, and fails a timeout with exit
//! code 124.
//!
//! The shells run without shell integration, so the only OSC 133 marks are
//! the ones each test prints.
use super::super::*;

/// A command starts (OSC 133 C).
const COMMAND_START: &str = r"\033]133;C\007";
/// The command ends (D).
const COMMAND_END: &str = r"\033]133;D;0\007";
/// The command ends (D) and the shell draws its prompt (A).
const COMMAND_END_AND_PROMPT: &str = r"\033]133;D;0\007\033]133;A\007";
const SECONDS_10: Duration = Duration::from_secs(10);

fn new_terminal(server: &HeadlessServer) -> String {
    let created = json_cli(server, &["tab", "create", "terminal"]);
    assert_success(&created);
    json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_string()
}

fn write(server: &HeadlessServer, terminal: &str, text: &str) {
    assert_success(&json_cli(server, &["terminal", terminal, "write", "--text", text]));
}

fn record(server: &HeadlessServer, terminal: &str) -> serde_json::Value {
    let shown = json_cli(server, &["terminal", terminal, "show"]);
    assert_success(&shown);
    json_output(&shown)
}

/// Starts a command that runs until a line arrives: marks C, reads a line,
/// then prints `after`. Returns once the daemon shows the command running.
fn start_waiting_command(server: &HeadlessServer, terminal: &str, after: &str) {
    write(server, terminal, &format!("printf '{COMMAND_START}'; read line; printf '{after}'\n"));
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let shown = record(server, terminal);
        if shown["extra"]["activity"]["state"] == "running" {
            return;
        }
        assert!(Instant::now() < deadline, "the command never showed as running: {shown}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn spawn_wait(server: &HeadlessServer, terminal: &str, args: &[&str]) -> Child {
    Command::new(bin())
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["terminal", terminal, "wait"])
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

/// The wait's output once it exits, failing the test when it still runs
/// after `within`.
#[track_caller]
fn finished(mut child: Child, within: Duration) -> Output {
    if !wait_for_child_exit(&mut child, within) {
        let _ = child.kill();
        let output = child.wait_with_output().unwrap();
        panic!(
            "the wait did not return within {within:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    child.wait_with_output().unwrap()
}

/// The wait has not returned after a moment in which nothing changed.
#[track_caller]
fn assert_still_waiting(child: &mut Child) {
    std::thread::sleep(Duration::from_millis(800));
    if let Some(status) = child.try_wait().unwrap() {
        let mut stderr = String::new();
        if let Some(mut pipe) = child.stderr.take() {
            let _ = pipe.read_to_string(&mut stderr);
        }
        panic!("the wait returned before its condition held: {status}: {stderr}");
    }
}

#[track_caller]
fn assert_timed_out(output: &Output) {
    assert_eq!(output.status.code(), Some(124), "{}", String::from_utf8_lossy(&output.stderr));
    let error = json_error(output);
    assert_eq!(error["code"], "wait.timeout", "{error}");
    assert_eq!(error["details"]["timed_out"], true, "{error}");
}

/// `--until idle` returns at once on a terminal with nothing running, waits
/// while a shell command runs, returns when it ends, and fails a timeout
/// with 124.
#[test]
fn terminal_wait_until_idle_returns_when_the_command_ends() {
    let server = HeadlessServer::start_without_shell_integration("terminal-wait-idle");
    let terminal = new_terminal(&server);

    let output = finished(spawn_wait(&server, &terminal, &["--until", "idle"]), SECONDS_10);
    assert_success(&output);
    let shown = json_output(&output);
    assert_eq!(shown["terminal_id"], terminal.as_str(), "{shown}");
    assert_eq!(shown["until"], "idle", "{shown}");
    assert_eq!(shown["state"], "idle", "{shown}");
    assert!(shown["waited_ms"].is_string(), "{shown}");

    start_waiting_command(&server, &terminal, COMMAND_END);
    let mut waiting = spawn_wait(&server, &terminal, &["--until", "idle", "--timeout", "60s"]);
    assert_still_waiting(&mut waiting);
    write(&server, &terminal, "go\n");
    let output = finished(waiting, SECONDS_10);
    assert_success(&output);
    let shown = json_output(&output);
    assert_eq!(shown["terminal_id"], terminal.as_str(), "{shown}");
    assert_eq!(shown["terminal"]["id"], terminal.as_str(), "{shown}");
    let extra = &shown["terminal"]["extra"];
    assert!(extra["activity"].is_null(), "an idle terminal shows a command: {shown}");

    start_waiting_command(&server, &terminal, COMMAND_END);
    let started = Instant::now();
    let output = finished(
        spawn_wait(&server, &terminal, &["--until", "idle", "--timeout", "1s"]),
        SECONDS_10,
    );
    assert!(started.elapsed() >= Duration::from_secs(1), "the wait ended before its timeout");
    assert_timed_out(&output);
    write(&server, &terminal, "go\n");
}

/// `--until ready` on a terminal whose agent never gets ready fails its
/// timeout like the other waits: 124, `wait.timeout`, `timed_out: true` and
/// `waited_ms`.
#[test]
fn terminal_wait_until_ready_timeout_says_timed_out() {
    let server = HeadlessServer::start_without_shell_integration("terminal-wait-ready-timeout");
    let terminal = new_terminal(&server);
    let output = finished(
        spawn_wait(&server, &terminal, &["--until", "ready", "--timeout", "1s"]),
        SECONDS_10,
    );
    assert_timed_out(&output);
    let error = json_error(&output);
    assert_eq!(error["details"]["waited_ms"], "1000", "{error}");
}

/// `--until prompt` waits for the shell's prompt mark: a terminal that never
/// drew one times out, a running command keeps the wait blocked, and the
/// prompt after it ends the wait with the record that shows it.
#[test]
fn terminal_wait_until_prompt_returns_at_the_prompt_mark() {
    let server = HeadlessServer::start_without_shell_integration("terminal-wait-prompt");
    let terminal = new_terminal(&server);

    let output = finished(
        spawn_wait(&server, &terminal, &["--until", "prompt", "--timeout", "1s"]),
        SECONDS_10,
    );
    assert_timed_out(&output);

    start_waiting_command(&server, &terminal, COMMAND_END_AND_PROMPT);
    let mut waiting = spawn_wait(&server, &terminal, &["--until", "prompt", "--timeout", "60s"]);
    assert_still_waiting(&mut waiting);
    write(&server, &terminal, "go\n");
    let output = finished(waiting, SECONDS_10);
    assert_success(&output);
    let shown = json_output(&output);
    assert_eq!(shown["until"], "prompt", "{shown}");
    assert_eq!(shown["state"], "prompt", "{shown}");
    let extra = &shown["terminal"]["extra"];
    assert!(extra["prompt"]["since_ms"].is_string(), "no prompt fact: {shown}");
    assert!(extra["activity"].is_null(), "a command still shows: {shown}");

    // At the prompt already: the wait answers at once.
    let output = finished(spawn_wait(&server, &terminal, &["--until", "prompt"]), SECONDS_10);
    assert_success(&output);
}

/// An unknown condition, or a timeout that is not a duration, is a usage
/// error (exit 2).
#[test]
fn terminal_wait_until_refuses_an_unknown_condition() {
    let server = HeadlessServer::start_without_shell_integration("terminal-wait-usage");
    let terminal = new_terminal(&server);
    for args in [&["--until", "soon"][..], &["--until", "idle", "--timeout", "later"]] {
        let output = finished(spawn_wait(&server, &terminal, args), SECONDS_10);
        assert_eq!(
            output.status.code(),
            Some(2),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

/// Bench round 4 item 10 (W5-R): `wait --until idle` right after input
/// returned the idle state the terminal had before that input, because the
/// command the input started had not shown yet. The wait now holds until
/// the terminal answers the input (here the command it started ends), or a
/// short grace passes with nothing started.
#[test]
fn w5r_terminal_wait_until_idle_after_input_waits_for_the_input_to_answer() {
    let server = HeadlessServer::start_without_shell_integration("w5r-wait-after-input");
    let terminal = new_terminal(&server);
    // The command shows as running only after a moment, as an agent's turn
    // starts a moment after Enter.
    write(
        &server,
        &terminal,
        &format!("sleep 1; printf '{COMMAND_START}'; sleep 1; printf '{COMMAND_END}'\n"),
    );
    let output = finished(
        spawn_wait(&server, &terminal, &["--until", "idle", "--timeout", "30s"]),
        Duration::from_secs(30),
    );
    assert_success(&output);
    let shown = json_output(&output);
    let extra = &shown["terminal"]["extra"];
    assert!(
        extra["last_command"]["finished_at_ms"].is_string(),
        "the wait returned before the command the input started ended: {shown}"
    );
    assert!(extra["activity"].is_null(), "a command still shows: {shown}");
}

/// An OSC 7501 report of Claude Code, as its hooks print it.
fn claude_status(fields: &str) -> String {
    format!(r"printf '\033]7501;{fields}:app=claude-code\033\\'; ")
}

/// W6-C (bench round 5 orchestration row 4): an agent that waits on a
/// permission dialog is structured on the pane path. `terminal status`,
/// `terminal wait --until idle` (exit 4, the shape `--until ready` has) and
/// `agents dialog list` in a session no app owns all give the dialog's
/// kind, message, options with their keys, and the keys that deny it.
/// After the answer, the same wait shape says idle.
#[test]
fn w6bc_a_blocked_terminal_agent_gives_its_dialog_on_every_read() {
    let server = HeadlessServer::start_without_shell_integration("w6bc-terminal-dialog");
    let terminal = new_terminal(&server);
    // "approve Bash: touch /tmp/w6bc", base64 as OSC 7501 carries it.
    let msg = "YXBwcm92ZSBCYXNoOiB0b3VjaCAvdG1wL3c2YmM=";
    let script = format!(
        "printf '\\033[2J\\033[H'; {}printf ' Bash command\\n touch /tmp/w6bc\\n Do you want to proceed?\\n \
         > 1. Yes\\n   2. No\\n\\n Esc to cancel\\n'; read line; {}\n",
        claude_status(&format!("state=blocked:kind=permission:msg={msg}")),
        claude_status("state=idle"),
    );
    write(&server, &terminal, &script);
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let shown = record(&server, &terminal);
        let blocked = shown["extra"]["program_status"]
            .as_array()
            .is_some_and(|records| records.iter().any(|record| record["state"] == "blocked"));
        let screen = json_cli(&server, &["terminal", &terminal, "screen", "read", "--details"]);
        if blocked && json_output(&screen)["text"].as_str().is_some_and(|t| t.contains("2. No")) {
            break;
        }
        assert!(Instant::now() < deadline, "the dialog never showed: {shown}");
        std::thread::sleep(Duration::from_millis(50));
    }
    let assert_dialog = |dialog: &serde_json::Value, what: &str| {
        assert_eq!(dialog["kind"], "permission", "{what}: {dialog}");
        assert_eq!(dialog["msg"], "approve Bash: touch /tmp/w6bc", "{what}: {dialog}");
        assert_eq!(dialog["options"][0]["label"], "Yes", "{what}: {dialog}");
        assert_eq!(dialog["options"][1]["label"], "No", "{what}: {dialog}");
        let keys = serde_json::json!(["down", "enter"]);
        assert_eq!(dialog["options"][1]["keys"], keys, "{what}: {dialog}");
        assert_eq!(dialog["deny_keys"], serde_json::json!(["escape"]), "{what}: {dialog}");
    };

    let status = json_cli(&server, &["terminal", &terminal, "status"]);
    assert_success(&status);
    let records = json_output(&status);
    let blocked = records
        .as_array()
        .and_then(|records| records.iter().find(|record| record["state"] == "blocked"))
        .cloned()
        .unwrap_or_default();
    assert_dialog(&blocked["dialog"], "terminal status");

    let output = finished(
        spawn_wait(&server, &terminal, &["--until", "idle", "--timeout", "10s"]),
        SECONDS_10,
    );
    assert_eq!(output.status.code(), Some(4), "{}", String::from_utf8_lossy(&output.stderr));
    let waited = json_output(&output);
    assert_eq!(waited["terminal_id"], terminal.as_str(), "{waited}");
    assert_eq!(waited["until"], "idle", "{waited}");
    assert_eq!(waited["state"], "blocked", "{waited}");
    assert_dialog(&waited["dialog"], "wait --until idle");

    let listed = json_cli(&server, &["agents", "dialog", "list"]);
    assert_success(&listed);
    let listed = json_output(&listed);
    let terminals = listed["result"]["terminals"].as_array().cloned().unwrap_or_default();
    let row = terminals.iter().find(|row| row["terminal"] == terminal.as_str());
    let row = row.unwrap_or_else(|| panic!("agents dialog list has no row for it: {listed}"));
    assert_dialog(&row["dialog"], "agents dialog list");

    write(&server, &terminal, "go\n");
    let output = finished(
        spawn_wait(&server, &terminal, &["--until", "idle", "--timeout", "10s"]),
        SECONDS_10,
    );
    assert_success(&output);
    let waited = json_output(&output);
    assert_eq!(waited["state"], "idle", "{waited}");
    assert!(waited["dialog"].is_null(), "{waited}");
}
