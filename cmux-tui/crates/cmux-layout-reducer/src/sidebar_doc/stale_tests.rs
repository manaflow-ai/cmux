//! A stale op applies to the document as it is now (`stale.rs`). Each test
//! names the change an automatic caller sends after the document moved on:
//! auto-archive's pass on a workspace that closed, an agent's move next to a
//! row that left, Delete Space's follow-up on an item already gone, a retried
//! change. Before, each was refused (`unknown_item`, `invalid_target`,
//! `unknown_section`), and the app drew the refusal as a toast (Leo, 2026-11-14:
//! "the daemon shouldn't even refuse those").

use serde_json::{Value, json};

use super::reduce::{apply_in_place, check};
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

/// Machine sections for A and B and a custom section; a1, a2, a3 loose in A's, b1 in B's.
fn doc() -> Doc {
    let mut custom = Section::new("sec_custom", SectionKind::Custom, Region::Middle);
    custom.order = "c".into();
    let mut a = Section::machine(A);
    a.order = "a".into();
    let mut b = Section::machine(B);
    b.order = "b".into();
    let mut items = Vec::new();
    for (session, ws, order) in [(A, "a1", "a"), (A, "a2", "b"), (A, "a3", "c"), (B, "b1", "a")] {
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

fn op(value: Value) -> Op {
    serde_json::from_value(value).expect("a wire op")
}

/// Applies `ops`; true when a row changed, false for a no-op.
fn run(doc: &mut Doc, ops: &[Value]) -> Result<bool, Refusal> {
    let ops: Vec<Op> = ops.iter().cloned().map(op).collect();
    apply_in_place(doc, &ops, &mut minter()).map(|applied| !applied.changes.is_empty())
}

/// The ids of `section`'s top-level items, in order.
fn top(doc: &Doc, section: &str) -> Vec<ItemId> {
    doc.list(section, None).map(|item| item.id.clone()).collect()
}

const GONE: &str = "w_closed_meanwhile";

#[test]
fn an_op_on_a_gone_item_is_a_no_op() {
    let ops = [
        json!({"op": "archive", "items": [GONE]}),
        json!({"op": "unarchive", "items": [GONE]}),
        json!({"op": "pin", "items": [GONE]}),
        json!({"op": "unpin", "items": [GONE]}),
        json!({"op": "move", "items": [GONE], "to": {"section": machine_section_id(A)}}),
        json!({"op": "item.remove", "id": GONE}),
        json!({"op": "item.update", "id": GONE, "patch": {"room": "space_2"}}),
        json!({"op": "group.update", "id": "g_deleted", "patch": {"name": "Work"}}),
        json!({"op": "group.ungroup", "id": "g_deleted"}),
        json!({"op": "section.remove", "id": "sec_deleted"}),
        json!({"op": "section.update", "id": "sec_deleted", "patch": {"title": "Later"}}),
        json!({"op": "item.remove_ref", "ref": {"kind": "url", "value": "https://gone.example"}}),
    ];
    for one in ops {
        let mut doc = doc();
        let before = doc.clone();
        assert_eq!(run(&mut doc, std::slice::from_ref(&one)), Ok(false), "{one}");
        assert_eq!(doc, before, "{one} changed the document");
    }
}

#[test]
fn the_items_still_there_apply_and_the_gone_ones_drop_out() {
    let mut doc = doc();
    assert_eq!(run(&mut doc, &[json!({"op": "archive", "items": [GONE, ws(A, "a1")]})]), Ok(true));
    assert!(doc.item(&ws(A, "a1")).unwrap().archived());
}

#[test]
fn a_move_next_to_a_gone_row_lands_at_the_end() {
    let mut doc = doc();
    let section = machine_section_id(A);
    let moved = run(
        &mut doc,
        &[
            json!({"op": "move", "items": [ws(A, "a1")], "to": {"section": section, "before": GONE}}),
        ],
    );
    assert_eq!(moved, Ok(true));
    assert_eq!(top(&doc, &section), vec![ws(A, "a2"), ws(A, "a3"), ws(A, "a1")]);
}

#[test]
fn a_move_into_a_gone_group_lands_at_the_top_level() {
    let mut doc = doc();
    let section = machine_section_id(A);
    let moved = run(
        &mut doc,
        &[
            json!({"op": "move", "items": [ws(A, "a1")], "to": {"section": section, "parent": "g_deleted", "after": ws(A, "a3")}}),
        ],
    );
    assert_eq!(moved, Ok(true));
    assert_eq!(doc.item(&ws(A, "a1")).unwrap().parent, None);
    assert_eq!(top(&doc, &section), vec![ws(A, "a2"), ws(A, "a3"), ws(A, "a1")]);
}

#[test]
fn a_move_into_a_gone_section_leaves_the_items_where_they_are() {
    let mut doc = doc();
    let before = doc.clone();
    assert_eq!(
        run(
            &mut doc,
            &[json!({"op": "move", "items": [ws(A, "a1")], "to": {"section": "sec_deleted"}})]
        ),
        Ok(false)
    );
    assert_eq!(doc, before);
}

/// A replayed change finds it applied: archiving what is archived, moving to where it is.
#[test]
fn a_replayed_change_is_a_no_op() {
    let mut doc = doc();
    let archive = json!({"op": "archive", "items": [ws(A, "a2")]});
    assert_eq!(run(&mut doc, std::slice::from_ref(&archive)), Ok(true));
    assert_eq!(run(&mut doc, &[archive]), Ok(false));
}

/// What stays refused is impossible on the document as it is, not stale.
#[test]
fn an_impossible_move_is_still_refused() {
    let mut doc = doc();
    let into_b =
        json!({"op": "move", "items": [ws(A, "a1")], "to": {"section": machine_section_id(B)}});
    assert_eq!(run(&mut doc, &[into_b]), Err(Refusal::CrossMachine));
}
