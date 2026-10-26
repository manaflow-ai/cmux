//! New Tab creates an unbound agent tab and binds the session when it starts.
//! Public clients must retain that canonical identity instead of the browser
//! compatibility projection intended for clients that cannot render conversations.
use super::*;
use serde_json::{Value, json};

const SESSION: &str = "sess-newtab-identity";

fn started_newtab(server: &HeadlessServer) -> String {
    json_socket_request(&server.socket, json!({"id":1,"cmd":"new-workspace"}));
    let tree = json_socket_request(&server.socket, json!({"id":2,"cmd":"list-workspaces"}));
    let pane = tree["workspaces"][0]["screens"][0]["panes"][0]["id"].clone();
    let tab = json_socket_request(
        &server.socket,
        json!({"id":3,"cmd":"new-conversation-tab",
        "pane":pane,"agent_session":{"host":"install:newtab-test","session":null,"harness":"codex"}}),
    );
    json_socket_request(
        &server.socket,
        json!({"id":4,"cmd":"bind-conversation-tab-session",
        "surface":tab["surface"],"expected_session":null,"session":SESSION}),
    );
    tab["tab_resource_id"].as_str().unwrap().to_owned()
}

fn assert_agent_tab(value: &Value, tab: &str) {
    let row = find_tab(value, tab).unwrap_or_else(|| panic!("missing {tab}: {value}"));
    assert_eq!(row["content_kind"], "conversation", "agent tab projected as a browser: {row}");
    assert_eq!(row["extra"]["conversation"]["agent_session"]["session"], SESSION, "{row}");
}

fn find_tab<'a>(value: &'a Value, tab: &str) -> Option<&'a Value> {
    if value["id"] == tab && value.get("content_kind").is_some() {
        return Some(value);
    }
    match value {
        Value::Object(fields) => fields.values().find_map(|v| find_tab(v, tab)),
        Value::Array(items) => items.iter().find_map(|v| find_tab(v, tab)),
        _ => None,
    }
}

#[test]
fn newtab_agent_identity_cli_preserves_bound_session() {
    let server = HeadlessServer::start("newtab-cli-identity");
    let tab = started_newtab(&server);
    for args in [vec!["tab", "list"], vec!["tab", &tab, "get"], vec!["session", "snapshot"]] {
        let output = json_cli(&server, &args);
        assert_success(&output);
        assert_agent_tab(&json_output(&output), &tab);
    }
}

#[test]
fn newtab_agent_identity_mcp_preserves_bound_session_before_prefix_lookup() {
    let server = HeadlessServer::start("newtab-mcp-identity");
    let tab = started_newtab(&server);
    let config = server.dir.join("next.json");
    fs::write(&config, r#"{"mcp":{"enabled":true}}"#).unwrap();
    let mut child = Command::new(bin())
        .args(["--socket"])
        .arg(&server.socket)
        .args(["mcp", "serve"])
        .env("CMUX_NEXT_CONFIG_FILE", config)
        .env_remove("CMUX_TUI_SOCKET")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    for message in [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{
            "protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"newtab-test","version":"1"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{
            "name":"tab_get","arguments":{"tab":&tab[..12]}}}),
    ] {
        writeln!(input, "{message}").unwrap();
    }
    drop(input);
    let output = child.wait_with_output().unwrap();
    assert_success(&output);
    let response = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|message| message["id"] == 2)
        .expect("tools/call response");
    assert_eq!(response["result"]["isError"], false, "{response}");
    assert_agent_tab(&response["result"]["structuredContent"], &tab);
}
