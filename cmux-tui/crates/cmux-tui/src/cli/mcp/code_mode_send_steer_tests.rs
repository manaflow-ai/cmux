use super::*;

/// A chat with acpmux's `send` folded in is told in `cmux_exec`'s description to message
/// other sessions with it, not the CLI in a shell; one without it is not.
#[test]
fn the_exec_description_names_the_send_tool_only_where_it_is() {
    let with = descriptors(&[json!({"name": SEND}), json!({"name": "acpmux_inbox_reply"})]);
    let text = with[0]["description"].as_str().unwrap();
    assert!(text.contains("cmux.acpmux_send({to, text})"), "{text}");
    assert!(text.contains("not `acpmux send` in a shell"), "{text}");
    assert!(text.contains("cmux.acpmux_inbox_reply({thread, text})"), "{text}");
    let without = descriptors(&[json!({"name": "pane_split"})]);
    assert!(!without[0]["description"].as_str().unwrap().contains("acpmux_send"));
}
