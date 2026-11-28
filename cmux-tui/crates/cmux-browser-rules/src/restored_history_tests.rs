use crate::ops;
use crate::restored_history::{Slot, Source, merged, position, session};
use serde_json::json;

fn s(source: Source, index: usize) -> Slot {
    Slot { source, index }
}

#[test]
fn the_engines_first_entry_sits_after_the_saved_back_entries() {
    assert_eq!(position(2, 3, 0), 2);
    assert_eq!(position(0, 0, 0), 0);
}

#[test]
fn a_later_engine_entry_sits_after_the_saved_forward_entries_too() {
    assert_eq!(position(2, 3, 1), 6);
    assert_eq!(position(1, 0, 2), 3);
}

#[test]
fn merged_puts_back_first_then_the_engines_first_then_forward_then_the_rest() {
    let (slots, current) = merged(1, 2, 3, 2);
    assert_eq!(
        slots,
        [
            s(Source::Back, 0),
            s(Source::Own, 0),
            s(Source::Forward, 0),
            s(Source::Forward, 1),
            s(Source::Own, 1),
            s(Source::Own, 2),
        ]
    );
    assert_eq!(current, 5);
}

#[test]
fn merged_with_nothing_saved_is_the_engines_list() {
    let (slots, current) = merged(0, 0, 2, 1);
    assert_eq!(slots, [s(Source::Own, 0), s(Source::Own, 1)]);
    assert_eq!(current, 1);
}

#[test]
fn session_skips_engine_entries_without_a_url_and_follows_the_current_one() {
    let (slots, current) = session(1, 1, &[true, false, true], 2);
    assert_eq!(
        slots,
        [s(Source::Back, 0), s(Source::Own, 0), s(Source::Forward, 0), s(Source::Own, 2)]
    );
    assert_eq!(current, 3);
}

#[test]
fn session_keeps_the_current_in_range() {
    // the engine's only entry has no URL: nothing but the saved entries remain
    let (slots, current) = session(1, 0, &[false], 0);
    assert_eq!(slots, [s(Source::Back, 0)]);
    assert_eq!(current, 0);
    let (slots, current) = session(0, 0, &[false], 0);
    assert!(slots.is_empty());
    assert_eq!(current, 0);
    // current past the list lands on the last entry
    let (_, current) = session(0, 0, &[true], 5);
    assert_eq!(current, 0);
}

#[test]
fn the_ops_answer_in_the_wire_shape_the_app_reads() {
    let merged = ops::call(
        "browser_rules_restored_history_merged",
        json!({"back": 1, "forward": 1, "count": 2, "current": 1}),
    )
    .unwrap();
    assert_eq!(
        merged,
        json!({"slots": [
            {"source": "back", "index": 0},
            {"source": "own", "index": 0},
            {"source": "forward", "index": 0},
            {"source": "own", "index": 1},
        ], "current": 3})
    );
    let session = ops::call(
        "browser_rules_restored_history_session",
        json!({"back": 0, "forward": 0, "hasUrl": [false, true], "current": 1}),
    )
    .unwrap();
    assert_eq!(session, json!({"slots": [{"source": "own", "index": 1}], "current": 0}));
    let position = ops::call(
        "browser_rules_restored_history_position",
        json!({"back": 2, "forward": 1, "current": 0}),
    )
    .unwrap();
    assert_eq!(position, json!(2));
}
