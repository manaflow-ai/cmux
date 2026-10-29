//! Archiving (plans/cmux-next/archiving-DESIGN.md): an archived item moves
//! to the end of its own list (its group, or the section's top level), stays
//! after the unarchived items through every move, draws dimmed with its
//! subtree, and Unarchive puts it back where it was.

use super::doc::Doc;
use super::model::*;
use super::reduce::{apply_in_place, apply_rows};
use super::view::{LiveWorkspace, ViewRequest, view};

const SESSION: &str = "s1";

fn reference(id: &str) -> WorkspaceRef {
    WorkspaceRef::new(SESSION, id)
}

fn item_id(id: &str) -> ItemId {
    workspace_item_id(&reference(id))
}

fn run(doc: &mut Doc, ops: Vec<Op>) -> Vec<Op> {
    let mut next = 0;
    let mut mint = || {
        next += 1;
        format!("minted{next}")
    };
    apply_in_place(doc, &ops, &mut mint).expect("the reducer takes the ops").inverse
}

/// Machine section: w4, group g1 (w1, w2, w3), w5, w6.
fn fixture() -> Doc {
    let mut section = Section::machine(SESSION);
    section.order = super::order_key::spread(1).remove(0);
    let mut doc = Doc::from_parts(0, vec![section], vec![]);
    run(
        &mut doc,
        vec![Op::Adopt {
            refs: ["w4", "w1", "w2", "w3", "w5", "w6"].map(reference).to_vec(),
            to: None,
        }],
    );
    run(
        &mut doc,
        vec![Op::GroupCreate {
            id: Some("g1".into()),
            name: "G".into(),
            color: None,
            icon: None,
            profile: None,
            items: ["w1", "w2", "w3"].map(item_id).to_vec(),
            to: None,
        }],
    );
    doc
}

fn machine() -> SectionId {
    machine_section_id(SESSION)
}

/// The ids of one sibling list, in order, workspace ids unwrapped.
fn list(doc: &Doc, section: &str, parent: Option<&str>) -> Vec<String> {
    doc.list(section, parent)
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

fn live(ids: &[&str]) -> Vec<LiveWorkspace> {
    ids.iter()
        .map(|id| LiveWorkspace {
            session_id: SESSION.into(),
            workspace_id: (*id).into(),
            title: None,
        })
        .collect()
}

fn request(ids: &[&str]) -> ViewRequest {
    ViewRequest { live: live(ids), ..ViewRequest::default() }
}

/// The drawn rows as `(key, depth, archived)`, workspace ids unwrapped.
fn rows(doc: &Doc, request: &ViewRequest) -> Vec<(String, u8, bool)> {
    view(doc, request)
        .into_iter()
        .map(|row| {
            let key = row.reference.map_or(row.key, |r| r.workspace_id);
            (key, row.depth, row.archived)
        })
        .collect()
}

#[test]
fn archive_in_a_group_moves_the_item_to_the_end_of_the_group() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w1"])]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w2", "w3", "w1"]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "g1", "w5", "w6"]);
    assert!(archived(&doc, &item_id("w1")));
}

#[test]
fn archive_at_the_top_level_moves_the_item_to_the_end_of_its_section() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w4"])]);
    assert_eq!(list(&doc, &machine(), None), ["g1", "w5", "w6", "w4"]);
    // A second archive goes after the first: the newest is last.
    run(&mut doc, vec![archive(&["w5"])]);
    assert_eq!(list(&doc, &machine(), None), ["g1", "w6", "w4", "w5"]);
}

#[test]
fn a_group_archives_whole_and_its_subtree_draws_archived() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Archive { items: vec!["g1".into()] }]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "w5", "w6", "g1"]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w1", "w2", "w3"]);
    let request = request(&["w1", "w2", "w3", "w4", "w5", "w6"]);
    assert_eq!(
        rows(&doc, &request),
        [
            ("w4".into(), 0, false),
            ("w5".into(), 0, false),
            ("w6".into(), 0, false),
            ("g1".into(), 0, true),
            ("w1".into(), 1, true),
            ("w2".into(), 1, true),
            ("w3".into(), 1, true),
        ]
    );
}

#[test]
fn unarchive_puts_the_item_back_after_the_sibling_it_followed() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w2"])]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w1", "w3", "w2"]);
    run(&mut doc, vec![unarchive(&["w2"])]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w1", "w2", "w3"]);
    let item = doc.item(&item_id("w2")).expect("item");
    assert!(!item.archived());
    assert!(!item.extra.contains_key(UNARCHIVE_TO_KEY));
    // The first item goes back first.
    run(&mut doc, vec![archive(&["w4"])]);
    run(&mut doc, vec![unarchive(&["w4"])]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "g1", "w5", "w6"]);
}

#[test]
fn unarchive_with_its_old_neighbor_archived_goes_last_among_the_unarchived() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w5"])]);
    run(&mut doc, vec![Op::Archive { items: vec!["g1".into()] }]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "w6", "w5", "g1"]);
    // w5 followed g1, which is archived now.
    run(&mut doc, vec![unarchive(&["w5"])]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "w6", "w5", "g1"]);
    assert!(!archived(&doc, &item_id("w5")));
    assert!(archived(&doc, "g1"));
}

#[test]
fn moves_keep_unarchived_items_above_the_archived_tail() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w4"])]);
    // A drop at the very end lands above the archived item.
    run(&mut doc, vec![Op::Move { items: vec![item_id("w5")], to: Target::end(&machine()) }]);
    assert_eq!(list(&doc, &machine(), None), ["g1", "w6", "w5", "w4"]);
    // An archived item dropped on top stays in the tail.
    let top = Target { section: machine(), index: Some(0), ..Target::default() };
    run(&mut doc, vec![Op::Move { items: vec![item_id("w4")], to: top }]);
    assert_eq!(list(&doc, &machine(), None), ["g1", "w6", "w5", "w4"]);
    assert!(archived(&doc, &item_id("w4")));
    // A new workspace lands above the archived tail, and draws there before it is placed.
    let request = request(&["w1", "w2", "w3", "w4", "w5", "w6", "w7"]);
    let drawn: Vec<String> =
        rows(&doc, &request).into_iter().filter(|row| row.1 == 0).map(|row| row.0).collect();
    assert_eq!(drawn, ["g1", "w6", "w5", "w7", "w4"]);
    run(&mut doc, vec![Op::Adopt { refs: vec![reference("w7")], to: None }]);
    assert_eq!(list(&doc, &machine(), None), ["g1", "w6", "w5", "w7", "w4"]);
}

#[test]
fn items_archived_together_come_back_in_their_order() {
    let mut doc = fixture();
    // w5 and w6 sit together after the group; the selection names them in either order.
    run(&mut doc, vec![archive(&["w6", "w5"])]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "g1", "w5", "w6"]);
    assert!(archived(&doc, &item_id("w5")) && archived(&doc, &item_id("w6")));
    run(&mut doc, vec![archive(&["w4"])]);
    assert_eq!(list(&doc, &machine(), None), ["g1", "w5", "w6", "w4"]);
    run(&mut doc, vec![unarchive(&["w6", "w5", "w4"])]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "g1", "w5", "w6"]);
    // Pin unarchives several the same way.
    run(&mut doc, vec![archive(&["w1", "w2"])]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w3", "w1", "w2"]);
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w2"), item_id("w1")] }]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w2", "w1", "w3"]);
}

#[test]
fn archive_unpins_in_the_group_and_pin_unarchives() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w3", "w1", "w2"]);
    run(&mut doc, vec![archive(&["w3"])]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w1", "w2", "w3"]);
    let item = doc.item(&item_id("w3")).expect("item");
    assert!(item.archived() && !item.pinned_in_group());
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w3", "w1", "w2"]);
    let item = doc.item(&item_id("w3")).expect("item");
    assert!(!item.archived() && item.pinned_in_group());
}

#[test]
fn undo_of_an_archive_restores_the_mark_and_the_order() {
    let mut doc = fixture();
    let inverse = run(&mut doc, vec![archive(&["w1"])]);
    apply_rows(&mut doc, &inverse);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w1", "w2", "w3"]);
    assert!(!archived(&doc, &item_id("w1")));
}

#[test]
fn archive_survives_a_round_trip_through_the_wire() {
    let mut doc = fixture();
    run(&mut doc, vec![archive(&["w1"])]);
    let item = doc.item(&item_id("w1")).expect("item").clone();
    let wire = serde_json::to_value(&item).expect("item serializes");
    assert_eq!(wire["extra"][ARCHIVED_KEY], serde_json::Value::Bool(true));
    let back: Item = serde_json::from_value(wire).expect("item reads");
    assert!(back.archived());
    let op: Op = serde_json::from_value(serde_json::json!({"op": "unarchive", "items": ["x"]}))
        .expect("op reads");
    assert_eq!(op, Op::Unarchive { items: vec!["x".into()] });
}
