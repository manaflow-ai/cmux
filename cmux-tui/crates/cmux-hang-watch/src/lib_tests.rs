//! Unit tests of the state word, the slot name, the record line and the thread kinds.

use super::*;
use crate::slot::{BUDGET_MAX_MS, budget_ms, pack};

#[test]
fn state_packs_deadline_budget_and_flags_apart() {
    let state = pack(123_456, 2_000);
    assert_eq!(deadline_of(state), 123_456);
    assert_eq!(budget_of(state), 2_000);
    assert_eq!(budget_of(state | IGNORED | REPORTED), 2_000);
    assert_eq!(budget_ms(Duration::ZERO), 1, "an open state is never 0");
    assert_eq!(budget_ms(Duration::from_micros(1500)), 2);
    assert_eq!(budget_ms(Duration::from_secs(10_000)), BUDGET_MAX_MS);
}

#[test]
fn names_are_cut_at_a_character_boundary() {
    let slot = Slot::new();
    slot.set_name("mux-control-dispatch");
    assert_eq!(slot.read_name(), "mux-control-dispatch");
    let long = "é".repeat(30);
    slot.set_name(&long);
    assert_eq!(slot.read_name(), "é".repeat(20));
}

#[test]
fn json_line_escapes_the_name() {
    let hang = Hang {
        pid: 7,
        t_ns: 9,
        thread: "a\"b\\c\n".into(),
        kind: ThreadKind::Io,
        native_thread_id: 3,
        slot: 1,
        deadline_ms: 250,
        overdue_ms: 4,
        stack: None,
    };
    assert_eq!(
        hang.to_json_line(),
        "{\"schema\":1,\"pid\":7,\"t_ns\":9,\"thread\":\"a\\\"b\\\\c\\u000a\",\"kind\":\"io\",\
         \"native_thread_id\":3,\"slot\":1,\"deadline_ms\":250,\"overdue_ms\":4}\n"
    );
}

#[test]
fn thread_kinds_round_trip_with_the_swift_values() {
    let raw: Vec<u8> = ThreadKind::ALL.iter().map(|kind| *kind as u8).collect();
    assert_eq!(raw, [1, 2, 3, 4, 5, 6]);
    for kind in ThreadKind::ALL {
        assert_eq!(ThreadKind::from_raw(kind as u8), Some(kind));
    }
    assert_eq!(ThreadKind::from_raw(0), None);
}
