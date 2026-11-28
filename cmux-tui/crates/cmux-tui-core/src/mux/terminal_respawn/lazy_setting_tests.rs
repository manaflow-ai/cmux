use super::lazy_start_setting;

#[test]
fn lazy_start_is_on_unless_turned_off() {
    for on in [None, Some(""), Some("1"), Some("on"), Some("true"), Some("yes")] {
        assert!(lazy_start_setting(on), "{on:?} should leave lazy start on");
    }
    for off in [Some("0"), Some("off"), Some(" OFF "), Some("false"), Some("no")] {
        assert!(!lazy_start_setting(off), "{off:?} should turn lazy start off");
    }
}
