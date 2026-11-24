use std::collections::HashMap;
use std::sync::Mutex;

use super::*;

type Items = HashMap<(String, String), Vec<u8>>;

pub(super) struct MemoryKeychain {
    items: Mutex<Option<Items>>,
    reject_write: std::sync::atomic::AtomicBool,
    refusals: Mutex<Vec<Refusal>>,
}

struct Refusal {
    service: String,
    account: String,
    error: Error,
    write_only: bool,
}

impl MemoryKeychain {
    const fn new() -> Self {
        Self {
            items: Mutex::new(None),
            reject_write: std::sync::atomic::AtomicBool::new(false),
            refusals: Mutex::new(Vec::new()),
        }
    }

    fn refuse(&self, service: &str, account: &str, error: Error, write_only: bool) {
        self.refusals.lock().unwrap().push(Refusal {
            service: service.to_owned(),
            account: account.to_owned(),
            error,
            write_only,
        });
    }

    fn authorize(&self, service: &str, account: &str, writing: bool) -> Result<(), Error> {
        for item in self.refusals.lock().unwrap().iter() {
            if item.service == service && item.account == account && (writing || !item.write_only) {
                return Err(item.error);
            }
        }
        Ok(())
    }
}

pub(super) static KEYCHAIN: MemoryKeychain = MemoryKeychain::new();

impl Store<'_> {
    pub(crate) fn refuse_test_item(&self, id: &str, error: Error) {
        KEYCHAIN.refuse(&self.service(), id, error, false);
    }
}

impl Keychain for MemoryKeychain {
    fn read(&self, service: &str, account: &str) -> Result<Option<Vec<u8>>, Error> {
        self.authorize(service, account, false)?;
        Ok(self
            .items
            .lock()
            .unwrap()
            .as_ref()
            .and_then(|items| items.get(&(service.to_owned(), account.to_owned())).cloned()))
    }

    fn write(&self, service: &str, account: &str, value: &[u8]) -> Result<bool, Error> {
        self.authorize(service, account, true)?;
        if self.reject_write.load(std::sync::atomic::Ordering::Relaxed) {
            return Err(Error::KeychainLocked);
        }
        Ok(self
            .items
            .lock()
            .unwrap()
            .get_or_insert_with(HashMap::new)
            .insert((service.to_owned(), account.to_owned()), value.to_vec())
            .is_none())
    }

    fn delete(&self, service: &str, account: &str) -> Result<(), Error> {
        self.authorize(service, account, false)?;
        if let Some(items) = self.items.lock().unwrap().as_mut() {
            items.remove(&(service.to_owned(), account.to_owned()));
        }
        Ok(())
    }
}

#[test]
fn subscription_migration_retries_a_failed_keychain_write_and_reads_the_rotated_record() {
    use std::sync::atomic::Ordering;
    let home = tempfile::tempdir().unwrap();
    let keychain = MemoryKeychain::new();
    let store = Store { home: home.path(), provider: "chatgpt", keychain: Some(&keychain) };
    let id = "chatgpt";
    let path = store.path(id).unwrap();
    let original = json!({
        "client_id": "fixture", "sub": "fixture-user", "expires_at": 100,
        "access_token": "fixture-access", "refresh_token": "fixture-refresh", "id_token": "fixture-id"
    });
    let bytes = serde_json::to_vec(&original).unwrap();
    crate::chatgpt::store::write_atomic(&path, &bytes).unwrap();

    keychain.reject_write.store(true, Ordering::Relaxed);
    assert!(matches!(store.read::<Value>(id), Err(Error::KeychainLocked)));
    assert!(std::fs::read(&path).is_ok_and(|actual| actual == bytes));

    keychain.reject_write.store(false, Ordering::Relaxed);
    assert!(store.read::<Value>(id).is_ok_and(|actual| actual.as_ref() == Some(&original)));
    let index: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    assert!(index.get("access_token").is_none());
    assert!(index.get("refresh_token").is_none());
    assert!(index.get("id_token").is_none());
    assert_eq!(index["signed_in"], true);
    assert!(index["keychain"].as_str().is_some());
    let rotated = json!({
        "client_id": "fixture", "sub": "fixture-user", "expires_at": 200,
        "access_token": "fixture-access-2", "refresh_token": "fixture-refresh-2"
    });
    store.write(id, &rotated).unwrap();
    assert!(store.read::<Value>(id).is_ok_and(|actual| actual.as_ref() == Some(&rotated)));
    assert_eq!(keychain.items.lock().unwrap().as_ref().map(HashMap::len), Some(1));
    store.delete(id).unwrap();
    assert!(!path.exists());
    assert!(keychain.read(&store.service(), id).unwrap().is_none());
}

#[test]
fn subscription_read_distinguishes_another_build_from_a_locked_keychain() {
    let home = tempfile::tempdir().unwrap();
    let keychain = MemoryKeychain::new();
    let store = Store { home: home.path(), provider: "grok", keychain: Some(&keychain) };
    let record = json!({"access_token": "fixture", "expires_at": 100});
    for (id, error) in
        [("other-build", Error::KeychainOtherBuild), ("locked", Error::KeychainLocked)]
    {
        store.write(id, &record).unwrap();
        keychain.refuse(&store.service(), id, error, false);
        assert_eq!(store.available::<Value>(id), Err(error));
        assert_eq!(store.metadata(id).unwrap()["signed_in"], true);
    }
}

#[test]
fn subscription_write_moves_a_refused_item_to_a_new_account() {
    let home = tempfile::tempdir().unwrap();
    let keychain = MemoryKeychain::new();
    let store = Store { home: home.path(), provider: "grok", keychain: Some(&keychain) };
    for (id, write_only) in [("reauth", false), ("refresh", true)] {
        let prior = json!({"access_token": "fixture-old", "expires_at": 100});
        let fresh = json!({"access_token": "fixture-new", "expires_at": 200});
        store.write(id, &prior).unwrap();
        let service = store.service();
        let prior_bytes = keychain.read(&service, id).unwrap().unwrap();
        keychain.refuse(&service, id, Error::KeychainOtherBuild, write_only);

        store.write(id, &fresh).unwrap();
        let index: Value = decode(&std::fs::read(store.path(id).unwrap()).unwrap()).unwrap();
        let generation = generation(&index).unwrap().unwrap();
        let account = account(id, Some(generation));
        assert_eq!(
            index["keychain"],
            format!("keychain:cmux-vault/.subscription/{service}/{account}")
        );
        assert!(index.get("access_token").is_none());
        assert!(store.read::<Value>(id).is_ok_and(|record| record.as_ref() == Some(&fresh)));
        assert!(keychain.read(&service, &account).unwrap().is_some());
        store.delete(id).unwrap();
        assert!(keychain.read(&service, &account).unwrap().is_none());
        let items = keychain.items.lock().unwrap();
        assert!(items.as_ref().unwrap().get(&(service, id.into())) == Some(&prior_bytes));
    }
}

#[test]
fn subscription_migration_prefers_the_grant_with_the_later_expiry() {
    let home = tempfile::tempdir().unwrap();
    let keychain = MemoryKeychain::new();
    let store = Store { home: home.path(), provider: "kimi", keychain: Some(&keychain) };
    for (id, legacy_expiry, keychain_expiry) in [("newer-file", 200, 100), ("newer-item", 100, 200)]
    {
        let legacy = json!({"access_token": "fixture-legacy", "expires_at": legacy_expiry, "region": "global"});
        let stored = json!({"access_token": "fixture-item", "expires_at": keychain_expiry, "region": "global"});
        let path = store.path(id).unwrap();
        let service = store.service();
        crate::chatgpt::store::write_atomic(&path, &serde_json::to_vec(&legacy).unwrap()).unwrap();
        keychain.write(&service, id, &serde_json::to_vec(&stored).unwrap()).unwrap();
        let expected = if legacy_expiry > keychain_expiry { legacy } else { stored };
        assert!(store.read::<Value>(id).is_ok_and(|record| record.as_ref() == Some(&expected)));
        assert!(store.read::<Value>(id).is_ok_and(|record| record.as_ref() == Some(&expected)));
        let index: Value = decode(&std::fs::read(path).unwrap()).unwrap();
        assert!(index.get("access_token").is_none());
        assert_eq!(index["expires_at"], 200);
    }
}

#[test]
fn subscription_startup_migrates_all_four_provider_folders_without_routes() {
    let home = tempfile::tempdir().unwrap();
    let id = "orphan";
    let record = json!({
        "client_id": "fixture", "sub": "fixture-user", "expires_at": 100,
        "access_token": "fixture-access", "refresh_token": "fixture-refresh"
    });
    let providers = ["chatgpt", "grok", "copilot", "kimi"];
    for provider in providers {
        let store = Store::new(home.path(), provider);
        let path = store.path(&format!("{id}-{provider}")).unwrap();
        crate::chatgpt::store::write_atomic(&path, &serde_json::to_vec(&record).unwrap()).unwrap();
    }

    migrate_legacy(home.path());

    for provider in providers {
        let store = Store::new(home.path(), provider);
        let id = format!("{id}-{provider}");
        let index: Value = decode(&std::fs::read(store.path(&id).unwrap()).unwrap()).unwrap();
        assert!(index["keychain"].is_string());
        assert!(index.get("access_token").is_none());
        assert!(index.get("refresh_token").is_none());
        assert!(store.read::<Value>(&id).is_ok_and(|value| value.as_ref() == Some(&record)));
    }
}

#[test]
fn subscription_startup_keeps_same_route_id_grants_separate_across_providers() {
    let home = tempfile::tempdir().unwrap();
    let active = Store::new(home.path(), "grok");
    let orphan = Store::new(home.path(), "kimi");
    let id = "shared-id";
    let grok = json!({
        "access_token": "fixture-grok", "refresh_token": "refresh-grok", "expires_at": 100
    });
    let kimi = json!({
        "access_token": "fixture-kimi", "refresh_token": "refresh-kimi", "expires_at": 200, "region": "global"
    });
    active.write(id, &grok).unwrap();
    let path = orphan.path(id).unwrap();
    crate::chatgpt::store::write_atomic(&path, &serde_json::to_vec(&kimi).unwrap()).unwrap();

    migrate_legacy(home.path());

    let index: Value = decode(&std::fs::read(path).unwrap()).unwrap();
    assert!(index.get("access_token").is_none());
    assert!(active.read::<Value>(id).is_ok_and(|record| record.as_ref() == Some(&grok)));
    assert!(orphan.read::<Value>(id).is_ok_and(|record| record.as_ref() == Some(&kimi)));
}

#[test]
fn subscription_migration_ignores_a_different_providers_item_left_after_removal() {
    let home = tempfile::tempdir().unwrap();
    let keychain = MemoryKeychain::new();
    let removed = Store { home: home.path(), provider: "grok", keychain: Some(&keychain) };
    let legacy = Store { home: home.path(), provider: "kimi", keychain: Some(&keychain) };
    let id = "shared-id";
    let grok =
        json!({"access_token": "fixture-grok", "refresh_token": "refresh-grok", "expires_at": 200});
    let kimi = json!({"access_token": "fixture-kimi", "refresh_token": "refresh-kimi", "expires_at": 100, "region": "global"});
    removed.write(id, &grok).unwrap();
    keychain.refuse(&removed.service(), id, Error::KeychainOtherBuild, false);
    removed.delete(id).unwrap();
    keychain.refusals.lock().unwrap().clear();
    crate::chatgpt::store::write_atomic(
        &legacy.path(id).unwrap(),
        &serde_json::to_vec(&kimi).unwrap(),
    )
    .unwrap();

    assert!(legacy.read::<Value>(id).is_ok_and(|record| record.as_ref() == Some(&kimi)));
    let original = keychain.read(&removed.service(), id).unwrap().unwrap();
    assert!(decode::<Value>(&original).is_ok_and(|record| record == grok));
}

#[test]
fn a_locked_keychain_is_probed_again_after_backoff() {
    use std::time::{Duration, Instant};
    let now = Instant::now();
    let mut probe = KeychainProbe::default();
    assert!(!probe.available(now, || false));
    assert!(!probe.available(now, || panic!("a burst must not repeat the probe")));
    assert!(probe.available(now + Duration::from_secs(2), || true));
    assert!(probe.available(now + Duration::from_secs(3), || panic!("success is cached")));
}
