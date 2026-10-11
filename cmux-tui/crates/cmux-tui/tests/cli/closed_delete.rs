//! `closed.delete` through the CLI and a real daemon.
#![cfg(unix)]

use super::*;

/// Delete Permanently and Clear Recently Closed (`closed.delete`) through
/// the CLI and a real daemon: chosen members of a group, one group, every
/// group closed at or after `--since-ms`, and every group. A deleted group
/// cannot be reopened.
#[test]
fn state_cli_closed_delete_and_clear_through_a_real_daemon() {
    let server = HeadlessServer::start("state-cli-closed-delete");
    for name in ["alpha", "beta"] {
        state_cli(&server, None, &["workspace", "create", "--name", name, "--empty"]);
    }
    // A closed group of two tabs: one pane, three terminal tabs, two of
    // them grouped so the pane stays open.
    state_cli(&server, None, &["workspace", "create", "--name", "gamma"]);
    let gamma = workspace_id_named(&server, "gamma");
    let snapshot = state_cli_topology(&server);
    let gamma_tab = |snapshot: &serde_json::Value| -> Vec<serde_json::Value> {
        snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|terminal| {
                workspace_of_terminal(snapshot, terminal["id"].as_str().unwrap()) == gamma
            })
            .map(|terminal| terminal["tab_id"].clone())
            .collect()
    };
    let first_tab = gamma_tab(&snapshot)[0].as_str().unwrap().to_string();
    let pane = snapshot["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["id"] == first_tab.as_str())
        .and_then(|tab| tab["pane_id"].as_str())
        .unwrap()
        .to_string();
    for _ in 0..2 {
        state_cli(&server, None, &["tab", "create", "terminal", "--pane", &pane]);
    }
    let tabs = gamma_tab(&state_cli_topology(&server));
    assert_eq!(tabs.len(), 3, "gamma has three terminal tabs: {tabs:?}");
    let tabs = tabs[1..].iter().map(|tab| tab.as_str().unwrap()).collect::<Vec<_>>().join(",");
    state_cli(&server, None, &["tab", "group", "create", "--tabs", &tabs, "--name", "pair"]);
    state_cli(&server, None, &["tab", "group", "pair", "close"]);
    for name in ["alpha", "beta"] {
        let workspace = workspace_id_named(&server, name);
        state_cli(&server, None, &["workspace", &workspace, "close"]);
    }
    let closed = state_cli(&server, None, &["closed", "list"]);
    let closed_id = |predicate: &dyn Fn(&serde_json::Value) -> bool| {
        closed
            .as_array()
            .unwrap()
            .iter()
            .find(|item| predicate(item))
            .and_then(|item| item["id"].as_str())
            .unwrap_or_else(|| panic!("closed history has no such group: {closed}"))
            .to_string()
    };
    let alpha = closed_id(&|item| item["kind"] == "workspace" && item["name"] == "alpha");
    let beta = closed_id(&|item| item["kind"] == "workspace" && item["name"] == "beta");
    let pair = closed_id(&|item| item["member_count"] == 2);
    let member_count = |id: &str| {
        let closed = state_cli(&server, None, &["closed", "list"]);
        closed
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["id"] == id)
            .map(|item| item["member_count"].clone())
    };

    let partial = state_cli(&server, None, &["closed", &pair, "delete", "--members", "0"]);
    assert_eq!(partial["value"]["deleted"], serde_json::json!([]), "{partial}");
    assert_eq!(partial["value"]["updated"], serde_json::json!([pair]), "{partial}");
    assert_eq!(member_count(&pair), Some(serde_json::json!(1)));

    let whole = state_cli(&server, None, &["closed", &alpha, "delete"]);
    assert_eq!(whole["value"]["deleted"], serde_json::json!([alpha]), "{whole}");
    let reopen = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["closed", &alpha, "reopen"])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    assert!(!reopen.status.success(), "a deleted group reopened");
    assert_eq!(json_error(&reopen)["code"], "resource.not_found");

    let future = state_cli(&server, None, &["closed", "clear", "--since-ms", "99999999999999"]);
    assert_eq!(future["value"]["deleted"], serde_json::json!([]), "{future}");
    let cleared = state_cli(&server, None, &["closed", "clear"]);
    let mut deleted = cleared["value"]["deleted"].as_array().cloned().unwrap_or_default();
    deleted.sort_by_key(|id| id.to_string());
    let mut expected = vec![serde_json::json!(beta), serde_json::json!(pair)];
    expected.sort_by_key(|id| id.to_string());
    assert_eq!(deleted, expected, "{cleared}");
    assert_eq!(state_cli(&server, None, &["closed", "list"]), serde_json::json!([]));

    let bad = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["closed", "clear", "--since-ms", "soon"])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    assert!(!bad.status.success());
    assert!(String::from_utf8_lossy(&bad.stderr).contains("--since-ms"));
}
