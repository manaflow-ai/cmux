use super::is_refusal;

#[test]
fn connection_limit_refusal_requires_the_cmux_protocol() {
    assert!(is_refusal(br#"{"protocol":"cmux.protocol/2","type":"refused","code":"server.busy"}"#));
    for other_service in [
        br#"{"type":"refused","code":"server.busy"}"#.as_slice(),
        br#"{"protocol":"another.protocol/2","type":"refused","code":"server.busy"}"#,
    ] {
        assert!(!is_refusal(other_service), "an unrelated service must not be replaced");
    }
}
