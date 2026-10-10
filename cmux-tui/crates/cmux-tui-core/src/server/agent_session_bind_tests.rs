//! `agent-session-tabs-v1`: the agent session bind is a compare-and-swap on
//! the tab's current session, concurrent binds commit at most once, and the
//! agent session source carries an optional host display name.

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

fn terminal_pane(mux: &Arc<Mux>) -> (SurfaceId, PaneId) {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    (terminal, mux.with_state(|state| state.pane_of(terminal)).unwrap())
}

fn agent_tab(mux: &Arc<Mux>, pane: PaneId) -> SurfaceId {
    let created = run(
        mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:mac-test","harness":"claude"}}),
    )
    .unwrap();
    created["surface"].as_u64().unwrap()
}

fn bind(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    session: &str,
    expected: Value,
) -> anyhow::Result<Value> {
    run(
        mux,
        json!({"cmd":"bind-conversation-tab-session","surface":surface,"session":session,
               "expected_session":expected}),
    )
}

fn revision(mux: &Arc<Mux>) -> u64 {
    mux.with_state(|state| state.resource_revision)
}

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

fn session_of(mux: &Arc<Mux>, surface: SurfaceId) -> Value {
    raw_tab(mux, surface).unwrap()["conversation"]["agent_session"]["session"].clone()
}

/// The bind applies when `expected_session` is the current session, so a
/// tab moves to a new session; another expectation names the current one.
#[test]
fn agent_session_bind_is_compare_and_swap() {
    let mux = test_mux("agent-bind-cas");
    let (_, pane) = terminal_pane(&mux);
    let surface = agent_tab(&mux, pane);

    let missing =
        run(&mux, json!({"cmd":"bind-conversation-tab-session","surface":surface,"session":"s-1"}));
    assert!(missing.is_err(), "expected_session is required: {missing:?}");

    let first = bind(&mux, surface, "s-1", Value::Null).unwrap();
    assert_eq!(first["replayed"], false, "{first}");
    assert_eq!(session_of(&mux, surface), "s-1");

    let swapped = bind(&mux, surface, "s-2", json!("s-1")).unwrap();
    assert_eq!(swapped["replayed"], false, "{swapped}");
    assert_eq!(swapped["conversation"]["agent_session"]["session"], "s-2");
    assert_eq!(session_of(&mux, surface), "s-2");

    for expected in [json!("s-1"), Value::Null] {
        let error = bind(&mux, surface, "s-3", expected.clone()).unwrap_err().to_string();
        assert!(error.starts_with("conversation_tab.session_conflict:"), "{expected}: {error}");
        assert!(error.contains("s-2"), "the conflict names the current session: {error}");
    }
    assert_eq!(session_of(&mux, surface), "s-2");

    let before = revision(&mux);
    let replay = bind(&mux, surface, "s-2", json!("s-2")).unwrap();
    assert_eq!(replay["replayed"], true, "{replay}");
    assert_eq!(revision(&mux), before, "a replay commits nothing");
    mux.shutdown();
}

/// Concurrent binds with one expectation: exactly one applies, the others
/// replay it or conflict, and the store commits once.
#[test]
fn concurrent_agent_session_binds_commit_once() {
    let mux = test_mux("agent-bind-race");
    let (_, pane) = terminal_pane(&mux);
    // The revisions one bind commits.
    let probe = agent_tab(&mux, pane);
    let before = revision(&mux);
    bind(&mux, probe, "probe", Value::Null).unwrap();
    let one_bind = revision(&mux) - before;
    assert!(one_bind > 0);

    let surface = agent_tab(&mux, pane);
    let before = revision(&mux);
    let threads = ["r-0", "r-0", "r-1", "r-1", "r-2", "r-2"]
        .into_iter()
        .map(|session| {
            let mux = mux.clone();
            std::thread::spawn(move || (session, bind(&mux, surface, session, Value::Null)))
        })
        .collect::<Vec<_>>();
    let results = threads.into_iter().map(|thread| thread.join().unwrap()).collect::<Vec<_>>();
    let applied = results
        .iter()
        .filter(|(_, result)| result.as_ref().is_ok_and(|value| value["replayed"] == false))
        .map(|(session, _)| *session)
        .collect::<Vec<_>>();
    assert_eq!(applied.len(), 1, "exactly one bind applies: {results:?}");
    let winner = applied[0];
    for (session, result) in &results {
        match result {
            Ok(value) if value["replayed"] == true => assert_eq!(*session, winner),
            Ok(_) => {}
            Err(error) => assert!(
                error.to_string().starts_with("conversation_tab.session_conflict:"),
                "{session}: {error}"
            ),
        }
    }
    assert_eq!(session_of(&mux, surface), winner);
    assert_eq!(revision(&mux) - before, one_bind, "the race commits exactly once");
    mux.shutdown();
}

/// `agent_session.host_name` round-trips through creation, the raw tree,
/// v2 `extra.conversation` and Reopen Closed; an invalid one is refused.
#[test]
fn agent_session_host_name_round_trips() {
    let mux = test_mux("agent-host-name");
    let (terminal, pane) = terminal_pane(&mux);
    let name = "Lawrence’s Mac mini";
    let created = run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:mac-test","session":"s-1","host_name":name}}),
    )
    .unwrap();
    assert_eq!(created["conversation"]["agent_session"]["host_name"], name, "{created}");
    let surface = created["surface"].as_u64().unwrap();
    let tab_id = created["tab_resource_id"].as_str().unwrap().to_string();
    assert_eq!(raw_tab(&mux, surface).unwrap()["conversation"]["agent_session"]["host_name"], name);
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let tab = snapshot["tabs"].as_array().unwrap().iter().find(|tab| tab["id"] == tab_id).unwrap();
    assert_eq!(tab["extra"]["conversation"]["agent_session"]["host_name"], name, "{tab}");

    run(&mux, json!({"cmd":"close-surface","surface":surface})).unwrap();
    let envelope = |operation: &str, params: Value, key: Option<&str>| {
        let mut params = params;
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":operation,
                                  "operation":operation,"params":params});
        if let Some(key) = key {
            envelope["idempotency_key"] = json!(key);
        }
        let response =
            crate::resource_router::handle_resource_message(&mux, &envelope.to_string()).unwrap();
        assert_eq!(response["ok"], true, "{operation}: {response}");
        response["result"].clone()
    };
    let closed = envelope("closed.list", json!({}), None);
    let group = closed.as_array().unwrap().first().cloned().expect("the close is recorded");
    envelope("closed.reopen", json!({"closed": group["id"]}), Some("host-name-reopen"));
    let back = mux
        .with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone()))
        .unwrap()
        .into_iter()
        .find(|tab| *tab != terminal)
        .expect("a reopened tab");
    let record = raw_tab(&mux, back).unwrap()["conversation"]["agent_session"].clone();
    assert_eq!(record["host_name"], name, "{record}");
    assert_eq!(record["session"], "s-1");

    for invalid in [json!(""), json!("a\nb"), json!("x".repeat(256))] {
        let error = run(
            &mux,
            json!({"cmd":"new-conversation-tab","pane":pane,
                   "agent_session":{"host":"install:mac-test","host_name":invalid}}),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("bad request"), "{invalid}: {error}");
    }
    mux.shutdown();
}
