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

fn classic(home: &Home, bundle: &str) -> PathBuf {
    classic_bundle_folder(&home.0, bundle)
}

#[test]
fn state_moves_out_of_classics_folder_once_and_classics_sign_in_stays() {
    let home = Home::new();
    let old = classic(&home, SHIPPED_NIGHTLY_BUNDLE);
    fs::create_dir_all(old.join("client-config")).unwrap();
    fs::write(old.join(STATE_FILE), r#"{"name":"staging","revision":7,"explicit":true}"#).unwrap();
    fs::write(old.join("client-config/origin.json"), "{}").unwrap();
    // Classic NIGHTLY shares the bundle id and keeps its file-fallback sign-in here.
    fs::write(old.join("credentials.json"), "classic").unwrap();

    let resolver = Resolver::new(SHIPPED_NIGHTLY_BUNDLE, &home.0).unwrap();
    let next = bundle_folder(&home.0, SHIPPED_NIGHTLY_BUNDLE);
    assert_eq!(resolver.state_path(), next.join(STATE_FILE));
    assert!(fs::symlink_metadata(next.join(STATE_FILE)).unwrap().is_file());
    assert_eq!(fs::read_to_string(next.join("client-config/origin.json")).unwrap(), "{}");
    // An older daemon still reads the old paths, through the links left there.
    assert!(fs::symlink_metadata(old.join(STATE_FILE)).unwrap().file_type().is_symlink());
    assert!(fs::read_to_string(old.join(STATE_FILE)).unwrap().contains("staging"));
    assert_eq!(fs::read_to_string(old.join("client-config/origin.json")).unwrap(), "{}");
    assert_eq!(fs::read_to_string(old.join("credentials.json")).unwrap(), "classic");
    assert!(!next.join("credentials.json").exists());

    // Once: the links are not moved again, and a later resolver reads the same state.
    Resolver::new(SHIPPED_NIGHTLY_BUNDLE, &home.0).unwrap();
    assert!(fs::symlink_metadata(next.join(STATE_FILE)).unwrap().is_file());
}

#[test]
fn state_already_in_use_in_the_new_place_is_never_replaced() {
    let home = Home::new();
    let old = classic(&home, DEV_BUNDLE);
    let next = bundle_folder(&home.0, DEV_BUNDLE);
    fs::create_dir_all(&old).unwrap();
    fs::create_dir_all(next.join("client-config")).unwrap();
    fs::write(old.join(STATE_FILE), r#"{"name":"staging","revision":7,"explicit":true}"#).unwrap();
    fs::write(next.join(STATE_FILE), r#"{"name":"dev","revision":0,"explicit":false}"#).unwrap();
    fs::create_dir_all(old.join("client-config")).unwrap();
    fs::write(old.join("client-config/a.json"), "old").unwrap();
    fs::write(next.join("client-config/b.json"), "new").unwrap();

    let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
    assert_eq!(resolver.resolve(None).unwrap().name, "dev");
    assert!(fs::symlink_metadata(old.join(STATE_FILE)).unwrap().is_file());
    assert_eq!(fs::read_to_string(old.join("client-config/a.json")).unwrap(), "old");
    assert!(!next.join("client-config/a.json").exists());
}

#[test]
fn a_fresh_home_writes_nothing_in_classics_folder() {
    let home = Home::new();
    let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
    resolver.resolve(None).unwrap();
    assert!(resolver.state_path().is_file());
    assert!(!classic_bundle_folder(&home.0, DEV_BUNDLE).exists());
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

const TAILNET: &str = "https://cmux-dev-backend-1.tail137216.ts.net:3850";
const PUBLIC_STACK: &str = "https://api.s7.wdev.cmux.dev";

/// The tag hand-off's file (`backend.json` in the bundle's folder), as review.sh writes it.
fn write_tag_backend(home: &Home, bundle: &str, body: &str) {
    let folder = bundle_folder(&home.0, bundle);
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("backend.json"), body).unwrap();
}

fn override_source(selection: &Selection) -> serde_json::Value {
    serde_json::to_value(selection).unwrap()["backend_override"].clone()
}

#[test]
fn a_dev_builds_tag_file_sits_below_the_launch_override_and_above_the_picker() {
    let home = Home::new();
    let bundle = "com.cmuxterm.app.debug.cnx-tag";
    let resolver = Resolver::new(bundle, &home.0).unwrap();
    // No file: the picker's choice (default dev), no override named.
    let default = resolver.resolve(None).unwrap();
    assert_eq!(default.name, "dev");
    assert_eq!(override_source(&default), serde_json::Value::Null);
    resolver.set(Environment::Staging).unwrap();
    write_tag_backend(&home, bundle, &format!(r#"{{"backend":"{TAILNET}","tag":"cnx-tag"}}"#));
    // The tag file beats the persisted picker choice...
    let tagged = resolver.resolve(None).unwrap();
    assert_eq!(tagged.api_origin, TAILNET);
    assert_eq!(tagged.name, TAILNET);
    assert_eq!(override_source(&tagged), "tag_file");
    // ...its sign-in is its own, never the picker's or a legacy default's...
    assert!(!tagged.legacy_storage);
    assert_eq!(tagged.auth_storage_namespace.as_deref(), Some(tagged.auth_namespace.as_str()));
    // ...its other services are the shared development deployment's.
    assert_eq!(tagged.platform_origin, DEVELOPMENT_PLATFORM);
    assert_eq!(tagged.stack_project_id, DEVELOPMENT_STACK_PROJECT);
    // The launch's own override beats the file.
    let launched = resolver.resolve(Some("prod")).unwrap();
    assert_eq!(launched.name, "prod");
    assert_eq!(override_source(&launched), "launch");
    // The file never rewrites the picker's choice: removing it restores staging.
    fs::remove_file(bundle_folder(&home.0, bundle).join("backend.json")).unwrap();
    assert_eq!(resolver.resolve(None).unwrap().name, "staging");
    // A file naming the shared dev deployment selects it.
    write_tag_backend(&home, bundle, r#"{"backend":"dev"}"#);
    assert_eq!(resolver.resolve(None).unwrap().name, "dev");
    // An empty value is no override.
    write_tag_backend(&home, bundle, r#"{"backend":""}"#);
    assert_eq!(resolver.resolve(None).unwrap().name, "staging");
}

#[test]
fn a_tag_file_naming_anything_else_fails_closed() {
    let home = Home::new();
    let bundle = "com.cmuxterm.app.debug.cnx-tag";
    let resolver = Resolver::new(bundle, &home.0).unwrap();
    for body in [
        r#"{"backend":"https://attacker.example"}"#,
        r#"{"backend":"http://cmux-dev-backend-1.tail137216.ts.net:3850"}"#,
        r#"{"backend":"https://ts.net"}"#,
        r#"{"backend":"https://cmux-dev-backend-1.tail137216.ts.net.attacker.example"}"#,
        r#"{"backend":"https://cmux-dev-backend-1.tail137216.ts.net/path"}"#,
        r#"{"backend":"https://user@cmux-dev-backend-1.tail137216.ts.net"}"#,
        r#"{"backend":"https://100.70.231.80"}"#,
        r#"{"backend":7}"#,
        "{bad",
    ] {
        write_tag_backend(&home, bundle, body);
        assert!(resolver.resolve(None).is_err(), "{body}");
    }
}

#[test]
fn release_rc_and_nightly_ignore_the_tag_file_and_refuse_a_tailnet_backend() {
    for bundle in [
        "com.cmuxterm.app",
        "com.cmuxterm.app.rc",
        "com.cmuxterm.app.rc.test",
        SHIPPED_NIGHTLY_BUNDLE,
        NIGHTLY_BUNDLE,
    ] {
        let home = Home::new();
        write_tag_backend(&home, bundle, &format!(r#"{{"backend":"{TAILNET}"}}"#));
        let resolver = Resolver::new(bundle, &home.0).unwrap();
        let selected = resolver.resolve(None).unwrap();
        assert_eq!(selected.name, "prod", "{bundle}");
        assert_eq!(override_source(&selected), serde_json::Value::Null, "{bundle}");
        assert!(resolver.resolve(Some(TAILNET)).is_err(), "{bundle}");
        assert!(resolver.resolve(Some(PUBLIC_STACK)).is_err(), "{bundle}");
    }
    // A dev bundle takes a tag stack's public origin, as its tailnet one.
    let home = Home::new();
    let dev = Resolver::new("com.cmuxterm.app.debug.cnx-tag", &home.0).unwrap();
    assert_eq!(dev.resolve(Some(PUBLIC_STACK)).unwrap().api_origin, PUBLIC_STACK);
    // NIGHTLY's picker cannot persist one either.
    let home = Home::new();
    let nightly = Resolver::new(NIGHTLY_BUNDLE, &home.0).unwrap();
    let tailnet = Environment::parse(TAILNET).unwrap();
    assert!(nightly.set(tailnet).is_err());
}

#[test]
fn nightly_refuses_a_tailnet_backend_written_into_its_state_file() {
    // The picker's set() refuses it, but the state file is a plain file: a
    // hand-written or stale one must not move NIGHTLY to a tailnet backend.
    let home = Home::new();
    let nightly = Resolver::new(NIGHTLY_BUNDLE, &home.0).unwrap();
    let state = nightly.state_path();
    std::fs::create_dir_all(state.parent().unwrap()).unwrap();
    for body in [
        format!(r#"{{"name":"{TAILNET}","revision":3,"explicit":true}}"#),
        format!(r#"{{"name":"{TAILNET}"}}"#),
    ] {
        std::fs::write(&state, &body).unwrap();
        assert!(nightly.resolve(None).is_err(), "{body}");
        assert!(nightly.resolve_persisted().is_err(), "{body}");
    }
    // A dev build may keep one there.
    let dev = Resolver::new("com.cmuxterm.app.debug.cnx-tag", &home.0).unwrap();
    let state = dev.state_path();
    std::fs::create_dir_all(state.parent().unwrap()).unwrap();
    std::fs::write(&state, format!(r#"{{"name":"{TAILNET}","revision":3,"explicit":true}}"#))
        .unwrap();
    assert_eq!(dev.resolve(None).unwrap().name, TAILNET);
}

#[test]
fn the_persisted_read_never_takes_the_tag_file() {
    let home = Home::new();
    let bundle = "com.cmuxterm.app.debug.cnx-tag";
    let resolver = Resolver::new(bundle, &home.0).unwrap();
    resolver.set(Environment::Staging).unwrap();
    write_tag_backend(&home, bundle, &format!(r#"{{"backend":"{TAILNET}"}}"#));
    assert_eq!(resolver.resolve_persisted().unwrap().name, "staging");
    assert_eq!(resolver.resolve(None).unwrap().name, TAILNET);
}

#[test]
fn tailnet_origins_are_https_machine_names_only() {
    for origin in [
        TAILNET,
        "https://cmux-dev-backend-1.tail137216.ts.net",
        "https://cmux-dev-backend-1.tail137216.ts.net/",
    ] {
        let parsed = Environment::parse(origin).unwrap();
        assert_eq!(parsed.configuration().api_origin, origin.trim_end_matches('/'), "{origin}");
    }
    for origin in [
        "http://cmux-dev-backend-1.tail137216.ts.net:3850",
        "https://ts.net",
        "https://tail137216.ts.net",
        "https://cmux-dev-backend-1.tail137216.ts.net.attacker.example",
        "https://cmux-dev-backend-1.tail137216.ts.net/v1",
        "https://cmux-dev-backend-1.tail137216.ts.net?x=1",
        "https://user@cmux-dev-backend-1.tail137216.ts.net",
        "https://cmux_dev.tail137216.ts.net",
        // Another tailnet's machine (a Funnel name is public) or a name under ours that is no machine.
        "https://cmux-dev-backend-1.tail9999.ts.net:3850",
        "https://evil.ts.net",
        "https://a.b.tail137216.ts.net",
        "https://.tail137216.ts.net",
        // Under cmux.dev but no tag stack's API host.
        "https://mobile.s7.wdev.cmux.dev",
        "https://api.s7.wdev.cmux.dev:8443",
        "https://api.s7.other.cmux.dev",
        "https://cmux.dev",
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

fn words(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

/// CMUX-571: the app's launch read runs in its own process ([`Resolver::launch_read`]).
/// A known deployment answers with no fetch, persisted like `cloud env get`.
#[test]
fn the_launch_read_answers_a_known_deployment_with_no_fetch() {
    let home = Home::new();
    let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
    let read = resolver.launch_read(None).unwrap().expect("a known deployment needs no fetch");
    assert_eq!(read.name, "dev");
    assert_eq!(read.config_source, ConfigSource::KnownOriginFallback);
    assert_eq!(read.bundle_id, DEV_BUNDLE);
    assert!(resolver.state_path().is_file(), "the first launch's default is persisted");
    let seeded = resolver.launch_read(Some("staging")).unwrap().unwrap();
    assert_eq!(seeded.name, "staging");
    assert!(!seeded.legacy_storage, "an override never adopts the default's credentials");
}

/// A custom origin with no cache is left to the CLI's fetch; a refused seed is an error.
#[test]
fn the_launch_read_leaves_a_custom_origin_with_no_cache_to_the_fetch() {
    let home = Home::new();
    let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
    assert_eq!(resolver.launch_read(Some("http://127.0.0.1:9")).unwrap(), None);
    assert!(resolver.launch_read(Some("https://example.com")).is_err());
    let release = Resolver::new("com.cmuxterm.app", &home.0).unwrap();
    assert!(release.launch_read(Some("http://127.0.0.1:9")).is_err());
}

/// The launch read is the CLI's `get --cache-first` minus the fetch.
#[cfg(feature = "fetch")]
#[test]
fn the_launch_read_is_the_cache_first_read() {
    let home = Home::new();
    let resolver = Resolver::new(DEV_BUNDLE, &home.0).unwrap();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    for seed in [None, Some("staging"), Some("prod")] {
        let cli = runtime
            .block_on(resolver.client_config_cache_first(resolver.resolve(seed).unwrap()))
            .unwrap();
        assert_eq!(resolver.launch_read(seed).unwrap(), Some(cli), "seed {seed:?}");
    }
}

#[test]
fn the_launch_seed_is_the_arguments_then_the_environment() {
    let env = |key: &str| match key {
        "CMUX_NEXT_CLOUD_BACKEND" => Some("staging-from-env".to_owned()),
        "CMUX_NEXT_CLOUD_ENV" => Some("prod".to_owned()),
        _ => None,
    };
    let backend = |args: &[&str]| launch_seed(&words(args), env);
    assert_eq!(
        backend(&["cmux", "--cloud-backend", STAGING_API]).unwrap().as_deref(),
        Some(STAGING_API)
    );
    assert_eq!(backend(&["cmux", "--cloud-backend=dev"]).unwrap().as_deref(), Some("dev"));
    assert_eq!(backend(&["cmux"]).unwrap().as_deref(), Some("staging-from-env"));
    assert_eq!(
        launch_seed(&words(&["cmux"]), |key| (key == "CMUX_NEXT_CLOUD_ENV")
            .then(|| "prod".to_owned()))
        .unwrap()
        .as_deref(),
        Some("prod")
    );
    assert_eq!(launch_seed(&words(&["cmux"]), |_| None).unwrap(), None);
    assert!(backend(&["cmux", "--cloud-backend"]).is_err());
    assert!(backend(&["cmux", "--cloud-backend=dev", "--cloud-backend", "prod"]).is_err());
    assert!(backend(&["cmux", "--cloud-backend", "https://example.com"]).is_err());
}
