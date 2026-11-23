//! A launch's own state root (`CMUX_NEXT_STATE_ROOT`): every per-user thing the launch keeps goes
//! under one folder the launcher picks, and every Keychain service it signs in with carries that
//! folder's run segment, so a fresh folder is a fresh person (Chromium's `--user-data-dir`). A
//! fresh-home probe sets it to a new temporary folder per run instead of wiping the account.
//!
//! The folder stands for the home: the selection state and its client-config cache are in
//! `<root>/Library/Application Support/cmux-next/<bundle id>` ([`crate::bundle_folder`] of the
//! root), as the app's own folders are (CmuxNext `NextSupport.stateRoot`). The selection's sign-in
//! namespace ends in [`run_segment`], so the Stack token Keychain service, its file fallback, the
//! `cmux.auth.*` defaults keys and every store the app namespaces by the selection (install key,
//! device hub, mobile host, Cloud paths) are the run's own. Unset or blank: nothing changes.

use std::path::{Path, PathBuf};

/// The launch variable naming the state root (an absolute path).
pub const STATE_ROOT_ENV: &str = "CMUX_NEXT_STATE_ROOT";

/// The state root `value` names: an absolute path, trailing slashes dropped; None for an unset,
/// blank or relative value (a relative root would move with the working folder).
pub fn state_root(value: Option<&str>) -> Option<PathBuf> {
    let trimmed = value?.trim();
    if !trimmed.starts_with('/') {
        return None;
    }
    let path = trimmed.trim_end_matches('/');
    Some(PathBuf::from(if path.is_empty() { "/" } else { path }))
}

/// This process's state root ([`STATE_ROOT_ENV`]).
pub fn state_root_from_env() -> Option<PathBuf> {
    state_root(std::env::var(STATE_ROOT_ENV).ok().as_deref())
}

/// The run segment of `root`: `run-` and the FNV-1a 64 hash of its path's bytes as 16 lowercase
/// hex digits (CmuxNext `NextSupport.runSegment(stateRoot:)` makes the same). Path- and
/// Keychain-safe; one root always gives one segment, so a relaunch on the same root restores
/// the run's sign-in.
pub fn run_segment(root: &Path) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in root.as_os_str().as_encoded_bytes() {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("run-{hash:016x}")
}

/// The sign-in namespace `namespace` becomes under a state root whose segment is `run`.
pub(crate) fn scoped_namespace(namespace: &str, run: &str) -> String {
    format!("{namespace}-{run}")
}

#[cfg(test)]
mod tests {
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
        let plain =
            Resolver::with_state_root(RELEASE, &home.0, None).unwrap().resolve(None).unwrap();
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
        let again = Resolver::with_state_root(RELEASE, &home.0, Some(&root))
            .unwrap()
            .resolve(None)
            .unwrap();
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
        let selection = Resolver::with_state_root(RELEASE, &home.0, Some(&root))
            .unwrap()
            .resolve(None)
            .unwrap();
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
}
