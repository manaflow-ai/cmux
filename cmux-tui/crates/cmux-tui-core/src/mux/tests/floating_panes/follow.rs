//! The list of a screen after an act that is not a float request (`floating-panes-v1`): a dock of the column of
//! a floating pane, a new row in that column, a close that gives the focus to a floating pane, a tab select, a
//! move of a tab, a swap and a zoom. Each test reads the live list, and the store where the act writes it.

use super::acts::{CENTERED, float, float_at, floating, list, mux_with_panes};
use super::*;
use crate::model::{ColumnDock, DockEdge, DockMode};

/// The stored list of the first screen, back to front.
fn stored(mux: &Mux) -> Vec<Floating<PanePublicId>> {
    let screen = mux.with_state(|state| state.workspaces[0].screens[0].public_id.clone());
    let topology = mux.workspace_registry.lock().unwrap().resource_topology_snapshot().unwrap();
    topology
        .screens
        .into_iter()
        .find(|candidate| candidate.public_id == screen)
        .expect("the store has the first screen")
        .floating
}

/// A dock of the column of a floating pane makes the pane tiled, in the live list and in the store. The end of
/// the dock does not make the pane float again.
#[test]
fn floating_pane_becomes_tiled_when_its_column_docks() {
    let (mux, panes) = mux_with_panes(3);
    float(&mux, panes[2], FloatMode::On).unwrap();
    assert_eq!(floating(&mux), vec![panes[2]]);
    assert_eq!(stored(&mux), live_list(&mux), "the store after the float");

    let dock = ColumnDock::new(DockEdge::Right, DockMode::Docked);
    mux.set_column_dock(panes[2], Some(dock), None).unwrap();
    assert!(list(&mux).is_empty(), "a pane of a docked column does not float");
    assert!(stored(&mux).is_empty(), "the store has no record of the pane");

    mux.set_column_dock(panes[2], None, None).unwrap();
    assert!(list(&mux).is_empty(), "the pane stays tiled when the dock ends");
    assert!(stored(&mux).is_empty(), "the store after the end of the dock");
}

/// A new row in the column of a floating pane makes the pane tiled, in the live list and in the store.
#[test]
fn floating_pane_becomes_tiled_when_its_column_gets_a_row() {
    let (mux, panes) = mux_with_panes(3);
    float(&mux, panes[0], FloatMode::On).unwrap();
    assert_eq!(floating(&mux), vec![panes[0]]);

    mux.new_row_with_options(panes[0], 500, Default::default(), Some((38, 10)), None).unwrap();
    assert!(list(&mux).is_empty(), "a pane of a column with rows does not float");
    assert!(stored(&mux).is_empty(), "the store has no record of the pane");
}

/// A close that gives the focus to a floating pane brings that pane to the front, in the live list and in the
/// store.
#[test]
fn floating_pane_that_takes_the_focus_at_a_close_comes_to_the_front() {
    let (mux, panes) = mux_with_panes(4);
    float(&mux, panes[0], FloatMode::On).unwrap();
    float(&mux, panes[1], FloatMode::On).unwrap();
    // Pane 0 has the focus, then the tiled pane 3 has it. A frame then brings pane 1 to the front.
    assert!(mux.focus_pane(panes[0]));
    assert!(mux.focus_pane(panes[3]));
    float_at(&mux, panes[1], CENTERED, None).unwrap();
    assert_eq!(floating(&mux), vec![panes[0], panes[1]]);

    assert!(mux.close_pane(panes[3]).unwrap());
    let focused = mux.with_state(|state| state.workspaces[0].screens[0].active_pane);
    assert_eq!(focused, panes[0], "the pane that had the focus last takes it");
    assert_eq!(floating(&mux), vec![panes[1], panes[0]], "the focused pane is the front pane");
    assert_eq!(stored(&mux), live_list(&mux), "the store has the list of the screen");
}

/// A tab select that brings a floating pane to the front emits one layout change of the screen.
#[test]
fn floating_pane_raised_by_a_tab_select_emits_a_layout_change() {
    let (mux, panes) = mux_with_panes(3);
    float(&mux, panes[0], FloatMode::On).unwrap();
    mux.new_tab(Some(panes[0]), None, Some((38, 22))).unwrap();
    mux.focus_pane(panes[0]);
    // The focus stays on pane 0; the float of pane 1 puts pane 1 in front of it.
    float(&mux, panes[1], FloatMode::On).unwrap();
    assert_eq!(floating(&mux), vec![panes[0], panes[1]]);
    let (screen, focused) = mux.with_state(|state| {
        let screen = &state.workspaces[0].screens[0];
        (screen.id, screen.active_pane)
    });
    assert_eq!(focused, panes[0], "pane 0 has the focus before the select");

    let events = mux.subscribe();
    mux.select_tab(Some(panes[0]), Some(0), None);
    assert_eq!(floating(&mux), vec![panes[1], panes[0]], "the select brings the pane to the front");
    let layout_changes = events
        .try_iter()
        .filter(|event| matches!(event, MuxEvent::LayoutChanged(changed, _) if *changed == screen))
        .count();
    assert_eq!(layout_changes, 1, "one layout change of the screen");
}

/// The only tab of a floating pane moves to another pane: the pane leaves the tree and the list, in the live
/// list and in the store. The other floating pane keeps its place.
#[test]
fn floating_pane_whose_only_tab_moves_away_leaves_the_list() {
    let (mux, panes) = mux_with_panes(4);
    float(&mux, panes[0], FloatMode::On).unwrap();
    float(&mux, panes[1], FloatMode::On).unwrap();
    let tab = mux.with_state(|state| state.panes[&panes[1]].tabs[0]);

    assert!(mux.move_tab(tab, panes[3], 1));
    assert_eq!(floating(&mux), vec![panes[0]], "the pane that left the tree is not in the list");
    assert_eq!(stored(&mux), live_list(&mux), "the store has the list of the screen");
}

/// A swap of a floating pane with a tiled pane keeps the list. A swap that puts the floating pane into a
/// docked column makes it tiled, in the live list and in the store.
#[test]
fn floating_pane_swap_keeps_the_list_and_a_swap_into_a_docked_column_ends_the_float() {
    let (mux, panes) = mux_with_panes(4);
    let dock = ColumnDock::new(DockEdge::Right, DockMode::Docked);
    mux.set_column_dock(panes[3], Some(dock), None).unwrap();
    float(&mux, panes[0], FloatMode::On).unwrap();

    assert!(mux.swap_panes(panes[0], panes[1]));
    assert_eq!(floating(&mux), vec![panes[0]], "the pane floats after a swap with a tiled pane");
    assert_eq!(stored(&mux), live_list(&mux), "the store after the first swap");

    assert!(mux.swap_panes(panes[0], panes[3]));
    assert!(list(&mux).is_empty(), "a pane of a docked column does not float");
    assert!(stored(&mux).is_empty(), "the store has no record of the pane");
}

/// A floating pane is never zoomed: a zoom request of a floating pane is refused and changes nothing. A tiled
/// pane of the same screen zooms, and a float of the zoomed pane ends its zoom.
#[test]
fn floating_pane_refuses_a_zoom() {
    let (mux, panes) = mux_with_panes(3);
    float(&mux, panes[0], FloatMode::On).unwrap();
    let zoomed = |mux: &Mux| mux.with_state(|state| state.workspaces[0].screens[0].zoomed_pane);

    assert!(mux.zoom_pane(Some(panes[0]), ZoomMode::On).is_err(), "a zoom of a floating pane");
    assert!(mux.zoom_pane(Some(panes[0]), ZoomMode::Toggle).is_err(), "a toggle of the zoom");
    assert_eq!(zoomed(&mux), None);
    assert_eq!(floating(&mux), vec![panes[0]], "the refusal keeps the list");
    let off = mux.zoom_pane(Some(panes[0]), ZoomMode::Off).unwrap();
    assert!(!off.zoomed, "the end of a zoom that is not there is no fault");

    assert!(mux.zoom_pane(Some(panes[1]), ZoomMode::On).unwrap().zoomed);
    assert_eq!(zoomed(&mux), Some(panes[1]));
    float(&mux, panes[1], FloatMode::On).unwrap();
    assert_eq!(zoomed(&mux), None, "the float ends the zoom of its pane");
    assert_eq!(stored(&mux), live_list(&mux), "the store has the list of the screen");
}
