use super::*;

#[test]
fn the_params_never_print_a_token() {
    let params: SpareWarmParams = serde_json::from_value(serde_json::json!({
        "platform": "https://platform.example", "api": "https://api.example",
        "access_token": "stack.secret", "install_token": "install.secret", "account": "user_a",
        "claimed": "vm_0123456789abcdefghij", "login_scopes": ["team_a", null], "dogfood": true,
    }))
    .unwrap();
    let printed = format!("{params:?}");
    assert!(!printed.contains("secret"), "{printed}");
    assert_eq!(params.login_scopes, vec![Some("team_a".to_owned()), None]);
}

#[test]
fn an_unknown_field_is_refused() {
    let parsed = serde_json::from_value::<SpareWarmParams>(serde_json::json!({
        "platform": "p", "api": "a", "access_token": "t", "install_token": "i", "account": "user_a",
        "credential": "elsewhere",
    }));
    assert!(parsed.is_err());
}

fn params_for(account: &str, consent: Option<bool>) -> SpareWarmParams {
    SpareWarmParams { account: account.into(), consent, ..SpareWarmParams::default() }
}

#[test]
fn a_consent_change_ends_the_copies_begun_before_it_and_is_read_at_the_write() {
    let control = Arc::new(SpareWarmControl::default());
    let guard = LiveGuard::new(None, control.clone(), &params_for("user_a", Some(true)));
    assert!(guard.still("user_a"));
    assert!(!guard.still("user_b"), "another account's copy");
    assert_eq!(guard.consent(), Some(true), "no push yet: the warm's own consent");
    control.set_consent(Some(true));
    assert!(guard.still("user_a"), "the first push is no change");
    control.set_consent(Some(true));
    assert!(guard.still("user_a"), "the same value again is no change");
    control.set_consent(None);
    assert_eq!(guard.consent(), None, "the write reads the latest consent");
    assert!(!guard.still("user_a"), "a changed consent ends the copy");
    let later = LiveGuard::new(None, control, &params_for("user_a", Some(true)));
    assert!(later.still("user_a"), "a copy begun after the change goes on");
    assert_eq!(later.consent(), None, "the app's latest beats the warm's snapshot");
}

fn lease(service: &CloudConversations, sub: &str) {
    use base64::Engine as _;
    let claims = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(serde_json::json!({"sub": sub, "aud": "project"}).to_string());
    let params = serde_json::from_value(serde_json::json!({
        "api_base_url": "https://api.cmux.test", "access_token": format!("e30.{claims}.sig"),
        "expires_at": 4_102_444_800_000_u64
    }))
    .unwrap();
    service.set_session(params).unwrap();
}

#[test]
fn a_sign_out_ends_the_copy_but_a_daemon_never_leased_keeps_it() {
    use crate::cloud_conversations::testing::FakeBackend;
    let service = CloudConversations::new(Arc::new(FakeBackend::default()));
    let control = Arc::new(SpareWarmControl::default());
    // Never leased: the app's own account goes on.
    let never = LiveGuard::new(Some(service.clone()), control.clone(), &params_for("user_a", None));
    assert!(never.still("user_a"));
    lease(&service, "user_a");
    assert!(never.still("user_a"), "the same person's first lease");
    let leased =
        LiveGuard::new(Some(service.clone()), control.clone(), &params_for("user_a", None));
    lease(&service, "user_a");
    assert!(leased.still("user_a"), "a renewal");
    service.clear_session();
    assert!(!leased.still("user_a"), "a lease cleared since is no lease never had");
    assert!(!never.still("user_a"), "the sign-out ends every copy in flight");
    lease(&service, "user_a");
    assert!(!leased.still("user_a"), "signing in again does not revive it");
    let switched = LiveGuard::new(Some(service.clone()), control, &params_for("user_a", None));
    lease(&service, "user_b");
    assert!(!switched.still("user_a"), "another account's lease");
}
