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
    assert_eq!(json_output(&output)["id"], terminal.as_str());

    start_waiting_command(&server, &terminal, COMMAND_END);
    let mut waiting = spawn_wait(&server, &terminal, &["--until", "idle", "--timeout", "60s"]);
    assert_still_waiting(&mut waiting);
    write(&server, &terminal, "go\n");
    let output = finished(waiting, SECONDS_10);
    assert_success(&output);
    let shown = json_output(&output);
    assert_eq!(shown["id"], terminal.as_str(), "{shown}");
    assert!(shown["extra"]["activity"].is_null(), "an idle terminal shows a command: {shown}");

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
    assert!(shown["extra"]["prompt"]["since_ms"].is_string(), "no prompt fact: {shown}");
    assert!(shown["extra"]["activity"].is_null(), "a command still shows: {shown}");

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
