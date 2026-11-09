//! `cmux agent explain` and `cmux terminal wait --any|--all` through a real
//! daemon (bench round 4: the herdr/Rex gaps).
//!
//! - explain: a Claude hook turn (`UserPromptSubmit`, then
//!   `PermissionRequest`) leaves the agent blocked; explain names that hook
//!   event, its journal record, how the daemon took it and the working state
//!   before. A terminal with no agent is `agent.not_found`.
//! - wait: `--any` returns on the first listed agent that goes idle, `--all`
//!   only when every one has, and a passed `--timeout` is `wait.timeout`
//!   (exit 124). The waits ride the session's event stream.
use super::super::*;

const SECONDS_10: Duration = Duration::from_secs(10);

fn new_terminal(server: &HeadlessServer) -> String {
    let created = json_cli(server, &["tab", "create", "terminal"]);
    assert_success(&created);
    json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_string()
}

/// Runs the Claude hook helper for `event` in `terminal`, as Claude Code
/// does, with `native` on stdin.
fn hook(server: &HeadlessServer, terminal: &str, event: &str, native: &serde_json::Value) {
    let mut child = Command::new(bin())
        .args(["__agent-hook", "claude", event])
        .env("CMUX_TUI_SOCKET", &server.socket)
        .env("CMUX_TUI_TERMINAL_ID", terminal)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(format!("{native}\n").as_bytes()).unwrap();
    assert!(child.wait().unwrap().success(), "the {event} hook failed");
}

fn explain(server: &HeadlessServer, terminal: &str) -> Output {
    Command::new(bin())
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["agent", "explain", terminal])
        .output()
        .unwrap()
}

/// The explain value once the agent shows `state` (hooks are delivered by a
/// detached helper, so the state lands a moment after the hook returns).
#[track_caller]
fn explained_once(server: &HeadlessServer, terminal: &str, state: &str) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let output = explain(server, terminal);
        if output.status.success() {
            let value = json_output(&output);
            if value["state"] == state {
                return value;
            }
            assert!(Instant::now() < deadline, "the agent never showed {state}: {value}");
        } else {
            assert!(
                Instant::now() < deadline,
                "explain kept failing: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn report(server: &HeadlessServer, terminal: &str, state: &str) {
    let output = json_cli(
        server,
        &[
            "agent",
            "report",
            "--terminal",
            terminal,
            "--state",
            state,
            "--source",
            "socket",
            "--source-session",
            "w5t-wait",
        ],
    );
    assert_success(&output);
}

fn spawn_wait(server: &HeadlessServer, args: &[&str]) -> Child {
    Command::new(bin())
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["terminal", "wait"])
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

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

#[test]
fn w5t_agent_explain_names_the_hook_event_and_the_state_before() {
    let server = HeadlessServer::start_without_shell_integration("w5t-agent-explain");
    let terminal = new_terminal(&server);
    let session = serde_json::json!({"session_id": "w5t-explain", "prompt": "list files"});
    hook(&server, &terminal, "UserPromptSubmit", &session);
    explained_once(&server, &terminal, "working");
    let permission = serde_json::json!({
        "session_id": "w5t-explain",
        "tool_name": "Bash",
        "tool_input": {"command": "ls"},
    });
    hook(&server, &terminal, "PermissionRequest", &permission);
    let value = explained_once(&server, &terminal, "blocked");
    assert_eq!(value["terminal"], terminal.as_str(), "{value}");
    assert_eq!(value["source"], "hook", "{value}");
    let cause = &value["cause"];
    assert_eq!(cause["event"], "PermissionRequest", "{value}");
    assert_eq!(cause["decision"], "hook", "{value}");
    assert!(cause["sequence"].as_str().is_some_and(|sequence| !sequence.is_empty()), "{value}");
    assert_eq!(cause["retained"], true, "the journal still keeps the record: {value}");
    assert_eq!(value["previous"]["state"], "working", "{value}");
    assert_eq!(value["previous"]["source"], "hook", "{value}");

    // The text a person reads says the same.
    let text = Command::new(bin())
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .arg("--socket")
        .arg(&server.socket)
        .args(["agent", &terminal, "explain"])
        .output()
        .unwrap();
    assert_success(&text);
    let text = String::from_utf8_lossy(&text.stdout);
    assert!(text.contains("state: blocked, source hook"), "{text}");
    assert!(text.contains("hook event PermissionRequest"), "{text}");
    assert!(text.contains("before: working, source hook"), "{text}");

    // A terminal with no agent has nothing to explain.
    let plain = new_terminal(&server);
    let output = explain(&server, &plain);
    assert_eq!(output.status.code(), Some(1), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(json_error(&output)["code"], "agent.not_found");
}

#[test]
fn w5t_terminal_wait_any_and_all_return_on_the_agents_they_name() {
    let server = HeadlessServer::start_without_shell_integration("w5t-terminal-wait-any");
    let first = new_terminal(&server);
    let second = new_terminal(&server);
    report(&server, &first, "working");
    report(&server, &second, "working");
    let targets = format!("{first},{second}");

    // --any: the second agent goes idle first and is the one named.
    let mut any = spawn_wait(&server, &["--any", &targets, "--until", "idle", "--timeout", "60s"]);
    assert_still_waiting(&mut any);
    report(&server, &second, "idle");
    let output = finished(any, SECONDS_10);
    assert_success(&output);
    let value = json_output(&output);
    assert_eq!(value["mode"], "any", "{value}");
    assert_eq!(value["terminal"], second.as_str(), "{value}");
    assert!(matches!(value["status"].as_str(), Some("idle" | "done")), "{value}");
    assert_eq!(value["agents"][0]["status"], "working", "{value}");

    // --all: one agent still works, so the wait holds until it stops.
    let mut all = spawn_wait(&server, &["--all", &targets, "--until", "idle", "--timeout", "60s"]);
    assert_still_waiting(&mut all);
    report(&server, &first, "idle");
    let output = finished(all, SECONDS_10);
    assert_success(&output);
    let value = json_output(&output);
    assert_eq!(value["mode"], "all", "{value}");
    assert_eq!(value["matched"], serde_json::json!([first, second]), "{value}");

    // A condition that already holds returns at once.
    let output = finished(spawn_wait(&server, &["--any", &targets]), SECONDS_10);
    assert_success(&output);

    // A passed timeout is wait.timeout, exit 124.
    report(&server, &first, "working");
    let started = Instant::now();
    let output = finished(
        spawn_wait(&server, &["--any", &first, "--until", "blocked", "--timeout", "1s"]),
        SECONDS_10,
    );
    assert!(started.elapsed() >= Duration::from_secs(1), "the wait ended before its timeout");
    assert_eq!(output.status.code(), Some(124), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(json_error(&output)["code"], "wait.timeout");
}
