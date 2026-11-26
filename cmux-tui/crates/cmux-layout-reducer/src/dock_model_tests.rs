//! Ported from cmux-next macOS `WindowDocksTests.swift` (the model section, W1 to W5) and
//! `WindowDockModelTests.swift` (the per-dock tab-bar mode, moving a dock, the actions' target),
//! plus the Dock Column plan and the layout model's dock checks.

use super::*;

fn dock(docks: &mut WindowDocks, workspace: &str, edge: DockEdge) -> Option<String> {
    docks.dock(workspace, edge, DockMode::Docked, DEFAULT_EXTENT_PERMILLE)
}

fn strings(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

#[test]
fn one_dock_per_edge_and_docking_an_occupied_edge_returns_the_workspace_it_displaced() {
    let mut docks = WindowDocks::default();
    assert_eq!(dock(&mut docks, "ws-a", DockEdge::Left), None);
    assert_eq!(docks.dock_at(DockEdge::Left).map(|d| d.workspace.as_str()), Some("ws-a"));
    assert_eq!(dock(&mut docks, "ws-b", DockEdge::Left).as_deref(), Some("ws-a"), "W1");
    assert_eq!(docks.dock_at(DockEdge::Left).map(|d| d.workspace.as_str()), Some("ws-b"));
    assert_eq!(docks.all.len(), 1);
}

#[test]
fn a_workspace_is_in_one_dock_only() {
    let mut docks = WindowDocks::default();
    dock(&mut docks, "ws-a", DockEdge::Left);
    dock(&mut docks, "ws-a", DockEdge::Bottom);
    assert!(docks.dock_at(DockEdge::Left).is_none(), "W2: docking it elsewhere moves it");
    assert_eq!(docks.edge_of("ws-a"), Some(DockEdge::Bottom));
}

#[test]
fn undock_removes_the_dock() {
    let mut docks = WindowDocks::default();
    dock(&mut docks, "ws-a", DockEdge::Right);
    assert!(docks.undock("ws-a"));
    assert!(docks.all.is_empty());
    assert!(!docks.undock("ws-a"));
}

#[test]
fn toggle_hides_and_shows_and_reports_an_empty_edge() {
    let mut docks = WindowDocks::default();
    assert_eq!(docks.toggle(DockEdge::Top), ToggleResult::Empty);
    dock(&mut docks, "ws-a", DockEdge::Top);
    assert_eq!(docks.toggle(DockEdge::Top), ToggleResult::Hidden);
    assert!(docks.visible().is_empty(), "a hidden dock is not placed");
    assert_eq!(docks.dock_at(DockEdge::Top).map(|d| d.workspace.as_str()), Some("ws-a"));
    assert_eq!(docks.toggle(DockEdge::Top), ToggleResult::Shown);
    let visible: Vec<&str> = docks.visible().iter().map(|d| d.workspace.as_str()).collect();
    assert_eq!(visible, ["ws-a"]);
}

#[test]
fn reveal_shows_a_hidden_dock() {
    let mut docks = WindowDocks::default();
    dock(&mut docks, "ws-a", DockEdge::Bottom);
    docks.toggle(DockEdge::Bottom);
    assert!(docks.reveal("ws-a"), "W4: selecting a hidden docked workspace shows its dock");
    assert_eq!(docks.dock_at(DockEdge::Bottom).map(|d| d.hidden), Some(false));
    assert!(!docks.reveal("ws-a"), "already shown: no change");
}

#[test]
fn floating_toggles_the_mode() {
    let mut docks = WindowDocks::default();
    dock(&mut docks, "ws-a", DockEdge::Left);
    assert_eq!(docks.toggle_floating("ws-a"), Some(DockMode::Overlay));
    assert_eq!(docks.toggle_floating("ws-a"), Some(DockMode::Docked));
    assert_eq!(docks.toggle_floating("ws-missing"), None);
}

#[test]
fn pruned_drops_docks_of_workspaces_that_left() {
    let mut docks = WindowDocks::default();
    dock(&mut docks, "ws-a", DockEdge::Left);
    dock(&mut docks, "ws-b", DockEdge::Right);
    docks.prune(|workspace| workspace == "ws-b");
    let left: Vec<&str> = docks.all.iter().map(|d| d.workspace.as_str()).collect();
    assert_eq!(left, ["ws-b"], "W3");
}

#[test]
fn the_stage_follows_the_focused_workspace_unless_it_is_docked() {
    let mut docks = WindowDocks::default();
    dock(&mut docks, "ws-dock", DockEdge::Left);
    let listed = strings(&["ws-dock", "ws-a", "ws-b"]);
    assert_eq!(docks.stage(Some("ws-a"), Some("ws-b"), &[], &listed).as_deref(), Some("ws-a"));
    assert_eq!(
        docks.stage(Some("ws-dock"), Some("ws-b"), &[], &listed).as_deref(),
        Some("ws-b"),
        "W5: focus in a dock keeps the stage"
    );
    let recency = strings(&["ws-dock", "ws-b", "ws-a"]);
    assert_eq!(docks.stage(Some("ws-dock"), None, &recency, &listed).as_deref(), Some("ws-b"));
    assert_eq!(
        docks.stage(Some("ws-dock"), Some("ws-gone"), &[], &listed).as_deref(),
        Some("ws-a")
    );
    assert_eq!(docks.stage(Some("ws-dock"), None, &[], &strings(&["ws-dock"])), None);
}

#[test]
fn extents_are_clamped_and_docks_keep_edge_order() {
    let mut docks = WindowDocks::default();
    docks.dock("ws-b", DockEdge::Bottom, DockMode::Docked, 5);
    docks.dock("ws-l", DockEdge::Left, DockMode::Docked, 1200);
    let edges: Vec<DockEdge> = docks.all.iter().map(|d| d.edge).collect();
    assert_eq!(edges, [DockEdge::Left, DockEdge::Bottom]);
    assert_eq!(docks.dock_at(DockEdge::Left).map(|d| d.extent_permille), Some(900));
    assert_eq!(docks.dock_at(DockEdge::Bottom).map(|d| d.extent_permille), Some(100));
}

#[test]
fn the_no_tab_bar_mode_is_per_dock_and_keeps_a_second_tab_reachable() {
    let mut docks = WindowDocks::default();
    dock(&mut docks, "ws-chief", DockEdge::Left);
    dock(&mut docks, "ws-logs", DockEdge::Bottom);
    assert!(!docks.hides_tab_bar("ws-chief", 1), "off by default, as before");
    assert_eq!(docks.toggle_tab_bar("ws-chief"), Some(true));
    assert!(docks.hides_tab_bar("ws-chief", 1), "one tab: no tab bar");
    assert!(!docks.hides_tab_bar("ws-chief", 2), "a tab dragged in brings the bar back");
    assert!(!docks.hides_tab_bar("ws-logs", 1), "per dock: the other dock keeps its bar");
    assert!(!docks.hides_tab_bar("ws-stage", 1), "a workspace in no dock keeps its bar");
    assert_eq!(docks.toggle_tab_bar("ws-chief"), Some(false));
    assert_eq!(docks.toggle_tab_bar("ws-none"), None);
}

#[test]
fn moving_a_dock_keeps_its_mode_extent_and_tab_bar_and_shows_it() {
    let mut docks = WindowDocks::default();
    docks.dock("ws-chief", DockEdge::Left, DockMode::Overlay, 420);
    docks.toggle_tab_bar("ws-chief");
    docks.toggle(DockEdge::Left);
    dock(&mut docks, "ws-other", DockEdge::Right);
    assert_eq!(docks.move_dock("ws-chief", DockEdge::Right).as_deref(), Some("ws-other"), "W1");
    let moved = docks.dock_at(DockEdge::Right).cloned();
    assert_eq!(moved.as_ref().map(|d| d.workspace.as_str()), Some("ws-chief"));
    assert!(moved.as_ref().is_some_and(|d| {
        d.mode == DockMode::Overlay && d.extent_permille == 420 && d.hides_tab_bar && !d.hidden
    }));
    assert!(docks.dock_at(DockEdge::Left).is_none());
    assert_eq!(docks.move_dock("ws-none", DockEdge::Top), None);
}

#[test]
fn the_actions_target_the_focused_dock_else_the_first_shown() {
    let mut docks = WindowDocks::default();
    assert!(docks.target(Some("ws-a")).is_none());
    dock(&mut docks, "ws-l", DockEdge::Left);
    dock(&mut docks, "ws-b", DockEdge::Bottom);
    let target = |docks: &WindowDocks| docks.target(Some("ws-stage")).map(|d| d.workspace.clone());
    assert_eq!(docks.target(Some("ws-b")).map(|d| d.workspace.as_str()), Some("ws-b"));
    assert_eq!(target(&docks).as_deref(), Some("ws-l"), "else the first shown");
    docks.toggle(DockEdge::Left);
    assert_eq!(target(&docks).as_deref(), Some("ws-b"));
    docks.toggle(DockEdge::Bottom);
    assert_eq!(target(&docks).as_deref(), Some("ws-l"), "else the first hidden");
}

// MARK: Dock Column

fn column(id: &str, width: f64, panes: &[&str], dock: Option<DockColumn>) -> LayoutColumn {
    LayoutColumn { id: id.to_owned(), width, panes: strings(panes), dock }
}

fn columns_screen(columns: Vec<LayoutColumn>) -> LayoutScreen {
    LayoutScreen { id: "s1".to_owned(), layout: ScreenLayout::Columns(columns), floating: vec![] }
}

#[test]
fn the_default_width_is_clamped_into_a_dock_share() {
    assert_eq!(DockDefaults.width(0.1), 0.25);
    assert_eq!(DockDefaults.width(0.33), 0.33);
    assert_eq!(DockDefaults.width(0.9), 0.40);
}

#[test]
fn the_default_edge_is_left_for_the_leftmost_of_several_else_right_and_yields_to_a_free_side() {
    let layout = ScreenLayout::Columns(vec![
        column("a", 0.5, &["p1"], None),
        column("b", 0.5, &["p2"], None),
    ]);
    assert_eq!(DockDefaults.edge("a", &layout), DockEdge::Left);
    assert_eq!(DockDefaults.edge("b", &layout), DockEdge::Right);
    let held = ScreenLayout::Columns(vec![
        column("a", 0.5, &["p1"], None),
        column("r", 0.3, &["p2"], Some(DockColumn::new(DockEdge::Right, DockMode::Docked))),
        column("b", 0.5, &["p3"], None),
    ]);
    assert_eq!(DockDefaults.edge("b", &held), DockEdge::Left, "the right side is held");
}

#[test]
fn a_plan_pins_undocks_or_moves_the_tab_of_the_last_scrolling_column() {
    let docked = DockColumn::new(DockEdge::Left, DockMode::Docked);
    let screen = columns_screen(vec![
        column("a", 0.2, &["p1"], None),
        column("b", 0.5, &["p2", "p3"], None),
        column("d", 0.3, &["p4"], Some(docked.clone())),
    ]);
    assert_eq!(
        DockDefaults.plan(&screen, "a", None, None, None, DockMode::Docked),
        Some(DockPlan::Pin {
            column: "a".to_owned(),
            dock: DockColumn::new(DockEdge::Right, DockMode::Docked),
            width: 0.25,
        }),
        "left is held: the free side"
    );
    assert_eq!(
        DockDefaults.plan(&screen, "d", None, None, None, DockMode::Docked),
        Some(DockPlan::Undock { column: "d".to_owned() }),
        "asking for the state it has undocks"
    );
    let last = columns_screen(vec![
        column("b", 0.5, &["p2", "p3"], None),
        column("d", 0.3, &["p4"], Some(docked)),
    ]);
    assert_eq!(
        DockDefaults.plan(&last, "b", Some("p3"), Some(DockEdge::Right), None, DockMode::Overlay),
        Some(DockPlan::MoveTab {
            pane: "p3".to_owned(),
            dock: DockColumn::new(DockEdge::Right, DockMode::Overlay),
            width: 0.40,
        })
    );
    assert_eq!(DockDefaults.plan(&last, "zz", None, None, None, DockMode::Docked), None);
    let splits = LayoutScreen {
        id: "s2".to_owned(),
        layout: ScreenLayout::Splits(strings(&["q1", "q2"])),
        floating: vec![],
    };
    assert_eq!(
        DockDefaults.plan(&splits, "implicit:s2", Some("gone"), None, None, DockMode::Docked),
        Some(DockPlan::MoveTab {
            pane: "q1".to_owned(),
            dock: DockColumn::new(DockEdge::Right, DockMode::Docked),
            width: 0.40,
        }),
        "the implicit column keeps scrolling; an unknown pane uses its first"
    );
}

#[test]
fn the_layout_model_refuses_what_the_daemon_would() {
    let right = DockColumn::new(DockEdge::Right, DockMode::Docked);
    let screens = vec![
        columns_screen(vec![column("a", 0.5, &["p1"], None), column("b", 0.5, &["p2"], None)]),
        LayoutScreen {
            id: "s2".to_owned(),
            layout: ScreenLayout::Splits(strings(&["q1"])),
            floating: strings(&["f1"]),
        },
    ];
    assert_eq!(validate_dock(&screens, Some(&right), "zz"), Some(DockRefusal::UnknownColumn));
    assert_eq!(validate_dock(&screens, None, "a"), Some(DockRefusal::Unchanged));
    assert_eq!(
        validate_dock(&screens, Some(&right), "implicit:s2"),
        Some(DockRefusal::LastScrollingColumn)
    );
    assert_eq!(validate_dock(&screens, Some(&right), "a"), None);
    assert_eq!(
        set_column_dock(&screens, "a", Some(&right)),
        Ok(SetColumnDock { column: "a".to_owned(), any_pane: "p1".to_owned(), dock: Some(right) })
    );
    let found = dock_column_containing(&screens, "q1");
    assert_eq!(found.map(|c| c.id), Some("implicit:s2".to_owned()));
    assert_eq!(dock_column_containing(&screens, "f1"), None, "a floating pane has no column");
}
