//! Durable tab links (plans/cmux-next/durable-links-DESIGN.md): a
//! `cmux://tab/tab_…` link names a tab by its resource id, and that id stays
//! the tab's for good. A closed tab reopens BY ITS ID (`closed.reopen
//! {tab}`) with the SAME id, also after the daemon restarts, so every link
//! to it keeps working. A live tab, or one reopened already, is not in
//! closed history: the app reveals it instead.

use super::*;

const SESSION: (&str, &str) = ("current", "current");

/// The resource ids of every tab the tree lists.
fn tab_ids(harness: &RecoveryHarness) -> Vec<String> {
    let tree = request(&harness.socket, serde_json::json!({"id":10,"cmd":"list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .filter_map(|tab| tab["tab_resource_id"].as_str().map(str::to_string))
        .collect()
}

/// A workspace with a second terminal tab beside its first one; returns the
/// second tab's surface and resource id.
fn new_terminal_tab(harness: &RecoveryHarness) -> (u64, String) {
    request(&harness.socket, serde_json::json!({"id":1,"cmd":"new-workspace","name":"links"}));
    let pane =
        request(&harness.socket, serde_json::json!({"id":2,"cmd":"list-workspaces"}))["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|workspace| workspace["name"] == "links")
            .and_then(|workspace| workspace["screens"][0]["panes"][0]["id"].as_u64())
            .expect("the workspace has a pane");
    let created = request(&harness.socket, serde_json::json!({"id":3,"cmd":"new-tab","pane":pane}));
    let surface = created["surface"].as_u64().expect("new-tab returned no surface");
    let tree = request(&harness.socket, serde_json::json!({"id":4,"cmd":"list-workspaces"}));
    let tab = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"].as_u64() == Some(surface))
        .and_then(|tab| tab["tab_resource_id"].as_str().map(str::to_string))
        .unwrap_or_else(|| panic!("no tab id for surface {surface}: {tree}"));
    (surface, tab)
}

fn close(harness: &RecoveryHarness, surface: u64) {
    request(
        &harness.socket,
        serde_json::json!({"id":11,"cmd":"close-tabs","surfaces":[surface],"end_terminals":true}),
    );
}

/// `closed.reopen {tab}`: the raw reply, ok or not.
fn reopen_tab(harness: &RecoveryHarness, tab: &str, key: &str) -> serde_json::Value {
    request_response(
        &harness.socket,
        serde_json::json!({
            "protocol":"cmux.protocol/2","type":"request","id":key,"operation":"closed.reopen",
            "params":{"machine":SESSION.0,"session":SESSION.1,"tab":tab},
            "idempotency_key":key,
        }),
    )
}

/// The tab ids a successful reopen reply names.
fn reopened_ids(reply: &serde_json::Value) -> Vec<String> {
    assert_eq!(reply["ok"], true, "closed.reopen {{tab}} failed: {reply}");
    reply["result"]["value"]["tab_ids"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|tab| tab.as_str().map(str::to_string))
        .collect()
}

fn wait_for_tab(harness: &RecoveryHarness, tab: &str) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while !tab_ids(harness).iter().any(|id| id == tab) {
        assert!(Instant::now() < deadline, "the tree never listed {tab}: {:?}", tab_ids(harness));
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn a_closed_tab_reopens_by_its_id_with_the_same_id() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("durable-link-same-id");
    let (surface, tab) = new_terminal_tab(&harness);
    close(&harness, surface);
    assert!(!tab_ids(&harness).contains(&tab), "the tab did not close");

    let reply = reopen_tab(&harness, &tab, "durable-reopen");
    assert_eq!(reopened_ids(&reply), vec![tab.clone()], "the link's tab came back as another id");
    wait_for_tab(&harness, &tab);
    // Clicking the link again finds it live: nothing more to reopen.
    let again = reopen_tab(&harness, &tab, "durable-reopen-again");
    assert_eq!(again["error"]["code"], "resource.not_found", "{again}");
}

#[test]
fn a_tab_closed_before_a_restart_reopens_by_its_id_after_it() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("durable-link-restart");
    let (surface, tab) = new_terminal_tab(&harness);
    close(&harness, surface);
    harness.terminate();
    harness.restart();

    let reply = reopen_tab(&harness, &tab, "durable-restart-reopen");
    assert_eq!(reopened_ids(&reply), vec![tab.clone()], "{reply}");
    wait_for_tab(&harness, &tab);
}

#[test]
fn a_live_tab_is_not_reopened_by_its_id() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("durable-link-live");
    let (_, tab) = new_terminal_tab(&harness);
    let reply = reopen_tab(&harness, &tab, "durable-live");
    assert_eq!(reply["error"]["code"], "resource.not_found", "{reply}");
    assert_eq!(tab_ids(&harness).iter().filter(|id| **id == tab).count(), 1);
}
