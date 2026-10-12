//! A resource commit that adds or moves a tab sends the v1 tree delta that
//! delta clients (the Mac app) build their tree from: `tab-added` for a new
//! view, `tab-changed` naming the new pane and index for a moved one, and
//! `tree-changed` (a resync) for a change a tab delta cannot express.

use std::sync::Arc;

use crate::mux::{Mux, MuxEvent, TreeDelta, TreeDeltaKind};
use crate::workspace_registry::WorkspaceMutation;
use crate::{PaneId, ScreenId, SplitDir, SplitId, SurfaceId, SurfaceOptions};

/// One workspace with one pane holding `count` terminal tabs.
fn terminal_tabs(mux: &Arc<Mux>, count: usize) -> (PaneId, Vec<SurfaceId>) {
    let first = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let mut tabs = vec![first];
    for _ in 1..count {
        tabs.push(mux.new_tab(Some(pane), None, None).unwrap().id);
    }
    (pane, tabs)
}

fn tabs_of(mux: &Mux, pane: PaneId) -> Vec<SurfaceId> {
    mux.with_state(|state| state.panes[&pane].tabs.clone())
}

fn terminal_selectors(mux: &Mux, surface: SurfaceId) -> crate::ResourceSelectors {
    let terminal = mux.surface(surface).unwrap().terminal_public_id().unwrap().to_string();
    crate::ResourceSelectors { terminal: Some(terminal), ..Mux::ordinary_resource_selectors() }
}

fn tab_deltas(events: impl Iterator<Item = MuxEvent>) -> Vec<TreeDelta> {
    events
        .filter_map(|event| match event {
            MuxEvent::TreeDelta(delta)
                if matches!(delta.kind, TreeDeltaKind::TabAdded | TreeDeltaKind::TabChanged) =>
            {
                Some(delta)
            }
            _ => None,
        })
        .collect()
}

fn move_terminal(mux: &Arc<Mux>, surface: SurfaceId, pane: PaneId, index: usize) {
    mux.resource_move_terminal_selected(
        terminal_selectors(mux, surface),
        mux.resource_selectors_for_pane(Some(pane)).unwrap(),
        index,
        None,
        &WorkspaceMutation::daemon_local("resource-tab-deltas-test"),
    )
    .unwrap();
}

/// `terminal.project` into the middle of a pane: `tab-added` at the view's
/// index, carrying the tab entity.
#[test]
fn terminal_project_into_the_middle_of_a_pane_emits_tab_added_at_its_index() {
    let mux = Mux::new_for_test("tab-deltas-project", SurfaceOptions::default());
    let (pane, tabs) = terminal_tabs(&mux, 3);
    let events = mux.subscribe();

    mux.resource_project_terminal_selected(
        terminal_selectors(&mux, tabs[2]),
        mux.resource_selectors_for_pane(Some(pane)).unwrap(),
        1,
        None,
        None,
        &WorkspaceMutation::daemon_local("resource-tab-deltas-test"),
    )
    .unwrap();

    let after = tabs_of(&mux, pane);
    assert_eq!(after.len(), 4);
    let view = after[1];
    let deltas = tab_deltas(events.try_iter());
    assert_eq!(deltas.len(), 1, "one tab-added and nothing else: {deltas:?}");
    assert_eq!(deltas[0].kind, TreeDeltaKind::TabAdded);
    assert_eq!(deltas[0].surface, Some(view));
    assert_eq!(deltas[0].pane, Some(pane));
    assert_eq!(deltas[0].index, Some(1));
    assert_eq!(deltas[0].entity["surface"], view);
}

/// `terminal.move` inside its pane: one `tab-changed` for the moved tab at
/// its new index (the app reads that as a move inside the pane).
#[test]
fn terminal_move_inside_a_pane_emits_tab_changed_at_the_new_index() {
    let mux = Mux::new_for_test("tab-deltas-move-in-pane", SurfaceOptions::default());
    let (pane, tabs) = terminal_tabs(&mux, 3);
    let events = mux.subscribe();

    move_terminal(&mux, tabs[0], pane, 3);

    assert_eq!(tabs_of(&mux, pane), [tabs[1], tabs[2], tabs[0]]);
    let deltas = tab_deltas(events.try_iter());
    assert_eq!(deltas.len(), 1, "one tab-changed for the moved tab: {deltas:?}");
    assert_eq!(deltas[0].kind, TreeDeltaKind::TabChanged);
    assert_eq!(deltas[0].surface, Some(tabs[0]));
    assert_eq!(deltas[0].pane, Some(pane));
    assert_eq!(deltas[0].index, Some(2));
}

/// `terminal.move` to a pane of another workspace while its source pane
/// keeps other tabs: `tab-changed` naming the destination pane and index.
#[test]
fn terminal_move_to_another_pane_emits_tab_changed_naming_the_destination() {
    let mux = Mux::new_for_test("tab-deltas-move-across", SurfaceOptions::default());
    let (source, tabs) = terminal_tabs(&mux, 3);
    let (destination, others) = terminal_tabs(&mux, 2);
    let events = mux.subscribe();

    move_terminal(&mux, tabs[1], destination, 1);

    assert_eq!(tabs_of(&mux, source), [tabs[0], tabs[2]]);
    assert_eq!(tabs_of(&mux, destination), [others[0], tabs[1], others[1]]);
    let deltas = tab_deltas(events.try_iter());
    assert_eq!(deltas.len(), 1, "one tab-changed for the moved tab: {deltas:?}");
    assert_eq!(deltas[0].kind, TreeDeltaKind::TabChanged);
    assert_eq!(deltas[0].surface, Some(tabs[1]));
    assert_eq!(deltas[0].pane, Some(destination));
    assert_eq!(deltas[0].index, Some(1));
}

/// `tab.move` inside a pane (the topology op behind `move-tab` and the
/// reopen's index restore): `tab-changed` for the moved tab.
#[test]
fn tab_move_inside_a_pane_emits_tab_changed_at_the_new_index() {
    let mux = Mux::new_for_test("tab-deltas-tab-move", SurfaceOptions::default());
    let (pane, tabs) = terminal_tabs(&mux, 3);
    let events = mux.subscribe();

    assert!(mux.move_tab(tabs[2], pane, 0));

    assert_eq!(tabs_of(&mux, pane), [tabs[2], tabs[0], tabs[1]]);
    let deltas = tab_deltas(events.try_iter());
    assert_eq!(deltas.len(), 1, "one tab-changed for the moved tab: {deltas:?}");
    assert_eq!(deltas[0].kind, TreeDeltaKind::TabChanged);
    assert_eq!(deltas[0].surface, Some(tabs[2]));
    assert_eq!(deltas[0].pane, Some(pane));
    assert_eq!(deltas[0].index, Some(0));
}

/// `terminal.move` of a pane's only tab closes that pane, which no tab
/// delta expresses: the commit sends `tree-changed` so delta clients
/// resync.
#[test]
fn terminal_move_that_empties_its_pane_emits_tree_changed() {
    let mux = Mux::new_for_test("tab-deltas-move-structural", SurfaceOptions::default());
    let (_, lonely) = terminal_tabs(&mux, 1);
    let (destination, _) = terminal_tabs(&mux, 2);
    let events = mux.subscribe();

    move_terminal(&mux, lonely[0], destination, 0);

    assert_eq!(tabs_of(&mux, destination)[0], lonely[0]);
    assert!(
        events.try_iter().any(|event| matches!(event, MuxEvent::TreeChanged)),
        "a structural move resyncs delta clients"
    );
}

/// An ordinary tab move between panes keeps the split index (moved from
/// mux.rs, which is at its godfile budget) and sends the adopted tab's
/// `tab-changed` before one `tree-changed`.
#[test]
fn ordinary_tab_moves_do_not_rebuild_the_split_index() {
    let mux = Mux::new_for_test("tab-deltas-split-index", SurfaceOptions::default());
    let first = mux.new_workspace(None, None).unwrap();
    let first_pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(first_pane, SplitDir::Right, None).unwrap();
    let second_pane = mux.with_state(|state| state.pane_of(second.id).unwrap());
    let extra = mux.new_tab(Some(first_pane), None, None).unwrap();
    let sentinel = SplitId::MAX;
    {
        let mut state = mux.state.lock().unwrap();
        state.split_screens.insert(sentinel, (usize::MAX, usize::MAX, ScreenId::MAX));
    }

    assert!(mux.move_tab(extra.id, first_pane, 0));
    mux.with_state(|state| assert!(state.split_screens.contains_key(&sentinel)));
    let events = mux.subscribe();
    assert!(mux.move_tab(extra.id, second_pane, 0));
    mux.with_state(|state| assert!(state.split_screens.contains_key(&sentinel)));
    // The adopted tab's tab-changed, then one tree-changed.
    let received = events.try_iter().collect::<Vec<_>>();
    assert!(received.iter().any(|event| matches!(event, MuxEvent::TreeDelta(TreeDelta {
        kind: TreeDeltaKind::TabChanged, surface, pane, ..
    }) if *surface == Some(extra.id) && *pane == Some(second_pane))));
    assert!(matches!(received.last(), Some(MuxEvent::TreeChanged)));
    assert_eq!(received.iter().filter(|event| matches!(event, MuxEvent::TreeChanged)).count(), 1);
}
