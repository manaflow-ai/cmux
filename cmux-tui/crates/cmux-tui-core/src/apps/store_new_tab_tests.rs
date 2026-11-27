use serde_json::json;

/// The store offers Use as New Tab only for an app whose manifest implements `cmux.newtab/1`.
#[test]
fn only_a_newtab_implementation_draws_new_tab() {
    let drawn = json!({ "implements": { "cmux.newtab/1": { "export": "renderNewTab" } } });
    assert!(super::draws_new_tab(&drawn));
    let other = json!({ "implements": { "cmux.section/1": { "export": "render" } } });
    assert!(!super::draws_new_tab(&other));
    assert!(!super::draws_new_tab(&json!({})));
}
