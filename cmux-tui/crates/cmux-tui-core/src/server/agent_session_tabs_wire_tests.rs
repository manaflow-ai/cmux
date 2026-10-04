//! `agent-session-tabs-v1` on the wire and in the store: the session bind
//! reaches v2 readers, connections without the capability read agent tabs
//! as browsers, keyed creations are serialized and fingerprint their target,
//! and a close deletes the browser's session history.

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

fn terminal_pane(mux: &Arc<Mux>) -> PaneId {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    mux.with_state(|state| state.pane_of(terminal)).unwrap()
}

fn agent_request(pane: PaneId, key: &str) -> Value {
    json!({"cmd":"new-conversation-tab","pane":pane,"origin":"wire-test","mutation_id":key,
           "agent_session":{"host":"install:mac-test","harness":"codex"}})
}

fn agent_tab_extra(snapshot_or_value: &Value, tab_id: &str) -> Option<Value> {
    match snapshot_or_value {
        Value::Object(object) => {
            if object.get("id").and_then(Value::as_str) == Some(tab_id)
                && object.contains_key("content_kind")
            {
                return Some(snapshot_or_value["extra"]["conversation"].clone());
            }
            object.values().find_map(|child| agent_tab_extra(child, tab_id))
        }
        Value::Array(items) => items.iter().find_map(|item| agent_tab_extra(item, tab_id)),
        _ => None,
    }
}

/// The bind commits on the state path: `session.events` upserts the tab
/// with the bound session, and a fresh snapshot shows it.
#[test]
fn bound_session_reaches_v2_readers() {
    let mux = test_mux("agent-tabs-wire-bind");
    let pane = terminal_pane(&mux);
    let created = run(&mux, agent_request(pane, "bind-v2")).unwrap();
    let surface = created["surface"].as_u64().unwrap();
    let tab_id = created["tab_resource_id"].as_str().unwrap().to_string();
    let before = mux.with_state(|state| state.resource_revision);

    let bound =
        run(&mux, json!({"cmd":"bind-conversation-tab-session","surface":surface,"session":"s-9"}))
            .unwrap();
    assert_eq!(bound["replayed"], false, "{bound}");
    let after = mux.with_state(|state| state.resource_revision);
    assert!(after > before, "the bind commits a resource revision");
    let changes = mux
        .resource_events_after(before)
        .unwrap()
        .batches
        .into_iter()
        .flat_map(|batch| batch.changes.as_array().cloned().unwrap_or_default())
        .collect::<Vec<_>>();
    let upserted = agent_tab_extra(&Value::Array(changes.clone()), &tab_id)
        .unwrap_or_else(|| panic!("no tab upsert after the bind: {changes:?}"));
    assert_eq!(upserted["agent_session"]["session"], "s-9");
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    assert_eq!(agent_tab_extra(&snapshot, &tab_id).unwrap()["agent_session"]["session"], "s-9");

    // The same session again is a replay and commits nothing.
    let replay =
        run(&mux, json!({"cmd":"bind-conversation-tab-session","surface":surface,"session":"s-9"}))
            .unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(mux.with_state(|state| state.resource_revision), after);
    mux.shutdown();
}

/// A connection with `conversation-tabs-v1` only reads an agent session tab
/// as a browser without its record; a conversation source keeps its kind.
#[test]
fn agent_session_tabs_downgrade_without_the_capability() {
    crate::state::conversation_tabs_store::mark_conversation_tabs_present();
    let agent = json!({"agent_session":{"host":"install:a","session":null,"harness":null}});
    let message = json!({
        "tabs":[{"content_kind":"conversation","extra":{"conversation":agent}},
                {"content_kind":"conversation",
                 "extra":{"conversation":{"conversation":"conv_1","owner":"local"}}}],
        "raw":[{"kind":"conversation","browser_renderer":"frontend","conversation":agent}],
    });
    let (writer, outbound) = writer_with_outbound();
    writer.negotiate_conversation_tabs(["conversation-tabs-v1".to_string()].iter());
    writer.send_control(&message).unwrap();
    let read: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(read["tabs"][0]["content_kind"], "browser");
    assert!(read["tabs"][0]["extra"].get("conversation").is_none(), "{read}");
    assert_eq!(read["tabs"][1]["content_kind"], "conversation");
    assert_eq!(read["raw"][0]["kind"], "browser");
    assert_eq!(read["raw"][0]["conversation"], Value::Null);

    writer.negotiate_conversation_tabs(["agent-session-tabs-v1".to_string()].iter());
    writer.send_control(&message).unwrap();
    let read: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(read["tabs"][0]["content_kind"], "conversation");
    assert_eq!(read["raw"][0]["conversation"], agent);
}

/// `set-client-info` negotiates `agent-session-tabs-v1` like
/// `conversation-tabs-v1`.
#[test]
fn agent_session_capability_is_accepted_by_set_client_info() {
    let mux = test_mux("agent-tabs-wire-capability");
    let (writer, outbound) = writer_with_outbound();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let capabilities = vec!["conversation-tabs-v1".to_string(), "agent-session-tabs-v1".into()];
    mux.control_clients.set_info(client, None, None, Some(capabilities)).unwrap();
    assert!(mux.control_clients.supports_capability(client, "agent-session-tabs-v1"));
    crate::state::conversation_tabs_store::mark_conversation_tabs_present();
    let agent = json!({"agent_session":{"host":"install:a","session":null,"harness":null}});
    writer
        .send_control(&json!({"tabs":[{"content_kind":"conversation",
                                       "extra":{"conversation":agent}}]}))
        .unwrap();
    let read: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(read["tabs"][0]["content_kind"], "conversation");
    mux.shutdown();
}

/// The same key with another target (pane or workspace) is refused.
#[test]
fn keyed_creation_refuses_another_target() {
    let mux = test_mux("agent-tabs-wire-target");
    let first = terminal_pane(&mux);
    let second = terminal_pane(&mux);
    run(&mux, agent_request(first, "target-1")).unwrap();
    let error = run(&mux, agent_request(second, "target-1")).unwrap_err();
    assert!(error.to_string().starts_with("idempotency.conflict:"), "{error}");
    let workspace = mux.with_state(|state| {
        let (index, _) = state.screen_of(first).unwrap();
        state.workspaces[index].id
    });
    let mut by_workspace = agent_request(first, "target-1");
    by_workspace.as_object_mut().unwrap().remove("pane");
    by_workspace["workspace"] = json!(workspace);
    let error = run(&mux, by_workspace).unwrap_err();
    assert!(error.to_string().starts_with("idempotency.conflict:"), "{error}");
    assert_eq!(run(&mux, agent_request(first, "target-1")).unwrap()["replayed"], true);
    mux.shutdown();
}

/// Concurrent requests with one key create one tab; the others replay it.
#[test]
fn concurrent_keyed_creations_create_one_tab() {
    let mux = test_mux("agent-tabs-wire-race");
    let pane = terminal_pane(&mux);
    let threads = (0..6)
        .map(|_| {
            let mux = mux.clone();
            std::thread::spawn(move || run(&mux, agent_request(pane, "race-1")))
        })
        .collect::<Vec<_>>();
    let results =
        threads.into_iter().map(|thread| thread.join().unwrap().unwrap()).collect::<Vec<_>>();
    let surfaces =
        results.iter().filter_map(|result| result["surface"].as_u64()).collect::<HashSet<_>>();
    assert_eq!(surfaces.len(), 1, "{results:?}");
    assert_eq!(results.iter().filter(|result| result["replayed"] == false).count(), 1);
    mux.shutdown();
}

/// A replay after the close carries a machine prefix, and the close deletes
/// a frontend browser's session history with its record.
#[test]
fn close_deletes_history_and_replay_reports_closed() {
    let mux = test_mux("agent-tabs-wire-close");
    let pane = terminal_pane(&mux);
    let created = run(&mux, agent_request(pane, "closed-1")).unwrap();
    run(&mux, json!({"cmd":"close-surface","surface":created["surface"]})).unwrap();
    let error = run(&mux, agent_request(pane, "closed-1")).unwrap_err();
    assert!(error.to_string().starts_with("frontend_browser_key_closed:"), "{error}");

    let record = crate::workspace_registry::FrontendBrowserRecord {
        engine: "cef".into(),
        url: "https://example.com/".into(),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    let browser = mux.new_frontend_browser_tab(Some(pane), record, None).unwrap();
    mux.set_frontend_browser_history(browser.id, Some(r#"{"entries":[]}"#.into())).unwrap();
    let browser_id = browser.resource_identity().unwrap().content_id.as_str().to_string();
    let history_rows = |mux: &Arc<Mux>| {
        mux.read_registry_state(|connection| {
            Ok(connection.query_row(
                "SELECT count(*) FROM frontend_browser_history WHERE browser_id = ?1",
                [&browser_id],
                |row| row.get::<_, i64>(0),
            )?)
        })
        .unwrap()
    };
    assert_eq!(history_rows(&mux), 1);
    run(&mux, json!({"cmd":"close-surface","surface":browser.id})).unwrap();
    assert_eq!(history_rows(&mux), 0);
    mux.shutdown();
}
