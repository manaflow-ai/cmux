//! `conversation-tab-split-v1`: `new-conversation-tab {pane, split}` is one
//! gesture, one store transaction and one tree delta. A person's Cmd-D from a
//! New Tab page used to be two operations (a tab in the source pane, then a
//! move to a new split), so every client saw the tab in the source pane's
//! strip, saw it leave, and then saw the split (Lawrence 2026-10-17). These
//! tests drive the raw command and read every event the daemon emits.

use super::super::*;
use crate::TreeDelta;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

/// Every tree delta and full tree change emitted so far.
fn tree_events(events: &crate::MuxEventReceiver) -> (Vec<TreeDelta>, usize) {
    let mut deltas = Vec::new();
    let mut changed = 0;
    while let Ok(event) = events.try_recv() {
        match event {
            MuxEvent::TreeDelta(delta) => deltas.push(delta),
            MuxEvent::TreeChanged => changed += 1,
            _ => {}
        }
    }
    (deltas, changed)
}

fn pane_tabs(mux: &Arc<Mux>, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone()).unwrap_or_default())
}

fn split_request(pane: PaneId, direction: &str, pane_id: &str) -> Value {
    json!({"cmd":"new-conversation-tab","pane":pane,
           "agent_session":{"host":"install:mac-test"},
           "origin":"split-test","mutation_id":"split-1","transaction":"txn-split-1",
           "split":{"direction":direction,"pane_id":pane_id}})
}

#[test]
fn conversation_tab_split_capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&"conversation-tab-split-v1"));
}

/// The split creates the tab in a new pane in one `pane-added` delta that
/// carries the client transaction; the source pane never lists the tab, and
/// a keyed replay returns the same tab and emits nothing.
#[test]
fn new_conversation_tab_split_is_one_pane_added_delta() {
    let mux = Mux::new_for_test("conversation-tab-split", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let source = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let pane_id = "pane_0123456789abcdef0123456789abcdef";
    let request = split_request(source, "right", pane_id);
    let events = mux.subscribe();
    let created = run(&mux, request.clone()).unwrap();
    let surface = created["surface"].as_u64().unwrap();
    assert_eq!(created["transaction"], "txn-split-1", "{created}");
    assert_eq!(created["replayed"], false, "{created}");

    let (deltas, changed) = tree_events(&events);
    assert_eq!(changed, 0, "no full tree change: clients get one delta");
    assert_eq!(deltas.len(), 1, "exactly one tree delta: {deltas:?}");
    let added = &deltas[0];
    assert_eq!(added.kind, TreeDeltaKind::PaneAdded, "{added:?}");
    assert_eq!(
        added.transaction.as_deref(),
        Some("txn-split-1"),
        "the delta echoes the transaction"
    );
    let new_pane = added.pane.unwrap();
    assert_ne!(new_pane, source);
    assert_eq!(added.entity["resource_id"], pane_id, "the caller-minted pane id: {}", added.entity);
    let tabs = added.entity["tabs"].as_array().unwrap();
    assert_eq!(tabs.len(), 1, "the new pane holds only the tab: {}", added.entity);
    assert_eq!(tabs[0]["surface"], json!(surface));
    assert_eq!(tabs[0]["kind"], "conversation", "{}", tabs[0]);

    // The source pane never listed the tab.
    assert_eq!(pane_tabs(&mux, source), vec![terminal]);
    assert_eq!(pane_tabs(&mux, new_pane), vec![surface]);
    assert!(
        mux.with_state(|state| state.surfaces.get(&surface).cloned())
            .and_then(|tab| mux.conversation_tab_of(&tab))
            .is_some(),
        "the tab keeps its conversation record"
    );
    let (layout, screen_panes) = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(source).unwrap();
        let screen = &state.workspaces[workspace].screens[screen];
        (screen.root.pane_ids_vec(), screen.active_pane)
    });
    assert_eq!(layout, vec![source, new_pane], "right: the new pane is after the source");
    assert_eq!(screen_panes, new_pane, "the new pane is the screen's active pane");

    // A keyed replay returns the same tab and emits nothing.
    let replay = run(&mux, request).unwrap();
    assert_eq!(
        (replay["replayed"].as_bool(), replay["surface"].as_u64()),
        (Some(true), Some(surface)),
        "{replay}"
    );
    assert_eq!(replay["transaction"], "txn-split-1", "{replay}");
    let (deltas, changed) = tree_events(&events);
    assert!(deltas.is_empty() && changed == 0, "a replay changes nothing: {deltas:?}");
    assert_eq!(pane_tabs(&mux, source), vec![terminal]);

    // The key names its split: the same key with another side is refused.
    let error = run(&mux, split_request(source, "down", pane_id)).unwrap_err().to_string();
    assert!(error.contains("idempotency.conflict"), "{error}");
    // And the same key without the split is another target.
    let mut unsplit = split_request(source, "right", pane_id);
    unsplit.as_object_mut().unwrap().remove("split");
    let error = run(&mux, unsplit).unwrap_err().to_string();
    assert!(error.contains("idempotency.conflict"), "{error}");
    mux.shutdown();
}

/// `left` and `up` put the new pane before the source, in the same one delta.
#[test]
fn new_conversation_tab_split_left_and_up_put_the_pane_first() {
    for direction in ["left", "up"] {
        let mux =
            Mux::new_for_test("conversation-tab-split-before", crate::SurfaceOptions::default());
        let terminal = mux.new_workspace(None, None).unwrap().id;
        let source = mux.with_state(|state| state.pane_of(terminal)).unwrap();
        let events = mux.subscribe();
        let request = json!({"cmd":"new-conversation-tab","pane":source,"page":"settings",
                             "split":{"direction":direction}});
        let surface = run(&mux, request).unwrap()["surface"].as_u64().unwrap();
        let (deltas, _) = tree_events(&events);
        assert_eq!(deltas.len(), 1, "{direction}: {deltas:?}");
        assert_eq!(deltas[0].kind, TreeDeltaKind::PaneAdded);
        let new_pane = deltas[0].pane.unwrap();
        assert_eq!(pane_tabs(&mux, new_pane), vec![surface]);
        let layout = mux.with_state(|state| {
            let (workspace, screen) = state.screen_of(source).unwrap();
            state.workspaces[workspace].screens[screen].root.pane_ids_vec()
        });
        assert_eq!(layout, vec![new_pane, source], "{direction}");
        mux.shutdown();
    }
}

/// A malformed split is a bad request and creates nothing.
#[test]
fn malformed_conversation_tab_splits_are_refused() {
    let mux = Mux::new_for_test("conversation-tab-split-bad", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let source = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    let page = |extra: Value| {
        let mut request = json!({"cmd":"new-conversation-tab","page":"settings"});
        request.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        request
    };
    let refused = [
        page(json!({"split":{"direction":"right"}})),
        page(json!({"pane":source,"split":{"direction":"sideways"}})),
        page(json!({"pane":source,"split":{"direction":"right","pane_id":"nope"}})),
        page(json!({"pane":source,"split":{"direction":"right","extra":1}})),
        page(json!({"workspace":workspace,"split":{"direction":"right"}})),
    ];
    let panes = mux.with_state(|state| state.panes.len());
    for request in refused {
        assert!(run(&mux, request.clone()).is_err(), "{request} must be refused");
        assert_eq!(mux.with_state(|state| state.panes.len()), panes, "{request} created a pane");
        assert_eq!(pane_tabs(&mux, source), vec![terminal], "{request} created a tab");
    }
    mux.shutdown();
}

/// `pinned-dock-alone-v1`: a split right of Home's pinned dock with nothing
/// beside it opens a new column right of the dock, as wide as a link Home
/// opens there; the dock keeps its pin, width and only tab.
#[test]
fn a_split_right_of_a_lone_pinned_dock_is_a_new_column_beside_it() {
    let mux = Mux::new_for_test("conversation-tab-split-lone", crate::SurfaceOptions::default());
    let home = mux.new_workspace(None, Some((80, 22))).unwrap().id;
    let dock = mux.with_state(|state| state.pane_of(home)).unwrap();
    let right = mux.new_pane_right(dock, 0.5, Some((38, 22))).unwrap().id;
    run(
        &mux,
        json!({"cmd":"set-column-dock","pane":dock,"dock":true,"edge":"left",
                     "role":"agent_chat","pinned":true}),
    )
    .unwrap();
    run(&mux, json!({"cmd":"close-surface","surface":right})).unwrap();
    let width = mux.with_state(|state| {
        let columns = &state.workspaces[0].screens[0].layout_columns;
        assert_eq!(columns.len(), 1, "the dock is alone");
        columns[0].width
    });
    let created =
        run(&mux, split_request(dock, "right", "pane_0123456789abcdef0123456789abcdef")).unwrap();
    let surface = created["surface"].as_u64().unwrap();
    let columns = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        screen
            .layout_columns
            .iter()
            .map(|column| (column.width, column.dock.is_some_and(|d| d.pinned)))
            .collect::<Vec<_>>()
    });
    assert_eq!(columns, vec![(width, true), (crate::mux::LONE_DOCK_NEIGHBOR_WIDTH, false)]);
    assert_eq!(pane_tabs(&mux, dock), vec![home], "the dock keeps only its tab");
    let beside = mux.with_state(|state| state.pane_of(surface)).unwrap();
    assert_ne!(beside, dock);
}
