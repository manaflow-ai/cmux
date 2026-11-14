use super::*;

/// A chat whose tools include acpmux's `bg_start` is told in `cmux_exec`'s own description
/// to run long commands there; one without it is not (acpmux docs/hibernation.md).
#[test]
fn the_exec_description_steers_long_commands_to_bg_start_only_where_it_is() {
    let with = descriptors(&[json!({"name": BG_START}), json!({"name": "pane_split"})]);
    let text = with[0]["description"].as_str().unwrap();
    assert!(text.contains("cmux.acpmux_bg_start({command, cwd})"), "{text}");
    assert!(text.contains("hibernates after 2 idle minutes"), "{text}");
    // The parallel-work rule is the first-turn context's (`CONCURRENT_WORK_RULE`), sent once
    // per chat; the tool description does not say it a second time.
    assert!(!text.contains("one batch of independent tool calls"), "{text}");
    let without = descriptors(&[json!({"name": "pane_split"})]);
    assert!(!without[0]["description"].as_str().unwrap().contains("acpmux_bg_start"));
}
