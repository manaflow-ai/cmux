//! Pinning (plans/cmux-next/pinning-DESIGN.md): a workspace pinned inside a
//! group stays in that group, first among its members; Unpin puts it right
//! under the group's other pinned members; a top-level item pinned to the
//! Pinned band goes back to where it was when it is unpinned.

use super::doc::Doc;
use super::model::*;
use super::reduce::{apply_in_place, apply_rows};

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

/// Machine section: w4, group g1 (w1, w2, w3), w5.
fn fixture() -> Doc {
    let mut section = Section::machine(SESSION);
    section.order = super::order_key::spread(1).remove(0);
    let mut doc = Doc::from_parts(0, vec![section], vec![]);
    run(
        &mut doc,
        vec![Op::Adopt { refs: ["w4", "w1", "w2", "w3", "w5"].map(reference).to_vec(), to: None }],
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

fn pinned_in_group(doc: &Doc, id: &str) -> bool {
    doc.item(&item_id(id)).expect("item").pinned_in_group()
}

#[test]
fn fixture_lists_loose_rows_around_the_group() {
    let doc = fixture();
    assert_eq!(list(&doc, &machine(), None), ["w4", "g1", "w5"]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w1", "w2", "w3"]);
}

#[test]
fn pin_in_a_group_keeps_the_workspace_in_the_group_on_top() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    let item = doc.item(&item_id("w3")).unwrap();
    assert_eq!(item.parent.as_deref(), Some("g1"));
    assert_eq!(item.section, machine());
    assert!(item.pinned_in_group());
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w3", "w1", "w2"]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "g1", "w5"], "nothing moves at the top level");
}

#[test]
fn a_second_pin_in_a_group_lands_after_the_first() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w2")] }]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w3", "w2", "w1"]);
}

#[test]
fn pin_is_idempotent_in_a_group() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w2")] }]);
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    assert_eq!(
        list(&doc, &machine(), Some("g1")),
        ["w3", "w2", "w1"],
        "pinning a pinned member keeps its place"
    );
}

#[test]
fn unpin_in_a_group_returns_under_the_pinned_members() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w2")] }]);
    run(&mut doc, vec![Op::Unpin { items: vec![item_id("w3")] }]);
    assert!(!pinned_in_group(&doc, "w3"));
    assert_eq!(
        doc.item(&item_id("w3")).unwrap().parent.as_deref(),
        Some("g1"),
        "unpin keeps it in its group"
    );
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w2", "w3", "w1"]);
}

#[test]
fn an_unpinned_member_cannot_go_above_the_pinned_ones() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    let to = Target {
        section: machine(),
        parent: Some("g1".into()),
        index: Some(0),
        ..Target::default()
    };
    run(&mut doc, vec![Op::Move { items: vec![item_id("w1")], to }]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w3", "w1", "w2"]);
}

#[test]
fn a_pinned_member_cannot_go_below_the_unpinned_ones() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    let to = Target { section: machine(), parent: Some("g1".into()), ..Target::default() };
    run(&mut doc, vec![Op::Move { items: vec![item_id("w3")], to }]);
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w3", "w1", "w2"]);
    assert!(pinned_in_group(&doc, "w3"));
}

#[test]
fn a_pinned_member_dragged_out_of_its_group_is_no_longer_pinned() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    run(&mut doc, vec![Op::Move { items: vec![item_id("w3")], to: Target::end(&machine()) }]);
    let item = doc.item(&item_id("w3")).unwrap();
    assert_eq!(item.parent, None);
    assert!(!item.pinned_in_group());
    assert_eq!(list(&doc, &machine(), None), ["w4", "g1", "w5", "w3"]);
}

#[test]
fn undo_of_a_pin_in_a_group_restores_the_order_and_the_flag() {
    let mut doc = fixture();
    let inverse = run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    apply_rows(&mut doc, &inverse);
    assert!(!pinned_in_group(&doc, "w3"));
    assert_eq!(list(&doc, &machine(), Some("g1")), ["w1", "w2", "w3"]);
}

#[test]
fn a_loose_workspace_pinned_to_the_band_unpins_back_to_its_place() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w4")] }]);
    assert_eq!(list(&doc, PINNED_SECTION_ID, None), ["w4"]);
    assert_eq!(list(&doc, &machine(), None), ["g1", "w5"]);
    run(&mut doc, vec![Op::Unpin { items: vec![item_id("w4")] }]);
    assert_eq!(
        list(&doc, &machine(), None),
        ["w4", "g1", "w5"],
        "back first, where it was, not at the end"
    );
    assert!(
        doc.item(&item_id("w4")).unwrap().extra.get(UNPIN_TO_KEY).is_none(),
        "the remembered place is spent"
    );
}

#[test]
fn a_pinned_group_unpins_back_to_its_place() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec!["g1".into()] }]);
    assert_eq!(list(&doc, PINNED_SECTION_ID, None), ["g1"]);
    assert_eq!(
        list(&doc, PINNED_SECTION_ID, Some("g1")),
        ["w1", "w2", "w3"],
        "its members follow it"
    );
    run(&mut doc, vec![Op::Unpin { items: vec!["g1".into()] }]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "g1", "w5"]);
}

/// An empty group (a saved group kept when its workspaces closed) has no
/// workspace to name its machine: Unpin was refused (`no_machine`), so an
/// empty pinned group stayed in Pinned for good (#22259).
#[test]
fn an_empty_pinned_group_unpins_back_to_its_place() {
    let mut doc = fixture();
    let empty = Op::GroupCreate {
        id: Some("g2".into()),
        name: "Saved".into(),
        color: None,
        icon: None,
        profile: None,
        items: Vec::new(),
        to: Some(Target::end(&machine())),
    };
    run(&mut doc, vec![empty]);
    assert_eq!(list(&doc, &machine(), None), ["w4", "g1", "w5", "g2"]);
    run(&mut doc, vec![Op::Pin { items: vec!["g2".into()] }]);
    assert_eq!(list(&doc, PINNED_SECTION_ID, None), ["g2"]);
    run(&mut doc, vec![Op::Unpin { items: vec!["g2".into()] }]);
    assert_eq!(
        list(&doc, &machine(), None),
        ["w4", "g1", "w5", "g2"],
        "back where it was pinned from"
    );
    assert!(list(&doc, PINNED_SECTION_ID, None).is_empty());
}

/// An empty group made in Pinned has no place to go back to: Unpin puts it
/// at the top of the first machine section.
#[test]
fn an_empty_group_made_in_pinned_unpins_to_the_top_of_the_first_machine_section() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w5")] }]);
    let empty = Op::GroupCreate {
        id: Some("g2".into()),
        name: "Saved".into(),
        color: None,
        icon: None,
        profile: None,
        items: Vec::new(),
        to: Some(Target::end(PINNED_SECTION_ID)),
    };
    run(&mut doc, vec![empty]);
    assert_eq!(list(&doc, PINNED_SECTION_ID, None), ["w5", "g2"]);
    run(&mut doc, vec![Op::Unpin { items: vec!["g2".into()] }]);
    assert_eq!(list(&doc, &machine(), None), ["g2", "w4", "g1"]);
}

#[test]
fn unpin_falls_back_to_the_top_when_the_old_neighbor_is_gone() {
    let mut doc = fixture();
    // w5 sat after g1; then g1 is pinned too, so w5's old neighbor is not in the list.
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w5")] }]);
    run(&mut doc, vec![Op::Pin { items: vec!["g1".into()] }]);
    run(&mut doc, vec![Op::Unpin { items: vec![item_id("w5")] }]);
    assert_eq!(
        list(&doc, &machine(), None),
        ["w5", "w4"],
        "the top of its machine section, as Move to Top"
    );
    // g1 sat after w4, which is still there.
    run(&mut doc, vec![Op::Unpin { items: vec!["g1".into()] }]);
    assert_eq!(list(&doc, &machine(), None), ["w5", "w4", "g1"]);
}

#[test]
fn an_old_pin_with_no_remembered_place_unpins_to_the_top() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec!["g1".into()] }]);
    // A pin made before the place was remembered (an older daemon).
    let id: ItemId = "g1".into();
    let mut item = doc.item(&id).unwrap().clone();
    item.extra.remove(UNPIN_TO_KEY);
    apply_rows(&mut doc, &[Op::ItemPut { item }]);
    run(&mut doc, vec![Op::Unpin { items: vec![id] }]);
    assert_eq!(list(&doc, &machine(), None), ["g1", "w4", "w5"]);
}

#[test]
fn pins_survive_a_save_and_load() {
    let mut doc = fixture();
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w3")] }]);
    run(&mut doc, vec![Op::Pin { items: vec![item_id("w4")] }]);
    let (sections, items) = doc.to_parts();
    let text = serde_json::to_string(&(sections, items)).unwrap();
    let (sections, items): (Vec<Section>, Vec<Item>) = serde_json::from_str(&text).unwrap();
    let mut loaded = Doc::from_parts(doc.revision, sections, items);
    assert!(pinned_in_group(&loaded, "w3"));
    assert_eq!(list(&loaded, &machine(), Some("g1")), ["w3", "w1", "w2"]);
    run(&mut loaded, vec![Op::Unpin { items: vec![item_id("w4")] }]);
    assert_eq!(
        list(&loaded, &machine(), None),
        ["w4", "g1", "w5"],
        "the remembered place survives a restart"
    );
}

/// Each space owns its pins (leo-workspace design/spaces.md): a link, tab or app
/// moved into Pinned from another band takes the acting window's space, which
/// `item.update {patch: {room}}` stores as `extra.room` in the same change as
/// the move; its inverse takes it back, and a null room clears it.
#[test]
fn item_update_stores_the_items_space_and_its_inverse_takes_it_back() {
    let mut pinned = Section::pinned();
    pinned.order = super::order_key::spread(1).remove(0);
    let mut link = Item::new(
        "l1",
        PINNED_SECTION_ID,
        Body::Url { url: "https://a.example".into(), title: None, icon_url: None },
    );
    link.order = super::order_key::spread(1).remove(0);
    let mut doc = Doc::from_parts(0, vec![pinned], vec![link]);
    let room = |doc: &Doc| doc.item("l1").expect("l1").extra.get("room").cloned();
    let update: Vec<Op> = serde_json::from_value(serde_json::json!([
        {"op": "item.update", "id": "l1", "patch": {"room": "prof_work"}}
    ]))
    .expect("ops read");
    let inverse = run(&mut doc, update);
    assert_eq!(room(&doc), Some(serde_json::Value::String("prof_work".into())));
    run(&mut doc, inverse);
    assert_eq!(room(&doc), None, "undo takes the space back");

    let set: Vec<Op> = serde_json::from_value(serde_json::json!([
        {"op": "item.update", "id": "l1", "patch": {"room": "prof_work"}}
    ]))
    .expect("ops read");
    run(&mut doc, set);
    let clear: Vec<Op> = serde_json::from_value(serde_json::json!([
        {"op": "item.update", "id": "l1", "patch": {"room": null}}
    ]))
    .expect("ops read");
    run(&mut doc, clear);
    assert_eq!(room(&doc), None, "a null room clears it");
}
