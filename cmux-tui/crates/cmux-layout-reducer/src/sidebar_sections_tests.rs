//! Mirrors the Swift tests of the sections' membership, loose-edit detectors and workspace order
//! (SidebarNewWindowGroupsTests, LegacyPinnedGroupOrderTests, SidebarCloseMoveSpliceTests,
//! SidebarStructuralSpliceTests, SidebarWorkspaceOrderTests) on the rules alone.

use super::*;

fn ws(id: &str) -> Node {
    Node::Workspace(Workspace { id: id.into(), ..Workspace::default() })
}

fn group(id: &str, members: &[&str], parent: Option<&str>) -> Node {
    Node::Group(Group {
        id: id.into(),
        parent: parent.map(Into::into),
        workspaces: members
            .iter()
            .map(|id| Workspace { id: (*id).into(), ..Workspace::default() })
            .collect(),
        ..Group::default()
    })
}

fn section(nodes: Vec<Node>) -> Vec<Section> {
    vec![Section { id: "mac".into(), nodes, ..Section::default() }]
}

fn set(ids: &[&str]) -> BTreeSet<Id> {
    ids.iter().map(|id| id.to_string()).collect()
}

fn group_ids(sections: &[Section]) -> Vec<String> {
    sections
        .iter()
        .flat_map(|section| &section.nodes)
        .filter_map(|node| match node {
            Node::Group(group) => Some(group.id.clone()),
            _ => None,
        })
        .collect()
}

#[test]
fn the_window_filter_drops_groups_whose_workspaces_list_elsewhere() {
    let mut only_links = group("only-links", &[], None);
    if let Node::Group(group) = &mut only_links {
        group.key = Some("links".into());
    }
    let sections = section(vec![
        ws("ws-1"),
        group("elsewhere", &["ws-2"], None),
        group("parent", &[], None),
        group("child", &["ws-3"], Some("parent")),
        group("linked", &["ws-4"], None),
        only_links,
        group("empty", &[], None),
        group("mine-parent", &[], None),
        group("mine", &["ws-5", "ws-6"], Some("mine-parent")),
    ]);
    let filtered = filter(sections, &set(&["ws-1", "ws-5"]));
    assert_eq!(group_ids(&filtered), ["only-links", "empty", "mine-parent", "mine"]);
    assert_eq!(workspace_order(&filtered), ["ws-1", "ws-5"]);
    assert_eq!(filtered.len(), 1, "section headers always stay");
}

#[test]
fn pinned_groups_list_first_in_their_section_and_pinned_rows_move_to_the_top() {
    let pinned_group = Node::Group(Group { id: "g2".into(), pinned: true, ..Group::default() });
    let sections = section(vec![ws("a"), group("g1", &["b"], None), pinned_group, ws("c")]);
    let unpinned = pinned_first(sections.clone(), &BTreeSet::new());
    assert_eq!(group_ids(&unpinned), ["g2", "g1"]);
    assert_eq!(unpinned[0].nodes.len(), 4);
    let moved = pinned_first(sections, &set(&["c", "b"]));
    assert!(moved[0].pinned, "a Pinned section at the top");
    assert_eq!(workspace_order(&moved[..1]), ["b", "c"], "in sidebar order");
    assert_eq!(workspace_order(&moved[1..]), ["a"]);
    assert_eq!(group_ids(&moved), ["g2", "g1"], "groups stay, even when every member is pinned");
    let existing = vec![
        Section { pinned: true, nodes: vec![ws("p")], ..Section::default() },
        section(vec![ws("a")]).remove(0),
    ];
    let appended = pinned_first(existing, &set(&["a"]));
    assert_eq!(appended.len(), 2);
    assert_eq!(workspace_order(&appended[..1]), ["p", "a"]);
}

#[test]
fn with_no_pinned_group_nothing_moves() {
    let sections = section(vec![ws("a"), group("g1", &["b"], None), ws("c")]);
    assert_eq!(pinned_first(sections.clone(), &BTreeSet::new()), sections);
}

#[test]
fn hiding_and_placeholders_drop_rows_but_keep_groups() {
    let sections = section(vec![ws("a"), group("g", &["b", "c"], None)]);
    let hidden = hiding(sections.clone(), &set(&["a", "b"]));
    assert_eq!(workspace_order(&hidden), ["c"]);
    assert_eq!(group_ids(&hidden), ["g"]);
    assert_eq!(hiding(sections.clone(), &BTreeSet::new()), sections);
    let mut pending = sections;
    if let Node::Workspace(workspace) = &mut pending[0].nodes[0] {
        workspace.pending = true;
    }
    assert_eq!(workspace_order(&without_placeholders(pending)), ["b", "c"]);
}

#[test]
fn the_order_lists_each_workspace_once_and_orders_members_in_their_slots() {
    let sections = section(vec![ws("a"), group("g", &["b", "a"], None), ws("c")]);
    let order = workspace_order(&sections);
    assert_eq!(order, ["a", "b", "c"], "a row listed twice counts at its first place");
    let members: Vec<Id> = ["c", "x", "a", "b"].iter().map(|id| id.to_string()).collect();
    assert_eq!(ordering(&order, &members), ["a", "x", "b", "c"], "x keeps its slot");
    assert_eq!(ordering(&order, &["y".to_string()]), ["y"]);
}

#[test]
fn the_sets_are_found_only_for_one_loose_row() {
    let s = |ids: &[&str]| section(ids.iter().map(|id| ws(id)).collect());
    assert_eq!(
        loose_insertion(&s(&["a", "c"]), &s(&["a", "b", "c"])),
        Some(Place { section: 0, node: 1 })
    );
    assert_eq!(loose_insertion(&s(&["a"]), &s(&["a", "b"])), Some(Place { section: 0, node: 1 }));
    assert_eq!(loose_removal(&s(&["a", "b", "c"]), &s(&["a", "c"])).map(|p| p.node), Some(1));
    assert_eq!(loose_removal(&s(&["a", "b", "c"]), &s(&["c"])), None);
    assert_eq!(
        loose_move(&s(&["a", "b", "c"]), &s(&["c", "a", "b"])).map(|m| m.insertion.node),
        Some(0)
    );
    assert_eq!(
        loose_move(&s(&["a", "b", "c"]), &s(&["b", "c", "a"])).map(|m| m.removal.node),
        Some(0)
    );
    assert_eq!(loose_move(&s(&["a", "b", "c"]), &s(&["c", "b", "a"])), None);
    assert_eq!(loose_move(&s(&["a", "b", "c"]), &s(&["a", "b", "c"])), None);
    let mut retitled = s(&["a", "c"]);
    retitled[0].key = Some("renamed".into());
    assert_eq!(
        loose_insertion(&retitled, &s(&["a", "b", "c"])),
        None,
        "a changed shell is no insertion"
    );
}

#[test]
fn the_batch_is_found_only_for_loose_adds_and_closes() {
    let s = |ids: &[&str]| section(ids.iter().map(|id| ws(id)).collect());
    let first =
        |old: &[&str], new: &[&str]| loose_edits(&s(old), &s(new)).map(|edits| edits[0].clone());
    assert_eq!(
        first(&["a", "b", "c"], &["d", "a", "e", "b", "c"]).map(|e| e.inserted),
        Some(vec![0, 2])
    );
    assert_eq!(first(&["a", "b", "c", "d"], &["b", "d"]).map(|e| e.removed), Some(vec![0, 2]));
    assert_eq!(
        first(&["a", "b", "c"], &["e", "b", "d"]).map(|e| [e.removed, e.inserted]),
        Some([vec![0, 2], vec![0, 2]])
    );
    assert_eq!(first(&["a", "b", "c"], &["c", "b", "a"]), None, "an order change is no batch");
    assert_eq!(first(&["a", "b", "c"], &["b", "c", "a", "d"]), None, "closed and added back");
    assert_eq!(first(&["a", "b"], &["a", "b"]), None);
}
