#[test]
fn only_the_daemons_pipe_names_are_accepted() {
    assert!(super::control_name("cmux-cu-ctl-0a1b"));
    assert!(!super::control_name("cmux-cu-ctl-"));
    assert!(!super::control_name("cmux-cu-ctl-..\\x"));
    assert!(!super::control_name("other"));
}
