use super::*;

/// `cmux_exec` is always loaded, so its description is part of every turn's cached prefix:
/// an app action added or removed mid-chat (`action.catalog.changed` re-lists the tools) must
/// leave it byte for byte the same, or the next turn writes the whole prompt to the cache
/// again. A family that appears or goes away still shows.
#[test]
fn the_exec_description_does_not_move_when_a_family_gains_a_tool() {
    let before = descriptors(&[json!({"name": "app_new_tab"}), json!({"name": "pane_split"})]);
    let after = descriptors(&[
        json!({"name": "app_new_tab"}),
        json!({"name": "app_close_tab"}),
        json!({"name": "pane_split"}),
    ]);
    assert_eq!(before[0]["description"], after[0]["description"]);
    let text = before[0]["description"].as_str().unwrap();
    assert!(text.contains("Families: app, pane."), "{text}");
    let fewer = descriptors(&[json!({"name": "pane_split"})]);
    assert!(fewer[0]["description"].as_str().unwrap().contains("Families: pane."));
}
