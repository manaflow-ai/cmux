//! Groups follow their members (plans/cmux-next/auto-archive-DESIGN.md
//! "Groups"): a group whose last unarchived member archives archives too,
//! up the tree; restoring a member, or dropping a live one in, restores the
//! group; a group stores its own auto-archive rule.

use serde_json::json;

use super::doc::Doc;
use super::model::*;
use super::reduce::{apply_in_place, apply_rows, check};
use super::view::{LiveWorkspace, ViewRequest, view};

const SESSION: &str = "s1";

fn reference(id: &str) -> WorkspaceRef {
    WorkspaceRef::new(SESSION, id)
}

fn item_id(id: &str) -> ItemId {
    workspace_item_id(&reference(id))
}

fn machine() -> SectionId {
    machine_section_id(SESSION)
}

fn run(doc: &mut Doc, ops: Vec<Op>) -> Vec<Op> {
    let mut next = 0;
    let mut mint = || {
        next += 1;
        format!("minted{next}")
    };
    let applied = apply_in_place(doc, &ops, &mut mint).expect("the reducer takes the ops");
    check(doc).expect("the document keeps its invariants");
    applied.inverse
}

fn try_run(doc: &mut Doc, ops: serde_json::Value) -> Result<(), Refusal> {
    let ops: Vec<Op> = serde_json::from_value(ops).expect("ops read");
    let mut mint = || "minted".to_string();
    apply_in_place(doc, &ops, &mut mint).map(|_| ())
}

fn group(id: &str, parent: Option<&str>, items: &[&str]) -> Op {
    Op::GroupCreate {
        id: Some(id.into()),
        name: id.to_uppercase(),
        color: None,
        icon: None,
        profile: None,
        items: items
            .iter()
            .map(|id| if id.starts_with('g') { (*id).into() } else { item_id(id) })
            .collect(),
        to: Some(Target {
            section: machine(),
            parent: parent.map(str::to_string),
            ..Target::default()
        }),
    }
}

/// Machine section: w4, outer (inner (w1, w2), w3), w5.
fn fixture() -> Doc {
    let mut section = Section::machine(SESSION);
    section.order = super::order_key::spread(1).remove(0);
    let mut doc = Doc::from_parts(0, vec![section], vec![]);
    run(
        &mut doc,
        vec![Op::Adopt { refs: ["w4", "w1", "w2", "w3", "w5"].map(reference).to_vec(), to: None }],
    );
    run(&mut doc, vec![group("outer", None, &["w3"])]);
    run(
        &mut doc,
        vec![Op::Move {
            items: vec!["outer".into()],
            to: Target { section: machine(), after: Some(item_id("w4")), ..Target::default() },
        }],
    );
    run(&mut doc, vec![group("inner", Some("outer"), &["w1", "w2"])]);
    run(
        &mut doc,
        vec![Op::Move {
            items: vec!["inner".into()],
            to: Target {
                section: machine(),
                parent: Some("outer".into()),
                index: Some(0),
                ..Target::default()
            },
        }],
    );
    doc
}

fn list(doc: &Doc, parent: Option<&str>) -> Vec<String> {
    doc.list(&machine(), parent)
        .map(|item| {
            item.body.workspace().map_or_else(|| item.id.clone(), |r| r.workspace_id.clone())
        })
        .collect()
}

fn archived(doc: &Doc, id: &str) -> bool {
    doc.item(id).expect("item").archived()
}

fn archive(ids: &[&str]) -> Op {
    Op::Archive { items: ids.iter().map(|id| item_id(id)).collect() }
}

fn unarchive(ids: &[&str]) -> Op {
    Op::Unarchive { items: ids.iter().map(|id| item_id(id)).collect() }
}

/// `(key, archived)` of every drawn row, workspace ids unwrapped.
fn rows(doc: &Doc) -> Vec<(String, bool)> {
    let live = ["w1", "w2", "w3", "w4", "w5", "w6"]
        .iter()
        .map(|id| LiveWorkspace {
            session_id: SESSION.into(),
            workspace_id: (*id).into(),
            title: None,
        })
        .collect();
    view(doc, &ViewRequest { live, ..ViewRequest::default() })
        .into_iter()
        .filter(|row| row.kind != "section")
        .map(|row| (row.reference.map_or(row.key, |r| r.workspace_id), row.archived))
        .collect()
}

#[test]
fn the_fixture_nests_inner_in_outer() {
    let doc = fixture();
    assert_eq!(list(&doc, None), ["w4", "outer", "w5"]);
    assert_eq!(list(&doc, Some("outer")), ["inner", "w3"]);
    assert_eq!(list(&doc, Some("inner")), ["w1", "w2"]);
}

#[test]
fn archiving_some_members_leaves_the_group_live() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w1"])]);
    assert!(!archived(&doc, "inner"));
    assert!(!archived(&doc, "outer"));
}

#[test]
fn archiving_the_last_live_member_archives_the_group() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w1"])]);
    run(&mut doc, vec![archive(&["w2"])]);
    assert!(archived(&doc, "inner"));
    assert_eq!(doc.item("inner").expect("inner").extra.get("archived_by"), Some(&json!("members")));
    // The group moves to its own list's archived tail, after w3.
    assert_eq!(list(&doc, Some("outer")), ["w3", "inner"]);
    // outer still has w3 live.
    assert!(!archived(&doc, "outer"));
}

#[test]
fn the_roll_up_climbs_nested_groups() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w1", "w2", "w3"])]);
    assert!(archived(&doc, "inner"));
    assert!(archived(&doc, "outer"));
    assert_eq!(list(&doc, None), ["w4", "w5", "outer"]);
}

#[test]
fn unarchiving_a_member_restores_its_groups_and_draws_it_undimmed() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w1", "w2", "w3"])]);
    run(&mut doc, vec![unarchive(&["w2"])]);
    assert!(!archived(&doc, "outer"));
    assert!(!archived(&doc, "inner"));
    assert!(!archived(&doc, &item_id("w2")));
    assert!(archived(&doc, &item_id("w1")));
    // outer goes back where it was, after w4.
    assert_eq!(list(&doc, None), ["w4", "outer", "w5"]);
    let drawn = rows(&doc);
    let w2 = drawn.iter().find(|(key, _)| key == "w2").expect("w2 draws");
    assert!(!w2.1, "a restored member draws undimmed: {drawn:?}");
    assert!(!doc.item("outer").expect("outer").extra.contains_key("archived_by"));
}

#[test]
fn a_live_workspace_moved_into_an_archived_group_restores_it() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w1", "w2"])]);
    assert!(archived(&doc, "inner"));
    let into = Target { section: machine(), parent: Some("inner".into()), ..Target::default() };
    run(&mut doc, vec![Op::Move { items: vec![item_id("w5")], to: into }]);
    assert!(!archived(&doc, "inner"));
    assert!(!archived(&doc, &item_id("w5")));
}

#[test]
fn an_archived_workspace_moved_into_an_archived_group_leaves_it_archived() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w1", "w2", "w5"])]);
    let into = Target { section: machine(), parent: Some("inner".into()), ..Target::default() };
    run(&mut doc, vec![Op::Move { items: vec![item_id("w5")], to: into }]);
    assert!(archived(&doc, "inner"));
}

#[test]
fn one_undo_takes_back_the_archive_and_its_roll_up() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w1"])]);
    let inverse = run(&mut doc, vec![archive(&["w2"])]);
    apply_rows(&mut doc, &inverse);
    assert!(!archived(&doc, "inner"));
    assert!(!archived(&doc, &item_id("w2")));
    assert_eq!(list(&doc, Some("outer")), ["inner", "w3"]);
}

#[test]
fn a_group_stores_its_own_auto_archive_rule() {
    let mut doc = fixture();
    let update = |rule: serde_json::Value| json!([{"op": "group.update", "id": "inner", "patch": {"auto_archive": rule}}]);
    try_run(&mut doc, update(json!("never"))).expect("never is a rule");
    assert_eq!(doc.item("inner").expect("inner").extra.get("auto_archive"), Some(&json!("never")));
    try_run(&mut doc, update(json!(72))).expect("hours are a rule");
    assert_eq!(doc.item("inner").expect("inner").extra.get("auto_archive"), Some(&json!(72)));
    assert_eq!(try_run(&mut doc, update(json!("soon"))), Err(Refusal::InvalidValue));
    assert_eq!(try_run(&mut doc, update(json!(0))), Err(Refusal::InvalidValue));
    try_run(&mut doc, update(json!(null))).expect("null clears");
    assert!(!doc.item("inner").expect("inner").extra.contains_key("auto_archive"));
}
