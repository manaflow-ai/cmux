//! Pin and Unpin on nested groups (a283's remote groups slice 1, pinning-DESIGN.md):
//! a top-level group pins and unpins with its whole tree; a nested group or a
//! workspace in one pins inside its own parent; a member of a pinned tree is not
//! pinned itself, so Unpin leaves it in the tree. Closing the last workspace removes
//! the groups it empties in a machine section, never in Pinned.

use super::doc::Doc;
use super::model::*;
use super::reduce::apply_in_place;

const A: &str = "sa";

fn ws(id: &str) -> ItemId {
    workspace_item_id(&WorkspaceRef::new(A, id))
}

fn sec() -> SectionId {
    machine_section_id(A)
}

fn run(doc: &mut Doc, ops: Vec<Op>) {
    let mut n = 0;
    let mut mint = || {
        n += 1;
        format!("itm_m{n}")
    };
    apply_in_place(doc, &ops, &mut mint).expect("the reducer takes the ops");
}

fn group(id: &str, parent: Option<&str>, items: &[&str]) -> Op {
    Op::GroupCreate {
        id: Some(id.into()),
        name: id.into(),
        color: None,
        icon: None,
        profile: None,
        items: items.iter().map(|w| ws(w)).collect(),
        to: Some(Target {
            section: sec(),
            parent: parent.map(str::to_string),
            ..Target::default()
        }),
    }
}

/// Machine A: loose w0, then host > project (w1, w2) > branch (w3, w4), then loose w9.
fn fixture() -> Doc {
    let mut section = Section::machine(A);
    section.order = "a".into();
    let mut doc = Doc::from_parts(0, vec![section], vec![]);
    let refs = ["w0", "w1", "w2", "w3", "w4", "w9"].map(|w| WorkspaceRef::new(A, w)).to_vec();
    run(&mut doc, vec![Op::Adopt { refs, to: None }]);
    run(
        &mut doc,
        vec![
            group("host", None, &[]),
            group("project", Some("host"), &["w1", "w2"]),
            group("branch", Some("project"), &["w3", "w4"]),
        ],
    );
    // host sits between w0 and w9.
    run(
        &mut doc,
        vec![Op::Move {
            items: vec!["host".into()],
            to: Target { section: sec(), after: Some(ws("w0")), ..Target::default() },
        }],
    );
    doc
}

fn names(doc: &Doc, section: &str, parent: Option<&str>) -> Vec<String> {
    doc.list(section, parent)
        .map(|i| i.body.workspace().map_or_else(|| i.id.clone(), |r| r.workspace_id.clone()))
        .collect()
}

#[test]
fn fixture_nests_three_levels() {
    let doc = fixture();
    assert_eq!(names(&doc, &sec(), None), ["w0", "host", "w9"]);
    assert_eq!(names(&doc, &sec(), Some("project")), ["w1", "w2", "branch"]);
}

#[test]
fn a_pinned_tree_unpins_whole_to_its_place() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec!["host".into()] }]);
    for id in ["host", "project", "branch", &ws("w3")] {
        assert_eq!(doc.item(id).unwrap().section, PINNED_SECTION_ID, "{id} followed the pin");
    }
    run(&mut doc, vec![Op::Unpin { items: vec!["host".into()] }]);
    assert_eq!(names(&doc, &sec(), None), ["w0", "host", "w9"]);
    for id in ["project", "branch", &ws("w3")] {
        assert_eq!(doc.item(id).unwrap().section, sec(), "{id} came back with the tree");
    }
    assert_eq!(doc.item("branch").unwrap().parent.as_deref(), Some("project"));
}

#[test]
fn a_nested_group_pins_first_in_its_parent_with_its_subtree() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec!["branch".into()] }]);
    let branch = doc.item("branch").unwrap();
    assert_eq!(
        (branch.section.as_str(), branch.parent.as_deref()),
        (sec().as_str(), Some("project"))
    );
    assert!(branch.pinned_in_group());
    assert_eq!(names(&doc, &sec(), Some("project")), ["branch", "w1", "w2"]);
    assert_eq!(names(&doc, &sec(), Some("branch")), ["w3", "w4"]);
    run(&mut doc, vec![Op::Unpin { items: vec!["branch".into()] }]);
    assert!(!doc.item("branch").unwrap().pinned_in_group());
    assert_eq!(doc.item("branch").unwrap().parent.as_deref(), Some("project"));
}

#[test]
fn a_workspace_in_the_deepest_group_pins_there() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![ws("w4")] }]);
    assert_eq!(names(&doc, &sec(), Some("branch")), ["w4", "w3"]);
    assert_eq!(doc.item(&ws("w4")).unwrap().parent.as_deref(), Some("branch"));
}

#[test]
fn unpin_on_a_member_of_a_pinned_tree_leaves_it_in_the_tree() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec!["host".into()] }]);
    run(&mut doc, vec![Op::Unpin { items: vec![ws("w3"), "project".into()] }]);
    assert_eq!(doc.item(&ws("w3")).unwrap().parent.as_deref(), Some("branch"), "w3 left its group");
    assert_eq!(
        doc.item("project").unwrap().parent.as_deref(),
        Some("host"),
        "project left its tree"
    );
    assert_eq!(doc.item(&ws("w3")).unwrap().section, PINNED_SECTION_ID);
}

#[test]
fn closed_members_stay_while_pinned_and_go_with_their_groups_once_unpinned() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec!["host".into()] }]);
    let closed = vec![WorkspaceRef::new(A, "w3"), WorkspaceRef::new(A, "w4")];
    run(&mut doc, vec![Op::Close { refs: closed.clone() }]);
    assert!(doc.item("branch").is_some(), "Pinned keeps a group of closed workspaces");
    assert!(doc.item(&ws("w3")).is_some());
    // Unpin, then the daemon closes what is not open (closes_for_unpin).
    run(&mut doc, vec![Op::Unpin { items: vec!["host".into()] }, Op::Close { refs: closed }]);
    assert!(doc.item(&ws("w3")).is_none() && doc.item(&ws("w4")).is_none());
    assert!(doc.item("branch").is_none(), "the group the close emptied stays");
    assert_eq!(names(&doc, &sec(), Some("project")), ["w1", "w2"]);
}
