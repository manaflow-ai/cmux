//! A Cloud chat start's workspace (the app's `CloudStartChat`, 2026-11-10): `create-workspace` with a caller key,
//! then `new-conversation-tab {workspace}`. The workspace holds the chat tab only: neither command makes a
//! terminal (no starter shell beside the chat). A terminal the person opens there later is created and listed.

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

/// Every tab of the workspace keyed `key`, in screen and pane order.
fn workspace_tabs(mux: &Arc<Mux>, key: &str) -> Vec<SurfaceId> {
    mux.with_state(|state| {
        let workspace = state.workspaces.iter().find(|workspace| workspace.key == key).unwrap();
        let mut panes = Vec::new();
        for screen in &workspace.screens {
            screen.root.pane_ids(&mut panes);
        }
        panes
            .iter()
            .filter_map(|pane| state.panes.get(pane))
            .flat_map(|pane| pane.tabs.clone())
            .collect()
    })
}

#[test]
fn a_chat_start_workspace_holds_only_the_chat_and_a_later_terminal_shows() {
    let mux = Mux::new_for_test("conversation-tab-chat-only", crate::SurfaceOptions::default());
    let key = "5f0c1d2e-3a4b-5c6d-8e7f-0a1b2c3d4e5f";
    let created = run(&mux, json!({"cmd":"create-workspace","key":key})).unwrap();
    assert!(workspace_tabs(&mux, key).is_empty(), "create-workspace made a tab: {created}");

    let chat = run(
        &mux,
        json!({"cmd":"new-conversation-tab","workspace":created["workspace"],
                                "origin":"chat-only-test","mutation_id":"cloud-start-k1",
                                "agent_session":{"host":"registry:s-vm","harness":"claude"}}),
    )
    .unwrap();
    let chat = chat["surface"].as_u64().unwrap();
    assert_eq!(
        workspace_tabs(&mux, key),
        [chat],
        "the chat's workspace has a starter terminal beside the chat"
    );
    let terminals = run(&mux, json!({"cmd":"list-terminals"})).unwrap();
    assert_eq!(
        terminals["terminals"].as_array().map(Vec::len),
        Some(0),
        "the start made a terminal: {terminals}"
    );

    // The person opens a terminal there later: it is made and listed with the chat.
    let terminal =
        run(&mux, json!({"cmd":"create-terminal","key":key,"cols":80,"rows":24})).unwrap();
    let terminal = terminal["surface"].as_u64().unwrap();
    let tabs = workspace_tabs(&mux, key);
    assert!(tabs.contains(&chat) && tabs.contains(&terminal) && tabs.len() == 2, "{tabs:?}");
    mux.shutdown();
}
