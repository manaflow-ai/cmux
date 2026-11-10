use super::*;

#[test]
fn the_params_never_print_a_token() {
    let params: SpareWarmParams = serde_json::from_value(serde_json::json!({
        "platform": "https://platform.example", "api": "https://api.example",
        "access_token": "stack.secret", "install_token": "install.secret", "account": "user_a",
        "claimed": "vm_0123456789abcdefghij", "team": "team_b", "login_teams": ["team_a", "team_b"], "dogfood": true,
    }))
    .unwrap();
    let printed = format!("{params:?}");
    assert!(!printed.contains("secret"), "{printed}");
    // The selected team first, the other teams, then personal; never twice.
    let scopes = params.login_scopes();
    assert_eq!(scopes, vec![Some("team_b".to_owned()), Some("team_a".to_owned()), None]);
    let personal = SpareWarmParams { team: None, ..params };
    assert_eq!(personal.login_scopes(), vec![None, Some("team_a".into()), Some("team_b".into())]);
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

fn leased(sub: &str) -> CloudConversations {
    use crate::cloud_conversations::testing::FakeBackend;
    let service = CloudConversations::new(Arc::new(FakeBackend::default()));
    lease(&service, sub);
    service
}

#[test]
fn a_consent_change_ends_the_copies_begun_before_it_and_is_read_at_the_write() {
    let control = Arc::new(SpareWarmControl::default());
    let service = leased("user_a");
    let guard =
        LiveGuard::new(Some(service.clone()), control.clone(), &params_for("user_a", Some(true)));
    assert!(guard.still("user_a"));
    assert!(!guard.still("user_b"), "another account's copy");
    assert_eq!(guard.consent(), Some(true), "no push yet: the warm's own consent");
    assert!(control.set_consent(1, 1, Some(true)));
    assert!(guard.still("user_a"), "the first push is no change");
    assert!(control.set_consent(1, 2, Some(true)));
    assert!(guard.still("user_a"), "the same value again is no change");
    assert!(control.set_consent(1, 3, None));
    assert_eq!(guard.consent(), None, "the write reads the latest consent");
    assert!(!guard.still("user_a"), "a changed consent ends the copy");
    let later = LiveGuard::new(Some(service), control, &params_for("user_a", Some(true)));
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
fn a_sign_out_ends_the_copy_and_no_lease_fails_closed() {
    use crate::cloud_conversations::testing::FakeBackend;
    let service = CloudConversations::new(Arc::new(FakeBackend::default()));
    let control = Arc::new(SpareWarmControl::default());
    // No lease is no person: a warm that reached the daemon after a sign-out (the guard is
    // built then, with the cleared lease's epoch) copies nothing.
    let unleased =
        LiveGuard::new(Some(service.clone()), control.clone(), &params_for("user_a", None));
    assert!(!unleased.still("user_a"));
    lease(&service, "user_a");
    service.clear_session();
    let after_sign_out =
        LiveGuard::new(Some(service.clone()), control.clone(), &params_for("user_a", None));
    assert!(!after_sign_out.still("user_a"), "an older warm after cloud-session-clear");
    assert!(
        !LiveGuard::new(None, control.clone(), &params_for("user_a", None)).still("user_a"),
        "no conversations service: no person"
    );
    lease(&service, "user_a");
    let leased =
        LiveGuard::new(Some(service.clone()), control.clone(), &params_for("user_a", None));
    lease(&service, "user_a");
    assert!(leased.still("user_a"), "a renewal");
    service.clear_session();
    assert!(!leased.still("user_a"), "a lease cleared since ends the copy");
    lease(&service, "user_a");
    assert!(!leased.still("user_a"), "signing in again does not revive it");
    let switched = LiveGuard::new(Some(service.clone()), control, &params_for("user_a", None));
    lease(&service, "user_b");
    assert!(!switched.still("user_a"), "another account's lease");
}

#[test]
fn a_stale_consent_read_never_overwrites_a_later_one() {
    let control = Arc::new(SpareWarmControl::default());
    let guard = LiveGuard::new(Some(leased("user_a")), control.clone(), &params_for("user_a", Some(true)));
    // A warm read yes (generation 4), then awaited its tokens; meanwhile the person turned copying
    // off and the follower sent that read (generation 5) first.
    assert!(control.set_consent(7, 5, Some(false)));
    assert!(!control.set_consent(7, 4, Some(true)), "the warm's older read is dropped");
    assert_eq!(guard.consent(), Some(false));
    assert!(!control.set_consent(7, 5, Some(true)), "the same generation again is no newer");
    // A new connection (the app restarted or reconnected) numbers its reads from scratch.
    assert!(control.set_consent(8, 1, Some(true)));
    assert_eq!(guard.consent(), Some(true));
}

#[test]
fn a_consent_send_carries_its_generation() {
    let parsed: ConsentParams =
        serde_json::from_value(serde_json::json!({"consent": false, "generation": 3})).unwrap();
    assert_eq!((parsed.consent, parsed.generation), (Some(false), 3));
    assert!(serde_json::from_value::<ConsentParams>(serde_json::json!({"consent": true})).is_err());
}
