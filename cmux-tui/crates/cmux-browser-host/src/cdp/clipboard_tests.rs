use super::*;

#[test]
fn only_meta_c_x_v_key_downs_are_shortcuts() {
    let key = |kind: &str, key: &str, code: &str, mods: Value| json!({"type": kind, "key": key, "code": code, "modifiers": mods});
    assert_eq!(shortcut("input.key", &key("down", "c", "KeyC", json!(["Meta"]))), Some("copy"));
    assert_eq!(shortcut("input.key", &key("down", "X", "", json!(["Meta", "Shift"]))), Some("cut"));
    assert_eq!(shortcut("input.key", &key("down", "v", "KeyV", json!(["Meta"]))), Some("paste"));
    assert_eq!(shortcut("input.key", &key("up", "c", "KeyC", json!(["Meta"]))), None);
    assert_eq!(shortcut("input.key", &key("down", "c", "KeyC", json!(["Control"]))), None);
    assert_eq!(shortcut("input.mouse", &key("down", "c", "KeyC", json!(["Meta"]))), None);
}

#[test]
fn clipboard_items_need_a_type_and_data() {
    assert!(clipboard_items(Some(&json!([{"type": "text/plain", "base64": "YQ=="}]))).is_ok());
    assert!(clipboard_items(Some(&json!([{"type": "text/plain"}]))).is_err());
    assert!(clipboard_items(None).is_err());
}
