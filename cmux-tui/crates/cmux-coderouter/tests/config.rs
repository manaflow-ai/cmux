use cmux_coderouter::RouterConfig;

#[test]
fn oauth_pooling_is_disabled_by_default() {
    let config = RouterConfig::default();
    assert!(!config.allow_oauth_pooling);
}

#[test]
fn oauth_pooling_config_uses_explicit_camel_case_key() {
    let config: RouterConfig = serde_json::from_str(r#"{}"#).unwrap();
    assert!(!config.allow_oauth_pooling);
    let enabled: RouterConfig = serde_json::from_str(r#"{"allowOAuthPooling":true}"#).unwrap();
    assert!(enabled.allow_oauth_pooling);
}
