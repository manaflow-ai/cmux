//! Browser profile CLI commands exercise the real daemon control socket.

use super::*;

fn tree(server: &HeadlessServer) -> serde_json::Value {
    try_json_socket_request(&server.socket, serde_json::json!({"id": 1, "cmd": "list-workspaces"}))
        .expect("list-workspaces response")
}

fn browser_tab(tree: &serde_json::Value) -> &serde_json::Value {
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["browser_renderer"] == "frontend")
        .expect("frontend browser tab")
}

#[test]
fn browser_profile_commands_create_move_open_and_delete_through_the_daemon() {
    let server = HeadlessServer::start("browser-profiles");

    let created = state_cli(&server, None, &["browser", "profile", "create", "--name", "Work"]);
    let profile_id =
        created["browser_profile"]["id"].as_str().expect("created browser profile id").to_owned();

    let listed = state_cli(&server, None, &["browser", "profile", "list"]);
    assert_eq!(listed["browser_profiles"][1]["name"], "Work", "{listed}");
    assert_eq!(listed["browser_profiles"][1]["id"], profile_id, "{listed}");

    let opened = state_cli(
        &server,
        None,
        &[
            "browser",
            "profile",
            "open",
            "https://example.com/agents",
            "--engine",
            "webkit",
            "--profile",
            "Work",
        ],
    );
    assert!(opened["content_resource_id"].as_str().is_some(), "{opened}");
    assert_eq!(browser_tab(&tree(&server))["browser_profile_id"], profile_id);

    state_cli(&server, None, &["browser", "profile", "move", "--profile", "Work", "--index", "0"]);
    let moved = state_cli(&server, None, &["browser", "profile", "list"]);
    assert_eq!(moved["browser_profiles"][0]["name"], "Work", "{moved}");

    state_cli(&server, None, &["browser", "profile", "delete", "--profile", "Work"]);
    let after_delete = state_cli(&server, None, &["browser", "profile", "list"]);
    assert!(
        after_delete["browser_profiles"]
            .as_array()
            .unwrap()
            .iter()
            .all(|profile| profile["id"] != profile_id),
        "{after_delete}"
    );
}
