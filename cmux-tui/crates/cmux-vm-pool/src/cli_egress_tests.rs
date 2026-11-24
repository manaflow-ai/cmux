use super::parse;

#[test]
fn a_named_load_url_passes_the_gate_and_others_do_not() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let words: Vec<String> =
        ["schedule", "--load-url", "https://pool-load-named-test.org/v1/pool/telemetry"]
            .map(str::to_owned)
            .to_vec();
    let args = parse(&words).unwrap();
    assert_eq!(
        args.load_url.as_deref(),
        Some("https://pool-load-named-test.org/v1/pool/telemetry")
    );
    assert!(cmux_egress::check("pool-load-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("unrelated-pool-load-test.org", "test").is_err());
}
