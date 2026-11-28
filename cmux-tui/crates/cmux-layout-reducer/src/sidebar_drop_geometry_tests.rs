//! Ported from the app's `SidebarDragGeometryGroupDropTests`,
//! `SidebarDragGeometryEdgeReorderTests`, `SidebarDragGroupHeaderTargetTests`
//! and the outliner part of `SidebarNestedGroupAlignmentTests`.

use super::*;

fn rect(y: f64) -> Frame {
    Frame::new(0.0, y, 200.0, 20.0)
}
fn rect_h(y: f64, height: f64) -> Frame {
    Frame::new(0.0, y, 200.0, height)
}
fn slot(key: &str, parent: Option<&str>, frame: Frame, kind: Kind) -> Slot {
    Slot {
        key: key.into(),
        item: (kind != Kind::Section).then(|| key.into()),
        section: "s".into(),
        parent: parent.map(Into::into),
        frame,
        kind,
        collapsed: false,
    }
}
fn accept(before: bool, into: bool, after: bool, refusal: Option<&str>) -> Acceptance {
    Acceptance { before, into, after, refusal: refusal.map(Into::into) }
}
fn t(before: Option<&str>, after: Option<&str>, parent: Option<&str>) -> Target {
    Target {
        section: "s".into(),
        parent: parent.map(Into::into),
        before: before.map(Into::into),
        after: after.map(Into::into),
        index: None,
    }
}
fn before(item: &str) -> Target {
    t(Some(item), None, None)
}
fn after(item: &str) -> Target {
    t(None, Some(item), None)
}
fn first_in_section() -> Target {
    Target { section: "s".into(), index: Some(0), ..Target::default() }
}
fn into(group: &str) -> Target {
    t(None, None, Some(group))
}

// MARK: dragged groups drop between groups (SidebarDragGeometryGroupDropTests)

/// Home's section header 0..20; loose `w1` 20..40; group `g1` 40..60 with `m1` 60..80 and `m2` 80..100; group
/// `g2` 100..120 with `m3` 120..140.
fn group_slots() -> Vec<Slot> {
    vec![
        slot("s", None, rect(0.0), Kind::Section),
        slot("w1", None, rect(20.0), Kind::Row),
        slot("g1", None, rect(40.0), Kind::Group),
        slot("m1", Some("g1"), rect(60.0), Kind::Row),
        slot("m2", Some("g1"), rect(80.0), Kind::Row),
        slot("g2", None, rect(100.0), Kind::Group),
        slot("m3", Some("g2"), rect(120.0), Kind::Row),
    ]
}

/// What `drag_begin` gives for a dragged group: no member row of a group and no group header's middle takes it.
fn group_drag() -> HashMap<String, Acceptance> {
    HashMap::from([
        ("s".into(), accept(false, true, false, None)),
        ("w1".into(), accept(true, false, true, None)),
        ("g1".into(), accept(true, false, true, None)),
        ("m1".into(), accept(false, false, false, Some("nesting"))),
        ("m2".into(), accept(false, false, false, Some("nesting"))),
        ("g2".into(), accept(true, false, true, None)),
        ("m3".into(), accept(false, false, false, Some("nesting"))),
    ])
}

fn probe(y: f64, acceptance: HashMap<String, Acceptance>) -> Option<Hit> {
    Geometry::new(group_slots(), acceptance).hit(100.0, y)
}

#[test]
fn dragged_group_drops_between_groups() {
    let cases = [
        // A member row in the upper half of g1's block (40..100): before g1.
        (65.0, before("g1")),
        // The lower half: after g1, between g1 and g2.
        (85.0, after("g1")),
        // g1's header middle and its bottom band: before g1 (the header is the block's top).
        (50.0, before("g1")),
        (58.0, before("g1")),
        // g1's header top band: before g1, as before.
        (42.0, before("g1")),
        // The last group's last member: after g2, the list's end.
        (135.0, after("g2")),
        // g2's header: before g2, between g1 and g2.
        (110.0, before("g2")),
        // A loose row keeps its halves.
        (25.0, before("w1")),
        (35.0, after("w1")),
        // The section header: first in the section, the top of the list under Home.
        (5.0, first_in_section()),
    ];
    for (y, expected) in cases {
        let hit = probe(y, group_drag()).unwrap_or_else(|| panic!("no hit at {y}"));
        assert_eq!(hit.target, Some(expected), "at {y}");
        assert_eq!(hit.refusal, None, "at {y}");
    }
}

#[test]
fn every_gap_between_groups_is_reachable() {
    let targets: Vec<Target> = (0..140)
        .filter_map(|y| probe(f64::from(y), group_drag()).and_then(|hit| hit.target))
        .collect();
    assert_eq!(targets.len(), 140);
    for expected in [first_in_section(), after("w1"), after("g1"), before("g2"), after("g2")] {
        assert!(targets.contains(&expected), "{expected:?} is never reached");
    }
    assert!(targets.iter().all(|target| target.parent.is_none()));
}

#[test]
fn dragged_workspace_still_drops_into_and_inside_groups() {
    // A workspace drag (empty table: every place takes it) keeps the into band and the member slots.
    assert_eq!(probe(50.0, HashMap::new()).and_then(|hit| hit.target), Some(into("g1")));
    assert_eq!(
        probe(65.0, HashMap::new()).and_then(|hit| hit.target),
        Some(t(Some("m1"), None, Some("g1")))
    );
    assert_eq!(probe(25.0, HashMap::new()).and_then(|hit| hit.target), Some(before("w1")));
}

#[test]
fn group_that_takes_nothing_stays_refused() {
    // Another machine's group whose header sides are refused too: the member row stays refused.
    let mut table = group_drag();
    table.insert("g1".into(), accept(false, false, false, Some("cross_machine")));
    let refused = probe(65.0, table).unwrap_or_else(|| panic!("no hit"));
    assert_eq!(refused.target, None);
    assert_eq!(refused.refusal.as_deref(), Some("nesting"));
}

#[test]
fn a_refused_slot_without_a_reason_says_refused() {
    let mut table = group_drag();
    table.insert("w1".into(), accept(false, false, false, None));
    let refused = probe(25.0, table).unwrap_or_else(|| panic!("no hit"));
    assert_eq!(refused.target, None);
    assert_eq!(refused.refusal.as_deref(), Some("refused"));
}

#[test]
fn a_header_the_table_lacks_takes_the_drop() {
    let mut table = group_drag();
    table.remove("s");
    assert_eq!(probe(5.0, table).and_then(|hit| hit.target), Some(first_in_section()));
}

// MARK: the midpoint rule (SidebarDragGeometryEdgeReorderTests)

/// The list without the dragged card: section header 0..20; loose `a` 20..40; tall loose `b` 40..80; loose `c`
/// 80..100; group `g` 100..120 with members `m1` 120..140 and `m2` 140..160.
fn edge_geometry() -> Geometry {
    Geometry::new(
        vec![
            slot("s", None, rect_h(0.0, 20.0), Kind::Section),
            slot("a", None, rect_h(20.0, 20.0), Kind::Row),
            slot("b", None, rect_h(40.0, 40.0), Kind::Row),
            slot("c", None, rect_h(80.0, 20.0), Kind::Row),
            slot("g", None, rect_h(100.0, 20.0), Kind::Group),
            slot("m1", Some("g"), rect_h(120.0, 20.0), Kind::Row),
            slot("m2", Some("g"), rect_h(140.0, 20.0), Kind::Row),
        ],
        HashMap::new(),
    )
}

/// The drop for a card `height` tall with its top at `top`, the gap open at `gap_y` (as tall as the card): none
/// when the drop holds, else the hit's target.
fn edge_target(
    top: f64,
    height: f64,
    up: bool,
    gap_y: f64,
    current: Option<Target>,
    reversing: bool,
) -> Option<Option<Target>> {
    let geometry = edge_geometry();
    let edge = Edge {
        top,
        bottom: top + height,
        x: 100.0,
        moving_up: up,
        gap_y: Some(gap_y),
        gap_height: height,
        current,
        reversing,
    };
    let y = geometry.edge_y(&edge)?;
    Some(geometry.hit(100.0, y).and_then(|hit| hit.target))
}

fn moved(top: f64, up: bool, gap_y: f64) -> Option<Option<Target>> {
    edge_target(top, 20.0, up, gap_y, None, false)
}

#[test]
fn a_card_at_rest_stays() {
    assert_eq!(moved(80.0, true, 80.0), Some(Some(before("c"))));
    assert_eq!(moved(80.0, false, 80.0), Some(Some(before("c"))));
}

#[test]
fn up_swaps_when_the_top_edge_passes_the_middle_above() {
    assert_eq!(moved(61.0, true, 80.0), Some(Some(after("b"))));
    assert_eq!(moved(59.0, true, 80.0), Some(Some(before("b"))));
}

#[test]
fn down_swaps_when_the_bottom_edge_passes_the_middle_below() {
    assert_eq!(moved(59.0, false, 40.0), Some(Some(before("b"))));
    assert_eq!(moved(61.0, false, 40.0), Some(Some(after("b"))));
}

#[test]
fn a_tall_card_moves_down_by_its_bottom_edge() {
    // The gap at 80 (between b and c): c is drawn at 140..160, its middle at 150.
    assert_eq!(edge_target(89.0, 60.0, false, 80.0, None, false), Some(Some(before("c"))));
    assert_eq!(edge_target(91.0, 60.0, false, 80.0, None, false), Some(Some(after("c"))));
}

#[test]
fn a_tall_card_moves_up_by_its_top_edge() {
    // The gap at 40 (between a and b): a's middle is at 30.
    assert_eq!(edge_target(31.0, 60.0, true, 40.0, None, false), Some(Some(after("a"))));
    assert_eq!(edge_target(29.0, 60.0, true, 40.0, None, false), Some(Some(before("a"))));
}

#[test]
fn a_member_moves_up_inside_its_group() {
    // The gap at 140 (between m1 and m2): m1's middle is at 130.
    assert_eq!(moved(131.0, true, 140.0), Some(Some(t(None, Some("m1"), Some("g")))));
    assert_eq!(moved(129.0, true, 140.0), Some(Some(t(Some("m1"), None, Some("g")))));
}

#[test]
fn turning_back_needs_the_margin() {
    let swapped = before("b");
    let margin = hysteresis(40.0);
    // Just past the middle: held.
    assert_eq!(edge_target(61.0, 20.0, false, 40.0, Some(swapped.clone()), true), None);
    // Past the middle by the margin: back after b.
    assert_eq!(
        edge_target(61.0 + margin, 20.0, false, 40.0, Some(swapped.clone()), true),
        Some(Some(after("b")))
    );
    // The same point, still moving the way it swapped: no margin.
    assert_eq!(edge_target(61.0, 20.0, false, 40.0, Some(swapped), false), Some(Some(after("b"))));
}

#[test]
fn a_reversing_drag_already_at_its_drop_is_not_held() {
    assert_eq!(
        edge_target(80.0, 20.0, false, 80.0, Some(before("c")), true),
        Some(Some(before("c")))
    );
}

#[test]
fn hysteresis_is_a_fifth_of_the_row_up_to_eight_points() {
    assert_eq!(hysteresis(20.0), 4.0);
    assert_eq!(hysteresis(100.0), MAX_HYSTERESIS);
    assert_eq!(hysteresis(-5.0), 0.0);
}

#[test]
fn base_y_removes_the_open_gap() {
    assert_eq!(base_y(30.0, Some(40.0), 20.0), 30.0);
    assert_eq!(base_y(70.0, Some(40.0), 20.0), 50.0);
    // Inside the gap: the gap's top.
    assert_eq!(base_y(45.0, Some(40.0), 20.0), 40.0);
    assert_eq!(base_y(45.0, None, 20.0), 45.0);
}

// MARK: group headers (SidebarDragGroupHeaderTargetTests)

/// Loose `w1` 0..20; open group `g` 20..40 with `m1` 40..60 and `m2` 60..80; loose `w2` 80..100.
fn header_slots() -> Vec<Slot> {
    vec![
        slot("w1", None, rect(0.0), Kind::Row),
        slot("g", None, rect(20.0), Kind::Group),
        slot("m1", Some("g"), rect(40.0), Kind::Row),
        slot("m2", Some("g"), rect(60.0), Kind::Row),
        slot("w2", None, rect(80.0), Kind::Row),
    ]
}

fn target_at(geometry: &Geometry, y: f64) -> Option<Target> {
    geometry.hit(100.0, y).and_then(|hit| hit.target)
}

#[test]
fn an_open_headers_bottom_band_drops_before_its_first_member() {
    let geometry = Geometry::new(header_slots(), HashMap::new());
    // 38: the header's bottom quarter, right over m1.
    assert_eq!(target_at(&geometry, 38.0), Some(t(Some("m1"), None, Some("g"))));
    // The header's middle still drops into the group, its top quarter before it.
    assert_eq!(target_at(&geometry, 30.0), Some(into("g")));
    assert_eq!(target_at(&geometry, 22.0), Some(before("g")));
}

#[test]
fn a_closed_headers_bottom_band_still_drops_after_the_group() {
    let closed: Vec<Slot> = header_slots()
        .into_iter()
        .filter(|slot| slot.parent.is_none())
        .map(|mut slot| {
            if slot.key == "w2" {
                slot.frame = rect(40.0);
            }
            slot
        })
        .collect();
    assert_eq!(target_at(&Geometry::new(closed, HashMap::new()), 38.0), Some(after("g")));
}

#[test]
fn a_collapsed_header_with_a_kept_member_still_drops_after_the_group() {
    let kept: Vec<Slot> = header_slots()
        .into_iter()
        .filter(|slot| slot.key != "m2")
        .map(|mut slot| {
            if slot.key == "g" {
                slot.collapsed = true;
            }
            if slot.key == "w2" {
                slot.frame = rect(60.0);
            }
            slot
        })
        .collect();
    assert_eq!(target_at(&Geometry::new(kept, HashMap::new()), 38.0), Some(after("g")));
}

// MARK: tiles, sections, empty groups and beside

#[test]
fn tiles_on_one_line_split_left_and_right() {
    let slots = vec![
        slot("s", None, rect(0.0), Kind::Section),
        slot("t1", None, Frame::new(0.0, 20.0, 50.0, 30.0), Kind::Tile),
        slot("t2", None, Frame::new(50.0, 20.0, 50.0, 30.0), Kind::Tile),
        slot("t3", None, Frame::new(100.0, 20.0, 50.0, 30.0), Kind::Tile),
        slot("t4", None, Frame::new(0.0, 50.0, 50.0, 30.0), Kind::Tile),
    ];
    let geometry = Geometry::new(slots, HashMap::new());
    let at = |x: f64, y: f64| geometry.hit(x, y).and_then(|hit| hit.target);
    assert_eq!(at(10.0, 30.0), Some(before("t1")));
    assert_eq!(at(40.0, 30.0), Some(after("t1")));
    assert_eq!(at(60.0, 30.0), Some(before("t2")));
    assert_eq!(at(140.0, 30.0), Some(after("t3")));
    // Past the last tile of the line: the line's last tile.
    assert_eq!(at(400.0, 30.0), Some(after("t3")));
    // The next line.
    assert_eq!(at(10.0, 60.0), Some(before("t4")));
}

#[test]
fn an_empty_group_row_drops_into_its_group() {
    let mut empty = slot("g-empty", Some("g"), rect(40.0), Kind::EmptyGroup);
    empty.item = Some("g".into());
    let slots = vec![slot("g", None, rect(20.0), Kind::Group), empty];
    let geometry = Geometry::new(slots, HashMap::new());
    assert_eq!(geometry.hit(100.0, 45.0).map(|hit| hit.zone), Some(Zone::Into));
    assert_eq!(target_at(&geometry, 45.0), Some(into("g")));
}

#[test]
fn above_and_below_the_slots_hit_the_nearest_line() {
    let geometry = Geometry::new(header_slots(), HashMap::new());
    assert_eq!(target_at(&geometry, -40.0), Some(before("w1")));
    assert_eq!(target_at(&geometry, 400.0), Some(after("w2")));
    assert_eq!(Geometry::new(Vec::new(), HashMap::new()).hit(0.0, 0.0), None);
}

#[test]
fn the_hit_names_the_slot_as_given() {
    let geometry = Geometry::new(header_slots().into_iter().rev().collect(), HashMap::new());
    let hit = geometry.hit(100.0, 5.0).unwrap_or_else(|| panic!("no hit"));
    assert_eq!(geometry.slots().get(hit.slot).map(|slot| slot.key.as_str()), Some("w1"));
}

#[test]
fn beside_drops_right_before_or_after_a_key() {
    let geometry = Geometry::new(group_slots(), group_drag());
    assert_eq!(geometry.beside("g2", false).and_then(|hit| hit.target), Some(before("g2")));
    assert_eq!(geometry.beside("g1", true).and_then(|hit| hit.target), Some(after("g1")));
    // A section's slot: first in it.
    assert_eq!(geometry.beside("s", true).and_then(|hit| hit.target), Some(first_in_section()));
    // A refused place, or a key the list lacks: none.
    assert_eq!(geometry.beside("m1", false), None);
    assert_eq!(geometry.beside("nope", false), None);
}

// MARK: levels and the outliner rule (SidebarNestedGroupAlignmentTests, SidebarIndent)

/// Group `a` 0..20 holding `w` 20..40 and group `b` 40..60, which holds `x` 60..80 and group `c` 80..100,
/// which holds `y` 100..120; loose `z` 120..140.
fn nested_slots() -> Vec<Slot> {
    vec![
        slot("a", None, rect(0.0), Kind::Group),
        slot("w", Some("a"), rect(20.0), Kind::Row),
        slot("b", Some("a"), rect(40.0), Kind::Group),
        slot("x", Some("b"), rect(60.0), Kind::Row),
        slot("c", Some("b"), rect(80.0), Kind::Group),
        slot("y", Some("c"), rect(100.0), Kind::Row),
        slot("z", None, rect(120.0), Kind::Row),
    ]
}

fn outline() -> Option<Outline> {
    Some(Outline { indent: Indent::new(8.0), leading: 10.0, width: 400.0 })
}

#[test]
fn levels_follow_the_group_tree() {
    let geometry = Geometry::new(nested_slots(), HashMap::new());
    let levels: Vec<i32> = geometry.slots().iter().map(|slot| geometry.level(slot)).collect();
    assert_eq!(levels, vec![0, 1, 1, 2, 2, 3, 0]);
    let into = Hit { slot: 4, zone: Zone::Into, target: None, refusal: None };
    assert_eq!(geometry.drop_level(&into), 3);
    let after = Hit { slot: 4, zone: Zone::After, target: None, refusal: None };
    assert_eq!(geometry.drop_level(&after), 2);
}

#[test]
fn the_outliner_rule_picks_the_ancestor_by_x() {
    let geometry = Geometry::new(nested_slots(), HashMap::new()).with_outline(outline());
    let below_y = |x: f64| geometry.hit(10.0 + x, 118.0).and_then(|hit| hit.target);
    // At y's own level (3: two steps in) the drop stays after y in c.
    assert_eq!(below_y(17.0), Some(t(None, Some("y"), Some("c"))));
    // One step in: level 2, after c in b.
    assert_eq!(below_y(9.0), Some(t(None, Some("c"), Some("b"))));
    // Level 1 (the rest of the first step): after b in a.
    assert_eq!(below_y(5.0), Some(t(None, Some("b"), Some("a"))));
    // The first half step: level 0, after a at the top.
    assert_eq!(below_y(1.0), Some(after("a")));
}

#[test]
fn without_the_outline_the_bottom_edge_keeps_its_row() {
    let geometry = Geometry::new(nested_slots(), HashMap::new());
    assert_eq!(
        geometry.hit(11.0, 118.0).and_then(|hit| hit.target),
        Some(t(None, Some("y"), Some("c")))
    );
}

#[test]
fn the_outliner_rule_never_lands_inside_a_block_above() {
    let geometry = Geometry::new(nested_slots(), HashMap::new()).with_outline(outline());
    // Below x: b's subtree goes on under it (c, y), so only x's own place qualifies.
    assert_eq!(
        geometry.hit(11.0, 78.0).and_then(|hit| hit.target),
        Some(t(None, Some("x"), Some("b")))
    );
}

#[test]
fn an_open_headers_after_is_inside_its_block() {
    let geometry = Geometry::new(nested_slots(), HashMap::new()).with_outline(outline());
    // c's bottom quarter: before its first member y, whatever the x.
    assert_eq!(
        geometry.hit(11.0, 98.0).and_then(|hit| hit.target),
        Some(t(Some("y"), None, Some("c")))
    );
}

#[test]
fn the_indent_level_at_x() {
    let indent = Indent::new(8.0);
    // Level 0 shares level 1's x: the first half step is 0, the rest of the step 1, then one per step.
    assert_eq!(indent.level_at_x(0.0, 400.0, 0, 5), 0);
    assert_eq!(indent.level_at_x(3.9, 400.0, 0, 5), 0);
    assert_eq!(indent.level_at_x(4.0, 400.0, 0, 5), 1);
    assert_eq!(indent.level_at_x(8.0, 400.0, 0, 5), 2);
    assert_eq!(indent.level_at_x(16.0, 400.0, 0, 5), 3);
    // Clamped to the range.
    assert_eq!(indent.level_at_x(100.0, 400.0, 0, 3), 3);
    assert_eq!(indent.level_at_x(-100.0, 400.0, 2, 3), 2);
    // A zero step picks the range's low end.
    assert_eq!(Indent::new(0.0).level_at_x(50.0, 400.0, 1, 4), 1);
}

#[test]
fn the_indent_level_at_x_with_top_level_indent() {
    let indent = Indent { indents_top_level: true, ..Indent::new(8.0) };
    assert_eq!(indent.level_at_x(3.9, 400.0, 0, 5), 0);
    assert_eq!(indent.level_at_x(4.0, 400.0, 0, 5), 1);
    assert_eq!(indent.level_at_x(12.0, 400.0, 0, 5), 2);
}

#[test]
fn past_the_cap_the_deepest_level_wins() {
    let indent = Indent::new(8.0);
    // 166 pt wide: (166 - 150) / 8 = 2 steps fit.
    assert_eq!(indent.visual_cap(166.0), 2.0);
    assert_eq!(indent.level_at_x(16.0, 166.0, 0, 5), 5);
    assert_eq!(indent.level_at_x(8.0, 166.0, 0, 5), 2);
    // An unbounded width keeps the level cap and never traps.
    assert_eq!(indent.visual_cap(f64::MAX), 6.0);
    assert_eq!(indent.visual_cap(f64::INFINITY), 6.0);
    assert_eq!(indent.visual_cap(f64::NAN), 1.0);
    assert_eq!(indent.visual_cap(10.0), 1.0);
}

#[test]
fn a_cycle_in_the_group_tree_never_hangs() {
    let slots = vec![
        slot("p", Some("q"), rect(0.0), Kind::Group),
        slot("q", Some("p"), rect(20.0), Kind::Group),
    ];
    let geometry = Geometry::new(slots, HashMap::new()).with_outline(outline());
    assert!(geometry.hit(10.0, 38.0).is_some());
    assert!(geometry.slots().iter().all(|slot| geometry.level(slot) < 4));
}

#[test]
fn the_wire_shapes_round_trip() {
    let slot: Slot = serde_json::from_value(serde_json::json!({
        "key": "g", "item": "g", "section": "s",
        "frame": {"x": 0.0, "y": 20.0, "width": 200.0, "height": 20.0},
        "kind": "empty_group",
    }))
    .unwrap_or_else(|error| panic!("{error}"));
    assert_eq!(slot.kind, Kind::EmptyGroup);
    assert!(!slot.collapsed && slot.parent.is_none());
    let acceptance: Acceptance = serde_json::from_value(serde_json::json!({"into": true}))
        .unwrap_or_else(|error| panic!("{error}"));
    assert_eq!(acceptance, accept(false, true, false, None));
    assert_eq!(
        serde_json::to_value(first_in_section()).unwrap_or_else(|error| panic!("{error}")),
        serde_json::json!({"section": "s", "index": 0})
    );
    let indent: Indent = serde_json::from_value(serde_json::json!({"step": 8.0}))
        .unwrap_or_else(|error| panic!("{error}"));
    assert_eq!(indent, Indent::new(8.0));
}
