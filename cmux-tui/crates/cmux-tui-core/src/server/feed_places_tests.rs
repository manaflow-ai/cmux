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
