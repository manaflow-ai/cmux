use super::on;

#[test]
fn the_fence_is_on_unless_the_kill_switch_says_off() {
    for value in [None, Some(""), Some("1"), Some("on"), Some("junk")] {
        assert!(on(value), "{value:?}");
    }
    for value in ["0", "false", "off", "no", " 0 "] {
        assert!(!on(Some(value)), "{value}");
    }
}
