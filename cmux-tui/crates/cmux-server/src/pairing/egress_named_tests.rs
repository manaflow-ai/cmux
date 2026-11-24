use super::named_api_origin;

#[test]
fn a_named_api_origin_passes_the_gate_and_others_do_not() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    assert!(cmux_egress::check("server-pair-named-test.org", "test").is_err());
    let api = named_api_origin(Some("https://server-pair-named-test.org/")).unwrap();
    assert_eq!(api, "https://server-pair-named-test.org");
    assert!(cmux_egress::check("server-pair-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("unrelated-server-pair-test.org", "test").is_err());
    assert!(named_api_origin(Some("http://server-pair-plain-test.org/")).is_err());
    assert!(cmux_egress::check("server-pair-plain-test.org", "test").is_err());
}
