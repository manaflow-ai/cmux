//! The creator link: a workspace an agent or script made lists under the
//! workspace that made it (Leo 2026-11-07: "a bit of indentation ... that
//! little line thing ... especially when it's like agent created ... And you
//! can break the link if you want").

use super::tree::{Guide, TreeRow, rows};
use super::*;

const LOCAL: &str = "local";

fn ws(id: &str, creator: Option<&str>) -> Workspace {
    Workspace {
        id: id.into(),
        machine: LOCAL.into(),
        creator: creator.map(str::to_owned),
        ..Workspace::default()
    }
}

/// `"a"` is a root; `"b<a"` is `b`, made by `a`.
fn row(spec: &str) -> Workspace {
    match spec.split_once('<') {
        Some((id, creator)) => ws(id, Some(creator)),
        None => ws(spec, None),
    }
}

fn loose(spec: &str) -> Node {
    Node::Workspace { workspace: row(spec) }
}

fn group(id: &str, members: &[&str]) -> Node {
    Node::Group {
        group: Group {
            id: id.into(),
            name: id.into(),
            parent: None,
            pinned: false,
            collapsed: false,
            members: members
                .iter()
                .map(|spec| Member::Workspace { workspace: row(spec) })
                .collect(),
        },
    }
}

fn machine(id: &str) -> SectionId {
    SectionId::Machine { id: id.into() }
}

fn tree(nodes: Vec<Node>) -> Vec<Section> {
    vec![Section { id: machine(LOCAL), collapsed: false, nodes }]
}

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|id| (*id).to_owned()).collect()
}

/// A container's rows as specs: `"b<a"` for a linked workspace, a group's id.
fn listed(entries: impl IntoIterator<Item = String>) -> Vec<String> {
    entries.into_iter().collect()
}

fn spec(workspace: &Workspace) -> String {
    match &workspace.creator {
        Some(creator) => format!("{}<{creator}", workspace.id),
        None => workspace.id.clone(),
    }
}

fn top(sections: &[Section]) -> Vec<String> {
    listed(sections[0].nodes.iter().map(|node| match node {
        Node::Workspace { workspace } => spec(workspace),
        Node::Group { group } => group.id.clone(),
        Node::Item { r#ref } => format!("item{ref}"),
    }))
}

fn members(sections: &[Section], id: &str) -> Vec<String> {
    let (s, n) = locate_group(id, sections).expect("group listed");
    let Node::Group { group } = &sections[s].nodes[n] else { panic!("not a group") };
    listed(group.members.iter().map(|member| match member {
        Member::Workspace { workspace } => spec(workspace),
        Member::Item { r#ref } => format!("item{ref}"),
    }))
}

fn run(intent: Intent, sections: &[Section]) -> (bool, Vec<Section>) {
    let mut sections = sections.to_vec();
    let changed = apply(&intent, &mut sections);
    (changed, sections)
}

fn at(group: Option<&str>, index: i64) -> Position {
    Position { section: machine(LOCAL), group: group.map(str::to_owned), index }
}

// MARK: Rules

#[test]
fn attach_places_the_child_right_after_its_creators_subtree() {
    // `a` made `b`, and `b` made `c`; `x` is attached to `a`.
    let sections = tree(vec![loose("x"), loose("a"), loose("b<a"), loose("c<b"), loose("d")]);
    let (changed, after) = run(Intent::Attach { ids: ids(&["x"]), creator: "a".into() }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["a", "b<a", "c<b", "x<a", "d"]);
}

#[test]
fn attach_moves_the_child_into_its_creators_group() {
    let sections = tree(vec![loose("x"), group("g", &["a", "b"])]);
    let (changed, after) = run(Intent::Attach { ids: ids(&["x"]), creator: "a".into() }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["g"]);
    assert_eq!(members(&after, "g"), ["a", "x<a", "b"]);
}

#[test]
fn moving_a_creator_moves_its_children() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("c<b"), loose("d"), loose("e")]);
    // `a` alone is named (the index counts the rows without it); its subtree comes with it.
    let (changed, after) =
        run(Intent::Reorder { ids: ids(&["a"]), position: at(None, 4) }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["d", "e", "a", "b<a", "c<b"]);
}

#[test]
fn moving_a_creator_into_a_group_moves_its_children() {
    let sections = tree(vec![loose("a"), loose("b<a"), group("g", &["m"])]);
    let (changed, after) = run(Intent::Move { ids: ids(&["a"]), group: "g".into() }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["g"]);
    assert_eq!(members(&after, "g"), ["m", "a", "b<a"]);
}

#[test]
fn moving_a_child_among_its_siblings_keeps_the_link() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("c<a"), loose("d")]);
    let (changed, after) =
        run(Intent::Reorder { ids: ids(&["c"]), position: at(None, 1) }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["a", "c<a", "b<a", "d"]);
}

#[test]
fn moving_a_child_out_of_its_creators_group_detaches_it() {
    let sections = tree(vec![group("g", &["a", "b<a"]), loose("d")]);
    let (changed, after) =
        run(Intent::Reorder { ids: ids(&["b"]), position: at(None, 2) }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["g", "d", "b"]);
    assert_eq!(members(&after, "g"), ["a"]);
}

#[test]
fn moving_a_child_out_of_its_creators_subtree_detaches_it() {
    let sections = tree(vec![loose("d"), loose("a"), loose("b<a")]);
    let (changed, after) =
        run(Intent::Reorder { ids: ids(&["b"]), position: at(None, 0) }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["b", "d", "a"]);
}

#[test]
fn a_row_dropped_inside_a_subtree_lands_after_it() {
    let sections = tree(vec![loose("x"), loose("a"), loose("b<a"), loose("c<a"), loose("d")]);
    // Between `b` and `c`: `x` is no child of `a`, so it lists after `a`'s children.
    let (changed, after) =
        run(Intent::Reorder { ids: ids(&["x"]), position: at(None, 2) }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["a", "b<a", "c<a", "x", "d"]);
}

#[test]
fn closing_a_creator_clears_its_childrens_link() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("c<b"), loose("d")]);
    let (changed, after) = run(Intent::Close { ids: ids(&["a"]) }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["b", "c<b", "d"]);
}

#[test]
fn closing_a_creators_group_clears_its_childrens_link() {
    // `b` lists in another section; its creator goes with the closed group.
    let mut sections = tree(vec![group("g", &["a"])]);
    sections
        .insert(0, Section { id: SectionId::Pinned, collapsed: false, nodes: vec![loose("b<a")] });
    let (changed, after) = run(Intent::CloseGroup { group: "g".into() }, &sections);
    assert!(changed);
    let Node::Workspace { workspace } = &after[0].nodes[0] else { panic!("b listed") };
    assert_eq!(workspace.creator, None);
}

#[test]
fn a_creator_not_listed_here_keeps_its_childrens_link() {
    // The creator may be in another window: an edit here never clears that link.
    let sections = tree(vec![loose("b<elsewhere"), group("g", &["m"])]);
    let (_, after) = run(Intent::ToggleGroup { group: "g".into() }, &sections);
    assert_eq!(top(&after), ["b<elsewhere", "g"]);
}

#[test]
fn an_attach_that_makes_a_cycle_is_refused() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("c<b")]);
    for (id, creator) in [("a", "c"), ("a", "b"), ("a", "a")] {
        let reply = edit(&EditRequest {
            sections: sections.clone(),
            intent: Intent::Attach { ids: ids(&[id]), creator: creator.into() },
            prunes: true,
        });
        assert_eq!(reply, EditReply { changed: false, sections: None }, "{id} under {creator}");
    }
}

#[test]
fn an_attach_to_an_unlisted_creator_is_refused() {
    let sections = tree(vec![loose("a"), loose("b")]);
    let (changed, after) =
        run(Intent::Attach { ids: ids(&["b"]), creator: "gone".into() }, &sections);
    assert!(!changed);
    assert_eq!(after, sections);
}

#[test]
fn detach_breaks_the_link_and_lists_the_row_after_its_old_subtree() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("c<b"), loose("d<a"), loose("e")]);
    let (changed, after) = run(Intent::Detach { ids: ids(&["b"]) }, &sections);
    assert!(changed);
    // `b` keeps its own child `c`.
    assert_eq!(top(&after), ["a", "d<a", "b", "c<b", "e"]);
}

#[test]
fn toggle_children_flips_the_creators_collapse() {
    let sections = tree(vec![loose("a"), loose("b<a")]);
    let (changed, after) = run(Intent::ToggleChildren { id: "a".into() }, &sections);
    assert!(changed);
    let Node::Workspace { workspace } = &after[0].nodes[0] else { panic!("a listed") };
    assert!(workspace.collapsed_children);
    let (_, again) = run(Intent::ToggleChildren { id: "a".into() }, &after);
    assert_eq!(again, sections);
}

#[test]
fn toggle_children_on_a_row_without_children_changes_nothing() {
    let sections = tree(vec![loose("a"), loose("b")]);
    let reply = edit(&EditRequest {
        sections,
        intent: Intent::ToggleChildren { id: "a".into() },
        prunes: true,
    });
    assert_eq!(reply, EditReply { changed: false, sections: None });
}

#[test]
fn attaching_a_row_already_under_its_creator_changes_nothing() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("c<a")]);
    let reply = edit(&EditRequest {
        sections,
        intent: Intent::Attach { ids: ids(&["b"]), creator: "a".into() },
        prunes: true,
    });
    assert_eq!(reply, EditReply { changed: false, sections: None });
}

#[test]
fn attaching_a_child_to_another_creator_in_its_container_moves_it() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("c")]);
    let (changed, after) = run(Intent::Attach { ids: ids(&["b"]), creator: "c".into() }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["a", "c", "b<c"]);
}

#[test]
fn moving_a_row_whose_creator_is_not_listed_keeps_the_link() {
    let sections = tree(vec![loose("b<elsewhere"), loose("x")]);
    let (changed, after) =
        run(Intent::Reorder { ids: ids(&["b"]), position: at(None, 1) }, &sections);
    assert!(changed);
    assert_eq!(top(&after), ["x", "b<elsewhere"]);
}

/// One keyboard step of `id`, as the app runs it: the slot, then a reorder.
fn step(id: &str, direction: Direction, sections: &[Section]) -> Vec<String> {
    let position = keyboard_target(&ids(&[id]), direction, sections).expect("a slot");
    let (changed, after) = run(Intent::Reorder { ids: ids(&[id]), position }, sections);
    assert!(changed, "{id} {direction:?} moved");
    top(&after)
}

#[test]
fn keyboard_down_on_a_creator_moves_its_subtree_below_the_next_row() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("d")]);
    assert_eq!(step("a", Direction::Down, &sections), ["d", "a", "b<a"]);
}

#[test]
fn keyboard_up_below_a_subtree_steps_over_it() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("x")]);
    assert_eq!(step("x", Direction::Up, &sections), ["x", "a", "b<a"]);
    // And back down over it.
    let sections = tree(vec![loose("x"), loose("a"), loose("b<a")]);
    assert_eq!(step("x", Direction::Down, &sections), ["a", "b<a", "x"]);
}

#[test]
fn keyboard_steps_a_child_among_its_siblings() {
    let sections = tree(vec![loose("a"), loose("b<a"), loose("c<a"), loose("d")]);
    assert_eq!(step("b", Direction::Down, &sections), ["a", "c<a", "b<a", "d"]);
}

#[test]
fn a_creator_is_matched_on_its_childs_machine() {
    // Pinned holds `a` of another machine; `b`'s creator `a` on its own machine is not listed.
    let mut other = ws("a", None);
    other.machine = "cloud".into();
    let sections = vec![Section {
        id: SectionId::Pinned,
        collapsed: false,
        nodes: vec![Node::Workspace { workspace: other }, loose("b<a")],
    }];
    let rows = rows(&sections, 12);
    assert_eq!(find(&rows, "b").depth, 0);
    let (changed, _) = run(Intent::Attach { ids: ids(&["b"]), creator: "a".into() }, &sections);
    assert!(!changed);
}

#[test]
fn an_attach_whose_id_another_machine_shares_is_refused() {
    // Pinned holds `a` and `b` of the cloud machine; the local section holds another `b`.
    let cloud = |id: &str| {
        let mut workspace = ws(id, None);
        workspace.machine = "cloud".into();
        Node::Workspace { workspace }
    };
    let sections = vec![
        Section { id: SectionId::Pinned, collapsed: false, nodes: vec![cloud("a"), cloud("b")] },
        Section { id: machine(LOCAL), collapsed: false, nodes: vec![loose("b")] },
    ];
    let (changed, after) = run(Intent::Attach { ids: ids(&["b"]), creator: "a".into() }, &sections);
    assert!(!changed);
    assert_eq!(after, sections);
}

// MARK: Layout

fn find<'a>(rows: &'a [TreeRow], id: &str) -> &'a TreeRow {
    rows.iter().find(|row| row.id == id).expect("row listed")
}

#[test]
fn rows_past_depth_three_flatten_to_depth_three() {
    let sections = tree(vec![
        loose("a"),
        loose("b<a"),
        loose("c<b"),
        loose("d<c"),
        loose("e<d"),
        loose("f<e"),
    ]);
    let rows = rows(&sections, 12);
    let depths: Vec<u8> = rows.iter().map(|row| row.depth).collect();
    assert_eq!(depths, [0, 1, 2, 3, 3, 3]);
    assert_eq!(find(&rows, "e").indent, 36);
    // The cap is the layout's: the stored links are unchanged.
    let Node::Workspace { workspace } = &sections[0].nodes[4] else { panic!("e listed") };
    assert_eq!(workspace.creator.as_deref(), Some("d"));
}

#[test]
fn guides_draw_a_branch_an_end_corner_and_continuation_lines() {
    // a
    // ├ b
    // │ └ c
    // └ d
    //   ├ e
    //   └ f
    // g
    let sections = tree(vec![
        loose("a"),
        loose("b<a"),
        loose("c<b"),
        loose("d<a"),
        loose("e<d"),
        loose("f<d"),
        loose("g"),
    ]);
    let rows = rows(&sections, 12);
    let guides = |id: &str| find(&rows, id).guides.clone();
    assert_eq!(guides("a"), []);
    assert_eq!(guides("b"), [Guide::Branch]);
    assert_eq!(guides("c"), [Guide::Line, Guide::End]);
    assert_eq!(guides("d"), [Guide::End]);
    assert_eq!(guides("e"), [Guide::None, Guide::Branch]);
    assert_eq!(guides("f"), [Guide::None, Guide::End]);
    assert_eq!(guides("g"), []);
}

#[test]
fn a_collapsed_creator_hides_its_children_behind_a_count() {
    let mut sections = tree(vec![loose("a"), loose("b<a"), loose("c<b"), loose("d")]);
    let (_, collapsed) = run(Intent::ToggleChildren { id: "a".into() }, &sections);
    sections = collapsed;
    let rows = rows(&sections, 12);
    assert_eq!(find(&rows, "a").collapsed_count, 2);
    assert!(find(&rows, "a").has_children);
    assert!(find(&rows, "b").hidden);
    assert!(find(&rows, "c").hidden);
    assert!(!find(&rows, "d").hidden);
}

#[test]
fn a_link_to_a_creator_in_another_group_draws_flat() {
    let sections = tree(vec![loose("a"), group("g", &["b<a"])]);
    let rows = rows(&sections, 12);
    assert_eq!(find(&rows, "b").depth, 0);
    assert_eq!(find(&rows, "b").group.as_deref(), Some("g"));
}

// MARK: Wire

#[test]
fn the_new_intents_and_fields_have_their_wire_shape() {
    let detach: Intent = serde_json::from_value(serde_json::json!(
        {"kind": "detach", "ids": ["b"]}
    ))
    .unwrap();
    assert_eq!(detach, Intent::Detach { ids: ids(&["b"]) });
    let attach: Intent = serde_json::from_value(serde_json::json!(
        {"kind": "attach", "ids": ["b"], "creator": "a"}
    ))
    .unwrap();
    assert_eq!(attach, Intent::Attach { ids: ids(&["b"]), creator: "a".into() });
    let toggle: Intent = serde_json::from_value(serde_json::json!(
        {"kind": "toggle_children", "id": "a"}
    ))
    .unwrap();
    assert_eq!(toggle, Intent::ToggleChildren { id: "a".into() });
    // A workspace without the new fields still reads, and writes as before.
    let plain: Workspace =
        serde_json::from_value(serde_json::json!({"id": "a", "machine": "local"})).unwrap();
    assert_eq!(plain, ws("a", None));
    assert_eq!(
        serde_json::to_value(&plain).unwrap(),
        serde_json::json!({"id": "a", "machine": "local"})
    );
    let request: Request = serde_json::from_value(serde_json::json!(
        {"op": "tree", "sections": [{"id": {"kind": "machine", "id": "local"}, "nodes": [
            {"kind": "workspace", "workspace": {"id": "a", "machine": "local"}},
            {"kind": "workspace", "workspace": {"id": "b", "machine": "local", "creator": "a"}}
        ]}]}
    ))
    .unwrap();
    let reply: serde_json::Value = serde_json::from_slice(&respond(&request).unwrap()).unwrap();
    assert_eq!(
        reply["rows"][1],
        serde_json::json!({
            "id": "b",
            "section": {"kind": "machine", "id": "local"},
            "group": null,
            "depth": 1,
            "indent": 12,
            "guides": ["end"],
            "has_children": false,
            "collapsed_count": 0,
            "hidden": false
        })
    );
}
