//! One frontend browser id belongs to at most one tab, ever. A closed tab
//! keeps its browser id as a tombstone (`resource_identities`; its frontend
//! and source rows are deleted with the close), so neither a keyed retry nor
//! any other creation may bind that id to a second tab (a registry once held two
//! `tab.create_browser` receipts with one `frontend_browser_id`: the home
//! chief tab's fixed key re-created a closed conversation tab).

use super::super::*;
use serde_json::Map;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn pane_of_new_workspace(mux: &Arc<Mux>) -> PaneId {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    mux.with_state(|state| state.pane_of(terminal)).unwrap()
}

/// Frontend-rendered tabs (conversation tabs included) in the raw tree.
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

fn conversation_tab(pane: PaneId, key: &str) -> Value {
    json!({"cmd":"new-conversation-tab","pane":pane,"conversation":"conv_01CHIEF",
           "owner":"local","origin":"cmux-next-home","mutation_id":key})
}

fn close(mux: &Arc<Mux>, created: &Value) {
    run(mux, json!({"cmd":"close-tabs","surfaces":[created["surface"]]})).unwrap();
}

/// The evidence path: a keyed conversation tab is created, closed (its
/// browser is tombstoned), and the same key is sent again. The retry must
/// create nothing and say why with a typed code; a new key gets a new id.
#[test]
fn keyed_conversation_tab_retry_after_close_never_rebinds_the_browser_id() {
    let mux = Mux::new_for_test("frontend-reuse-conversation", crate::SurfaceOptions::default());
    let pane = pane_of_new_workspace(&mux);
    let first = run(&mux, conversation_tab(pane, "home-chief-tab")).unwrap();
    close(&mux, &first);
    assert!(frontend_tabs(&mux).is_empty());

    let error = run(&mux, conversation_tab(pane, "home-chief-tab"))
        .expect_err("a closed keyed tab must not come back under its old browser id");
    assert_eq!(response_error_code(&error).as_deref(), Some("frontend_browser_key_closed"));
    assert!(frontend_tabs(&mux).is_empty(), "the refused retry created a tab");

    let fresh = run(&mux, conversation_tab(pane, "home-chief-tab-2")).unwrap();
    assert_ne!(fresh["content_resource_id"], first["content_resource_id"]);
    assert_ne!(fresh["tab_resource_id"], first["tab_resource_id"]);
    assert_eq!(frontend_tabs(&mux).len(), 1);
    mux.shutdown();
}

/// The keyed `new-frontend-browser-tab` refusal after a close carries the
/// same typed code.
#[test]
fn keyed_frontend_browser_retry_after_close_has_a_typed_code() {
    let mux = Mux::new_for_test("frontend-reuse-keyed", crate::SurfaceOptions::default());
    let pane = pane_of_new_workspace(&mux);
    let request = json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"about:blank",
                         "engine":"cef","idempotency_key":"reuse-1"});
    let first = run(&mux, request.clone()).unwrap();
    close(&mux, &first);
    let error = run(&mux, request).expect_err("the key's tab is closed");
    assert_eq!(response_error_code(&error).as_deref(), Some("frontend_browser_key_closed"));
    assert!(frontend_tabs(&mux).is_empty());
    mux.shutdown();
}

/// The daemon refuses a browser creation whose `frontend_browser_id` a tab
/// already committed, live or closed, before it records any receipt, so a
/// retry after an indeterminate first attempt can never bind one id to two
/// tabs.
#[test]
fn create_browser_refuses_a_frontend_browser_id_bound_to_another_tab() {
    let mux = Mux::new_for_test("frontend-reuse-bound", crate::SurfaceOptions::default());
    let pane = pane_of_new_workspace(&mux);
    let first = run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"about:blank","engine":"cef"}),
    )
    .unwrap();
    let browser = first["content_resource_id"].as_str().unwrap().to_string();
    let reuse = || {
        let fields =
            Map::from_iter([("frontend_browser_id".to_string(), Value::String(browser.clone()))]);
        mux.new_browser_tab_with_fields("about:blank".into(), Some(pane), None, fields)
    };

    let live = reuse().expect_err("the browser id belongs to a live tab");
    assert_eq!(response_error_code(&live).as_deref(), Some("frontend_browser_bound"), "{live:#}");
    assert_eq!(frontend_tabs(&mux).len(), 1);

    close(&mux, &first);
    let closed = reuse().expect_err("the browser id belongs to a closed tab");
    assert_eq!(response_error_code(&closed).as_deref(), Some("frontend_browser_bound"));
    assert!(frontend_tabs(&mux).is_empty(), "a tombstoned browser id came back");
    mux.shutdown();
}

/// A closed tab's `frontend_browser_tabs` row and session history go with the
/// close (nothing reads them after it: Reopen Closed restores from the closed
/// history record), and the id still never resolves or binds again: the
/// guarantee rests only on the `resource_identities` tombstone.
#[test]
fn a_closed_frontend_tab_drops_its_rows_and_never_resolves() {
    let mux = Mux::new_for_test("frontend-reuse-row", crate::SurfaceOptions::default());
    let pane = pane_of_new_workspace(&mux);
    let first = run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"about:blank","engine":"cef"}),
    )
    .unwrap();
    let browser = first["content_resource_id"].as_str().unwrap().to_string();
    assert!(mux.presentation_snapshot().frontend_browsers.contains_key(&browser));
    close(&mux, &first);

    let rows = mux
        .read_registry_state(|connection| {
            Ok(connection.query_row(
                "SELECT COUNT(*) FROM frontend_browser_tabs WHERE browser_id = ?1",
                [&browser],
                |row| row.get::<_, i64>(0),
            )?)
        })
        .unwrap();
    assert_eq!(rows, 0, "the close deletes the closed tab's frontend row");
    let history = mux
        .read_registry_state(|connection| {
            Ok(connection.query_row(
                "SELECT COUNT(*) FROM frontend_browser_history WHERE browser_id = ?1",
                [&browser],
                |row| row.get::<_, i64>(0),
            )?)
        })
        .unwrap();
    assert_eq!(history, 0, "and its session history");
    let fields = Map::from_iter([("frontend_browser_id".to_string(), Value::String(browser.clone()))]);
    let rebind = mux
        .new_browser_tab_with_fields("about:blank".into(), Some(pane), None, fields)
        .expect_err("a deleted row must not free the browser id");
    assert_eq!(response_error_code(&rebind).as_deref(), Some("frontend_browser_bound"), "{rebind:#}");
    // The snapshot a start (or any presentation reload) loads leaves it out.
    let loaded = mux.workspace_registry.lock().unwrap().presentation_snapshot().unwrap();
    assert!(
        !loaded.frontend_browsers.contains_key(&browser),
        "a tombstoned browser must not load as a live frontend browser"
    );
    mux.shutdown();
}
