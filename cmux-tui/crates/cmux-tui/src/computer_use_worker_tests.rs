#[test]
fn only_one_asks_the_worker_to_give_up_gaining_privileges() {
    assert!(super::wants_no_new_privs(Some("1")));
    assert!(super::wants_no_new_privs(Some(" 1\n")));
    for other in [None, Some(""), Some("0"), Some("true"), Some("yes")] {
        assert!(!super::wants_no_new_privs(other), "{other:?}");
    }
}

#[test]
fn only_the_daemons_pipe_names_are_accepted() {
    assert!(super::control_name("cmux-cu-ctl-0a1b"));
    assert!(!super::control_name("cmux-cu-ctl-"));
    assert!(!super::control_name("cmux-cu-ctl-..\\x"));
    assert!(!super::control_name("other"));
}
