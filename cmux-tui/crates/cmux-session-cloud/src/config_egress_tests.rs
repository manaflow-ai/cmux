use super::*;

#[test]
fn a_named_store_passes_the_gate_and_others_do_not() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let state = tempfile::tempdir().unwrap();
    let credential = state.path().join("credential");
    std::fs::write(&credential, "token\n").unwrap();
    let config = Config {
        store: "https://session-cloud-store-named-test.org".to_owned(),
        credential_file: Some(credential),
        key_file: None,
        root_prefix: None,
        state: state.path().to_path_buf(),
    };
    assert!(config.open_store().is_ok());
    assert!(cmux_egress::check("session-cloud-store-named-test.org", "test").is_ok());
    assert!(cmux_egress::check("unrelated-session-cloud-test.org", "test").is_err());
}
