//! A tab or tab group moved to a new workspace stays in its space: the new
//! workspace takes the source workspace's room pin
//! (https://github.com/manaflow-ai/cmux/issues/42754).

use super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

/// The room `key` is pinned to on this daemon's own session, if any.
fn pin_of(mux: &Arc<Mux>, own: &str, key: &str) -> Option<String> {
    let personal = run(mux, json!({"cmd":"list-personal"})).unwrap();
    personal["pins"].as_array().unwrap().iter().find_map(|pin| {
        (pin["session_id"] == own && pin["workspace_key"] == key)
            .then(|| pin["profile"].as_str().unwrap().to_string())
    })
}

/// A workspace pinned to room "Work" with three tabs; returns the mux, this
/// daemon's session id, the source key and the tabs.
fn pinned_source(name: &str) -> (Arc<Mux>, String, String, [SurfaceId; 3]) {
    let mux = Mux::new_for_test(name, crate::SurfaceOptions::default());
    let own =
        run(&mux, json!({"cmd":"identify"})).unwrap()["registry_id"].as_str().unwrap().to_string();
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let second = mux.new_tab(Some(pane), None, None).unwrap().id;
    let third = mux.new_tab(Some(pane), None, None).unwrap().id;
    let key = mux.placed_workspace_key(first).expect("canonical workspace key");
    run(&mux, json!({"cmd":"create-profile","profile":"prof_work","name":"Work"})).unwrap();
    run(
        &mux,
        json!({"cmd":"pin-workspace","session_id":own,"workspace_key":key,"profile":"prof_work"}),
    )
    .unwrap();
    assert_eq!(pin_of(&mux, &own, &key).as_deref(), Some("prof_work"));
    (mux, own, key, [first, second, third])
}

#[test]
fn a_tab_moved_to_a_new_workspace_keeps_its_space() {
    let (mux, own, source, [_, _, tab]) = pinned_source("room-pin-tab-move");
    let moved = run(&mux, json!({"cmd":"move-tab-to-new-workspace","surface":tab})).unwrap();
    let key = moved["key"].as_str().unwrap().to_string();
    assert_ne!(key, source);
    assert_eq!(pin_of(&mux, &own, &key).as_deref(), Some("prof_work"), "{moved}");
    assert_eq!(pin_of(&mux, &own, &source).as_deref(), Some("prof_work"));
    mux.shutdown();
}

#[test]
fn a_tab_group_moved_to_a_new_workspace_keeps_its_space() {
    let (mux, own, source, [first, second, _]) = pinned_source("room-pin-group-move");
    let created =
        run(&mux, json!({"cmd":"create-tab-group","surfaces":[first, second],"name":"Build"}))
            .unwrap();
    let group = created["group"]["id"].as_str().unwrap().to_string();
    let moved = run(&mux, json!({"cmd":"move-tab-group-to-new-workspace","group":group})).unwrap();
    let key = mux.placed_workspace_key(first).unwrap();
    assert_ne!(key, source);
    assert_eq!(pin_of(&mux, &own, &key).as_deref(), Some("prof_work"), "{moved}");
    mux.shutdown();
}

/// An unpinned source pins nothing: the new workspace follows its session
/// like the source did.
#[test]
fn a_tab_from_an_unpinned_workspace_moves_without_a_pin() {
    let mux = Mux::new_for_test("room-pin-unpinned", crate::SurfaceOptions::default());
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let tab = mux.new_tab(Some(pane), None, None).unwrap().id;
    run(&mux, json!({"cmd":"move-tab-to-new-workspace","surface":tab})).unwrap();
    let personal = run(&mux, json!({"cmd":"list-personal"})).unwrap();
    assert_eq!(personal["pins"], json!([]));
    mux.shutdown();
}
