//! `new-frontend-browser-tab {idempotency_key}`: a retry after a lost reply
//! creates exactly one tab, like every other typed creation (ownership rule:
//! every change is an op with a client-chosen idempotency key).

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, 0, command, &writer)
}

/// Frontend-rendered browser tabs in the raw tree.
fn frontend_tabs(mux: &Arc<Mux>) -> Vec<Value> {
    let tree = run(mux, json!({"cmd":"list-workspaces"})).unwrap();
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().unwrap().iter())
        .flat_map(|screen| screen["panes"].as_array().unwrap().iter())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .filter(|tab| tab["browser_renderer"] == "frontend")
        .cloned()
        .collect()
}

fn create(pane: PaneId, url: &str, key: &str) -> Value {
    json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":url,"engine":"cef",
           "owner":"install-a","idempotency_key":key})
}

#[test]
fn keyed_frontend_browser_tab_retry_after_a_lost_reply_creates_one_tab() {
    let mux = Mux::new_for_test("frontend-browser-keys", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();

    // The client sends the create and loses the reply (timeout or
    // disconnect), then resends the same request with the same key.
    let first = run(&mux, create(pane, "https://cmux.com", "gpui-create-1")).unwrap();
    let retry = run(&mux, create(pane, "https://cmux.com", "gpui-create-1")).unwrap();
    assert_eq!(retry["tab_resource_id"], first["tab_resource_id"], "{first} {retry}");
    assert_eq!(retry["surface"], first["surface"]);
    assert_eq!(retry["content_resource_id"], first["content_resource_id"]);
    assert_eq!(first["replayed"], false);
    assert_eq!(retry["replayed"], true);
    assert_eq!(frontend_tabs(&mux).len(), 1, "a keyed retry must not create a second tab");

    // The same key with another request is a conflict and creates nothing.
    let conflict = run(&mux, create(pane, "https://example.com", "gpui-create-1")).unwrap_err();
    assert!(conflict.to_string().contains("idempotency"), "{conflict}");
    assert_eq!(frontend_tabs(&mux).len(), 1);

    // A new key is a new tab.
    let second = run(&mux, create(pane, "https://cmux.com", "gpui-create-2")).unwrap();
    assert_ne!(second["tab_resource_id"], first["tab_resource_id"]);
    assert_eq!(second["replayed"], false);
    assert_eq!(frontend_tabs(&mux).len(), 2);
    mux.shutdown();
}

/// Without a key the command keeps its old behavior: every request is a tab.
#[test]
fn unkeyed_frontend_browser_tab_creates_a_tab_per_request() {
    let mux = Mux::new_for_test("frontend-browser-unkeyed", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let request = json!({"cmd":"new-frontend-browser-tab","pane":pane,
                         "url":"https://cmux.com","engine":"webkit"});
    let first = run(&mux, request.clone()).unwrap();
    let second = run(&mux, request).unwrap();
    assert_ne!(first["tab_resource_id"], second["tab_resource_id"]);
    assert_eq!(frontend_tabs(&mux).len(), 2);
    mux.shutdown();
}

/// The daemon says it dedupes, so a client can tell before it relies on it.
#[test]
fn frontend_browser_tab_keys_capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&"frontend-browser-tab-keys-v1"));
}
