//! Ports of the app's SidebarDragGeometry tests (GroupDrop, EdgeReorder,
//! GroupHeaderTarget, NestedGroupAlignment) plus the transliterated vectors.

use super::*;

fn slot(key: &str, kind: SlotKind, parent: Option<&str>, y: f64, height: f64) -> Slot {
    Slot {
        key: key.to_owned(),
        item: (kind != SlotKind::Section).then(|| key.to_owned()),
        section: "s".to_owned(),
        parent: parent.map(str::to_owned),
        frame: Rect { x: 0.0, y, width: 200.0, height },
        kind,
        collapsed: false,
    }
}

fn acc(before: bool, into: bool, after: bool, refusal: Option<&str>) -> Acceptance {
    Acceptance { before, into, after, refusal: refusal.map(str::to_owned) }
}

fn before(item: &str, parent: Option<&str>) -> Target {
    Target {
        section: "s".to_owned(),
        parent: parent.map(str::to_owned),
        before: Some(item.to_owned()),
        after: None,
        index: None,
    }
}

fn after(item: &str, parent: Option<&str>) -> Target {
    Target {
        section: "s".to_owned(),
        parent: parent.map(str::to_owned),
        before: None,
        after: Some(item.to_owned()),
        index: None,
    }
}

fn into(parent: &str) -> Target {
    Target {
        section: "s".to_owned(),
        parent: Some(parent.to_owned()),
        before: None,
        after: None,
        index: None,
    }
}

fn first_in_section() -> Target {
    Target { section: "s".to_owned(), parent: None, before: None, after: None, index: Some(0) }
}

fn group_slots() -> Vec<Slot> {
    vec![
        slot("s", SlotKind::Section, None, 0.0, 20.0),
        slot("w1", SlotKind::Row, None, 20.0, 20.0),
        slot("g1", SlotKind::Group, None, 40.0, 20.0),
        slot("m1", SlotKind::Row, Some("g1"), 60.0, 20.0),
        slot("m2", SlotKind::Row, Some("g1"), 80.0, 20.0),
        slot("g2", SlotKind::Group, None, 100.0, 20.0),
        slot("m3", SlotKind::Row, Some("g2"), 120.0, 20.0),
    ]
}

fn group_drag_table() -> HashMap<String, Acceptance> {
    let mut table = HashMap::new();
    table.insert("s".to_owned(), acc(false, true, false, None));
    table.insert("w1".to_owned(), acc(true, false, true, None));
    table.insert("g1".to_owned(), acc(true, false, true, None));
    table.insert("g2".to_owned(), acc(true, false, true, None));
    for member in ["m1", "m2", "m3"] {
        table.insert(member.to_owned(), acc(false, false, false, Some("nesting")));
    }
    table
}

fn target_at(geometry: &Geometry, y: f64) -> Option<Target> {
    geometry.hit(100.0, y).and_then(|h| h.target)
}

#[test]
fn group_drag_over_members_goes_around_the_group() {
    let geometry = Geometry::new(&group_slots(), group_drag_table());
    assert_eq!(target_at(&geometry, 65.0), Some(before("g1", None)));
    assert_eq!(target_at(&geometry, 85.0), Some(after("g1", None)));
    for y in [50.0, 58.0, 42.0] {
        assert_eq!(target_at(&geometry, y), Some(before("g1", None)), "y {y}");
    }
    assert_eq!(target_at(&geometry, 135.0), Some(after("g2", None)));
    assert_eq!(target_at(&geometry, 110.0), Some(before("g2", None)));
    assert_eq!(target_at(&geometry, 25.0), Some(before("w1", None)));
    assert_eq!(target_at(&geometry, 35.0), Some(after("w1", None)));
    assert_eq!(target_at(&geometry, 5.0), Some(first_in_section()));
}

#[test]
fn group_drag_never_nests() {
    let geometry = Geometry::new(&group_slots(), group_drag_table());
    let targets: Vec<Target> =
        (0..140).filter_map(|y| target_at(&geometry, f64::from(y))).collect();
    assert_eq!(targets.len(), 140);
    assert!(targets.iter().all(|t| t.parent.is_none()));
}

#[test]
fn an_empty_table_accepts_every_place() {
    let geometry = Geometry::new(&group_slots(), HashMap::new());
    assert_eq!(target_at(&geometry, 50.0), Some(into("g1")));
    assert_eq!(target_at(&geometry, 65.0), Some(before("m1", Some("g1"))));
    assert_eq!(target_at(&geometry, 25.0), Some(before("w1", None)));
}

#[test]
fn a_refused_group_keeps_the_members_refusal() {
    let mut table = group_drag_table();
    table.insert("g1".to_owned(), acc(false, false, false, Some("cross_machine")));
    let geometry = Geometry::new(&group_slots(), table);
    let hit = geometry.hit(100.0, 65.0).expect("hit");
    assert_eq!(hit.target, None);
    assert_eq!(hit.refusal.as_deref(), Some("nesting"));
}

fn edge_slots() -> Vec<Slot> {
    vec![
        slot("s", SlotKind::Section, None, 0.0, 20.0),
        slot("a", SlotKind::Row, None, 20.0, 20.0),
        slot("b", SlotKind::Row, None, 40.0, 40.0),
        slot("c", SlotKind::Row, None, 80.0, 20.0),
        slot("g", SlotKind::Group, None, 100.0, 20.0),
        slot("m1", SlotKind::Row, Some("g"), 120.0, 20.0),
        slot("m2", SlotKind::Row, Some("g"), 140.0, 20.0),
    ]
}

fn edge_target(
    geometry: &Geometry,
    top: f64,
    height: f64,
    up: bool,
    gap_y: f64,
    current: Option<&Target>,
    reversing: bool,
) -> Option<Target> {
    let y =
        geometry.edge_y(top, top + height, 100.0, up, Some(gap_y), height, current, reversing)?;
    target_at(geometry, y)
}

#[test]
fn edge_reorder_uses_the_leading_edge() {
    let geometry = Geometry::new(&edge_slots(), HashMap::new());
    assert_eq!(
        edge_target(&geometry, 80.0, 20.0, true, 80.0, None, false),
        Some(before("c", None))
    );
    assert_eq!(
        edge_target(&geometry, 80.0, 20.0, false, 80.0, None, false),
        Some(before("c", None))
    );
    assert_eq!(edge_target(&geometry, 61.0, 20.0, true, 80.0, None, false), Some(after("b", None)));
    assert_eq!(
        edge_target(&geometry, 59.0, 20.0, true, 80.0, None, false),
        Some(before("b", None))
    );
    assert_eq!(
        edge_target(&geometry, 59.0, 20.0, false, 40.0, None, false),
        Some(before("b", None))
    );
    assert_eq!(
        edge_target(&geometry, 61.0, 20.0, false, 40.0, None, false),
        Some(after("b", None))
    );
    assert_eq!(
        edge_target(&geometry, 89.0, 60.0, false, 80.0, None, false),
        Some(before("c", None))
    );
    assert_eq!(
        edge_target(&geometry, 91.0, 60.0, false, 80.0, None, false),
        Some(after("c", None))
    );
    assert_eq!(edge_target(&geometry, 31.0, 60.0, true, 40.0, None, false), Some(after("a", None)));
    assert_eq!(
        edge_target(&geometry, 29.0, 60.0, true, 40.0, None, false),
        Some(before("a", None))
    );
    assert_eq!(
        edge_target(&geometry, 131.0, 20.0, true, 140.0, None, false),
        Some(after("m1", Some("g")))
    );
    assert_eq!(
        edge_target(&geometry, 129.0, 20.0, true, 140.0, None, false),
        Some(before("m1", Some("g")))
    );
}

#[test]
fn a_turning_back_drag_holds_until_past_the_hysteresis() {
    let geometry = Geometry::new(&edge_slots(), HashMap::new());
    let current = before("b", None);
    assert_eq!(
        geometry.edge_y(61.0, 81.0, 100.0, false, Some(40.0), 20.0, Some(&current), true),
        None
    );
    let past = 61.0 + hysteresis(40.0);
    assert_eq!(past, 69.0);
    assert_eq!(
        edge_target(&geometry, past, 20.0, false, 40.0, Some(&current), true),
        Some(after("b", None))
    );
    assert_eq!(
        edge_target(&geometry, 61.0, 20.0, false, 40.0, Some(&current), false),
        Some(after("b", None))
    );
}

#[test]
fn an_open_header_bottom_quarter_goes_before_its_first_member() {
    let slots = vec![
        slot("w1", SlotKind::Row, None, 0.0, 20.0),
        slot("g", SlotKind::Group, None, 20.0, 20.0),
        slot("m1", SlotKind::Row, Some("g"), 40.0, 20.0),
        slot("m2", SlotKind::Row, Some("g"), 60.0, 20.0),
        slot("w2", SlotKind::Row, None, 80.0, 20.0),
    ];
    let geometry = Geometry::new(&slots, HashMap::new());
    assert_eq!(target_at(&geometry, 38.0), Some(before("m1", Some("g"))));
    assert_eq!(target_at(&geometry, 30.0), Some(into("g")));
    assert_eq!(target_at(&geometry, 22.0), Some(before("g", None)));
}

#[test]
fn a_closed_header_bottom_quarter_goes_after_it() {
    let slots = vec![
        slot("w1", SlotKind::Row, None, 0.0, 20.0),
        slot("g", SlotKind::Group, None, 20.0, 20.0),
        slot("w2", SlotKind::Row, None, 40.0, 20.0),
    ];
    let geometry = Geometry::new(&slots, HashMap::new());
    assert_eq!(target_at(&geometry, 38.0), Some(after("g", None)));

    let mut header = slot("g", SlotKind::Group, None, 20.0, 20.0);
    header.collapsed = true;
    let collapsed = vec![
        slot("w1", SlotKind::Row, None, 0.0, 20.0),
        header,
        slot("m1", SlotKind::Row, Some("g"), 40.0, 20.0),
        slot("w2", SlotKind::Row, None, 60.0, 20.0),
    ];
    let geometry = Geometry::new(&collapsed, HashMap::new());
    assert_eq!(target_at(&geometry, 38.0), Some(after("g", None)));
}

#[test]
fn indent_offsets_cap_at_the_visual_levels() {
    let indent = Indent {
        step: 8.0,
        minimum_label_width: 150.0,
        max_visual_levels: 6,
        indents_top_level: false,
    };
    assert_eq!(indent.offset(3, f64::INFINITY), 16.0);
    assert_eq!(indent.offset(99, f64::MAX), 6.0 * 8.0);
    assert_eq!(indent.offset(0, 400.0), 0.0);
    assert_eq!(indent.visual_cap(100.0), 1);
    let zero = Indent { step: 0.0, ..indent };
    assert_eq!(zero.visual_cap(400.0), 0);
    assert_eq!(zero.level_at_x(40.0, 400.0, 1, 4), 1);
}

#[test]
fn nested_level_counts_enclosing_groups() {
    let slots = vec![
        slot("g", SlotKind::Group, None, 0.0, 20.0),
        slot("h", SlotKind::Group, Some("g"), 20.0, 20.0),
        slot("m", SlotKind::Row, Some("h"), 40.0, 20.0),
    ];
    let geometry = Geometry::new(&slots, HashMap::new());
    let levels: Vec<i64> = slots.iter().map(|s| geometry.level(s)).collect();
    assert_eq!(levels, vec![0, 1, 2]);
}

#[test]
fn the_outline_drops_after_the_ancestor_the_x_picks() {
    let slots = vec![
        slot("g", SlotKind::Group, None, 0.0, 20.0),
        slot("h", SlotKind::Group, Some("g"), 20.0, 20.0),
        slot("m", SlotKind::Row, Some("h"), 40.0, 20.0),
        slot("w", SlotKind::Row, None, 60.0, 20.0),
    ];
    let mut geometry = Geometry::new(&slots, HashMap::new());
    let indent = Indent {
        step: 16.0,
        minimum_label_width: 150.0,
        max_visual_levels: 6,
        indents_top_level: true,
    };
    geometry.outline = Some(Outline { indent, leading: 0.0, width: 300.0 });
    // Bottom half of m, at m's own level: stays after m.
    assert_eq!(geometry.hit(40.0, 55.0).and_then(|h| h.target), Some(after("m", Some("h"))));
    // Left of h's level: after h, in g.
    assert_eq!(geometry.hit(17.0, 55.0).and_then(|h| h.target), Some(after("h", Some("g"))));
    // At the edge: after g, top level.
    assert_eq!(geometry.hit(0.0, 55.0).and_then(|h| h.target), Some(after("g", None)));
}

const VECTORS: &str = include_str!("../../../../schemas/sidebar-drag-geometry/vectors.json");

#[test]
fn geometry_vectors_match_the_swift_transliteration() {
    let doc: serde_json::Value = serde_json::from_str(VECTORS).expect("vectors");
    let cases = doc["geometry"].as_array().expect("geometry cases");
    assert!(cases.len() >= 50);
    for (index, case) in cases.iter().enumerate() {
        let request: Request = serde_json::from_value(case.clone()).expect("request");
        let reply = serde_json::to_value(respond(&request)).expect("reply");
        let expected = &case["answers"];
        let answers = reply["answers"].as_array().expect("answers");
        for (q, (got, want)) in
            answers.iter().zip(expected.as_array().expect("expected")).enumerate()
        {
            assert!(
                same(got, want),
                "case {index} query {q}: {:?}\ngot {got}\nwant {want}",
                case["queries"][q]
            );
        }
        assert_eq!(answers.len(), expected.as_array().map_or(0, Vec::len));
    }
}

#[test]
fn indent_vectors_match_the_swift_transliteration() {
    let doc: serde_json::Value = serde_json::from_str(VECTORS).expect("vectors");
    for (index, case) in doc["indent"].as_array().expect("indent cases").iter().enumerate() {
        let indent: Indent = serde_json::from_value(case["indent"].clone()).expect("indent");
        let width = case["width"].as_f64().expect("width");
        let level = case["level"].as_i64().expect("level");
        let (low, high) =
            (case["low"].as_i64().expect("low"), case["high"].as_i64().expect("high"));
        let x = case["x"].as_f64().expect("x");
        assert_eq!(
            indent.visual_cap(width),
            case["visual_cap"].as_i64().expect("cap"),
            "case {index}"
        );
        assert_eq!(
            indent.offset(level, width),
            case["offset"].as_f64().expect("offset"),
            "case {index}"
        );
        assert_eq!(
            indent.level_at_x(x, width, low, high),
            case["level_at_x"].as_i64().expect("lx"),
            "case {index}"
        );
    }
}

/// JSON equality that reads every number as f64 (Python writes 20.0 where serde may write 20).
fn same(a: &serde_json::Value, b: &serde_json::Value) -> bool {
    use serde_json::Value;
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}
