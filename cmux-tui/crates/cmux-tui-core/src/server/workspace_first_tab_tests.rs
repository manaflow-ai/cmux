//! `workspace-first-tab-v1` and `frontend-browser-tab-workspace-v1`: a
//! workspace and its first browser tab in one request. A new browser
//! workspace used to be four requests (`create-workspace`, `create-terminal`,
//! `new-frontend-browser-tab` in the terminal's pane, `close-tab` of the
//! terminal), so every client saw a terminal first, the terminal took focus,
//! and a failed last step left it there for good (Lawrence 2026-11-10: "I
//! make a new browser workspace and then it makes a new terminal"). These
//! tests drive the raw commands and read every event the daemon emits.

use super::super::*;
use crate::TreeDelta;

const KEY: &str = "018f6e21-7b70-7e70-8000-0000000000b1";
const URL: &str = "https://example.com/first";

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn tree_deltas(events: &crate::MuxEventReceiver) -> Vec<TreeDelta> {
    let mut deltas = Vec::new();
    while let Ok(event) = events.try_recv() {
        if let MuxEvent::TreeDelta(delta) = event {
            deltas.push(delta);
        }
    }
    deltas
}

fn create_request() -> Value {
    json!({"cmd":"create-workspace","name":"web","key":KEY,
           "origin":"cmux-next","mutation_id":"first-tab-create",
           "first_tab":{"kind":"browser","url":URL,"engine":"webkit",
                        "idempotency_key":"first-tab-key"}})
}

/// Every surface the daemon holds, and whether each is a frontend browser.
fn surfaces(mux: &Arc<Mux>) -> Vec<(SurfaceId, bool)> {
    let all = mux.with_state(|state| state.surfaces.values().cloned().collect::<Vec<_>>());
    all.iter().map(|surface| (surface.id, mux.is_frontend_browser_surface(surface))).collect()
}

#[test]
fn first_tab_capabilities_are_advertised() {
    let advertised = advertised_capabilities(false);
    assert!(advertised.contains(&"workspace-first-tab-v1"));
    assert!(advertised.contains(&"frontend-browser-tab-workspace-v1"));
}

/// One `create-workspace {first_tab}` makes the workspace with its browser
/// tab: no terminal exists at any point, and no delta ever lists one.
#[test]
fn one_request_creates_a_browser_workspace_with_no_terminal() {
    let mux = Mux::new_for_test("workspace-first-tab", crate::SurfaceOptions::default());
    let events = mux.subscribe();
    let created = run(&mux, create_request()).unwrap();
    assert_eq!(created["key"], KEY, "{created}");
    let surface = created["first_tab"]["surface"]
        .as_u64()
        .unwrap_or_else(|| panic!("the reply names the first tab: {created}"));
    assert_eq!(created["first_tab"]["replayed"], false, "{created}");

    assert_eq!(
        surfaces(&mux),
        vec![(surface, true)],
        "the workspace's one surface is its browser tab"
    );
    let tab = mux.with_state(|state| state.surfaces.get(&surface).cloned()).unwrap();
    assert_eq!(mux.frontend_browser(&tab).map(|record| record.url), Some(URL.to_string()));
    let pane = mux.with_state(|state| state.pane_of(surface)).expect("the tab is in a pane");
    let (workspace_key, tabs) = mux.with_state(|state| {
        let (workspace, _) = state.screen_of(pane).unwrap();
        (state.workspaces[workspace].key.to_string(), state.panes[&pane].tabs.clone())
    });
    assert_eq!(workspace_key, KEY, "the tab is in the workspace the request made");
    assert_eq!(tabs, vec![surface]);
    for delta in tree_deltas(&events) {
        assert!(
            !delta.entity.to_string().contains("\"kind\":\"terminal\""),
            "a delta listed a terminal: {}",
            delta.entity
        );
    }
    mux.shutdown();
}

/// A first tab that cannot be made takes the workspace back: no caller is
/// left with an empty workspace to repair.
#[test]
fn a_refused_first_tab_leaves_no_workspace() {
    let mux = Mux::new_for_test("workspace-first-tab-refused", crate::SurfaceOptions::default());
    let mut request = create_request();
    request["first_tab"]["engine"] = json!("");
    let error = run(&mux, request).unwrap_err();
    assert!(mux.with_state(|state| state.workspaces.is_empty()), "the workspace stayed: {error:#}");
    assert!(surfaces(&mux).is_empty());

    // A first tab that names a place of its own is refused before anything is made.
    let mut request = create_request();
    request["first_tab"]["after"] = json!(1);
    let error = run(&mux, request).unwrap_err();
    assert!(error.to_string().contains("first_tab"), "{error:#}");
    assert!(mux.with_state(|state| state.workspaces.is_empty()));
    mux.shutdown();
}

/// A retry after a lost reply (same mutation, same tab key) answers the same
/// workspace and tab, and makes nothing new.
#[test]
fn a_replayed_create_replays_its_first_tab() {
    let mux = Mux::new_for_test("workspace-first-tab-replay", crate::SurfaceOptions::default());
    let first = run(&mux, create_request()).unwrap();
    let again = run(&mux, create_request()).unwrap();
    assert_eq!(again["replayed"], true, "{again}");
    assert_eq!(again["first_tab"]["surface"], first["first_tab"]["surface"], "{again}");
    assert_eq!(again["first_tab"]["replayed"], true, "{again}");
    assert_eq!(surfaces(&mux).len(), 1, "one tab after the replay");
    assert_eq!(mux.with_state(|state| state.workspaces.len()), 1);
    mux.shutdown();
}

/// `new-frontend-browser-tab {workspace}` is the first tab of an empty
/// workspace that is not the active one, and is refused with `pane`.
#[test]
fn a_browser_tab_targets_a_workspace() {
    let mux = Mux::new_for_test("frontend-browser-workspace", crate::SurfaceOptions::default());
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let source = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let empty = run(&mux, json!({"cmd":"create-workspace","key":KEY})).unwrap();
    let workspace = empty["workspace"].clone();

    let both = run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","pane":source,"workspace":workspace,
                                "url":URL,"engine":"webkit"}),
    );
    assert!(both.is_err(), "pane and workspace together are a bad request");

    let created = run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","workspace":workspace,
                                   "url":URL,"engine":"webkit"}),
    )
    .unwrap();
    let surface = created["surface"].as_u64().unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface)).unwrap();
    assert_ne!(pane, source, "the tab is not in the active workspace's pane");
    let key = mux.with_state(|state| {
        let (workspace, _) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].key.to_string()
    });
    assert_eq!(key, KEY);
    assert_eq!(
        mux.with_state(|state| state.panes[&source].tabs.clone()),
        vec![terminal],
        "the active workspace's pane never listed the tab"
    );
    mux.shutdown();
}
