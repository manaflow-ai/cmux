use super::*;

#[test]
fn round_trip_keeps_key_order_and_numbers() {
    let text = "{\n  \"zeta\": 1,\n  \"alpha\": {\n    \"y\": [true, null, 2.5],\n    \"b\": \"x\"\n  },\n  \"m\": -3\n}\n";
    let value = OJson::parse(text).unwrap();
    assert_eq!(
        value.to_pretty(),
        text.replace("[true, null, 2.5]", "[\n      true,\n      null,\n      2.5\n    ]")
    );
    let keys: Vec<_> = value.as_object().unwrap().keys().cloned().collect();
    assert_eq!(keys, ["zeta", "alpha", "m"]);
}

#[test]
fn empty_file_is_an_empty_object() {
    assert_eq!(OJson::parse("  \n").unwrap(), OJson::object());
}

#[test]
fn render_over_keeps_untouched_members_text() {
    let old = "{\n  \"allow\": [\"a\", \"b\"],\n  \"hooks\": {}\n}\n";
    let mut value = OJson::parse(old).unwrap();
    // Unchanged: byte for byte, the compact array included.
    assert_eq!(value.render_over(old), old);
    if let Some(map) = value.as_object_mut() {
        map.insert("hooks".to_owned(), OJson::parse("{\"Stop\": []}").unwrap());
    }
    assert_eq!(
        value.render_over(old),
        "{\n  \"allow\": [\"a\", \"b\"],\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n"
    );
}
