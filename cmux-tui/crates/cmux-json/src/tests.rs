use super::JsonSet as _;
use serde_json::{Map, Value, json};

#[test]
fn set_writes_objects_and_null() {
    let mut object = json!({ "a": 1 });
    object.set("b", json!("two"));
    object.set("a", json!([3]));
    assert_eq!(object, json!({ "a": [3], "b": "two" }));

    let mut null = Value::Null;
    assert!(null.set("k", json!(true)));
    assert_eq!(null, json!({ "k": true }));
}

#[test]
fn set_leaves_non_objects_unchanged() {
    for start in [json!([1]), json!("s"), json!(4), json!(false)] {
        let mut value = start.clone();
        assert!(!value.set("k", json!(1)));
        assert!(value.object_mut().is_none());
        value.set_path(&["k", "j"], json!(1));
        assert_eq!(value, start);
    }
}

#[test]
fn set_path_creates_parents_and_stops_at_non_objects() {
    let mut value = json!({ "error": null, "meta": { "keep": 1 } });
    value.set_path(&["error", "data"], json!(5));
    value.set_path(&["meta", "acpmux", "source"], json!("peer"));
    assert_eq!(
        value,
        json!({ "error": { "data": 5 }, "meta": { "keep": 1, "acpmux": { "source": "peer" } } })
    );

    let mut blocked = json!({ "error": "text" });
    blocked.set_path(&["error", "data"], json!(5));
    assert_eq!(blocked, json!({ "error": "text" }));

    let mut empty = json!({});
    empty.set_path(&[], json!(5));
    assert_eq!(empty, json!({}));
}

#[test]
fn map_set_inserts() {
    let mut map = Map::new();
    map.set("k", json!(1));
    map.set_path(&["a", "b"], json!(2));
    assert_eq!(Value::Object(map), json!({ "k": 1, "a": { "b": 2 } }));
}

#[test]
fn get_reads_one_member_of_its_type_and_never_coerces() {
    use super::JsonGet as _;
    let value = json!({ "s": "x", "n": 7, "neg": -1, "b": false, "a": [1], "q": "7" });
    assert_eq!(value.get_str("s"), Some("x"));
    assert_eq!(value.get_string("s"), Some("x".to_owned()));
    assert_eq!(value.get_nonempty_str("s"), Some("x"));
    assert_eq!(json!({ "e": "" }).get_nonempty_str("e"), None);
    assert_eq!(json!({ "e": "" }).get_str("e"), Some(""));
    assert_eq!(value.get_u64("n"), Some(7));
    assert_eq!(value.get_bool("b"), Some(false));
    assert_eq!(value.get_array("a"), &[json!(1)]);
    assert_eq!(value.get_u64("q"), None, "a numeric string is not a number");
    assert_eq!(value.get_u64("neg"), None);
    assert_eq!(value.get_str("n"), None);
    assert_eq!(value.get_bool("missing"), None);
    assert!(value.get_array("s").is_empty());
    for other in [json!([1]), json!("s"), Value::Null] {
        assert_eq!(other.get_str("s"), None);
        assert!(other.get_array("a").is_empty());
    }
    let map = value.as_object().unwrap();
    assert_eq!(map.get_str("s"), Some("x"));
}
