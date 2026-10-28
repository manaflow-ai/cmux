use serde_json::{Value, json};

use super::JsonFields;

#[test]
fn field_reads_like_the_index_operator() {
    let value = json!({"a": {"b": 1}, "list": [1, 2]});
    assert_eq!(value.field("a").field("b"), &json!(1));
    assert_eq!(value.field("missing"), &Value::Null);
    assert_eq!(value.field("list").field("b"), &Value::Null);
    assert_eq!(json!("text").field("a"), &Value::Null);
}

#[test]
fn insert_writes_objects_and_turns_null_into_one() {
    let mut value = json!({"a": 1});
    value.insert("b", json!(2));
    assert_eq!(value, json!({"a": 1, "b": 2}));

    let mut null = Value::Null;
    null.insert("a", json!(true));
    assert_eq!(null, json!({"a": true}));
}

#[test]
fn insert_on_a_non_object_leaves_it_unchanged_where_index_mut_panics() {
    for original in [json!([1, 2]), json!("text"), json!(3), json!(false)] {
        let mut value = original.clone();
        value.insert("a", json!(1));
        assert_eq!(value, original);
    }
}
