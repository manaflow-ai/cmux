//! Ported from the app's CloudConfigurationSignedDEVTests, CloudShareAPITests and
//! CloudSignedDEVAuthPersistenceTests (the configuration parts).

use std::collections::BTreeMap;

use super::*;

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

fn config(
    bundle_id: &str,
    bundled: &[(&str, &str)],
    process: &[(&str, &str)],
    debug: bool,
) -> Configuration {
    resolve(&Inputs {
        bundle_id: Some(bundle_id.to_owned()),
        bundled: map(bundled),
        process: map(process),
        is_debug_build: debug,
    })
}

fn none() -> BTreeMap<String, String> {
    BTreeMap::new()
}

#[test]
fn signed_dev_uses_the_development_cloud_without_launch_overrides() {
    let config = config(NEXT_DEV_BUNDLE_ID, &[], &[], false);
    let identity = config.identity();
    assert_eq!(config.link_source, LinkSource::AppServer);
    assert_eq!(
        owner_api_base_url(&identity, &none()),
        "https://cmux-api-development.debussy.workers.dev"
    );
    assert_eq!(config.api_base_url, "https://cmux-staging.vercel.app");
    assert_eq!(config.auth_web_origin, "https://cmux-staging.vercel.app");
    assert_eq!(config.stack_project_id, "454ecd03-1db2-4050-845e-4ce5b0cd9895");
    assert!(!config.is_production_auth);
    assert!(!config.is_debug_build);
    assert_eq!(config.callback_scheme, "cmux-next-dev");
    assert_eq!(
        keychain_service(&identity),
        "com.cmuxterm.app.debug.next.auth.454ecd03-1db2-4050-845e-4ce5b0cd9895"
    );
    // The Cloud API is NEXT Cloud's development Worker, never the classic staging web app.
    assert_eq!(config.cloud_api_base_url, "https://cmux-api-development.debussy.workers.dev");
    assert_eq!(config.backend, Backend::Development(config.cloud_api_base_url.clone()));
    assert_eq!(vm_api_base_url(&config.backend), "https://vm-staging.cmux.dev");
}

#[test]
fn signed_dev_does_not_accept_endpoint_or_auth_overrides() {
    let overrides = [
        ("CMUX_AUTH_ENVIRONMENT", "production"),
        ("CMUX_STACK_BASE_URL", "https://override.invalid"),
        ("CMUX_STACK_PROJECT_ID", "other-project"),
        ("CMUX_API_BASE_URL", "https://override.invalid"),
        ("CMUX_AUTH_WWW_ORIGIN", "https://override.invalid"),
        ("CMUX_NEXT_FEED_API_URL", "https://override.invalid"),
        ("CMUX_AUTH_CALLBACK_SCHEME", "other-app"),
        ("CMUX_NEXT_CLOUD_LINK", "legacy"),
    ];
    let baseline = config(NEXT_DEV_BUNDLE_ID, &[], &[], false);
    let config = config(NEXT_DEV_BUNDLE_ID, &overrides, &overrides, false);
    assert_eq!(config, baseline);
    assert_eq!(
        owner_api_base_url(&config.identity(), &map(&overrides)),
        owner_api_base_url(&baseline.identity(), &none())
    );
}

#[test]
fn other_release_channels_keep_production() {
    for bundle_id in [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.nightly.cmux-next",
        "com.cmuxterm.app.rc",
        "com.cmuxterm.app.debug",
        "com.cmuxterm.app.debug.next.other",
        "com.cmuxterm.app.debug.nextx",
    ] {
        let config = config(bundle_id, &[], &[], false);
        assert_eq!(config.link_source, LinkSource::AppServer, "{bundle_id}");
        assert!(config.is_production_auth, "{bundle_id}");
        assert_eq!(config.api_base_url, "https://cmux.com", "{bundle_id}");
        assert_eq!(config.cloud_api_base_url, "https://cmux.com", "{bundle_id}");
        assert_eq!(owner_api_base_url(&config.identity(), &none()), "https://cloud-api.cmux.dev");
        assert_eq!(vm_api_base_url(&config.backend), "https://vm.cmux.dev");
        assert_eq!(keychain_service(&config.identity()), format!("{bundle_id}.auth"));
    }
    assert_eq!(config("com.cmuxterm.app.nightly", &[], &[], false).callback_scheme, "cmux-nightly");
    assert_eq!(config("com.cmuxterm.app.rc", &[], &[], false).callback_scheme, "cmux-rc");
    assert_eq!(config("com.cmuxterm.app", &[], &[], false).callback_scheme, "cmux");
}

#[test]
fn production_keeps_the_legacy_escape_hatch() {
    for bundled in [[("CMUX_NEXT_CLOUD_LINK", "legacy")], [("CMUX_CLOUD_LINK", "LEGACY")]] {
        let config = config("com.cmuxterm.app.nightly.cmux-next", &bundled, &[], false);
        assert_eq!(config.link_source, LinkSource::Legacy);
        assert!(config.is_production_auth);
    }
    let launched = config(
        "com.cmuxterm.app.nightly.cmux-next",
        &[],
        &[("CMUX_NEXT_CLOUD_LINK", "legacy")],
        false,
    );
    assert_eq!(launched.link_source, LinkSource::Legacy);
}

#[test]
fn only_a_bench_capture_build_is_configured_as_debug() {
    assert!(is_capture_build(Some("com.cmuxterm.app.debug.cap0123456789"), true));
    assert!(is_capture_build(Some("com.cmuxterm.app.debug.capabcdef0123"), true));
    assert!(!is_capture_build(Some("com.cmuxterm.app.debug.cap0123456789"), false));
    for bundle_id in [
        None,
        Some("com.cmuxterm.app"),
        Some("com.cmuxterm.app.nightly"),
        Some("com.cmuxterm.app.rc"),
        Some("com.cmuxterm.app.debug.next"),
        Some("com.cmuxterm.app.debug.chrome.parity.x"),
        Some("com.cmuxterm.app.debug.cap012345678"),
        Some("com.cmuxterm.app.debug.cap0123456789a"),
        Some("com.cmuxterm.app.debug.capABCDEF0123"),
        Some("com.cmuxterm.app.debug.cap0123456789.x"),
        Some("com.cmuxterm.app.nightly.cap0123456789"),
    ] {
        assert!(!is_capture_build(bundle_id, true), "{bundle_id:?}");
    }
    let capture = config("com.cmuxterm.app.debug.cap0123456789", &[], &[], true);
    assert!(!capture.is_production_auth);
    assert_eq!(
        owner_api_base_url(&capture.identity(), &none()),
        "https://cmux-api-development.debussy.workers.dev"
    );
}

#[test]
fn debug_build_keeps_its_explicit_link_and_worker_overrides() {
    let config = config(NEXT_DEV_BUNDLE_ID, &[("CMUX_CLOUD_LINK", "app")], &[], true);
    assert_eq!(config.link_source, LinkSource::AppServer);
    assert_eq!(
        owner_api_base_url(
            &config.identity(),
            &map(&[("CMUX_NEXT_FEED_API_URL", "https://override.invalid")])
        ),
        "https://override.invalid"
    );
}

#[test]
fn a_debug_build_mints_share_tokens_from_the_development_worker() {
    let identity = config("com.cmuxterm.app.debug.walk", &[], &[], true).identity();
    assert_eq!(owner_api_base_url(&identity, &none()), DEVELOPMENT_WORKER_ORIGIN);
    assert_eq!(share_api_base_url(&identity, &none()), DEVELOPMENT_WORKER_ORIGIN);
}

#[test]
fn an_owner_api_override_is_the_share_api_too_and_a_release_build_keeps_its_owner_api() {
    let debug = config("com.cmuxterm.app.debug.walk", &[], &[], true).identity();
    let named = map(&[("CMUX_NEXT_FEED_API_URL", "https://owner.standin.invalid")]);
    assert_eq!(share_api_base_url(&debug, &named), owner_api_base_url(&debug, &named));
    let release = config("com.cmuxterm.app", &[], &[], false).identity();
    assert_eq!(share_api_base_url(&release, &none()), owner_api_base_url(&release, &none()));
    // A release build never takes the debug override.
    assert_eq!(owner_api_base_url(&release, &named), PRODUCTION_OWNER_API);
}

#[test]
fn a_release_build_sends_credentials_only_to_a_cmux_api() {
    let release = config("com.cmuxterm.app", &[], &[], false).identity();
    let debug = config("com.cmuxterm.app.debug.walk", &[], &[], true).identity();
    for api in [
        "https://cloud-api.cmux.dev",
        "https://cloud-api-staging.cmux.dev",
        "https://cmux-api-development.debussy.workers.dev/",
    ] {
        assert!(accepts_share_api(&release, api), "{api}");
    }
    assert!(!accepts_share_api(&release, "https://elsewhere.example"));
    assert!(accepts_share_api(&debug, "https://elsewhere.example"));
    for api in [
        "http://cloud-api.cmux.dev",
        "https://cloud-api.cmux.dev:8443",
        "https://cloud-api.cmux.dev/v1",
        "https://u:p@cloud-api.cmux.dev",
    ] {
        assert!(!accepts_share_api(&debug, api), "{api}");
    }
}

#[test]
fn signed_dev_scopes_its_tokens_apart_from_the_old_production_session() {
    let development = config(NEXT_DEV_BUNDLE_ID, &[], &[], false).identity();
    let previous_production = Identity {
        is_production_auth: true,
        stack_project_id: PRODUCTION_PROJECT_ID.to_owned(),
        ..development.clone()
    };
    assert_ne!(keychain_service(&development), keychain_service(&previous_production));
    assert_ne!(credentials_subpath(&development), credentials_subpath(&previous_production));
    assert_eq!(
        credentials_subpath(&development),
        ["Library", "Application Support", "cmux", NEXT_DEV_BUNDLE_ID, DEVELOPMENT_PROJECT_ID]
    );
    assert_eq!(
        auth_defaults_key(&development, "cmux.auth.cachedUser"),
        format!("cmux.auth.cachedUser.{DEVELOPMENT_PROJECT_ID}")
    );
    assert_eq!(
        auth_defaults_key(&previous_production, "cmux.auth.cachedUser"),
        "cmux.auth.cachedUser"
    );
    let unnamed = Identity { bundle_id: None, ..previous_production };
    assert_eq!(keychain_service(&unnamed), "com.cmuxterm.app.auth");
    assert_eq!(credentials_subpath(&unnamed), ["Library", "Application Support", "cmux", "cmux"]);
}

#[test]
fn a_debug_build_signs_in_on_staging_and_takes_only_asked_for_loopback_origins() {
    let tagged = [("CMUX_TAG", "My Tag!"), ("CMUX_API_BASE_URL", "http://localhost:4000")];
    let plain = config("com.cmuxterm.app.debug.my-tag", &tagged, &[], true);
    assert_eq!(plain.api_base_url, STAGING_WEB_ORIGIN);
    assert_eq!(plain.cloud_api_base_url, DEVELOPMENT_WORKER_ORIGIN);
    assert_eq!(plain.backend, Backend::Development(DEVELOPMENT_WORKER_ORIGIN.to_owned()));
    assert_eq!(plain.callback_scheme, "cmux-dev-my-tag");
    assert!(!plain.is_production_auth);
    let local = config(
        "com.cmuxterm.app.debug.my-tag",
        &tagged,
        &[("CMUX_NEXT_CLOUD_BACKEND", "local")],
        true,
    );
    assert_eq!(local.api_base_url, "http://localhost:4000");
    assert_eq!(local.cloud_api_base_url, "http://localhost:4000");
    assert_eq!(local.backend, Backend::LocalOnly("http://localhost:4000".to_owned()));
    let port = config(
        "com.cmuxterm.app.debug",
        &[("CMUX_PORT", "3999")],
        &[("CMUX_NEXT_CLOUD_BACKEND", "LOCAL")],
        true,
    );
    assert_eq!(port.api_base_url, "http://localhost:3999");
    let remote = config(
        "com.cmuxterm.app.debug",
        &[("CMUX_DEV_BACKEND_URL", "https://dev.example")],
        &[],
        true,
    );
    assert_eq!(
        (remote.api_base_url.as_str(), remote.auth_web_origin.as_str()),
        ("https://dev.example", "https://dev.example")
    );
    // The bundle wins over the launch environment; blank values count as unset.
    let bundled = config(
        "com.cmuxterm.app.debug",
        &[("CMUX_API_BASE_URL", "https://a.example")],
        &[("CMUX_API_BASE_URL", "https://b.example")],
        true,
    );
    assert_eq!(bundled.api_base_url, "https://a.example");
    assert_eq!(bundled.cloud_api_base_url, "https://a.example");
    let blank = config("com.cmuxterm.app.debug", &[("CMUX_STACK_PROJECT_ID", "  ")], &[], true);
    assert_eq!(blank.stack_project_id, DEVELOPMENT_PROJECT_ID);
    let production =
        config("com.cmuxterm.app.debug", &[("CMUX_AUTH_ENVIRONMENT", "Production")], &[], true);
    assert!(production.is_production_auth);
    assert_eq!(production.callback_scheme, "cmux-dev");
}

#[test]
fn a_callback_scheme_that_cannot_form_a_url_is_ignored() {
    let bad = config(
        "com.cmuxterm.app.debug",
        &[("CMUX_AUTH_CALLBACK_SCHEME", "not a scheme")],
        &[],
        true,
    );
    assert_eq!(bad.callback_scheme, "cmux-dev");
    let good =
        config("com.cmuxterm.app.debug", &[("CMUX_AUTH_CALLBACK_SCHEME", "cmux-x")], &[], true);
    assert_eq!(good.callback_scheme, "cmux-x");
}

#[test]
fn previews_and_artifacts_come_from_each_owners_platform() {
    let debug = config("com.cmuxterm.app.debug", &[], &[], true).identity();
    assert_eq!(
        platform_preview_api_base_url(&debug, &none()).as_deref(),
        Some(DEVELOPMENT_PLATFORM)
    );
    let staging_owner = map(&[("CMUX_NEXT_FEED_API_URL", "https://cloud-api-staging.cmux.dev")]);
    assert_eq!(
        platform_preview_api_base_url(&debug, &staging_owner).as_deref(),
        Some(STAGING_PLATFORM)
    );
    let named = map(&[("CMUX_NEXT_PLATFORM_PREVIEW_API_URL", "https://p.example")]);
    assert_eq!(platform_preview_api_base_url(&debug, &named).as_deref(), Some("https://p.example"));
    let bad = map(&[("CMUX_NEXT_PLATFORM_PREVIEW_API_URL", "https://p.example/x")]);
    assert_eq!(platform_preview_api_base_url(&debug, &bad), None);
    let release = config("com.cmuxterm.app", &[], &[], false).identity();
    assert_eq!(platform_preview_api_base_url(&release, &none()), None);
    assert_eq!(artifacts_api_base_url(&release, &none()), PRODUCTION_PLATFORM);
    assert_eq!(artifacts_api_base_url(&debug, &none()), DEVELOPMENT_PLATFORM);
    let local = map(&[("CMUX_NEXT_ARTIFACTS_API_URL", "http://localhost:8787")]);
    assert_eq!(artifacts_api_base_url(&debug, &local), "http://localhost:8787");
    let foreign = map(&[("CMUX_NEXT_ARTIFACTS_API_URL", "https://elsewhere.example")]);
    assert_eq!(artifacts_api_base_url(&debug, &foreign), DEVELOPMENT_PLATFORM);
}

#[test]
fn scheme_tags_are_lowercase_runs_joined_by_single_hyphens() {
    assert_eq!(sanitized_scheme_tag("My__Tag 2").as_deref(), Some("my-tag-2"));
    assert_eq!(sanitized_scheme_tag("--x--").as_deref(), Some("x"));
    assert_eq!(sanitized_scheme_tag("!!!"), None);
}

#[test]
fn no_development_build_uses_the_classic_staging_web_app_as_its_cloud_api() {
    for (bundle_id, debug) in [
        (NEXT_DEV_BUNDLE_ID, false),
        ("com.cmuxterm.app.debug", true),
        ("com.cmuxterm.app.debug.my-tag", true),
    ] {
        let config = config(bundle_id, &[], &[], debug);
        assert_ne!(config.cloud_api_base_url, STAGING_WEB_ORIGIN, "{bundle_id}");
        assert_eq!(config.cloud_api_base_url, DEVELOPMENT_WORKER_ORIGIN, "{bundle_id}");
    }
}
