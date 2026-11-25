use super::*;

#[test]
fn pressed_button_prefers_left() {
    assert_eq!(pressed_button(0), "none");
    assert_eq!(pressed_button(6), "right");
    assert_eq!(pressed_button(7), "left");
}

#[test]
fn editing_commands_follow_mac_shortcuts() {
    assert_eq!(editing_commands("KeyA", 4), vec!["selectAll"]);
    assert_eq!(editing_commands("KeyZ", 12), vec!["redo"]);
    assert_eq!(editing_commands("ArrowLeft", 9), vec!["moveWordLeftAndModifySelection"]);
    assert!(editing_commands("KeyA", 0).is_empty());
    assert!(editing_commands("KeyA", 6).is_empty(), "Control+Meta+A is not select all");
    assert_eq!(editing_commands("KeyB", 4), vec!["bold"]);
    assert!(editing_commands("KeyB", 2).is_empty(), "Control+B stays the platform's own");
}
