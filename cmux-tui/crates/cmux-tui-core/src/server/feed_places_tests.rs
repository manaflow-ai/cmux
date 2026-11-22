//! Feed rows name the workspace, tab and agent of an item's context ids
//! (feed_places.rs).

use super::super::*;
use cmux_feed_core::client::{FeedItem, Poster, Row};

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

/// An item posted by `api-hook` with `context`.
fn item(context: Value) -> FeedItem {
    let mut item = FeedItem::notice("fi_place", "Allow Bash?", Poster::new("hook", "api-hook"), 1);
    item.context = context.as_object().cloned().unwrap();
    item
}

/// (who, where) of the item's row against the mux's places now.
fn row(mux: &Arc<Mux>, context: Value) -> (Option<String>, Option<String>) {
    let item = item(context);
    let places = mux.feed_places();
    let row = Row::of(&item, places(&item).as_ref());
    (row.who, row.place)
}

/// A workspace `api` with a terminal tab named `server`; returns the
/// terminal surface, its pane and its ids (`ws_…`, `tab_…`, `term_…`).
fn named_terminal(mux: &Arc<Mux>) -> (SurfaceId, PaneId, String, String, String) {
    let terminal = mux.new_workspace(Some("api".into()), None).unwrap();
    let surface = terminal.id;
    run(mux, json!({"cmd":"rename-surface","surface":surface,"name":"server"})).unwrap();
    let (pane, workspace, tab) = mux.with_state(|state| {
        let pane = state.pane_of(surface).unwrap();
        let (workspace, _) = state.screen_of(pane).unwrap();
        (
            pane,
            state.workspaces[workspace].public_id.as_str().to_owned(),
            state.resource_indexes.tab_ids[&surface].as_str().to_owned(),
        )
    });
    let term = match &terminal.resource_identity().unwrap().content_id {
        ContentPublicId::Terminal(id) => id.as_str().to_owned(),
        ContentPublicId::Browser(_) => panic!("a new workspace starts with a terminal"),
    };
    (surface, pane, workspace, tab, term)
}

#[test]
fn a_terminal_item_names_its_workspace_and_tab() {
    let mux = Mux::new_for_test("feed-places-terminal", crate::SurfaceOptions::default());
    let (surface, _, workspace, tab, term) = named_terminal(&mux);
    // The poster stays the `who` of a terminal tab (it has no harness).
    let poster = Some("api-hook".to_owned());
    let expected = (poster.clone(), Some("api › server".to_owned()));
    assert_eq!(row(&mux, json!({"terminal": term})), expected);
    assert_eq!(row(&mux, json!({"tab": tab})), expected);
    assert_eq!(row(&mux, json!({"tab": surface.to_string()})), expected);
    // A tab id that resolves wins over a workspace id; the workspace alone
    // names the workspace.
    assert_eq!(row(&mux, json!({"workspace": "ws_unknown", "terminal": term})), expected);
    assert_eq!(row(&mux, json!({"workspace": workspace})), (poster, Some("api".to_owned())));
    // A rename shows on the next read.
    run(&mux, json!({"cmd":"rename-surface","surface":surface,"name":"logs"})).unwrap();
    assert_eq!(row(&mux, json!({"terminal": term})).1.as_deref(), Some("api › logs"));
    mux.shutdown();
}

#[test]
fn an_agent_session_item_names_the_harness() {
    let mux = Mux::new_for_test("feed-places-agent", crate::SurfaceOptions::default());
    let (_, pane, _, _, _) = named_terminal(&mux);
    let created = run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:mac-test","session":"sess-feed","harness":"claude"}}),
    )
    .unwrap();
    let chat = created["surface"].as_u64().unwrap();
    run(&mux, json!({"cmd":"rename-surface","surface":chat,"name":"Feed perf"})).unwrap();
    assert_eq!(
        row(&mux, json!({"acp_session": "sess-feed"})),
        (Some("Claude Code".to_owned()), Some("api › Feed perf".to_owned()))
    );
    mux.shutdown();
}

#[test]
fn unknown_ids_name_nothing_and_the_row_names_the_poster() {
    let mux = Mux::new_for_test("feed-places-unknown", crate::SurfaceOptions::default());
    named_terminal(&mux);
    let context = json!({
        "host": "install:other-mac",
        "workspace": "ws_00000000000000000000000000000000",
        "tab": "tab_00000000000000000000000000000000",
        "terminal": "term_00000000000000000000000000000000",
        "acp_session": "sess-elsewhere",
    });
    let item = item(context.clone());
    assert_eq!(mux.feed_places()(&item), None);
    assert_eq!(row(&mux, context), (Some("api-hook".to_owned()), None));
    mux.shutdown();
}

/// The point lookups of a delta read (`feed_places_of`) name the same tab,
/// workspace and agent as the whole index, for every way an item names them.
#[test]
fn point_lookups_name_what_the_index_names() {
    let mux = Mux::new_for_test("feed-places-point", crate::SurfaceOptions::default());
    let (surface, pane, workspace, tab, term) = named_terminal(&mux);
    run(
        &mux,
        json!({"cmd":"new-conversation-tab","pane":pane,
               "agent_session":{"host":"install:mac-test","session":"sess-point","harness":"claude"}}),
    )
    .unwrap();
    let contexts = [
        json!({"terminal": term}),
        json!({"tab": tab}),
        json!({"tab": surface.to_string()}),
        json!({"workspace": workspace}),
        json!({"workspace": "ws_unknown", "terminal": term}),
        json!({"acp_session": "sess-point"}),
        json!({"acp_session": "sess-elsewhere"}),
        json!({"tab": "tab_00000000000000000000000000000000", "terminal": term}),
        json!({"tab": "tab_00000000000000000000000000000000"}),
    ];
    let whole = mux.feed_places();
    for context in contexts {
        let item = item(context.clone());
        let point = mux.feed_places_of(std::slice::from_ref(&item));
        assert_eq!(point(&item), whole(&item), "{context}");
    }
    mux.shutdown();
}

/// Detector (audit 2026-11-18 §15): a delta `feed.view.read` (`only`, the
/// ids a `feed-view-changed` carries) names only those items, with no pass
/// over every tab; a whole read makes one.
#[test]
fn a_delta_view_read_makes_no_pass_over_the_tabs() {
    let mux = Mux::new_for_test("feed-places-delta", crate::SurfaceOptions::default());
    let (_, _, _, _, term) = named_terminal(&mux);
    let feed = mux.feed_client();
    let posted = feed.post(item(json!({"terminal": term})));
    let read = |request: Value| {
        super::INDEX_BUILDS.with(|builds| builds.set(0));
        let view = feed.view(&serde_json::from_value(request).unwrap());
        (view, super::INDEX_BUILDS.with(std::cell::Cell::get))
    };
    let (_, whole) = read(json!({"layout": "list"}));
    assert_eq!(whole, 1, "a whole read builds the index once");
    let (view, delta) = read(json!({"layout": "list", "only": [posted.id]}));
    assert_eq!(delta, 0, "a delta read built the whole place index");
    let entry = &view["groups"][1]["entries"][0]["item"];
    assert_eq!(entry["row"]["where"], "api › server", "{view}");
    let (view, _) = read(json!({"layout": "list", "only": []}));
    assert_eq!(view["groups"][1]["entries"][0]["item"], json!({"id": posted.id, "same": true}));
    feed.shutdown();
    mux.shutdown();
}
