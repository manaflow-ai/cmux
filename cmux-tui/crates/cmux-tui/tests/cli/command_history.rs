//! Terminal command history through a real daemon
//! (`terminal-command-history-v1`): a command run in a terminal becomes a
//! row a trusted client lists and deletes, with a retention.
#![cfg(unix)]

use super::*;

#[path = "mouse_mode_reset.rs"]
mod mouse_mode_reset;

fn raw(server: &HeadlessServer, request: serde_json::Value) -> serde_json::Value {
    raw_json(server, request)
}

fn commands(server: &HeadlessServer) -> serde_json::Value {
    raw(server, serde_json::json!({"id": "list", "cmd": "list-terminal-commands"}))
}

#[test]
fn terminal_command_history_records_lists_and_deletes_commands() {
    let server = HeadlessServer::start("command-history");
    let identity = raw(&server, serde_json::json!({"id": "who", "cmd": "identify"}));
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "terminal-command-history-v1"),
        "{identity}"
    );
    let set = raw(
        &server,
        serde_json::json!({"id": "on", "cmd": "set-terminal-command-history", "enabled": true,
                           "retention_days": 7}),
    );
    assert_eq!(set, serde_json::json!({"enabled": true, "retention_days": 7}), "{set}");
    let zero = raw_cli(
        &server,
        serde_json::json!({"id": "zero", "cmd": "set-terminal-command-history", "enabled": true,
                           "retention_days": 0}),
    );
    assert!(!zero.status.success(), "retention_days 0 was accepted");

    let created = json_cli(&server, &["tab", "create", "terminal"]);
    assert_success(&created);
    let terminal = json_output(&created)["value"]["terminal_id"].as_str().unwrap().to_string();
    for marker in ["history_first", "history_second"] {
        let write = json_cli(
            &server,
            &["terminal", &terminal, "write", "--text", &format!("echo {marker}\n")],
        );
        assert_success(&write);
        wait_for_screen(&server, &terminal, marker);
    }
    let deadline = Instant::now() + Duration::from_secs(20);
    let listed = loop {
        let listed = commands(&server);
        let texts = listed["commands"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|row| row["command"].as_str())
            .filter(|text| text.contains("history_"))
            .count();
        if texts == 2 {
            break listed;
        }
        assert!(Instant::now() < deadline, "commands were never recorded: {listed}");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert_eq!(listed["retention_days"], 7, "{listed}");
    let rows = listed["commands"].as_array().unwrap();
    let first = rows.iter().find(|row| row["command"] == "echo history_first").unwrap();
    assert_eq!(first["terminal_id"], terminal.as_str(), "{first}");
    assert_eq!(first["exit_code"], 0, "{first}");

    // A delete names exactly one selector.
    let bad = raw_cli(
        &server,
        serde_json::json!({"id": "bad", "cmd": "delete-terminal-commands", "all": true,
                           "ids": ["1"]}),
    );
    assert!(!bad.status.success());
    let deleted = raw(
        &server,
        serde_json::json!({"id": "one", "cmd": "delete-terminal-commands", "ids": [first["id"]]}),
    );
    assert_eq!(deleted, serde_json::json!({"deleted": 1}));
    let left = commands(&server);
    assert!(
        left["commands"].as_array().unwrap().iter().all(|row| row["id"] != first["id"]),
        "{left}"
    );
    raw(&server, serde_json::json!({"id": "all", "cmd": "delete-terminal-commands", "all": true}));
    assert_eq!(commands(&server)["commands"], serde_json::json!([]));

    // Off: a command run while off is never recorded. Turning history back
    // on and recording a later command proves the earlier one was dropped,
    // not just slow.
    raw(
        &server,
        serde_json::json!({"id": "off", "cmd": "set-terminal-command-history", "enabled": false}),
    );
    let write =
        json_cli(&server, &["terminal", &terminal, "write", "--text", "echo history_off\n"]);
    assert_success(&write);
    wait_for_screen(&server, &terminal, "history_off");
    raw(
        &server,
        serde_json::json!({"id": "on2", "cmd": "set-terminal-command-history", "enabled": true}),
    );
    let write =
        json_cli(&server, &["terminal", &terminal, "write", "--text", "echo history_back\n"]);
    assert_success(&write);
    wait_for_screen(&server, &terminal, "history_back");
    let deadline = Instant::now() + Duration::from_secs(20);
    let texts = loop {
        let texts: Vec<String> = commands(&server)["commands"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|row| row["command"].as_str().map(str::to_string))
            .collect();
        if texts.iter().any(|text| text == "echo history_back") {
            break texts;
        }
        assert!(Instant::now() < deadline, "the command after re-enabling was never recorded");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert!(!texts.iter().any(|text| text.contains("history_off")), "{texts:?}");
}
