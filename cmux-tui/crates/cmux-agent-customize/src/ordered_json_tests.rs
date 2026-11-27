use super::*;

#[test]
fn keeps_order_and_untouched_text() {
    let text = "{\n  \"zeta\": 1,\n  \"alpha\": {\"b\": 2,   \"a\": 1},\n  \"env\": {\"TOKEN\": \"x\"}\n}\n";
    let mut members = Members::parse(text).unwrap();
    assert_eq!(
        members.0.iter().map(|(k, _)| k.as_str()).collect::<Vec<_>>(),
        ["zeta", "alpha", "env"]
    );
    members.set("new", raw_string("v"));
    assert_eq!(
        members.render(0),
        "{\n  \"zeta\": 1,\n  \"alpha\": {\"b\": 2,   \"a\": 1},\n  \"env\": {\"TOKEN\": \"x\"},\n  \"new\": \"v\"\n}"
    );
    members.set("alpha", None);
    assert!(members.get("alpha").is_none());
    assert_eq!(Members::parse("  ").unwrap().render(0), "{}");
    assert!(Members::parse("[1]").is_err());
}
