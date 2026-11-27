//! Parity with the Swift rules these came from (CmuxNextAppTests
//! TabDropPointerSlotTests, LinkDragDropTests; CmuxNextFilesTests
//! FileHelpersTests) plus the cases their doc comments promise.

use super::*;

fn tab(width: f64) -> Slot {
    Slot { width, ..Slot::default() }
}

fn member(width: f64, group: &str) -> Slot {
    Slot { width, group: Some(group.into()), ..Slot::default() }
}

fn chip(width: f64, group: &str, collapsed: bool) -> Slot {
    Slot { width, group: Some(group.into()), is_group_chip: true, is_collapsed: collapsed }
}

#[test]
fn insertion_picks_the_nearest_leading_edge() {
    assert_eq!(insertion_index(0.0, 0.0, &[]), 0);
    assert_eq!(insertion_index(49.0, 0.0, &[100.0, 100.0]), 0);
    assert_eq!(insertion_index(51.0, 0.0, &[100.0, 100.0]), 1);
    assert_eq!(insertion_index(500.0, 0.0, &[100.0, 100.0]), 2);
    assert_eq!(insertion_index(50.0, 0.0, &[100.0]), 0, "a tie keeps the first edge");
}

#[test]
fn a_drop_lands_on_the_side_of_the_midpoint_the_pointer_is_on() {
    for (fraction, expected) in [(0.15, 0), (0.85, 1)] {
        let entries = [tab(48.0), tab(180.0)];
        let landing = resolve_tab(&entries, 0.0, 48.0 * fraction, None, 0.3 * 180.0);
        assert_eq!(landing, TabLanding { index: expected, group: None }, "{fraction}");
    }
}

#[test]
fn a_position_between_members_or_after_a_chip_is_inside_the_group() {
    let entries = [chip(30.0, "g", false), member(100.0, "g"), member(100.0, "g"), tab(100.0)];
    let after_chip = resolve_tab(&entries, 0.0, 31.0, None, 10.0);
    assert_eq!(after_chip, TabLanding { index: 0, group: Some("g".into()) });
    let between = resolve_tab(&entries, 0.0, 131.0, None, 10.0);
    assert_eq!(between, TabLanding { index: 1, group: Some("g".into()) });
}

#[test]
fn the_trailing_edge_of_a_group_holds_its_membership_by_hysteresis() {
    let entries = [chip(30.0, "g", false), member(100.0, "g"), tab(100.0)];
    // The edge after the last member is at 130.
    assert_eq!(resolve_tab(&entries, 0.0, 135.0, Some("g"), 10.0).group.as_deref(), Some("g"));
    assert_eq!(resolve_tab(&entries, 0.0, 141.0, Some("g"), 10.0).group, None);
    assert_eq!(resolve_tab(&entries, 0.0, 125.0, None, 10.0).group, None);
    assert_eq!(resolve_tab(&entries, 0.0, 115.0, None, 10.0).group.as_deref(), Some("g"));
}

#[test]
fn a_collapsed_group_takes_no_tab_inside_it() {
    let entries =
        [chip(30.0, "g", true), Slot { is_collapsed: true, ..member(0.0, "g") }, tab(100.0)];
    // The edges before the chip and before its collapsed member are inside it: the probe at the
    // chip's leading edge lands after the group, outside it.
    let landing = resolve_tab(&entries, 0.0, 0.0, None, 10.0);
    assert_eq!(landing, TabLanding { index: 1, group: None });
    let landing = resolve_tab(&entries, 0.0, 120.0, None, 10.0);
    assert_eq!(landing, TabLanding { index: 2, group: None });
}

#[test]
fn units_fold_a_chip_with_its_members() {
    let entries =
        [tab(50.0), chip(30.0, "g", false), member(100.0, "g"), member(100.0, "g"), tab(70.0)];
    assert_eq!(
        units(&entries),
        vec![
            Unit { width: 50.0, tab_count: 1 },
            Unit { width: 230.0, tab_count: 2 },
            Unit { width: 70.0, tab_count: 1 },
        ]
    );
    assert_eq!(resolve_group(&entries, 0.0, 0.0), GroupLanding { unit_index: 0, tab_index: 0 });
    assert_eq!(resolve_group(&entries, 0.0, 290.0), GroupLanding { unit_index: 2, tab_index: 3 });
    assert_eq!(resolve_group(&entries, 0.0, 999.0), GroupLanding { unit_index: 3, tab_index: 4 });
}

fn drag(window: Option<&str>) -> WorkspaceDrag {
    WorkspaceDrag {
        window: window.map(Into::into),
        source_window: Some("w1".into()),
        ..WorkspaceDrag::default()
    }
}

fn into(id: &str, target: WorkspaceTarget) -> WorkspaceOutcome {
    WorkspaceOutcome::Window { id: id.into(), target }
}

#[test]
fn outside_every_window_a_drag_makes_or_moves_a_window() {
    assert_eq!(workspace_outcome(&drag(None)), WorkspaceOutcome::NewWindow);
    let all = WorkspaceDrag { dragging_all_of_source: true, ..drag(None) };
    assert_eq!(workspace_outcome(&all), WorkspaceOutcome::MoveWindow);
}

#[test]
fn another_window_takes_the_sidebar_hit_then_the_pane_then_itself() {
    let mut other = drag(Some("w2"));
    assert_eq!(workspace_outcome(&other), into("w2", WorkspaceTarget::Window));
    other.layout_hit = Some(PaneHit { split_edge: None });
    assert_eq!(workspace_outcome(&other), into("w2", WorkspaceTarget::Merge));
    other.sidebar_hit = Some(SidebarHit::IntoGroup);
    assert_eq!(workspace_outcome(&other), into("w2", WorkspaceTarget::IntoGroup));
    other.is_group = true;
    assert_eq!(
        workspace_outcome(&other),
        into("w2", WorkspaceTarget::Window),
        "a group joins whole"
    );
}

#[test]
fn multi_view_places_beside_on_a_split_edge_or_the_shown_edge() {
    let mut beside = drag(Some("w2"));
    beside.places_beside = true;
    beside.layout_hit = Some(PaneHit { split_edge: Some(Edge::Left) });
    assert_eq!(
        workspace_outcome(&beside),
        into("w2", WorkspaceTarget::Beside { edge: Edge::Left })
    );
    beside.layout_hit = None;
    beside.beside_edge = Some(Edge::Bottom);
    assert_eq!(
        workspace_outcome(&beside),
        into("w2", WorkspaceTarget::Beside { edge: Edge::Bottom })
    );
    beside.places_beside = false;
    assert_eq!(workspace_outcome(&beside), into("w2", WorkspaceTarget::Window));
    beside.layout_hit = Some(PaneHit { split_edge: Some(Edge::Left) });
    assert_eq!(workspace_outcome(&beside), into("w2", WorkspaceTarget::Merge));
}

#[test]
fn back_home_only_a_slot_or_a_pane_means_something() {
    let mut home = drag(Some("w1"));
    assert_eq!(workspace_outcome(&home), WorkspaceOutcome::Cancel);
    home.sidebar_hit = Some(SidebarHit::IntoGroup);
    assert_eq!(workspace_outcome(&home), WorkspaceOutcome::Cancel);
    home.sidebar_hit = Some(SidebarHit::Window);
    assert_eq!(workspace_outcome(&home), WorkspaceOutcome::Cancel);
    home.sidebar_hit = Some(SidebarHit::Position);
    assert_eq!(workspace_outcome(&home), into("w1", WorkspaceTarget::Position));
    home.is_group = true;
    assert_eq!(workspace_outcome(&home), WorkspaceOutcome::Cancel);
    home.is_group = false;
    home.sidebar_hit = None;
    home.layout_hit = Some(PaneHit { split_edge: Some(Edge::Top) });
    assert_eq!(workspace_outcome(&home), into("w1", WorkspaceTarget::Merge));
}

#[test]
fn a_link_drop_uses_a_tabs_zones() {
    assert_eq!(link_plan(LayoutTarget::PaneCenter, true), LinkPlan::Tab);
    assert_eq!(link_plan(LayoutTarget::PaneCenter, false), LinkPlan::Refused);
    for edge in [Edge::Left, Edge::Right, Edge::Top, Edge::Bottom] {
        assert_eq!(link_plan(LayoutTarget::PaneEdge(edge), false), LinkPlan::Split { edge });
    }
    assert_eq!(link_plan(LayoutTarget::NewColumn, false), LinkPlan::Column);
    assert_eq!(link_plan(LayoutTarget::NewDock, false), LinkPlan::Dock);
}

#[test]
fn a_file_drop_moves_on_its_volume_and_copies_across() {
    let local = [Some(1), Some(1)];
    assert_eq!(transfer_mode(&local, Some(1), false, false), TransferMode::Move);
    assert_eq!(transfer_mode(&local, Some(2), false, false), TransferMode::Copy);
    assert_eq!(transfer_mode(&local, Some(1), true, false), TransferMode::Copy);
    assert_eq!(transfer_mode(&local, Some(2), false, true), TransferMode::Move);
    assert_eq!(transfer_mode(&local, None, false, false), TransferMode::Copy);
    assert_eq!(transfer_mode(&[Some(1), None], Some(1), false, false), TransferMode::Copy);
    assert_eq!(transfer_mode(&[], Some(1), false, false), TransferMode::Move);
}

#[test]
fn the_wire_names_match_the_app() {
    let drag: WorkspaceDrag = serde_json::from_value(serde_json::json!({
        "window": "w2", "layoutHit": {"splitEdge": "right"}, "placesBeside": true, "sourceWindow": "w1"
    }))
    .unwrap();
    assert_eq!(
        serde_json::to_value(workspace_outcome(&drag)).unwrap(),
        serde_json::json!({"outcome": "window", "id": "w2", "target": {"kind": "beside", "edge": "right"}})
    );
    let target: LayoutTarget =
        serde_json::from_value(serde_json::json!({"paneEdge": "top"})).unwrap();
    assert_eq!(
        serde_json::to_value(link_plan(target, true)).unwrap(),
        serde_json::json!({"plan": "split", "edge": "top"})
    );
    let target: LayoutTarget = serde_json::from_value(serde_json::json!("paneCenter")).unwrap();
    assert_eq!(
        serde_json::to_value(link_plan(target, false)).unwrap(),
        serde_json::json!({"plan": "refused"})
    );
}
