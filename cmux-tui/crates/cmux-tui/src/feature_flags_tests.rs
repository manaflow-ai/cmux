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
