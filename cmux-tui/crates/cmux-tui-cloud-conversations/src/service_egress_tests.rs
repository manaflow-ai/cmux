use super::*;

#[test]
fn named_api_origins_pass_the_gate_and_others_do_not() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let origins = named_api_origins(
        " https://cloud-api-one-named-test.org , ,https://cloud-api-two-named-test.org",
    );
    assert_eq!(
        origins,
        ["https://cloud-api-one-named-test.org", "https://cloud-api-two-named-test.org"]
    );
    assert!(cmux_egress::check("cloud-api-one-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("cloud-api-two-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("unrelated-cloud-api-test.org", "test").is_err());
}
