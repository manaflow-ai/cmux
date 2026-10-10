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
    handle_command(mux, mux.local_test_client(0), command, &writer)
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

fn test_mux_for_conversation_tabs() -> Arc<Mux> {
    Mux::new_for_test("conversation-tabs", crate::SurfaceOptions::default())
}
