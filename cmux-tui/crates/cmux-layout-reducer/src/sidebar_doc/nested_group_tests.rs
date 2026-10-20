//! Nested groups (plans/cmux-next/remote-groups-DESIGN.md R1-R4): a group
//! may hold groups up to [`MAX_GROUP_DEPTH`] levels (host > project >
//! branch), a subtree never mixes machines, a moved group carries its whole
//! subtree, closing the last workspace removes emptied ancestors, and view
//! rows carry the depth.

use super::accept;
use super::reduce::{apply_in_place, check, repair};
use super::view::{LiveWorkspace, ViewRequest, view};
use super::*;

const A: &str = "mini";
const B: &str = "linux-vm";

fn minter() -> impl FnMut() -> ItemId {
    let mut n = 0;
    move || {
        n += 1;
        format!("itm_minted_{n}")
    }
}

/// A document with machine sections for A and B and one custom section,
/// and workspaces a1, a2 (machine A) and b1 (machine B) placed loose in
/// their machine sections.
fn doc() -> Doc {
    let mut custom = Section::new("sec_custom", SectionKind::Custom, Region::Middle);
    custom.order = "c".into();
    let mut a = Section::machine(A);
    a.order = "a".into();
    let mut b = Section::machine(B);
    b.order = "b".into();
    let mut items = Vec::new();
    for (session, ws, order) in [(A, "a1", "a"), (A, "a2", "b"), (B, "b1", "a")] {
        let mut item =
            Item::workspace(WorkspaceRef::new(session, ws), &machine_section_id(session));
        item.order = order.into();
        items.push(item);
    }
    let doc = Doc::from_parts(1, vec![a, b, custom], items);
    check(&doc).expect("fixture passes the invariants");
    doc
}

fn ws(session: &str, id: &str) -> ItemId {
    workspace_item_id(&WorkspaceRef::new(session, id))
}

fn group(id: &str, name: &str, section: &str, parent: Option<&str>, items: Vec<ItemId>) -> Op {
    Op::GroupCreate {
        id: Some(id.into()),
        name: name.into(),
        color: None,
        icon: None,
        profile: None,
        items,
        to: Some(Target {
            section: section.into(),
            parent: parent.map(str::to_string),
            ..Target::default()
        }),
    }
}

fn apply(doc: &mut Doc, ops: &[Op]) -> Result<(), Refusal> {
    apply_in_place(doc, ops, &mut minter()).map(|_| ())
}

/// host > project > branch inside machine A's section.
fn three_levels(doc: &mut Doc) {
    let sec = machine_section_id(A);
    apply(
        doc,
        &[
            group("g_project", "cmux", &sec, None, vec![]),
            group("g_branch", "feat-x", &sec, Some("g_project"), vec![]),
            group("g_leaf", "spike", &sec, Some("g_branch"), vec![ws(A, "a1")]),
        ],
    )
    .expect("three levels of groups are allowed");
}

#[test]
fn a_group_can_hold_a_group() {
    let mut doc = doc();
    let sec = machine_section_id(A);
    apply(&mut doc, &[group("g_project", "cmux", &sec, None, vec![ws(A, "a1")])]).unwrap();
    apply(&mut doc, &[group("g_branch", "feat-x", &sec, Some("g_project"), vec![ws(A, "a2")])])
        .expect("a group under a group");
    let branch = doc.item("g_branch").unwrap();
    assert_eq!(branch.parent.as_deref(), Some("g_project"));
    assert_eq!(doc.item(&ws(A, "a2")).unwrap().parent.as_deref(), Some("g_branch"));
    check(&doc).expect("nested document passes the full check");
}

#[test]
fn three_levels_fit_and_a_fourth_is_refused() {
    let mut doc = doc();
    three_levels(&mut doc);
    check(&doc).unwrap();
    let sec = machine_section_id(A);
    assert_eq!(
        apply(&mut doc, &[group("g_too_deep", "x", &sec, Some("g_leaf"), vec![])]),
        Err(Refusal::Nesting)
    );
}

#[test]
fn moving_a_group_into_its_own_subtree_is_refused() {
    let mut doc = doc();
    three_levels(&mut doc);
    let sec = machine_section_id(A);
    let into_child = Op::Move {
        items: vec!["g_project".into()],
        to: Target { section: sec, parent: Some("g_leaf".into()), ..Target::default() },
    };
    assert_eq!(apply(&mut doc, &[into_child]), Err(Refusal::InvalidTarget));
}

#[test]
fn moving_a_group_under_a_group_respects_the_height_of_its_subtree() {
    let mut doc = doc();
    three_levels(&mut doc);
    let sec = machine_section_id(A);
    apply(&mut doc, &[group("g_other", "other", &sec, None, vec![ws(A, "a2")])]).unwrap();
    // g_branch has two levels (g_branch > g_leaf); under g_other that is three: fits.
    let fits = Op::Move {
        items: vec!["g_branch".into()],
        to: Target { section: sec.clone(), parent: Some("g_other".into()), ..Target::default() },
    };
    apply(&mut doc, &[fits]).expect("two-level subtree under a top-level group fits");
    assert_eq!(doc.item("g_branch").unwrap().parent.as_deref(), Some("g_other"));
    // g_other now has three levels; it cannot go under anything.
    let mut doc2 = doc.clone();
    apply(&mut doc2, &[group("g_top", "top", &sec, None, vec![])]).unwrap();
    let too_deep = Op::Move {
        items: vec!["g_other".into()],
        to: Target { section: sec, parent: Some("g_top".into()), ..Target::default() },
    };
    assert_eq!(apply(&mut doc2, &[too_deep]), Err(Refusal::Nesting));
}

#[test]
fn a_subtree_never_mixes_machines() {
    let mut doc = doc();
    // In a custom section (no machine of its own): project holds branch,
    // branch holds a workspace of A; a workspace of B may not join anywhere
    // in that subtree.
    apply(
        &mut doc,
        &[
            group("g_project", "cmux", "sec_custom", None, vec![]),
            group("g_branch", "feat-x", "sec_custom", Some("g_project"), vec![ws(A, "a1")]),
        ],
    )
    .unwrap();
    let b_into_project = Op::Move {
        items: vec![ws(B, "b1")],
        to: Target {
            section: "sec_custom".into(),
            parent: Some("g_project".into()),
            ..Target::default()
        },
    };
    assert_eq!(apply(&mut doc, &[b_into_project]), Err(Refusal::CrossMachine));
    let b_into_sibling_group = [
        group("g_b", "b-stuff", "sec_custom", Some("g_project"), vec![]),
        Op::Move {
            items: vec![ws(B, "b1")],
            to: Target {
                section: "sec_custom".into(),
                parent: Some("g_b".into()),
                ..Target::default()
            },
        },
    ];
    assert_eq!(apply(&mut doc, &b_into_sibling_group), Err(Refusal::CrossMachine));
    check(&doc).unwrap();
}

#[test]
fn a_moved_group_carries_its_whole_subtree() {
    let mut doc = doc();
    three_levels(&mut doc);
    let pin = Op::Pin { items: vec!["g_project".into()] };
    apply(&mut doc, &[pin]).expect("pin a nested tree");
    for id in ["g_project", "g_branch", "g_leaf"] {
        assert_eq!(doc.item(id).unwrap().section, PINNED_SECTION_ID, "{id} followed");
    }
    assert_eq!(doc.item(&ws(A, "a1")).unwrap().section, PINNED_SECTION_ID);
    assert_eq!(doc.item("g_leaf").unwrap().parent.as_deref(), Some("g_branch"));
    check(&doc).unwrap();
}

#[test]
fn closing_the_last_workspace_removes_emptied_ancestors() {
    let mut doc = doc();
    three_levels(&mut doc);
    apply(&mut doc, &[Op::Close { refs: vec![WorkspaceRef::new(A, "a1")] }]).unwrap();
    for id in ["g_leaf", "g_branch", "g_project"] {
        assert!(doc.item(id).is_none(), "{id} emptied and removed");
    }
    check(&doc).unwrap();
}

#[test]
fn closing_keeps_an_ancestor_that_still_has_members() {
    let mut doc = doc();
    three_levels(&mut doc);
    let sec = machine_section_id(A);
    let a2_into_project = Op::Move {
        items: vec![ws(A, "a2")],
        to: Target { section: sec, parent: Some("g_project".into()), ..Target::default() },
    };
    apply(&mut doc, &[a2_into_project]).unwrap();
    apply(&mut doc, &[Op::Close { refs: vec![WorkspaceRef::new(A, "a1")] }]).unwrap();
    assert!(doc.item("g_leaf").is_none());
    assert!(doc.item("g_branch").is_none());
    assert!(doc.item("g_project").is_some(), "still holds a2");
}

#[test]
fn view_rows_carry_depth_and_collapse_hides_the_subtree() {
    let mut doc = doc();
    three_levels(&mut doc);
    let live = vec![
        LiveWorkspace {
            session_id: A.into(),
            workspace_id: "a1".into(),
            title: Some("one".into()),
        },
        LiveWorkspace {
            session_id: A.into(),
            workspace_id: "a2".into(),
            title: Some("two".into()),
        },
        LiveWorkspace {
            session_id: B.into(),
            workspace_id: "b1".into(),
            title: Some("bee".into()),
        },
    ];
    let rows = view(&doc, &ViewRequest { live: live.clone(), ..ViewRequest::default() });
    let depth = |key: &str| rows.iter().find(|r| r.key == key).map(|r| r.depth);
    assert_eq!(depth("g_project"), Some(0));
    assert_eq!(depth("g_branch"), Some(1));
    assert_eq!(depth("g_leaf"), Some(2));
    assert_eq!(depth(&ws(A, "a1")), Some(3));
    let order: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
    let at = |key: &str| order.iter().position(|k| *k == key).unwrap();
    assert!(at("g_project") < at("g_branch") && at("g_branch") < at("g_leaf"));
    assert!(at("g_leaf") < at(&ws(A, "a1")));

    let folded = view(
        &doc,
        &ViewRequest { live, collapsed: Some(vec!["g_branch".into()]), ..ViewRequest::default() },
    );
    assert!(folded.iter().any(|r| r.key == "g_branch" && r.collapsed));
    assert!(!folded.iter().any(|r| r.key == "g_leaf"), "collapsed branch hides its subgroup");
    assert!(!folded.iter().any(|r| r.key == ws(A, "a1")));
}

#[test]
fn a_text_filter_reaches_a_nested_workspace() {
    let mut doc = doc();
    three_levels(&mut doc);
    let live = vec![LiveWorkspace {
        session_id: A.into(),
        workspace_id: "a1".into(),
        title: Some("needle".into()),
    }];
    let rows =
        view(&doc, &ViewRequest { live, filter: Some("needle".into()), ..ViewRequest::default() });
    let keys: Vec<&str> = rows.iter().map(|r| r.key.as_str()).collect();
    for key in ["g_project", "g_branch", "g_leaf"] {
        assert!(keys.contains(&key), "{key} shows as the path to the match: {keys:?}");
    }
    assert!(keys.contains(&ws(A, "a1").as_str()));
}

#[test]
fn items_in_order_lists_a_subtree_depth_first() {
    let mut doc = doc();
    three_levels(&mut doc);
    let order: Vec<String> = doc.items_in_order().into_iter().map(|i| i.id.clone()).collect();
    let at = |key: &str| order.iter().position(|k| k == key).unwrap();
    assert!(at("g_project") < at("g_branch"));
    assert!(at("g_branch") < at("g_leaf"));
    assert!(at("g_leaf") < at(&ws(A, "a1")));
    assert_eq!(order.len(), doc.item_count(), "every item listed once");
}

#[test]
fn repair_lifts_a_chain_that_is_too_deep_or_cycles() {
    let sec = machine_section_id(A);
    let mut items = Vec::new();
    for (id, parent) in [("g1", None), ("g2", Some("g1")), ("g3", Some("g2")), ("g4", Some("g3"))] {
        let mut item = Item::new(
            id,
            &sec,
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
    let mut cyc_a = Item::new(
        "cyc_a",
        &sec,
        Body::Group { name: "a".into(), color: None, icon: None, collapsed: false, profile: None },
    );
    cyc_a.parent = Some("cyc_b".into());
    let mut cyc_b = Item::new(
        "cyc_b",
        &sec,
        Body::Group { name: "b".into(), color: None, icon: None, collapsed: false, profile: None },
    );
    cyc_b.parent = Some("cyc_a".into());
    items.push(cyc_a);
    items.push(cyc_b);
    let mut doc = Doc::from_parts(1, vec![Section::machine(A)], items);
    assert!(check(&doc).is_err());
    assert!(repair(&mut doc));
    check(&doc).expect("repaired");
    assert_eq!(doc.item("g3").unwrap().parent.as_deref(), Some("g2"), "within the limit kept");
    assert!(doc.item("g4").is_some(), "repair never deletes a group");
    assert!(doc.item("cyc_a").is_some() && doc.item("cyc_b").is_some());
}

#[test]
fn drag_does_not_nest_yet_and_a_dragged_tree_is_self() {
    let mut doc = doc();
    three_levels(&mut doc);
    let sec = machine_section_id(A);
    apply(&mut doc, &[group("g_solo", "solo", &sec, None, vec![ws(A, "a2")])]).unwrap();
    let live = vec![
        LiveWorkspace { session_id: A.into(), workspace_id: "a1".into(), title: None },
        LiveWorkspace { session_id: A.into(), workspace_id: "a2".into(), title: None },
    ];
    let rows = view(&doc, &ViewRequest { live, ..ViewRequest::default() });
    let table = accept::drag_begin(&doc, &rows, &["g_solo".to_string()]);
    assert!(!table["g_project"].into, "the sidebar does not draw nested groups yet");
    assert!(table["g_project"].before, "a group still lands beside a top-level group");
    let table = accept::drag_begin(&doc, &rows, &["g_project".to_string()]);
    for key in ["g_branch", "g_leaf"] {
        assert_eq!(table[key].refusal.as_deref(), Some("self"), "{key} is under the dragged tree");
    }
    let table = accept::drag_begin(&doc, &rows, &[ws(A, "a2")]);
    assert!(table["g_leaf"].into, "a workspace drops into a nested group");
}
