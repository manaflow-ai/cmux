//! `page-tabs-v1`: a conversation tab whose source is one of the app's own
//! pages (App Store, Settings, ...) is an ordinary store tab. It keeps its
//! record across every move, a pane holding only a page tab is a valid
//! pane, closing it deletes its store rows, Reopen Closed brings it back,
//! and a connection without the capability reads it as a browser tab with
//! no record.

use super::super::*;

fn writer_with_outbound() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    (writer, outbound)
}

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let (writer, _) = writer_with_outbound();
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn test_mux(name: &str) -> Arc<Mux> {
    Mux::new_for_test(name, crate::SurfaceOptions::default())
}

/// A new workspace with one terminal; returns (terminal surface, its pane).
fn terminal_pane(mux: &Arc<Mux>) -> (SurfaceId, PaneId) {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    (terminal, mux.with_state(|state| state.pane_of(terminal)).unwrap())
}

fn page_tab(mux: &Arc<Mux>, pane: PaneId, page: &str) -> anyhow::Result<Value> {
    run(mux, json!({"cmd":"new-conversation-tab","pane":pane,"page":page}))
}

fn surface_of(created: &Value) -> SurfaceId {
    created["surface"].as_u64().unwrap()
}

/// The raw tree tab of `surface`, if it is placed.
fn raw_tab(mux: &Arc<Mux>, surface: SurfaceId) -> Option<Value> {
    let tree = run(mux, json!({"cmd":"list-workspaces"})).unwrap();
    tree["workspaces"]
        .as_array()?
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"] == json!(surface))
        .cloned()
}

fn pane_tabs(mux: &Arc<Mux>, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone()).unwrap_or_default())
}

fn page_rows(mux: &Arc<Mux>, browser_id: &str) -> i64 {
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT count(*) FROM page_tabs WHERE browser_id = ?1",
            [browser_id],
            |row| row.get::<_, i64>(0),
        )?)
    })
    .unwrap()
}

fn resource(mux: &Arc<Mux>, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":operation,
                              "operation":operation,"params":params});
    if let Some(key) = key {
        envelope["idempotency_key"] = json!(key);
    }
    let response =
        crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], true, "{operation}: {response}");
    response["result"].clone()
}

/// A page tab keeps its record across move-tab, move-tab-to-split (alone in
/// the new pane) and move-tab-to-new-workspace, and its pane's last other
/// tab can close without closing it. Its close deletes its row.
#[test]
fn page_tab_is_an_ordinary_store_tab() {
    let mux = test_mux("page-tabs-moves");
    let (terminal, first) = terminal_pane(&mux);
    let (_, second) = terminal_pane(&mux);
    let created = page_tab(&mux, first, "app-store").unwrap();
    let surface = surface_of(&created);
    assert_eq!(created["conversation"], json!({"page":"app-store"}), "{created}");
    let tab = raw_tab(&mux, surface).unwrap();
    assert_eq!(tab["kind"], "conversation");
    assert_eq!(tab["conversation"], json!({"page":"app-store"}));

    // The terminal leaves; the page tab holds the pane.
    run(&mux, json!({"cmd":"close-surface","surface":terminal})).unwrap();
    assert_eq!(pane_tabs(&mux, first), vec![surface], "a page tab alone is a valid pane");

    run(&mux, json!({"cmd":"move-tab","surface":surface,"pane":second,"index":0})).unwrap();
    assert_eq!(mux.with_state(|state| state.pane_of(surface)), Some(second));
    run(&mux, json!({"cmd":"move-tab-to-split","surface":surface,"pane":second,"edge":"right"}))
        .unwrap();
    let split = mux.with_state(|state| state.pane_of(surface)).unwrap();
    assert_ne!(split, second);
    assert_eq!(pane_tabs(&mux, split), vec![surface]);
    run(&mux, json!({"cmd":"move-tab-to-new-workspace","surface":surface})).unwrap();
    assert_eq!(raw_tab(&mux, surface).unwrap()["conversation"], json!({"page":"app-store"}));

    let browser = created["content_resource_id"].as_str().unwrap().to_string();
    assert_eq!(page_rows(&mux, &browser), 1);
    run(&mux, json!({"cmd":"close-surface","surface":surface})).unwrap();
    assert_eq!(page_rows(&mux, &browser), 0);
    mux.shutdown();
}

/// Reopen Closed brings a page tab back with its page, from the close record.
#[test]
fn reopened_page_tab_keeps_its_page() {
    let mux = test_mux("page-tabs-reopen");
    let (terminal, pane) = terminal_pane(&mux);
    let created = page_tab(&mux, pane, "settings").unwrap();
    run(&mux, json!({"cmd":"close-surface","surface":surface_of(&created)})).unwrap();
    let closed = resource(&mux, "closed.list", json!({}), None);
    let group = closed.as_array().unwrap().first().cloned().expect("the close is recorded");
    resource(&mux, "closed.reopen", json!({"closed": group["id"]}), Some("page-re-1"));
    let back = pane_tabs(&mux, pane).into_iter().find(|surface| *surface != terminal).unwrap();
    let tab = raw_tab(&mux, back).unwrap();
    assert_eq!(tab["kind"], "conversation", "{tab}");
    assert_eq!(tab["conversation"], json!({"page":"settings"}));
    mux.shutdown();
}

/// A page id is 1 to 64 lowercase letters, digits or '-', '_', '.'; a page
/// and another source together are refused.
#[test]
fn page_source_is_validated() {
    let mux = test_mux("page-tabs-validate");
    let (_, pane) = terminal_pane(&mux);
    for page in ["", "App Store", "a/b", &"x".repeat(65)] {
        let error = page_tab(&mux, pane, page).unwrap_err();
        assert!(error.to_string().starts_with("bad request"), "{page}: {error}");
    }
    let both = run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,"page":"settings",
               "conversation":"conv_1","owner":"local"}),
    );
    assert!(both.unwrap_err().to_string().starts_with("bad request"));
    assert!(page_tab(&mux, pane, "debug-settings").is_ok());
    mux.shutdown();
}

/// A connection without `page-tabs-v1` reads a page tab as a browser with
/// no record, in v2 and raw form; agent session and conversation sources
/// are untouched by it.
#[test]
fn page_tabs_downgrade_without_the_capability() {
    crate::state::conversation_tabs_store::mark_conversation_tabs_present();
    let page = json!({"page":"app-store"});
    let agent = json!({"agent_session":{"host":"install:a","session":null,"harness":null}});
    let message = json!({
        "tabs":[{"content_kind":"conversation","extra":{"conversation":page}},
                {"content_kind":"conversation","extra":{"conversation":agent}}],
        "raw":[{"kind":"conversation","browser_renderer":"frontend","conversation":page}],
    });
    let (writer, outbound) = writer_with_outbound();
    let negotiated = ["conversation-tabs-v1".to_string(), "agent-session-tabs-v1".to_string()];
    writer.negotiate_conversation_tabs(negotiated.iter());
    writer.send_control(&message).unwrap();
    let read: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(read["tabs"][0]["content_kind"], "browser", "{read}");
    assert!(read["tabs"][0]["extra"].get("conversation").is_none(), "{read}");
    assert_eq!(read["tabs"][1]["content_kind"], "conversation");
    assert_eq!(read["raw"][0]["kind"], "browser");
    assert_eq!(read["raw"][0]["conversation"], Value::Null);

    writer.negotiate_conversation_tabs(["page-tabs-v1".to_string()].iter());
    writer.send_control(&message).unwrap();
    let read: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(read["tabs"][0]["content_kind"], "conversation");
    assert_eq!(read["raw"][0]["conversation"], page);
}

/// The daemon advertises `page-tabs-v1`, and `set-client-info` negotiates it.
#[test]
fn page_tabs_capability_is_advertised_and_negotiated() {
    let mux = test_mux("page-tabs-capability");
    assert!(identify_capabilities(&mux).contains(&"page-tabs-v1"), "page-tabs-v1 is advertised");
    let (writer, _) = writer_with_outbound();
    let client = mux.control_clients.register(ClientTransport::Unix, writer);
    let capabilities = vec!["conversation-tabs-v1".to_string(), "page-tabs-v1".into()];
    mux.control_clients.set_info(client, None, None, Some(capabilities)).unwrap();
    assert!(mux.control_clients.supports_capability(client, "page-tabs-v1"));
    mux.shutdown();
}
