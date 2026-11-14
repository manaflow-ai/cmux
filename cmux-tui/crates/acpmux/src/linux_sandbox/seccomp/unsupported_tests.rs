#[test]
fn unsupported_architecture_is_refused() {
    assert!(super::deny_filter().is_err());
}
