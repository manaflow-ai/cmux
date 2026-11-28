#[test]
fn extra_arguments_are_refused_before_any_desktop_opens() {
    assert_eq!(super::run(&["--control".into(), "x".into()]), 2);
}
