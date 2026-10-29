use super::*;
use serde_json::json;

#[test]
fn set_field_writes_objects_and_nulls() {
    let mut object = json!({"op": "close-tabs"});
    set_field(&mut object, "reason", json!("session_end")).unwrap();
    assert_eq!(object, json!({"op": "close-tabs", "reason": "session_end"}));

    let mut null = Value::Null;
    set_field(&mut null, "cwd", json!("/tmp")).unwrap();
    assert_eq!(null, json!({"cwd": "/tmp"}));

    let mut named = json!({});
    set_named_field(&mut named, "fields", "argv".to_string(), json!(["sh"])).unwrap();
    assert_eq!(named, json!({"argv": ["sh"]}));
}

#[test]
fn set_field_on_a_non_object_is_an_error_not_a_panic() {
    for mut value in [json!("text"), json!(3), json!([1, 2]), json!(true)] {
        let before = value.clone();
        assert_eq!(set_field(&mut value, "reason", json!(1)), Err(NotAnObject { key: "reason" }));
        assert_eq!(value, before, "a refused write leaves the value unchanged");
        assert_eq!(
            set_named_field(&mut value, "result", "key".to_string(), json!(1)),
            Err(NotAnObject { key: "result" })
        );
    }
    let error: anyhow::Error = NotAnObject { key: "zoomed" }.into();
    assert_eq!(
        error.to_string(),
        "cannot set field \"zoomed\" on a JSON value that is not an object"
    );
}
