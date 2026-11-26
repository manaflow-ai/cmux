//! The Swift tests of `SidebarGroupDragPlan`, `SidebarLayoutMetrics` and `WorkspaceRowContent`,
//! mirrored, and a replay of the Swift transliteration's vectors.

use super::*;

const VECTORS: &str = include_str!("../../../../schemas/sidebar-row-rules/vectors.json");

fn row(kind: RowKind, y: f64) -> Row {
    Row {
        kind,
        id: None,
        y,
        height: 20.0,
        group: None,
        depth: 0,
        sibling_index: 0,
        parent_index: None,
        stands_for_group: false,
    }
}

fn base() -> Vec<Row> {
    let mut g = row(RowKind::Group, 52.0);
    g.id = Some("g".into());
    g.sibling_index = 1;
    let mut a = row(RowKind::Workspace, 26.0);
    a.sibling_index = 0;
    let member = |y| {
        let mut r = row(RowKind::Workspace, y);
        r.group = Some("g".into());
        r.depth = 1;
        r
    };
    let mut b = row(RowKind::Workspace, 124.0);
    b.sibling_index = 2;
    let mut c = row(RowKind::Workspace, 150.0);
    c.sibling_index = 3;
    vec![row(RowKind::Section, 0.0), a, g, member(74.0), member(98.0), b, c]
}

fn plan(allowed: Option<Vec<bool>>) -> Plan {
    Plan::new(blocks(&base()), 52.0, 60.0, 6.0, 6.0, allowed)
}

#[test]
fn blocks_are_the_top_level_rows_with_a_group_whole() {
    let p = plan(None);
    let ranges: Vec<[f64; 2]> = p.blocks.iter().map(|b| b.range).collect();
    assert_eq!(
        ranges,
        vec![[0.0, 20.0], [26.0, 46.0], [52.0, 118.0], [124.0, 144.0], [150.0, 170.0]]
    );
    let heads: Vec<usize> = p.blocks.iter().map(|b| b.head).collect();
    assert_eq!(heads, vec![0, 1, 2, 5, 6]);
}

#[test]
fn blocks_keep_members_with_their_head() {
    let mut g = row(RowKind::Group, 60.0);
    g.id = Some("g".into());
    g.group = Some("g".into());
    let mut m = row(RowKind::Workspace, 80.0);
    m.group = Some("g".into());
    let rows = vec![
        row(RowKind::Section, 0.0),
        row(RowKind::Workspace, 20.0),
        g,
        m,
        row(RowKind::Workspace, 120.0),
    ];
    let ranges: Vec<[f64; 2]> = blocks(&rows).iter().map(|b| b.range).collect();
    assert_eq!(ranges, vec![[0.0, 20.0], [20.0, 40.0], [60.0, 100.0], [120.0, 140.0]]);
}

#[test]
fn a_standing_row_heads_its_groups_block() {
    let mut sole = row(RowKind::Workspace, 30.0);
    sole.group = Some("g".into());
    sole.depth = 1;
    sole.parent_index = Some(4);
    sole.stands_for_group = true;
    let found = blocks(&[sole]);
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].next_index, 5);
}

#[test]
fn the_origin_is_the_groups_own_slot() {
    let p = plan(None);
    assert_eq!(p.origin, 2);
    assert_eq!(p.slot(52.0 + 30.0), 2);
}

#[test]
fn a_slot_changes_at_each_blocks_midpoint() {
    let p = plan(None);
    for (index, block) in p.blocks.iter().enumerate() {
        let mid = (block.range[0] + block.range[1]) / 2.0;
        assert_eq!(p.slot(mid - 0.01 + 30.0), index);
        assert_eq!(p.slot(mid + 0.01 + 30.0), index + 1);
    }
}

#[test]
fn the_slot_is_monotonic_in_the_centre() {
    let p = plan(None);
    let mut last = 0;
    let mut y = -200.0;
    while y < 400.0 {
        let slot = p.slot(y);
        assert!(slot >= last, "slot {slot} at {y} after {last}");
        last = slot;
        y += 0.5;
    }
    assert_eq!(p.slot(-1000.0), 0);
    assert_eq!(p.slot(1000.0), 5);
}

#[test]
fn a_refused_slot_gives_the_nearest_accepted_one() {
    let p = plan(Some(vec![false, true, false, false, true, false]));
    assert_eq!(p.allowed, vec![false, true, true, false, true, false]);
    assert_eq!(p.slot(-100.0), 1);
    // Block 2's midpoint: raw slot 3 just past it.
    let mid3 = (52.0 + 118.0) / 2.0;
    assert_eq!(p.slot(mid3 + 1.0 + 30.0), 2);
    assert_eq!(p.slot(1000.0), 4);
}

#[test]
fn a_wrong_length_allowed_accepts_only_the_origin() {
    let p = plan(Some(vec![true; 3]));
    assert_eq!(p.allowed, vec![false, false, true, false, false, false]);
    assert_eq!(p.slot(1000.0), 2);
}

#[test]
fn the_card_height_cuts_past_three_rows() {
    let rows = [
        [100.0, 128.0],
        [130.0, 158.0],
        [160.0, 188.0],
        [190.0, 218.0],
        [220.0, 248.0],
        [250.0, 278.0],
    ];
    assert_eq!(card_height(&rows, 100.0, 178.0, 3), 118.0);
    assert_eq!(card_height(&rows[..4], 100.0, 118.0, 3), 118.0);
    assert_eq!(card_height(&[[100.0, 128.0]], 100.0, 28.0, 3), 28.0);
    let with_empty =
        [[100.0, 128.0], [128.0, 128.0], [130.0, 158.0], [160.0, 188.0], [190.0, 218.0]];
    assert_eq!(card_height(&with_empty, 100.0, 118.0, 3), 118.0);
}

#[test]
fn the_gap_is_the_card_and_its_trail() {
    assert_eq!(plan(None).gap(), 66.0);
}

#[test]
fn each_slot_has_its_top() {
    let p = plan(None);
    let tops: Vec<f64> = (0..5).map(|s| p.top(s)).collect();
    assert_eq!(tops, vec![0.0, 26.0, 52.0, 124.0, 150.0]);
    assert_eq!(p.top(5), 176.0);
}

#[test]
fn a_placement_opens_the_gap_at_the_slots_top() {
    let reply = group_drag(&GroupDragRequest {
        rows: base(),
        group_top: 52.0,
        card: 60.0,
        lead: 6.0,
        trail: 6.0,
        allowed: None,
        carried: vec![Carried { y: 0.0, height: 20.0 }, Carried { y: 50.0, height: 20.0 }],
        centres: vec![],
        place: vec![1, 5, 9],
    });
    assert_eq!(reply.placements.len(), 2);
    assert_eq!(reply.placements[0].insert_at, 1);
    assert_eq!(reply.placements[0].carried_y, vec![26.0, 66.0]);
    assert_eq!(reply.placements[1].insert_at, 7);
    assert_eq!(reply.placements[1].top, 176.0);
}

#[test]
fn a_rows_height_is_its_lines_status_and_subagents() {
    let m = Metrics {
        row_height: 28.0,
        row_height_with_subtitle: 40.0,
        two_line_rows: false,
        status_line_height: 14.0,
        progress_bar_height: 8.0,
        status_bottom_padding: 4.0,
        subagent_line_height: 24.0,
        subagent_stack_height: 18.0,
    };
    let plain = RowShape {
        has_detail: false,
        has_meta: false,
        status_lines: None,
        has_progress: false,
        subagents: None,
    };
    assert_eq!(m.height(&plain), 28.0);
    assert_eq!(m.resolved(true, false).height(&plain), 40.0);
    assert_eq!(m.resolved(true, true).height(&plain), 28.0);
    let full = RowShape {
        has_detail: true,
        has_meta: true,
        status_lines: Some(2),
        has_progress: true,
        subagents: Some(Strip { stack: false, line_count: 3 }),
    };
    assert_eq!(m.height(&full), 28.0 + 24.0 + 28.0 + 8.0 + 4.0 + 72.0);
    let stacked = RowShape { subagents: Some(Strip { stack: true, line_count: 9 }), ..plain };
    assert_eq!(m.subagents_height(&stacked), 18.0);
}

#[test]
fn only_what_asks_for_the_person_gets_a_chip() {
    assert_eq!(row_chip(Some(Chip::Done)), None);
    assert_eq!(row_chip(Some(Chip::Working)), None);
    assert_eq!(row_chip(Some(Chip::Idle)), None);
    assert_eq!(row_chip(None), None);
    for chip in [Chip::NeedsYou, Chip::Failed, Chip::Lost, Chip::CiFailing] {
        assert_eq!(row_chip(Some(chip)), Some(chip));
    }
}

#[test]
fn a_local_line_repeating_the_title_is_dropped() {
    assert_eq!(non_redundant_detail(Some("local · demo-session"), "demo-session"), None);
    assert_eq!(
        non_redundant_detail(Some("build-mac · demo-session"), "demo-session").as_deref(),
        Some("build-mac · demo-session")
    );
    assert_eq!(
        non_redundant_detail(Some("local · ~/work/demo"), "demo-session").as_deref(),
        Some("local · ~/work/demo")
    );
    assert_eq!(
        non_redundant_detail(Some("local · Waiting"), "demo-session").as_deref(),
        Some("local · Waiting")
    );
    assert_eq!(non_redundant_detail(Some(""), "x"), None);
}

#[test]
fn the_activity_glyph_follows_the_working_and_progress_elements() {
    assert_eq!(activity(Activity::Waiting, false, false), Activity::Waiting);
    assert_eq!(activity(Activity::Busy, false, false), Activity::Idle);
    assert_eq!(activity(Activity::Busy, false, true), Activity::Busy);
    assert_eq!(activity(Activity::Working, false, true), Activity::Idle);
    assert_eq!(activity(Activity::Working, true, false), Activity::Working);
}

#[test]
fn titles_compare_without_case_or_diacritics() {
    assert!(same_title(" Café ", "cafe"));
    assert!(!same_title("", ""));
    assert!(!same_title("a", "b"));
    assert_eq!(description_line(Some("\n  first \nsecond")).as_deref(), Some("first"));
    assert_eq!(description_line(Some(" \n\t")), None);
}

#[test]
fn a_lone_status_line_moves_onto_the_names_line() {
    let ws =
        Workspace { title: "w".into(), status: Some("Thinking".into()), ..Workspace::default() };
    let set =
        Elements { shown: vec![Element::AgentStatus], second_line: vec![Element::AgentStatus] };
    let content = compact(&ws, &set);
    assert_eq!(content.trailing_status.as_deref(), Some("Thinking"));
    assert_eq!(content.detail, None);
}

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

#[test]
fn vectors_match_the_swift_transliteration() {
    let doc: serde_json::Value = serde_json::from_str(VECTORS).expect("vectors");
    for (index, case) in doc["cases"].as_array().expect("cases").iter().enumerate() {
        let mut request = case.clone();
        let expected = request.as_object_mut().and_then(|o| o.remove("reply")).expect("reply");
        let request: Request = serde_json::from_value(request).expect("request");
        let reply = serde_json::to_value(respond(&request)).expect("reply");
        assert!(same(&reply, &expected), "case {index}: {reply} vs {expected}");
    }
}
