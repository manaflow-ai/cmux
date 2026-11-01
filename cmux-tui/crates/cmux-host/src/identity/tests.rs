use super::*;
use crate::cloud::client::{MemoryStore, ensure_install_key};
use crate::cloud::wire::{BIND_FILE, BOUND_FILE, INSTALL_KEY_FILE};
use crate::config::Paths;
use serde_json::json;

fn enrolled_store() -> (MemoryStore, InstallKey) {
    let mut store = MemoryStore::default();
    let key = ensure_install_key(&mut store, "provider-a", &SystemRandom::new()).unwrap().key;
    let bound = json!({
        "machine":"machine-a", "team":"team-a", "host":"host-a", "epoch":1,
        "install":"install-a", "user":"user-a", "grant":"secret-not-returned",
        "env":"dev", "api_origin":"https://cmux-api-development.debussy.workers.dev",
        "keyset":{}, "bound_at":1,
    });
    store.write(BOUND_FILE, &bound.to_string(), 0o600).unwrap();
    record(&mut store, "machine-a", &key).unwrap();
    (store, key)
}

#[test]
fn identity_resume_keeps_fingerprint_and_returns_no_credential() {
    let (mut store, key) = enrolled_store();
    let before = enrolled(&store, "provider-a").unwrap();
    let resumed = ensure_install_key(&mut store, "provider-a", &SystemRandom::new()).unwrap();
    assert!(!resumed.rotated);
    assert_eq!(before, enrolled(&store, "provider-a").unwrap());
    assert_eq!(before.guest_key, format!("sha256:{:x}", Sha256::digest(key.public_spki())));
    let json = serde_json::to_value(before).unwrap();
    assert_eq!(json.as_object().unwrap().len(), 3);
    assert_eq!(json["machine"], "machine-a");
    assert_eq!(json["instanceId"], "provider-a");
    assert!(!json.to_string().contains("secret-not-returned"));
    assert_eq!(store.mode_of(RECEIPT), Some(0o600));
}

#[test]
fn identity_clone_fails_before_and_after_key_rotation_until_enrolled() {
    let (mut store, _) = enrolled_store();
    assert!(enrolled(&store, "provider-b").is_err());
    let cloned = ensure_install_key(&mut store, "provider-b", &SystemRandom::new()).unwrap();
    assert!(cloned.rotated);
    assert!(enrolled(&store, "provider-b").is_err(), "old bound.json cannot bind a new key");
    assert!(enrolled(&store, "provider-a").is_err());
    // Ordinary host restart does not repair an enrollment that never happened.
    assert!(!ensure_install_key(&mut store, "provider-b", &SystemRandom::new()).unwrap().rotated);
    assert!(enrolled(&store, "provider-b").is_err());
}

#[test]
fn identity_requires_receipt_current_binding_and_key() {
    let (mut store, _) = enrolled_store();
    store.write(BIND_FILE, "{}", 0o600).unwrap();
    assert!(enrolled(&store, "provider-a").is_err());
    store.remove(BIND_FILE);
    assert!(enrolled(&store, "").is_err());
    store.make_unreadable(BIND_FILE);
    assert!(enrolled(&store, "provider-a").is_err());

    for path in [RECEIPT, BOUND_FILE, INSTALL_KEY_FILE] {
        let (mut store, _) = enrolled_store();
        store.remove(path);
        assert!(enrolled(&store, "provider-a").is_err(), "missing {path}");
    }
    let (mut store, _) = enrolled_store();
    let other = InstallKey::generate(&SystemRandom::new()).unwrap();
    store
        .write(
            INSTALL_KEY_FILE,
            &json!({"instance_id":"provider-a","pkcs8":other.pkcs8_base64url()}).to_string(),
            0o600,
        )
        .unwrap();
    assert!(enrolled(&store, "provider-a").is_err());
}

#[test]
fn scoped_identity_does_not_block_on_bound_machine_before_scope_read() {
    let (mut store, _) = enrolled_store();
    let before_key = store.read(INSTALL_KEY_FILE).unwrap();
    store.remove(RECEIPT);
    let root = tempfile::tempdir().unwrap();
    let error = scoped(&mut store, &Paths::new(root.path())).unwrap_err();
    assert_eq!(error, "scope is unavailable");
    assert_eq!(store.read(INSTALL_KEY_FILE).as_deref(), Some(before_key.as_str()));
    assert!(store.read(SCOPED_INSTALL_KEY_FILE).is_none());
    assert!(store.read(SCOPED_RECEIPT).is_none());
}

#[test]
fn scoped_identity_refuses_bound_machine_without_rotating_legacy_key() {
    let (mut store, _) = enrolled_store();
    let before_key = store.read(INSTALL_KEY_FILE).unwrap();
    let before_receipt = store.read(RECEIPT).unwrap();

    let result = scoped(&mut store, &Paths::new(tempfile::tempdir().unwrap().path()));
    assert!(result.is_err());
    assert_eq!(store.read(INSTALL_KEY_FILE).as_deref(), Some(before_key.as_str()));
    assert_eq!(store.read(RECEIPT).as_deref(), Some(before_receipt.as_str()));
}
