//! The tab drag's rules, ported from the app's Swift tests
//! (BonsplitDropParityTests, HomeLoneDockTests) and the resolver's cases.

use super::*;

fn context(pane_tabs: i64, workspace_tabs: i64, dragged: i64) -> Context {
    Context {
        source_pane_id: "p1".into(),
        source_pane_tab_count: pane_tabs,
        source_workspace_id: "w".into(),
        source_workspace_tab_count: workspace_tabs,
        dragged_tab_count: dragged,
        source_window_workspace_count: 1,
        source_strip_id: None,
        source_index: None,
        source_group_id: None,
        is_group_drag: false,
        source_stays_put: false,
    }
}

fn in_strip(mut context: Context, index: i64) -> Context {
    context.source_strip_id = Some("S".into());
    context.source_index = Some(index);
    context
}

fn strip(index: i64, group: Option<&str>) -> DropKind {
    DropKind::Strip { strip_id: "S".into(), index, group_id: group.map(str::to_owned) }
}

const P: Point = Point { x: 5.0, y: 7.0 };

/// A tab dropped on its own pane's body names its own slot: a stay, and the
/// drop changes nothing.
#[test]
fn a_drop_on_its_own_place_stays() {
    let context = in_strip(context(3, 3, 1), 0);
    let resolution = resolve(Some(&strip(0, None)), None, true, P, &context);
    assert_eq!(resolution.preview, Preview::Stay);
    assert_eq!(resolution.outcome, Outcome::Cancel);
    assert_eq!(verdict(&strip(0, None), &context), Verdict::Stay);
    // Another slot, another group or another strip is a target.
    assert_eq!(verdict(&strip(2, None), &context), Verdict::Accept);
    assert_eq!(verdict(&strip(0, Some("g")), &context), Verdict::Accept);
    let other = DropKind::Strip { strip_id: "T".into(), index: 0, group_id: None };
    assert_eq!(verdict(&other, &context), Verdict::Accept);
}

/// The own place is the final index clamped to the strip without the dragged
/// tabs: past the end is the last slot, before the start the first.
#[test]
fn the_own_place_is_clamped() {
    let last = in_strip(context(3, 3, 1), 2);
    assert!(last.is_own_place("S", 9, None));
    let first = in_strip(context(3, 3, 1), 0);
    assert!(first.is_own_place("S", -4, None));
    // A group of two in a strip of three ends at 1 at most.
    let group = in_strip(context(3, 3, 2), 1);
    assert!(group.is_own_place("S", 5, None));
    // No source strip: never its own place.
    assert!(!context(3, 3, 1).is_own_place("S", 0, None));
}

/// A pane's only tab dropped on its own edge is never refused: the tab stays
/// and the New Tab page opens on the far side.
#[test]
fn a_lone_tab_on_its_own_edge_is_always_a_target() {
    let lone = context(1, 2, 1);
    let kind = DropKind::NewSplit { pane_id: "p1".into(), edge: Edge::Left };
    assert_eq!(verdict(&kind, &lone), Verdict::Accept);
    assert!(lone.splits_behind("p1") && !lone.splits_behind("p2"));
    assert!(!context(2, 2, 1).splits_behind("p1"));
}

/// The New Tab page opens across the pane from a left or top edge; right and
/// bottom open there and swap back.
#[test]
fn the_split_behind_opens_on_the_far_side() {
    assert_eq!(split_behind(Edge::Left), (Edge::Right, false));
    assert_eq!(split_behind(Edge::Top), (Edge::Bottom, false));
    assert_eq!(split_behind(Edge::Right), (Edge::Right, true));
    assert_eq!(split_behind(Edge::Bottom), (Edge::Bottom, true));
    assert_eq!(Edge::Left.opposite(), Edge::Right);
    assert_eq!(Edge::Bottom.opposite(), Edge::Top);
}

/// Only Home's own tab stays in Home: it never becomes a new workspace.
#[test]
fn only_homes_own_tab_stays_put() {
    let mut context = context(2, 3, 1);
    let kind = DropKind::NewWorkspace { group_id: None, index: 0 };
    assert_eq!(verdict(&kind, &context), Verdict::Accept);
    context.source_stays_put = true;
    assert_eq!(verdict(&kind, &context), Verdict::Refuse { refusal: Refusal::StaysPut });
    let resolution = resolve(Some(&kind), None, true, P, &context);
    assert_eq!(resolution.preview, Preview::Refused);
    assert_eq!(resolution.refusal, Some(Refusal::StaysPut));
    assert_eq!(resolution.outcome, Outcome::Cancel);
    // Nor a new window.
    assert_eq!(outcome(None, false, P, &context), Outcome::Cancel);
}

#[test]
fn a_column_before_the_first_and_a_group_on_a_dock_are_refused() {
    let mut context = context(2, 3, 1);
    let before = DropKind::NewColumn { screen_id: "s".into(), after_column_id: None };
    assert_eq!(verdict(&before, &context), Verdict::Refuse { refusal: Refusal::ColumnBeforeFirst });
    let after = DropKind::NewColumn { screen_id: "s".into(), after_column_id: Some("c".into()) };
    assert_eq!(
        outcome(Some(&after), true, P, &context),
        Outcome::NewColumn { screen_id: "s".into(), after_column_id: "c".into() }
    );
    let dock = DropKind::NewDock { screen_id: "s".into(), edge: "top".into() };
    assert_eq!(verdict(&dock, &context), Verdict::Accept);
    context.is_group_drag = true;
    assert_eq!(verdict(&dock, &context), Verdict::Refuse { refusal: Refusal::GroupDock });
}

#[test]
fn its_own_workspace_stays() {
    let context = context(2, 3, 1);
    let own = DropKind::Workspace { id: "w".into() };
    assert_eq!(verdict(&own, &context), Verdict::Stay);
    let other = DropKind::Workspace { id: "v".into() };
    assert_eq!(outcome(Some(&other), true, P, &context), Outcome::Workspace { id: "v".into() });
}

/// Outside every window: a tear-off, or the window or workspace itself moves
/// when the drag carries everything its workspace holds.
#[test]
fn outside_every_window() {
    let resolution = resolve(None, None, false, P, &context(2, 3, 1));
    assert_eq!(resolution.preview, Preview::NewWindow);
    assert_eq!(resolution.outcome, Outcome::TearOff { point: P });
    assert_eq!(outcome(None, false, P, &context(1, 1, 1)), Outcome::MoveWindow { point: P });
    let mut shared = context(1, 1, 1);
    shared.source_window_workspace_count = 2;
    assert_eq!(outcome(None, false, P, &shared), Outcome::MoveWorkspaceToNewWindow { point: P });
}

/// A sidebar gap makes a new workspace, or moves the emptied workspace
/// itself; a negative index is no slot.
#[test]
fn a_sidebar_gap() {
    let gap = DropKind::NewWorkspace { group_id: Some("g".into()), index: -1 };
    assert_eq!(
        outcome(Some(&gap), true, P, &context(2, 3, 1)),
        Outcome::NewWorkspace { group_id: Some("g".into()), index: None }
    );
    let slot = DropKind::NewWorkspace { group_id: None, index: 2 };
    assert_eq!(
        outcome(Some(&slot), true, P, &context(1, 1, 1)),
        Outcome::MoveWorkspace { group_id: None, index: Some(2) }
    );
}

#[test]
fn no_answer_and_a_surface_refusal_commit_nothing() {
    let context = context(2, 3, 1);
    let none = resolve(None, None, true, P, &context);
    assert_eq!((none.preview, none.outcome), (Preview::None, Outcome::Cancel));
    let kind = DropKind::NewSplit { pane_id: "p2".into(), edge: Edge::Right };
    let refused = resolve(Some(&kind), Some("No room"), true, P, &context);
    assert_eq!(refused.preview, Preview::Refused);
    assert_eq!(refused.refusal, Some(Refusal::Surface { reason: "No room".into() }));
    assert_eq!(refused.outcome, Outcome::Cancel);
    let target = resolve(Some(&kind), None, true, P, &context);
    assert_eq!(target.preview, Preview::Target);
    assert_eq!(target.outcome, Outcome::NewSplit { pane_id: "p2".into(), edge: Edge::Right });
}

/// The first accepted proposal wins unless the tabs' own place comes first.
#[test]
fn the_winner() {
    let context = in_strip(context(3, 3, 1), 0);
    let split = DropKind::NewSplit { pane_id: "p1".into(), edge: Edge::Top };
    let refused = DropKind::NewColumn { screen_id: "s".into(), after_column_id: None };
    assert_eq!(winner(&[None, Some(refused.clone()), Some(split.clone())], &context), Some(2));
    assert_eq!(winner(&[Some(strip(0, None)), Some(split)], &context), None);
    assert!(blocks(&strip(0, None), &context) && !blocks(&refused, &context));
    assert_eq!(winner(&[], &context), None);
}

#[test]
fn the_fallback_split_swaps_left_and_top() {
    assert_eq!(fallback_split(Edge::Left), (SplitDirection::Right, true));
    assert_eq!(fallback_split(Edge::Right), (SplitDirection::Right, false));
    assert_eq!(fallback_split(Edge::Top), (SplitDirection::Down, true));
    assert_eq!(fallback_split(Edge::Bottom), (SplitDirection::Down, false));
}

#[test]
fn a_docks_width() {
    assert_eq!(dock_width("right", Some(0.4), None, false), Some(0.4));
    assert_eq!(dock_width("left", None, None, false), Some(LEFT_DOCK_WIDTH));
    assert_eq!(dock_width("top", None, None, false), Some(DOCK_FALLBACK_WIDTH));
    // A right dock asks for the width beside its anchor, once.
    assert_eq!(dock_width("right", None, None, false), None);
    assert_eq!(dock_width("right", None, Some(0.25), true), Some(0.25));
    assert_eq!(dock_width("right", None, None, true), Some(DOCK_FALLBACK_WIDTH));
}

#[test]
fn a_new_columns_anchor_avoids_the_emptied_pane() {
    let column: Vec<String> = vec!["a".into(), "b".into()];
    let screen: Vec<String> = vec!["b".into(), "c".into()];
    assert_eq!(column_anchor(&column, &screen, None).map(String::as_str), Some("b"));
    assert_eq!(column_anchor(&column, &screen, Some("b")).map(String::as_str), Some("a"));
    let lone: Vec<String> = vec!["b".into()];
    assert_eq!(column_anchor(&lone, &screen, Some("b")).map(String::as_str), Some("c"));
    assert_eq!(column_anchor(&lone, &lone, Some("b")), None);
}

/// The wire shapes the app reads.
#[test]
fn the_wire() {
    let kind: DropKind =
        serde_json::from_str(r#"{"kind":"new_column","screen_id":"s"}"#).expect("kind");
    assert_eq!(kind, DropKind::NewColumn { screen_id: "s".into(), after_column_id: None });
    let context: Context = serde_json::from_str(
        r#"{"source_pane_id":"p","source_pane_tab_count":1,"source_workspace_id":"w",
            "source_workspace_tab_count":1,"dragged_tab_count":1}"#,
    )
    .expect("context");
    assert_eq!(context.source_window_workspace_count, 1);
    let json = serde_json::to_value(Verdict::Refuse { refusal: Refusal::GroupDock }).expect("json");
    assert_eq!(json, serde_json::json!({"verdict": "refuse", "refusal": {"code": "group_dock"}}));
    let json = serde_json::to_value(Outcome::TearOff { point: P }).expect("json");
    assert_eq!(json, serde_json::json!({"outcome": "tear_off", "point": {"x": 5.0, "y": 7.0}}));
}
