use super::*;
use serde_json::json;

const LIMITS: WriteLimits =
    WriteLimits { bytes: 1000, records: 50, repeat_percent: 50, repeat_floor: 10 };

/// A kind over its bytes warns once in its window, and again in the next hour.
#[test]
fn a_kind_over_its_bytes_warns_once_an_hour() {
    let budget = WriteBudget::new("test log", LIMITS);
    let warnings = |start: u64| {
        (0..8u64)
            .filter_map(|i| budget.note("big", 200, &json!({"n": i}), start + i))
            .collect::<Vec<_>>()
    };
    let first = warnings(0);
    assert_eq!(first.len(), 1);
    assert!(first[0].contains("kind big wrote 1200 bytes in 6 records"), "{}", first[0]);
    assert_eq!(warnings(WINDOW_MS).len(), 1, "a new window warns again");
    assert!(budget.note("other", 10, &json!("x"), WINDOW_MS + 9).is_none(), "kinds count apart");
}

/// Two states written in turn (ABAB), each with a new revision and time, warn as repeats though
/// no record equals the one before.
#[test]
fn a_ping_pong_warns_as_repeats() {
    let budget = WriteBudget::new("test log", LIMITS);
    let warned: Vec<String> = (0..12u64)
        .filter_map(|i| {
            budget.note("flip", 10, &json!({"state": i % 2, "revision": i, "updated_at_ms": i}), i)
        })
        .collect();
    assert_eq!(warned.len(), 1);
    assert!(warned[0].contains("in 10 records"), "{}", warned[0]);
    let distinct = WriteBudget::new("test log", LIMITS);
    assert!(
        (0..40u64).all(|i| distinct.note("new", 10, &json!({"n": i, "revision": i}), i).is_none())
    );
}

/// A resource row's state written again under a new idempotency key counts as a repeat, and
/// the same fields nested differently do not (review follow-ups on #39148).
#[test]
fn repeats_ignore_the_write_key_and_respect_nesting() {
    let hash = |value: serde_json::Value| {
        let mut hasher = DefaultHasher::new();
        fingerprint(&value, &mut hasher);
        hasher.finish()
    };
    assert_eq!(
        hash(json!({"idempotency_key": "k1", "result": {"project": "p", "last_used_ms": 1}})),
        hash(json!({"idempotency_key": "k2", "result": {"project": "p", "last_used_ms": 2}})),
    );
    assert_ne!(hash(json!({"a": {"b": 1}, "c": 2})), hash(json!({"a": {"b": 1, "c": 2}})));
}

/// Too many records warn even when each is small.
#[test]
fn too_many_records_warn() {
    let budget = WriteBudget::new("test log", LIMITS);
    let warned = (0..60u64).filter(|i| budget.note("tick", 1, &json!({"n": i}), *i).is_some());
    assert_eq!(warned.count(), 1);
}
