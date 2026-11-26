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
