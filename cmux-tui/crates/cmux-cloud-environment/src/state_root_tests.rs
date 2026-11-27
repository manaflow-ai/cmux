use super::*;

use crate::{Resolver, bundle_folder, tests::Home};

const RELEASE: &str = "com.cmuxterm.app";

#[test]
fn without_a_root_the_resolver_is_unchanged() {
    let home = Home::new();
    let plain = Resolver::with_state_root(RELEASE, &home.0, None).unwrap();
    let selection = plain.resolve(None).unwrap();
    // The release's untouched default keeps its historical, unscoped sign-in.
    assert!(selection.legacy_storage);
    assert_eq!(selection.auth_storage_namespace, None);
    assert!(!selection.auth_namespace.contains("run-"));
    assert_eq!(plain.state_path(), bundle_folder(&home.0, RELEASE).join(crate::STATE_FILE));
}

#[test]
fn a_root_holds_the_state_and_scopes_every_sign_in_to_the_run() {
    let home = Home::new();
    let root = home.0.join("run-a");
    let plain = Resolver::with_state_root(RELEASE, &home.0, None).unwrap().resolve(None).unwrap();
    let resolver = Resolver::with_state_root(RELEASE, &home.0, Some(&root)).unwrap();
    assert_eq!(resolver.state_path(), bundle_folder(&root, RELEASE).join(crate::STATE_FILE));
    let selection = resolver.resolve(None).unwrap();
    let run = run_segment(&root);
    // Never the account's unscoped store: its own namespace, ending in the run.
    assert!(!selection.legacy_storage);
    assert_eq!(selection.auth_namespace, format!("{}-{run}", plain.auth_namespace));
    assert_eq!(
        selection.auth_storage_namespace.as_deref(),
        Some(selection.auth_namespace.as_str())
    );
    // A launch override is scoped the same way; the same root gives the same namespace.
    let launch = resolver.resolve(Some("prod")).unwrap();
    assert!(launch.auth_namespace.ends_with(&run));
    let again =
        Resolver::with_state_root(RELEASE, &home.0, Some(&root)).unwrap().resolve(None).unwrap();
    assert_eq!(again.auth_namespace, selection.auth_namespace);
    // Another root is another person.
    let other = Resolver::with_state_root(RELEASE, &home.0, Some(&home.0.join("run-b")))
        .unwrap()
        .resolve(None)
        .unwrap();
    assert_ne!(other.auth_namespace, selection.auth_namespace);
}

#[test]
fn a_rooted_selection_names_a_run_keychain_service() {
    let home = Home::new();
    let root = home.0.join("run-a");
    let selection =
        Resolver::with_state_root(RELEASE, &home.0, Some(&root)).unwrap().resolve(None).unwrap();
    let names = cmux_cloud_config_names(&selection);
    assert_eq!(names, format!("{RELEASE}.auth.{}", selection.auth_namespace));
    assert!(names.ends_with(&run_segment(&root)));
}

/// The Stack token service the app's configuration makes (cmux-cloud-config `storage_names`):
/// `<bundle id>.auth.<storage namespace>`, unscoped `<bundle id>.auth` without one.
fn cmux_cloud_config_names(selection: &crate::Selection) -> String {
    match &selection.auth_storage_namespace {
        Some(namespace) => format!("{}.auth.{namespace}", selection.bundle_id),
        None => format!("{}.auth", selection.bundle_id),
    }
}

#[test]
fn only_an_absolute_path_is_a_root() {
    assert_eq!(state_root(None), None);
    assert_eq!(state_root(Some("")), None);
    assert_eq!(state_root(Some("  ")), None);
    assert_eq!(state_root(Some("relative/run")), None);
    assert_eq!(state_root(Some("~/run")), None);
    assert_eq!(state_root(Some("/tmp/run-1/")), Some(PathBuf::from("/tmp/run-1")));
    assert_eq!(state_root(Some(" /tmp/run-1 ")), Some(PathBuf::from("/tmp/run-1")));
}

#[test]
fn run_segment_is_stable_and_matches_the_app() {
    // The same vector as CmuxNextCompatTests' StateRootTests: the app and the CLI name one run.
    assert_eq!(run_segment(Path::new("/tmp/cmux-run-1")), "run-8fde1965cd1ca6b3");
    assert_eq!(run_segment(Path::new("")), "run-cbf29ce484222325");
    assert_ne!(run_segment(Path::new("/tmp/a")), run_segment(Path::new("/tmp/b")));
}
