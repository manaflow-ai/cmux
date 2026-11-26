//! A terminal whose pane was closed keeps its shell for the reap grace, so a reopen shows it
//! again. Through the CLI and a real daemon: input to it is refused as `terminal.closed` (it
//! answered `"sent": true`), a screen read says `"closed": true` (it read as live), and the closed
//! pane's id names its reopen (it said only "no pane matches"). Reopened, the terminal takes
//! input again.
#![cfg(unix)]

use super::*;

/// The terminal shown in `pane`, from one session snapshot.
fn terminal_in_pane(server: &HeadlessServer, pane: &str) -> String {
    let snapshot = state_cli_topology(server);
    let tab = snapshot["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["pane_id"] == pane)
        .and_then(|tab| tab["id"].as_str())
        .unwrap_or_else(|| panic!("no tab in {pane}: {snapshot}"))
        .to_string();
    snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["tab_id"] == tab.as_str())
        .and_then(|terminal| terminal["id"].as_str())
        .unwrap_or_else(|| panic!("no terminal in {tab}: {snapshot}"))
        .to_string()
}

#[track_caller]
fn assert_refused_as_closed(output: &Output, terminal: &str) {
    assert_eq!(
        output.status.code(),
        Some(1),
        "input to a closed terminal must fail\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let error = json_error(output);
    assert_eq!(error["code"], "terminal.closed", "{error}");
    assert_eq!(error["details"]["terminal_id"], terminal, "{error}");
    let message = error["message"].as_str().unwrap();
    assert!(message.contains("`cmux closed list`"), "{message}");
    assert!(message.contains("reopen"), "{message}");
}

#[test]
fn a_closed_panes_terminal_refuses_input_and_says_it_was_closed() {
    let server = HeadlessServer::start("closed-terminal-refuses");
    let created = json_cli(&server, &["workspace", "create", "--name", "closed-terminal"]);
    assert_success(&created);
    let pane0 = json_output(&created)["value"]["pane_id"].as_str().unwrap().to_string();
    let split = json_cli(&server, &["pane", &pane0, "split", "--right"]);
    assert_success(&split);
    let pane = json_output(&split)["value"]["pane_id"].as_str().unwrap().to_string();
    let terminal = terminal_in_pane(&server, &pane);

    // Live: a read carries no `closed`, and input lands.
    let read = json_cli(&server, &["terminal", &terminal, "screen", "read"]);
    assert_success(&read);
    assert!(json_output(&read).get("closed").is_none(), "{}", json_output(&read));
    assert_success(&json_cli(&server, &["terminal", &terminal, "write", "--text", "live"]));

    assert_success(&json_cli(&server, &["pane", &pane, "close"]));

    // The last screen is still readable, marked closed.
    let read = json_cli(&server, &["terminal", &terminal, "screen", "read"]);
    assert_success(&read);
    let screen = json_output(&read);
    assert_eq!(screen["closed"], true, "{screen}");

    // Input is refused, by every input verb and by `send`.
    assert_refused_as_closed(
        &json_cli(&server, &["terminal", &terminal, "write", "--text", "hi"]),
        &terminal,
    );
    assert_refused_as_closed(
        &json_cli(&server, &["terminal", &terminal, "keys", "enter"]),
        &terminal,
    );
    let sent =
        json_cli(&server, &["terminal", &terminal, "send", "--text", "hi", "--wait", "none"]);
    assert!(!String::from_utf8_lossy(&sent.stdout).contains("\"sent\""), "{sent:?}");
    assert_refused_as_closed(&sent, &terminal);

    // The closed pane's id says it was closed and names its reopen.
    let shown = json_cli(&server, &["pane", &pane, "show"]);
    assert_eq!(shown.status.code(), Some(1), "{shown:?}");
    let error = json_error(&shown);
    assert_eq!(error["code"], "selector.not_found", "{error}");
    let closed = state_cli(&server, None, &["closed", "list"]);
    let group = closed[0]["id"].as_str().unwrap().to_string();
    let message = error["message"].as_str().unwrap();
    assert!(message.contains(&format!("pane {pane} was closed")), "{message}");
    assert!(message.contains(&format!("`cmux closed {group} reopen`")), "{message}");

    // An id that never existed names the list command.
    let unknown = format!("pane_{}", "0".repeat(32));
    let error = json_error(&json_cli(&server, &["pane", &unknown, "show"]));
    let message = error["message"].as_str().unwrap();
    assert!(message.contains("`cmux pane list --json`"), "{message}");

    // Reopened within the grace, the same terminal shows again and takes input.
    assert_success(&json_cli(&server, &["closed", &group, "reopen"]));
    assert_success(&json_cli(&server, &["terminal", &terminal, "write", "--text", "back"]));
    let read = json_cli(&server, &["terminal", &terminal, "screen", "read"]);
    assert_success(&read);
    assert!(json_output(&read).get("closed").is_none(), "{}", json_output(&read));
}
