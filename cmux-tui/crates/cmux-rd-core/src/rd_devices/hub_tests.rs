use super::*;

fn t(url: &str, user: &str) -> Option<Target> {
    Some(Target { url: url.into(), user: user.into() })
}

fn signed_in() -> ReconcileInputs {
    ReconcileInputs {
        url: Some("https://hub".into()),
        user: Some("u1".into()),
        ..Default::default()
    }
}

#[test]
fn the_hub_starts_once_per_address_and_user() {
    assert_eq!(
        reconcile(&signed_in()),
        Reconcile::Restart { url: "https://hub".into(), user: "u1".into() }
    );
    let running = ReconcileInputs { running: t("https://hub", "u1"), ..signed_in() };
    assert_eq!(reconcile(&running), Reconcile::Keep);
    let loading = ReconcileInputs { loading_for: t("https://hub", "u1"), ..signed_in() };
    assert_eq!(reconcile(&loading), Reconcile::Keep);
    let other_user = ReconcileInputs { running: t("https://hub", "u2"), ..signed_in() };
    assert!(matches!(reconcile(&other_user), Reconcile::Restart { .. }));
}

#[test]
fn signed_out_no_address_or_left_stops_and_cleanup_holds() {
    let out = ReconcileInputs { user: None, ..signed_in() };
    assert_eq!(
        reconcile(&out),
        Reconcile::Stop { address_set: true, signed_in: false, left_hub: false }
    );
    let left = ReconcileInputs { left_hub: true, running: t("https://hub", "u1"), ..signed_in() };
    assert_eq!(
        reconcile(&left),
        Reconcile::Stop { address_set: true, signed_in: true, left_hub: true }
    );
    let none = ReconcileInputs { url: None, ..signed_in() };
    assert!(matches!(reconcile(&none), Reconcile::Stop { address_set: false, .. }));
    let held = ReconcileInputs { capture_cleanup_active: true, url: None, ..signed_in() };
    assert_eq!(reconcile(&held), Reconcile::Keep);
}

#[test]
fn startup_errors_have_stable_codes() {
    assert_eq!(
        startup_error_code(&StartupError::Keychain { status: -25300 }),
        "device_identity_keychain_-25300"
    );
    assert_eq!(startup_error_code(&StartupError::Other), "device_identity_unavailable");
    assert_eq!(
        startup_error_code(&StartupError::ConfigurationTimeout),
        "device_hub_configuration_timeout"
    );
}

#[test]
fn the_bundle_and_build_space() {
    assert_eq!(hub_bundle(Some("com.x"), Some("pr-12"), Some("app")), "com.x.cloud.pr-12");
    assert_eq!(hub_bundle(None, Some("pr-12"), None), "cmux.cloud.pr-12");
    assert_eq!(hub_bundle(None, None, Some("")), DEFAULT_BUNDLE);
    assert_eq!(hub_bundle(None, None, Some("com.example.app")), "com.example.app");
    // DeviceHubBuildSpaceTests: a DEV build with no usable tag sends nothing; NIGHTLY names none.
    assert_eq!(BuildSpace::of(true, Some("dev:tag-a")), BuildSpace::Unusable);
    assert_eq!(BuildSpace::of(false, None), BuildSpace::Nightly);
    assert_eq!(
        BuildSpace::of(false, Some("dev:tag-a")),
        BuildSpace::Dev { header: "dev:tag-a".into() }
    );
    assert!(BuildSpace::Nightly.allows_remote_hub() && !BuildSpace::Unusable.allows_remote_hub());
    assert_eq!(user_id(true, None), Some(String::new()));
    assert_eq!(user_id(false, Some("u")), None);
}
