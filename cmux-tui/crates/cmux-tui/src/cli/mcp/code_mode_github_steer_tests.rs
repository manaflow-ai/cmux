use super::*;

/// A chat with acpmux's `github_status` is told when to call it in `cmux_exec`'s own
/// description; one without it is not.
#[test]
fn the_exec_description_names_github_status_only_where_it_is() {
    let with = descriptors(&[json!({"name": GITHUB_STATUS})]);
    let text = with[0]["description"].as_str().unwrap();
    assert!(text.contains("cmux.acpmux_github_status({})"), "{text}");
    let without = descriptors(&[json!({"name": "pane_split"})]);
    assert!(!without[0]["description"].as_str().unwrap().contains("github_status"));
}
