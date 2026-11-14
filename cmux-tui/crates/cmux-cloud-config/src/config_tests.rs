//! Ported from the app's CloudRuntimeSelectionTests, CloudConfigurationSignedDEVTests and
//! CloudAuthNamespacedAdoptionTests (the configuration parts).

use std::collections::BTreeMap;

use super::*;

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

fn selection(
    name: &str,
    bundle_id: &str,
    namespace: &str,
    legacy: bool,
    storage: Option<&str>,
) -> Selection {
    Selection {
        name: name.to_owned(),
        api_origin: "https://backend.standin.invalid".to_owned(),
        auth_web_origin: "https://signin.standin.invalid".to_owned(),
        stack_origin: "https://stack.standin.invalid".to_owned(),
        stack_project_id: "staging-project".to_owned(),
        stack_client_key: "staging-key".to_owned(),
        bundle_id: bundle_id.to_owned(),
        auth_namespace: namespace.to_owned(),
        auth_storage_namespace: storage.map(str::to_owned),
        legacy_storage: legacy,
    }
}

fn configure(selection: Selection, bundled: &[(&str, &str)], debug: bool) -> Configuration {
    from_selection(&Inputs {
        bundle_id: Some(selection.bundle_id.clone()),
        selection,
        bundled: map(bundled),
        process: map(&[("CMUX_AUTH_CALLBACK_SCHEME", "from-the-shell")]),
        is_debug_build: debug,
    })
}

#[test]
fn the_selection_names_every_origin_and_scopes_auth() {
    let selected = selection("staging", NEXT_DEV_BUNDLE_ID, "staging-2", false, None);
    let config = configure(
        selected.clone(),
        &[
            ("CMUX_AUTH_CALLBACK_SCHEME", "cmux-test-callback"),
            ("CMUX_STACK_PROJECT_ID", "wrong-project"),
        ],
        false,
    );
    assert_eq!(config.backend, Backend::Development(selected.api_origin.clone()));
    assert_eq!(config.api_base_url, selected.api_origin);
    assert_eq!(config.auth_web_origin, selected.auth_web_origin);
    assert_eq!(config.stack_base_url, selected.stack_origin);
    assert_eq!(config.stack_project_id, "staging-project");
    assert_eq!(config.stack_publishable_client_key, "staging-key");
    // The bundle's value wins over the shell's.
    assert_eq!(config.callback_scheme, "cmux-test-callback");
    assert!(!config.is_production_auth);
    assert_eq!(config.storage.keychain_service, "com.cmuxterm.app.debug.next.auth.staging-2");
    assert_eq!(config.storage.credentials_subpath.last().map(String::as_str), Some("staging-2"));
    assert_eq!(config.storage.defaults_key_suffix.as_deref(), Some("staging-2"));
    assert_eq!(config.namespaced_legacy_store, None);
    // Another backend's namespace is another store.
    let other = configure(
        selection("staging", NEXT_DEV_BUNDLE_ID, "other-backend", false, None),
        &[],
        false,
    );
    assert_ne!(other.storage, config.storage);
    // A selected local backend is available: development, not local-only.
    let mut local = selection("local", NEXT_DEV_BUNDLE_ID, "staging-2", false, None);
    local.api_origin = "http://localhost:8787".to_owned();
    assert_eq!(
        configure(local, &[], false).backend,
        Backend::Development("http://localhost:8787".to_owned())
    );
}

#[test]
fn only_known_untouched_defaults_keep_their_old_locations() {
    let production = configure(
        selection("prod", "com.cmuxterm.app.nightly.cmux-next", "backend-0", true, None),
        &[],
        false,
    );
    assert_eq!(production.backend, Backend::Production);
    assert!(production.is_production_auth);
    assert_eq!(production.storage.keychain_service, "com.cmuxterm.app.nightly.cmux-next.auth");
    assert_eq!(
        production.storage.credentials_subpath,
        ["Library", "Application Support", "cmux", "com.cmuxterm.app.nightly.cmux-next"]
    );
    assert_eq!(production.storage.defaults_key_suffix, None);
    // A legacy default adopts, once, a session from the namespaced store its update used.
    let legacy = production.namespaced_legacy_store.expect("legacy store");
    assert_eq!(legacy.keychain_service, "com.cmuxterm.app.nightly.cmux-next.auth.backend-0");
    assert_eq!(legacy.credentials_subpath.last().map(String::as_str), Some("backend-0"));

    let signed_dev = configure(
        selection(
            "dev",
            NEXT_DEV_BUNDLE_ID,
            "backend-0",
            true,
            Some("development-project-fixture"),
        ),
        &[],
        false,
    );
    assert_eq!(
        signed_dev.storage.keychain_service,
        "com.cmuxterm.app.debug.next.auth.development-project-fixture"
    );
    assert_eq!(
        signed_dev.storage.defaults_key_suffix.as_deref(),
        Some("development-project-fixture")
    );
    assert_eq!(signed_dev.namespaced_legacy_store, None);
    let switched =
        configure(selection("dev", NEXT_DEV_BUNDLE_ID, "backend-1", false, Some("x")), &[], false);
    assert_eq!(switched.storage.keychain_service, "com.cmuxterm.app.debug.next.auth.backend-1");
}

#[test]
fn the_placeholder_never_restores_a_real_bundles_credentials() {
    let names = storage_names(Some(UNAVAILABLE_BUNDLE_ID), None);
    assert_eq!(
        names.keychain_service,
        "com.cmuxterm.app.cloud-unavailable.auth.bootstrap-unavailable"
    );
    assert_eq!(
        names.credentials_subpath[3..],
        ["com.cmuxterm.app.cloud-unavailable", "bootstrap-unavailable"]
    );
    assert_eq!(names.defaults_key_suffix.as_deref(), Some("bootstrap-unavailable"));
    assert_eq!(storage_names(None, None).keychain_service, "com.cmuxterm.app.auth");
    assert_eq!(storage_names(Some(""), None).credentials_subpath[3], "cmux");
}

#[test]
fn the_callback_scheme_follows_the_build() {
    let scheme = |bundle: &str, bundled: &[(&str, &str)], debug: bool| {
        let mut config = from_selection(&Inputs {
            bundle_id: Some(bundle.to_owned()),
            selection: selection("dev", bundle, "n", true, None),
            bundled: map(bundled),
            process: BTreeMap::new(),
            is_debug_build: debug,
        });
        std::mem::take(&mut config.callback_scheme)
    };
    assert_eq!(scheme(NEXT_DEV_BUNDLE_ID, &[], false), "cmux-next-dev");
    assert_eq!(scheme(NEXT_DEV_BUNDLE_ID, &[], true), "cmux-next-dev");
    assert_eq!(
        scheme("com.cmuxterm.app.debug.x", &[("CMUX_TAG", "My_Tag!!2")], true),
        "cmux-dev-my-tag-2"
    );
    assert_eq!(scheme("com.cmuxterm.app.debug.x", &[("CMUX_TAG", "---")], true), "cmux-dev");
    assert_eq!(scheme("com.cmuxterm.app.nightly", &[], false), "cmux-nightly");
    assert_eq!(scheme("com.cmuxterm.app.rc", &[], false), "cmux-rc");
    assert_eq!(scheme("com.cmuxterm.app", &[], false), "cmux");
    // A scheme that cannot form a URL is ignored.
    assert_eq!(
        scheme("com.cmuxterm.app", &[("CMUX_AUTH_CALLBACK_SCHEME", "1 bad")], false),
        "cmux"
    );
}

#[test]
fn only_signed_dev_on_production_adopts_nightlys_session() {
    assert!(
        configure(selection("prod", NEXT_DEV_BUNDLE_ID, "n", true, None), &[], false)
            .adopts_nightly_session
    );
    assert!(
        !configure(selection("dev", NEXT_DEV_BUNDLE_ID, "n", true, None), &[], false)
            .adopts_nightly_session
    );
    assert!(
        !configure(selection("prod", NEXT_DEV_BUNDLE_ID, "n", true, None), &[], true)
            .adopts_nightly_session
    );
    assert!(
        !configure(selection("prod", NIGHTLY_BUNDLE_ID, "n", true, None), &[], false)
            .adopts_nightly_session
    );
}

#[test]
fn the_sign_in_url_nests_the_callback_with_its_state() {
    assert_eq!(
        sign_in_url("http://localhost:4577", "cmux-dev-safauth", Some("state-secret")),
        "http://localhost:4577/handler/native-sign-in?after_auth_return_to=http%3A%2F%2Flocalhost%3A4577%2Fhandler%2Fafter-sign-in%3Fnative_app_return_to%3Dcmux-dev-safauth%253A%252F%252Fauth-callback%253Fcmux_auth_state%253Dstate-secret"
    );
    assert_eq!(
        sign_in_url("https://cmux.com/", "cmux", None),
        "https://cmux.com/handler/native-sign-in?after_auth_return_to=https%3A%2F%2Fcmux.com%2Fhandler%2Fafter-sign-in%3Fnative_app_return_to%3Dcmux%253A%252F%252Fauth-callback"
    );
}

#[test]
fn the_vm_api_follows_the_backend() {
    assert_eq!(vm_api_base_url(&Backend::Production), PRODUCTION_VM_API);
    assert_eq!(vm_api_base_url(&Backend::Development("https://x".to_owned())), STAGING_VM_API);
}
