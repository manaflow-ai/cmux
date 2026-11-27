use super::*;

fn args(value: Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

#[test]
fn hours_defaults_and_bounds() {
    assert_eq!(hours(&args(json!({}))), Ok(24));
    assert_eq!(hours(&args(json!({"hours": 3}))), Ok(3));
    assert!(hours(&args(json!({"hours": 0}))).is_err());
    assert!(hours(&args(json!({"hours": "3"}))).is_err());
    assert_eq!(hours(&args(json!({"days": 1}))), Ok(24));
}

#[test]
fn other_tools_are_not_this_one() {
    assert!(call("video_info", &Map::new()).is_none());
    assert_eq!(descriptor()["name"], NAME);
    assert_eq!(descriptor()["annotations"]["readOnlyHint"], true);
}
