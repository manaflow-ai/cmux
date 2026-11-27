use super::*;
use crate::server::session_patch::SentRows;
use serde_json::json;

fn changed(id: &str, row: Value, row_seq: Option<u64>) -> Value {
    let mut p = json!({"sessionId": id, "session": row, "kind": "status", "seq": 1});
    if let Some(n) = row_seq {
        p["rowSeq"] = json!(n);
    }
    p
}

fn patch(id: &str, patch: Value, base: u64) -> Value {
    json!({"sessionId": id, "patch": patch, "rowSeq": base + 1, "baseRowSeq": base,
           "kind": "status", "recordKind": "turn_started", "seq": 2})
}

/// The daemon's side and this one against each other: every row the peer's `SentRows` sends as
/// a patch comes out of the link as that row, whole.
#[test]
fn each_patch_comes_out_as_the_row_it_stands_for() {
    let rows = [
        json!({"sessionId": "s", "status": "idle", "timeBreakdown": {"spans": (0..40).map(|i| json!({"i": i})).collect::<Vec<_>>()}}),
        json!({"sessionId": "s", "status": "running", "timeBreakdown": {"spans": (0..41).map(|i| json!({"i": i})).collect::<Vec<_>>()}}),
        json!({"sessionId": "s", "status": "running", "turn": {"activity": "Read"}, "timeBreakdown": {"spans": (1..42).map(|i| json!({"i": i})).collect::<Vec<_>>()}}),
        json!({"sessionId": "s", "status": "idle", "timeBreakdown": {"spans": (1..42).map(|i| json!({"i": i})).collect::<Vec<_>>()}}),
    ];
    let mut sent = SentRows::default();
    let mut held = HeldRows::default();
    for row in &rows {
        let (m, mut p) = match sent.change("s", true, row) {
            crate::server::session_patch::Change::Whole { row_seq } => {
                (method::MUX_SESSION_CHANGED, changed("s", row.clone(), Some(row_seq)))
            }
            crate::server::session_patch::Change::Patch { patch: d, row_seq } => {
                (method::MUX_SESSION_PATCH, patch("s", d, row_seq - 1))
            }
        };
        let read = held.read(m, &mut p, 100);
        assert!(matches!(read, Read::Pass | Read::Changed), "{read:?}");
        assert_eq!(&p["session"], row);
        assert!(p.get("patch").is_none() && p.get("baseRowSeq").is_none(), "{p}");
    }
    assert_eq!(held.held("s").unwrap().0, 4);
}

/// A patch whose base is not the held row (one went missing) is dropped with the row, and the
/// link asks for it whole once; the patches after it are dropped without asking again, until
/// the whole row comes.
#[test]
fn a_gap_drops_the_row_and_asks_for_it_whole_once() {
    let mut held = HeldRows::default();
    let mut p = changed("s", json!({"a": 1}), Some(1));
    assert_eq!(held.read(method::MUX_SESSION_CHANGED, &mut p, 10), Read::Pass);
    let mut p = patch("s", json!({"a": 3}), 2);
    assert_eq!(held.read(method::MUX_SESSION_PATCH, &mut p, 10), Read::Drop(Some("s".into())));
    assert!(held.held("s").is_none());
    let mut p = patch("s", json!({"a": 4}), 3);
    assert_eq!(held.read(method::MUX_SESSION_PATCH, &mut p, 10), Read::Drop(None));
    // The resync's whole row.
    let mut p = changed("s", json!({"a": 4}), Some(5));
    assert_eq!(held.read(method::MUX_SESSION_CHANGED, &mut p, 10), Read::Pass);
    let mut p = patch("s", json!({"b": 1}), 5);
    assert_eq!(held.read(method::MUX_SESSION_PATCH, &mut p, 10), Read::Changed);
    assert_eq!(p["session"], json!({"a": 4, "b": 1}));
    // A later gap asks again.
    let mut p = patch("s", json!({"b": 2}), 9);
    assert_eq!(held.read(method::MUX_SESSION_PATCH, &mut p, 10), Read::Drop(Some("s".into())));
}

/// A patch of a chat never held (the link opened after its whole row) and one that does not
/// fit the held row (a splice past its end) both ask for the row whole.
#[test]
fn a_patch_of_nothing_held_or_that_does_not_fit_asks_for_the_row() {
    let mut held = HeldRows::default();
    let mut p = patch("new", json!({"a": 1}), 1);
    assert_eq!(held.read(method::MUX_SESSION_PATCH, &mut p, 10), Read::Drop(Some("new".into())));
    let mut p = changed("s", json!({"l": [1, 2]}), Some(1));
    held.read(method::MUX_SESSION_CHANGED, &mut p, 10);
    let mut p = patch("s", json!({"l": {"$splice": [0, 9, [3]]}}), 1);
    assert_eq!(held.read(method::MUX_SESSION_PATCH, &mut p, 10), Read::Drop(Some("s".into())));
    assert!(held.held("s").is_none());
}

/// A peer before version 2 sends whole rows with no `rowSeq`: they pass as they came and
/// nothing is held for them.
#[test]
fn an_old_peers_whole_rows_pass_and_hold_nothing() {
    let mut held = HeldRows::default();
    let row = json!({"sessionId": "s", "title": "x"});
    let mut p = changed("s", row.clone(), None);
    assert_eq!(held.read(method::MUX_SESSION_CHANGED, &mut p, 10), Read::Pass);
    assert_eq!(p["session"], row);
    assert!(held.held("s").is_none());
    assert_eq!(held.bytes(), 0);
    let mut other = json!({"sessionId": "s", "seq": 3});
    assert_eq!(held.read(method::MUX_EVENT, &mut other, 10), Read::Pass);
}

/// A purge lets the chat's row go: a patch after it asks for the row again.
#[test]
fn a_purge_lets_the_row_go() {
    let mut held = HeldRows::default();
    let mut p = changed("s", json!({"a": 1}), Some(1));
    held.read(method::MUX_SESSION_CHANGED, &mut p, 10);
    let mut purge = json!({"sessionId": "s", "session": {"sessionId": "s"}, "kind": "purged"});
    held.read(method::MUX_SESSION_CHANGED, &mut purge, 10);
    assert!(held.held("s").is_none());
    assert_eq!(held.bytes(), 0);
}

/// A patched row is used: past the bound it outlives a row only held whole, as the peer keeps the
/// rows it sent last (`session_patch.rs` `SentRows`).
#[test]
fn a_patched_row_outlives_an_idle_one() {
    let mut held = HeldRows::default();
    for i in 0..MAX_ROWS {
        let mut p = changed(&format!("c{i}"), json!({"i": i}), Some(1));
        held.read(method::MUX_SESSION_CHANGED, &mut p, 10);
    }
    let mut patch = json!({"sessionId": "c0", "patch": {"i": 99}, "rowSeq": 2, "baseRowSeq": 1});
    assert_eq!(held.read(method::MUX_SESSION_PATCH, &mut patch, 10), Read::Changed);
    let mut p = changed("fresh", json!({}), Some(1));
    held.read(method::MUX_SESSION_CHANGED, &mut p, 10);
    assert!(held.held("c0").is_some(), "the patched row stays");
    assert!(held.held("c1").is_none(), "the row heard longest ago went");
    assert_eq!(held.rows.len(), MAX_ROWS);
}

/// Bounded by count and by bytes: past either the oldest go, and the bytes count stays true.
#[test]
fn held_rows_stay_within_their_bounds() {
    let mut held = HeldRows::default();
    for i in 0..MAX_ROWS + 20 {
        let mut p = changed(&format!("c{i}"), json!({"i": i}), Some(1));
        held.read(method::MUX_SESSION_CHANGED, &mut p, 1000);
    }
    assert_eq!(held.rows.len(), MAX_ROWS);
    assert!(held.held("c0").is_none() && held.held(&format!("c{}", MAX_ROWS + 19)).is_some());
    assert_eq!(held.bytes(), MAX_ROWS * 1000);
    // A row held again is the newest: the oldest others go before it, and the order stays near
    // the rows' count.
    let newest = format!("c{}", MAX_ROWS + 19);
    let renewed = "c20";
    for n in 2..2000 {
        let mut p = changed(renewed, json!({"n": n}), Some(n));
        held.read(method::MUX_SESSION_CHANGED, &mut p, 1000);
    }
    assert!(held.order.len() <= 2 * MAX_ROWS + 1, "{}", held.order.len());
    let mut p = changed("fresh", json!({}), Some(1));
    held.read(method::MUX_SESSION_CHANGED, &mut p, 1000);
    assert!(held.held(renewed).is_some(), "the renewed row stays");
    assert!(held.held("c21").is_none(), "the oldest other row went");
    assert!(held.held(&newest).is_some());
    assert_eq!(held.rows.len(), MAX_ROWS);
    // Rows past the byte bound let the oldest go, never the one just held.
    let mut big = HeldRows::default();
    for i in 0..4 {
        let mut p = changed(&format!("b{i}"), json!({}), Some(1));
        big.read(method::MUX_SESSION_CHANGED, &mut p, MAX_BYTES / 3);
    }
    assert!(big.bytes() <= MAX_BYTES);
    assert!(big.held("b3").is_some() && big.held("b0").is_none());
}
