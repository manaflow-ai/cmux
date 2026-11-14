use super::*;

#[test]
fn the_marker_names_a_command_without_its_control_characters() {
    assert_eq!(marker(None), ENGLISH.restored);
    assert_eq!(
        marker(Some(Ran::Command("ca\u{1b}t -n"))),
        "\u{2014} session restored (previous process ended; it ran cat -n) \u{2014}"
    );
    assert_eq!(marker(Some(Ran::Command("\u{7}"))), ENGLISH.restored);
    assert_eq!(
        marker(Some(Ran::Agent("claude --resume a1"))),
        "\u{2014} session restored; resume with claude --resume a1 \u{2014}"
    );
    let long = marker(Some(Ran::Command(&"x".repeat(500))));
    assert!(long.contains(&format!("{}\u{2026}", "x".repeat(MARKER_COMMAND_CHARS - 1))));
}

#[test]
fn the_marker_names_a_freed_shells_last_command_and_exit() {
    assert_eq!(
        marker(Some(Ran::Last { command: "npm\u{1b} test", exit_code: Some(1) })),
        "\u{2014} session restored \u{b7} last: npm test \u{b7} exit 1 \u{2014}"
    );
    assert_eq!(
        marker(Some(Ran::Last { command: "make", exit_code: None })),
        "\u{2014} session restored \u{b7} last: make \u{2014}"
    );
    assert_eq!(marker(Some(Ran::Last { command: "\u{7}", exit_code: Some(0) })), ENGLISH.restored);
}

#[test]
fn the_stopped_marker_names_the_program_without_control_characters() {
    assert_eq!(
        stopped_marker("sle\u{1b}ep"),
        "\u{2014} sleep was stopped when this tab closed \u{2014}"
    );
}
