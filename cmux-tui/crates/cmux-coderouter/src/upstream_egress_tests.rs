use super::*;

#[test]
fn a_named_upstream_passes_the_gate_and_others_do_not() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let origin = "https://coderouter-upstream-named-test.org";
    assert!(Upstream::new(origin, "bearer".into(), 0).is_ok());
    // A refused origin is not let through.
    assert!(Upstream::new("http://coderouter-plain-named-test.org", "bearer".into(), 0).is_err());
    assert!(cmux_egress::check("coderouter-upstream-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("coderouter-plain-named-test.org", "test").is_err());
    assert!(cmux_egress::check("unrelated-coderouter-upstream-test.org", "test").is_err());
}
