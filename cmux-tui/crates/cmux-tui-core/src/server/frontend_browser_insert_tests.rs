//! `new-frontend-browser-tab {after}` (`frontend-browser-insert-after-v1`):
//! a link's new tab lands right after its opener (or the opener's last
//! child), as Chrome places it, instead of at the end of the strip. The
//! app names the slot; the daemon commits the tab there in one step, so
//! every client sees the same order without a later move.

use super::super::*;

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    let command: Command = serde_json::from_value(request)?;
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    handle_command(mux, mux.local_test_client(0), command, &writer)
}

fn tabs(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.tabs.clone())).unwrap_or_default()
}

fn active_tab(mux: &Mux, pane: PaneId) -> usize {
    mux.with_state(|state| state.panes.get(&pane).map(|pane| pane.active_tab)).unwrap()
}

/// A pane with three terminal tabs: `[opener, middle, last]`, the opener active.
fn pane_with_three_tabs(label: &str) -> (Arc<Mux>, PaneId, [SurfaceId; 3]) {
    let mux =
        Mux::new_for_test(format!("frontend-insert-{label}"), crate::SurfaceOptions::default());
    let opener = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(opener)).unwrap();
    let middle = mux.new_tab(Some(pane), None, None).unwrap().id;
    let last = mux.new_tab(Some(pane), None, None).unwrap().id;
    mux.select_tab(Some(pane), Some(0), None);
    (mux, pane, [opener, middle, last])
}

fn open_after(mux: &Arc<Mux>, pane: PaneId, after: SurfaceId, activate: bool) -> SurfaceId {
    let created = run(
        mux,
        json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"https://a.test/","engine":"webkit",
               "activate":activate,"after":after}),
    )
    .unwrap();
    created["surface"].as_u64().unwrap()
}

/// Three Cmd-clicks: each tab goes right after the previous child, so the
/// children sit right of the opener in click order.
#[test]
fn background_children_land_after_the_opener_in_click_order() {
    let (mux, pane, [opener, middle, last]) = pane_with_three_tabs("order");
    let first = open_after(&mux, pane, opener, false);
    let second = open_after(&mux, pane, first, false);
    let third = open_after(&mux, pane, second, false);
    assert_eq!(tabs(&mux, pane), vec![opener, first, second, third, middle, last]);
    assert_eq!(active_tab(&mux, pane), 0, "the opener stays active");
}

/// A foreground child goes right after the opener and becomes active.
#[test]
fn a_foreground_child_lands_after_the_opener_and_is_active() {
    let (mux, pane, [opener, middle, last]) = pane_with_three_tabs("foreground");
    let child = open_after(&mux, pane, opener, true);
    assert_eq!(tabs(&mux, pane), vec![opener, child, middle, last]);
    assert_eq!(active_tab(&mux, pane), 1);
}

/// A background tab put before the active tab keeps that tab active.
#[test]
fn a_background_tab_before_the_active_tab_keeps_it_active() {
    let (mux, pane, [opener, middle, last]) = pane_with_three_tabs("shift");
    mux.select_tab(Some(pane), Some(2), None);
    let child = open_after(&mux, pane, opener, false);
    assert_eq!(tabs(&mux, pane), vec![opener, child, middle, last]);
    assert_eq!(active_tab(&mux, pane), 3, "`last` stays the active tab");
}

/// A tab that is not in the pane (closed, moved away) leaves the end.
#[test]
fn an_unknown_anchor_appends() {
    let (mux, pane, [opener, middle, last]) = pane_with_three_tabs("unknown");
    let child = open_after(&mux, pane, 999_999, false);
    assert_eq!(tabs(&mux, pane), vec![opener, middle, last, child]);
}

/// The slot after a group member that is not the group's last moves to the
/// end of the group's run: an ungrouped tab never splits a group.
#[test]
fn a_slot_inside_a_group_moves_to_the_end_of_the_run() {
    let (mux, pane, [opener, middle, last]) = pane_with_three_tabs("group");
    mux.create_tab_group(&[opener, middle], None, Some("green".into()), Some("g1".into()), None)
        .unwrap();
    let child = open_after(&mux, pane, opener, false);
    assert_eq!(tabs(&mux, pane), vec![opener, middle, child, last]);
}

/// The keyed (idempotent) creation takes the slot too.
#[test]
fn a_keyed_creation_takes_the_slot() {
    let (mux, pane, [opener, middle, last]) = pane_with_three_tabs("keyed");
    let created = run(
        &mux,
        json!({"cmd":"new-frontend-browser-tab","pane":pane,"url":"https://a.test/","engine":"webkit",
               "after":opener,"idempotency_key":"link-1"}),
    )
    .unwrap();
    let child = created["surface"].as_u64().unwrap();
    assert_eq!(tabs(&mux, pane), vec![opener, child, middle, last]);
}

#[test]
fn identify_advertises_frontend_browser_insert_after() {
    let mux = Mux::new_for_test("frontend-insert-identify", crate::SurfaceOptions::default());
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    let capabilities = identity["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|c| c == "frontend-browser-insert-after-v1"), "{identity}");
}
