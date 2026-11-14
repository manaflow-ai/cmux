use super::*;
use std::fs;

pub(super) struct Home(pub(super) PathBuf);
impl Home {
    pub(super) fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "cmux-cloud-env-test-{}-{}",
            std::process::id(),
            next_revision()
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Home {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn table_has_distinct_preview_namespace() {
    let preview = Environment::Preview(42).configuration();
    assert_eq!(preview.name, "preview-42");
    assert!(preview.api_origin.contains("preview-42"));
    assert_eq!(preview.platform_origin, Environment::Dev.configuration().platform_origin);
    assert_eq!(preview.share_api_origin, DEVELOPMENT_API);
}

#[test]
fn launch_override_wins_without_overwriting_persisted_choice() {
    let home = Home::new();
    let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
    resolver.set(Environment::Staging).unwrap();
    assert_eq!(resolver.resolve(Some("prod")).unwrap().name, "prod");
    assert_eq!(resolver.resolve(None).unwrap().name, "staging");
}

#[test]
fn release_accepts_allowlisted_launch_override_and_keeps_legacy_default() {
    let home = Home::new();
    let resolver = Resolver::new("com.cmuxterm.app", &home.0).unwrap();
    let default = resolver.resolve(None).unwrap();
    assert_eq!(default.name, "prod");
    assert!(default.legacy_storage);
    assert_eq!(resolver.resolve(Some("dev")).unwrap().name, "dev");
    assert!(resolver.resolve(Some("https://untrusted.example")).is_err());
    assert!(resolver.set(Environment::Dev).is_err());
}

#[test]
fn real_switch_rotates_sign_in_namespace_but_same_selection_does_not() {
    let home = Home::new();
    let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
    let initial = resolver.resolve(None).unwrap();
    assert_eq!(initial.name, "dev");
    assert!(!initial.legacy_storage);
    assert_eq!(resolver.set(Environment::Dev).unwrap().auth_namespace, initial.auth_namespace);
    let staging = resolver.set(Environment::Staging).unwrap();
    assert!(!staging.legacy_storage);
    assert_ne!(staging.auth_namespace, initial.auth_namespace);
    assert_eq!(resolver.resolve(None).unwrap().auth_namespace, staging.auth_namespace);
    assert_ne!(resolver.set(Environment::Dev).unwrap().auth_namespace, initial.auth_namespace);
}

#[test]
fn invalid_persistence_fails_closed_and_bundle_cannot_traverse() {
    let home = Home::new();
    assert!(Resolver::new("../other", &home.0).is_err());
    let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
    resolver.resolve(None).unwrap();
    fs::write(resolver.state_path(), "{bad").unwrap();
    assert!(resolver.resolve(None).is_err());
    assert_eq!(resolver.resolve(Some("prod")).unwrap().name, "prod");
    assert_eq!(resolver.set(Environment::Prod).unwrap().name, "prod");
    assert_eq!(resolver.resolve(None).unwrap().name, "prod");
}

#[test]
fn an_update_from_a_build_before_runtime_selection_stays_signed_in() {
    // Shipped NEXT Nightly is `com.cmuxterm.app.nightly`; its session was in
    // `<bundle>.auth` before #35284 and must still be read there (2026-11-05).
    for bundle in
        ["com.cmuxterm.app", "com.cmuxterm.app.rc", "com.cmuxterm.app.nightly", NIGHTLY_BUNDLE]
    {
        let home = Home::new();
        let selected = Resolver::new(bundle, &home.0).unwrap().resolve(None).unwrap();
        assert_eq!(selected.configuration.name, "prod", "{bundle}");
        assert!(selected.legacy_storage, "{bundle}");
        assert_eq!(selected.auth_storage_namespace, None, "{bundle}");
    }
}

#[test]
fn safe_untouched_defaults_preserve_historical_storage_only() {
    let home = Home::new();
    for bundle in
        ["com.cmuxterm.app", "com.cmuxterm.app.rc", "com.cmuxterm.app.rc.test", NIGHTLY_BUNDLE]
    {
        let resolver = Resolver::new(bundle, &home.0).unwrap();
        let selected = resolver.resolve(None).unwrap();
        assert!(selected.legacy_storage, "{bundle}");
        assert_eq!(selected.auth_storage_namespace, None);
        let explicit = resolver.resolve(Some("prod")).unwrap();
        assert!(!explicit.legacy_storage);
        assert_eq!(explicit.auth_storage_namespace, Some(explicit.auth_namespace));
    }
    let resolver = Resolver::new("com.cmuxterm.app.debug.next", &home.0).unwrap();
    let selected = resolver.resolve(None).unwrap();
    assert!(selected.legacy_storage);
    assert_eq!(selected.auth_storage_namespace.as_deref(), Some(DEVELOPMENT_STACK_PROJECT));
    let switched = resolver.set(Environment::Staging).unwrap();
    assert!(!switched.legacy_storage);
    assert_eq!(switched.auth_storage_namespace, Some(switched.auth_namespace.clone()));
    let returned = resolver.set(Environment::Dev).unwrap();
    assert!(!returned.legacy_storage);
    assert_eq!(returned.auth_storage_namespace, Some(returned.auth_namespace.clone()));
    assert_ne!(returned.auth_storage_namespace, selected.auth_storage_namespace);
}

#[test]
fn unknown_debug_history_never_restores_unscoped_credentials() {
    let home = Home::new();
    for bundle in [DEV_BUNDLE, "com.cmuxterm.app.debug.tagged", "com.cmuxterm.app.debug.nextx"] {
        let selected = Resolver::new(bundle, &home.0).unwrap().resolve(None).unwrap();
        assert!(!selected.legacy_storage, "{bundle}");
        assert_eq!(selected.auth_storage_namespace, Some(selected.auth_namespace));
    }
}

#[test]
fn backend_origin_aliases_remain_within_the_declared_allowlist() {
    for (origin, expected) in [
        (PRODUCTION_API, Environment::Prod),
        (STAGING_API, Environment::Staging),
        (DEVELOPMENT_API, Environment::Dev),
        ("https://cmux-api-preview-123.debussy.workers.dev", Environment::Preview(123)),
    ] {
        assert_eq!(Environment::parse(origin).unwrap(), expected);
    }
    for origin in [
        "https://cloud-api.cmux.dev.attacker.example",
        "https://user@cloud-api.cmux.dev",
        "https://cloud-api.cmux.dev/extra",
        "https://cloud-api.cmux.dev?query=x",
        "http://cloud-api.cmux.dev",
        "https://cmux-api-preview-0.debussy.workers.dev",
    ] {
        assert!(Environment::parse(origin).is_err(), "{origin}");
    }
}

#[cfg(unix)]
#[test]
fn persistence_permissions_do_not_depend_on_umask() {
    use std::os::unix::fs::PermissionsExt;
    let home = Home::new();
    let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
    resolver.set(Environment::Staging).unwrap();
    assert_eq!(fs::metadata(resolver.state_path()).unwrap().permissions().mode() & 0o777, 0o600);
}
