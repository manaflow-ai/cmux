use super::*;

#[derive(serde::Deserialize, Debug)]
#[serde(deny_unknown_fields)]
#[allow(dead_code)]
struct Params {
    surface: u64,
    #[serde(default)]
    model: Option<String>,
}

fn field(params: Value) -> Option<String> {
    decode::<Params>(params.as_object().cloned().unwrap_or_default()).unwrap_err()
}

#[test]
fn serde_names_an_unknown_or_missing_field_and_never_a_value() {
    assert_eq!(field(json!({"surface": 1, "extra": "secret"})).as_deref(), Some("extra"));
    assert_eq!(field(json!({"model": "m"})).as_deref(), Some("surface"));
    assert_eq!(field(json!({"surface": 1, "model": 42})), None, "a wrong type quotes the value");
    assert_eq!(field(json!({"surface": 1, "a`b c": 1})), None, "not a param name");
}
