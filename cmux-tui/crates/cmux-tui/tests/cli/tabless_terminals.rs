//! Hidden running shells (bench round 4, friction 1; port of feat W5-O).
//! `pane move` into a new pane or a new screen left a running shell with no
//! tab: not in the TUI, not in `pane list`, only in `terminal list` with
//! `tab_ids: []`. The command opens a shell tab only to hold the new pane, so
//! it must end that shell before it returns. Main's owner has no reaper, so a
//! terminal the command leaves stays until the session ends: the count right
//! after each command is the leak.
#![cfg(unix)]

use serde_json::Value;

use super::*;

/// How long a closed terminal may take to stop being listed as running.
const SETTLE: Duration = Duration::from_secs(10);

/// `cmux --json <args>` against `server`; the JSON result of a success.
fn run(server: &HeadlessServer, args: &[&str]) -> Value {
    let output = cmux_command()
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(args)
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_TUI_SESSION_ID")
        .output()
        .unwrap();
    assert_success(&output);
    json_output(&output)
}

/// The running terminals `terminal list` shows, split into (with a tab,
/// with no tab).
fn running(server: &HeadlessServer) -> (Vec<Value>, Vec<Value>) {
    let listed = run(server, &["terminal", "list"]);
    listed
        .as_array()
        .unwrap_or_else(|| panic!("terminal list is not an array: {listed}"))
        .iter()
        .filter(|terminal| terminal["lifecycle"] != "exited")
        .cloned()
        .partition(|terminal| terminal["tab_ids"].as_array().is_some_and(|tabs| !tabs.is_empty()))
}

/// No running terminal is left without a tab after `step` (an ended one may
/// take a moment to stop being listed as running).
fn assert_no_tabless(server: &HeadlessServer, step: &str) {
    let deadline = Instant::now() + SETTLE;
    loop {
        let (_, left) = running(server);
        if left.is_empty() {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "{step} left {} running terminal(s) with no tab: {}",
            left.len(),
            Value::Array(left)
        );
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn text(value: &Value, pointers: &[&str]) -> String {
    pointers
        .iter()
        .find_map(|pointer| value.pointer(pointer).and_then(Value::as_str))
        .unwrap_or_else(|| panic!("no {pointers:?} in {value}"))
        .to_owned()
}

#[test]
fn w5o_placeholder_shells_end_with_the_command_that_opened_them() {
    let server = HeadlessServer::start("tabless");
    assert_no_tabless(&server, "the new daemon");

    // Two panes, each with its own shell: the shells the moves keep.
    let created = run(&server, &["workspace", "create", "--name", "tabless"]);
    let first = text(&created, &["/value/pane_id", "/pane_id"]);
    let split = run(&server, &["pane", &first, "split", "--right"]);
    let second = text(&split, &["/value/pane_id", "/pane_id"]);
    assert_no_tabless(&server, "workspace create and pane split");

    // A move into a split: the split opens with a shell tab.
    let moved = run(&server, &["pane", &second, "move", "--to-pane", &first, "--split", "down"]);
    assert_no_tabless(&server, "pane move --to-pane --split down");
    let moved_pane = text(&moved, &["/destination/pane", "/value/destination/pane"]);

    // A move to a new screen: the screen opens with a shell tab.
    run(&server, &["pane", &moved_pane, "move", "--new-screen", "--name", "moved"]);
    assert_no_tabless(&server, "pane move --new-screen");

    // Only the placeholders ended: both panes' own shells still run, in tabs.
    let (placed, _) = running(&server);
    assert_eq!(placed.len(), 2, "a pane's own shell ended with a placeholder: {placed:?}");
}

/// `agent start` (port of feat W3-H, with W5-O's rule): the shell a new
/// workspace or a split opens with ends with `terminal close`, so no running
/// terminal is left without a tab, and the agents' own terminals still run.
#[test]
fn w3h_agent_start_ends_its_placeholder_shells() {
    let server = HeadlessServer::start("agentstart");
    assert_no_tabless(&server, "the new daemon");

    // No pane given: a new workspace (empty session) or a split of the
    // focused pane, each opened with a placeholder shell.
    let alpha =
        run(&server, &["agent", "start", "alpha", "--cmd", "sleep 300", "--no-wait", "--no-focus"]);
    assert_no_tabless(&server, "agent start alpha");

    // A split of a named pane.
    let pane = text(&alpha, &["/pane_id", "/value/pane_id"]);
    let beta = run(
        &server,
        &[
            "agent",
            "start",
            "beta",
            "--cmd",
            "sleep 300",
            "--no-wait",
            "--no-focus",
            "--pane",
            &pane,
            "--split",
            "down",
        ],
    );
    assert_no_tabless(&server, "agent start beta --pane --split down");

    let (placed, _) = running(&server);
    let ids: Vec<&str> = placed.iter().filter_map(|terminal| terminal["id"].as_str()).collect();
    for agent in [&alpha, &beta] {
        let terminal = text(agent, &["/terminal_id", "/value/terminal_id"]);
        assert!(
            ids.contains(&terminal.as_str()),
            "the agent's terminal {terminal} ended: {placed:?}"
        );
    }
}
