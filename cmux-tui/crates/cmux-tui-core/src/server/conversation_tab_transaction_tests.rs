//! `conversation-tab-transaction-v1`: `new-conversation-tab {transaction}`
//! echoes the client's transaction on the raw `tab-added` delta of the tab it
//! creates and in its result, so the app replaces its provisional tab on
//! whichever arrives first. A keyed replay echoes it in the result only.

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn added_transaction(events: &crate::MuxEventReceiver, surface: SurfaceId) -> Option<String> {
    std::iter::from_fn(|| events.try_recv().ok()).find_map(|event| match event {
        MuxEvent::TreeDelta(delta)
            if delta.kind == TreeDeltaKind::TabAdded && delta.surface == Some(surface) =>
        {
            delta.transaction.map(|transaction| transaction.to_string())
        }
        _ => None,
    })
}

#[test]
fn new_conversation_tab_echoes_the_transaction_on_tab_added() {
    let mux = Mux::new_for_test("conversation-tab-transaction", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let request = json!({"cmd":"new-conversation-tab","pane":pane,
                         "agent_session":{"host":"install:mac-test"},
                         "origin":"echo-test","mutation_id":"tab-1","transaction":"txn-agent-1"});
    let events = mux.subscribe();
    let created = run(&mux, request.clone()).unwrap();
    let surface = created["surface"].as_u64().unwrap();
    assert_eq!(created["transaction"], "txn-agent-1", "{created}");
    assert_eq!(added_transaction(&events, surface).as_deref(), Some("txn-agent-1"));

    // A keyed replay echoes the transaction in its result and emits nothing.
    let replay = run(&mux, request).unwrap();
    assert_eq!(
        (replay["replayed"].as_bool(), replay["surface"].as_u64()),
        (Some(true), Some(surface))
    );
    assert_eq!(replay["transaction"], "txn-agent-1", "{replay}");
    assert_eq!(added_transaction(&events, surface), None, "a replay adds no tab");

    let bad = json!({"cmd":"new-conversation-tab","pane":pane,
                     "agent_session":{"host":"install:mac-test"},"transaction":""});
    let error = run(&mux, bad).unwrap_err().to_string();
    assert!(error.contains("bad request"), "{error}");
    mux.shutdown();
}
