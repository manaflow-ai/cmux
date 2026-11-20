use super::*;
use serde_json::json;

#[test]
fn catalog_round_trip_and_session_edits_are_independent() {
    let raw = json!([{"id":"model", "currentValue":"a", "options":[
        {"value":"a", "name":"Model A", "future":{"unicode":"λ", "null":null}},
        {"value":"b", "name":"Model B"}
    ]}]);
    let original: SharedValue = serde_json::from_value(raw.clone()).unwrap();
    let mut edited: SharedValue = serde_json::from_value(raw.clone()).unwrap();
    assert!(Arc::ptr_eq(&original.0, &edited.0));
    edited[0]["currentValue"] = json!("b");
    assert!(!Arc::ptr_eq(&original.0, &edited.0));
    assert_eq!(serde_json::to_value(&original).unwrap(), raw);
    assert_eq!(edited[0]["currentValue"], "b");
    assert_eq!(original[0]["currentValue"], "a");
    let cloned = original.clone();
    assert!(Arc::ptr_eq(&original.0, &cloned.0));
}

#[test]
fn collisions_do_not_share_different_catalogs() {
    let mut pool = Interner::default();
    let first = pool.intern(json!({"a":1}), 0);
    let second = pool.intern(json!({"a":2}), 0);
    assert!(!Arc::ptr_eq(&first, &second));
    assert_eq!(*first, json!({"a":1}));
    assert_eq!(*second, json!({"a":2}));
}

#[test]
fn no_op_updates_keep_sharing_and_real_edits_detach() {
    let original = SharedValue::from(json!([
        {"id":"model", "currentValue":"a"},
        {"id":"mode", "currentValue":"default"}
    ]));
    let mut edited = original.clone();
    assert!(!edited.update_matching(
        |item| item["currentValue"] == "bypassPermissions",
        |item| item["currentValue"] = Value::Null,
    ));
    assert!(Arc::ptr_eq(&original.0, &edited.0));
    assert!(
        edited.update_matching(
            |item| item["id"] == "mode",
            |item| item["currentValue"] = Value::Null,
        )
    );
    assert!(!Arc::ptr_eq(&original.0, &edited.0));
    assert_eq!(original[1]["currentValue"], "default");
    assert!(edited[1]["currentValue"].is_null());
    assert_eq!(edited[0], original[0]);
}

#[test]
fn bookkeeping_is_bounded_and_does_not_retain_catalogs() {
    let mut pool = Interner::default();
    let live: Vec<_> = (0..INTERN_SLOTS * 2).map(|n| pool.intern(json!(n), n as u64)).collect();
    assert!(pool.0.len() <= INTERN_SLOTS);
    assert_eq!(*live[0], json!(0));
    let weak = Arc::downgrade(&live[0]);
    drop(live);
    assert!(weak.upgrade().is_none());
    pool.intern(Value::Null, u64::MAX);
    assert_eq!(pool.0.len(), 1);
}
