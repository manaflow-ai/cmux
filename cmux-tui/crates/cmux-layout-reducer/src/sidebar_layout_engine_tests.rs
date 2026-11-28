use super::*;
use serde_json::{Value, json};

// The Swift tests' fixtures (CmuxNextSidebarTests: SidebarDoneFold, SidebarShowMore, SidebarNestedGroupLayout,
// SidebarOneRowPerWorkspace, SidebarHostGroupLayout, SidebarCloudMachineHeader, SidebarSingleMember,
// SidebarRecents, SidebarUniformRowSpacing), through the wire so the JSON shape is pinned too.

const VECTORS: &str = include_str!("../../../../schemas/sidebar-layout-engine/vectors.json");

fn metrics() -> Value {
    json!({
        "topPadding": 8.0, "bottomPadding": 12.0, "sectionHeaderHeight": 28.0, "sectionSpacing": 12.0,
        "rowHeight": 28.0, "rowHeightWithSubtitle": 44.0, "rowSpacing": 2.0, "emptySectionHeight": 28.0
    })
}

fn ws(id: &str) -> Value {
    json!({"id": id, "title": id, "height": 28.0})
}

fn done(id: &str) -> Value {
    json!({"id": id, "title": id, "height": 28.0, "done": true})
}

fn group(id: &str, members: Vec<Value>) -> Value {
    json!({"group": {"id": id, "name": id, "workspaces": members}})
}

fn loose(id: &str) -> Value {
    json!({"workspace": ws(id)})
}

fn machine(name: &str, kind: &str, nodes: Vec<Value>) -> Value {
    json!({"kind": {"machine": {"id": name, "kind": kind}}, "nodes": nodes})
}

fn layout(sections: Vec<Value>, options: Value) -> Layout {
    let request: Request = serde_json::from_value(
        json!({"rule": "make", "sections": sections, "metrics": metrics(), "options": options}),
    )
    .expect("request");
    match respond(&request) {
        Reply::Make(layout) => *layout,
    }
}

fn keys(layout: &Layout) -> Vec<Value> {
    layout.rows.iter().map(|r| serde_json::to_value(&r.key).expect("key")).collect()
}

fn w(id: &str) -> Value {
    json!({"workspace": id})
}

fn g(id: &str) -> Value {
    json!({"group": id})
}

fn fold_key(tag: &str, section: &str, group: Option<&str>) -> Value {
    json!({tag: {"section": {"machine": section}, "group": group, "kind": "done", "folder": null}})
}

fn row<'a>(layout: &'a Layout, key: &Value) -> Option<&'a Row> {
    layout.rows.iter().find(|r| serde_json::to_value(&r.key).ok().as_ref() == Some(key))
}

// MARK: - Done fold

fn done_sections() -> Vec<Value> {
    vec![machine(
        "local",
        "local",
        vec![
            loose("a"),
            json!({"workspace": done("b")}),
            loose("c"),
            json!({"workspace": done("d")}),
            group("g", vec![done("g1"), ws("g2"), done("g3")]),
        ],
    )]
}

#[test]
fn done_rows_fold_under_one_row_per_list() {
    let l = layout(done_sections(), json!({"foldsDone": true}));
    assert_eq!(
        keys(&l),
        vec![
            w("a"),
            w("c"),
            g("g"),
            w("g2"),
            fold_key("done_fold", "local", Some("g")),
            fold_key("done_fold", "local", None)
        ]
    );
    let gf = row(&l, &fold_key("done_fold", "local", Some("g"))).expect("group fold");
    assert_eq!((gf.child_count, gf.is_collapsed, gf.is_last_in_group), (2, true, true));
    let lf = row(&l, &fold_key("done_fold", "local", None)).expect("loose fold");
    assert_eq!(lf.child_count, 2);
}

#[test]
fn an_open_done_fold_lists_its_rows_after_it() {
    let opened = json!([
        {"section": {"machine": "local"}, "group": "g", "kind": "done"},
        {"section": {"machine": "local"}, "kind": "done"}
    ]);
    let l = layout(done_sections(), json!({"foldsDone": true, "openDoneFolds": opened}));
    assert_eq!(
        keys(&l),
        vec![
            w("a"),
            w("c"),
            g("g"),
            w("g2"),
            fold_key("done_fold", "local", Some("g")),
            w("g1"),
            w("g3"),
            fold_key("done_fold", "local", None),
            w("b"),
            w("d")
        ]
    );
}

#[test]
fn the_active_done_row_keeps_its_place() {
    let l = layout(done_sections(), json!({"foldsDone": true, "activeWorkspaceId": "b"}));
    let k = keys(&l);
    assert_eq!(&k[..3], &[w("a"), w("b"), w("c")]);
    assert_eq!(row(&l, &fold_key("done_fold", "local", None)).expect("fold").child_count, 1);
}

#[test]
fn folds_done_off_or_a_filter_lists_every_row() {
    let l = layout(done_sections(), json!({}));
    assert_eq!(keys(&l), vec![w("a"), w("b"), w("c"), w("d"), g("g"), w("g1"), w("g2"), w("g3")]);
    let l = layout(done_sections(), json!({"foldsDone": true, "filterMatches": ["b", "c"]}));
    assert_eq!(keys(&l), vec![w("b"), w("c")]);
}

// MARK: - Show more

fn members(prefix: &str, n: usize) -> Vec<Value> {
    (0..n).map(|i| ws(&format!("{prefix}{i}"))).collect()
}

#[test]
fn a_long_group_shows_its_limit_then_show_more() {
    let l = layout(
        vec![machine("local", "local", vec![group("g", members("m", 14))])],
        json!({"rowLimit": 10}),
    );
    let mut expected = vec![g("g")];
    expected.extend((0..10).map(|i| w(&format!("m{i}"))));
    expected.push(fold_key("show_more", "local", Some("g")));
    assert_eq!(keys(&l), expected);
    let more = l.rows.last().expect("show more");
    assert_eq!((more.child_count, more.is_collapsed, more.is_last_in_group), (4, true, true));
}

#[test]
fn needs_you_and_the_active_row_stay_past_the_limit() {
    let mut list = members("m", 14);
    list[12]["needsYou"] = json!(true);
    let l = layout(
        vec![machine("local", "local", vec![group("g", list)])],
        json!({"rowLimit": 10, "activeWorkspaceId": "m11"}),
    );
    let k = keys(&l);
    assert!(k.contains(&w("m11")) && k.contains(&w("m12")));
    assert!(!k.contains(&w("m10")) && !k.contains(&w("m13")));
}

#[test]
fn an_open_show_more_lists_every_row() {
    let opened = json!([{"section": {"machine": "local"}, "group": "g", "kind": "done"}]);
    let l = layout(
        vec![machine("local", "local", vec![group("g", members("m", 14))])],
        json!({"rowLimit": 10, "openShowMore": opened}),
    );
    assert_eq!(l.rows.len(), 16);
    let more = l.rows.last().expect("show fewer");
    assert_eq!((more.child_count, more.is_collapsed), (0, false));
}

#[test]
fn one_over_the_limit_or_limit_zero_draws_no_show_more() {
    let l = layout(
        vec![machine("local", "local", vec![group("g", members("m", 11))])],
        json!({"rowLimit": 10}),
    );
    assert_eq!(l.rows.len(), 12);
    let l = layout(
        vec![machine("local", "local", vec![group("g", members("m", 14))])],
        json!({"rowLimit": 0}),
    );
    assert_eq!(l.rows.len(), 15);
}

#[test]
fn done_rows_fold_before_the_limit_counts() {
    let mut list = members("m", 14);
    list[0]["done"] = json!(true);
    list[1]["done"] = json!(true);
    let l = layout(
        vec![machine("local", "local", vec![group("g", list)])],
        json!({"rowLimit": 10, "foldsDone": true}),
    );
    let mut expected = vec![g("g")];
    expected.extend((2..12).map(|i| w(&format!("m{i}"))));
    expected.push(fold_key("show_more", "local", Some("g")));
    expected.push(fold_key("done_fold", "local", Some("g")));
    assert_eq!(keys(&l), expected);
}

#[test]
fn loose_rows_take_the_limit_too() {
    let nodes = (0..12).map(|i| loose(&format!("m{i}"))).collect();
    let l = layout(vec![machine("local", "local", nodes)], json!({"rowLimit": 10}));
    let mut expected: Vec<Value> = (0..10).map(|i| w(&format!("m{i}"))).collect();
    expected.push(fold_key("show_more", "local", None));
    assert_eq!(keys(&l), expected);
}

// MARK: - Nested groups

fn nested(collapsed: &[&str]) -> Vec<Value> {
    let grp = |id: &str, parent: Option<&str>, depth: usize, m: Vec<Value>| {
        json!({"group": {"id": id, "name": id, "isCollapsed": collapsed.contains(&id), "workspaces": m,
                         "parent": parent, "depth": depth}})
    };
    vec![machine(
        "mini",
        "server",
        vec![
            grp("g_project", None, 0, vec![ws("a2")]),
            grp("g_branch", Some("g_project"), 1, vec![]),
            grp("g_leaf", Some("g_branch"), 2, vec![ws("a1")]),
            loose("a3"),
        ],
    )]
}

#[test]
fn subgroups_indent_one_level_per_ancestor() {
    let l = layout(nested(&[]), json!({}));
    let depth = |k: Value| row(&l, &k).map(|r| r.depth);
    assert_eq!(depth(g("g_project")), Some(0));
    assert_eq!(depth(w("a2")), Some(1));
    assert_eq!(depth(g("g_branch")), Some(1));
    assert_eq!(depth(g("g_leaf")), Some(2));
    assert_eq!(depth(w("a1")), Some(3));
    assert_eq!(depth(w("a3")), Some(0));
    assert_eq!(row(&l, &w("a1")).and_then(|r| r.group.as_deref()), Some("g_leaf"));
}

#[test]
fn a_collapsed_group_hides_its_whole_subtree() {
    let l = layout(nested(&["g_branch"]), json!({}));
    assert!(row(&l, &g("g_branch")).is_some_and(|r| r.is_collapsed));
    assert!(row(&l, &g("g_leaf")).is_none());
    assert!(row(&l, &w("a1")).is_none());
    assert!(row(&l, &w("a2")).is_some());
}

#[test]
fn a_filter_keeps_the_path_to_a_deep_match() {
    let l = layout(nested(&[]), json!({"filterMatches": ["a1"]}));
    for k in [g("g_project"), g("g_branch"), g("g_leaf"), w("a1")] {
        assert!(row(&l, &k).is_some(), "{k} shows");
    }
    assert!(row(&l, &w("a2")).is_none());
}

// MARK: - One row per workspace, host groups, Cloud headers

fn cloned() -> Vec<Value> {
    vec![
        machine("local", "local", vec![loose("ws_mac")]),
        machine("vm-a", "cloud", vec![loose("ws_image")]),
        machine("vm-b", "cloud", vec![loose("ws_b")]),
        machine("vm-c", "cloud", vec![loose("ws_image")]),
        machine("vm-d", "cloud", vec![loose("ws_d")]),
    ]
}

#[test]
fn every_row_has_its_own_key_and_the_first_machine_keeps_it() {
    let l = layout(cloned(), json!({"flattensMachines": true}));
    let k = keys(&l);
    let unique: HashSet<String> = k.iter().map(Value::to_string).collect();
    assert_eq!(unique.len(), k.len());
    assert_eq!(
        row(&l, &w("ws_image")).map(|r| r.section.clone()),
        Some(SectionId::Machine("vm-a".into()))
    );
}

#[test]
fn no_blank_slot_between_rows() {
    let l = layout(cloned(), json!({"flattensMachines": true}));
    for pair in l.rows.windows(2) {
        let pitch = 2.0 + if matches!(pair[1].key, Key::Section(_)) { 12.0 } else { 0.0 };
        assert!(
            (pair[1].y - (pair[0].y + pair[0].height + pitch)).abs() < 0.5,
            "{:?}",
            pair[1].key
        );
    }
}

#[test]
fn a_repeated_group_member_lists_once() {
    let sections = vec![
        machine("local", "local", vec![loose("ws_image")]),
        machine("vm-a", "cloud", vec![group("g", vec![ws("ws_image")])]),
    ];
    let l = layout(sections, json!({"flattensMachines": true}));
    let k = keys(&l);
    assert_eq!(k.iter().filter(|x| **x == w("ws_image")).count(), 1);
    assert!(k.contains(&g("g")));
}

fn headers(sections: Vec<Value>) -> Vec<SectionId> {
    layout(sections, json!({"flattensMachines": true}))
        .rows
        .into_iter()
        .filter_map(|r| if let Key::Section(id) = r.key { Some(id) } else { None })
        .collect()
}

fn host(name: &str, kind: &str, host_group: bool) -> Value {
    let mut s = machine(name, kind, vec![loose(&format!("{name}-ws"))]);
    s["isHostGroup"] = json!(host_group);
    s
}

#[test]
fn a_remote_group_keeps_its_header_in_one_list() {
    assert_eq!(
        headers(vec![host("local", "local", false), host("mini", "server", true)]),
        vec![SectionId::Machine("mini".into())]
    );
    assert!(headers(vec![host("local", "local", false), host("vm", "ssh", false)]).is_empty());
}

#[test]
fn cloud_workspaces_are_ordinary_rows_with_no_machine_header() {
    let sections = vec![
        machine("local", "local", vec![loose("ws_mac")]),
        machine("lease-lease_21_c6c", "cloud", vec![loose("ws_a")]),
        machine("paused", "cloud", vec![]),
        machine("vm_dev", "cloud", vec![loose("ws_b")]),
    ];
    assert_eq!(
        keys(&layout(sections, json!({"flattensMachines": true}))),
        vec![w("ws_mac"), w("ws_a"), w("ws_b")]
    );
    assert!(headers(vec![machine("vm_dev", "cloud", vec![loose("ws_b")])]).is_empty());
}

// MARK: - Sole member

#[test]
fn a_group_whose_sole_member_shares_its_name_draws_no_header() {
    let sole = vec![machine(
        "local",
        "local",
        vec![group(
            "release-coord",
            vec![json!({"id": "r", "title": " release-coord ", "height": 28.0})],
        )],
    )];
    let reference = vec![machine("local", "local", vec![group("release-coord", vec![ws("r")])])];
    let l = layout(sole, json!({}));
    let r = layout(reference, json!({}));
    assert_eq!(keys(&l), vec![w("r")]);
    let row_r = &l.rows[0];
    let header = row(&r, &g("release-coord")).expect("reference header");
    assert_eq!(row_r.y, header.y);
    assert_eq!(row_r.depth, header.depth + 1);
    assert_eq!(
        (row_r.parent_index, row_r.sibling_index, row_r.is_last_in_group, row_r.stands_for_group),
        (Some(0), 0, true, true)
    );
    assert_eq!(r.rows.len(), 2);
    assert!(l.total_height < r.total_height);
    let two = vec![machine(
        "local",
        "local",
        vec![group("release-coord", vec![ws("release-coord"), ws("x")])],
    )];
    assert!(row(&layout(two, json!({})), &g("release-coord")).is_some());
}

// MARK: - Projects and Recents

#[test]
fn projects_then_recents_newest_first() {
    let mut a = ws("a");
    a["lastActivity"] = json!(-600.0);
    let mut c = ws("c");
    c["lastActivity"] = json!(-60.0);
    let sections = vec![machine(
        "local",
        "local",
        vec![
            json!({"workspace": a}),
            group("g", vec![ws("g1")]),
            loose("b"),
            json!({"workspace": c}),
        ],
    )];
    let l = layout(sections, json!({"grouping": {"by": "recents"}}));
    assert_eq!(
        keys(&l),
        vec![
            json!({"list_header": "projects"}),
            g("g"),
            w("g1"),
            json!({"list_header": "recents"}),
            w("c"),
            w("a"),
            w("b")
        ]
    );
    assert_eq!(l.rows[0].child_count, 1);
    assert_eq!(l.rows[3].child_count, 3);
}

#[test]
fn projects_past_five_fold_under_show_more() {
    let nodes = (0..7).map(|i| group(&format!("g{i}"), vec![ws(&format!("w{i}"))])).collect();
    let l = layout(vec![machine("local", "local", nodes)], json!({"grouping": {"by": "recents"}}));
    let more = json!({"show_more": {"section": "pinned", "group": null, "kind": "projects", "folder": null}});
    let k = keys(&l);
    assert!(k.contains(&g("g4")) && !k.contains(&g("g5")));
    let r = row(&l, &more).expect("show more");
    assert_eq!((r.child_count, r.is_collapsed), (2, true));
}

// MARK: - Uniform spacing, blocks and the gap

#[test]
fn a_groups_last_row_and_the_next_row_keep_the_row_spacing() {
    let l = layout(
        vec![machine("local", "local", vec![group("g", vec![ws("g1")]), loose("z")])],
        json!({}),
    );
    let last = row(&l, &w("g1")).expect("g1");
    let next = row(&l, &w("z")).expect("z");
    assert_eq!(next.y, last.y + last.height + 2.0);
}

#[test]
fn the_pinned_block_is_followed_by_a_row_spacing() {
    let sections = vec![
        json!({"kind": {"custom": "sec_pinned"}, "nodes": []}),
        machine("local", "local", vec![group("g", vec![ws("g1")])]),
    ];
    let l = layout(sections.clone(), json!({"blockHeights": {"sec_pinned": 52.0}}));
    let block = row(&l, &json!({"block": "sec_pinned"})).expect("block");
    assert_eq!(block.height, 52.0);
    let next = &l.rows[1];
    assert_eq!(next.y, block.y + block.height + 2.0);
    let gap = json!({"section": {"custom": "sec_pinned"}, "index": 0});
    let shifted = layout(
        sections,
        json!({"blockHeights": {"sec_pinned": 52.0}, "gap": gap, "gapHeight": 30.0}),
    );
    assert!(shifted.gap_y.is_some());
    assert_eq!(shifted.rows[1].y, next.y + shifted.gap_shift);
}

// MARK: - Edges

#[test]
fn hidden_workspaces_lay_out_nothing() {
    let l = layout(done_sections(), json!({"hidesWorkspaces": true}));
    assert!(l.rows.is_empty());
    assert_eq!(l.total_height, 0.0);
}

#[test]
fn archived_rows_leave_the_list_unless_a_filter_finds_them() {
    let mut x = ws("x");
    x["archived"] = json!(true);
    let sections = vec![machine("local", "local", vec![loose("a"), json!({"workspace": x})])];
    assert_eq!(keys(&layout(sections.clone(), json!({}))), vec![w("a")]);
    assert_eq!(keys(&layout(sections, json!({"filterMatches": ["x"]}))), vec![w("x")]);
}

#[test]
fn group_by_status_lists_states_in_order() {
    let mut n = ws("n");
    n["statusSection"] = json!("needs_you");
    let sections = vec![machine("local", "local", vec![loose("a"), group("g", vec![n])])];
    let l = layout(sections, json!({"grouping": {"byStatus": true}}));
    assert_eq!(
        keys(&l),
        vec![json!({"status": "needs_you"}), w("n"), json!({"status": "idle"}), w("a")]
    );
}

#[test]
fn every_vector_answers_as_the_swift_did() {
    let doc: Value = serde_json::from_str(VECTORS).expect("vectors");
    let cases = doc["cases"].as_array().expect("cases");
    assert!(!cases.is_empty());
    for (index, case) in cases.iter().enumerate() {
        let mut request = case.clone();
        let expected = request.as_object_mut().and_then(|o| o.remove("reply")).expect("reply");
        let request: Request = serde_json::from_value(request).expect("request");
        let got = serde_json::to_value(respond(&request)).expect("reply");
        assert!(same(&got, &expected), "case {index}: {got}");
    }
}

/// JSON equality that reads every number as f64.
fn same(a: &Value, b: &Value) -> bool {
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
