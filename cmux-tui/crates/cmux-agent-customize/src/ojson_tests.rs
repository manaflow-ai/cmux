use super::*;

#[test]
fn keeps_order_and_bytes() {
    let text = "{\n  \"zeta\": 1,\n  \"alpha\": {\n    \"b\": [\n      \"x\",\n      2.5,\n      true,\n      null\n    ],\n    \"a\": {},\n    \"e\": []\n  },\n  \"ü\": \"é\\n\\\"q\\\"\"\n}";
    let json = Json::parse(text).unwrap();
    assert_eq!(json.pretty(), text);
    let keys: Vec<&str> = json.as_object().unwrap().iter().map(|(k, _)| k.as_str()).collect();
    assert_eq!(keys, ["zeta", "alpha", "ü"]);
}

#[test]
fn numbers_print_as_javascript() {
    for (input, shown) in [
        ("1", "1"),
        ("-3", "-3"),
        ("1.0", "1"),
        ("0.1", "0.1"),
        ("1e21", "1e+21"),
        ("1.5e-7", "1.5e-7"),
        ("18446744073709551615", "18446744073709551615"),
    ] {
        assert_eq!(Json::parse(input).unwrap().pretty(), shown, "{input}");
    }
}

#[test]
fn set_keeps_position_and_remove_drops() {
    let mut json = Json::parse(r#"{"a":1,"b":2,"c":3}"#).unwrap();
    json.set("b", Json::Bool(false));
    json.set("d", Json::Null);
    assert_eq!(json.remove("a"), Some(Json::Number(1.into())));
    assert_eq!(json.pretty(), "{\n  \"b\": false,\n  \"c\": 3,\n  \"d\": null\n}");
    let mut not_object = Json::Array(vec![]);
    assert!(!not_object.set("x", Json::Null));
    assert!(not_object.object_at("x").is_none());
    let mut holder = Json::parse(r#"{"s":"text"}"#).unwrap();
    assert!(holder.object_at("s").is_none(), "a string member is never replaced");
}
