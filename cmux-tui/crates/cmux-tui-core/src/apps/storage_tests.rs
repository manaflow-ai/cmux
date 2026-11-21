use super::*;

#[test]
fn set_get_keys_delete_and_clear_are_per_app() {
    let s = Storage::open(None).unwrap();
    s.call("cmux/a", "app.storage.set", &json!({ "key": "k", "value": { "n": 1 } })).unwrap();
    s.call("cmux/b", "app.storage.set", &json!({ "key": "k", "value": 2 })).unwrap();
    assert_eq!(
        s.call("cmux/a", "app.storage.get", &json!({ "key": "k" })).unwrap(),
        json!({ "n": 1 })
    );
    assert_eq!(s.call("cmux/a", "app.storage.keys", &json!({})).unwrap(), json!(["k"]));
    s.clear("cmux/a").unwrap();
    assert_eq!(s.call("cmux/a", "app.storage.get", &json!({ "key": "k" })).unwrap(), Value::Null);
    assert_eq!(s.call("cmux/b", "app.storage.get", &json!({ "key": "k" })).unwrap(), json!(2));
    s.call("cmux/b", "app.storage.delete", &json!({ "key": "k" })).unwrap();
    assert_eq!(s.call("cmux/b", "app.storage.keys", &json!({})).unwrap(), json!([]));
}

#[test]
fn limits_are_enforced() {
    let s = Storage::open(None).unwrap();
    let big = "x".repeat(MAX_VALUE_BYTES);
    assert_eq!(
        s.call("a", "app.storage.set", &json!({ "key": "k", "value": big })).unwrap_err().code,
        "app.limit"
    );
    assert_eq!(
        s.call("a", "app.storage.get", &json!({ "key": "" })).unwrap_err().code,
        "validation.invalid"
    );
}
