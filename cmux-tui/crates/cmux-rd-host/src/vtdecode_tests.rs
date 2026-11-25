#[test]
fn prewarm_creates_a_session_from_the_built_in_parameter_sets() {
    let first = super::prewarm().expect("prewarm session");
    let second = super::prewarm().expect("second prewarm session");
    eprintln!("prewarm first {first:?}, second {second:?}");
}
