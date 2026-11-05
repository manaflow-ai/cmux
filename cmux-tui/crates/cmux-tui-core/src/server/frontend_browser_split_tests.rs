//! `frontend-browser-tab-split-v1`: `new-frontend-browser-tab {pane, split}`
//! creates a frontend-rendered browser tab directly in a new pane split from
//! `pane`, in one `pane.split` commit and one `pane-added` delta. Opening a
//! link to the right (a terminal Cmd-click, a chat's PR link) used to be two
//! requests (`new-frontend-browser-tab` in the source pane, then
//! `move-tab-to-split`), so every client saw the page as a tab of the source
//! pane before it jumped right. These tests drive the raw command and read
//! every event the daemon emits.

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

fn split_request(pane: PaneId, direction: &str) -> Value {
    json!({"cmd":"new-frontend-browser-tab","pane":pane,
           "url":"https://github.com/manaflow-ai/cmux/pull/1","engine":"webkit",
           "split":{"direction":direction}})
}

fn with_fields(mut request: Value, extra: Value) -> Value {
    request.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
    request
}

const PANE_ID: &str = "pane_0123456789abcdef0123456789abcdef";
const SPLIT_ID: &str = "split_0123456789abcdef0123456789abcdef";

#[test]
fn frontend_browser_tab_split_capability_is_advertised() {
    assert!(advertised_capabilities(false).contains(&"frontend-browser-tab-split-v1"));
}

/// The split creates the frontend browser tab in a new pane in one
/// `pane-added` delta under the caller-minted pane id; the source pane never
/// lists the tab, and the tab is frontend-rendered (no CDP target).
#[test]
fn new_frontend_browser_tab_split_is_one_pane_added_delta() {
    let mux = Mux::new_for_test("frontend-browser-split", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let source = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let events = mux.subscribe();
    let request = with_fields(
        split_request(source, "right"),
        json!({"split":{"direction":"right","pane_id":PANE_ID,"split_id":SPLIT_ID}}),
    );
    let created = run(&mux, request).unwrap();
    let surface = created["surface"].as_u64().unwrap();
    assert_eq!(created["replayed"], false, "{created}");
    assert!(created["tab_resource_id"].is_string(), "{created}");

    let (deltas, changed) = tree_events(&events);
    assert_eq!(changed, 0, "no full tree change: clients get one delta");
    assert_eq!(deltas.len(), 1, "exactly one tree delta: {deltas:?}");
    let added = &deltas[0];
    assert_eq!(added.kind, TreeDeltaKind::PaneAdded, "{added:?}");
    let new_pane = added.pane.unwrap();
    assert_ne!(new_pane, source);
    assert_eq!(added.entity["resource_id"], PANE_ID, "the caller-minted pane id: {}", added.entity);
    let tabs = added.entity["tabs"].as_array().unwrap();
    assert_eq!(tabs.len(), 1, "the new pane holds only the tab: {}", added.entity);
    assert_eq!(tabs[0]["surface"], json!(surface));
    assert_eq!(tabs[0]["kind"], "browser", "{}", tabs[0]);

    // The source pane never listed the tab.
    assert_eq!(pane_tabs(&mux, source), vec![terminal]);
    assert_eq!(pane_tabs(&mux, new_pane), vec![surface]);
    let tab = mux.with_state(|state| state.surfaces.get(&surface).cloned()).unwrap();
    assert!(mux.is_frontend_browser_surface(&tab), "the tab is frontend-rendered");
    assert_eq!(
        mux.frontend_browser(&tab).map(|record| record.url),
        Some("https://github.com/manaflow-ai/cmux/pull/1".to_string())
    );
    let (layout, active_pane, split_ids) = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(source).unwrap();
        let screen = &state.workspaces[workspace].screens[screen];
        let split_ids = state
            .resource_indexes
            .splits
            .keys()
            .map(|id| id.as_str().to_string())
            .collect::<Vec<_>>();
        (screen.root.pane_ids_vec(), screen.active_pane, split_ids)
    });
    assert_eq!(layout, vec![source, new_pane], "right: the new pane is after the source");
    assert_eq!(active_pane, new_pane, "the new pane is the screen's active pane");
    assert!(split_ids.iter().any(|id| id == SPLIT_ID), "the caller-minted split id: {split_ids:?}");
    mux.shutdown();
}

/// A title reaches the split tab as on the non-split path, and only through
/// a `tab-changed` of the new tab: nothing lists the tab in the source pane.
#[test]
fn new_frontend_browser_tab_split_keeps_its_title() {
    let mux = Mux::new_for_test("frontend-browser-split-title", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let source = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let events = mux.subscribe();
    let request = with_fields(split_request(source, "right"), json!({"title":"PR 1"}));
    let surface = run(&mux, request).unwrap()["surface"].as_u64().unwrap();
    let (deltas, _) = tree_events(&events);
    assert_eq!(deltas[0].kind, TreeDeltaKind::PaneAdded, "{deltas:?}");
    for delta in &deltas[1..] {
        assert_eq!(delta.kind, TreeDeltaKind::TabChanged, "{delta:?}");
        assert_ne!(delta.pane, Some(source), "{delta:?}");
    }
    let tab = mux.with_state(|state| state.surfaces.get(&surface).cloned()).unwrap();
    assert_eq!(tab.as_browser().unwrap().title(), "PR 1");
    assert_eq!(pane_tabs(&mux, source), vec![terminal]);
    mux.shutdown();
}

/// `left` and `up` put the new pane before the source, in the same one delta.
#[test]
fn new_frontend_browser_tab_split_left_and_up_put_the_pane_first() {
    for direction in ["left", "up"] {
        let mux =
            Mux::new_for_test("frontend-browser-split-before", crate::SurfaceOptions::default());
        let terminal = mux.new_workspace(None, None).unwrap().id;
        let source = mux.with_state(|state| state.pane_of(terminal)).unwrap();
        let events = mux.subscribe();
        let surface =
            run(&mux, split_request(source, direction)).unwrap()["surface"].as_u64().unwrap();
        let (deltas, _) = tree_events(&events);
        assert_eq!(deltas.len(), 1, "{direction}: {deltas:?}");
        assert_eq!(deltas[0].kind, TreeDeltaKind::PaneAdded);
        let new_pane = deltas[0].pane.unwrap();
        assert_eq!(pane_tabs(&mux, new_pane), vec![surface]);
        assert_eq!(pane_tabs(&mux, source), vec![terminal]);
        let layout = mux.with_state(|state| {
            let (workspace, screen) = state.screen_of(source).unwrap();
            state.workspaces[workspace].screens[screen].root.pane_ids_vec()
        });
        assert_eq!(layout, vec![new_pane, source], "{direction}");
        mux.shutdown();
    }
}

/// A malformed split is a bad request and creates nothing: no pane, no tab
/// and no frontend browser record.
#[test]
fn malformed_frontend_browser_tab_splits_are_refused() {
    let mux = Mux::new_for_test("frontend-browser-split-bad", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let source = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let browser = |extra: Value| {
        with_fields(
            json!({"cmd":"new-frontend-browser-tab","url":"https://a.test/","engine":"webkit"}),
            extra,
        )
    };
    let refused = [
        browser(json!({"split":{"direction":"right"}})),
        browser(json!({"pane":source,"split":{"direction":"sideways"}})),
        browser(json!({"pane":source,"split":{"direction":"right","pane_id":"nope"}})),
        browser(json!({"pane":source,"split":{"direction":"right","split_id":"nope"}})),
        browser(json!({"pane":source,"split":{"direction":"right","extra":1}})),
        browser(json!({"pane":source,"split":{}})),
        browser(json!({"pane":source,"after":terminal,"split":{"direction":"right"}})),
    ];
    let panes = mux.with_state(|state| state.panes.len());
    let records = mux.presentation_snapshot().frontend_browsers.len();
    for request in refused {
        let Err(error) = run(&mux, request.clone()) else { panic!("{request} must be refused") };
        let message = format!("{error:#}");
        assert!(
            ["bad request", "unknown field", "missing field"].iter().any(|s| message.contains(s)),
            "{request}: {message}"
        );
        assert_eq!(mux.with_state(|state| state.panes.len()), panes, "{request} created a pane");
        assert_eq!(pane_tabs(&mux, source), vec![terminal], "{request} created a tab");
        assert_eq!(
            mux.presentation_snapshot().frontend_browsers.len(),
            records,
            "{request} registered a browser"
        );
    }
    mux.shutdown();
}

/// With `idempotency_key` a retry returns the split's tab and emits nothing;
/// the key names its split, so the same key with another side, or without
/// the split, is `idempotency.conflict`.
#[test]
fn keyed_frontend_browser_tab_split_replays_and_names_its_split() {
    let mux = Mux::new_for_test("frontend-browser-split-keyed", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let source = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let keyed = |direction: &str| {
        with_fields(
            split_request(source, direction),
            json!({"idempotency_key":"split-key-1",
                   "split":{"direction":direction,"pane_id":PANE_ID}}),
        )
    };
    let events = mux.subscribe();
    let created = run(&mux, keyed("right")).unwrap();
    let surface = created["surface"].as_u64().unwrap();
    assert_eq!(created["replayed"], false, "{created}");
    let (deltas, _) = tree_events(&events);
    assert_eq!(deltas.len(), 1, "{deltas:?}");
    assert_eq!(deltas[0].kind, TreeDeltaKind::PaneAdded);
    let new_pane = deltas[0].pane.unwrap();

    let replay = run(&mux, keyed("right")).unwrap();
    assert_eq!(
        (replay["replayed"].as_bool(), replay["surface"].as_u64()),
        (Some(true), Some(surface)),
        "{replay}"
    );
    let (deltas, changed) = tree_events(&events);
    assert!(deltas.is_empty() && changed == 0, "a replay changes nothing: {deltas:?}");
    assert_eq!(pane_tabs(&mux, source), vec![terminal]);
    assert_eq!(pane_tabs(&mux, new_pane), vec![surface]);

    let error = run(&mux, keyed("down")).unwrap_err().to_string();
    assert!(error.contains("idempotency.conflict"), "{error}");
    let mut unsplit = keyed("right");
    unsplit.as_object_mut().unwrap().remove("split");
    let error = run(&mux, unsplit).unwrap_err().to_string();
    assert!(error.contains("idempotency.conflict"), "{error}");
    assert_eq!(pane_tabs(&mux, source), vec![terminal]);
    mux.shutdown();
}

/// `pinned-dock-alone-v1`: a split right of Home's pinned dock with nothing
/// beside it opens a new column right of the dock, as wide as a link Home
/// opens there; the dock keeps its pin, width and only tab.
#[test]
fn a_frontend_browser_split_right_of_a_lone_pinned_dock_is_a_new_column_beside_it() {
    let mux = Mux::new_for_test("frontend-browser-split-lone", crate::SurfaceOptions::default());
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
    let created = run(&mux, split_request(dock, "right")).unwrap();
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
    mux.shutdown();
}
