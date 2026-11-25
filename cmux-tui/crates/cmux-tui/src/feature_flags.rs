//! Invite-wave flags (plans/cmux-next/tui-tester-rollout.md #10).
//!
//! The nightly publishes `notes/flags.json` beside the release notes, signed
//! (`notes/flags.json.sig`, base64 Ed25519) with the same `content-signing`
//! key, from the reviewed `release-notes/next/flags.json`:
//!
//! ```json
//! { "version": 1,
//!   "default": { "DisabledFeatures": ["cloud-vm"] },
//!   "cohorts": { "linux-wave-1": { "DisabledFeatures": ["remote-browser"] } } }
//! ```
//!
//! Each object holds policy keys in the shape of `managed/policy.rs`; a
//! cohort's keys replace the default's. The owner fetches the document at
//! start (`owner_start/background_checks.rs`) and caches it at the state root
//! only when the signature verifies; every reader verifies the cache again,
//! so an edited file on disk counts for nothing. A tester's cohort comes from
//! `CMUX_TUI_COHORT` or the `tester.cohort` key of cmux.json, else `default`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use base64::Engine;
use serde_json::Value;

/// The `content-signing` public key (raw, base64), as `ContentSignature.publicKey` in the app.
const PUBLIC_KEY: &str = "AnrDI4vqN4lFGX2IpzeWPZsa/Hk7yQMkVIKppFwAst4=";
/// Where the nightly publishes the document.
pub(crate) const FLAGS_URL: &str = "https://files-next.cmux.com/nightly-next/next/notes/flags.json";
const CACHE_NAME: &str = "flags.json";
const DEFAULT_COHORT: &str = "default";
#[cfg(debug_assertions)]
pub(crate) const TEST_URL_ENV: &str = "CMUX_TUI_TEST_FLAGS_URL";
#[cfg(debug_assertions)]
const TEST_PUBLIC_KEY_ENV: &str = "CMUX_TUI_TEST_CONTENT_PUBLIC_KEY";

/// Whether `signature` (base64 text) is an Ed25519 signature of `data` by `public_key` (raw, base64).
pub(crate) fn verify(data: &[u8], signature: &[u8], public_key: &str) -> bool {
    let engine = &base64::engine::general_purpose::STANDARD;
    let Ok(signature) = engine.decode(String::from_utf8_lossy(signature).trim()) else {
        return false;
    };
    let Ok(key) = engine.decode(public_key) else { return false };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
        .verify(data, &signature)
        .is_ok()
}

/// The policy keys `document` sets for `cohort`: the default's, replaced by the cohort's.
/// None when the document is not version 1.
pub(crate) fn resolve(document: &Value, cohort: &str) -> Option<BTreeMap<String, Value>> {
    if document.get("version").and_then(Value::as_u64) != Some(1) {
        return None;
    }
    let mut keys = BTreeMap::new();
    let objects =
        [document.get("default"), document.get("cohorts").and_then(|cohorts| cohorts.get(cohort))];
    for object in objects.into_iter().flatten().filter_map(Value::as_object) {
        keys.extend(object.iter().map(|(key, value)| (key.clone(), value.clone())));
    }
    Some(keys)
}

/// `DisabledFeatures` of resolved keys.
pub(crate) fn disabled_features(keys: &BTreeMap<String, Value>) -> Vec<String> {
    keys.get("DisabledFeatures")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(|item| item.as_str().map(String::from)).collect())
        .unwrap_or_default()
}

/// The public key this build trusts.
pub(crate) fn public_key() -> String {
    #[cfg(debug_assertions)]
    if let Some(key) = std::env::var(TEST_PUBLIC_KEY_ENV).ok().filter(|key| !key.is_empty()) {
        return key;
    }
    PUBLIC_KEY.to_string()
}

/// The state root (`owner-panics-*.jsonl`, the caches) for this process.
pub(crate) fn state_root() -> Option<PathBuf> {
    let sessions = cmux_tui_core::platform::workspace_state_dir()?;
    Some(sessions.parent().map(PathBuf::from).unwrap_or(sessions))
}

fn cache_paths(root: &Path) -> (PathBuf, PathBuf) {
    (root.join(CACHE_NAME), root.join(format!("{CACHE_NAME}.sig")))
}

/// Caches a fetched document when its signature verifies. Err names why not.
pub(crate) fn store(root: &Path, data: &[u8], signature: &[u8], key: &str) -> Result<(), String> {
    if !verify(data, signature, key) {
        return Err("bad signature".into());
    }
    let document: Value =
        serde_json::from_slice(data).map_err(|error| format!("not JSON: {error}"))?;
    if resolve(&document, DEFAULT_COHORT).is_none() {
        return Err("not a version 1 document".into());
    }
    let (data_path, signature_path) = cache_paths(root);
    // The signature first: a crash between the two leaves a pair that fails
    // verification, never an old signature that vouches for nothing new.
    write_atomic(&signature_path, signature)?;
    write_atomic(&data_path, data)
}

/// The cached document, when its signature verifies.
pub(crate) fn cached(root: &Path, key: &str) -> Option<Value> {
    let (data_path, signature_path) = cache_paths(root);
    let data = std::fs::read(data_path).ok()?;
    let signature = std::fs::read(signature_path).ok()?;
    if !verify(&data, &signature, key) {
        return None;
    }
    serde_json::from_slice(&data).ok()
}

/// This tester's cohort: `CMUX_TUI_COHORT`, else cmux.json `tester.cohort`, else `default`.
pub(crate) fn cohort(env: &dyn Fn(&str) -> Option<String>, settings: Option<&Value>) -> String {
    env("CMUX_TUI_COHORT")
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            settings
                .and_then(|root| cmux_config::value::value_at(root, &["tester", "cohort"][..]))
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty())
                .map(String::from)
        })
        .map(|value| value.trim().to_string())
        .unwrap_or_else(|| DEFAULT_COHORT.to_string())
}

/// cmux.json as JSON, when it parses.
pub(crate) fn settings() -> Option<Value> {
    std::fs::read_to_string(cmux_config::config_path())
        .ok()
        .and_then(|text| cmux_config::jsonc::parse(&text).ok())
}

/// The cohort and what the cached, verified document turns off for it.
pub(crate) fn report() -> (String, Vec<String>) {
    let env = |name: &str| std::env::var(name).ok();
    let cohort = cohort(&env, settings().as_ref());
    let disabled = state_root()
        .and_then(|root| cached(&root, &public_key()))
        .and_then(|document| resolve(&document, &cohort))
        .map(|keys| disabled_features(&keys))
        .unwrap_or_default();
    (cohort, disabled)
}

/// The `DisabledFeatures` name of docked workspaces.
pub(crate) const DOCKED_WORKSPACES: &str = "docked-workspaces";
/// Turns docked workspaces on without editing cmux-tui.json.
pub(crate) const DOCKED_WORKSPACES_ENV: &str = "CMUX_TUI_DOCKED_WORKSPACES";

/// Whether docked workspaces (plans/cmux-next/docked-workspace-DESIGN.md) are
/// on. The prototype is off by default: cmux-tui.json
/// `viewport.docked_workspaces: true` or `CMUX_TUI_DOCKED_WORKSPACES=1` turns
/// it on, and the managed policy or this tester's wave can still turn it off.
pub(crate) fn docked_workspaces_enabled(
    configured: bool,
    env: &dyn Fn(&str) -> Option<String>,
) -> bool {
    let requested = configured
        || env(DOCKED_WORKSPACES_ENV)
            .is_some_and(|value| matches!(value.trim(), "1" | "true" | "on" | "yes"));
    requested && !disables(DOCKED_WORKSPACES)
}

/// Whether the managed policy or this tester's wave turns `feature` off.
pub(crate) fn disables(feature: &str) -> bool {
    let env = |name: &str| std::env::var(name).ok();
    let managed = cmux_config::managed::default_reader(env).read();
    let managed_off = managed
        .forced
        .get("DisabledFeatures")
        .and_then(Value::as_array)
        .is_some_and(|items| items.iter().any(|item| item.as_str() == Some(feature)));
    managed_off || report().1.iter().any(|item| item == feature)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let mut temp_name = path.file_name().unwrap_or_default().to_os_string();
    temp_name.push(".tmp");
    let temp = path.with_file_name(temp_name);
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file =
        options.open(&temp).map_err(|error| format!("write {}: {error}", temp.display()))?;
    file.write_all(bytes).map_err(|error| format!("write {}: {error}", temp.display()))?;
    std::fs::rename(&temp, path).map_err(|error| format!("write {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    fn key_pair() -> Ed25519KeyPair {
        Ed25519KeyPair::from_seed_unchecked(&[3u8; 32]).unwrap()
    }

    fn encode(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn only_the_key_holder_signs_a_document() {
        let pair = key_pair();
        let key = encode(pair.public_key().as_ref());
        let data = br#"{"version":1}"#;
        let signature = format!("{}\n", encode(pair.sign(data).as_ref()));
        assert!(verify(data, signature.as_bytes(), &key));
        assert!(!verify(br#"{"version":2}"#, signature.as_bytes(), &key));
        assert!(!verify(data, signature.as_bytes(), PUBLIC_KEY));
        assert!(!verify(data, b"not base64!", &key));
    }

    #[test]
    fn a_cohort_replaces_the_default_keys() {
        let document = serde_json::json!({
            "version": 1,
            "default": {"DisabledFeatures": ["a"], "MinimumVersion": "1.0.0"},
            "cohorts": {"wave-1": {"DisabledFeatures": ["b"]}},
        });
        let wave = resolve(&document, "wave-1").unwrap();
        assert_eq!(disabled_features(&wave), ["b"]);
        assert_eq!(wave["MinimumVersion"], "1.0.0");
        assert_eq!(disabled_features(&resolve(&document, "other").unwrap()), ["a"]);
        assert!(resolve(&serde_json::json!({"version": 2}), "wave-1").is_none());
    }

    #[test]
    fn the_cohort_comes_from_the_environment_then_the_settings() {
        let settings = serde_json::json!({"tester": {"cohort": "mac-wave-2"}});
        let none = |_: &str| -> Option<String> { None };
        let set = |name: &str| (name == "CMUX_TUI_COHORT").then(|| "linux-wave-1".to_string());
        assert_eq!(cohort(&set, Some(&settings)), "linux-wave-1");
        assert_eq!(cohort(&none, Some(&settings)), "mac-wave-2");
        assert_eq!(cohort(&none, None), "default");
    }

    #[test]
    fn docked_workspaces_stay_off_unless_requested() {
        let none = |_: &str| -> Option<String> { None };
        let on = |name: &str| (name == DOCKED_WORKSPACES_ENV).then(|| "1".to_string());
        let off = |name: &str| (name == DOCKED_WORKSPACES_ENV).then(|| "0".to_string());
        assert!(!docked_workspaces_enabled(false, &none));
        assert!(!docked_workspaces_enabled(false, &off));
        assert_eq!(docked_workspaces_enabled(false, &on), !disables(DOCKED_WORKSPACES));
        assert_eq!(docked_workspaces_enabled(true, &none), !disables(DOCKED_WORKSPACES));
    }

    #[test]
    fn only_a_verified_document_is_cached() {
        let root = tempfile::tempdir().unwrap();
        let pair = key_pair();
        let key = encode(pair.public_key().as_ref());
        let data = br#"{"version":1,"default":{"DisabledFeatures":["x"]}}"#;
        let signature = encode(pair.sign(data).as_ref());
        assert!(store(root.path(), b"{}", signature.as_bytes(), &key).is_err());
        assert!(cached(root.path(), &key).is_none());
        store(root.path(), data, signature.as_bytes(), &key).unwrap();
        assert!(cached(root.path(), &key).is_some());
        // An edit on disk voids the cache.
        std::fs::write(root.path().join(CACHE_NAME), br#"{"version":1}"#).unwrap();
        assert!(cached(root.path(), &key).is_none());
    }
}
