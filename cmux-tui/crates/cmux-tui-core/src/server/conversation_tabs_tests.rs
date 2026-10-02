//! `conversation-tabs-v1`: creation, idempotent replay, the canonical kind
//! in storage, the per-connection `browser` projection, and the browser
//! refusals.

use super::super::*;

fn writer_with_outbound() -> (MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    (writer, outbound)
}

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let (writer, _) = writer_with_outbound();
    handle_command(mux, 0, command, &writer)
}

fn pane_with_terminal(mux: &Arc<Mux>) -> PaneId {
    let terminal = mux.new_workspace(None, None).unwrap().id;
    mux.with_state(|state| state.pane_of(terminal)).unwrap()
}

fn create(mux: &Arc<Mux>, pane: PaneId, key: &str, conversation: &str) -> anyhow::Result<Value> {
    run(
        mux,
        json!({"cmd":"new-conversation-tab","pane":pane,"conversation":conversation,
               "owner":"local","origin":"home-test","mutation_id":key}),
    )
}

fn raw_tab(tree: &Value, surface: u64) -> Value {
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().unwrap().iter())
        .flat_map(|screen| screen["panes"].as_array().unwrap().iter())
        .flat_map(|pane| pane["tabs"].as_array().unwrap().iter())
        .find(|tab| tab["surface"] == json!(surface))
        .cloned()
        .expect("the conversation tab is in the raw tree")
}

#[test]
fn conversation_tab_creation_replays_and_stores_the_canonical_kind() {
    let mux = test_mux_for_conversation_tabs();
    let pane = pane_with_terminal(&mux);
    let created = create(&mux, pane, "tab-1", "conv_01HOME").unwrap();
    assert_eq!(created["replayed"], false);
    assert_eq!(created["conversation"], json!({"conversation":"conv_01HOME","owner":"local"}));
    let surface = created["surface"].as_u64().unwrap();
    let tab_id = created["tab_resource_id"].as_str().unwrap().to_string();

    let replay = create(&mux, pane, "tab-1", "conv_01HOME").unwrap();
    assert_eq!(
        (replay["surface"].as_u64(), replay["replayed"].as_bool()),
        (Some(surface), Some(true))
    );
    let conflict = create(&mux, pane, "tab-1", "conv_02OTHER").unwrap_err();
    assert!(conflict.to_string().contains("idempotency.conflict"), "{conflict}");
    assert!(
        run(
            &mux,
            json!({"cmd":"new-conversation-tab","conversation":"conv_1","owner":"elsewhere"})
        )
        .is_err()
    );

    // Raw tree: canonical kind and the conversation record.
    let tree = run(&mux, json!({"cmd":"list-workspaces"})).unwrap();
    let tab = raw_tab(&tree, surface);
    assert_eq!(tab["kind"], "conversation");
    assert_eq!(tab["conversation"], json!({"conversation":"conv_01HOME","owner":"local"}));
    assert_eq!(tab["browser_renderer"], "frontend");

    // Resource API snapshot: canonical content kind and extra.conversation.
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let tab = snapshot["tabs"].as_array().unwrap().iter().find(|tab| tab["id"] == tab_id).unwrap();
    assert_eq!(tab["content_kind"], "conversation");
    assert_eq!(tab["extra"]["conversation"]["conversation"], "conv_01HOME");
    mux.shutdown();
}

#[test]
fn conversation_tab_refuses_browser_commands_and_operations() {
    let mux = test_mux_for_conversation_tabs();
    let pane = pane_with_terminal(&mux);
    let created = create(&mux, pane, "tab-2", "conv_01HOME").unwrap();
    let surface = created["surface"].as_u64().unwrap();
    let browser = created["content_resource_id"].as_str().unwrap().to_string();
    for request in [
        json!({"cmd":"browser-navigate","surface":surface,"url":"https://example.com"}),
        json!({"cmd":"browser-back","surface":surface}),
        json!({"cmd":"browser-insert-text","surface":surface,"text":"x"}),
    ] {
        let error = run(&mux, request.clone()).expect_err("a conversation tab is not a page");
        assert!(error.to_string().contains("conversation tab"), "{request}: {error}");
    }
    let envelope = json!({
        "protocol":"cmux.protocol/2","type":"request","id":"nav","operation":"browser.navigate",
        "idempotency_key":"nav-1",
        "params":{"machine":"current","session":"current","browser":browser,
                  "url":"https://example.com"},
    });
    let response =
        crate::resource_router::handle_resource_message(&mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], false, "{response}");
    assert_eq!(response["error"]["code"], "validation.invalid", "{response}");
    mux.shutdown();
}

#[test]
fn conversation_tab_projection_follows_the_connection_capability() {
    crate::state::conversation_tabs_store::mark_conversation_tabs_present();
    let message = json!({"tabs":[{"content_kind":"conversation"}],
                         "raw":[{"kind":"conversation","browser_renderer":"frontend"}],
                         "change":{"kind":"conversation"}});
    let (writer, outbound) = writer_with_outbound();
    writer.send_control(&message).unwrap();
    let downgraded: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(downgraded["tabs"][0]["content_kind"], "browser");
    assert_eq!(downgraded["raw"][0]["kind"], "browser");
    assert_eq!(downgraded["change"]["kind"], "conversation");

    let capabilities =
        [crate::state::conversation_tabs_store::CONVERSATION_TABS_CAPABILITY.to_string()];
    writer.negotiate_conversation_tabs(capabilities.iter());
    writer.send_control(&message).unwrap();
    let canonical: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(canonical["tabs"][0]["content_kind"], "conversation");
    assert_eq!(canonical["raw"][0]["kind"], "conversation");
}

/// A client that declares the capability through raw `set-client-info`
/// reads the canonical kind.
#[test]
fn conversation_tab_capability_is_accepted_by_set_client_info() {
    let mux = test_mux_for_conversation_tabs();
    let (writer, _) = writer_with_outbound();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients
        .set_info(client, None, None, Some(vec!["conversation-tabs-v1".to_string()]))
        .unwrap();
    assert!(mux.control_clients.supports_capability(client, "conversation-tabs-v1"));
    assert!(writer.conversation_tabs.load(Ordering::Acquire));
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|v| v == "conversation-tabs-v1")
    );
    mux.shutdown();
}

fn test_mux_for_conversation_tabs() -> Arc<Mux> {
    Mux::new_for_test("conversation-tabs", crate::SurfaceOptions::default())
}

fn resource(mux: &Arc<Mux>, operation: &str, params: Value) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let envelope = json!({"protocol":"cmux.protocol/2","type":"request","id":operation,
                          "operation":operation,"params":params});
    crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap()
}

/// A conversation tab's content is no browser: `browser.list` omits it,
/// `browser.get` and `update-frontend-browser-tab` refuse it.
#[test]
fn conversation_tab_is_not_listed_or_updated_as_a_browser() {
    let mux = test_mux_for_conversation_tabs();
    let pane = pane_with_terminal(&mux);
    let created = create(&mux, pane, "tab-3", "conv_01HOME").unwrap();
    let surface = created["surface"].as_u64().unwrap();
    let browser = created["content_resource_id"].as_str().unwrap().to_string();

    let listed = resource(&mux, "browser.list", json!({}));
    assert_eq!(listed["ok"], true, "{listed}");
    assert!(listed["result"].as_array().unwrap().iter().all(|item| item["id"] != browser.as_str()));
    let got = resource(&mux, "browser.get", json!({"browser":browser}));
    assert_eq!(got["error"]["code"], "validation.invalid", "{got}");

    let update = json!({"cmd":"update-frontend-browser-tab","surface":surface,
                        "url":"https://example.com"});
    let error = run(&mux, update).expect_err("a conversation tab never gets a page");
    assert!(error.to_string().contains("conversation tab"), "{error}");
    mux.shutdown();
}

/// The home workspace starts empty; a conversation tab sent to it by
/// workspace gets the workspace's first pane, and a keyed retry replays.
#[test]
fn conversation_tab_fills_the_empty_home_workspace() {
    let mux = test_mux_for_conversation_tabs();
    let _ = pane_with_terminal(&mux);
    let home = mux.state_ensure_home().unwrap().workspace_id;
    let workspace = mux.with_state(|state| {
        state.workspaces.iter().find(|item| item.public_id.as_str() == home).unwrap().id
    });
    let request = json!({"cmd":"new-conversation-tab","workspace":workspace,
                         "conversation":"conv_01CHIEF","owner":"local",
                         "origin":"cmux-next-home","mutation_id":"home-chief-tab"});
    let created = run(&mux, request.clone()).unwrap();
    let surface = created["surface"].as_u64().unwrap();
    let in_home = mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        state.screen_of(pane).map(|(index, _)| state.workspaces[index].id) == Some(workspace)
    });
    assert!(in_home, "the conversation tab is not in the home workspace");
    assert_eq!(run(&mux, request).unwrap()["replayed"], true);
    let both = json!({"cmd":"new-conversation-tab","workspace":workspace,"pane":1,
                      "conversation":"conv_01CHIEF","owner":"local"});
    assert!(run(&mux, both).is_err());
    mux.shutdown();
}
