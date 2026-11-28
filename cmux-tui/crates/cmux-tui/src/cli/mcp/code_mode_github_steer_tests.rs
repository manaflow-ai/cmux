use super::*;

/// A chat with acpmux's `github_status` is told when to call it in `cmux_exec`'s own
/// description; one without it is not.
#[test]
fn the_exec_description_names_github_status_only_where_it_is() {
    let with = descriptors(&[json!({"name": GITHUB_STATUS})], false);
    let text = with[0]["description"].as_str().unwrap();
    assert!(text.contains("cmux.acpmux_github_status({})"), "{text}");
    let without = descriptors(&[json!({"name": "pane_split"})], false);
    assert!(!without[0]["description"].as_str().unwrap().contains("github_status"));
}

/// A chat with acpmux's `settings_ask` finds it named in `cmux_exec`'s description, the one
/// tool a code-mode chat lists (cmux ask c-073fa3e7ff: a NIGHTLY chat said it had no such tool).
#[test]
fn the_exec_description_names_settings_ask_only_where_it_is() {
    let with = descriptors(&[json!({"name": SETTINGS_ASK})], false);
    let text = with[0]["description"].as_str().unwrap();
    assert!(text.contains("cmux.acpmux_settings_ask({target, why})"), "{text}");
    let without = descriptors(&[json!({"name": "pane_split"})], false);
    assert!(!without[0]["description"].as_str().unwrap().contains("settings_ask"));
}
