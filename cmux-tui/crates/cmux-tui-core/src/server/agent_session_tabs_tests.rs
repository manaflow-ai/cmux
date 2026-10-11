//! `agent-session-tabs-v1` (plans/cmux-next/agent-tabs-store.md): a
//! conversation tab whose source is an acpmux agent session is an ordinary
//! store tab. It keeps its record across every move, its session is bound
//! once, and closing any conversation tab deletes its store rows (the close
//! record in the closed history is what reopen uses).

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
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

fn agent_tab(mux: &Arc<Mux>, pane: PaneId, session: Option<&str>) -> anyhow::Result<Value> {
    run(
        mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:mac-test","session":session,"harness":"claude"}}),
    )
}

fn conversation_tab(mux: &Arc<Mux>, pane: PaneId, key: &str) -> anyhow::Result<Value> {
    run(
        mux,
        json!({"cmd":"new-conversation-tab","pane":pane,"conversation":"conv_01GROWTH",
               "owner":"local","origin":"agent-tabs-test","mutation_id":key}),
    )
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

fn rows(mux: &Arc<Mux>, table: &str, browser_ids: &[String]) -> i64 {
    let sql = format!(
        "SELECT count(*) FROM {table} WHERE browser_id IN (SELECT value FROM json_each(?1))"
    );
    let ids = serde_json::to_string(browser_ids).unwrap();
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(&sql, [ids], |row| row.get::<_, i64>(0))?)
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

const AGENT: &str = "agent_session";

/// An agent tab keeps its source across move-tab to another pane,
/// move-tab-to-split and move-tab-to-new-workspace; a pane holding only the
/// agent tab is a valid pane (I3).
#[test]
fn agent_session_tab_keeps_its_record_across_every_move() {
    let mux = test_mux("agent-tabs-moves");
    let (_, first) = terminal_pane(&mux);
    let (_, second) = terminal_pane(&mux);
    let created = agent_tab(&mux, first, Some("sess-1")).unwrap();
    let surface = surface_of(&created);
    let expected =
        json!({"host":"install:mac-test","session":"sess-1","harness":"claude","host_name":null});
    assert_eq!(created["conversation"][AGENT], expected, "{created}");
    let tab = raw_tab(&mux, surface).unwrap();
    assert_eq!(tab["kind"], "conversation");
    assert_eq!(tab["conversation"][AGENT], expected);

    run(&mux, json!({"cmd":"move-tab","surface":surface,"pane":second,"index":0})).unwrap();
    assert_eq!(mux.with_state(|state| state.pane_of(surface)), Some(second));
    assert_eq!(raw_tab(&mux, surface).unwrap()["conversation"][AGENT], expected);

    run(&mux, json!({"cmd":"move-tab-to-split","surface":surface,"pane":second,"edge":"right"}))
        .unwrap();
    let split = mux.with_state(|state| state.pane_of(surface)).unwrap();
    assert_ne!(split, second);
    assert_eq!(pane_tabs(&mux, split), vec![surface], "the agent tab alone is a valid pane");
    assert_eq!(raw_tab(&mux, surface).unwrap()["conversation"][AGENT], expected);

    run(&mux, json!({"cmd":"move-tab-to-new-workspace","surface":surface})).unwrap();
    let alone = mux.with_state(|state| state.pane_of(surface)).unwrap();
    assert_eq!(pane_tabs(&mux, alone), vec![surface]);
    assert_eq!(raw_tab(&mux, surface).unwrap()["conversation"][AGENT], expected);

    let browser = created["content_resource_id"].as_str().unwrap().to_string();
    assert_eq!(rows(&mux, "agent_session_tabs", std::slice::from_ref(&browser)), 1);
    run(&mux, json!({"cmd":"close-surface","surface":surface})).unwrap();
    assert_eq!(rows(&mux, "agent_session_tabs", &[browser]), 0);
    mux.shutdown();
}

/// A new chat's session is bound from null: the same id replays, another id
/// with a stale expectation is refused; a conversation-source tab has no
/// session.
#[test]
fn agent_session_is_bound_from_null() {
    let mux = test_mux("agent-tabs-bind");
    let (_, pane) = terminal_pane(&mux);
    let surface = surface_of(&agent_tab(&mux, pane, None).unwrap());
    assert_eq!(raw_tab(&mux, surface).unwrap()["conversation"][AGENT]["session"], Value::Null);

    let bind = |session: &str| {
        run(
            &mux,
            json!({"cmd":"bind-conversation-tab-session","surface":surface,"session":session,
                   "expected_session":null}),
        )
    };
    let first = bind("sess-new").unwrap();
    assert_eq!(first["replayed"], false, "{first}");
    assert_eq!(first["conversation"][AGENT]["session"], "sess-new");
    assert_eq!(raw_tab(&mux, surface).unwrap()["conversation"][AGENT]["session"], "sess-new");
    assert_eq!(bind("sess-new").unwrap()["replayed"], true);
    let other = bind("sess-other").unwrap_err();
    assert!(other.to_string().starts_with("conversation_tab.session_conflict"), "{other}");
    assert_eq!(raw_tab(&mux, surface).unwrap()["conversation"][AGENT]["session"], "sess-new");

    let conversation = surface_of(&conversation_tab(&mux, pane, "bind-conv").unwrap());
    let refused = run(
        &mux,
        json!({"cmd":"bind-conversation-tab-session","surface":conversation,"session":"sess-x",
               "expected_session":null}),
    )
    .unwrap_err();
    assert!(refused.to_string().contains("bad request"), "{refused}");
    mux.shutdown();
}

/// Closing conversation tabs leaves no frontend browser or conversation
/// rows behind (the tables do not grow with every closed tab).
#[test]
fn closed_conversation_tabs_leave_no_store_rows() {
    let mux = test_mux("agent-tabs-growth");
    let (_, pane) = terminal_pane(&mux);
    let mut browsers = Vec::new();
    for index in 0..3 {
        let created = conversation_tab(&mux, pane, &format!("growth-{index}")).unwrap();
        browsers.push(created["content_resource_id"].as_str().unwrap().to_string());
        run(&mux, json!({"cmd":"close-surface","surface":surface_of(&created)})).unwrap();
    }
    assert_eq!(rows(&mux, "frontend_browser_tabs", &browsers), 0);
    assert_eq!(rows(&mux, "conversation_tabs", &browsers), 0);
    mux.shutdown();
}

/// Reopen Closed brings a conversation tab back as a conversation tab with
/// the same record, from the close record.
#[test]
fn reopened_conversation_tab_keeps_its_record() {
    let mux = test_mux("agent-tabs-reopen");
    let (terminal, pane) = terminal_pane(&mux);
    let created = conversation_tab(&mux, pane, "reopen-1").unwrap();
    run(&mux, json!({"cmd":"close-surface","surface":surface_of(&created)})).unwrap();
    let closed = resource(&mux, "closed.list", json!({}), None);
    let group = closed.as_array().unwrap().first().cloned().expect("the close is recorded");
    let reopened = resource(&mux, "closed.reopen", json!({"closed": group["id"]}), Some("re-1"));
    let reopened = &reopened["value"];
    assert_eq!(reopened["tab_ids"].as_array().unwrap().len(), 1, "{reopened}");
    let tabs = pane_tabs(&mux, pane);
    let back = tabs.into_iter().find(|surface| *surface != terminal).expect("a reopened tab");
    let tab = raw_tab(&mux, back).unwrap();
    assert_eq!(tab["kind"], "conversation", "{tab}");
    assert_eq!(tab["conversation"], json!({"conversation":"conv_01GROWTH","owner":"local"}));
    mux.shutdown();
}

/// A keyed creation replayed after its tab closed is refused and creates
/// nothing (idempotency survives the row deletion).
#[test]
fn keyed_conversation_tab_replay_after_close_is_refused() {
    let mux = test_mux("agent-tabs-replay");
    let (_, pane) = terminal_pane(&mux);
    let created = conversation_tab(&mux, pane, "replay-1").unwrap();
    run(&mux, json!({"cmd":"close-surface","surface":surface_of(&created)})).unwrap();
    let before = pane_tabs(&mux, pane);
    let error = conversation_tab(&mux, pane, "replay-1").unwrap_err();
    assert!(error.to_string().contains("closed"), "{error}");
    assert_eq!(pane_tabs(&mux, pane), before, "a refused replay creates nothing");
    mux.shutdown();
}
