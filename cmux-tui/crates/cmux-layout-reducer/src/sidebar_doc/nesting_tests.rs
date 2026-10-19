//! Nested groups: depth, cycles, repair, display order, moves across
//! sections, unpin and section removal of a group of several machines,
//! ungroup, close, the window rows and the drop table.

use super::reduce::{apply_in_place, check, repair};
use super::view::{LiveWorkspace, ViewRequest, view};
use super::*;

const LOCAL: &str = "local";
const CLOUD_A: &str = "cloud-a";
const CLOUD_B: &str = "cloud-b";

fn doc() -> Doc {
    let mut custom = Section::new("sec_cloud", SectionKind::Custom, Region::Middle);
    custom.keeps_closed = false;
    let mut doc = Doc::from_parts(1, Vec::new(), Vec::new());
    for section in [Section::pinned(), Section::machine(LOCAL)] {
        run(&mut doc, &[Op::SectionAdd { section, place: SectionPlace::default() }]).unwrap();
    }
    run(&mut doc, &[Op::SectionAdd { section: custom, place: SectionPlace::default() }]).unwrap();
    doc
}

fn run(doc: &mut Doc, ops: &[Op]) -> Result<(), Refusal> {
    let mut next = 0;
    let mut mint = || {
        next += 1;
        format!("itm_minted_{next}")
    };
    apply_in_place(doc, ops, &mut mint).map(|_| ())
}

fn into(section: &str, parent: Option<&str>) -> Target {
    Target { section: section.into(), parent: parent.map(str::to_string), ..Target::default() }
}

fn group(doc: &mut Doc, id: &str, section: &str, parent: Option<&str>) -> Result<(), Refusal> {
    run(
        doc,
        &[Op::GroupCreate {
            id: Some(id.into()),
            name: id.into(),
            color: None,
            icon: None,
            profile: None,
            items: Vec::new(),
            to: Some(into(section, parent)),
        }],
    )
}

fn workspace(doc: &mut Doc, session: &str, id: &str, to: Target) -> String {
    let reference = WorkspaceRef::new(session, id);
    run(doc, &[Op::Adopt { refs: vec![reference.clone()], to: Some(to) }]).unwrap();
    workspace_item_id(&reference)
}

fn move_to(doc: &mut Doc, id: &str, to: Target) -> Result<(), Refusal> {
    run(doc, &[Op::Move { items: vec![id.into()], to }])
}

fn order(doc: &Doc) -> Vec<String> {
    doc.items_in_order().iter().map(|item| item.id.clone()).collect()
}

fn local() -> String {
    machine_section_id(LOCAL)
}

#[test]
fn three_group_levels_are_allowed_and_a_fourth_is_refused() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    group(&mut doc, "c", &local(), Some("b")).unwrap();
    // A workspace under the third level is fine.
    workspace(&mut doc, LOCAL, "w1", into(&local(), Some("c")));
    assert_eq!(group(&mut doc, "d", &local(), Some("c")), Err(Refusal::TooDeep));
    assert!(doc.item("d").is_none(), "a refused op changes nothing");
    check(&doc).unwrap();
}

#[test]
fn moving_a_group_whose_subtree_gets_too_deep_is_refused() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    group(&mut doc, "x", &local(), None).unwrap();
    group(&mut doc, "y", &local(), Some("x")).unwrap();
    let before = doc.clone();
    assert_eq!(move_to(&mut doc, "x", into(&local(), Some("b"))), Err(Refusal::TooDeep));
    assert_eq!(doc, before);
    // One level higher it fits: a > x > y.
    move_to(&mut doc, "x", into(&local(), Some("a"))).unwrap();
    assert_eq!(doc.ancestors("y").len(), 2);
    check(&doc).unwrap();
}

#[test]
fn a_group_cannot_move_into_itself_or_its_own_group() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    assert_eq!(move_to(&mut doc, "a", into(&local(), Some("b"))), Err(Refusal::Nesting));
    assert_eq!(move_to(&mut doc, "a", into(&local(), Some("a"))), Err(Refusal::InvalidTarget));
    assert!(doc.item("a").unwrap().parent.is_none());
}

#[test]
fn repair_lifts_a_parent_cycle_and_a_too_deep_group() {
    let section = local();
    let mut items = Vec::new();
    for (id, parent) in [
        ("p", Some("q")),
        ("q", Some("p")),
        ("g1", None),
        ("g2", Some("g1")),
        ("g3", Some("g2")),
        ("g4", Some("g3")),
    ] {
        let mut item = Item::new(
            id,
            &section,
            Body::Group {
                name: id.into(),
                color: None,
                icon: None,
                collapsed: false,
                profile: None,
            },
        );
        item.parent = parent.map(str::to_string);
        items.push(item);
    }
    let mut machine = Section::machine(LOCAL);
    machine.order = order_key::spread(1).remove(0);
    let mut doc = Doc::from_parts(3, vec![machine], items);
    assert!(check(&doc).is_err());
    assert!(repair(&mut doc));
    check(&doc).unwrap();
    assert!(doc.item("g4").unwrap().parent.is_none(), "the fourth level is lifted");
    assert_eq!(doc.item("g3").unwrap().parent.as_deref(), Some("g2"), "three levels stay");
    let cycle = [doc.item("p").unwrap(), doc.item("q").unwrap()];
    assert!(cycle.iter().any(|item| item.parent.is_none()), "the cycle is cut");
}

#[test]
fn nested_items_keep_display_order_and_previous_rows() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    let w1 = workspace(&mut doc, LOCAL, "w1", into(&local(), Some("a")));
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    let w2 = workspace(&mut doc, LOCAL, "w2", into(&local(), Some("b")));
    let w3 = workspace(&mut doc, LOCAL, "w3", into(&local(), Some("a")));
    let w4 = workspace(&mut doc, LOCAL, "w4", into(&local(), None));
    assert_eq!(order(&doc), ["a", &w1, "b", &w2, &w3, &w4]);
    let previous = |doc: &Doc, id: &str| doc.previous_in_order(id).map(|item| item.id.clone());
    assert_eq!(
        previous(&doc, &w3).as_deref(),
        Some(w2.as_str()),
        "after the nested group's last row"
    );
    assert_eq!(previous(&doc, "b").as_deref(), Some(w1.as_str()));
    assert_eq!(previous(&doc, &w4).as_deref(), Some(w3.as_str()));
    let mut keys: Vec<_> = doc.items_in_order().into_iter().cloned().collect();
    keys.reverse();
    keys.sort_by_cached_key(|item| doc.display_key(item));
    assert_eq!(keys.iter().map(|item| item.id.clone()).collect::<Vec<_>>(), order(&doc));
}

#[test]
fn a_group_moves_to_another_section_with_every_level_under_it() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    group(&mut doc, "c", &local(), Some("b")).unwrap();
    let w = workspace(&mut doc, LOCAL, "w", into(&local(), Some("c")));
    run(&mut doc, &[Op::Pin { items: vec!["a".into()] }]).unwrap();
    for id in ["a", "b", "c", w.as_str()] {
        assert_eq!(doc.item(id).unwrap().section, PINNED_SECTION_ID, "{id}");
    }
    assert_eq!(doc.item(&w).unwrap().parent.as_deref(), Some("c"));
    check(&doc).unwrap();
}

/// A Cloud group in a custom section, with a per-project group inside,
/// holding workspaces of two cloud machines.
fn cloud_doc() -> (Doc, String, String) {
    let mut doc = doc();
    group(&mut doc, "cloud", "sec_cloud", None).unwrap();
    group(&mut doc, "project", "sec_cloud", Some("cloud")).unwrap();
    let a = workspace(&mut doc, CLOUD_A, "wa", into("sec_cloud", Some("cloud")));
    let b = workspace(&mut doc, CLOUD_B, "wb", into("sec_cloud", Some("project")));
    check(&doc).unwrap();
    (doc, a, b)
}

#[test]
fn a_group_outside_machine_sections_holds_several_machines_but_not_in_one() {
    let (mut doc, _, b) = cloud_doc();
    assert_eq!(doc.machines_of("cloud").len(), 2);
    assert_eq!(move_to(&mut doc, "cloud", into(&local(), None)), Err(Refusal::CrossMachine));
    // A cloud workspace moves out of the group into its own machine.
    run(
        &mut doc,
        &[Op::SectionAdd { section: Section::machine(CLOUD_B), place: SectionPlace::default() }],
    )
    .unwrap();
    move_to(&mut doc, &b, into(&machine_section_id(CLOUD_B), None)).unwrap();
    assert!(doc.item(&b).unwrap().parent.is_none());
}

#[test]
fn unpinning_a_group_of_several_machines_splits_it_by_machine() {
    let (mut doc, a, b) = cloud_doc();
    run(&mut doc, &[Op::Unpin { items: vec!["cloud".into()] }]).unwrap();
    assert_eq!(doc.item(&a).unwrap().section, machine_section_id(CLOUD_A));
    assert_eq!(doc.item(&b).unwrap().section, machine_section_id(CLOUD_B));
    assert!(doc.item("cloud").is_none() && doc.item("project").is_none());
    check(&doc).unwrap();
}

#[test]
fn removing_the_section_of_a_group_of_several_machines_keeps_its_workspaces() {
    let (mut doc, a, b) = cloud_doc();
    run(&mut doc, &[Op::SectionRemove { id: "sec_cloud".into() }]).unwrap();
    assert_eq!(doc.item(&a).unwrap().section, machine_section_id(CLOUD_A));
    assert_eq!(doc.item(&b).unwrap().section, machine_section_id(CLOUD_B));
    assert!(doc.section("sec_cloud").is_none());
    check(&doc).unwrap();
}

#[test]
fn reset_splits_a_group_of_several_machines() {
    let (mut doc, a, b) = cloud_doc();
    run(&mut doc, &[Op::Reset]).unwrap();
    assert_eq!(doc.item(&a).unwrap().section, machine_section_id(CLOUD_A));
    assert_eq!(doc.item(&b).unwrap().section, machine_section_id(CLOUD_B));
    check(&doc).unwrap();
}

#[test]
fn ungrouping_a_nested_group_moves_its_items_up_to_its_parent() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    group(&mut doc, "c", &local(), Some("b")).unwrap();
    let w = workspace(&mut doc, LOCAL, "w", into(&local(), Some("b")));
    run(&mut doc, &[Op::GroupUngroup { id: "b".into() }]).unwrap();
    assert_eq!(doc.item("c").unwrap().parent.as_deref(), Some("a"));
    assert_eq!(doc.item(&w).unwrap().parent.as_deref(), Some("a"));
    assert_eq!(order(&doc), ["a", "c", &w]);
    check(&doc).unwrap();
}

#[test]
fn removing_a_group_removes_every_level_under_it() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    workspace(&mut doc, LOCAL, "w", into(&local(), Some("b")));
    run(&mut doc, &[Op::ItemRemove { id: "a".into() }]).unwrap();
    assert_eq!(doc.item_count(), 0);
}

#[test]
fn closing_the_last_workspace_removes_the_groups_it_empties() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    group(&mut doc, "keep", &local(), None).unwrap();
    workspace(&mut doc, LOCAL, "w", into(&local(), Some("b")));
    workspace(&mut doc, LOCAL, "x", into(&local(), Some("keep")));
    run(&mut doc, &[Op::Close { refs: vec![WorkspaceRef::new(LOCAL, "w")] }]).unwrap();
    assert!(doc.item("b").is_none() && doc.item("a").is_none());
    assert!(doc.item("keep").is_some());
}

fn live(ids: &[&str]) -> Vec<LiveWorkspace> {
    ids.iter()
        .map(|id| LiveWorkspace {
            session_id: LOCAL.into(),
            workspace_id: (*id).into(),
            title: Some((*id).into()),
        })
        .collect()
}

#[test]
fn window_rows_indent_nested_groups_and_collapse_hides_every_level() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    group(&mut doc, "c", &local(), Some("b")).unwrap();
    let w = workspace(&mut doc, LOCAL, "w", into(&local(), Some("c")));
    let rows = |collapsed: &[&str], filter: Option<&str>| {
        view(
            &doc,
            &ViewRequest {
                live: live(&["w"]),
                collapsed: Some(collapsed.iter().map(|id| (*id).to_string()).collect()),
                filter: filter.map(str::to_string),
                ..ViewRequest::default()
            },
        )
        .into_iter()
        .filter(|row| row.kind != "section")
        .map(|row| (row.key, row.depth))
        .collect::<Vec<_>>()
    };
    assert_eq!(rows(&[], None), [("a".into(), 0), ("b".into(), 1), ("c".into(), 2), (w, 3)]);
    assert_eq!(rows(&["a"], None), [("a".into(), 0)], "a collapsed parent hides every level");
    assert_eq!(rows(&["b"], None), [("a".into(), 0), ("b".into(), 1)]);
    // c keeps its own collapse while a parent is collapsed and opened.
    assert_eq!(rows(&["c"], None), [("a".into(), 0), ("b".into(), 1), ("c".into(), 2)]);
    // A filter that matches only the nested workspace shows its groups.
    assert_eq!(rows(&["a"], Some("w")).len(), 4);
}

#[test]
fn the_drop_table_refuses_a_nest_that_is_too_deep_or_inside_itself() {
    let mut doc = doc();
    group(&mut doc, "a", &local(), None).unwrap();
    group(&mut doc, "b", &local(), Some("a")).unwrap();
    group(&mut doc, "c", &local(), Some("b")).unwrap();
    group(&mut doc, "x", &local(), None).unwrap();
    group(&mut doc, "y", &local(), Some("x")).unwrap();
    let rows = view(&doc, &ViewRequest::default());
    let table = accept::drag_begin(&doc, &rows, &["x".into()]);
    assert!(table["a"].into, "x > y fits under a");
    assert!(!table["b"].into, "under b it would be four levels");
    assert_eq!(table["c"].refusal.as_deref(), Some("too_deep"));
    assert_eq!(table["y"].refusal.as_deref(), Some("self"));
    let table = accept::drag_begin(&doc, &rows, &["a".into()]);
    assert_eq!(table["c"].refusal.as_deref(), Some("self"), "a grandchild of the dragged group");
}

#[test]
fn closing_the_last_workspace_of_a_nested_cloud_group_removes_only_emptied_groups() {
    let (mut doc, a, b) = cloud_doc();
    // cloud > project > wb; cloud > wa. wb closes: project is empty and
    // goes; cloud still holds wa and stays.
    run(&mut doc, &[Op::Close { refs: vec![WorkspaceRef::new(CLOUD_B, "wb")] }]).unwrap();
    assert!(doc.item(&b).is_none() && doc.item("project").is_none());
    assert!(doc.item("cloud").is_some() && doc.item(&a).is_some());
    // wa closes too: now cloud is empty and goes.
    run(&mut doc, &[Op::Close { refs: vec![WorkspaceRef::new(CLOUD_A, "wa")] }]).unwrap();
    assert!(doc.item("cloud").is_none());
    assert_eq!(doc.section_item_count("sec_cloud"), 0);
    check(&doc).unwrap();
}

#[test]
fn a_group_split_by_unpin_leaves_no_empty_nested_group() {
    let (mut doc, a, b) = cloud_doc();
    group(&mut doc, "empty", "sec_cloud", Some("project")).unwrap();
    run(&mut doc, &[Op::Unpin { items: vec!["cloud".into()] }]).unwrap();
    let groups: Vec<String> = doc
        .items_unordered()
        .filter(|item| item.body.is_group())
        .map(|item| item.id.clone())
        .collect();
    assert!(groups.is_empty(), "no group is left: {groups:?}");
    assert!(doc.item(&a).unwrap().parent.is_none() && doc.item(&b).unwrap().parent.is_none());
    check(&doc).unwrap();
}
