//! `list-workspaces-limit-v1` (hq#8813): `limit: N` returns the first N
//! workspaces in sidebar order and `total`, so a phone draws its first screen
//! from a god session as fast as from a small one.

use super::tests::captured_writer;
use super::*;
use crate::SurfaceOptions;

fn run(mux: &Arc<Mux>, request: Value) -> Value {
    let command: Command = serde_json::from_value(request).unwrap();
    let (writer, _) = captured_writer();
    handle_command(mux, mux.local_test_client(0), command, &writer).unwrap()
}

/// The workspace ids in sidebar order, as `workspace.list {order: "personal"}` lists them.
fn sidebar_ids(mux: &Arc<Mux>) -> Vec<String> {
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":"list",
                          "operation":"workspace.list",
                          "params":{"machine":"current","session":"current","order":"personal"}});
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["result"]
        .as_array()
        .unwrap()
        .iter()
        .map(|workspace| workspace["id"].as_str().unwrap().to_string())
        .collect()
}

fn ids(reply: &Value) -> Vec<String> {
    reply["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .map(|workspace| workspace["resource_id"].as_str().unwrap().to_string())
        .collect()
}

fn five_workspaces(session: &str) -> Arc<Mux> {
    let mux = Mux::new_for_test(session, SurfaceOptions::default());
    for index in 0..5 {
        mux.create_empty_workspace(Some(format!("w{index}")), None, None).unwrap();
    }
    mux
}

#[test]
fn a_limit_lists_the_first_workspaces_in_sidebar_order_with_the_total() {
    let mux = five_workspaces("limit-first");
    let sidebar = sidebar_ids(&mux);
    assert_eq!(sidebar.len(), 5);
    let first = run(&mux, json!({"cmd": "list-workspaces", "limit": 2}));
    assert_eq!(first["total"], json!(5), "{first}");
    assert_eq!(ids(&first), sidebar[..2].to_vec());
    for field in ["registry_id", "generation", "workspace_revision", "pane_revision"] {
        assert!(!first[field].is_null(), "{field}: {first}");
    }
    // A row is the row the whole tree has.
    let whole = run(&mux, json!({"cmd": "list-workspaces"}));
    let row = whole["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["resource_id"] == json!(sidebar[0]))
        .unwrap();
    assert_eq!(&first["workspaces"][0], row);
    assert_eq!(run(&mux, json!({"cmd": "list-workspaces", "limit": 0}))["workspaces"], json!([]));
    mux.shutdown();
}

#[test]
fn a_part_of_the_tree_gives_no_revision_to_hold_and_a_whole_one_does() {
    let mux = five_workspaces("limit-known");
    let part = run(&mux, json!({"cmd": "list-workspaces", "known": {}, "limit": 2}));
    assert_eq!(part["workspaces"].as_array().unwrap().len(), 2);
    assert!(part.get("tree_revision").is_none(), "a part handed out a revision: {part}");

    let whole = run(&mux, json!({"cmd": "list-workspaces", "known": {}, "limit": 50}));
    assert_eq!(whole["workspaces"].as_array().unwrap().len(), 5);
    assert_eq!(whole["total"], json!(5));
    let revision = whole["tree_revision"].clone();
    assert!(revision.is_string(), "a whole list under the limit has a revision: {whole}");

    // The phone that holds the whole tree asks with its first-screen limit: unchanged.
    let known = json!({
        "registry_id": whole["registry_id"], "generation": whole["generation"],
        "workspace_revision": whole["workspace_revision"], "pane_revision": whole["pane_revision"],
        "terminal_revision": whole["terminal_revision"], "tree_revision": revision,
    });
    let again = run(&mux, json!({"cmd": "list-workspaces", "known": known, "limit": 2}));
    assert_eq!(again["unchanged"], json!(true), "{again}");
    mux.shutdown();
}
