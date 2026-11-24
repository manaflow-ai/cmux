//! A reply written from a tree's text has the bytes serde_json writes of the reply's value: for
//! any tree, with keys before, at and after `lines_written_before_read`, any id and any count.

use super::super::Response;
use super::*;
use proptest::prelude::*;

/// Keys near `lines_written_before_read` in order, keys that need escapes, and the key itself.
fn key() -> impl Strategy<Value = String> {
    prop_oneof![
        Just(LINES_WRITTEN_KEY.to_string()),
        Just("lines_written_before_rea".to_string()),
        Just("lines_written_before_reae".to_string()),
        Just("lines_written_before_reaz".to_string()),
        Just("generation".to_string()),
        Just("workspaces".to_string()),
        "[a-z_\"\\\\\u{e9}\u{7}]{0,8}",
    ]
}

fn json_value() -> impl Strategy<Value = Value> {
    let leaf = prop_oneof![
        Just(Value::Null),
        any::<bool>().prop_map(Value::from),
        any::<i64>().prop_map(Value::from),
        any::<u64>().prop_map(Value::from),
        any::<f64>().prop_map(Value::from),
        key().prop_map(Value::from),
    ];
    leaf.prop_recursive(3, 32, 6, |inner| {
        prop_oneof![
            prop::collection::vec(inner.clone(), 0..6).prop_map(Value::Array),
            prop::collection::btree_map(key(), inner, 0..6)
                .prop_map(|entries| Value::Object(entries.into_iter().collect())),
        ]
    })
}

fn tree() -> impl Strategy<Value = Value> {
    prop::collection::btree_map(key(), json_value(), 0..8)
        .prop_map(|entries| Value::Object(entries.into_iter().collect()))
}

/// The reply's bytes on the command path: the tree with the count set, in a `Response`.
fn value_path(tree: &Value, id: Option<&Value>, lines: Option<u64>) -> Vec<u8> {
    let mut data = tree.clone();
    if let (Some(lines), Value::Object(entries)) = (lines, &mut data) {
        entries.insert(LINES_WRITTEN_KEY.into(), Value::from(lines));
    }
    let response = Response {
        id: id.cloned(),
        ok: true,
        data: Some(data),
        error: None,
        error_code: None,
        error_delivery: None,
    };
    serde_json::to_vec(&response.into_value()).unwrap()
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 512, ..ProptestConfig::default() })]

    #[test]
    fn a_reply_written_from_the_text_has_the_bytes_of_its_value(
        tree in tree(),
        id in prop::option::of(json_value()),
        lines in prop::option::of(any::<u64>()),
    ) {
        let text = TreeText::of(&tree).unwrap();
        let mut written = Vec::new();
        text.write_reply(&mut written, id.as_ref(), lines).unwrap();
        let expected = value_path(&tree, id.as_ref(), lines);
        prop_assert_eq!(String::from_utf8_lossy(&written), String::from_utf8_lossy(&expected));
    }
}

#[test]
fn a_tree_that_is_not_an_object_has_no_text() {
    for tree in [Value::Null, Value::from(1), Value::Array(Vec::new())] {
        assert!(TreeText::of(&tree).is_err(), "{tree}");
    }
}
