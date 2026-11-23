use super::*;

fn fields(line: &str) -> Map<String, Value> {
    let mut object: Map<String, Value> = serde_json::from_str(line).unwrap();
    assert_eq!(object.remove("cmd"), Some(json!(COMMAND)));
    assert_eq!(object.remove("id"), Some(json!(REQUEST_ID)));
    object
}

#[test]
fn each_role_round_trips() {
    for role in [Some(VmKind::Owner), Some(VmKind::Team), None] {
        assert_eq!(parse(&fields(&line(role))), Some(role), "{role:?}");
    }
}

#[test]
fn anything_but_exactly_vmk_is_malformed() {
    for bad in [
        json!({}),
        json!({"vmk": "admin"}),
        json!({"vmk": 1}),
        json!({"vmk": "Owner"}),
        json!({"vmk": "owner", "extra": true}),
        json!({"role": "owner"}),
    ] {
        assert_eq!(parse(bad.as_object().unwrap()), None, "{bad}");
    }
}
